# Operations Runbook — Cloud Native Taskr

## Cách dùng runbook này
Mỗi scenario có: Triệu chứng → Chẩn đoán nhanh → Xử lý theo thứ tự.
Không bỏ qua bước chẩn đoán dù tưởng đã biết nguyên nhân.

---

## Scenario 1: task-api CrashLoopBackOff

**Triệu chứng:** `kubectl -n taskr get pods` hiện STATUS = CrashLoopBackOff

**Chẩn đoán:**
```bash
# Xem log của lần crash gần nhất
kubectl -n taskr logs <pod-name> --previous

# Xem event liên quan
kubectl -n taskr describe pod <pod-name>

# Kiểm tra exit code (137 = OOM, 1 = runtime error, 2 = config error)
kubectl -n taskr get pod <pod-name> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}'
```

**Xử lý theo exit code:**

Exit 137 (OOM Kill):
```bash
# Tăng memory limit tạm thời
kubectl -n taskr set resources deployment/task-api --limits=memory=256Mi
# Sau đó cập nhật deployment.yaml và commit
```

Exit 1 (runtime panic):
```bash
# Tìm PANIC line trong log
kubectl -n taskr logs <pod-name> --previous | grep -i panic
# Rollback về version trước nếu do code mới
kubectl argo rollouts undo task-api -n taskr
```

Exit 1 (config error - biến môi trường thiếu):
```bash
# Xem env hiện tại của pod
kubectl -n taskr exec <pod-name> -- env | grep -E 'DATABASE|SERVICE|HTTP'
# Nếu thiếu env, kiểm tra deployment.yaml env section
```

---

## Scenario 2: ArgoCD stuck ở Progressing / OutOfSync

**Triệu chứng:** ArgoCD UI hiện vàng "Progressing" quá 5 phút

**Chẩn đoán:**
```bash
# Xem chi tiết sync status
kubectl -n argocd get app task-api-local -o jsonpath='{.status.conditions}' | jq

# Xem resource nào đang fail
kubectl -n argocd get app task-api-local -o jsonpath='{.status.operationState}' | jq

# Xem log của ArgoCD application controller
kubectl -n argocd logs deployment/argocd-application-controller --tail=50
```

**Xử lý phổ biến:**

Resource conflict (ai đó kubectl edit thủ công):
```bash
# Force sync với prune
argocd app sync task-api-local --force --prune
# Hoặc từ UI: click "Sync" → check "Force" → "Synchronize"
```

Helm chart version không tồn tại:
```bash
# Kiểm tra chart version trong Application spec
kubectl -n argocd get app prometheus-stack -o jsonpath='{.spec.source.targetRevision}'
# Tìm version hợp lệ: helm search repo prometheus-community/kube-prometheus-stack --versions | head -5
```

CRD conflict khi upgrade:
```bash
# Apply CRD thủ công trước
kubectl apply --server-side -f https://raw.githubusercontent.com/.../crds.yaml
# Sau đó sync lại
argocd app sync <app-name>
```

---

## Scenario 3: Metrics không xuất hiện trong Grafana

**Triệu chứng:** Dashboard task-api trống, "No data"

**Chẩn đoán theo luồng:**
```bash
# 1. task-api có expose /metrics không?
kubectl -n taskr port-forward svc/task-api 8080:80 &
curl http://localhost:8080/metrics | head -20

# 2. Prometheus có scrape được không?
# Mở http://prometheus.local/targets và tìm taskr
# Status phải là UP

# 3. Prometheus có ServiceMonitor/annotation không?
kubectl -n taskr get pod <task-api-pod> -o jsonpath='{.metadata.annotations}' | jq
# Phải thấy prometheus.io/scrape: "true"

# 4. Kiểm tra Prometheus scrape config
kubectl -n observability exec -it pod/prometheus-kube-prometheus-stack-prometheus-0 -- \
  wget -qO- localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.namespace=="taskr")'
```

**Xử lý:**
```bash
# Nếu annotation thiếu
kubectl -n taskr annotate pod <pod-name> \
  prometheus.io/scrape=true \
  prometheus.io/port=8080 \
  prometheus.io/path=/metrics

# Nếu Grafana datasource sai URL
# Vào http://grafana.local → Configuration → Data Sources → Prometheus
# URL phải là: http://prometheus-operated.observability.svc.cluster.local:9090
```

---

## Scenario 4: Cluster hết disk (kind local)

**Triệu chứng:** Pod evicted, PersistentVolume fail, node condition DiskPressure

**Chẩn đoán:**
```bash
# Check disk usage trên node
docker exec taskr-control-plane df -h
docker exec taskr-worker df -h

# Xem node condition
kubectl describe node | grep -A5 Conditions
```

**Xử lý:**
```bash
# Xóa unused Docker images trên host
docker image prune -f

# Xóa log cũ trong cluster (nếu Loki persistence enabled)
kubectl -n observability exec -it pod/loki-0 -- \
  find /var/loki -name "*.gz" -mtime +1 -delete

# Reset cluster nếu cần
make clean && make cluster-up && make bootstrap
```

---

## Scenario 5: Canary rollout bị stuck ở Paused

**Triệu chứng:** `kubectl argo rollouts get rollout task-api -n taskr` hiện Paused

**Chẩn đoán:**
```bash
# Xem trạng thái chi tiết
kubectl argo rollouts get rollout task-api -n taskr -w

# Xem Analysis result
kubectl -n taskr get analysisrun -l rollout-name=task-api

# Xem metric value thực tế
kubectl -n taskr describe analysisrun <analysisrun-name>
```

**Xử lý:**
```bash
# Option 1: Promote thủ công (nếu bạn tin là OK)
kubectl argo rollouts promote task-api -n taskr

# Option 2: Abort và rollback về stable
kubectl argo rollouts abort task-api -n taskr
kubectl argo rollouts undo task-api -n taskr

# Option 3: Điều chỉnh threshold nếu metric query sai
# Sửa AnalysisTemplate, commit, ArgoCD sync
```

---

## Quy trình postmortem (sau mọi incident P1/P2)

Template: `docs/postmortem-template.md`

Bắt buộc điền trong 5 ngày:
1. Timeline (UTC, từng phút)
2. Impact (số user bị ảnh hưởng, thời gian downtime)
3. Root cause (dùng 5-Why)
4. Điều gì hoạt động tốt
5. Điều gì không hoạt động tốt
6. Action items (assignee + deadline cụ thể)

**Nguyên tắc blameless:** postmortem tập trung vào hệ thống, không vào cá nhân.

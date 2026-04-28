# Hướng Dẫn Triển Khai Cloud Native Taskr
### Với 16 CNCF Tools · Phase 0 → 6 · GCP $300

> Toàn bộ phát triển chạy local bằng kind (miễn phí). GCP chỉ dùng khi demo Phase 4+.
> Mỗi phase xây trên phase trước — không bỏ qua bước nào.

---

## Bản đồ CNCF tools theo phase

| Phase | CNCF Tools (Graduated) | CNCF Tools (Incubating/Sandbox) | Non-CNCF |
|---|---|---|---|
| 0 | — | — | gcloud, Docker, Go |
| 1 | **Kubernetes · Helm · Argo CD** | **cert-manager** | ingress-nginx, kind |
| 2 | **Prometheus · OpenTelemetry** | — | Grafana · Loki · Tempo |
| 3 | **Linkerd** | **Kyverno** | Sealed Secrets · Trivy |
| 4 | — | **CloudNativePG** (Sandbox) | Terraform · Velero |
| 5 | **Argo Rollouts** | **KEDA** | GitHub Actions |
| 6 | — | **Chaos Mesh · OpenCost** (Sandbox) | — |

**Tổng: 16 CNCF tools** (8 Graduated · 4 Incubating · 4 Sandbox) trên 24 tools toàn stack (67% CNCF).

---

## Phase 0 — Chuẩn bị môi trường
*Tools: gcloud CLI · Docker Desktop · Go 1.22+*

Truy cập `https://cloud.google.com/free`, đăng ký bằng Google account riêng. Bạn nhận $300 credit có hiệu lực 90 ngày — ghi ngay ngày hết hạn vào calendar. Tạo project `taskr-dev`, lưu lại **Project ID** (dạng `taskr-dev-428391`) vì mọi lệnh CLI đều dùng ID này.

```bash
# macOS
brew install --cask google-cloud-sdk
brew install kubectl kind helm go

# Verify toàn bộ
gcloud --version && kubectl version --client && kind --version && helm version && go version && docker info
```

```bash
# Đăng nhập và cấu hình
gcloud auth login
gcloud config set project taskr-dev-428391
gcloud auth application-default login   # Terraform dùng sau

# Enable APIs (làm một lần)
gcloud services enable container.googleapis.com compute.googleapis.com \
  artifactregistry.googleapis.com iam.googleapis.com
```

**Bắt buộc:** Vào `console.cloud.google.com/billing` → tạo budget $50/tháng với alert 50%/90%/100%. Budget không tự tắt tài nguyên — bạn phải chủ động `destroy` sau mỗi session GCP.

Chạy `bash scripts/00-prerequisites.sh` — tất cả `✓` là sẵn sàng.

---

## Phase 1 — Local Kubernetes + Go Service + ArgoCD
*CNCF Graduated: **Kubernetes · Helm · ArgoCD** · CNCF Incubating: **cert-manager***

Phase này 100% miễn phí, chạy hoàn toàn trên máy local.

```bash
make prereq        # kiểm tra lần cuối
make cluster-up    # kind tạo cluster 3 node (~5 phút lần đầu)
kubectl get nodes  # phải thấy 3 node STATUS=Ready
```

`make bootstrap` cài ba thành phần theo thứ tự: **ingress-nginx** (L7 router, port 80/443 forward vào cluster), **cert-manager** *(CNCF Incubating)* (TLS tự động, local dùng self-signed, GCP đổi sang Let's Encrypt không cần sửa code), **ArgoCD** *(CNCF Graduated)* (GitOps engine, resource đã tối giản cho 8GB RAM).

```bash
make bootstrap
echo '127.0.0.1 taskr.local argocd.local' | sudo tee -a /etc/hosts

# Build và deploy Go service
cd services/task-api && go mod tidy && cd ../..
make build             # Docker distroless image ~20MB, load vào kind
make deploy-task-api   # Kustomize overlay local (imagePullPolicy: Never)

# Verify
kubectl -n taskr get pods        # Running 1/1
make smoke-test                  # nhận JSON hợp lệ = Phase 1 xong
open http://argocd.local         # admin / $(make get-argocd-password)
```

**Lỗi thường gặp:** `ImagePullBackOff` → chạy lại `make build`. `502 Bad Gateway` → đợi 30 giây. Port 80 bị chiếm → `sudo lsof -i :80`.

---

## Phase 2 — Observability
*CNCF Graduated: **Prometheus · OpenTelemetry SDK + Collector***
*Non-CNCF: Grafana · Loki · Tempo (Grafana Labs, open source)*

Làm Phase 2 **trước** Phase 3: nếu security vỡ thứ gì, bạn cần Grafana để debug. OpenTelemetry *(CNCF Graduated)* đóng vai trò abstraction layer — metrics/traces từ Go service qua OTel Collector đến Prometheus và Tempo mà không lock-in vendor.

```bash
echo '127.0.0.1 grafana.local prometheus.local' | sudo tee -a /etc/hosts

# Merge code Phase 2 (main.go + router.go + go.mod đã thêm OTel SDK)
cd services/task-api && go mod tidy && cd ../..
make build deploy-task-api       # rebuild với OTel instrumentation

# Cài toàn bộ observability stack (~10 phút, pull ~2GB images)
make bootstrap-observability
```

Tổng RAM thêm ~900Mi — đã tối giản cho 8GB: Prometheus 256Mi, Grafana 128Mi, Loki 128Mi, Tempo 128Mi, OTel Collector 64Mi.

```bash
open http://grafana.local        # admin / taskr-grafana-admin
# Dashboard "task-api — RED Metrics" tự load từ ConfigMap
make smoke-test                  # generate traffic
# Grafana Explore → Loki → {namespace="taskr"} để xem log tập trung
```

Ba alert rule sẵn tại `http://prometheus.local/alerts`: service down 5 phút, error rate >5%, latency p99 >500ms.

---

## Phase 3 — Security
*CNCF Graduated: **Linkerd** (mTLS) · CNCF Incubating: **Kyverno***
*Non-CNCF: Sealed Secrets (Bitnami) · Trivy (Aqua Security)*

Thứ tự bên trong Phase 3 quan trọng: **Kyverno trước → NetworkPolicy sau → Sealed Secrets cuối**.

```bash
make bootstrap-security   # cài Kyverno + apply 5 ClusterPolicy + Sealed Secrets controller
make policy-check         # thử deploy pod root → phải bị Kyverno reject
```

5 ClusterPolicy **Kyverno** *(CNCF Incubating)* enforce: cấm root, bắt buộc resource requests, chỉ trusted registry, yêu cầu label chuẩn, cấm tag `latest`.

```bash
# NetworkPolicy: zero-trust cho namespace taskr
kubectl apply -f platform/security/networkpolicy/taskr-policies.yaml
make smoke-test   # ingress phải vẫn hoạt động sau default-deny-all

# Sealed Secrets: encrypt secret trước khi commit Git
brew install kubeseal
kubectl create secret generic db-credentials \
  --from-literal=password=my-password --namespace taskr \
  --dry-run=client -o yaml | kubeseal --format yaml \
  > platform/security/sealed-secrets/db-credentials.yaml
git add platform/security/sealed-secrets/db-credentials.yaml  # an toàn commit

make scan-image   # Trivy quét CVE trong Docker image
```

**Linkerd** *(CNCF Graduated)* inject sidecar vào namespace taskr, mọi giao tiếp east-west tự động được mã hóa mTLS — không cần thay đổi code application.

---

## Phase 4 — PostgreSQL + GCP Deploy
*CNCF Sandbox: **CloudNativePG** · Non-CNCF: Terraform · Velero*

Lần đầu tốn credit GCP. **Hexagonal architecture payoff**: domain layer Go không đổi một dòng, chỉ swap adapter từ memory sang postgres.

```bash
# Cài CloudNativePG operator
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
kubectl apply -f platform/security/sealed-secrets/db-credentials.yaml
kubectl apply -f deploy/task-api/overlays/gcp-demo/postgres-cluster.yaml
# CloudNativePG tự tạo: taskr-postgres-rw (primary) + taskr-postgres-ro (replica)

# GCP infrastructure với Terraform
find infra/terraform -name "*.tf" | xargs sed -i "s/YOUR_PROJECT_ID/taskr-dev-428391/g"
gsutil mb gs://taskr-dev-428391-tfstate
cd infra/terraform/envs/gcp-demo && terraform init && terraform apply
```

```bash
make gcp-push GCP_PROJECT=taskr-dev-428391   # build + push lên Artifact Registry
# Lấy LB IP: kubectl -n ingress-nginx get svc ingress-nginx-controller
# Sửa kustomization.yaml: taskr.REPLACE_WITH_LB_IP.nip.io
make gcp-deploy
curl http://taskr.34.142.123.45.nip.io/api/v1/tasks

# SAU KHI DEMO — BẮT BUỘC
make gcp-down GCP_PROJECT=taskr-dev-428391   # GKE idle ~$0.20/giờ
```

---

## Phase 5 — Canary Deployment
*CNCF Graduated: **Argo Rollouts** · CNCF Incubating: **KEDA***

Argo Rollouts *(CNCF Graduated)* thay RollingUpdate bằng canary thông minh: Prometheus làm gate tự động quyết định promote hay rollback.

```bash
make bootstrap-rollouts
kubectl -n taskr delete deployment task-api
kubectl apply -f platform/rollouts/task-api-rollout.yaml
# Canary flow: 10% → 5 phút → Prometheus check → 25% → 50% → 100%
# Error rate >5% bất kỳ bước nào → auto-rollback
```

GitHub Actions CI pipeline: lint → test (`-race`) → govulncheck → build → Trivy scan → push → bump image tag → ArgoCD deploy → canary rollout. Thêm secrets `GCP_PROJECT_ID`, `GCP_WIF_PROVIDER`, `GCP_SERVICE_ACCOUNT` vào GitHub repo.

```bash
# Demo auto-rollback
kubectl argo rollouts set image task-api task-api=task-api:buggy -n taskr
kubectl argo rollouts get rollout task-api -n taskr -w
# Quan sát: hệ thống tự rollback sau ~10 phút, không downtime
```

---

## Phase 6 — FinOps & Vận hành
*CNCF Incubating: **Chaos Mesh** · CNCF Sandbox: **OpenCost***

```bash
kubectl apply -f platform/finops/opencost.yaml   # ResourceQuota + LimitRange + OpenCost
make cost-report    # cost allocation per namespace trong 24h
```

**Chaos Mesh** *(CNCF Incubating)* verify HA không chỉ trên giấy:

```bash
kubectl apply -f platform/finops/chaos-experiments.yaml
# 3 experiment: pod-kill · network-delay · cpu-stress
# Song song chạy: for i in {1..60}; do curl -s http://localhost/api/v1/tasks; sleep 5; done
# Kết quả: pod tự heal, HTTP vẫn 200 xuyên suốt
kubectl delete -f platform/finops/chaos-experiments.yaml   # xóa sau khi xong
```

Đọc `docs/runbook.md` **trước khi** có incident: 5 scenario (CrashLoopBackOff, ArgoCD stuck, Grafana no data, cluster hết disk, canary paused) với triệu chứng → chẩn đoán → xử lý step-by-step.

---

## Tóm tắt · Checklist hoàn thành

```
Phase 0  ✓  gcloud auth + budget alert
Phase 1  ✓  make smoke-test → JSON hợp lệ + ArgoCD UI load
Phase 2  ✓  Grafana dashboard có data + Loki có log
Phase 3  ✓  Kyverno reject pod root + smoke-test vẫn pass
Phase 4  ✓  curl taskr.<LB_IP>.nip.io/api/v1/tasks + make gcp-down
Phase 5  ✓  demo auto-rollback không downtime
Phase 6  ✓  chaos experiment pass + cost-report có số
```

> **Nguyên tắc chi phí:** Phase 1–3 = $0 (local). Phase 4–6 = ~$0.20/giờ GCP.
> Với $300 credit, bạn có hơn 200 giờ demo session nếu luôn nhớ `make gcp-down`.

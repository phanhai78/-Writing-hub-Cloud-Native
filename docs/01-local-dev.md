# Phase 1 — Local Kubernetes + ArgoCD + task-api

Phase này mục tiêu: có một hệ thống chạy được end-to-end trên máy local.
Sau khi hoàn tất, bạn sẽ có:

- Một cluster Kubernetes thực sự (3 node) chạy trên Docker.
- ArgoCD quản lý mọi deployment qua Git.
- Một Go service `task-api` được deploy với hexagonal architecture.
- Smoke test chạy được: `curl` tạo task và query task qua ingress.

Ước tính thời gian: 1-2 giờ nếu chưa quen, 20 phút nếu đã biết.

---

## Luồng triển khai

Mở terminal ở thư mục gốc của repo. Tất cả lệnh dưới đây chạy từ đó.

### Bước 1. Kiểm tra công cụ

```bash
make prereq
```

Script này liệt kê các tool cần thiết và version tối thiểu. Nếu thiếu tool,
output sẽ chỉ cách cài. Không tool nào được tự động cài — bạn luôn chủ động
biết mình đang thêm gì vào máy.

**Output mong đợi:** mọi dòng có dấu `✓` xanh lá. Nếu có dấu `✗` đỏ, xử
lý theo gợi ý rồi chạy lại.

### Bước 2. Tạo kind cluster

```bash
make cluster-up
```

Lệnh này tạo cluster 3 node (1 control plane + 2 worker) theo cấu hình
`infra/kind/cluster.yaml`. Mất 1-2 phút lần đầu vì kind phải pull Docker
image `kindest/node` (~350MB).

**Điều quan trọng đã xảy ra:** port 80 và 443 của node control-plane đã được
map vào máy bạn. Nghĩa là khi ingress-nginx bind vào port của node, bạn có
thể truy cập qua `http://localhost` trực tiếp.

Kiểm tra:

```bash
kubectl get nodes
# Phải thấy 3 node ở trạng thái Ready
```

### Bước 3. Cài platform components

```bash
make bootstrap
```

Script `scripts/02-bootstrap.sh` cài ba thứ:

Thứ nhất là **ingress-nginx** — controller L7 nhận traffic từ ngoài. Cấu
hình đặc biệt cho kind: nodeSelector trỏ vào node có label `ingress-ready=true`,
hostPort=true để bind thẳng vào port 80/443 của node, và tolerations cho
phép schedule lên control-plane.

Thứ hai là **cert-manager** với một `ClusterIssuer` self-signed. Ở local
chúng ta không có domain thật để lấy cert Let's Encrypt, nên dùng self-signed.
Khi lên GCP, chỉ cần thay `ClusterIssuer` sang Let's Encrypt ACME — code
application không đổi.

Thứ ba là **ArgoCD** với tham số đã optimize cho resource nhỏ (memory request
chỉ 128-256Mi cho mỗi component thay vì default 512Mi).

Script cũng tạo Ingress cho ArgoCD UI tại `argocd.local`.

### Bước 4. Thêm host entries

Kind map localhost → cluster, nhưng ingress-nginx cần biết *host* nào đang
được request (HTTP Host header). Chúng ta dùng hostname giả `taskr.local`
và `argocd.local` để phân biệt.

```bash
echo '127.0.0.1 taskr.local argocd.local' | sudo tee -a /etc/hosts
```

Lệnh `sudo` vì `/etc/hosts` thuộc quyền root. Chỉ làm một lần; xóa sau khi
hoàn tất dự án bằng cách edit `/etc/hosts` thủ công.

### Bước 5. Truy cập ArgoCD UI

Mở `http://argocd.local` trong browser. Username: `admin`, password lấy từ:

```bash
make get-argocd-password
```

Giao diện ArgoCD ở đây chưa có Application nào (do ta chưa tạo). Đây là
trạng thái ban đầu — sạch và chờ lệnh.

### Bước 6. Build và deploy task-api

```bash
make build              # build image Docker và load vào kind
make deploy-task-api    # apply Kustomize overlay
```

Sau khi deploy, pod task-api sẽ ở namespace `taskr`. Kiểm tra:

```bash
kubectl -n taskr get pods
kubectl -n taskr logs -l app.kubernetes.io/name=task-api
```

**Output mong đợi:** pod `Running` với 1/1 ready. Log hiển thị "HTTP server
listening" và "initialized in-memory repository".

### Bước 7. Smoke test

```bash
make smoke-test
```

Lệnh này gọi `curl` qua ingress-nginx với host header `taskr.local`, tạo
task đầu tiên, rồi list tasks. Output phải là JSON hợp lệ.

Nếu muốn test thủ công:

```bash
curl -sS -H 'Host: taskr.local' http://localhost/api/v1/tasks | jq
curl -sS -X POST -H 'Host: taskr.local' \
  -H 'Content-Type: application/json' \
  -d '{"title":"Đầu task","description":"thử tay"}' \
  http://localhost/api/v1/tasks | jq
```

---

## Những gì vừa xảy ra — architecturally

Khi bạn gọi `curl http://localhost/api/v1/tasks` với host `taskr.local`,
đây là luồng end-to-end:

Đầu tiên request đến cổng 80 của máy bạn, được Docker forward vào port 80
của node control-plane kind (qua `extraPortMappings`). Bên trong node,
ingress-nginx đang bind cổng 80 qua `hostPort`, nhận request.

ingress-nginx đọc Host header `taskr.local`, match với Ingress resource
đã định nghĩa, biết đây là traffic của task-api. Nó forward request đến
Service `task-api.taskr.svc.cluster.local:80` (ClusterIP virtual).

kube-proxy (chạy trên mọi node) dịch Service IP thành pod IP thật thông
qua iptables rules. Request đến pod task-api, vào container, đến process Go.

Trong process, middleware chain của chi chạy: RequestID tạo ID, RealIP
rewrite remote address, hlog thêm logger vào context, Recoverer bọc panic.
Cuối cùng request đến handler `ListTasks`, gọi repository `FindAll`,
serialize kết quả thành JSON.

Response đi ngược lại đúng path đó. Toàn bộ mất vài mili giây ở local.

---

## Troubleshooting

**Pod `ImagePullBackOff`.** Image chưa load vào kind. Chạy lại `make build`
và kiểm tra output có dòng "Image đã sẵn sàng trong cluster". Nếu vẫn lỗi,
kiểm tra `imagePullPolicy: Never` trong overlay local.

**Pod `CrashLoopBackOff`.** Xem log: `kubectl -n taskr logs <pod-name>`.
Thường là lỗi runtime của Go code. Đặc biệt chú ý OOM (exit code 137) —
có thể tăng memory limit trong `deployment.yaml`.

**502 Bad Gateway khi `curl`.** Pod chưa ready. Check readiness probe với
`kubectl -n taskr describe pod <pod-name>`. Nếu readiness fail liên tục,
có thể endpoint `/readyz` có bug.

**ArgoCD UI không load.** Kiểm tra pod argocd-server đang running. Trang
load chậm lần đầu (SPA lớn); đợi 10 giây rồi refresh.

**"Too many redirects" khi truy cập ArgoCD.** Cấu hình ArgoCD server phải
có flag `--insecure` để tắt TLS server-side (ingress đã handle TLS).
Script bootstrap đã set, nhưng nếu bạn customize Helm values có thể bị
override.

**Mất port 80 vì đã bị process khác chiếm.** macOS hay có nginx/apache system.
Chạy `sudo lsof -i :80` để tìm, `sudo brew services stop nginx` để tắt.

**Cluster chậm/treo.** Docker Desktop chưa đủ RAM. Settings → Resources →
ít nhất 6GB. 4GB có thể chạy nhưng thỉnh thoảng OOM random.

---

## Reset hoàn toàn

Khi muốn bắt đầu lại từ đầu:

```bash
make clean   # xóa cluster + image
```

Tất cả dữ liệu mất (task-api dùng in-memory repo, tất nhiên). Chạy lại
từ bước 2.

---

## Bước tiếp theo

Khi mọi thứ chạy được và bạn đã thử nghiệm CRUD một chút, chuyển sang
**Phase 2 — Observability**. Phase 2 sẽ thêm Prometheus, Grafana, Loki,
Tempo vào cluster để bạn thấy được mỗi request đang đi đâu, metric nào
đang đo, và log nào đang được ghi ra. Đó là bước khi service bắt đầu
"có giọng nói" và bạn nghe được hệ thống đang "nói" gì.

# Phase 1 — Local Kubernetes + ArgoCD + task-api

Phase này mục tiêu: có một hệ thống chạy được end-to-end trên máy local
với security baseline đã được áp dụng ngay từ đầu (DevSecOps shift-left).
Sau khi hoàn tất, bạn sẽ có:

- Một cluster Kubernetes thực sự (3 node) chạy trên Docker.
- ArgoCD quản lý mọi deployment qua Git.
- Một Go service `task-api` được deploy với hexagonal architecture, dùng
  distroless base image và security context non-root.
- Trivy scan tích hợp vào Makefile, chạy ngay sau khi build image.
- Smoke test chạy được: `curl` tạo task và query task qua ingress.

Ước tính thời gian: 1-2 giờ nếu chưa quen, 30 phút nếu đã biết.

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

### Bước 6. Build, scan, và deploy task-api

```bash
make build              # build image Docker và load vào kind
make scan-image         # Trivy scan CVE — gate trước khi deploy (DevSecOps)
make deploy-task-api    # apply Kustomize overlay (chỉ chạy khi scan pass)
```

**Về `make scan-image`:** target này gọi `trivy image --severity HIGH,CRITICAL
--exit-code 1 task-api:local`. Nếu có CVE HIGH hoặc CRITICAL chưa có patch,
lệnh exit non-zero và Makefile sẽ dừng — bạn không deploy được image có lỗ
hổng nặng. Đây là **security gate** đầu tiên trong vòng đời image. Trong Phase
5, gate này sẽ được lặp lại trong CI pipeline trước khi push lên registry.

Image của task-api đã được hardened sẵn theo các nguyên tắc sau:

- Dùng `gcr.io/distroless/static-debian12` làm base (không có shell, không có
  package manager, attack surface tối thiểu).
- Multi-stage build: builder stage có Go toolchain, final stage chỉ có binary.
- Chạy non-root với `USER 65532:65532` (user nonroot mặc định của distroless).
- Pin base image về digest cụ thể chứ không dùng tag `latest`.

Sau khi deploy, pod task-api sẽ ở namespace `taskr`. Kiểm tra:

```bash
kubectl -n taskr get pods
kubectl -n taskr logs -l app.kubernetes.io/name=task-api

# Verify security context đã được áp dụng đúng
kubectl -n taskr get pod -l app.kubernetes.io/name=task-api \
  -o jsonpath='{.items[0].spec.securityContext}' | jq
# Phải thấy: runAsNonRoot:true, runAsUser:65532, fsGroup:65532
```

**Output mong đợi:** pod `Running` với 1/1 ready. Log hiển thị "HTTP server
listening" và "initialized in-memory repository". Security context có
`runAsNonRoot: true`.

### Bước 7. Quét vulnerability source code và sinh SBOM (DevSecOps)

Trước khi smoke test, chạy thêm hai check security baseline:

```bash
# Govulncheck — quét CVE trong Go module
cd services/task-api && govulncheck ./... && cd ../..

# Syft — sinh SBOM (Software Bill of Materials) ở format SPDX
syft task-api:local -o spdx-json=task-api-sbom.spdx.json

# Verify SBOM có dữ liệu
jq '.packages | length' task-api-sbom.spdx.json
# Nên thấy số > 0 (số dependency được liệt kê)
```

**Vì sao cần SBOM:** SBOM là danh sách đầy đủ mọi component trong image
(Go module, base image package, version, license). Khi một CVE mới được
công bố trong tương lai, bạn so SBOM với CVE database để biết ngay image
của mình có bị ảnh hưởng không, không cần rebuild và scan lại. Đây cũng
là yêu cầu compliance của NIST SSDF và US EO 14028.

File `task-api-sbom.spdx.json` được commit vào artifact của CI ở Phase 5,
không commit vào Git repo.

### Bước 8. Smoke test

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

**Tóm tắt DevSecOps đã có ở Phase 1:** image dùng distroless non-root,
Trivy scan gate trước deploy, govulncheck quét Go module, SBOM được sinh
ra cho mọi image build, pre-commit hook chặn secret từ workstation. Các
phase sau sẽ build trên nền tảng này thêm các lớp: observability tích
hợp security signal (Phase 2), policy enforcement và mTLS (Phase 3),
infrastructure-as-code scan (Phase 4), signed image và OIDC deploy
(Phase 5), security chaos engineering (Phase 6).
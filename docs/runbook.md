# Hướng Dẫn Triển Khai Cloud Native Taskr
### Với 16 CNCF Tools · Phase 0 → 6 · GCP $300

> Toàn bộ phát triển chạy local bằng kind (miễn phí). GCP chỉ dùng khi demo Phase 4+.
> Mỗi phase xây trên phase trước — không bỏ qua bước nào.

---

## Bản đồ CNCF tools + DevSecOps tools theo phase

| Phase | CNCF Tools (Graduated) | CNCF Tools (Incubating/Sandbox) | DevSecOps Tools |
|---|---|---|---|
| 0 | — | — | gcloud, Docker, Go, **Gitleaks, pre-commit, Trivy, Checkov, cosign, syft, govulncheck** |
| 1 | **Kubernetes · Helm · Argo CD** | **cert-manager** | ingress-nginx, kind, **Trivy image scan, Govulncheck, Syft SBOM, distroless** |
| 2 | **Prometheus · OpenTelemetry** | — | Grafana · Loki · Tempo, **Security signal dashboard, audit log scrape** |
| 3 | **Linkerd** | **Kyverno** | Sealed Secrets, **Falco, ModSecurity OWASP CRS, Trivy Operator** |
| 4 | — | **CloudNativePG** (Sandbox) | Terraform, Velero, **Checkov, tfsec, Security Command Center, CMEK encryption** |
| 5 | **Argo Rollouts** | **KEDA** | GitHub Actions, **Semgrep SAST, cosign keyless, Binary Authorization, OIDC WIF** |
| 6 | — | **Chaos Mesh · OpenCost** (Sandbox) | **Security chaos experiment, audit log review, quarterly access review** |

**Tổng: 16 CNCF tools** (8 Graduated · 4 Incubating · 4 Sandbox) + **15 DevSecOps tools**
trên 31 tools toàn stack. DevSecOps không phải là một phase riêng — nó được tích hợp
vào tất cả 6 phase theo principle "shift-left + defense in depth".

---

## Phase 0 — Chuẩn bị môi trường + DevSecOps baseline
*Tools: gcloud CLI · Docker Desktop · Go 1.22+ · Gitleaks · pre-commit · Trivy · Checkov · cosign · syft · govulncheck*

Truy cập `https://cloud.google.com/free`, đăng ký bằng Google account riêng. Bạn nhận $300 credit có hiệu lực 90 ngày — ghi ngay ngày hết hạn vào calendar. Tạo project `taskr-dev`, lưu lại **Project ID** (dạng `taskr-dev-428391`) vì mọi lệnh CLI đều dùng ID này.

```bash
# === Core tools ===
brew install --cask google-cloud-sdk
brew install kubectl kind helm go

# === DevSecOps tools (shift-left từ Phase 0) ===
brew install trivy gitleaks pre-commit checkov kubeseal cosign syft
go install golang.org/x/vuln/cmd/govulncheck@latest

# Verify toàn bộ
gcloud --version && kubectl version --client && kind --version && helm version && go version && docker info
trivy --version && gitleaks version && checkov --version && cosign version && syft version
```

```bash
# Đăng nhập và cấu hình
gcloud auth login
gcloud config set project taskr-dev-428391
gcloud auth application-default login   # Terraform dùng sau

# Enable APIs (làm một lần)
gcloud services enable container.googleapis.com compute.googleapis.com \
  artifactregistry.googleapis.com iam.googleapis.com \
  containerscanning.googleapis.com binaryauthorization.googleapis.com \
  securitycenter.googleapis.com cloudkms.googleapis.com
```

**Setup Workload Identity Federation cho GitHub Actions (KHÔNG dùng service account key):**
Chi tiết tại `docs/00-gcp-onboarding.md` Bước 6b. Cần làm xong trước Phase 5.

**Setup pre-commit hook:** tạo file `.pre-commit-config.yaml` với hooks Gitleaks +
Checkov, chạy `pre-commit install`. Chi tiết tại `docs/00-gcp-onboarding.md` Bước 8.

**Bắt buộc:** Vào `console.cloud.google.com/billing` → tạo budget $50/tháng với alert 50%/90%/100%. Budget không tự tắt tài nguyên — bạn phải chủ động `destroy` sau mỗi session GCP.

Chạy `bash scripts/00-prerequisites.sh` — tất cả `✓` là sẵn sàng.

---

## Phase 1 — Local Kubernetes + Go Service + ArgoCD (Security Baseline)
*CNCF Graduated: **Kubernetes · Helm · ArgoCD** · CNCF Incubating: **cert-manager***
*DevSecOps: Distroless image, non-root pod, Trivy scan gate, Govulncheck, SBOM*

Phase này 100% miễn phí, chạy hoàn toàn trên máy local. Security baseline được
áp dụng ngay từ Phase 1 (shift-left), không đợi đến Phase 3.

```bash
make prereq        # kiểm tra lần cuối
make cluster-up    # kind tạo cluster 3 node (~5 phút lần đầu)
kubectl get nodes  # phải thấy 3 node STATUS=Ready
```

`make bootstrap` cài ba thành phần theo thứ tự: **ingress-nginx** (L7 router, port 80/443 forward vào cluster), **cert-manager** *(CNCF Incubating)* (TLS tự động, local dùng self-signed, GCP đổi sang Let's Encrypt không cần sửa code), **ArgoCD** *(CNCF Graduated)* (GitOps engine, resource đã tối giản cho 8GB RAM).

```bash
make bootstrap
echo '127.0.0.1 taskr.local argocd.local' | sudo tee -a /etc/hosts

# Build, scan, SBOM, và deploy Go service
cd services/task-api && go mod tidy && govulncheck ./... && cd ../..
make build             # Docker distroless image ~20MB, non-root, load vào kind
make scan-image        # Trivy scan CVE — GATE trước khi deploy
syft task-api:local -o spdx-json=task-api-sbom.spdx.json
make deploy-task-api   # chỉ chạy nếu scan pass

# Verify security context đã được áp dụng
kubectl -n taskr get pod -l app.kubernetes.io/name=task-api \
  -o jsonpath='{.items[0].spec.securityContext}' | jq
# Phải có: runAsNonRoot:true, runAsUser:65532

# Smoke test
kubectl -n taskr get pods        # Running 1/1
make smoke-test                  # nhận JSON hợp lệ = Phase 1 xong
open http://argocd.local         # admin / $(make get-argocd-password)
```

**Security baseline đã có sau Phase 1:**
- Image dùng distroless non-root (không shell, không package manager)
- Pod chạy với `runAsNonRoot: true, runAsUser: 65532`
- Trivy scan là gate trước deploy, image có CVE HIGH/CRITICAL bị block
- Govulncheck quét Go module CVE trước build
- SBOM được sinh ra cho mọi image build (artifact để theo dõi CVE sau này)

**Lỗi thường gặp:** `ImagePullBackOff` → chạy lại `make build`. `502 Bad Gateway` → đợi 30 giây. Port 80 bị chiếm → `sudo lsof -i :80`. `make scan-image fail` → đọc CVE list, update base image hoặc dependency.

---

## Phase 2 — Observability + Security Signal
*CNCF Graduated: **Prometheus · OpenTelemetry SDK + Collector***
*Non-CNCF: Grafana · Loki · Tempo (Grafana Labs, open source)*
*DevSecOps: Audit log scrape, security dashboard, security alert*

Làm Phase 2 **trước** Phase 3: nếu security vỡ thứ gì, bạn cần Grafana để debug. OpenTelemetry *(CNCF Graduated)* đóng vai trò abstraction layer — metrics/traces từ Go service qua OTel Collector đến Prometheus và Tempo mà không lock-in vendor. Phase 2 cũng thiết lập nơi nhận security signal cho Phase 3 (Falco alert, Kyverno violation).

```bash
echo '127.0.0.1 grafana.local prometheus.local' | sudo tee -a /etc/hosts

# Merge code Phase 2 (main.go + router.go + go.mod đã thêm OTel SDK)
cd services/task-api && go mod tidy && cd ../..
make build scan-image deploy-task-api   # rebuild với OTel instrumentation + scan gate

# Cài toàn bộ observability stack (~10 phút, pull ~2GB images)
make bootstrap-observability
```

Tổng RAM thêm ~900Mi — đã tối giản cho 8GB: Prometheus 256Mi, Grafana 128Mi, Loki 128Mi, Tempo 128Mi, OTel Collector 64Mi.

```bash
open http://grafana.local        # admin / taskr-grafana-admin
# Dashboard "task-api — RED Metrics" tự load từ ConfigMap
# Dashboard "Security Overview" cũng được load (chuẩn bị cho Phase 3)
make smoke-test                  # generate traffic
# Grafana Explore → Loki → {namespace="taskr"} để xem log tập trung
# Grafana Explore → Loki → {source="kube-audit"} để xem audit log
```

**3 alert rule operational** sẵn tại `http://prometheus.local/alerts`: service down 5 phút, error rate >5%, latency p99 >500ms.

**3 alert rule security** chuẩn bị trước cho Phase 3: số admission denial bất thường, số 401/403 vượt ngưỡng, syscall execve từ container không mong đợi (Falco rule sẽ feed vào ở Phase 3).

---

## Phase 3 — Security (Defense in Depth, 4 lớp)
*CNCF Graduated: **Linkerd** (mTLS) · CNCF Incubating: **Kyverno · Falco***
*Non-CNCF: Sealed Secrets (Bitnami) · Trivy + Trivy Operator (Aqua Security)*
*WAF: ModSecurity OWASP CRS (embedded trong ingress-nginx)*

Thứ tự bên trong Phase 3 quan trọng: **Kyverno trước → NetworkPolicy → Linkerd → Falco → ModSecurity → Sealed Secrets**.

```bash
make bootstrap-security   # cài Kyverno + 7 ClusterPolicy + Falco + Sealed Secrets + Trivy Operator
make policy-check         # thử deploy pod root → phải bị Kyverno reject
```

**7 Kyverno ClusterPolicy** *(CNCF Incubating)* enforce: cấm root, bắt buộc resource requests, chỉ trusted registry, yêu cầu label chuẩn, cấm tag `latest`, `require-non-root` (chặn pod thiếu runAsNonRoot:true), `disallow-host-namespace` (chặn pod dùng hostPID/hostNetwork).

```bash
# NetworkPolicy: zero-trust cho namespace taskr
kubectl apply -f platform/security/networkpolicy/taskr-policies.yaml
make smoke-test   # ingress phải vẫn hoạt động sau default-deny-all

# Sealed Secrets: encrypt secret trước khi commit Git
kubectl create secret generic db-credentials \
  --from-literal=password=my-password --namespace taskr \
  --dry-run=client -o yaml | kubeseal --format yaml \
  > platform/security/sealed-secrets/db-credentials.yaml
git add platform/security/sealed-secrets/db-credentials.yaml  # an toàn commit

# Container scan
make scan-image   # Trivy quét CVE trong Docker image
```

**Linkerd** *(CNCF Graduated)* inject sidecar vào namespace taskr, mọi giao tiếp east-west tự động được mã hóa mTLS — không cần thay đổi code application.

**Falco** *(CNCF Incubating)* DaemonSet theo dõi syscall, alert qua Alertmanager khi có hành vi bất thường: shell spawn trong container task-api, write file ngoài /tmp, outbound connection đến IP ngoài cluster. Falco event → Loki qua FluentBit → Grafana dashboard "Security Overview".

**ModSecurity OWASP CRS** bật trong ingress-nginx (`enable-modsecurity: "true"`, paranoia level 1) chặn SQLi/XSS ở edge.

**Trivy Operator** scan toàn bộ workload cluster-wide theo CronJob hằng ngày, report ra CRD `VulnerabilityReport` xem được bằng `kubectl get vulnerabilityreports -A`.

---

## Phase 4 — PostgreSQL + GCP Deploy (IaC Security)
*CNCF Sandbox: **CloudNativePG** · Non-CNCF: Terraform · Velero*
*DevSecOps: Checkov + tfsec IaC scan, Security Command Center, CMEK encryption*

Lần đầu tốn credit GCP. **Hexagonal architecture payoff**: domain layer Go không đổi một dòng, chỉ swap adapter từ memory sang postgres.

```bash
# Cài CloudNativePG operator
kubectl apply -f https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.0.yaml
kubectl apply -f platform/security/sealed-secrets/db-credentials.yaml
kubectl apply -f deploy/task-api/overlays/gcp-demo/postgres-cluster.yaml
# CloudNativePG tự tạo: taskr-postgres-rw (primary) + taskr-postgres-ro (replica)

# === DevSecOps gate trước khi apply Terraform ===
cd infra/terraform/envs/gcp-demo
checkov -d . --quiet --compact            # gate 1: misconfig HIGH/CRITICAL → fail
tfsec . --minimum-severity HIGH           # gate 2: second opinion
# Chỉ chạy apply nếu cả 2 đều pass

# GCP infrastructure với Terraform
find infra/terraform -name "*.tf" | xargs sed -i "s/YOUR_PROJECT_ID/taskr-dev-428391/g"
gsutil mb gs://taskr-dev-428391-tfstate
terraform init && terraform apply
cd ../../../..
```

```bash
make gcp-push GCP_PROJECT=taskr-dev-428391   # build + scan + push lên Artifact Registry
# Artifact Registry tự scan CVE on-push (built-in GCP feature)

# Lấy LB IP: kubectl -n ingress-nginx get svc ingress-nginx-controller
# Sửa kustomization.yaml: taskr.REPLACE_WITH_LB_IP.nip.io
make gcp-deploy
curl http://taskr.34.142.123.45.nip.io/api/v1/tasks

# Kiểm tra Security Command Center finding
gcloud scc findings list --organization=YOUR_ORG --filter='state="ACTIVE"'

# SAU KHI DEMO — BẮT BUỘC
make gcp-down GCP_PROJECT=taskr-dev-428391   # GKE idle ~$0.20/giờ
```

**Security feature đã bật sẵn trong Terraform module GKE Autopilot:**
- Workload Identity (pod dùng GCP IAM, không dùng service account key)
- Private cluster (node không có public IP)
- Shielded GKE nodes (secure boot + integrity monitoring)
- Encryption at rest cho PostgreSQL với CMEK
- Artifact Registry vulnerability scanning on push
- Cloud Audit Log cho GKE, IAM, Artifact Registry

---

## Phase 5 — Canary Deployment + Full DevSecOps Pipeline
*CNCF Graduated: **Argo Rollouts** · CNCF Incubating: **KEDA***
*DevSecOps: Semgrep SAST, cosign keyless signing, Binary Authorization, OIDC WIF*

Argo Rollouts *(CNCF Graduated)* thay RollingUpdate bằng canary thông minh: Prometheus + Falco làm gate tự động quyết định promote hay rollback.

```bash
make bootstrap-rollouts
kubectl -n taskr delete deployment task-api
kubectl apply -f platform/rollouts/task-api-rollout.yaml
# Canary flow: 10% → 5 phút → Prometheus + Falco check → 25% → 50% → 100%
# Error rate >5% HOẶC Falco HIGH event → auto-rollback
```

**GitHub Actions CI/CD Pipeline — 4 stage DevSecOps:**

```
Stage 1 Pre-flight: Gitleaks + Checkov + tfsec → fail = block PR
Stage 2 Quality:    go vet + golangci-lint + go test + Semgrep + Govulncheck
Stage 3 Build:      Multi-stage Docker → Trivy scan → Syft SBOM → Cosign sign
Stage 4 Deploy:     GCP OIDC (WIF) → bump tag → ArgoCD sync → Binary Auth verify
```

Thêm secrets vào GitHub repo (Settings → Secrets and variables → Actions):
`GCP_PROJECT_ID`, `GCP_WIF_PROVIDER` (full resource name từ Phase 0),
`GCP_SERVICE_ACCOUNT` (`github-deployer@...`). **Không** thêm
`GOOGLE_CREDENTIALS` hay service account key — OIDC thay thế toàn bộ.

Bật Binary Authorization policy trên GKE chỉ cho phép image đã sign:

```bash
gcloud container binauthz policy import policy-strict.yaml
# Image không sign sẽ bị reject ở admission, không pod nào chạy được
```

```bash
# Demo auto-rollback
kubectl argo rollouts set image task-api task-api=task-api:buggy -n taskr
kubectl argo rollouts get rollout task-api -n taskr -w
# Quan sát: hệ thống tự rollback sau ~10 phút, không downtime
```

---

## Phase 6 — FinOps & Vận hành + Security Chaos
*CNCF Incubating: **Chaos Mesh** · CNCF Sandbox: **OpenCost***
*DevSecOps: Security chaos experiment, audit log review, quarterly access review*

```bash
kubectl apply -f platform/finops/opencost.yaml   # ResourceQuota + LimitRange + OpenCost
make cost-report    # cost allocation per namespace trong 24h
```

**Chaos Mesh** *(CNCF Incubating)* verify HA và security không chỉ trên giấy:

```bash
# 3 operational chaos experiment
kubectl apply -f platform/finops/chaos-experiments.yaml
# pod-kill · network-delay · cpu-stress

# 3 security chaos experiment (DevSecOps)
kubectl apply -f platform/finops/security-chaos.yaml
# kyverno-kill (verify pod root vẫn bị block ở API server level)
# falco-network-disrupt (verify alert retry không mất event)
# policy-bypass-attempt (verify hostNetwork=true bị reject + audit log)

# Song song chạy: for i in {1..60}; do curl -s http://localhost/api/v1/tasks; sleep 5; done
# Kết quả: pod tự heal, HTTP vẫn 200 xuyên suốt, không có pod root nào tồn tại
kubectl delete -f platform/finops/chaos-experiments.yaml
kubectl delete -f platform/finops/security-chaos.yaml
```

**Audit review hằng tuần:** chạy `scripts/audit-review.sh` extract từ Cloud Audit
Log các sự kiện bất thường trong 7 ngày qua (IAM policy change, service account
key create, failed gcloud command từ external IP), gửi report email.

**Quarterly access review** checklist trong runbook: list tất cả service account,
role binding, GitHub collaborator. Mỗi cái phải có owner xác nhận còn cần thiết.

Đọc `docs/runbook.md` **trước khi** có incident: 8 scenario (5 operational +
3 security) với triệu chứng → chẩn đoán → xử lý step-by-step.

---

## Tóm tắt · Checklist hoàn thành

```
Phase 0  ✓  gcloud auth + budget alert + Workload Identity Federation + pre-commit
Phase 1  ✓  make smoke-test → JSON hợp lệ + Trivy scan pass + SBOM sinh ra + ArgoCD UI
Phase 2  ✓  Grafana RED dashboard có data + Loki có log + Security Overview ready
Phase 3  ✓  Kyverno reject pod root + Falco DaemonSet running + mTLS Linkerd + ModSec ON
Phase 4  ✓  Checkov + tfsec pass + curl taskr.<LB_IP>.nip.io/api/v1/tasks + make gcp-down
Phase 5  ✓  CI 4 stage pass + cosign sign image + Binary Auth verify + auto-rollback OK
Phase 6  ✓  operational chaos pass + security chaos pass + audit report sinh ra
```

> **Nguyên tắc chi phí:** Phase 1–3 = $0 (local). Phase 4–6 = ~$0.20/giờ GCP.
> Với $300 credit, bạn có hơn 200 giờ demo session nếu luôn nhớ `make gcp-down`.
>
> **Nguyên tắc DevSecOps:** mỗi check bảo mật chạy ở giai đoạn sớm nhất có thể.
> Secret scan ở pre-commit, SAST ở PR, IaC scan trước terraform apply,
> image scan trước push, signature verify trước pull. Không bypass, không skip.
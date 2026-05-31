# Phase 0 — GCP Onboarding

Tài liệu này hướng dẫn bạn từng bước thiết lập tài khoản GCP và cài đặt các công cụ
cần thiết. Bạn chỉ cần làm phần này *một lần duy nhất*. Sau khi hoàn thành, mọi
script tự động trong thư mục `scripts/` sẽ chạy được.

---

## Bước 1 — Tạo tài khoản GCP và kích hoạt $300 credit

Mở trình duyệt và truy cập `https://cloud.google.com/free`. Nhấn nút **Get started
for free** ở góc trên bên phải. Bạn sẽ được yêu cầu đăng nhập bằng Google account
(nên dùng email riêng cho dự án, không dùng email công ty nếu bạn muốn tách bạch).

Trong bước xác thực, Google sẽ yêu cầu:

- Một thẻ tín dụng hoặc thẻ ghi nợ còn hiệu lực. Đây chỉ để xác minh danh tính,
  không bị tính phí trừ khi bạn chủ động nâng cấp sang paid account.
- Một số điện thoại để nhận mã OTP.
- Thông tin địa chỉ. Chọn **Vietnam** và điền địa chỉ thật.

Sau khi hoàn tất, bạn sẽ được chuyển vào GCP Console và nhận $300 credit có hiệu
lực trong 90 ngày. Ngay lập tức, hãy ghi lại *ngày hết hạn credit* ở một nơi dễ
nhìn thấy — ví dụ pin vào Notion hoặc dán sticky note trên màn hình. Đây là
deadline quan trọng cho toàn bộ dự án.

## Bước 2 — Tạo project đầu tiên

GCP tổ chức tài nguyên theo **project**. Mỗi project là một sandbox riêng biệt có
billing, IAM, và resource quota riêng. Một tài khoản có thể có nhiều project.

Trong Console, nhấn vào dropdown project ở thanh trên (mặc định là "My First
Project") → **New Project**. Đặt tên là `taskr-dev` (hoặc tên bạn thích). Ghi lại
**Project ID** được Google sinh tự động — nó sẽ có dạng `taskr-dev-123456`. Project
ID là *định danh toàn cầu duy nhất* và bạn không thể đổi sau khi tạo, nên hãy
chọn tên dễ nhớ.

Tôi khuyến nghị tạo luôn hai project: `taskr-dev` để thử nghiệm hàng ngày, và
`taskr-demo` để khi demo thật cho người khác xem. Tách project giúp bạn không
accidentally xóa nhầm tài nguyên demo khi đang nghịch dev.

## Bước 3 — Cài đặt công cụ dòng lệnh

Bạn cần cài các công cụ trên máy local. Đoạn dưới đây là cho macOS với Homebrew.
Nếu bạn dùng Linux hoặc Windows WSL, chạy `scripts/00-prerequisites.sh` để được
hướng dẫn đúng cho hệ điều hành của bạn.

```bash
# === Core tools ===
# Google Cloud SDK — để giao tiếp với GCP
brew install --cask google-cloud-sdk

# kubectl — để giao tiếp với bất kỳ Kubernetes cluster nào
brew install kubectl

# kind — để chạy Kubernetes trong Docker trên máy local
brew install kind

# Helm — để cài đặt các platform component (cert-manager, ingress-nginx, ...)
brew install helm

# Docker Desktop — cần thiết vì kind chạy Kubernetes bên trong Docker
# Tải tại https://www.docker.com/products/docker-desktop

# Go 1.22+ — để compile service
brew install go

# === DevSecOps tools (cài luôn từ Phase 0 để shift-left security) ===
# Trivy — quét CVE trong filesystem, Dockerfile, container image, IaC
brew install trivy

# Gitleaks — phát hiện secret bị commit vào Git
brew install gitleaks

# pre-commit framework — chạy security check trước mỗi commit
brew install pre-commit

# Checkov — quét misconfiguration trong Terraform, Kubernetes manifest
brew install checkov

# kubeseal — encrypt secret cho Sealed Secrets (dùng từ Phase 3)
brew install kubeseal

# cosign — ký và verify container image (dùng từ Phase 5)
brew install cosign

# syft — generate SBOM (Software Bill of Materials)
brew install syft

# govulncheck — quét CVE trong Go dependency
go install golang.org/x/vuln/cmd/govulncheck@latest
```

Sau khi cài xong, kiểm tra từng tool:

```bash
# Core
gcloud --version     # Nên thấy Google Cloud SDK 450.x.x trở lên
kubectl version --client
kind --version
helm version
docker info          # Đảm bảo Docker daemon đang chạy
go version           # Nên thấy 1.22 trở lên

# DevSecOps
trivy --version
gitleaks version
pre-commit --version
checkov --version
kubeseal --version
cosign version
syft version
govulncheck -version
```

Nếu bất kỳ lệnh nào báo lỗi `command not found`, mở shell mới (`source ~/.zshrc`
hoặc khởi động lại terminal) vì PATH chưa được refresh.

## Bước 4 — Đăng nhập gcloud

Chạy lệnh sau để liên kết gcloud CLI với tài khoản GCP của bạn:

```bash
gcloud auth login
```

Trình duyệt sẽ mở ra, đăng nhập và cho phép truy cập. Sau đó:

```bash
gcloud config set project taskr-dev    # thay bằng Project ID thật của bạn
gcloud auth application-default login  # cho Terraform dùng sau này
```

Lệnh cuối tạo ra file credentials tại `~/.config/gcloud/application_default_credentials.json`.
File này là *bí mật*, tuyệt đối không commit lên Git. Tôi đã thêm
`.config/` vào `.gitignore` trong repo để phòng ngừa.

## Bước 5 — Kích hoạt các API cần thiết

GCP mặc định khóa tất cả API, bạn phải enable từng cái một. Chạy đoạn này để
enable tất cả API chúng ta sẽ cần:

```bash
gcloud services enable \
  container.googleapis.com \
  compute.googleapis.com \
  artifactregistry.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iam.googleapis.com \
  dns.googleapis.com \
  monitoring.googleapis.com \
  logging.googleapis.com
```

Quá trình này mất khoảng 2-3 phút. Một số API phụ thuộc lẫn nhau nên Google sẽ
enable theo thứ tự đúng.

## Bước 6 — Tạo service account cho Terraform với least privilege (DevSecOps)

Phần này bạn *chưa cần làm ngay*. Nó chỉ cần thiết khi bạn đã làm xong Phase 1
local và muốn triển khai lên GCP để demo. Khi đến lúc đó, quay lại đây.

**Nguyên tắc DevSecOps áp dụng cho bước này:** least privilege (chỉ cấp quyền
tối thiểu cần thiết), không tạo long-lived service account key cho CI/CD (dùng
Workload Identity Federation thay thế), và tách biệt service account giữa
Terraform admin (chạy local) và CI/CD pipeline (chạy trên GitHub Actions).

### 6a. Service account cho Terraform admin (chạy local)

```bash
export PROJECT_ID=$(gcloud config get-value project)
export SA_NAME=terraform-admin

gcloud iam service-accounts create $SA_NAME \
  --display-name="Terraform Admin SA"

# Thay vì roles/editor (quá rộng), cấp các role cụ thể theo phạm vi project này
for role in \
  roles/compute.admin \
  roles/container.admin \
  roles/artifactregistry.admin \
  roles/iam.serviceAccountAdmin \
  roles/iam.serviceAccountUser \
  roles/resourcemanager.projectIamAdmin \
  roles/storage.admin \
  roles/dns.admin \
  roles/monitoring.admin \
  roles/logging.admin; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="$role" \
    --condition=None
done

# Key được tạo tạm thời và KHÔNG commit vào Git (đã có trong .gitignore)
gcloud iam service-accounts keys create ~/.config/gcloud/terraform-key.json \
  --iam-account=$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com
```

### 6b. Workload Identity Federation cho GitHub Actions (KHÔNG dùng key)

CI/CD pipeline ở Phase 5 sẽ deploy lên GCP. Nguyên tắc DevSecOps: **không bao giờ
lưu service account key vào GitHub Secrets**. Thay vào đó dùng OIDC federation
giữa GitHub và GCP để pipeline lấy short-lived token (TTL 15 phút).

```bash
# Tạo Workload Identity Pool
gcloud iam workload-identity-pools create github-pool \
  --location=global \
  --display-name="GitHub Actions Pool"

# Tạo OIDC provider trỏ về GitHub
gcloud iam workload-identity-pools providers create-oidc github-provider \
  --location=global \
  --workload-identity-pool=github-pool \
  --display-name="GitHub OIDC Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" \
  --attribute-condition="assertion.repository_owner == 'YOUR_GITHUB_ORG'" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Tạo service account riêng cho CI/CD (tách biệt với terraform-admin)
gcloud iam service-accounts create github-deployer \
  --display-name="GitHub Actions Deployer"

# Chỉ cấp các role tối thiểu cần cho deploy
for role in \
  roles/container.developer \
  roles/artifactregistry.writer \
  roles/iam.workloadIdentityUser; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:github-deployer@$PROJECT_ID.iam.gserviceaccount.com" \
    --role="$role" \
    --condition=None
done

# Bind GitHub repo cụ thể với service account (chỉ repo này mới impersonate được)
export REPO="YOUR_GITHUB_ORG/YOUR_REPO_NAME"
gcloud iam service-accounts add-iam-policy-binding \
  github-deployer@$PROJECT_ID.iam.gserviceaccount.com \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/projects/$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')/locations/global/workloadIdentityPools/github-pool/attribute.repository/$REPO"
```

Sau khi setup xong, lưu ba giá trị này để Phase 5 dùng làm GitHub Secret:
`GCP_PROJECT_ID`, `GCP_WIF_PROVIDER` (full resource name của provider),
`GCP_SERVICE_ACCOUNT` (email của `github-deployer`).

### 6c. Organization Policy chặn tạo service account key (khuyến nghị)

Nếu bạn có quyền Organization Admin, bật policy này để chặn vĩnh viễn việc tạo
key (chống nhân viên hoặc agent vô tình tạo và leak):

```bash
gcloud resource-manager org-policies enable-enforce \
  iam.disableServiceAccountKeyCreation \
  --project=$PROJECT_ID
```

## Bước 7 — Thiết lập budget alert

Đây là bước *bắt buộc* bạn phải làm trước khi tạo bất kỳ tài nguyên tốn phí nào.
Budget alert sẽ gửi email cảnh báo khi chi phí chạm ngưỡng, giúp bạn tránh
thức dậy với bill $300.

Truy cập `https://console.cloud.google.com/billing` → chọn billing account →
**Budgets & alerts** → **Create budget**. Cấu hình:

- Tên: `taskr-monthly-budget`
- Amount: $50 per month (giới hạn cứng để bạn còn dư credit cho 3 tháng)
- Alert ở các ngưỡng 50%, 90%, 100% của budget
- Email alert gửi tới địa chỉ bạn check hàng ngày

Nếu chi phí vượt 100% (tức $50/tháng), bạn sẽ nhận email ngay. Budget alert
*không tự động tắt tài nguyên*, chỉ cảnh báo. Việc tắt là trách nhiệm của bạn.

## Bước 8 — Thiết lập pre-commit hook (DevSecOps shift-left)

Pre-commit hook chạy security check trước khi commit được tạo ra, chặn từ
trong trứng các lỗi như secret bị paste vào code, file bí mật vô tình add.
Đây là lớp phòng thủ rẻ nhất nhưng hiệu quả nhất trong DevSecOps.

Tạo file `.pre-commit-config.yaml` ở root của repo (nếu chưa có):

```yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.6.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
      - id: check-added-large-files
        args: [--maxkb=500]
      - id: detect-private-key

  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.18.4
    hooks:
      - id: gitleaks

  - repo: https://github.com/bridgecrewio/checkov
    rev: 3.2.250
    hooks:
      - id: checkov
        args: [-d, infra/terraform, --quiet, --compact]
```

Kích hoạt:

```bash
pre-commit install
pre-commit run --all-files   # chạy thử một lần trên toàn repo
```

Từ giờ mỗi `git commit` sẽ tự động chạy các check trên. Nếu có lỗi, commit
bị block. Đây là behavior mong muốn: bạn phải fix trước khi code đến CI.

## Bước 9 — Xác nhận sẵn sàng

Chạy script kiểm tra tổng hợp:

```bash
bash scripts/00-prerequisites.sh
```

Nếu tất cả dấu `✓` xuất hiện, bạn đã sẵn sàng chuyển sang **Phase 1 — Local
cluster setup**. Đọc tiếp tại `docs/01-local-dev.md`.

---

## Những sai lầm thường gặp

Tôi đã chứng kiến nhiều người mới mắc phải các lỗi dưới đây, liệt kê để bạn
tránh:

**Quên tắt tài nguyên sau khi dùng xong.** Cloud tính tiền theo giờ, bất kể bạn
có đang dùng hay không. Một cluster GKE quên tắt cuối tuần có thể ngốn $20-30.
Luôn chạy `terraform destroy` khi xong buổi làm việc.

**Lẫn lộn project ID và project name.** Project name có thể trùng nhau và đổi
được, project ID là duy nhất và cố định. Mọi script và CLI dùng project ID.

**Không theo dõi credit usage.** Kiểm tra `https://console.cloud.google.com/billing`
ít nhất mỗi tuần một lần. GCP có dashboard hiển thị rõ bạn đã dùng bao nhiêu
và còn lại bao nhiêu.

**Dùng region quá xa.** Chọn region asia-southeast1 (Jakarta) hoặc asia-east1
(Taiwan) cho Việt Nam. Tránh us-central1 trừ khi cần dùng service chỉ có ở đó,
vì latency từ Hà Nội tới US là 200ms+, rất khó chịu khi develop.

**Không bật 2FA cho Google account.** Tài khoản có $300 credit là mục tiêu
hấp dẫn cho hacker. Bật 2FA ngay tại `https://myaccount.google.com/security`.
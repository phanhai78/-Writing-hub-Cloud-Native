#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 00-prerequisites.sh
# -----------------------------------------------------------------------------
# Kiểm tra toàn bộ công cụ cần thiết trên máy local. Script này KHÔNG cài đặt
# gì cả, chỉ kiểm tra và gợi ý. Lý do: người dùng nên chủ động biết mình đang
# cài gì lên máy, không để script tự ý cài package.
#
# Usage:
#   bash scripts/00-prerequisites.sh
# -----------------------------------------------------------------------------

set -euo pipefail

# Màu sắc cho output dễ nhìn. Chỉ bật màu khi output là terminal thật,
# nếu redirect ra file thì bỏ escape code để log sạch.
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

# Biến đếm lỗi để báo tổng kết cuối cùng.
# Nếu có bất kỳ tool nào thiếu, script exit với mã lỗi để CI/automation
# có thể phát hiện được.
ERRORS=0
WARNINGS=0

# Hàm tiện ích để in thông báo. Cách viết này chuẩn hóa format
# và giúp đoạn chính của script dễ đọc hơn.
ok()    { printf "${GREEN}✓${RESET}  %s\n" "$1"; }
fail()  { printf "${RED}✗${RESET}  %s\n" "$1"; ERRORS=$((ERRORS+1)); }
warn()  { printf "${YELLOW}⚠${RESET}  %s\n" "$1"; WARNINGS=$((WARNINGS+1)); }
info()  { printf "${BLUE}ℹ${RESET}  %s\n" "$1"; }
header(){ printf "\n${BOLD}%s${RESET}\n" "$1"; }

# Phát hiện OS để đưa ra hướng dẫn cài đặt phù hợp.
# Ba trường hợp: macOS (Darwin), Linux, và WSL/khác.
detect_os() {
  case "$(uname -s)" in
    Darwin*) echo "macos" ;;
    Linux*)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    *) echo "unknown" ;;
  esac
}

OS=$(detect_os)

# Hàm kiểm tra command tồn tại và đủ version tối thiểu.
# Tham số: tên command, version tối thiểu, lệnh lấy version, lệnh cài
check_tool() {
  local name=$1
  local min_version=$2
  local version_cmd=$3
  local install_hint=$4

  if ! command -v "$name" &> /dev/null; then
    fail "$name: chưa cài đặt"
    info "   Cài bằng: $install_hint"
    return
  fi

  # Lấy version. 2>/dev/null để nuốt stderr của các tool gây noise.
  local version
  version=$(eval "$version_cmd" 2>/dev/null | head -1 || echo "unknown")
  ok "$name: $version"
}

# -----------------------------------------------------------------------------
# Bắt đầu kiểm tra
# -----------------------------------------------------------------------------

printf "${BOLD}Cloud Native Taskr — Prerequisites Check${RESET}\n"
printf "OS được phát hiện: ${BOLD}%s${RESET}\n" "$OS"

header "▸ Công cụ cần thiết cho Phase 1 (local)"

# Docker: nền tảng cho kind. Không có Docker thì không có Kubernetes local.
if ! command -v docker &> /dev/null; then
  fail "docker: chưa cài đặt"
  case "$OS" in
    macos) info "   Cài bằng: Docker Desktop tại https://www.docker.com/products/docker-desktop" ;;
    linux) info "   Cài bằng: https://docs.docker.com/engine/install/" ;;
    wsl)   info "   Cài bằng: Docker Desktop for Windows với WSL2 backend" ;;
  esac
else
  # Kiểm tra daemon có chạy không. Nhiều user cài Docker rồi quên bật Desktop app.
  if docker info &> /dev/null; then
    ok "docker: $(docker --version | awk '{print $3}' | tr -d ',') (daemon đang chạy)"
  else
    fail "docker: đã cài nhưng daemon không chạy"
    info "   Mở Docker Desktop hoặc chạy: sudo systemctl start docker"
  fi
fi

# kubectl: giao tiếp với mọi Kubernetes cluster
case "$OS" in
  macos) KUBECTL_HINT="brew install kubectl" ;;
  linux) KUBECTL_HINT="https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/" ;;
  wsl)   KUBECTL_HINT="https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/" ;;
esac
check_tool "kubectl" "1.28" "kubectl version --client --output=json 2>/dev/null | grep -oP '\"gitVersion\":\\s*\"\\K[^\"]+' | head -1" "$KUBECTL_HINT"

# kind: tạo Kubernetes cluster trong Docker
case "$OS" in
  macos) KIND_HINT="brew install kind" ;;
  *)     KIND_HINT="go install sigs.k8s.io/kind@latest  (hoặc dùng binary từ GitHub releases)" ;;
esac
check_tool "kind" "0.20" "kind --version | awk '{print \$3}'" "$KIND_HINT"

# Helm: package manager cho Kubernetes
case "$OS" in
  macos) HELM_HINT="brew install helm" ;;
  *)     HELM_HINT="curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash" ;;
esac
check_tool "helm" "3.12" "helm version --short" "$HELM_HINT"

# Go: compile task-api
case "$OS" in
  macos) GO_HINT="brew install go" ;;
  *)     GO_HINT="https://go.dev/doc/install" ;;
esac
check_tool "go" "1.22" "go version | awk '{print \$3}'" "$GO_HINT"

header "▸ Công cụ cho Phase 2+ (GCP) — có thể bỏ qua bây giờ"

# gcloud: chỉ cần khi deploy lên GCP
if ! command -v gcloud &> /dev/null; then
  warn "gcloud: chưa cài đặt (không bắt buộc cho Phase 1)"
  case "$OS" in
    macos) info "   Cài bằng: brew install --cask google-cloud-sdk" ;;
    *)     info "   Cài bằng: https://cloud.google.com/sdk/docs/install" ;;
  esac
else
  ok "gcloud: $(gcloud --version 2>/dev/null | head -1 | awk '{print $NF}')"

  # Kiểm tra đã login chưa. Không bắt buộc nhưng tốt để thông báo.
  if gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | grep -q .; then
    ok "   đã đăng nhập gcloud với tài khoản: $(gcloud config get-value account 2>/dev/null)"
  else
    warn "   chưa đăng nhập gcloud. Chạy: gcloud auth login"
  fi
fi

# Terraform: chỉ cần khi deploy hạ tầng GCP
if ! command -v terraform &> /dev/null; then
  warn "terraform: chưa cài đặt (không bắt buộc cho Phase 1)"
  case "$OS" in
    macos) info "   Cài bằng: brew install terraform" ;;
    *)     info "   Cài bằng: https://developer.hashicorp.com/terraform/install" ;;
  esac
else
  ok "terraform: $(terraform version | head -1 | awk '{print $2}')"
fi

header "▸ Kiểm tra tài nguyên hệ thống"

# Docker Desktop trên macOS/Windows có giới hạn RAM mặc định. Cluster Kubernetes
# với đầy đủ platform component cần ít nhất 6GB để chạy thoải mái.
# Cách kiểm tra phụ thuộc OS nên chỉ cảnh báo chung chung.
if command -v docker &> /dev/null && docker info &> /dev/null; then
  DOCKER_MEM=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo 0)
  DOCKER_MEM_GB=$((DOCKER_MEM / 1024 / 1024 / 1024))

  if [ "$DOCKER_MEM_GB" -ge 6 ]; then
    ok "Docker RAM: ${DOCKER_MEM_GB}GB (đủ cho cluster + platform)"
  elif [ "$DOCKER_MEM_GB" -ge 4 ]; then
    warn "Docker RAM: ${DOCKER_MEM_GB}GB (có thể chạy nhưng chật)"
    info "   Gợi ý: tăng lên 6GB trong Docker Desktop Settings → Resources"
  else
    fail "Docker RAM: ${DOCKER_MEM_GB}GB (quá thấp, cluster sẽ OOM)"
    info "   Tăng lên ít nhất 6GB trong Docker Desktop Settings → Resources"
  fi
fi

# -----------------------------------------------------------------------------
# Tổng kết
# -----------------------------------------------------------------------------

header "▸ Tổng kết"

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
  printf "${GREEN}${BOLD}Tuyệt vời!${RESET} Môi trường của bạn đã sẵn sàng. Chạy tiếp:\n"
  printf "  ${BOLD}bash scripts/01-kind-up.sh${RESET}\n"
  exit 0
elif [ "$ERRORS" -eq 0 ]; then
  printf "${YELLOW}${BOLD}Sẵn sàng cho Phase 1${RESET} với %d cảnh báo.\n" "$WARNINGS"
  printf "Các cảnh báo trên là về công cụ Phase 2+. Bạn có thể bỏ qua cho đến khi\n"
  printf "sẵn sàng deploy lên GCP. Chạy tiếp:\n"
  printf "  ${BOLD}bash scripts/01-kind-up.sh${RESET}\n"
  exit 0
else
  printf "${RED}${BOLD}Cần xử lý %d lỗi${RESET} trước khi tiếp tục.\n" "$ERRORS"
  printf "Cài đặt các công cụ còn thiếu theo gợi ý ở trên, rồi chạy lại script này.\n"
  exit 1
fi

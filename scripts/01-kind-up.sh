#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 01-kind-up.sh — Tạo local Kubernetes cluster bằng kind
# -----------------------------------------------------------------------------
# Script này là idempotent: chạy nhiều lần không gây lỗi. Nếu cluster đã tồn tại,
# script sẽ hỏi bạn có muốn xóa và tạo lại không thay vì báo lỗi cứng đầu.
#
# Lý do chọn approach này: trong quá trình học, bạn sẽ thường xuyên muốn reset
# cluster về trạng thái sạch. Một script "smart" tiết kiệm rất nhiều thời gian.
# -----------------------------------------------------------------------------

set -euo pipefail

# Đường dẫn tuyệt đối tới thư mục script, bất kể script được gọi từ đâu.
# Đây là idiom chuẩn để script dùng file tương đối luôn đúng path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

CLUSTER_NAME="taskr"
CLUSTER_CONFIG="$ROOT_DIR/infra/kind/cluster.yaml"

# Màu sắc output — dùng lại pattern từ script 00.
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

log()   { printf "${BLUE}▸${RESET} %s\n" "$1"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}⚠${RESET} %s\n" "$1"; }
fail()  { printf "${RED}✗${RESET} %s\n" "$1"; exit 1; }

# Kiểm tra prerequisites nhanh. Không duplicate logic với script 00,
# chỉ check đủ để script này chạy được.
command -v kind &> /dev/null || fail "kind chưa cài. Chạy scripts/00-prerequisites.sh để xem hướng dẫn."
command -v kubectl &> /dev/null || fail "kubectl chưa cài."
docker info &> /dev/null || fail "Docker daemon không chạy. Mở Docker Desktop hoặc khởi động docker service."

[[ -f "$CLUSTER_CONFIG" ]] || fail "Không tìm thấy file config tại $CLUSTER_CONFIG"

# ─── Xử lý trường hợp cluster đã tồn tại ───
# Kind lưu danh sách cluster trong Docker; check bằng `kind get clusters`.
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' đã tồn tại."

  # Nếu script chạy trong terminal tương tác, hỏi xác nhận.
  # Nếu chạy trong CI (không có TTY), mặc định skip để không treo pipeline.
  if [[ -t 0 ]]; then
    read -rp "Xóa và tạo lại? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
      log "Xóa cluster cũ..."
      kind delete cluster --name "$CLUSTER_NAME"
    else
      log "Giữ nguyên cluster hiện tại. Kiểm tra với: kubectl get nodes"
      exit 0
    fi
  else
    warn "Non-interactive shell, giữ nguyên cluster."
    exit 0
  fi
fi

# ─── Tạo cluster mới ───
log "Tạo cluster '${CLUSTER_NAME}' (mất khoảng 1-2 phút)..."
log "Kind sẽ pull image kindest/node nếu chưa có (~350MB, chỉ lần đầu)."

# --wait 60s đảm bảo script chỉ return sau khi cluster thực sự ready,
# không phải chỉ khi các container Docker đã start.
# Nếu quá 60s chưa ready, thường là do Docker chưa đủ RAM.
kind create cluster \
  --name "$CLUSTER_NAME" \
  --config "$CLUSTER_CONFIG" \
  --wait 60s

# ─── Verify cluster sức khỏe ───
# kubectl context đã tự động switch sang cluster mới bởi kind.
# Check nodes đều Ready.
log "Kiểm tra cluster..."
if ! kubectl get nodes &> /dev/null; then
  fail "Không kết nối được tới cluster. Check 'kubectl config current-context'"
fi

# Đếm node Ready. Phải đủ 3 (1 CP + 2 worker).
READY_NODES=$(kubectl get nodes --no-headers | grep -c "Ready" || true)
TOTAL_NODES=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')

if [[ "$READY_NODES" -eq "$TOTAL_NODES" ]] && [[ "$TOTAL_NODES" -ge 1 ]]; then
  ok "Cluster ready với $READY_NODES/$TOTAL_NODES nodes"
else
  warn "$READY_NODES/$TOTAL_NODES nodes ready. Đợi thêm hoặc check 'kubectl describe nodes'"
fi

# ─── Hiển thị trạng thái ───
echo
kubectl get nodes -o wide
echo

ok "Cluster '${CLUSTER_NAME}' đã sẵn sàng"
printf "   Context: ${BOLD}kind-${CLUSTER_NAME}${RESET}\n"
printf "   Kubeconfig: ${BOLD}~/.kube/config${RESET} (đã tự động cập nhật)\n"
echo
printf "Bước tiếp theo: ${BOLD}bash scripts/02-bootstrap.sh${RESET}\n"
printf "   (cài ArgoCD + ingress-nginx + cert-manager)\n"

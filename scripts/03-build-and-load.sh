#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 03-build-and-load.sh — Build image task-api và load vào kind cluster
# -----------------------------------------------------------------------------
# Tại sao phải "load"? kind cluster chạy trong Docker nhưng có daemon Docker
# riêng bên trong node container. Image build trên host KHÔNG tự có trong kind.
# Lệnh `kind load docker-image` copy image từ host daemon vào kind node.
#
# Alternative: push image lên registry rồi pull. Chậm và cần internet.
# `kind load` là cách nhanh nhất cho local dev loop.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SERVICE_DIR="$ROOT_DIR/services/task-api"
IMAGE_NAME="task-api"
IMAGE_TAG="${IMAGE_TAG:-local-dev}"    # Override qua env nếu muốn tag khác
CLUSTER_NAME="taskr"

# Lấy git commit để inject vào binary — traceability từ binary về source code.
# || echo "none" phòng khi script chạy ngoài git repo.
GIT_COMMIT=$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "none")

# Màu sắc quen thuộc
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
  RED='\033[0;31m'
else
  GREEN=''; BLUE=''; BOLD=''; RESET=''; RED=''
fi

log() { printf "${BLUE}▸${RESET} %s\n" "$1"; }
ok()  { printf "${GREEN}✓${RESET} %s\n" "$1"; }
fail(){ printf "${RED}✗${RESET} %s\n" "$1"; exit 1; }

# ─── Prechecks ───
docker info &>/dev/null || fail "Docker daemon không chạy"
kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" \
  || fail "Kind cluster '${CLUSTER_NAME}' chưa tồn tại. Chạy scripts/01-kind-up.sh trước."

# ─── Build ───
log "Build image ${IMAGE_NAME}:${IMAGE_TAG} (commit=${GIT_COMMIT})"

# --load flag cho docker buildx đảm bảo image nằm trong local daemon
# (không push lên registry). Default builder buildx đã load=true nhưng
# tường minh cho rõ ý.
docker build \
  --file "$SERVICE_DIR/Dockerfile" \
  --tag "${IMAGE_NAME}:${IMAGE_TAG}" \
  --build-arg "VERSION=${IMAGE_TAG}" \
  --build-arg "COMMIT=${GIT_COMMIT}" \
  "$SERVICE_DIR"

ok "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"

# Hiển thị size để thấy distroless hiệu quả
IMAGE_SIZE=$(docker image inspect "${IMAGE_NAME}:${IMAGE_TAG}" --format '{{.Size}}' \
  | awk '{printf "%.1f MB", $1/1024/1024}')
log "Image size: ${IMAGE_SIZE}"

# ─── Load vào kind ───
log "Load image vào kind cluster '${CLUSTER_NAME}'..."

kind load docker-image "${IMAGE_NAME}:${IMAGE_TAG}" --name "${CLUSTER_NAME}"

ok "Image đã sẵn sàng trong cluster"

# ─── Verify image có trong node ───
# Lệnh này liệt kê image trong node control-plane — hữu ích để debug
# nếu pod vẫn báo ImagePullBackOff.
log "Verify image trong node:"
docker exec "${CLUSTER_NAME}-control-plane" crictl images 2>/dev/null \
  | grep -E "^(IMAGE|docker.io/library/${IMAGE_NAME})" \
  || log "(không tìm thấy — nhưng kind load báo success nên có thể ignore)"

echo
ok "Hoàn tất. Tiếp theo: ${BOLD}make deploy-task-api${RESET} hoặc:"
printf "   ${BOLD}kubectl apply -k deploy/task-api/overlays/local${RESET}\n"

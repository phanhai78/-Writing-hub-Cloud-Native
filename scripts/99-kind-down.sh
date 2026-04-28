#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 99-kind-down.sh — Xóa kind cluster hoàn toàn
# -----------------------------------------------------------------------------
# Dùng khi:
#   - Muốn reset về trạng thái sạch để test từ đầu
#   - Giải phóng RAM/CPU khi không làm việc
#   - Fix vấn đề khó debug bằng cách "nuke and restart"
#
# Không xóa Docker images đã build — lần sau `kind load` sẽ nhanh hơn.
# -----------------------------------------------------------------------------

set -euo pipefail

CLUSTER_NAME="taskr"

if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

if ! kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  printf "${YELLOW}Cluster '${CLUSTER_NAME}' không tồn tại. Không cần xóa.${RESET}\n"
  exit 0
fi

# Xác nhận trước khi xóa — an toàn cơ bản
if [[ -t 0 ]]; then
  printf "Xóa cluster ${BOLD}${CLUSTER_NAME}${RESET} và mọi dữ liệu? [y/N] "
  read -r confirm
  [[ "$confirm" =~ ^[Yy]$ ]] || { echo "Hủy."; exit 0; }
fi

printf "Đang xóa cluster...\n"
kind delete cluster --name "${CLUSTER_NAME}"
printf "${GREEN}✓${RESET} Đã xóa. Chạy ${BOLD}bash scripts/01-kind-up.sh${RESET} để tạo lại.\n"

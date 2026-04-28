#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# 02-bootstrap.sh — Cài đặt platform components lên kind cluster
# -----------------------------------------------------------------------------
# Script này cài đặt bộ platform tối thiểu cho Phase 1:
#   1. ingress-nginx — controller cho ingress, cho phép truy cập qua localhost
#   2. cert-manager  — quản lý TLS certificates (dùng self-signed cho local)
#   3. ArgoCD        — GitOps engine, sẽ quản lý mọi thứ từ đây trở đi
#
# Sau khi script này chạy xong, ArgoCD UI sẽ accessible tại http://argocd.local.
# -----------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Color output — pattern quen thuộc.
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'
  BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'
else
  GREEN=''; RED=''; YELLOW=''; BLUE=''; BOLD=''; RESET=''
fi

log()   { printf "\n${BLUE}▸${RESET} ${BOLD}%s${RESET}\n" "$1"; }
ok()    { printf "${GREEN}✓${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}⚠${RESET} %s\n" "$1"; }
fail()  { printf "${RED}✗${RESET} %s\n" "$1"; exit 1; }

# ─── Precheck: đang trỏ vào đúng cluster kind ───
# Nguy hiểm: nếu kubectl context trỏ vào cluster production thật, script này
# sẽ deploy lung tung. Bắt buộc check context trước mọi hành động.
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "none")
if [[ "$CURRENT_CONTEXT" != "kind-taskr" ]]; then
  fail "kubectl context hiện tại là '$CURRENT_CONTEXT', không phải 'kind-taskr'.
    Chạy: kubectl config use-context kind-taskr
    Hoặc tạo cluster trước: bash scripts/01-kind-up.sh"
fi
ok "Context: $CURRENT_CONTEXT"

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Add Helm repositories
# ─────────────────────────────────────────────────────────────────────────────
# Helm repo là nơi chứa chart (Kubernetes package). Mỗi chart có version riêng.
# Chúng ta pin version cụ thể ở phần install để deterministic, không dùng latest.

log "Step 1/4: Thêm Helm repositories"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo add jetstack      https://charts.jetstack.io                 2>/dev/null || true
helm repo add argo          https://argoproj.github.io/argo-helm       2>/dev/null || true
helm repo update > /dev/null
ok "Helm repos đã cập nhật"

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Cài ingress-nginx
# ─────────────────────────────────────────────────────────────────────────────
# ingress-nginx là Layer 7 reverse proxy, nhận traffic từ ngoài và route đến
# các Service trong cluster dựa trên host/path rules được định nghĩa trong
# Ingress resource. Đây là "cổng chính" vào cluster.
#
# Cấu hình dưới đây được tối ưu cho kind cluster:
# - kind.nodeSelector: chỉ deploy lên node có label ingress-ready=true
#   (control plane node đã được label ở cluster config)
# - kind.tolerations: cho phép schedule lên control plane (mặc định bị taint)
# - hostPort=true: bind trực tiếp vào port 80/443 của node, không qua Service
#   LoadBalancer. Kết hợp với port mapping của kind, điều này cho phép
#   localhost:80 đi thẳng vào ingress-nginx.

log "Step 2/4: Cài ingress-nginx"

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --create-namespace \
  --version 4.11.3 \
  --set controller.hostPort.enabled=true \
  --set controller.service.type=NodePort \
  --set controller.nodeSelector."ingress-ready"=true \
  --set-json 'controller.tolerations=[{"key":"node-role.kubernetes.io/control-plane","operator":"Equal","effect":"NoSchedule"}]' \
  --set controller.publishService.enabled=false \
  --wait --timeout 5m

ok "ingress-nginx đã cài đặt"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Cài cert-manager
# ─────────────────────────────────────────────────────────────────────────────
# cert-manager tự động phát hành và rotate TLS certificate. Ở local, chúng ta
# dùng một ClusterIssuer "self-signed" để không phụ thuộc Internet cho cert.
# Khi lên GCP, đổi issuer thành Let's Encrypt (ACME) mà không phải thay đổi
# logic application.

log "Step 3/4: Cài cert-manager"

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --version v1.16.1 \
  --set installCRDs=true \
  --set prometheus.enabled=false \
  --wait --timeout 5m

# Tạo ClusterIssuer self-signed. Đây là CRD của cert-manager, nên phải đợi
# cert-manager sẵn sàng xong rồi mới apply được.
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF

ok "cert-manager đã cài đặt + ClusterIssuer 'selfsigned-issuer' sẵn sàng"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Cài ArgoCD
# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD là trái tim của GitOps. Sau khi cài xong, mọi deployment tiếp theo
# sẽ được ArgoCD đồng bộ từ Git repo. Đây là lần duy nhất chúng ta cài đặt
# bằng Helm trực tiếp — từ đây trở đi, ArgoCD quản lý chính nó và mọi thứ.
#
# Cấu hình quan trọng:
# - server.insecure=true: tắt TLS cho ArgoCD server vì ingress đã handle TLS.
#   Nếu không tắt, sẽ bị "too many redirects" do double TLS termination.
# - configs.params."server.insecure"=true: config dùng bên trong ArgoCD.
# - Giảm resources để phù hợp local cluster.

log "Step 4/4: Cài ArgoCD"

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --version 7.7.5 \
  --set server.extraArgs="{--insecure}" \
  --set configs.params."server\.insecure"=true \
  --set controller.resources.requests.memory=256Mi \
  --set controller.resources.requests.cpu=100m \
  --set controller.resources.limits.memory=1Gi \
  --set repoServer.resources.requests.memory=128Mi \
  --set repoServer.resources.requests.cpu=50m \
  --set server.resources.requests.memory=128Mi \
  --set server.resources.requests.cpu=50m \
  --set redis.resources.requests.memory=64Mi \
  --set redis.resources.requests.cpu=25m \
  --wait --timeout 10m

ok "ArgoCD đã cài đặt"

# ─── Ingress cho ArgoCD UI ───
# Tạo Ingress resource để truy cập ArgoCD qua http://argocd.local.
# Người dùng cần thêm "127.0.0.1 argocd.local" vào /etc/hosts để resolve.
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    # Quan trọng: ArgoCD cần gRPC để các lệnh CLI hoạt động.
    # Annotation này báo ingress-nginx dùng HTTP/2 backend.
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
spec:
  ingressClassName: nginx
  rules:
    - host: argocd.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: argocd-server
                port:
                  number: 80
EOF

ok "Ingress cho ArgoCD đã tạo"

# ─────────────────────────────────────────────────────────────────────────────
# Lấy admin password ban đầu của ArgoCD
# ─────────────────────────────────────────────────────────────────────────────
# ArgoCD tự tạo password random lần đầu, lưu trong secret 'argocd-initial-admin-secret'.
# Best practice: đăng nhập một lần với password này rồi đổi ngay qua UI.

ARGOCD_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "")

# ─────────────────────────────────────────────────────────────────────────────
# Tổng kết
# ─────────────────────────────────────────────────────────────────────────────

log "Platform đã sẵn sàng"

cat <<EOF

  ${GREEN}${BOLD}✓ Cài đặt hoàn tất${RESET}

  Các component đã deploy:
    • ingress-nginx      ${BOLD}namespace${RESET} ingress-nginx
    • cert-manager       ${BOLD}namespace${RESET} cert-manager
    • ArgoCD             ${BOLD}namespace${RESET} argocd

  ${BOLD}Truy cập ArgoCD UI:${RESET}

    1. Thêm vào /etc/hosts (cần sudo):
       ${BOLD}echo '127.0.0.1 argocd.local' | sudo tee -a /etc/hosts${RESET}

    2. Mở trình duyệt: ${BOLD}http://argocd.local${RESET}

    3. Đăng nhập:
         Username: ${BOLD}admin${RESET}
         Password: ${BOLD}${ARGOCD_PW}${RESET}

       (password này cũng lấy được bất cứ lúc nào qua:
        ${BOLD}kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d${RESET})

  ${BOLD}Bước tiếp theo:${RESET}
    Build và deploy service đầu tiên:
      ${BOLD}make build-task-api${RESET}
      ${BOLD}make deploy-task-api${RESET}

EOF

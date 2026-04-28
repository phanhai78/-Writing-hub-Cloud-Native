#!/usr/bin/env bash
# 05-security.sh — Cài security stack: Kyverno + NetworkPolicy + Sealed Secrets
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTEXT="kind-taskr"

[[ -t 1 ]] && { G='\033[0;32m'; B='\033[0;34m'; BOLD='\033[1m'; R='\033[0m'; } \
            || { G=''; B=''; BOLD=''; R=''; }
log() { printf "${B}▸${R} ${BOLD}%s${R}\n" "$1"; }
ok()  { printf "${G}✓${R} %s\n" "$1"; }

kubectl config use-context "$CONTEXT" &>/dev/null

helm repo add kyverno   https://kyverno.github.io/kyverno/        2>/dev/null || true
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
helm repo update >/dev/null

# ─── Step 1: Kyverno ───
log "Step 1/3: Kyverno (policy engine)..."
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --version 3.2.7 \
  --set replicaCount=1 \
  --set admissionController.resources.requests.memory=128Mi \
  --set admissionController.resources.limits.memory=256Mi \
  --set backgroundController.resources.requests.memory=64Mi \
  --set backgroundController.resources.limits.memory=128Mi \
  --timeout 5m --wait
ok "Kyverno installed"

log "Deploy Kyverno policies..."
kubectl apply -f "$ROOT_DIR/platform/security/kyverno/policies.yaml"
ok "Kyverno policies applied"

# ─── Step 2: NetworkPolicy ───
log "Step 2/3: NetworkPolicy (zero-trust)..."
kubectl apply -f "$ROOT_DIR/platform/security/networkpolicy/taskr-policies.yaml"
ok "NetworkPolicy applied (default-deny + explicit allow)"

# ─── Step 3: Sealed Secrets ───
log "Step 3/3: Sealed Secrets controller..."
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --version 2.16.1 \
  --set resources.requests.memory=32Mi \
  --set resources.limits.memory=64Mi \
  --timeout 3m --wait
ok "Sealed Secrets installed"

# Cài kubeseal CLI nếu chưa có
if ! command -v kubeseal &>/dev/null; then
  printf "\n${B}ℹ${R} kubeseal CLI chưa cài. Cài bằng:\n"
  printf "  macOS: ${BOLD}brew install kubeseal${R}\n"
  printf "  Linux: ${BOLD}https://github.com/bitnami-labs/sealed-secrets/releases${R}\n"
fi

cat <<EOF

${G}${BOLD}✓ Security stack deployed${R}

  Kiểm tra policy enforcement:
    # Thử tạo pod chạy root — phải bị reject
    kubectl -n taskr run test-root --image=nginx --dry-run=server

  Tạo Sealed Secret (ví dụ DB password):
    echo -n "mysecretpassword" | kubectl create secret generic db-password \\
      --dry-run=client --from-file=password=/dev/stdin -o yaml | \\
      kubeseal --format yaml > platform/security/sealed-secrets/db-password.yaml
    git add platform/security/sealed-secrets/db-password.yaml
    git commit -m "add sealed db password"
    kubectl apply -f platform/security/sealed-secrets/db-password.yaml

EOF

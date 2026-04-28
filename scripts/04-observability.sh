#!/usr/bin/env bash
# 04-observability.sh — Cài observability stack lên kind cluster
# Không phụ thuộc Git repo — dùng trực tiếp Helm chart từ repo chính thức.
# Phù hợp cho: chưa có GitHub repo, hoặc muốn cài nhanh để thử.
#
# SAU KHI CÓ GITHUB REPO: chuyển qua ArgoCD Application trong
# infra/argocd/apps/observability.yaml để quản lý bằng GitOps.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONTEXT="kind-taskr"
NS="observability"

if [[ -t 1 ]]; then
  G='\033[0;32m'; B='\033[0;34m'; Y='\033[0;33m'; BOLD='\033[1m'; R='\033[0m'
else
  G=''; B=''; Y=''; BOLD=''; R=''
fi
log() { printf "${B}▸${R} ${BOLD}%s${R}\n" "$1"; }
ok()  { printf "${G}✓${R} %s\n" "$1"; }
warn(){ printf "${Y}⚠${R} %s\n" "$1"; }

kubectl config use-context "$CONTEXT" &>/dev/null \
  || { echo "Cluster kind-taskr không tồn tại. Chạy make cluster-up trước."; exit 1; }

# ─── Add Helm repos ───
log "Thêm Helm repos..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana              https://grafana.github.io/helm-charts              2>/dev/null || true
helm repo add open-telemetry       https://open-telemetry.github.io/opentelemetry-helm-charts 2>/dev/null || true
helm repo update >/dev/null
ok "Helm repos updated"

kubectl create namespace $NS --dry-run=client -o yaml | kubectl apply -f -

# ─── Step 1: kube-prometheus-stack ───
log "Step 1/4: kube-prometheus-stack (Prometheus + Grafana + Alertmanager)..."
log "Lần đầu chạy mất 3-5 phút (pull chart ~40MB)..."
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace $NS \
  --version 65.3.1 \
  --values "$ROOT_DIR/platform/observability/values/prometheus-stack.yaml" \
  --set grafana.adminPassword=taskr-grafana-admin \
  --timeout 10m \
  --wait
ok "kube-prometheus-stack installed"

# ─── Step 2: Loki ───
log "Step 2/4: Loki (log aggregation)..."
helm upgrade --install loki grafana/loki \
  --namespace $NS \
  --version 6.16.0 \
  --values "$ROOT_DIR/platform/observability/values/loki.yaml" \
  --timeout 5m \
  --wait
ok "Loki installed"

# ─── Step 3: Tempo ───
log "Step 3/4: Tempo (distributed tracing)..."
helm upgrade --install tempo grafana/tempo \
  --namespace $NS \
  --version 1.10.3 \
  --set resources.requests.cpu=50m \
  --set resources.requests.memory=128Mi \
  --set resources.limits.cpu=200m \
  --set resources.limits.memory=256Mi \
  --set persistence.enabled=false \
  --set tempo.reportingEnabled=false \
  --timeout 5m \
  --wait
ok "Tempo installed"

# ─── Step 4: OTel Collector ───
log "Step 4/4: OpenTelemetry Collector..."
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace $NS \
  --version 0.108.0 \
  --set mode=deployment \
  --set replicaCount=1 \
  --set resources.requests.cpu=25m \
  --set resources.requests.memory=64Mi \
  --set resources.limits.cpu=100m \
  --set resources.limits.memory=128Mi \
  --timeout 5m \
  --wait
ok "OTel Collector installed"

# ─── Deploy dashboards ConfigMap ───
log "Deploy Grafana dashboards..."
kubectl apply -f "$ROOT_DIR/platform/observability/dashboards/" \
  --namespace $NS
ok "Dashboards deployed"

# ─── Deploy PrometheusRules ───
log "Deploy alert rules..."
kubectl apply -f "$ROOT_DIR/platform/observability/prometheus-rules.yaml" \
  --namespace $NS 2>/dev/null || \
  warn "PrometheusRule CRD chưa có (đợi Prometheus Operator ready), bỏ qua"

# ─── Cập nhật /etc/hosts ───
HOSTS_NEEDED="grafana.local prometheus.local alertmanager.local"
MISSING=""
for host in $HOSTS_NEEDED; do
  grep -q "$host" /etc/hosts 2>/dev/null || MISSING="$MISSING $host"
done

if [[ -n "$MISSING" ]]; then
  warn "Thêm vào /etc/hosts:"
  printf "  ${BOLD}echo '127.0.0.1$MISSING' | sudo tee -a /etc/hosts${R}\n"
fi

# ─── Verify ───
log "Kiểm tra pod status..."
kubectl -n $NS get pods

cat <<EOF

${G}${BOLD}✓ Observability stack đã cài đặt${R}

  Truy cập:
    Grafana:       ${BOLD}http://grafana.local${R}
                   Username: admin / Password: taskr-grafana-admin

    Prometheus:    ${BOLD}http://prometheus.local${R}

  Rebuild task-api với OTel:
    ${BOLD}cd services/task-api && go mod tidy${R}
    ${BOLD}make build deploy-task-api${R}

  Sau đó smoke test và xem metrics tại Grafana:
    ${BOLD}make smoke-test${R}
    ${BOLD}open http://grafana.local/d/taskr-task-api-red${R}

EOF

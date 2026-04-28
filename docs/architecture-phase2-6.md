# Architecture — Phase 2 đến Phase 6

## Ràng buộc đã xác nhận
- RAM local: 8GB Docker → observability stack tối giản (tổng ~900Mi thêm)
- Domain: không có → dùng nip.io cho GCP, self-signed cho local
- Budget GCP: $300/90 ngày → GCP chỉ dùng khi demo Phase 4+

---

## Sơ đồ kiến trúc tổng thể (sau Phase 6)

```
╔══════════════════════════════════════════════════════════════════════╗
║  INTERNET                                                            ║
║    │                                                                  ║
║    ▼ HTTPS (Let's Encrypt / nip.io)                                  ║
╠══════════════════════════════════════════════════════════════════════╣
║  EDGE LAYER                                                          ║
║    Cloudflare (free) → WAF, DDoS protection                          ║
╠══════════════════════════════════════════════════════════════════════╣
║  INGRESS LAYER (namespace: ingress-nginx)                            ║
║    ingress-nginx ← cert-manager (Let's Encrypt / self-signed)        ║
╠══════════════════════════════════════════════════════════════════════╣
║  SECURITY LAYER (Phase 3)                                            ║
║    Kyverno (policy enforcement) ← applied at API server              ║
║    NetworkPolicy: default-deny + explicit allow rules                ║
║    Linkerd (mTLS, sidecar injection) ← east-west traffic             ║
╠═══════════════════════════════════╦══════════════════════════════════╣
║  APPLICATION (namespace: taskr)   ║  PLATFORM                        ║
║                                   ║                                  ║
║  task-api (Go, hexagonal)         ║  observability/                  ║
║    ├─ HTTP adapter (chi)          ║    Prometheus + Alertmanager      ║
║    ├─ OTel metrics/traces         ║    Grafana (dashboards as code)   ║
║    ├─ Domain (pure logic)         ║    Loki (log aggregation)         ║
║    └─ Adapter:                    ║    Tempo (distributed tracing)    ║
║        ├─ memory (Phase 1)        ║    OTel Collector (DaemonSet)     ║
║        └─ postgres (Phase 4)  ───▶║                                  ║
║                                   ║  security/                       ║
║  Argo Rollouts (Phase 5)          ║    Sealed Secrets                 ║
║    Canary 5→25→50→100%            ║    Kyverno policies               ║
║    AnalysisTemplate               ║                                  ║
║    (Prometheus gate)              ║  finops/ (Phase 6)               ║
║                                   ║    OpenCost                       ║
╠═══════════════════════════════════╣    Chaos Mesh                     ║
║  DATA LAYER (namespace: taskr)    ║                                  ║
║    PostgreSQL (CloudNativePG)     ╚══════════════════════════════════╣
║    Primary + 1 Replica (Phase 4)                                     ║
╠══════════════════════════════════════════════════════════════════════╣
║  GITOPS (ArgoCD — namespace: argocd)                                 ║
║    App-of-Apps pattern                                               ║
║    ├─ task-api-local                                                 ║
║    ├─ observability                                                   ║
║    ├─ security                                                        ║
║    └─ platform-tools                                                  ║
╠══════════════════════════════════════════════════════════════════════╣
║  CI/CD (GitHub Actions — Phase 5)                                    ║
║    Lint → Test → Security scan → Build → Push → Bump tag → ArgoCD   ║
╚══════════════════════════════════════════════════════════════════════╝
```

---

## Phase 2 — Observability (8GB-optimized)

**Stack:** kube-prometheus-stack (Prometheus+Grafana+Alertmanager) + Loki + Tempo + OTel Collector

**Resource budget tổng cho observability namespace:** ~900Mi RAM

| Component          | Request | Limit  | Ghi chú                    |
|--------------------|---------|--------|----------------------------|
| Prometheus         | 256Mi   | 512Mi  | retention 24h để nhỏ       |
| Grafana            | 128Mi   | 256Mi  | tắt plugin nặng            |
| Alertmanager       | 32Mi    | 64Mi   |                            |
| Loki               | 128Mi   | 256Mi  | single binary mode         |
| Tempo              | 128Mi   | 256Mi  | single binary mode         |
| OTel Collector     | 64Mi    | 128Mi  | Deployment (không DaemonSet)|
| **Tổng**           | **736Mi**| **1.4Gi**|                         |

**Deliverables:**
- Helm values tối giản cho từng component
- OTel instrumentation trong task-api (metrics + traces)
- 2 Grafana dashboard as code (service RED metrics, infra USE)
- PrometheusRule: 3 alert cơ bản
- ArgoCD Application cho observability namespace
- Script thêm hosts: grafana.local, prometheus.local

---

## Phase 3 — Security

**Stack:** Kyverno + NetworkPolicy + Linkerd + Sealed Secrets + Trivy scan

**Deliverables:**
- NetworkPolicy: default-deny taskr namespace + explicit allow rules
- 5 Kyverno ClusterPolicy (no-root, resource-required, trusted-registry, labels-required, no-latest-tag)
- Linkerd install + annotation cho namespace taskr
- Sealed Secrets controller + workflow encrypt/decrypt
- Trivy scan tích hợp vào Makefile

---

## Phase 4 — HA & GCP

**Stack:** CloudNativePG + postgres adapter Go + Terraform GKE Autopilot + Velero

**GCP cost estimate (demo 2h):** ~$1.00
- GKE Autopilot: $0.10/vCPU/h × 0.5 vCPU × 2h = $0.10
- Load Balancer: $0.025/h × 2h = $0.05
- Egress: ~$0.00 (minimal)

**Deliverables:**
- postgres adapter Go (swap memory → postgres, domain unchanged)
- golang-migrate schema migration
- CloudNativePG PostgreSQL CRD
- Terraform: VPC, GKE Autopilot, Artifact Registry, IAM
- Overlay gcp-demo với nip.io ingress
- Velero backup setup
- make gcp-up / make gcp-down (auto destroy sau 2h via Cloud Scheduler)

---

## Phase 5 — Progressive Delivery

**Stack:** Argo Rollouts + AnalysisTemplate + GitHub Actions CI

**Canary flow:**
```
deploy v2 → 5% traffic (5 phút) → check metrics →
  OK: 25% (5 phút) → OK: 50% (5 phút) → 100%
  FAIL: auto-rollback về v1
```

**Deliverables:**
- Rollout CRD thay thế Deployment
- AnalysisTemplate dùng Prometheus query
- GitHub Actions workflow (lint→test→build→push→bump)
- "Bug injection" script để demo rollback
- Makefile targets

---

## Phase 6 — FinOps & Operations

**Stack:** OpenCost + ResourceQuota + Chaos Mesh + Runbook

**Deliverables:**
- OpenCost deployment với Prometheus backend
- ResourceQuota + LimitRange cho namespace taskr
- Chaos Mesh: 3 experiment (pod-kill, network-delay, cpu-stress)
- Operations runbook (5 scenario thường gặp)
- Weekly cost report script

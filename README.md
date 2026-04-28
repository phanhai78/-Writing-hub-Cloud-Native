### Writing a New Post

1. Create a new file in `_articles/` (e.g. `my-post-title.md`)
2. Add front matter:

```yaml
---
layout: post
title: "Hướng Dẫn Triển Khai Cloud Native Taskr"
date: 2026-04-28
author: Phan Đức Hải
tags: [Kubenetes , Helm]
---
```

3. Write your content in Markdown
4. Submit a pull request
# Cloud Native Taskr

> Một dự án học hỏi kiến trúc cloud-native hoàn chỉnh — từ Go microservice,
> Kubernetes, GitOps với ArgoCD, đến observability, scaling và security.
> Chạy 100% local trên máy bạn với kind, deploy lên GCP khi cần demo.

---

## Tại sao dự án này tồn tại

Học cloud-native qua đọc tài liệu rời rạc rất khó, vì mỗi công cụ (Kubernetes,
ArgoCD, Prometheus, Helm, ...) được giới thiệu độc lập và bạn không thấy
chúng khớp vào một bức tranh tổng thể như thế nào. Dự án này xây từ con số
không *một hệ thống production-grade quy mô nhỏ*, qua đó bạn thấy được mọi
mảnh ghép phối hợp ra sao.

Chúng ta xây một **Task Manager** đơn giản — CRUD API cho task — nhưng dưới
nó là toàn bộ stack thực tế: hexagonal Go service, Kubernetes deployment với
security context chặt chẽ, ArgoCD GitOps, observability với Prometheus/Grafana/Loki,
canary deployment với Argo Rollouts. Mỗi phase thêm một lớp giá trị.

---

## Quickstart (5 phút)

```bash
# 1. Kiểm tra prerequisites (docker, kubectl, kind, helm, go)
make prereq

# 2. Tạo kind cluster
make cluster-up

# 3. Cài ArgoCD + ingress-nginx + cert-manager
make bootstrap

# 4. Build image và deploy task-api
make build deploy-task-api

# 5. Thêm vào /etc/hosts (chỉ làm 1 lần)
echo '127.0.0.1 taskr.local argocd.local' | sudo tee -a /etc/hosts

# 6. Smoke test
make smoke-test

# 7. Mở ArgoCD UI
open http://argocd.local
make get-argocd-password   # lấy password admin
```

Chạy `make help` để xem đầy đủ target.

---

## Cấu trúc thư mục

```
cloud-native-taskr/
├── docs/                          # Tài liệu theo từng phase
│   └── 00-gcp-onboarding.md
│
├── scripts/                       # Automation scripts
│   ├── 00-prerequisites.sh        # Check tools
│   ├── 01-kind-up.sh              # Tạo cluster
│   ├── 02-bootstrap.sh            # Cài platform
│   ├── 03-build-and-load.sh       # Build image
│   └── 99-kind-down.sh            # Xóa cluster
│
├── infra/
│   ├── kind/cluster.yaml          # Kind cluster config
│   ├── argocd/apps/               # ArgoCD Application manifests
│   └── terraform/                 # (Phase 4) Hạ tầng GCP
│
├── services/
│   └── task-api/                  # Go service đầu tiên
│       ├── cmd/server/main.go     # Entry point
│       ├── internal/
│       │   ├── domain/            # Business logic thuần túy
│       │   ├── port/              # Interface (hexagonal port)
│       │   ├── adapter/           # HTTP + memory implementations
│       │   └── observability/     # Logger, metrics (Phase 2)
│       ├── Dockerfile             # Multi-stage distroless
│       └── go.mod
│
├── deploy/
│   └── task-api/
│       ├── base/                  # K8s manifest chung (Kustomize base)
│       └── overlays/
│           ├── local/             # Overlay cho kind
│           └── gcp-demo/          # Overlay cho GCP (Phase 4)
│
├── platform/                      # (Phase 2) Platform components
│                                  # Prometheus, Grafana, Loki, ...
│
└── Makefile                       # Entry point mọi tác vụ
```

---

## Kiến trúc tổng quan

```
                  ┌─────────────────────────────┐
  User ──HTTP──▶  │   ingress-nginx (L7)         │
                  │   host: taskr.local          │
                  └──────────────┬───────────────┘
                                 │ ClusterIP
                  ┌──────────────▼───────────────┐
                  │   Service task-api           │
                  │   3x replica (base), 1x local│
                  └──────────────┬───────────────┘
                                 │
                  ┌──────────────▼───────────────┐
                  │  Pod: task-api container      │
                  │  ┌─────────────────────────┐  │
                  │  │  HTTP adapter (chi)      │  │
                  │  │     ↓ ↑                  │  │
                  │  │  Port (interface)        │  │
                  │  │     ↓ ↑                  │  │
                  │  │  Domain (pure logic)     │  │
                  │  │     ↓ ↑                  │  │
                  │  │  Memory adapter          │  │
                  │  └─────────────────────────┘  │
                  │  distroless image, non-root   │
                  └───────────────────────────────┘

         GitOps loop:
         ┌─────────┐         ┌────────┐        ┌────────────┐
         │ Git repo├────────▶│ ArgoCD ├───────▶│  cluster   │
         │ (this)  │  watch  │  sync  │ apply  │  resources │
         └─────────┘         └────────┘        └────────────┘
```

Phần sâu hơn về triết lý hexagonal architecture, lý do chọn từng công cụ,
và các quyết định trade-off, xem `docs/architecture.md` (Phase 2 sẽ có).

---

## Lộ trình theo phase

| Phase | Mục tiêu                                         | Trạng thái    |
|-------|--------------------------------------------------|---------------|
| 0     | Onboarding GCP + tools                           | ✓ Hoàn thành  |
| 1     | Go service + kind + ArgoCD (cái bạn đang đọc)    | ✓ Hoàn thành  |
| 2     | Observability: Prometheus, Grafana, Loki, Tempo  | ✓ Hoàn thành  |
| 3     | Security: NetworkPolicy, Kyverno, Linkerd mTLS   | ✓ Hoàn thành  |
| 4     | HA & multi-env: Postgres, GCP deploy             | ✓ Hoàn thành  |
| 5     | Canary với Argo Rollouts                         | ✓ Hoàn thành  |
| 6     | FinOps: OpenCost, right-sizing, spot instances   | ✓ Hoàn thành  |

---

## Triết lý thiết kế

Ba nguyên tắc dẫn đường mọi quyết định trong dự án:

**Đơn giản trước, phức tạp sau.** Phase 1 không có database, không có message
queue, không có service mesh. Mỗi phase chỉ thêm một khái niệm mới, và khái
niệm đó được dạy kỹ trước khi chuyển sang phase sau.

**Mỗi lớp tách biệt rõ ràng.** Domain không biết HTTP tồn tại. HTTP không
biết database tồn tại. Kubernetes không biết Go. Sự tách biệt này làm code
dễ test, dễ thay đổi, và dễ hiểu cho người mới.

**Git là nguồn sự thật duy nhất.** Sau bootstrap, bạn không bao giờ `kubectl
apply` thủ công nữa. Mọi thay đổi đi qua commit + push → ArgoCD tự sync.
Điều này buộc bạn có commit history sạch và audit trail đầy đủ.

---

## FAQ

**Tôi có bắt buộc phải dùng macOS không?**

Không. Dự án chạy trên Linux, WSL2 (Windows), macOS. Chỉ cần Docker và các
CLI tool trong `make prereq`.

**Tại sao dùng kind mà không phải minikube?**

Kind chạy Kubernetes "thật" trong Docker container, giống production nhất.
Minikube có nhiều mode (docker, virtualbox, hyperkit, ...) dễ gây confusion.
k3d cũng là lựa chọn tốt; chúng ta chọn kind vì nó là công cụ chính thức
của SIG-Testing của Kubernetes.

**Tại sao không dùng `go mod vendor`?**

Go module từ 1.11+ cache dependency trong `$GOPATH/pkg/mod`, reproducible
qua `go.sum`. Vendor chỉ cần khi bạn không có internet lúc build hoặc muốn
freeze bundled dep. Không cần cho dự án này.

**Sao không dùng framework như Gin hay Echo?**

Chi là HTTP router thuần túy (1000 dòng code), không phải framework. Bạn
nhìn thấy mọi thứ đang xảy ra, không có magic. Gin/Echo ẩn quá nhiều logic
khiến khó debug khi học. Nếu bạn thấy Gin tiện hơn, có thể swap — HTTP
adapter chỉ là một file, dễ thay.

---

## License

MIT (sẽ thêm file LICENSE sau).

## Contributing

Dự án cá nhân phục vụ học tập. Nếu bạn thấy bug hoặc có câu hỏi, mở issue
trên GitHub.

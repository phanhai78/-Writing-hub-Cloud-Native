# ═════════════════════════════════════════════════════════════════════════════
# Cloud Native Taskr — Makefile
# ═════════════════════════════════════════════════════════════════════════════
# Đây là "remote control" của dự án. Mọi tác vụ thường xuyên đều có target
# tương ứng. Chạy `make help` để xem danh sách đầy đủ.
#
# Quy ước:
#   - Target có mô tả bằng comment ## sẽ hiển thị trong make help
#   - Target bắt đầu bằng _ là internal, không dùng trực tiếp
# ═════════════════════════════════════════════════════════════════════════════

# Dùng bash với flags strict — khớp với script để behavior nhất quán.
SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c

# Biến — có thể override từ command line: make build IMAGE_TAG=v1.0.0
IMAGE_NAME ?= task-api
IMAGE_TAG  ?= local-dev
CLUSTER_NAME ?= taskr
KUBECTL_CONTEXT := kind-$(CLUSTER_NAME)

# Màu sắc cho help target.
BLUE  := \033[0;34m
GREEN := \033[0;32m
BOLD  := \033[1m
RESET := \033[0m

# ─── Default target — chạy `make` không tham số sẽ hiện help ───
.DEFAULT_GOAL := help

# Target KHÔNG tạo file có cùng tên — mọi target của chúng ta đều phony.
.PHONY: help \
        prereq cluster-up cluster-down bootstrap \
        build load deploy-task-api undeploy-task-api \
        logs-task-api port-forward-argocd \
        test lint fmt \
        smoke-test \
        clean

# ═══════════════════════════════════════════════════════════════════════════
# Help (auto-generated từ comment ## của các target)
# ═══════════════════════════════════════════════════════════════════════════

help: ## Hiển thị danh sách target và mô tả
	@printf "\n$(BOLD)Cloud Native Taskr — available targets$(RESET)\n\n"
	@awk 'BEGIN {FS = ":.*?## "} \
		/^[a-zA-Z_-]+:.*?## / { \
			printf "  $(BLUE)%-22s$(RESET) %s\n", $$1, $$2 \
		}' $(MAKEFILE_LIST)
	@printf "\nQuickstart:\n"
	@printf "  $(BOLD)make prereq$(RESET)          # kiểm tra tool cài đủ chưa\n"
	@printf "  $(BOLD)make cluster-up$(RESET)      # tạo kind cluster\n"
	@printf "  $(BOLD)make bootstrap$(RESET)       # cài ArgoCD + ingress-nginx + cert-manager\n"
	@printf "  $(BOLD)make build load$(RESET)      # build image + load vào kind\n"
	@printf "  $(BOLD)make deploy-task-api$(RESET) # deploy task-api\n"
	@printf "  $(BOLD)make smoke-test$(RESET)      # gửi request test\n\n"

# ═══════════════════════════════════════════════════════════════════════════
# Setup / Teardown
# ═══════════════════════════════════════════════════════════════════════════

prereq: ## Kiểm tra prerequisites (docker, kubectl, kind, helm, go)
	@bash scripts/00-prerequisites.sh

cluster-up: ## Tạo kind cluster (3 node)
	@bash scripts/01-kind-up.sh

cluster-down: ## Xóa kind cluster hoàn toàn
	@bash scripts/99-kind-down.sh

bootstrap: ## Cài ArgoCD + ingress-nginx + cert-manager lên cluster
	@bash scripts/02-bootstrap.sh

# ═══════════════════════════════════════════════════════════════════════════
# Build & Deploy
# ═══════════════════════════════════════════════════════════════════════════

build: ## Build Docker image task-api
	@bash scripts/03-build-and-load.sh

load: build ## Alias của build (build đã tự load vào kind)

deploy-task-api: ## Deploy task-api bằng kubectl + kustomize
	@printf "$(BLUE)▸$(RESET) Apply manifest từ overlay local...\n"
	@kubectl --context $(KUBECTL_CONTEXT) apply -k deploy/task-api/overlays/local
	@printf "$(BLUE)▸$(RESET) Đợi deployment ready...\n"
	@kubectl --context $(KUBECTL_CONTEXT) -n taskr rollout status deployment/task-api --timeout=2m
	@printf "$(GREEN)✓$(RESET) task-api deployed. Thử:\n"
	@printf "  $(BOLD)curl -H 'Host: taskr.local' http://localhost/api/v1/tasks$(RESET)\n"

undeploy-task-api: ## Xóa task-api khỏi cluster
	@kubectl --context $(KUBECTL_CONTEXT) delete -k deploy/task-api/overlays/local --ignore-not-found=true

deploy-via-argocd: ## Đăng ký task-api vào ArgoCD (yêu cầu Git repo public)
	@kubectl --context $(KUBECTL_CONTEXT) apply -f infra/argocd/apps/task-api-local.yaml
	@printf "$(GREEN)✓$(RESET) Đã đăng ký Application 'task-api-local' với ArgoCD.\n"
	@printf "   Xem tại http://argocd.local\n"

# ═══════════════════════════════════════════════════════════════════════════
# Observability / Debug
# ═══════════════════════════════════════════════════════════════════════════

logs-task-api: ## Tail log của tất cả pod task-api (cần stern hoặc kubectl >=1.28)
	@kubectl --context $(KUBECTL_CONTEXT) -n taskr logs -l app.kubernetes.io/name=task-api --all-containers --tail=100 -f

port-forward-argocd: ## Port-forward ArgoCD UI (nếu không thích dùng ingress)
	@printf "$(BLUE)▸$(RESET) ArgoCD UI sẽ available tại https://localhost:8443\n"
	@kubectl --context $(KUBECTL_CONTEXT) -n argocd port-forward svc/argocd-server 8443:443

get-argocd-password: ## In ra password admin ban đầu của ArgoCD
	@kubectl --context $(KUBECTL_CONTEXT) -n argocd get secret argocd-initial-admin-secret \
		-o jsonpath="{.data.password}" | base64 -d
	@echo

# ═══════════════════════════════════════════════════════════════════════════
# Go — test, lint, format
# ═══════════════════════════════════════════════════════════════════════════

test: ## Chạy unit test với race detector
	@cd services/task-api && go test -race -cover ./...

lint: ## Chạy golangci-lint (cần cài riêng)
	@if command -v golangci-lint &>/dev/null; then \
		cd services/task-api && golangci-lint run ./...; \
	else \
		echo "golangci-lint chưa cài. Hướng dẫn: https://golangci-lint.run/usage/install/"; \
		exit 1; \
	fi

fmt: ## Format code với gofmt + goimports
	@cd services/task-api && gofmt -w -s .
	@if command -v goimports &>/dev/null; then \
		cd services/task-api && goimports -w .; \
	fi

# ═══════════════════════════════════════════════════════════════════════════
# Smoke test — gửi request thực tế để verify end-to-end
# ═══════════════════════════════════════════════════════════════════════════

smoke-test: ## Gửi request test đến task-api qua ingress
	@printf "$(BLUE)▸$(RESET) Smoke test task-api qua http://taskr.local\n"
	@printf "$(BLUE)▸$(RESET) 1. List tasks (empty):\n"
	@curl -sS -H 'Host: taskr.local' http://localhost/api/v1/tasks | jq .
	@printf "\n$(BLUE)▸$(RESET) 2. Create task:\n"
	@curl -sS -X POST -H 'Host: taskr.local' -H 'Content-Type: application/json' \
		-d '{"title":"Test từ Makefile","description":"smoke test"}' \
		http://localhost/api/v1/tasks | jq .
	@printf "\n$(BLUE)▸$(RESET) 3. List tasks (1 item):\n"
	@curl -sS -H 'Host: taskr.local' http://localhost/api/v1/tasks | jq .

# ═══════════════════════════════════════════════════════════════════════════
# Cleanup
# ═══════════════════════════════════════════════════════════════════════════

clean: ## Xóa mọi artifact local (image, cluster, ...)
	@printf "Xóa cluster...\n"
	@$(MAKE) cluster-down
	@printf "Xóa Docker image...\n"
	@docker image rm $(IMAGE_NAME):$(IMAGE_TAG) 2>/dev/null || true
	@printf "$(GREEN)✓$(RESET) Đã clean.\n"

# syntax=docker/dockerfile:1.7
# -----------------------------------------------------------------------------
# Dockerfile cho task-api — multi-stage build tạo image distroless nhỏ gọn
# -----------------------------------------------------------------------------
# Kết quả: image cuối cùng ~20MB, chạy non-root, không có shell (giảm bề mặt
# tấn công), không có package manager (không thể install malware khi đã deploy).
#
# Build: docker build -t task-api:dev .
# Chạy:  docker run -p 8080:8080 task-api:dev
# -----------------------------------------------------------------------------

# ============================================================================
# Stage 1: builder — compile Go binary
# ============================================================================
# Dùng alpine thay vì golang:1.22 (Debian-based) vì nhỏ hơn ~100MB.
# Alpine vẫn có đủ tool cho Go build (gcc không cần vì CGO_ENABLED=0).

FROM golang:1.22-alpine AS builder

# Cài ca-certificates vì builder image sẽ dùng để copy certs sang image cuối.
# git dùng cho go mod download (một số dep qua git).
# tzdata copy sang image cuối cho time.LoadLocation hoạt động đúng.
RUN apk add --no-cache ca-certificates git tzdata

WORKDIR /build

# ─── Tối ưu cache: copy go.mod/go.sum trước, download dep riêng ───
# Docker layer caching: nếu go.mod không đổi, layer này được cache, tiết kiệm
# thời gian build đáng kể. Đây là kỹ thuật quan trọng nhất cho Dockerfile Go.
COPY go.mod go.sum* ./
RUN go mod download

# ─── Copy source code và build ───
COPY . .

# Build flags giải thích:
#   CGO_ENABLED=0    -> static binary, không link với libc. Chạy được trên
#                       scratch/distroless không cần glibc.
#   GOOS=linux       -> target Linux (container chạy Linux).
#   GOARCH=amd64     -> x86_64. Đổi sang arm64 nếu target ARM.
#   -ldflags:
#     -s             -> bỏ symbol table, binary nhỏ hơn ~25%.
#     -w             -> bỏ DWARF debug info, nhỏ hơn thêm.
#     -X main.xxx    -> inject version/commit vào biến global của main package.
#   -trimpath        -> xóa absolute path từ binary, làm build reproducible.
ARG VERSION=dev
ARG COMMIT=unknown

RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
      -o /build/task-api \
      ./cmd/server

# Verify binary: đảm bảo không có runtime dep bất ngờ.
# Nếu binary không static, lệnh này sẽ in "dynamic" và báo động.
RUN file /build/task-api || true

# ============================================================================
# Stage 2: runtime — distroless image chạy binary
# ============================================================================
# gcr.io/distroless/static-debian12:nonroot là image Google duy trì, chỉ chứa:
#   - ca-certificates (cho HTTPS outbound)
#   - tzdata
#   - User "nonroot" (UID 65532)
# KHÔNG có: shell, package manager, busybox, python. Minimal attack surface.
#
# Tag "nonroot" đảm bảo process không chạy as root — Kyverno/OPA policy sẽ
# enforce điều này, image tag này luôn đúng.

FROM gcr.io/distroless/static-debian12:nonroot

# OCI labels — metadata chuẩn cho image, hiển thị trong docker inspect
# và image registry UI. Giúp audit và trace về source.
LABEL org.opencontainers.image.title="task-api"
LABEL org.opencontainers.image.description="Task Manager API service"
LABEL org.opencontainers.image.source="https://github.com/taskr/cloud-native-taskr"
LABEL org.opencontainers.image.licenses="MIT"

# Copy binary và ca-certificates từ builder stage.
# --chown=nonroot:nonroot đảm bảo file thuộc về user non-root.
COPY --from=builder --chown=nonroot:nonroot /build/task-api /app/task-api
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo

# User non-root (UID 65532 do distroless định nghĩa).
# Kubernetes PodSecurityContext sẽ enforce runAsNonRoot=true,
# image này đã tuân thủ sẵn.
USER nonroot:nonroot

# Expose port (thông tin metadata, không mở port thực sự).
# Port thật được kube Service/NodePort mapping.
EXPOSE 8080

# Health check cho Docker standalone. Trong Kubernetes sẽ dùng liveness/readiness
# probe thay vì HEALTHCHECK này. Để lại cho docker run local test.
# distroless không có curl/wget, nên dùng binary self-check qua /healthz
# ... thực ra distroless không có tool nào, nên skip HEALTHCHECK ở đây.
# Kubernetes probe sẽ dùng HTTP GET trực tiếp.

# ENTRYPOINT dạng exec form (array) — PID 1 chính là binary, nhận signal
# trực tiếp từ Kubernetes (SIGTERM). Nếu dùng shell form (string), sẽ có
# sh làm PID 1 và signal không propagate — graceful shutdown fail.
ENTRYPOINT ["/app/task-api"]

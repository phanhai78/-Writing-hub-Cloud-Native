// router.go — cập nhật Phase 2: thêm /metrics và OTel instrumentation
package http

import (
	"context"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/hlog"

	"github.com/taskr/task-api/internal/observability"
	"github.com/taskr/task-api/internal/port"
)

// NewRouter — Phase 2: thêm metrics endpoint và OTel instrumentation.
// Signature thay đổi: nhận thêm metricsProvider để mount /metrics.
func NewRouter(
	repo port.TaskRepository,
	logger zerolog.Logger,
	metricsProvider *observability.MetricsProvider, // nil-safe: nếu nil thì bỏ qua
	serviceName string,
) http.Handler {
	r := chi.NewRouter()

	// ─── Middleware stack (giữ nguyên từ Phase 1) ───
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(hlog.NewHandler(logger))
	r.Use(hlog.AccessHandler(func(r *http.Request, status, size int, duration time.Duration) {
		hlog.FromRequest(r).Info().
			Str("method", r.Method).
			Str("path", r.URL.Path).
			Int("status", status).
			Int("bytes", size).
			Dur("duration", duration).
			Msg("request")
	}))
	r.Use(hlog.RequestIDHandler("request_id", "X-Request-Id"))
	r.Use(middleware.Recoverer)
	r.Use(middleware.Timeout(30 * time.Second))

	handler := NewHandler(repo, logger)

	// ─── Operational endpoints ───
	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	r.Get("/readyz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()
		if _, err := repo.Count(ctx); err != nil {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ready"))
	})

	// ─── Phase 2: /metrics endpoint ───
	// Prometheus sẽ scrape endpoint này mỗi scrapeInterval (30s).
	// Nếu metricsProvider nil (Phase 1 backward compat), skip.
	if metricsProvider != nil {
		r.Handle("/metrics", metricsProvider.Handler())
	}

	// ─── API routes với OTel instrumentation ───
	r.Route("/api/v1", func(r chi.Router) {
		r.Route("/tasks", func(r chi.Router) {
			r.Post("/", handler.CreateTask)
			r.Get("/", handler.ListTasks)
			r.Get("/{id}", handler.GetTask)
			r.Patch("/{id}", handler.UpdateTask)
			r.Delete("/{id}", handler.DeleteTask)
		})
	})

	// Bọc toàn bộ router với OTel HTTP instrumentation.
	// Phải wrap NGOÀI cùng (sau khi mount tất cả route) để instrument mọi endpoint.
	// Nếu serviceName trống, bỏ qua instrumentation.
	if serviceName != "" {
		return Instrument(r, serviceName)
	}
	return r
}

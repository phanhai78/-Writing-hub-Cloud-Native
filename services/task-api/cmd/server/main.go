// cmd/server/main.go — Phase 2 update
// Thêm: MetricsProvider + TracerProvider, graceful shutdown đa tầng
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	httpadapter "github.com/taskr/task-api/internal/adapter/http"
	"github.com/taskr/task-api/internal/adapter/memory"
	"github.com/taskr/task-api/internal/observability"
)

var (
	version = "dev"
	commit  = "unknown"
)

func main() {
	env         := getEnv("APP_ENV", "development")
	port        := getEnv("HTTP_PORT", "8080")
	serviceName := getEnv("SERVICE_NAME", "task-api")

	// ─── Logger ───
	logger := observability.NewLogger(env, serviceName, version)
	logger.Info().Str("commit", commit).Msg("starting task-api")

	// ─── Metrics provider (Phase 2) ───
	// NewMetricsProvider khởi tạo Prometheus exporter và gắn OTel global.
	metricsProvider, err := observability.NewMetricsProvider(serviceName, version)
	if err != nil {
		// Metrics thất bại không nên kill service — log warning và tiếp tục.
		logger.Warn().Err(err).Msg("metrics provider init failed, continuing without metrics")
		metricsProvider = nil
	} else {
		logger.Info().Msg("metrics provider ready")
	}

	// ─── Tracer provider (Phase 2) ───
	// Kết nối OTel Collector. Nếu Collector chưa chạy (local dev không có Phase 2),
	// service vẫn khởi động bình thường với no-op tracer.
	ctx := context.Background()
	tracerProvider, err := observability.NewTracerProvider(ctx, serviceName, version)
	if err != nil {
		logger.Warn().Err(err).Msg("tracer provider init failed, traces disabled")
	} else {
		logger.Info().Msg("tracer provider ready")
	}

	// ─── Repository ───
	repo := memory.NewTaskRepository()

	// ─── Router ───
	handler := httpadapter.NewRouter(repo, logger, metricsProvider, serviceName)

	// ─── HTTP Server ───
	srv := &http.Server{
		Addr:         ":" + port,
		Handler:      handler,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// ─── Start ───
	serverErr := make(chan error, 1)
	go func() {
		logger.Info().Str("addr", srv.Addr).Msg("HTTP server listening")
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			serverErr <- err
		}
	}()

	// ─── Signal handling ───
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)

	select {
	case err := <-serverErr:
		logger.Fatal().Err(err).Msg("server error")
	case sig := <-quit:
		logger.Info().Str("signal", sig.String()).Msg("shutting down")
	}

	// ─── Graceful shutdown — thứ tự quan trọng ───
	// 1. Stop nhận request mới (HTTP server drain)
	// 2. Flush traces còn trong buffer → Collector
	// 3. Flush metrics

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()

	// 1. HTTP drain
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error().Err(err).Msg("http shutdown error")
	}

	// 2. Flush traces
	if tracerProvider != nil {
		if err := tracerProvider.Shutdown(shutdownCtx); err != nil {
			logger.Error().Err(err).Msg("tracer shutdown error")
		}
	}

	// 3. Flush metrics
	if metricsProvider != nil {
		if err := metricsProvider.Shutdown(shutdownCtx); err != nil {
			logger.Error().Err(err).Msg("metrics shutdown error")
		}
	}

	logger.Info().Msg("shutdown complete")
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

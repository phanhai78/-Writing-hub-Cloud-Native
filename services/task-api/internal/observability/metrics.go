// Package observability — metrics.go
// Khởi tạo OpenTelemetry metrics provider với Prometheus exporter.
//
// THIẾT KẾ: Dùng OTel SDK làm abstraction layer. Exporter có thể swap
// (Prometheus, OTLP, ...) mà không phải thay code instrumentation.
// Ở Phase 2: export Prometheus format (pull) qua /metrics endpoint.
// Ở Phase 4+: thêm OTLP push sang OTel Collector.
package observability

import (
	"context"
	"fmt"
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/prometheus"
	"go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
)

// MetricsProvider bọc OTel MeterProvider và Prometheus HTTP handler.
// Caller dùng Provider() để lấy meter, và Handler() để expose /metrics.
type MetricsProvider struct {
	provider *sdkmetric.MeterProvider
	handler  http.Handler
}

// NewMetricsProvider khởi tạo Prometheus exporter và gắn vào OTel global.
// Gọi một lần trong main.go. Trả error nếu khởi tạo thất bại.
func NewMetricsProvider(serviceName, version string) (*MetricsProvider, error) {
	// Prometheus exporter — pull model, Prometheus scrape /metrics
	exporter, err := prometheus.New()
	if err != nil {
		return nil, fmt.Errorf("prometheus exporter: %w", err)
	}

	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(exporter),
		// Resource attributes — gắn vào mọi metric từ service này
		sdkmetric.WithResource(newResource(serviceName, version)),
	)

	// Gắn làm global provider để code bất kỳ đâu gọi otel.GetMeterProvider()
	// đều nhận đúng provider này.
	otel.SetMeterProvider(provider)

	return &MetricsProvider{
		provider: provider,
		// promhttp.Handler() trả metrics theo Prometheus text format
		handler: promhttp.Handler(),
	}, nil
}

// Handler trả http.Handler để mount tại /metrics.
func (mp *MetricsProvider) Handler() http.Handler {
	return mp.handler
}

// Meter trả Meter đã gắn serviceName — dùng để tạo instrument (counter, gauge, histogram).
func (mp *MetricsProvider) Meter(name string) metric.Meter {
	return mp.provider.Meter(name)
}

// Shutdown flush metrics còn đọng trước khi process exit.
// Gọi trong defer của graceful shutdown.
func (mp *MetricsProvider) Shutdown(ctx context.Context) error {
	return mp.provider.Shutdown(ctx)
}

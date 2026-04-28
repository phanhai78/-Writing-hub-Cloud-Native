// Package observability — tracing.go
// Khởi tạo OTel TracerProvider với OTLP exporter sang OTel Collector.
// Trace được gửi theo push model (OTLP/gRPC) → OTel Collector → Tempo.
package observability

import (
	"context"
	"fmt"
	"os"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/propagation"
	sdkresource "go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

// TracerProvider bọc OTel SDK TracerProvider.
type TracerProvider struct {
	provider *sdktrace.TracerProvider
}

// NewTracerProvider khởi tạo OTLP gRPC exporter và gắn vào OTel global.
//
// Env vars:
//   OTEL_EXPORTER_OTLP_ENDPOINT  — endpoint của OTel Collector (default: localhost:4317)
//   OTEL_SAMPLING_RATIO           — tỷ lệ sample trace (default: 1.0 = 100%)
//
// Nếu OTEL_EXPORTER_OTLP_ENDPOINT trống hoặc không kết nối được,
// tracing vẫn hoạt động nhưng trace không được export (no-op exporter).
func NewTracerProvider(ctx context.Context, serviceName, version string) (*TracerProvider, error) {
	endpoint := getEnvOrDefault("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")

	// Kết nối đến OTel Collector. WithBlock() để phát hiện lỗi ngay khi start.
	// Timeout 5s — nếu Collector chưa sẵn sàng, service vẫn start được
	// (trace sẽ bị drop cho đến khi Collector online).
	conn, err := grpc.NewClient(endpoint,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
	)
	if err != nil {
		// Không fail hard — trace không hoạt động nhưng service vẫn serve.
		// Log warning ở main.go và tiếp tục.
		return &TracerProvider{provider: noopTracerProvider(serviceName, version)}, nil
	}

	exporter, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithGRPCConn(conn),
	)
	if err != nil {
		return nil, fmt.Errorf("otlp trace exporter: %w", err)
	}

	provider := sdktrace.NewTracerProvider(
		// Batch processor — gom trace rồi gửi, hiệu quả hơn per-span.
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(newResource(serviceName, version)),
		// Sampler: 100% local, có thể giảm ở production
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)

	// Gắn global tracer và propagator (W3C TraceContext + Baggage)
	// Propagator quan trọng: đảm bảo trace_id được truyền qua HTTP header
	// giữa các service. Không set propagator → distributed trace bị đứt đoạn.
	otel.SetTracerProvider(provider)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	return &TracerProvider{provider: provider}, nil
}

// Shutdown flush trace còn trong buffer trước khi exit.
func (tp *TracerProvider) Shutdown(ctx context.Context) error {
	return tp.provider.Shutdown(ctx)
}

// newResource tạo OTel Resource với service metadata.
// Resource là tập attribute mô tả *nguồn gốc* của telemetry (service gì, version nào).
func newResource(serviceName, version string) *sdkresource.Resource {
	r, _ := sdkresource.Merge(
		sdkresource.Default(),
		sdkresource.NewWithAttributes(
			semconv.SchemaURL,
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion(version),
			semconv.DeploymentEnvironment(getEnvOrDefault("APP_ENV", "development")),
		),
	)
	return r
}

// noopTracerProvider trả provider không export trace — dùng khi Collector không có.
func noopTracerProvider(serviceName, version string) *sdktrace.TracerProvider {
	return sdktrace.NewTracerProvider(
		sdktrace.WithSampler(sdktrace.NeverSample()),
		sdktrace.WithResource(newResource(serviceName, version)),
	)
}

func getEnvOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

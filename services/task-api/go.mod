module github.com/taskr/task-api

go 1.22

require (
	// HTTP router
	github.com/go-chi/chi/v5 v5.1.0

	// UUID
	github.com/google/uuid v1.6.0

	// Structured logging
	github.com/rs/zerolog v1.33.0

	// ─── Phase 2: Observability ───

	// Prometheus client — expose /metrics
	github.com/prometheus/client_golang v1.20.0

	// OTel API + SDK
	go.opentelemetry.io/otel v1.30.0
	go.opentelemetry.io/otel/metric v1.30.0
	go.opentelemetry.io/otel/sdk v1.30.0
	go.opentelemetry.io/otel/sdk/metric v1.30.0

	// OTel exporters
	go.opentelemetry.io/otel/exporters/prometheus v0.52.0
	go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.30.0

	// OTel HTTP instrumentation (auto-instrument chi router)
	go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.56.0

	// OTel resource semantic conventions
	go.opentelemetry.io/otel/semconv/v1.26.0 v1.26.0

	// gRPC transport cho OTLP exporter
	google.golang.org/grpc v1.67.0
)

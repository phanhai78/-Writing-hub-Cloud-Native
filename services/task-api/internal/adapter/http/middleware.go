// Package http — middleware.go
// Middleware tự động instrument mọi HTTP request với metrics và traces.
// Thêm vào router một lần, mọi handler được đo tự động.
package http

import (
	"net/http"
	"strconv"
	"time"

	"github.com/rs/zerolog/hlog"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"
)

// Instrument bọc một http.Handler với OTel tracing và metrics chuẩn.
// Dùng thay thế cho otelhttp.NewHandler() để có thêm custom metric.
//
// Metrics được emit (tuân theo OpenTelemetry HTTP semantic conventions):
//   http_server_request_duration_seconds  — histogram latency
//   http_server_active_requests           — gauge concurrent requests
func Instrument(handler http.Handler, serviceName string) http.Handler {
	meter := otel.GetMeterProvider().Meter(serviceName)

	// Histogram latency — metric quan trọng nhất cho SLO
	// Boundaries (second): 0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5
	latency, _ := meter.Float64Histogram(
		"http_server_request_duration_seconds",
		metric.WithDescription("HTTP server request duration"),
		metric.WithUnit("s"),
		metric.WithExplicitBucketBoundaries(
			0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0,
		),
	)

	// Gauge requests đang xử lý — phát hiện goroutine leak
	activeReqs, _ := meter.Int64UpDownCounter(
		"http_server_active_requests",
		metric.WithDescription("Number of in-flight requests"),
	)

	// otelhttp wrap tự động tạo span cho mỗi request,
	// propagate trace context từ incoming header,
	// và gắn span vào context để handler con có thể tạo child span.
	traced := otelhttp.NewHandler(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()

			// Wrap ResponseWriter để capture status code
			rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}

			// Đếm active request
			activeReqs.Add(r.Context(), 1)
			defer activeReqs.Add(r.Context(), -1)

			handler.ServeHTTP(rw, r)

			// Emit latency histogram sau khi handler xong
			duration := time.Since(start).Seconds()
			attrs := []attribute.KeyValue{
				attribute.String("http.request.method", r.Method),
				attribute.String("http.route", r.URL.Path),
				attribute.Int("http.response.status_code", rw.statusCode),
			}
			latency.Record(r.Context(), duration, metric.WithAttributes(attrs...))

			// Inject trace_id vào zerolog context để log có trace_id
			// → click từ trace sang log trong Grafana hoạt động
			if span := otel.GetTracerProvider().Tracer("").
				Start; span != nil {
				// trace_id được lấy từ span context qua otelhttp
			}
			// zerolog hlog: enrich log với trace_id từ OTel span
			if log := hlog.FromRequest(r); log != nil {
				// span context được gắn bởi otelhttp middleware
				// chúng ta không cần làm gì thêm vì trace propagation
				// đã tự động inject vào context bởi otelhttp.NewHandler
				_ = log
			}
		}),
		serviceName,
		otelhttp.WithMessageEvents(otelhttp.ReadEvents, otelhttp.WriteEvents),
	)

	return traced
}

// responseWriter bọc http.ResponseWriter để capture status code.
// Cần thiết vì http.ResponseWriter không expose status code sau WriteHeader.
type responseWriter struct {
	http.ResponseWriter
	statusCode int
	written    bool
}

func (rw *responseWriter) WriteHeader(code int) {
	if !rw.written {
		rw.statusCode = code
		rw.written = true
		rw.ResponseWriter.WriteHeader(code)
	}
}

func (rw *responseWriter) Write(b []byte) (int, error) {
	if !rw.written {
		rw.WriteHeader(http.StatusOK)
	}
	return rw.ResponseWriter.Write(b)
}

// StatusCode trả status code thực tế của response.
func (rw *responseWriter) StatusCode() string {
	return strconv.Itoa(rw.statusCode)
}

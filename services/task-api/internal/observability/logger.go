// Package observability tập trung code setup cho logging, metrics, và tracing.
// Tách ra khỏi main.go để main gọn và từng concern có thể test độc lập.
package observability

import (
	"os"
	"strings"

	"github.com/rs/zerolog"
)

// NewLogger tạo zerolog.Logger với format phù hợp môi trường.
//
//   - "production" hoặc "staging": JSON format, output stdout, gắn sẵn fields
//     service + version. Loki/Fluent Bit sẽ index các field này.
//   - "development": console format (màu, human-readable) cho dev dễ đọc.
//
// Level control qua env LOG_LEVEL: debug, info, warn, error (default: info).
//
// Nguyên tắc: logger KHÔNG BAO GIỜ fatal hay panic — chỉ log. Caller quyết định
// có exit hay không. Logger fatal bên trong library là code smell nghiêm trọng.
func NewLogger(env, serviceName, version string) zerolog.Logger {
	// Parse level từ env. Default "info" — không quá verbose, không quá quiet.
	level, err := zerolog.ParseLevel(strings.ToLower(os.Getenv("LOG_LEVEL")))
	if err != nil || level == zerolog.NoLevel {
		level = zerolog.InfoLevel
	}
	zerolog.SetGlobalLevel(level)

	// Thời gian dùng Unix timestamp với microsecond precision.
	// Rất gọn khi log, dễ index, và đủ chính xác cho mọi use case.
	zerolog.TimeFieldFormat = zerolog.TimeFormatUnixMs

	var logger zerolog.Logger

	if env == "development" {
		// ConsoleWriter format đẹp cho local: màu, timestamp human-readable.
		logger = zerolog.New(zerolog.ConsoleWriter{
			Out:        os.Stdout,
			TimeFormat: "15:04:05",
		}).With().Timestamp().Logger()
	} else {
		// JSON format cho mọi environment khác — machine-readable, Loki/ES index được.
		logger = zerolog.New(os.Stdout).With().Timestamp().Logger()
	}

	// Gắn field thường trực vào logger. Các field này có mặt trong MỌI log line,
	// giúp query theo service/version dễ dàng.
	return logger.With().
		Str("service", serviceName).
		Str("version", version).
		Str("env", env).
		Logger()
}

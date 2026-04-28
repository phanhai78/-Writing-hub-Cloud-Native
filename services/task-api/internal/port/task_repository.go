// Package port định nghĩa các interface mà domain cần từ bên ngoài.
// "Port" là thuật ngữ từ hexagonal architecture — domain "mở cổng" và adapter
// "cắm vào cổng đó". Điều này cho phép swap implementation (memory, postgres,
// mongodb, ...) mà không chạm vào domain.
//
// QUAN TRỌNG: Port được định nghĩa THEO NHU CẦU của domain, không theo
// capability của database. Nếu repository có method "RawSQL()", đó là leak
// infrastructure vào domain — anti-pattern cần tránh.
package port

import (
	"context"

	"github.com/taskr/task-api/internal/domain"
)

// TaskRepository định nghĩa hợp đồng lưu trữ Task. Mọi method nhận context
// đầu tiên để cho phép cancellation, timeout, tracing propagation — đây là
// idiom Go đã trở thành chuẩn không viết thì thiếu chuyên nghiệp.
//
// Lưu ý: interface này NHỎ (chỉ 5 method). Nguyên tắc "Interface Segregation"
// của SOLID: interface lớn khó implement và khó mock. Khi cần thêm chức năng
// như bulk insert hoặc search phức tạp, tạo interface mới chuyên biệt.
type TaskRepository interface {
	// Save tạo mới hoặc cập nhật task. Upsert semantics để interface đơn giản;
	// implementation có thể phân biệt bên trong nếu cần (ví dụ INSERT vs UPDATE).
	Save(ctx context.Context, task *domain.Task) error

	// FindByID trả về task theo ID. Trả domain.ErrTaskNotFound nếu không tìm thấy
	// (không trả về nil, nil — ambiguous). Pattern Go idiomatic: err != nil = lỗi,
	// thay vì sentinel value.
	FindByID(ctx context.Context, id string) (*domain.Task, error)

	// FindAll trả về tất cả task. Ở phiên bản sau sẽ cần pagination, filter,
	// sort — nhưng YAGNI, chưa cần thì chưa thêm.
	FindAll(ctx context.Context) ([]*domain.Task, error)

	// Delete xóa task theo ID. Trả domain.ErrTaskNotFound nếu không tìm thấy
	// để client biết yêu cầu không idempotent.
	Delete(ctx context.Context, id string) error

	// Count đếm tổng số task — dùng cho metric và health check.
	Count(ctx context.Context) (int, error)
}

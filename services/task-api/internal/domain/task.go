// Package domain chứa entity Task và business rules thuần túy. Package này
// KHÔNG import bất kỳ thứ gì liên quan đến HTTP, database, hay framework ngoài.
// Nhờ vậy, domain có thể được test độc lập và tái sử dụng ở bất kỳ context nào
// (CLI, HTTP API, message consumer, batch job, ...).
//
// Đây là trái tim của hexagonal architecture: domain ở giữa, adapters bao quanh.
package domain

import (
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
)

// Status biểu diễn trạng thái của một Task. Dùng kiểu string thay vì int
// để log và debug dễ đọc — tradeoff: nhiều byte hơn, nhưng đáng giá.
type Status string

const (
	StatusTodo       Status = "todo"
	StatusInProgress Status = "in_progress"
	StatusDone       Status = "done"
)

// IsValid trả về true nếu status nằm trong tập giá trị cho phép.
// Validator này nằm ở domain vì "một status hợp lệ là gì" là câu hỏi
// business, không phải câu hỏi kỹ thuật.
func (s Status) IsValid() bool {
	switch s {
	case StatusTodo, StatusInProgress, StatusDone:
		return true
	default:
		return false
	}
}

// Sentinel errors — được export để tầng adapter có thể kiểm tra và
// chuyển sang HTTP status code phù hợp (404, 400, ...).
// Pattern errors.Is() của Go dùng các biến này để so sánh.
var (
	ErrTaskNotFound    = errors.New("task not found")
	ErrInvalidTitle    = errors.New("title must be between 1 and 200 characters")
	ErrInvalidStatus   = errors.New("status must be one of: todo, in_progress, done")
	ErrTitleTooLong    = errors.New("title too long")
)

// Task là entity trung tâm của domain. Các field đều PRIVATE (chữ thường)
// để buộc mọi thao tác đi qua method, đảm bảo invariant luôn được duy trì.
// Đây là nguyên tắc encapsulation cổ điển nhưng thường bị bỏ qua trong Go.
type Task struct {
	id          string
	title       string
	description string
	status      Status
	createdAt   time.Time
	updatedAt   time.Time
}

// NewTask là factory function — cách DUY NHẤT để tạo một Task hợp lệ.
// Nếu input không đúng, trả error ngay thay vì trả Task "half-baked".
// Đây là pattern "parse, don't validate": không bao giờ có Task sai quy tắc
// tồn tại trong hệ thống.
func NewTask(title, description string) (*Task, error) {
	title = strings.TrimSpace(title)
	if title == "" || len(title) > 200 {
		return nil, ErrInvalidTitle
	}

	now := time.Now().UTC() // Luôn UTC ở domain, convert sang timezone ở tầng trình bày.
	return &Task{
		id:          uuid.NewString(),
		title:       title,
		description: strings.TrimSpace(description),
		status:      StatusTodo, // Task mới luôn bắt đầu ở "todo".
		createdAt:   now,
		updatedAt:   now,
	}, nil
}

// ReconstituteTask dùng khi load Task từ storage (memory, database, ...).
// Khác với NewTask ở chỗ: nhận đầy đủ field, không tạo id/timestamp mới.
// Cần thiết vì repository phải rebuild Task từ dữ liệu đã persist.
//
// Lưu ý: hàm này BYPASS validation một phần (ví dụ không check title length
// lại) vì giả định dữ liệu trong storage đã hợp lệ — nó đã đi qua NewTask
// lúc tạo. Nếu dữ liệu bị corrupt ở storage, đó là lỗi infra, không phải domain.
func ReconstituteTask(id, title, description string, status Status, createdAt, updatedAt time.Time) (*Task, error) {
	if id == "" {
		return nil, errors.New("id cannot be empty")
	}
	if _, err := uuid.Parse(id); err != nil {
		return nil, errors.New("id must be valid UUID")
	}
	if !status.IsValid() {
		return nil, ErrInvalidStatus
	}
	return &Task{
		id:          id,
		title:       title,
		description: description,
		status:      status,
		createdAt:   createdAt,
		updatedAt:   updatedAt,
	}, nil
}

// ─── Getters ───
// Go không có getter tự động như Java; phải viết tay. Một ít boilerplate
// đổi lấy encapsulation là deal tốt.

func (t *Task) ID() string             { return t.id }
func (t *Task) Title() string          { return t.title }
func (t *Task) Description() string    { return t.description }
func (t *Task) Status() Status         { return t.status }
func (t *Task) CreatedAt() time.Time   { return t.createdAt }
func (t *Task) UpdatedAt() time.Time   { return t.updatedAt }

// ─── Behaviors ───
// Đây là nơi business rules được code hóa. Các method dưới đây là "verb"
// mà một Task có thể thực hiện. Tên method dùng imperative voice:
// task.Start(), task.Complete(), không phải task.SetStatus(inProgress).
// Lý do: verbose hơn nhưng self-documenting — code đọc như tiếng Anh.

// Start đổi trạng thái sang "in_progress". Chỉ hợp lệ khi đang "todo".
// Tại sao check state machine ở đây? Vì đây là business rule, không phải UI.
// Bất kỳ adapter nào (HTTP, CLI, event consumer) đều không thể bypass rule này.
func (t *Task) Start() error {
	if t.status != StatusTodo {
		return errors.New("can only start tasks in 'todo' status")
	}
	t.status = StatusInProgress
	t.updatedAt = time.Now().UTC()
	return nil
}

// Complete chuyển sang "done". Cho phép từ bất kỳ trạng thái nào vì
// sometimes user muốn đánh dấu hoàn thành trực tiếp mà không qua in_progress
// (ví dụ task quá nhỏ không cần track quá trình).
// Business rule này có thể thay đổi; khi đó chỉ sửa method này, không ảnh
// hưởng HTTP/DB layer.
func (t *Task) Complete() error {
	if t.status == StatusDone {
		return errors.New("task already completed")
	}
	t.status = StatusDone
	t.updatedAt = time.Now().UTC()
	return nil
}

// UpdateDetails cho phép sửa title/description. Không cho sửa status qua
// method này — status có flow riêng qua Start/Complete để đảm bảo đúng thứ tự.
func (t *Task) UpdateDetails(title, description string) error {
	title = strings.TrimSpace(title)
	if title == "" || len(title) > 200 {
		return ErrInvalidTitle
	}
	t.title = title
	t.description = strings.TrimSpace(description)
	t.updatedAt = time.Now().UTC()
	return nil
}

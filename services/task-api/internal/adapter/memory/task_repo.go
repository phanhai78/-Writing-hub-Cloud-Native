// Package memory là adapter in-memory cho TaskRepository. Dùng cho development,
// testing, và demo Phase 1. Dữ liệu mất khi process restart — chấp nhận được
// vì Phase 2 sẽ có postgres adapter thay thế.
//
// Điểm thiết kế: implementation này là thread-safe (dùng sync.RWMutex) vì
// HTTP server Go xử lý request đồng thời qua nhiều goroutine. Nếu không lock,
// concurrent Save + FindAll sẽ gây data race — bug khó debug nhất trong Go.
package memory

import (
	"context"
	"sort"
	"sync"

	"github.com/taskr/task-api/internal/domain"
	"github.com/taskr/task-api/internal/port"
)

// taskRepository là struct unexported — client bên ngoài package không
// biết đến kiểu này, chỉ thấy qua interface TaskRepository.
// Đây là pattern "return interface, accept interface" điển hình của Go.
type taskRepository struct {
	// mu bảo vệ map data. RWMutex thay vì Mutex thường vì read nhiều hơn write
	// rất nhiều (FindAll, FindByID) — nhiều read có thể chạy song song, chỉ
	// write cần exclusive lock.
	mu   sync.RWMutex
	data map[string]*domain.Task
}

// NewTaskRepository là constructor, trả về interface port.TaskRepository
// thay vì *taskRepository. Lý do: client không cần biết kiểu cụ thể,
// và chúng ta có thể swap implementation bất cứ lúc nào.
//
// Quy tắc: type unexported + constructor exported = zero-value không dùng
// được nhưng instance luôn valid. Client bắt buộc phải gọi constructor.
func NewTaskRepository() port.TaskRepository {
	return &taskRepository{
		data: make(map[string]*domain.Task),
	}
}

// Save — upsert semantics. Key là task.ID(), nếu đã tồn tại thì overwrite.
// Ở adapter postgres tương lai sẽ dùng INSERT ... ON CONFLICT DO UPDATE.
func (r *taskRepository) Save(ctx context.Context, task *domain.Task) error {
	// Respect context cancellation. Nếu client đóng kết nối giữa chừng,
	// ta không waste CPU tiếp tục — dù với memory adapter lợi ích nhỏ,
	// tính nhất quán giữa các adapter quan trọng hơn.
	if err := ctx.Err(); err != nil {
		return err
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	r.data[task.ID()] = task
	return nil
}

func (r *taskRepository) FindByID(ctx context.Context, id string) (*domain.Task, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	task, ok := r.data[id]
	if !ok {
		// Trả sentinel error từ domain package. Tầng HTTP sẽ kiểm tra bằng
		// errors.Is(err, domain.ErrTaskNotFound) để convert sang HTTP 404.
		return nil, domain.ErrTaskNotFound
	}
	return task, nil
}

func (r *taskRepository) FindAll(ctx context.Context) ([]*domain.Task, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	r.mu.RLock()
	defer r.mu.RUnlock()

	// Chú ý: tạo slice mới và copy để tránh client modify map trực tiếp
	// sau khi đã return. Đây là lỗi tinh tế rất dễ mắc.
	tasks := make([]*domain.Task, 0, len(r.data))
	for _, t := range r.data {
		tasks = append(tasks, t)
	}

	// Sort theo CreatedAt descending để UX ổn định — task mới nhất lên đầu.
	// Map trong Go không có thứ tự nên không sort thì output thay đổi mỗi lần,
	// rất khó debug và test.
	sort.Slice(tasks, func(i, j int) bool {
		return tasks[i].CreatedAt().After(tasks[j].CreatedAt())
	})

	return tasks, nil
}

func (r *taskRepository) Delete(ctx context.Context, id string) error {
	if err := ctx.Err(); err != nil {
		return err
	}

	r.mu.Lock()
	defer r.mu.Unlock()

	if _, ok := r.data[id]; !ok {
		return domain.ErrTaskNotFound
	}
	delete(r.data, id)
	return nil
}

func (r *taskRepository) Count(ctx context.Context) (int, error) {
	if err := ctx.Err(); err != nil {
		return 0, err
	}

	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.data), nil
}

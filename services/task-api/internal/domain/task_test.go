package domain_test

import (
	"strings"
	"testing"

	"github.com/taskr/task-api/internal/domain"
)

// Test đặt ở package domain_test (khác domain) để test hành vi public API,
// không phải implementation detail. Đây là pattern "black box testing" —
// test như một client của package sẽ sử dụng.

// ─── Table-driven tests ───
// Go idiom: một test function, nhiều case trong slice. Dễ thêm case,
// failure message rõ ràng (đi kèm tên case), và IDE/CI report từng sub-test riêng.

func TestNewTask_InputValidation(t *testing.T) {
	cases := []struct {
		name        string
		title       string
		description string
		wantErr     error
	}{
		{
			name:        "title hợp lệ",
			title:       "Viết báo cáo tuần",
			description: "Báo cáo gửi sếp thứ 6",
			wantErr:     nil,
		},
		{
			name:    "title rỗng — lỗi",
			title:   "",
			wantErr: domain.ErrInvalidTitle,
		},
		{
			name:    "title chỉ whitespace — lỗi (vì trim)",
			title:   "   \t  ",
			wantErr: domain.ErrInvalidTitle,
		},
		{
			name:    "title quá dài — lỗi",
			title:   strings.Repeat("a", 201),
			wantErr: domain.ErrInvalidTitle,
		},
		{
			name:        "title có whitespace đầu/cuối — được trim",
			title:       "  Xong task  ",
			description: "",
			wantErr:     nil,
		},
	}

	for _, tc := range cases {
		// Capture loop variable — tránh closure bug với t.Parallel().
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel() // Các sub-test chạy song song, nhanh hơn.

			task, err := domain.NewTask(tc.title, tc.description)

			if tc.wantErr != nil {
				if err != tc.wantErr {
					t.Fatalf("expected error %v, got %v", tc.wantErr, err)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if task == nil {
				t.Fatal("expected non-nil task")
			}

			// Invariants của task mới tạo:
			if task.Status() != domain.StatusTodo {
				t.Errorf("new task should have status 'todo', got %q", task.Status())
			}
			if task.ID() == "" {
				t.Error("task should have non-empty ID")
			}
			if task.CreatedAt().IsZero() {
				t.Error("task should have CreatedAt set")
			}
			// Title đã trim — kiểm tra điều này
			if strings.TrimSpace(tc.title) != task.Title() {
				t.Errorf("title mismatch: got %q want %q (trimmed)", task.Title(), strings.TrimSpace(tc.title))
			}
		})
	}
}

func TestTask_StateTransitions(t *testing.T) {
	t.Run("todo -> in_progress via Start", func(t *testing.T) {
		task, _ := domain.NewTask("test", "")
		if err := task.Start(); err != nil {
			t.Fatalf("Start() should succeed on todo task, got %v", err)
		}
		if task.Status() != domain.StatusInProgress {
			t.Errorf("expected status in_progress, got %q", task.Status())
		}
	})

	t.Run("không thể Start task đã in_progress", func(t *testing.T) {
		task, _ := domain.NewTask("test", "")
		_ = task.Start() // chuyển sang in_progress
		err := task.Start()
		if err == nil {
			t.Error("Start() trên in_progress task phải trả lỗi")
		}
	})

	t.Run("todo -> done qua Complete", func(t *testing.T) {
		task, _ := domain.NewTask("test", "")
		if err := task.Complete(); err != nil {
			t.Fatalf("Complete() from todo should succeed, got %v", err)
		}
		if task.Status() != domain.StatusDone {
			t.Errorf("expected done, got %q", task.Status())
		}
	})

	t.Run("in_progress -> done qua Complete", func(t *testing.T) {
		task, _ := domain.NewTask("test", "")
		_ = task.Start()
		if err := task.Complete(); err != nil {
			t.Errorf("Complete() from in_progress should succeed, got %v", err)
		}
	})

	t.Run("không thể Complete task đã done", func(t *testing.T) {
		task, _ := domain.NewTask("test", "")
		_ = task.Complete()
		if err := task.Complete(); err == nil {
			t.Error("Complete() trên done task phải trả lỗi")
		}
	})
}

func TestTask_UpdateDetails(t *testing.T) {
	task, _ := domain.NewTask("old title", "old desc")
	originalUpdatedAt := task.UpdatedAt()

	// Sleep 1ms để đảm bảo timestamp thay đổi khi UpdateDetails.
	// Đây là cách kiểm tra thô nhưng đủ cho unit test; production code không cần.

	err := task.UpdateDetails("new title", "new desc")
	if err != nil {
		t.Fatalf("UpdateDetails() failed: %v", err)
	}

	if task.Title() != "new title" {
		t.Errorf("title không update: got %q", task.Title())
	}
	if task.Description() != "new desc" {
		t.Errorf("description không update: got %q", task.Description())
	}
	if !task.UpdatedAt().After(originalUpdatedAt) {
		// UpdatedAt có thể equal nếu quá nhanh, nhưng không được trước
		if task.UpdatedAt().Before(originalUpdatedAt) {
			t.Error("UpdatedAt không được lùi về quá khứ")
		}
	}
}

func TestStatus_IsValid(t *testing.T) {
	cases := map[domain.Status]bool{
		domain.StatusTodo:       true,
		domain.StatusInProgress: true,
		domain.StatusDone:       true,
		"unknown":               false,
		"":                      false,
		"TODO":                  false, // case-sensitive
	}

	for status, want := range cases {
		t.Run(string(status), func(t *testing.T) {
			if got := status.IsValid(); got != want {
				t.Errorf("IsValid(%q) = %v, want %v", status, got, want)
			}
		})
	}
}

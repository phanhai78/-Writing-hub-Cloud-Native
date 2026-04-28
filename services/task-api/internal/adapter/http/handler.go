// Package http là adapter HTTP cho task-api. Nó dịch giữa giao thức HTTP/JSON
// và domain. Handler KHÔNG chứa business logic — mọi quyết định nghiệp vụ
// phải gọi xuống domain.
package http

import (
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/rs/zerolog"

	"github.com/taskr/task-api/internal/domain"
	"github.com/taskr/task-api/internal/port"
)

// ─── Data Transfer Objects (DTOs) ───
// DTO là cấu trúc dữ liệu riêng cho tầng HTTP, TÁCH BIỆT với domain.Task.
// Lý do: domain.Task có thể thay đổi trong khi API contract phải ổn định
// (backward compatible). Nếu dùng chung struct, một thay đổi domain sẽ
// accidentally break API — lỗi thường gặp nhất.

// CreateTaskRequest là payload POST /tasks. Các JSON tag quy định tên field
// trên wire. Pointer cho "description" để phân biệt "không gửi" (nil) vs
// "gửi chuỗi rỗng" (con trỏ tới "").
type CreateTaskRequest struct {
	Title       string `json:"title"`
	Description string `json:"description"`
}

// UpdateTaskRequest cho PATCH /tasks/{id}. Dùng pointer để client chỉ gửi
// field muốn update, các field nil không thay đổi. Đây là pattern "sparse
// update" chuẩn cho REST.
type UpdateTaskRequest struct {
	Title       *string `json:"title,omitempty"`
	Description *string `json:"description,omitempty"`
	Action      *string `json:"action,omitempty"` // "start" hoặc "complete"
}

// TaskResponse là response DTO. Tất cả field exported để JSON encoder serialize.
// Thời gian format RFC3339 (ISO 8601) — chuẩn de facto cho API hiện đại.
type TaskResponse struct {
	ID          string    `json:"id"`
	Title       string    `json:"title"`
	Description string    `json:"description"`
	Status      string    `json:"status"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// toTaskResponse chuyển domain.Task sang TaskResponse. Hàm này là ranh giới
// rõ ràng giữa domain và transport layer.
func toTaskResponse(t *domain.Task) TaskResponse {
	return TaskResponse{
		ID:          t.ID(),
		Title:       t.Title(),
		Description: t.Description(),
		Status:      string(t.Status()),
		CreatedAt:   t.CreatedAt(),
		UpdatedAt:   t.UpdatedAt(),
	}
}

// ErrorResponse là format lỗi chuẩn hóa. Mọi lỗi từ API đều theo format này
// để client parse dễ. "code" là string ổn định (client code có thể switch/case),
// "message" là human-readable có thể thay đổi.
type ErrorResponse struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// ─── Handler ───
// Handler giữ dependency (repository, logger) như field của struct. Khởi tạo
// một lần ở main, reuse cho mọi request. Đây là pattern "constructor injection"
// — test rất dễ vì có thể inject mock repository.

type Handler struct {
	repo   port.TaskRepository
	logger zerolog.Logger
}

func NewHandler(repo port.TaskRepository, logger zerolog.Logger) *Handler {
	return &Handler{repo: repo, logger: logger}
}

// ─── Helper functions ───
// Tách helper ra ngoài method vì chúng không cần state của Handler.

// writeJSON serialize data và set header chuẩn. Gộp logic trùng lặp
// thành một chỗ — nếu cần thêm header (như X-Request-ID) chỉ sửa một chỗ.
func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	// Bỏ qua lỗi Encode vì header đã ghi, không làm gì được nữa.
	// Log ở middleware để track pattern lỗi.
	_ = json.NewEncoder(w).Encode(data)
}

// writeError map domain error sang HTTP status code đúng chuẩn. Đây là
// điểm mấu chốt của adapter — domain nói "not found", HTTP nói "404".
func writeError(w http.ResponseWriter, err error) {
	switch {
	case errors.Is(err, domain.ErrTaskNotFound):
		writeJSON(w, http.StatusNotFound, ErrorResponse{
			Code:    "task_not_found",
			Message: err.Error(),
		})
	case errors.Is(err, domain.ErrInvalidTitle),
		errors.Is(err, domain.ErrInvalidStatus):
		writeJSON(w, http.StatusBadRequest, ErrorResponse{
			Code:    "invalid_input",
			Message: err.Error(),
		})
	default:
		// Unknown error — không expose message ra client (có thể leak info
		// nhạy cảm). Log chi tiết ở server side để debug.
		writeJSON(w, http.StatusInternalServerError, ErrorResponse{
			Code:    "internal_error",
			Message: "an unexpected error occurred",
		})
	}
}

// ─── HTTP Handlers ───
// Mỗi method handle một endpoint. Các method này tuân theo pattern:
//   1. Parse và validate input
//   2. Gọi domain method
//   3. Map response hoặc error

// CreateTask POST /tasks
func (h *Handler) CreateTask(w http.ResponseWriter, r *http.Request) {
	var req CreateTaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{
			Code:    "invalid_json",
			Message: "request body is not valid JSON",
		})
		return
	}

	task, err := domain.NewTask(req.Title, req.Description)
	if err != nil {
		writeError(w, err)
		return
	}

	if err := h.repo.Save(r.Context(), task); err != nil {
		// Log với context để dễ correlate. zerolog dùng structured fields.
		h.logger.Error().Err(err).Str("task_id", task.ID()).Msg("failed to save task")
		writeError(w, err)
		return
	}

	writeJSON(w, http.StatusCreated, toTaskResponse(task))
}

// GetTask GET /tasks/{id}
func (h *Handler) GetTask(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	task, err := h.repo.FindByID(r.Context(), id)
	if err != nil {
		writeError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, toTaskResponse(task))
}

// ListTasks GET /tasks
func (h *Handler) ListTasks(w http.ResponseWriter, r *http.Request) {
	tasks, err := h.repo.FindAll(r.Context())
	if err != nil {
		h.logger.Error().Err(err).Msg("failed to list tasks")
		writeError(w, err)
		return
	}

	responses := make([]TaskResponse, 0, len(tasks))
	for _, t := range tasks {
		responses = append(responses, toTaskResponse(t))
	}

	// Wrap array trong object { "items": [...] } thay vì trả array trực tiếp.
	// Lý do: dễ thêm metadata (total, page, ...) sau này mà không break API.
	writeJSON(w, http.StatusOK, map[string]interface{}{
		"items": responses,
		"total": len(responses),
	})
}

// UpdateTask PATCH /tasks/{id}
func (h *Handler) UpdateTask(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	var req UpdateTaskRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, ErrorResponse{
			Code:    "invalid_json",
			Message: "request body is not valid JSON",
		})
		return
	}

	task, err := h.repo.FindByID(r.Context(), id)
	if err != nil {
		writeError(w, err)
		return
	}

	// Áp dụng partial update. Thứ tự: trạng thái trước (qua action), nội dung sau.
	// Nếu action fail, không update nội dung — giữ tính atomic ở logic level.
	if req.Action != nil {
		var actionErr error
		switch *req.Action {
		case "start":
			actionErr = task.Start()
		case "complete":
			actionErr = task.Complete()
		default:
			writeJSON(w, http.StatusBadRequest, ErrorResponse{
				Code:    "invalid_action",
				Message: "action must be 'start' or 'complete'",
			})
			return
		}
		if actionErr != nil {
			writeJSON(w, http.StatusConflict, ErrorResponse{
				Code:    "invalid_state_transition",
				Message: actionErr.Error(),
			})
			return
		}
	}

	if req.Title != nil || req.Description != nil {
		newTitle := task.Title()
		newDesc := task.Description()
		if req.Title != nil {
			newTitle = *req.Title
		}
		if req.Description != nil {
			newDesc = *req.Description
		}
		if err := task.UpdateDetails(newTitle, newDesc); err != nil {
			writeError(w, err)
			return
		}
	}

	if err := h.repo.Save(r.Context(), task); err != nil {
		h.logger.Error().Err(err).Str("task_id", id).Msg("failed to save updated task")
		writeError(w, err)
		return
	}

	writeJSON(w, http.StatusOK, toTaskResponse(task))
}

// DeleteTask DELETE /tasks/{id}
func (h *Handler) DeleteTask(w http.ResponseWriter, r *http.Request) {
	id := chi.URLParam(r, "id")

	if err := h.repo.Delete(r.Context(), id); err != nil {
		writeError(w, err)
		return
	}

	// 204 No Content — REST convention cho DELETE thành công không trả body.
	w.WriteHeader(http.StatusNoContent)
}

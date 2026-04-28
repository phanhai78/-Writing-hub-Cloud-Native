// Package postgres — adapter PostgreSQL cho TaskRepository.
// Triết lý: domain/port không đổi. Chỉ thêm file này, swap trong main.go.
// Hexagonal architecture payoff: bạn thấy ngay ở đây.
package postgres

import (
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/taskr/task-api/internal/domain"
	"github.com/taskr/task-api/internal/port"
)

// taskRepository implement port.TaskRepository với pgx connection pool.
type taskRepository struct {
	pool *pgxpool.Pool
}

// NewTaskRepository tạo adapter PostgreSQL.
// dsn format: postgres://user:pass@host:5432/dbname?sslmode=require
func NewTaskRepository(ctx context.Context, dsn string) (port.TaskRepository, error) {
	config, err := pgxpool.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("parse DSN: %w", err)
	}

	// Connection pool config tối ưu cho service nhỏ
	config.MaxConns = 10
	config.MinConns = 2

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("create pool: %w", err)
	}

	// Ping để phát hiện lỗi config ngay lúc start
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}

	return &taskRepository{pool: pool}, nil
}

// Close đóng connection pool — gọi trong graceful shutdown.
func (r *taskRepository) Close() {
	r.pool.Close()
}

func (r *taskRepository) Save(ctx context.Context, task *domain.Task) error {
	// Upsert: insert hoặc update nếu id đã tồn tại.
	// ON CONFLICT DO UPDATE đảm bảo idempotent — gọi nhiều lần với cùng task an toàn.
	_, err := r.pool.Exec(ctx, `
		INSERT INTO tasks (id, title, description, status, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, $6)
		ON CONFLICT (id) DO UPDATE SET
			title       = EXCLUDED.title,
			description = EXCLUDED.description,
			status      = EXCLUDED.status,
			updated_at  = EXCLUDED.updated_at
	`,
		task.ID(),
		task.Title(),
		task.Description(),
		string(task.Status()),
		task.CreatedAt(),
		task.UpdatedAt(),
	)
	if err != nil {
		return fmt.Errorf("save task: %w", err)
	}
	return nil
}

func (r *taskRepository) FindByID(ctx context.Context, id string) (*domain.Task, error) {
	row := r.pool.QueryRow(ctx, `
		SELECT id, title, description, status, created_at, updated_at
		FROM tasks WHERE id = $1
	`, id)

	return scanTask(row)
}

func (r *taskRepository) FindAll(ctx context.Context) ([]*domain.Task, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, title, description, status, created_at, updated_at
		FROM tasks ORDER BY created_at DESC
	`)
	if err != nil {
		return nil, fmt.Errorf("query tasks: %w", err)
	}
	defer rows.Close()

	var tasks []*domain.Task
	for rows.Next() {
		task, err := scanTask(rows)
		if err != nil {
			return nil, err
		}
		tasks = append(tasks, task)
	}
	return tasks, rows.Err()
}

func (r *taskRepository) Delete(ctx context.Context, id string) error {
	result, err := r.pool.Exec(ctx, `DELETE FROM tasks WHERE id = $1`, id)
	if err != nil {
		return fmt.Errorf("delete task: %w", err)
	}
	if result.RowsAffected() == 0 {
		return domain.ErrTaskNotFound
	}
	return nil
}

func (r *taskRepository) Count(ctx context.Context) (int, error) {
	var count int
	err := r.pool.QueryRow(ctx, `SELECT COUNT(*) FROM tasks`).Scan(&count)
	return count, err
}

// scanTask đọc một row và reconstruct domain.Task.
// Dùng interface để work với cả pgx.Row và pgx.Rows.
func scanTask(row interface {
	Scan(...any) error
}) (*domain.Task, error) {
	var (
		id, title, description, status string
		createdAt, updatedAt           interface{}
	)

	// pgx tự convert timestamp PostgreSQL sang time.Time nếu dùng time.Time trực tiếp.
	// Dùng interface{} để tránh phụ thuộc vào pgtype package ở tầng domain.
	var tCreated, tUpdated interface{}
	err := row.Scan(&id, &title, &description, &status, &tCreated, &tUpdated)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, domain.ErrTaskNotFound
		}
		return nil, fmt.Errorf("scan task: %w", err)
	}

	_ = createdAt
	_ = updatedAt

	// Parse time — pgx trả về time.Time cho timestamp columns
	import "time"
	var ct, ut time.Time
	if t, ok := tCreated.(time.Time); ok {
		ct = t
	}
	if t, ok := tUpdated.(time.Time); ok {
		ut = t
	}

	return domain.ReconstituteTask(id, title, description, domain.Status(status), ct, ut)
}

-- migrations/001_create_tasks.up.sql
-- Chạy bằng golang-migrate:
--   migrate -path ./migrations -database "postgres://..." up

CREATE TABLE IF NOT EXISTS tasks (
    id          UUID PRIMARY KEY,
    title       VARCHAR(200) NOT NULL CHECK (length(trim(title)) > 0),
    description TEXT         NOT NULL DEFAULT '',
    status      VARCHAR(20)  NOT NULL DEFAULT 'todo'
                             CHECK (status IN ('todo', 'in_progress', 'done')),
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

-- Index cho query ORDER BY created_at DESC (FindAll)
CREATE INDEX IF NOT EXISTS idx_tasks_created_at ON tasks (created_at DESC);

-- Index cho status filter (Phase 5+ khi thêm filter API)
CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks (status);

COMMENT ON TABLE tasks IS 'Task entity table — managed by task-api service';

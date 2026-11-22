-- +goose Up
-- Workspace-level concurrency settings for in-turn MCP subagents (run_subagent)
-- and parallel delegated child runs (delegate).
ALTER TABLE workspaces
  ADD COLUMN max_concurrent_subagents integer NOT NULL DEFAULT 3 CHECK (max_concurrent_subagents BETWEEN 1 AND 16),
  ADD COLUMN max_parallel_delegations integer NOT NULL DEFAULT 3 CHECK (max_parallel_delegations BETWEEN 1 AND 8);

-- +goose Down
ALTER TABLE workspaces
  DROP COLUMN max_parallel_delegations,
  DROP COLUMN max_concurrent_subagents;

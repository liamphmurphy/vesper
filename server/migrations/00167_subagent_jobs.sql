-- +goose Up
-- Ephemeral in-turn explorer/helper subagent jobs queued via Vesper MCP run_subagent.
CREATE TABLE subagent_jobs (
  id             uuid PRIMARY KEY DEFAULT uuid_v7(),
  run_id         uuid NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  agent_type     text NOT NULL CHECK (agent_type IN ('explorer', 'helper')),
  role           text NOT NULL DEFAULT '',
  prompt         text NOT NULL,
  status         text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued', 'running', 'completed', 'failed', 'canceled')),
  result_text    text NOT NULL DEFAULT '',
  error          text NOT NULL DEFAULT '',
  input_tokens   bigint NOT NULL DEFAULT 0,
  output_tokens  bigint NOT NULL DEFAULT 0,
  cached_tokens  bigint NOT NULL DEFAULT 0,
  cost_usd       double precision,
  tool_calls     integer NOT NULL DEFAULT 0,
  created_at     timestamptz NOT NULL DEFAULT now(),
  started_at     timestamptz,
  completed_at   timestamptz
);

CREATE INDEX subagent_jobs_run_status_idx ON subagent_jobs (run_id, status, created_at);

-- +goose Down
DROP INDEX IF EXISTS subagent_jobs_run_status_idx;
DROP TABLE IF EXISTS subagent_jobs;

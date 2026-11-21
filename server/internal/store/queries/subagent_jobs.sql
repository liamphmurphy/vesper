-- name: CreateSubagentJob :one
INSERT INTO subagent_jobs (run_id, agent_type, role, prompt)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetSubagentJob :one
SELECT * FROM subagent_jobs WHERE id = $1;

-- name: ClaimNextSubagentJob :one
WITH next_job AS (
  SELECT sj.id FROM subagent_jobs sj
  WHERE sj.run_id = sqlc.arg(run_id) AND sj.status = 'queued'
  ORDER BY sj.created_at, sj.id
  FOR UPDATE OF sj SKIP LOCKED
  LIMIT 1
)
UPDATE subagent_jobs j
SET status = 'running', started_at = now()
FROM next_job
WHERE j.id = next_job.id
RETURNING j.*;

-- name: CompleteSubagentJob :exec
UPDATE subagent_jobs
SET status = 'completed',
    result_text = sqlc.arg(result_text),
    input_tokens = sqlc.arg(input_tokens),
    output_tokens = sqlc.arg(output_tokens),
    cached_tokens = sqlc.arg(cached_tokens),
    cost_usd = sqlc.narg(cost_usd),
    tool_calls = sqlc.arg(tool_calls),
    completed_at = now()
WHERE id = sqlc.arg(id);

-- name: FailSubagentJob :exec
UPDATE subagent_jobs
SET status = 'failed',
    error = sqlc.arg(error),
    input_tokens = sqlc.arg(input_tokens),
    output_tokens = sqlc.arg(output_tokens),
    cached_tokens = sqlc.arg(cached_tokens),
    cost_usd = sqlc.narg(cost_usd),
    tool_calls = sqlc.arg(tool_calls),
    completed_at = now()
WHERE id = sqlc.arg(id);

-- name: CancelPendingSubagentJobsForRun :exec
UPDATE subagent_jobs
SET status = 'canceled',
    error = sqlc.arg(error),
    completed_at = now()
WHERE run_id = sqlc.arg(run_id) AND status IN ('queued', 'running');

-- name: ListSubagentJobsForRun :many
SELECT * FROM subagent_jobs WHERE run_id = $1 ORDER BY created_at, id;

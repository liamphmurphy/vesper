-- Scheduled tasks are private to one person.

-- name: CreateScheduledTask :one
INSERT INTO scheduled_tasks (workspace_id, user_id, name, kind, instructions, workflow_id, persona_id, project_id, connector_ids, custom_app_id, custom_app_tool, custom_app_args, frequency, weekdays, month_day, at_time, timezone, cron, enabled, max_minutes, max_cost_micros, next_run_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, $22) RETURNING *;

-- name: UpdateScheduledTask :one
-- Returns no row when the revision is stale.
UPDATE scheduled_tasks SET name = $4, kind = $5, instructions = $6, workflow_id = $7, persona_id = $8, project_id = $9, connector_ids = $10, custom_app_id = $11, custom_app_tool = $12, custom_app_args = $13, frequency = $14, weekdays = $15, month_day = $16, at_time = $17, timezone = $18, cron = $19, enabled = $20, max_minutes = $21, max_cost_micros = $22, next_run_at = $23, revision = revision + 1, updated_at = now()
WHERE id = $1 AND workspace_id = $2 AND revision = $3 RETURNING *;

-- name: ListScheduledTasks :many
SELECT * FROM scheduled_tasks WHERE workspace_id = $1 AND user_id = $2 ORDER BY created_at, id;

-- name: GetScheduledTask :one
SELECT * FROM scheduled_tasks WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: DeleteScheduledTask :execrows
DELETE FROM scheduled_tasks WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: NextDueScheduledTask :one
-- However many times a task came due while Vesper was off, it is claimed once:
-- the caller moves next_run_at past now in the same transaction.
SELECT * FROM scheduled_tasks WHERE enabled AND next_run_at <= now() ORDER BY next_run_at LIMIT 1 FOR UPDATE SKIP LOCKED;

-- name: AdvanceScheduledTask :exec
UPDATE scheduled_tasks SET next_run_at = $2 WHERE id = $1;

-- name: HasActiveScheduledRun :one
SELECT EXISTS (SELECT 1 FROM scheduled_task_runs WHERE task_id = $1 AND state IN ('running', 'waiting'))::bool;

-- name: CreateScheduledRun :one
INSERT INTO scheduled_task_runs (task_id, trigger) VALUES ($1, $2) RETURNING *;

-- name: AttachScheduledRun :exec
UPDATE scheduled_task_runs SET chat_id = $2, workflow_run_id = $3 WHERE id = $1;

-- name: ActiveScheduledRuns :many
SELECT r.*, t.workspace_id, t.user_id, t.kind, t.max_minutes, t.max_cost_micros FROM scheduled_task_runs r JOIN scheduled_tasks t ON t.id = r.task_id
WHERE r.state IN ('running', 'waiting') ORDER BY r.started_at LIMIT 200;

-- name: SetScheduledRunState :exec
UPDATE scheduled_task_runs SET state = $2 WHERE id = $1 AND state IN ('running', 'waiting');

-- name: FinishScheduledRun :exec
UPDATE scheduled_task_runs SET state = $2, summary = $3, error = $4, cost_micros = $5, finished_at = now() WHERE id = $1 AND state IN ('running', 'waiting');

-- name: RecentScheduledRuns :many
-- Each of the person's tasks' latest runs, newest first.
SELECT * FROM (
  SELECT r.*, row_number() OVER (PARTITION BY r.task_id ORDER BY r.started_at DESC, r.id DESC) AS n
  FROM scheduled_task_runs r JOIN scheduled_tasks t ON t.id = r.task_id
  WHERE t.workspace_id = $1 AND t.user_id = $2
) ranked WHERE n <= 10 ORDER BY started_at DESC, id DESC;

-- name: LastAssistantBody :one
SELECT body_md FROM chat_messages WHERE session_id = $1 AND role = 'assistant' ORDER BY seq DESC LIMIT 1;

-- name: GetWorkflowRunByID :one
SELECT * FROM workflow_runs WHERE id = $1;

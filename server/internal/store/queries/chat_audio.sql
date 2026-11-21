-- name: CreateChatAudioJob :one
INSERT INTO chat_audio_jobs (workspace_id, user_id, chat_id, run_id, turn_id, persona_id, title, duration_ms, script_path, method)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10) RETURNING *;

-- name: CountChatAudioJobsForTurn :one
SELECT count(*)::int FROM chat_audio_jobs WHERE run_id = $1 AND turn_id = $2;

-- name: LockChatAudioJob :one
-- One of a run's jobs, locked for a stage change.
SELECT * FROM chat_audio_jobs WHERE id = $1 AND run_id = $2 FOR UPDATE;

-- name: GetChatAudioJob :one
SELECT * FROM chat_audio_jobs WHERE id = $1 AND workspace_id = $2;

-- name: SetChatAudioStage :one
-- The agent moved the job on. checks, script_path and method change only when given.
UPDATE chat_audio_jobs SET stage = sqlc.arg(stage),
  checks = coalesce(sqlc.narg(checks)::jsonb, checks),
  script_path = coalesce(sqlc.narg(script_path)::text, script_path),
  method = coalesce(sqlc.narg(method)::text, method),
  updated_at = now()
WHERE id = sqlc.arg(id) AND state = 'running'
RETURNING *;

-- name: FailChatAudioJob :one
-- Ends a running job as failed at the stage it reached.
UPDATE chat_audio_jobs SET state = 'failed', error = sqlc.arg(error), failure_kind = sqlc.arg(failure_kind), error_log = sqlc.arg(error_log), updated_at = now(), finished_at = now()
WHERE id = sqlc.arg(id) AND state = 'running'
RETURNING *;

-- name: RunningChatAudioJobs :many
-- The code-rendered jobs a run is working on, oldest first.
SELECT * FROM chat_audio_jobs WHERE run_id = $1 AND state = 'running' AND source_kind = 'code' ORDER BY created_at, id;

-- name: CreateMusicAudioJob :one
INSERT INTO chat_audio_jobs (
  workspace_id, user_id, chat_id, run_id, turn_id, persona_id,
  title, duration_ms, method, stage, stage_note,
  source_kind, provider_id, prompt, lyrics, instrumental
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'compose', $10, 'music', $11, $12, $13, $14)
RETURNING *;

-- name: UpdateMusicAudioJobProgress :exec
UPDATE chat_audio_jobs SET percent = sqlc.arg(percent), stage_note = sqlc.arg(stage_note), updated_at = now()
WHERE id = sqlc.arg(id) AND state = 'running';

-- name: UpdateMusicAudioJobStage :one
UPDATE chat_audio_jobs SET stage = sqlc.arg(stage), percent = sqlc.arg(percent), stage_note = sqlc.arg(stage_note), updated_at = now()
WHERE id = sqlc.arg(id) AND state = 'running'
RETURNING *;

-- name: FailMusicAudioJob :one
UPDATE chat_audio_jobs
SET state = 'failed', error = sqlc.arg(error), failure_kind = sqlc.arg(failure_kind), error_kind = sqlc.arg(error_kind), updated_at = now(), finished_at = now()
WHERE id = sqlc.arg(id) AND state = 'running'
RETURNING *;

-- name: SetChatAudioProgress :exec
-- What the runner read from the job's progress.json (the caller skips it when
-- nothing changed: every statement notifies).
UPDATE chat_audio_jobs SET percent = sqlc.arg(percent), stage_note = sqlc.arg(stage_note), updated_at = now()
WHERE id = sqlc.arg(id) AND state = 'running';

-- name: FinishChatAudioJob :one
-- The runner stored the finished file.
UPDATE chat_audio_jobs SET state = 'done', percent = 100, output_blob_key = $2, output_filename = $3, output_content_type = $4, output_size_bytes = $5,
  output_duration_ms = $6, library_item_id = $7, updated_at = now(), finished_at = now()
WHERE id = $1 AND state = 'running'
RETURNING *;

-- name: ListChatAudioJobs :many
-- A chat's audio, oldest first.
SELECT * FROM chat_audio_jobs WHERE chat_id = $1 ORDER BY created_at, id;

-- name: LinkChatAudioJobsToMessage :exec
-- Puts a turn's audio, and the Library copies of the finished ones, on the
-- reply that turn stored.
WITH j AS (
  UPDATE chat_audio_jobs SET message_id = sqlc.arg(message_id), updated_at = now()
  WHERE run_id = sqlc.arg(run_id) AND turn_id = sqlc.arg(turn_id) AND message_id IS NULL
  RETURNING library_item_id
)
UPDATE library_items SET message_id = sqlc.arg(message_id) WHERE id IN (SELECT library_item_id FROM j WHERE library_item_id IS NOT NULL);

-- name: DeleteDetachedChatAudioJobs :many
-- Removes up to row_limit jobs whose chat is gone, returning the files only
-- they held (the Library keeps its own).
WITH j AS (
  SELECT id FROM chat_audio_jobs WHERE chat_id IS NULL AND state <> 'running'
  ORDER BY created_at LIMIT sqlc.arg(row_limit) FOR UPDATE SKIP LOCKED
), d AS (
  DELETE FROM chat_audio_jobs WHERE id IN (SELECT id FROM j) RETURNING output_blob_key
)
SELECT d.output_blob_key::text FROM d WHERE d.output_blob_key IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM library_items l WHERE l.blob_key = d.output_blob_key);

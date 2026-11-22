-- name: ListPersonaStateMedia :many
-- One persona's state loops, in state order.
SELECT m.* FROM persona_state_media m
JOIN personas p ON p.id = m.persona_id
WHERE m.persona_id = sqlc.arg(persona_id) AND p.workspace_id = sqlc.arg(workspace_id) AND p.user_id = sqlc.arg(user_id)
ORDER BY array_position(ARRAY['idle', 'thinking', 'reading', 'coding', 'creating', 'needs_you'], m.state);

-- name: ListPersonasStateMedia :many
-- The state loops of several personas, for rendering a persona list.
SELECT * FROM persona_state_media WHERE persona_id = ANY(sqlc.arg(persona_ids)::uuid[]);

-- name: GetPersonaStateMedia :one
SELECT m.* FROM persona_state_media m
JOIN personas p ON p.id = m.persona_id
WHERE m.persona_id = sqlc.arg(persona_id) AND m.state = sqlc.arg(state) AND p.workspace_id = sqlc.arg(workspace_id) AND p.user_id = sqlc.arg(user_id);

-- name: LockPersonaStateMedia :many
-- Locks a persona's rows for a start or clear, so two can't race.
SELECT * FROM persona_state_media WHERE persona_id = $1 FOR UPDATE;

-- name: QueuePersonaStateMedia :one
-- Starts a new attempt for a state, keeping any loop it already has.
INSERT INTO persona_state_media (persona_id, state, status, job_id, percent, stage_note, prompt, tweak, provider_id, model)
VALUES ($1, $2, 'queued', $3, 0, $4, $5, $6, $7, '')
ON CONFLICT (persona_id, state) DO UPDATE SET
  status = 'queued', job_id = EXCLUDED.job_id, percent = 0, stage_note = EXCLUDED.stage_note,
  prompt = EXCLUDED.prompt, tweak = EXCLUDED.tweak, provider_id = EXCLUDED.provider_id,
  error = NULL, error_kind = NULL, updated_at = now()
RETURNING *;

-- name: ProgressPersonaStateMedia :exec
-- Moves a running attempt along; a superseded attempt changes nothing.
UPDATE persona_state_media SET status = 'running', percent = $4, stage_note = $5, updated_at = now()
WHERE persona_id = $1 AND state = $2 AND job_id = $3 AND status IN ('queued', 'running');

-- name: FinishPersonaStateMedia :one
-- Stores a finished loop. The caller deletes the blobs it replaced (the
-- previous row's keys), and its own new blobs when no row matches.
UPDATE persona_state_media SET status = 'ready', percent = 100, stage_note = '',
  model = $4, interaction_id = $5, backend = $6, blob_key = $7, content_type = $8, head_key = $9,
  width = $10, height = $11, frames = $12, duration_ms = $13, size_bytes = $14,
  error = NULL, error_kind = NULL, updated_at = now()
WHERE persona_id = $1 AND state = $2 AND job_id = $3 AND status IN ('queued', 'running')
RETURNING *;

-- name: FailPersonaStateMedia :exec
-- Marks an attempt failed; the state keeps any loop it had.
UPDATE persona_state_media SET status = 'failed', percent = 0, stage_note = '', error = $4, error_kind = $5, updated_at = now()
WHERE persona_id = $1 AND state = $2 AND job_id = $3 AND status IN ('queued', 'running');

-- name: DeletePersonaStateMedia :many
-- Removes a persona's loops (one state, or all with a NULL state) and returns
-- them so the caller can delete their blobs and cancel their attempts.
DELETE FROM persona_state_media
WHERE persona_id = sqlc.arg(persona_id) AND (sqlc.narg(state)::text IS NULL OR state = sqlc.narg(state)::text)
RETURNING *;

-- name: LockPersonaStateMediaOwner :exec
-- Serializes starts and clears for one persona, including its first start,
-- when there are no rows yet to lock.
SELECT pg_advisory_xact_lock(hashtextextended('persona-state-media:' || sqlc.arg(persona_id)::uuid::text, 0));

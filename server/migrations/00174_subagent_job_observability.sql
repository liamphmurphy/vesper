-- +goose Up
-- Spawn decision metadata for subagent tree visualization and debugging.
ALTER TABLE subagent_jobs
  ADD COLUMN requested_tier text NOT NULL DEFAULT '',
  ADD COLUMN reason text NOT NULL DEFAULT '',
  ADD COLUMN batch_id uuid;

-- +goose Down
ALTER TABLE subagent_jobs
  DROP COLUMN IF EXISTS batch_id,
  DROP COLUMN IF EXISTS reason,
  DROP COLUMN IF EXISTS requested_tier;

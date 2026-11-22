-- +goose Up
-- Resolved model tier, model ID, and effort for each in-turn subagent job.
ALTER TABLE subagent_jobs
  ADD COLUMN tier text NOT NULL DEFAULT '',
  ADD COLUMN model text NOT NULL DEFAULT '',
  ADD COLUMN effort text NOT NULL DEFAULT '';

-- +goose Down
ALTER TABLE subagent_jobs
  DROP COLUMN IF EXISTS effort,
  DROP COLUMN IF EXISTS model,
  DROP COLUMN IF EXISTS tier;

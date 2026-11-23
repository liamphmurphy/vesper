-- +goose Up
-- Allow Gemini API as an image engine (alongside Codex and Antigravity) and
-- register 'image' as a workspace media default capability.
ALTER TABLE workspace_media_defaults
  DROP CONSTRAINT IF EXISTS workspace_media_defaults_capability_check;

ALTER TABLE workspace_media_defaults
  ADD CONSTRAINT workspace_media_defaults_capability_check
  CHECK (capability IN ('image', 'music', 'tts', 'script', 'video'));

ALTER TABLE workspaces
  DROP CONSTRAINT IF EXISTS workspaces_image_engine_check;

ALTER TABLE workspaces
  ADD CONSTRAINT workspaces_image_engine_check
  CHECK (image_engine IN ('auto', 'codex', 'antigravity', 'gemini'));

ALTER TABLE personas
  DROP CONSTRAINT IF EXISTS personas_image_engine_check;

ALTER TABLE personas
  ADD CONSTRAINT personas_image_engine_check
  CHECK (image_engine IN ('', 'auto', 'codex', 'antigravity', 'gemini'));

ALTER TABLE chat_image_jobs
  DROP CONSTRAINT IF EXISTS chat_image_jobs_harness_check;

ALTER TABLE chat_image_jobs
  ADD CONSTRAINT chat_image_jobs_harness_check
  CHECK (harness IN ('codex', 'antigravity', 'gemini'));

-- +goose Down
UPDATE workspaces SET image_engine = 'auto' WHERE image_engine = 'gemini';
UPDATE personas SET image_engine = '' WHERE image_engine = 'gemini';
DELETE FROM chat_image_jobs WHERE harness = 'gemini';
DELETE FROM workspace_media_defaults WHERE capability = 'image';

ALTER TABLE chat_image_jobs
  DROP CONSTRAINT IF EXISTS chat_image_jobs_harness_check;

ALTER TABLE chat_image_jobs
  ADD CONSTRAINT chat_image_jobs_harness_check
  CHECK (harness IN ('codex', 'antigravity'));

ALTER TABLE personas
  DROP CONSTRAINT IF EXISTS personas_image_engine_check;

ALTER TABLE personas
  ADD CONSTRAINT personas_image_engine_check
  CHECK (image_engine IN ('', 'auto', 'codex', 'antigravity'));

ALTER TABLE workspaces
  DROP CONSTRAINT IF EXISTS workspaces_image_engine_check;

ALTER TABLE workspaces
  ADD CONSTRAINT workspaces_image_engine_check
  CHECK (image_engine IN ('auto', 'codex', 'antigravity'));

ALTER TABLE workspace_media_defaults
  DROP CONSTRAINT IF EXISTS workspace_media_defaults_capability_check;

ALTER TABLE workspace_media_defaults
  ADD CONSTRAINT workspace_media_defaults_capability_check
  CHECK (capability IN ('music', 'tts', 'script', 'video'));

-- +goose Up
-- Allow 'video' as a workspace default media capability (Gemini Omni CapVideo).
ALTER TABLE workspace_media_defaults
  DROP CONSTRAINT IF EXISTS workspace_media_defaults_capability_check;

ALTER TABLE workspace_media_defaults
  ADD CONSTRAINT workspace_media_defaults_capability_check
  CHECK (capability IN ('music', 'tts', 'script', 'video'));

-- +goose Down
DELETE FROM workspace_media_defaults WHERE capability = 'video';

ALTER TABLE workspace_media_defaults
  DROP CONSTRAINT IF EXISTS workspace_media_defaults_capability_check;

ALTER TABLE workspace_media_defaults
  ADD CONSTRAINT workspace_media_defaults_capability_check
  CHECK (capability IN ('music', 'tts', 'script'));

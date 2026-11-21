-- +goose Up
-- Media provider configurations (encrypted credentials + per-capability workspace defaults)
-- and music generation fields on chat_audio_jobs.
CREATE TABLE media_provider_configs (
  workspace_id      uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  provider_id       text NOT NULL CHECK (length(provider_id) BETWEEN 1 AND 64),
  enabled           boolean NOT NULL DEFAULT true,
  settings_json     jsonb NOT NULL DEFAULT '{}',
  secret_nonce      bytea,
  secret_ciphertext bytea,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, provider_id),
  CONSTRAINT media_provider_secret_pair CHECK ((secret_nonce IS NULL) = (secret_ciphertext IS NULL))
);

CREATE TABLE workspace_media_defaults (
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  capability   text NOT NULL CHECK (capability IN ('music', 'tts', 'script')),
  provider_id  text NOT NULL CHECK (length(provider_id) BETWEEN 1 AND 64),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, capability)
);

ALTER TABLE chat_audio_jobs
  ADD COLUMN source_kind text NOT NULL DEFAULT 'code' CHECK (source_kind IN ('code', 'music')),
  ADD COLUMN provider_id text NOT NULL DEFAULT '' CHECK (length(provider_id) <= 64),
  ADD COLUMN prompt text NOT NULL DEFAULT '' CHECK (length(prompt) <= 4000),
  ADD COLUMN lyrics text NOT NULL DEFAULT '' CHECK (length(lyrics) <= 8000),
  ADD COLUMN instrumental boolean NOT NULL DEFAULT false,
  ADD COLUMN error_kind text NOT NULL DEFAULT '' CHECK (error_kind IN ('', 'auth', 'quota', 'rate_limit', 'filtered', 'unavailable', 'error'));

-- +goose Down
ALTER TABLE chat_audio_jobs
  DROP COLUMN error_kind,
  DROP COLUMN instrumental,
  DROP COLUMN lyrics,
  DROP COLUMN prompt,
  DROP COLUMN provider_id,
  DROP COLUMN source_kind;

DROP TABLE workspace_media_defaults;
DROP TABLE media_provider_configs;

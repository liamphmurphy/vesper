-- +goose Up
-- Per-app host read-only mounts and background Nix package jobs for custom apps.
ALTER TABLE custom_apps ADD COLUMN mounts jsonb NOT NULL DEFAULT '{}'::jsonb;

CREATE TABLE custom_app_nix_jobs (
  id         uuid PRIMARY KEY DEFAULT uuid_v7(),
  app_id     uuid NOT NULL REFERENCES custom_apps(id) ON DELETE CASCADE,
  packages   text[] NOT NULL,
  command    text NOT NULL,
  state      text NOT NULL CHECK (state IN ('resolving', 'running', 'done', 'failed', 'canceled')),
  exit_code  integer,
  work_dir   text NOT NULL DEFAULT '',
  stdout     text NOT NULL DEFAULT '',
  stderr     text NOT NULL DEFAULT '',
  error      text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX custom_app_nix_jobs_app ON custom_app_nix_jobs (app_id, created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS custom_app_nix_jobs;
ALTER TABLE custom_apps DROP COLUMN IF EXISTS mounts;

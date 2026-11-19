-- +goose Up
-- Remove scheduled Google Drive backup tables; local/cloud-synced folder
-- backups are handled by the macOS app.
DROP TABLE IF EXISTS drive_backup_locks;
DROP TABLE IF EXISTS drive_backups;
DELETE FROM inbox_reads WHERE item_id LIKE 'drive_backup:%';

-- +goose Down
CREATE TABLE drive_backups (
  workspace_id uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id      uuid REFERENCES users(id) ON DELETE SET NULL,
  enabled      boolean NOT NULL DEFAULT false,
  secret_id    uuid REFERENCES user_secrets(id) ON DELETE SET NULL,
  folder_id    text NOT NULL DEFAULT '',
  folder_name  text NOT NULL DEFAULT '',
  at_time      text NOT NULL DEFAULT '03:00',
  timezone     text NOT NULL DEFAULT 'UTC',
  retention    integer NOT NULL DEFAULT 7 CHECK (retention >= 0),
  next_run_at  timestamptz,
  last_run_at  timestamptz,
  last_status  text NOT NULL DEFAULT '' CHECK (last_status IN ('', 'succeeded', 'failed')),
  last_error   text NOT NULL DEFAULT '',
  revision     integer NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX drive_backups_due ON drive_backups (next_run_at) WHERE enabled;

CREATE TABLE drive_backup_locks (
  workspace_id uuid PRIMARY KEY REFERENCES drive_backups(workspace_id) ON DELETE CASCADE,
  holder       text NOT NULL,
  started_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL
);

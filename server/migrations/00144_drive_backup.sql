-- +goose Up
-- Scheduled export to Google Drive: one configuration per workspace. The
-- archive is uploaded with a person's OAuth secret, so the row names its owner
-- and the secret; deleting either turns the backup off rather than losing the
-- rest of the settings.
CREATE TABLE drive_backups (
  workspace_id uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id      uuid REFERENCES users(id) ON DELETE SET NULL,
  enabled      boolean NOT NULL DEFAULT false,
  secret_id    uuid REFERENCES user_secrets(id) ON DELETE SET NULL,
  folder_id    text NOT NULL DEFAULT '',
  folder_name  text NOT NULL DEFAULT '',
  -- Daily, at this local time (HH:MM) in this IANA time zone.
  at_time      text NOT NULL DEFAULT '03:00',
  timezone     text NOT NULL DEFAULT 'UTC',
  -- How many backups to keep in the folder; 0 keeps them all.
  retention    integer NOT NULL DEFAULT 7 CHECK (retention >= 0),
  next_run_at  timestamptz,
  last_run_at  timestamptz,
  -- Outcome of the last finished run. A run in progress lives in
  -- drive_backup_locks, so an archive taken mid-run never says "running".
  last_status  text NOT NULL DEFAULT '' CHECK (last_status IN ('', 'succeeded', 'failed')),
  last_error   text NOT NULL DEFAULT '',
  revision     integer NOT NULL DEFAULT 1,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT drive_backups_enabled_complete CHECK (NOT enabled OR (secret_id IS NOT NULL AND user_id IS NOT NULL AND folder_id <> ''))
);
CREATE INDEX drive_backups_due ON drive_backups (next_run_at) WHERE enabled;

-- The lease on a backup in progress. It is runtime state of this machine, so
-- vesper export leaves it out (internal/transfer/schema.go).
CREATE TABLE drive_backup_locks (
  workspace_id uuid PRIMARY KEY REFERENCES drive_backups(workspace_id) ON DELETE CASCADE,
  holder       text NOT NULL,
  started_at   timestamptz NOT NULL DEFAULT now(),
  expires_at   timestamptz NOT NULL
);

-- +goose Down
DROP TABLE drive_backup_locks;
DROP TABLE drive_backups;

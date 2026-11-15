-- Scheduled export to Google Drive: one configuration per workspace, plus a
-- lease while a backup runs.

-- name: GetDriveBackup :one
SELECT * FROM drive_backups WHERE workspace_id = $1;

-- name: SaveDriveBackup :one
-- Creates the configuration or updates it. Returns no row when an existing
-- configuration's revision isn't the one the caller read.
INSERT INTO drive_backups (workspace_id, user_id, enabled, secret_id, folder_id, folder_name, at_time, timezone, retention, next_run_at)
VALUES (sqlc.arg(workspace_id), sqlc.arg(user_id), sqlc.arg(enabled), sqlc.narg(secret_id), sqlc.arg(folder_id), sqlc.arg(folder_name),
  sqlc.arg(at_time), sqlc.arg(timezone), sqlc.arg(retention), sqlc.narg(next_run_at))
ON CONFLICT (workspace_id) DO UPDATE SET user_id = EXCLUDED.user_id, enabled = EXCLUDED.enabled, secret_id = EXCLUDED.secret_id,
  folder_id = EXCLUDED.folder_id, folder_name = EXCLUDED.folder_name, at_time = EXCLUDED.at_time, timezone = EXCLUDED.timezone,
  retention = EXCLUDED.retention, next_run_at = EXCLUDED.next_run_at, revision = drive_backups.revision + 1, updated_at = now()
WHERE drive_backups.revision = sqlc.arg(revision)
RETURNING *;

-- name: NextDueDriveBackup :one
-- However many times a backup came due while Vesper was off, it is claimed
-- once: the caller moves next_run_at past now in the same transaction. NO KEY
-- UPDATE, so taking a lease (whose foreign key locks this row FOR KEY SHARE)
-- doesn't wait on the claiming transaction.
SELECT b.* FROM drive_backups b
WHERE b.enabled AND b.next_run_at <= now()
  AND NOT EXISTS (SELECT 1 FROM drive_backup_locks l WHERE l.workspace_id = b.workspace_id AND l.expires_at > now())
ORDER BY b.next_run_at LIMIT 1 FOR NO KEY UPDATE OF b SKIP LOCKED;

-- name: AdvanceDriveBackup :exec
UPDATE drive_backups SET next_run_at = $2 WHERE workspace_id = $1;

-- name: FinishDriveBackup :exec
UPDATE drive_backups SET last_run_at = now(), last_status = $2, last_error = $3 WHERE workspace_id = $1;

-- name: AcquireDriveBackupLock :one
-- Takes the lease, or a lease that has expired, for ttl_seconds. Returns no row
-- while another holder's lease is live, so a manual and a scheduled run never
-- overlap. Expiry is on the database's clock only, so app clock skew can't
-- stretch or shorten a lease.
INSERT INTO drive_backup_locks (workspace_id, holder, expires_at)
VALUES (sqlc.arg(workspace_id), sqlc.arg(holder), now() + make_interval(secs => sqlc.arg(ttl_seconds)::float8))
ON CONFLICT (workspace_id) DO UPDATE SET holder = EXCLUDED.holder, started_at = now(), expires_at = EXCLUDED.expires_at
WHERE drive_backup_locks.expires_at <= now()
RETURNING *;

-- name: ExtendDriveBackupLock :execrows
UPDATE drive_backup_locks SET expires_at = now() + make_interval(secs => sqlc.arg(ttl_seconds)::float8)
WHERE workspace_id = sqlc.arg(workspace_id) AND holder = sqlc.arg(holder);

-- name: ReleaseDriveBackupLock :exec
DELETE FROM drive_backup_locks WHERE workspace_id = $1 AND holder = $2;

-- name: GetDriveBackupLock :one
-- The live lease, if a backup is running.
SELECT * FROM drive_backup_locks WHERE workspace_id = $1 AND expires_at > now();

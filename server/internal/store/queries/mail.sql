-- Mail Butler accounts, synced contacts, deterministic rules, idle-VM triage queue, and audit log.

-- name: GetMailAccount :one
SELECT *
FROM mail_accounts
WHERE workspace_id = @workspace_id
  AND user_id = @user_id;

-- name: GetMailAccountByID :one
SELECT *
FROM mail_accounts
WHERE id = @id;

-- name: ListEnabledMailAccounts :many
SELECT *
FROM mail_accounts
WHERE enabled = true
ORDER BY last_synced_at ASC NULLS FIRST, id;

-- name: UpsertMailAccount :one
INSERT INTO mail_accounts (
  workspace_id, user_id, enabled, dry_run, email, imap_host, imap_port, carddav_url,
  password_nonce, password_ciphertext, default_folder, allowed_folders,
  triage_policy, pinned_model, poll_interval_seconds
) VALUES (
  @workspace_id, @user_id, @enabled, @dry_run, @email, @imap_host, @imap_port, @carddav_url,
  @password_nonce, @password_ciphertext, @default_folder, @allowed_folders,
  @triage_policy, @pinned_model, @poll_interval_seconds
)
ON CONFLICT (workspace_id, user_id) DO UPDATE SET
  enabled               = EXCLUDED.enabled,
  dry_run               = EXCLUDED.dry_run,
  email                 = EXCLUDED.email,
  imap_host             = EXCLUDED.imap_host,
  imap_port             = EXCLUDED.imap_port,
  carddav_url           = EXCLUDED.carddav_url,
  password_nonce        = CASE WHEN length(EXCLUDED.password_ciphertext) > 0 THEN EXCLUDED.password_nonce ELSE mail_accounts.password_nonce END,
  password_ciphertext   = CASE WHEN length(EXCLUDED.password_ciphertext) > 0 THEN EXCLUDED.password_ciphertext ELSE mail_accounts.password_ciphertext END,
  default_folder        = EXCLUDED.default_folder,
  allowed_folders       = EXCLUDED.allowed_folders,
  triage_policy         = EXCLUDED.triage_policy,
  pinned_model          = EXCLUDED.pinned_model,
  poll_interval_seconds = EXCLUDED.poll_interval_seconds,
  updated_at            = now()
RETURNING *;

-- name: DeleteMailAccount :exec
DELETE FROM mail_accounts
WHERE workspace_id = @workspace_id
  AND user_id = @user_id;

-- name: UpdateMailAccountSyncState :exec
UPDATE mail_accounts SET
  inbox_uid_validity = @inbox_uid_validity,
  last_seen_uid      = @last_seen_uid,
  last_synced_at     = now(),
  last_error         = @last_error,
  updated_at         = now()
WHERE id = @id;

-- name: UpdateMailAccountError :exec
UPDATE mail_accounts SET
  last_error = @last_error,
  updated_at = now()
WHERE id = @id;

-- name: TouchMailAccountContactsSynced :exec
UPDATE mail_accounts SET
  last_contacts_synced_at = now(),
  updated_at              = now()
WHERE id = @id;

-- name: CountMailContacts :one
SELECT count(*)::int
FROM mail_contacts
WHERE account_id = @account_id;

-- name: IsMailContact :one
SELECT EXISTS (
  SELECT 1 FROM mail_contacts
  WHERE account_id = @account_id
    AND email = lower(btrim(@email::text))
)::bool;

-- name: DeleteMailContacts :exec
DELETE FROM mail_contacts
WHERE account_id = @account_id;

-- name: UpsertMailContact :exec
INSERT INTO mail_contacts (account_id, email, display_name, synced_at)
VALUES (@account_id, lower(btrim(@email::text)), @display_name, now())
ON CONFLICT (account_id, email) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  synced_at    = now();

-- name: ListMailRules :many
SELECT *
FROM mail_rules
WHERE account_id = @account_id
ORDER BY priority ASC, created_at ASC, id ASC;

-- name: GetMailRule :one
SELECT *
FROM mail_rules
WHERE id = @id
  AND account_id = @account_id;

-- name: CreateMailRule :one
INSERT INTO mail_rules (
  account_id, priority, name, match_field, match_value, action, target_folder, enabled
) VALUES (
  @account_id, @priority, @name, @match_field, lower(btrim(@match_value::text)), @action, @target_folder, @enabled
)
RETURNING *;

-- name: UpdateMailRule :one
UPDATE mail_rules SET
  priority      = coalesce(sqlc.narg(priority), priority),
  name          = coalesce(sqlc.narg(name), name),
  match_field   = coalesce(sqlc.narg(match_field), match_field),
  match_value   = coalesce(lower(btrim(sqlc.narg(match_value)::text)), match_value),
  action        = coalesce(sqlc.narg(action), action),
  target_folder = coalesce(sqlc.narg(target_folder), target_folder),
  enabled       = coalesce(sqlc.narg(enabled), enabled),
  updated_at    = now()
WHERE id = @id
  AND account_id = @account_id
RETURNING *;

-- name: DeleteMailRule :one
DELETE FROM mail_rules
WHERE id = @id
  AND account_id = @account_id
RETURNING id;

-- name: EnqueueMailTriage :one
INSERT INTO mail_triage_queue (
  account_id, workspace_id, user_id, imap_uid, uid_validity, message_id,
  from_email, from_name, subject, list_unsubscribe, snippet, received_at
) VALUES (
  @account_id, @workspace_id, @user_id, @imap_uid, @uid_validity, @message_id,
  @from_email, @from_name, @subject, @list_unsubscribe, @snippet, @received_at
)
ON CONFLICT (account_id, uid_validity, imap_uid) DO NOTHING
RETURNING *;

-- name: NextMailTriageAccountDue :one
-- Finds one enabled account that has pending (or stale claimed) triage queue items.
SELECT q.account_id, q.workspace_id, q.user_id
FROM mail_triage_queue q
JOIN mail_accounts a ON a.id = q.account_id
WHERE a.enabled = true
  AND (
    q.status = 'pending'
    OR (q.status = 'claimed' AND q.claimed_at < @stale_before::timestamptz)
  )
  AND q.attempts < @max_attempts::int
ORDER BY q.created_at ASC
LIMIT 1;

-- name: ClaimMailTriageBatch :many
WITH batch AS (
  SELECT m.id
  FROM mail_triage_queue m
  WHERE m.account_id = @account_id
    AND (
      m.status = 'pending'
      OR (m.status = 'claimed' AND m.claimed_at < @stale_before::timestamptz)
    )
    AND m.attempts < @max_attempts::int
  ORDER BY m.created_at ASC
  LIMIT @batch_limit::int
  FOR UPDATE SKIP LOCKED
)
UPDATE mail_triage_queue q SET
  status     = 'claimed',
  claimed_at = now(),
  attempts   = q.attempts + 1,
  updated_at = now()
FROM batch
WHERE q.id = batch.id
RETURNING q.*;

-- name: SaveMailTriageDecision :exec
UPDATE mail_triage_queue SET
  status          = 'decided',
  decision_action = @decision_action,
  decision_folder = @decision_folder,
  decision_reason = @decision_reason,
  last_error      = '',
  updated_at      = now()
WHERE id = @id
  AND status = 'claimed';

-- name: FailMailTriageItem :exec
UPDATE mail_triage_queue SET
  status     = CASE WHEN attempts >= @max_attempts::int THEN 'failed' ELSE 'pending' END,
  last_error = @last_error,
  updated_at = now()
WHERE id = @id
  AND status = 'claimed';

-- name: ListDecidedMailTriageItems :many
SELECT *
FROM mail_triage_queue
WHERE account_id = @account_id
  AND status = 'decided'
ORDER BY created_at ASC
LIMIT @row_limit::int;

-- name: MarkMailTriageApplied :exec
UPDATE mail_triage_queue SET
  status     = 'applied',
  last_error = '',
  updated_at = now()
WHERE id = @id;

-- name: CountPendingMailTriage :one
SELECT count(*)::int
FROM mail_triage_queue
WHERE account_id = @account_id
  AND status IN ('pending', 'claimed', 'decided');

-- name: CreateMailTriageLog :one
INSERT INTO mail_triage_log (
  account_id, imap_uid, uid_validity, message_id, from_email, from_name, subject,
  source_folder, action, target_folder, tier, reason, dry_run
) VALUES (
  @account_id, @imap_uid, @uid_validity, @message_id, @from_email, @from_name, @subject,
  @source_folder, @action, @target_folder, @tier, @reason, @dry_run
)
RETURNING *;

-- name: ListMailTriageLog :many
SELECT *
FROM mail_triage_log
WHERE account_id = @account_id
ORDER BY created_at DESC, id DESC
LIMIT @row_limit::int;

-- name: GetMailTriageLog :one
SELECT *
FROM mail_triage_log
WHERE id = @id
  AND account_id = @account_id;

-- name: MarkMailTriageLogUndone :one
UPDATE mail_triage_log SET
  undone_at = now()
WHERE id = @id
  AND account_id = @account_id
  AND undone_at IS NULL
RETURNING *;

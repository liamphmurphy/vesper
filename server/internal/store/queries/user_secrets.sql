-- A person's API secrets are private to them: every query filters on (workspace_id, user_id).

-- name: CreateUserSecret :one
INSERT INTO user_secrets (id, workspace_id, user_id, name, handle, placement, placement_key, allowed_hosts, read_policy, write_policy, nonce, ciphertext, expires_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13) RETURNING *;

-- name: ListUserSecrets :many
SELECT * FROM user_secrets WHERE workspace_id = $1 AND user_id = $2 ORDER BY lower(name), id;

-- name: GetUserSecret :one
SELECT * FROM user_secrets WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: GetUserSecretByHandle :one
SELECT * FROM user_secrets WHERE workspace_id = $1 AND user_id = $2 AND handle = $3;

-- name: UserSecretHandleTaken :one
SELECT EXISTS (SELECT 1 FROM user_secrets WHERE workspace_id = $1 AND user_id = $2 AND handle = $3)::bool;

-- name: UpdateUserSecret :one
-- Returns no row when the revision is stale.
UPDATE user_secrets SET name = $4, placement = $5, placement_key = $6, allowed_hosts = $7, read_policy = $8, write_policy = $9,
  revision = revision + 1, updated_at = now()
WHERE id = $1 AND workspace_id = $2 AND revision = $3 RETURNING *;

-- name: SetUserSecretValue :one
UPDATE user_secrets SET nonce = $2, ciphertext = $3, expires_at = $4, revision = revision + 1, updated_at = now() WHERE id = $1 RETURNING *;

-- name: SetUserSecretPolicy :exec
-- "Always allow" from an approval: no revision check, the person just chose it.
UPDATE user_secrets SET read_policy = CASE WHEN sqlc.arg(write)::bool THEN read_policy ELSE sqlc.arg(policy)::text END,
  write_policy = CASE WHEN sqlc.arg(write)::bool THEN sqlc.arg(policy)::text ELSE write_policy END,
  revision = revision + 1, updated_at = now()
WHERE id = $1;

-- name: TouchUserSecret :exec
UPDATE user_secrets SET last_used_at = now() WHERE id = $1;

-- name: DeleteUserSecret :execrows
DELETE FROM user_secrets WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: ListUserSecretPersonas :many
SELECT secret_id, persona_id FROM user_secret_personas WHERE secret_id = ANY(sqlc.arg(ids)::uuid[]) ORDER BY secret_id, persona_id;

-- name: ClearUserSecretPersonas :exec
DELETE FROM user_secret_personas WHERE secret_id = $1;

-- name: AddUserSecretPersona :exec
INSERT INTO user_secret_personas (secret_id, persona_id) VALUES ($1, $2) ON CONFLICT DO NOTHING;

-- name: UserSecretsForPersona :many
-- What this persona may use; a chat's list, when it has one, narrows it.
SELECT s.* FROM user_secrets s JOIN user_secret_personas sp ON sp.secret_id = s.id
WHERE s.workspace_id = $1 AND s.user_id = $2 AND sp.persona_id = $3
  AND (sqlc.narg(allowed_ids)::uuid[] IS NULL OR s.id = ANY(sqlc.narg(allowed_ids)::uuid[]))
ORDER BY s.handle;

-- name: SetChatSecrets :one
UPDATE chat_sessions SET secret_ids = sqlc.narg(secret_ids)::uuid[] WHERE id = $1 RETURNING *;

-- name: CreateUserSecretApproval :one
INSERT INTO user_secret_approvals (workspace_id, user_id, secret_id, persona_id, chat_id, method, url, headers, body)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9) RETURNING *;

-- name: GetUserSecretApproval :one
SELECT * FROM user_secret_approvals WHERE id = $1;

-- name: DecideUserSecretApproval :one
UPDATE user_secret_approvals SET state = $2, decided_at = now()
WHERE id = $1 AND workspace_id = $3 AND user_id = $4 AND state = 'pending' RETURNING *;

-- name: ExpireUserSecretApproval :exec
UPDATE user_secret_approvals SET state = 'expired', decided_at = now() WHERE id = $1 AND state = 'pending';

-- name: PendingUserSecretApprovals :many
SELECT a.*, s.name AS secret_name, s.handle AS secret_handle, s.placement AS secret_placement, s.placement_key AS secret_placement_key
FROM user_secret_approvals a JOIN user_secrets s ON s.id = a.secret_id
WHERE a.chat_id = $1 AND a.state = 'pending' ORDER BY a.created_at;

-- name: HasPendingUserSecretApproval :one
SELECT EXISTS (SELECT 1 FROM user_secret_approvals WHERE chat_id = $1 AND state = 'pending')::bool;

-- name: CreateUserSecretProposal :one
INSERT INTO user_secret_proposals (chat_id, run_id, proposed_by, name, host, placement, placement_key, reason)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *;

-- name: CountPendingUserSecretProposals :one
SELECT count(*)::int FROM user_secret_proposals WHERE chat_id = $1 AND state = 'pending';

-- name: ListUserSecretProposals :many
SELECT * FROM user_secret_proposals WHERE chat_id = $1 AND state = 'pending' ORDER BY created_at, id;

-- name: GetUserSecretProposal :one
SELECT p.* FROM user_secret_proposals p JOIN chat_sessions c ON c.id = p.chat_id
WHERE p.id = $1 AND c.workspace_id = $2 AND c.created_by = $3;

-- name: FinishUserSecretProposal :one
UPDATE user_secret_proposals SET state = $2, secret_id = sqlc.narg(secret_id), decided_at = now()
WHERE id = $1 AND state = 'pending' RETURNING *;

-- name: LogUserSecretCall :exec
INSERT INTO user_secret_calls (secret_id, chat_id, persona_id, method, host, path, decision, status, error, redactions, duration_ms)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11);

-- name: ListUserSecretCalls :many
SELECT c.*, p.name AS persona_name FROM user_secret_calls c LEFT JOIN personas p ON p.id = c.persona_id
WHERE c.secret_id = $1 ORDER BY c.created_at DESC, c.id DESC LIMIT 200;

-- name: ChatSecretUsage :many
-- The secrets a chat used, for the chat header: sent requests and blocked ones alike.
SELECT s.id, s.name, s.handle, count(*)::int AS calls, max(c.created_at)::timestamptz AS last_used_at,
  array_agg(DISTINCT c.method ORDER BY c.method)::text[] AS methods
FROM user_secret_calls c JOIN user_secrets s ON s.id = c.secret_id
WHERE c.chat_id = $1 AND s.workspace_id = $2 AND s.user_id = $3
GROUP BY s.id, s.name, s.handle ORDER BY max(c.created_at) DESC;

-- name: CountPendingUserSecretApprovals :one
SELECT count(*)::int FROM user_secret_approvals WHERE chat_id = $1 AND state = 'pending';

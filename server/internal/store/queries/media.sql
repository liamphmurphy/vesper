-- name: ListMediaProviderConfigs :many
SELECT * FROM media_provider_configs WHERE workspace_id = $1 ORDER BY provider_id;

-- name: GetMediaProviderConfig :one
SELECT * FROM media_provider_configs WHERE workspace_id = $1 AND provider_id = $2;

-- name: UpsertMediaProviderConfig :one
INSERT INTO media_provider_configs (workspace_id, provider_id, enabled, settings_json, secret_nonce, secret_ciphertext, updated_at)
VALUES ($1, $2, $3, $4, $5, $6, now())
ON CONFLICT (workspace_id, provider_id) DO UPDATE SET
  enabled = EXCLUDED.enabled,
  settings_json = EXCLUDED.settings_json,
  secret_nonce = EXCLUDED.secret_nonce,
  secret_ciphertext = EXCLUDED.secret_ciphertext,
  updated_at = now()
RETURNING *;

-- name: ClearMediaProviderSecret :exec
UPDATE media_provider_configs
SET secret_nonce = NULL, secret_ciphertext = NULL, updated_at = now()
WHERE workspace_id = $1 AND provider_id = $2;

-- name: ListWorkspaceMediaDefaults :many
SELECT * FROM workspace_media_defaults WHERE workspace_id = $1 ORDER BY capability;

-- name: GetWorkspaceMediaDefault :one
SELECT * FROM workspace_media_defaults WHERE workspace_id = $1 AND capability = $2;

-- name: UpsertWorkspaceMediaDefault :one
INSERT INTO workspace_media_defaults (workspace_id, capability, provider_id, updated_at)
VALUES ($1, $2, $3, now())
ON CONFLICT (workspace_id, capability) DO UPDATE SET
  provider_id = EXCLUDED.provider_id,
  updated_at = now()
RETURNING *;

-- name: DeleteWorkspaceMediaDefault :exec
DELETE FROM workspace_media_defaults WHERE workspace_id = $1 AND capability = $2;

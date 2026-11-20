-- name: GetBackupEncryption :one
SELECT workspace_id, nonce, ciphertext, updated_at
FROM backup_encryption
WHERE workspace_id = $1;

-- name: GetAnyBackupEncryption :one
SELECT workspace_id, nonce, ciphertext, updated_at
FROM backup_encryption
LIMIT 1;

-- name: UpsertBackupEncryption :one
INSERT INTO backup_encryption (workspace_id, nonce, ciphertext)
VALUES ($1, $2, $3)
ON CONFLICT (workspace_id) DO UPDATE
SET nonce = EXCLUDED.nonce,
    ciphertext = EXCLUDED.ciphertext,
    updated_at = now()
RETURNING workspace_id, nonce, ciphertext, updated_at;

-- name: DeleteBackupEncryption :exec
DELETE FROM backup_encryption
WHERE workspace_id = $1;

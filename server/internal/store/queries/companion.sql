-- name: CreateCompanionPairingCode :exec
INSERT INTO companion_pairing_codes (code_hash, expires_at) VALUES ($1, $2);

-- name: RedeemCompanionPairingCode :one
-- Deleting the row guarantees single-use even under concurrent redeems.
DELETE FROM companion_pairing_codes WHERE code_hash = $1 AND expires_at > now()
RETURNING code_hash;

-- name: DeleteExpiredCompanionPairingCodes :exec
DELETE FROM companion_pairing_codes WHERE expires_at <= now();

-- name: CreateCompanionDevice :one
INSERT INTO companion_devices (user_id, name, platform, token_hash)
VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: GetActiveCompanionDeviceByTokenHash :one
SELECT * FROM companion_devices
WHERE token_hash = $1 AND revoked_at IS NULL;

-- name: TouchCompanionDevice :exec
UPDATE companion_devices SET last_used_at = now() WHERE id = $1;

-- name: ListActiveCompanionDevices :many
SELECT * FROM companion_devices
WHERE user_id = $1 AND revoked_at IS NULL
ORDER BY created_at DESC;

-- name: RevokeCompanionDevice :one
UPDATE companion_devices
SET revoked_at = now()
WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
RETURNING id;

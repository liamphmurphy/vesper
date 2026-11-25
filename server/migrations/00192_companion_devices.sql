-- +goose Up
-- Pairing codes and paired companion devices (e.g. iPhone over LAN or Tailscale).
-- Codes are single-use and short-lived; devices hold a revocable bearer token.
CREATE TABLE companion_pairing_codes (
    code_hash  BYTEA PRIMARY KEY,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE companion_devices (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    platform     TEXT NOT NULL DEFAULT 'ios',
    token_hash   BYTEA NOT NULL UNIQUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    revoked_at   TIMESTAMPTZ
);

CREATE INDEX companion_devices_user_active_idx
    ON companion_devices (user_id, created_at DESC)
    WHERE revoked_at IS NULL;

-- +goose Down
DROP TABLE IF EXISTS companion_devices;
DROP TABLE IF EXISTS companion_pairing_codes;

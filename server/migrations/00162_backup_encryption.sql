-- +goose Up
CREATE TABLE backup_encryption (
  workspace_id uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  nonce        bytea NOT NULL,
  ciphertext   bytea NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE IF EXISTS backup_encryption;

-- +goose Up
ALTER TABLE dev_workspaces
  ADD COLUMN custom_zshrc text;

-- +goose Down
ALTER TABLE dev_workspaces
  DROP COLUMN IF EXISTS custom_zshrc;

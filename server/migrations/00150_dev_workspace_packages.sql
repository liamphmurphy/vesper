-- +goose Up
ALTER TABLE dev_workspaces
  ADD COLUMN extra_packages jsonb NOT NULL DEFAULT '[]'::jsonb;

-- +goose Down
ALTER TABLE dev_workspaces
  DROP COLUMN IF EXISTS extra_packages;

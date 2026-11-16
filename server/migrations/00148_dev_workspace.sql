-- +goose Up
-- Persistent standalone Nix + LazyVim dev workspace, opt-in per Vesper workspace.
CREATE TABLE dev_workspaces (
  workspace_id uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  nix_mode text NOT NULL DEFAULT 'default' CHECK (nix_mode IN ('default')),
  repos jsonb NOT NULL DEFAULT '[]'::jsonb,
  state text NOT NULL DEFAULT 'stopped' CHECK (state IN ('stopped', 'starting', 'ready', 'error')),
  action text CHECK (action IS NULL OR action IN ('start', 'rebuild', 'sync', 'stop')),
  step text,
  error text,
  port integer,
  runner_id text,
  stack text,
  arch text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE IF EXISTS dev_workspaces;

-- +goose Up
ALTER TABLE dev_workspaces
  ADD COLUMN custom_zshrc text,
  ADD COLUMN custom_tmux_conf text,
  ADD COLUMN tmux_prefix text NOT NULL DEFAULT 'C-b' CHECK (tmux_prefix IN ('C-b', 'C-a', 'C-Space', 'C-s'));

-- +goose Down
ALTER TABLE dev_workspaces
  DROP COLUMN IF EXISTS tmux_prefix,
  DROP COLUMN IF EXISTS custom_tmux_conf,
  DROP COLUMN IF EXISTS custom_zshrc;

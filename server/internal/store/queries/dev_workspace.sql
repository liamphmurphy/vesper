-- name: GetDevWorkspace :one
SELECT * FROM dev_workspaces WHERE workspace_id = $1;

-- name: UpsertDevWorkspace :one
INSERT INTO dev_workspaces (workspace_id, user_id, enabled, nix_mode, repos, extra_packages, custom_zshrc, custom_tmux_conf, tmux_prefix, action, state, error, updated_at)
VALUES (
  sqlc.arg(workspace_id),
  sqlc.arg(user_id),
  sqlc.arg(enabled),
  sqlc.arg(nix_mode),
  sqlc.arg(repos),
  sqlc.arg(extra_packages),
  sqlc.narg(custom_zshrc),
  sqlc.narg(custom_tmux_conf),
  sqlc.arg(tmux_prefix),
  sqlc.narg(action),
  CASE WHEN sqlc.narg(action)::text IS NOT NULL THEN 'starting' ELSE 'stopped' END,
  NULL,
  now()
)
ON CONFLICT (workspace_id) DO UPDATE SET
  user_id = EXCLUDED.user_id,
  enabled = EXCLUDED.enabled,
  nix_mode = EXCLUDED.nix_mode,
  repos = EXCLUDED.repos,
  extra_packages = EXCLUDED.extra_packages,
  custom_zshrc = EXCLUDED.custom_zshrc,
  custom_tmux_conf = EXCLUDED.custom_tmux_conf,
  tmux_prefix = EXCLUDED.tmux_prefix,
  action = COALESCE(sqlc.narg(action), dev_workspaces.action),
  state = CASE WHEN sqlc.narg(action)::text IS NOT NULL THEN 'starting' ELSE dev_workspaces.state END,
  error = CASE WHEN sqlc.narg(action)::text IS NOT NULL THEN NULL ELSE dev_workspaces.error END,
  updated_at = now()
RETURNING *;

-- name: RequestDevWorkspaceAction :one
UPDATE dev_workspaces
SET action = sqlc.arg(action),
    state = 'starting',
    error = NULL,
    updated_at = now()
WHERE workspace_id = sqlc.arg(workspace_id)
RETURNING *;

-- name: ClaimDevWorkspaceAction :one
WITH target AS (
  SELECT workspace_id, action FROM dev_workspaces
  WHERE action IS NOT NULL
  ORDER BY updated_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
UPDATE dev_workspaces d
SET action = NULL,
    runner_id = sqlc.arg(runner_id),
    stack = sqlc.narg(stack),
    updated_at = now()
FROM target
WHERE d.workspace_id = target.workspace_id
RETURNING d.*, target.action AS claimed_action;

-- name: UpdateDevWorkspaceState :exec
UPDATE dev_workspaces
SET state = sqlc.arg(state),
    step = sqlc.narg(step),
    error = sqlc.narg(error),
    port = sqlc.narg(port),
    arch = COALESCE(sqlc.narg(arch), arch),
    updated_at = now()
WHERE workspace_id = sqlc.arg(workspace_id);

-- name: StopStackDevWorkspaces :exec
UPDATE dev_workspaces
SET state = CASE WHEN enabled THEN 'starting' ELSE 'stopped' END,
    action = CASE WHEN enabled THEN 'start' ELSE NULL END,
    step = NULL,
    port = NULL,
    runner_id = NULL,
    updated_at = now()
WHERE stack = sqlc.arg(stack)
   OR (enabled = true AND state IN ('ready', 'starting'));

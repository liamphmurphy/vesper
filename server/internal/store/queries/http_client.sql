-- name: ListHTTPWorkspaces :many
SELECT * FROM http_workspaces
WHERE workspace_id = $1
ORDER BY updated_at DESC, created_at DESC;

-- name: GetHTTPWorkspace :one
SELECT * FROM http_workspaces
WHERE id = $1 AND workspace_id = $2;

-- name: CreateHTTPWorkspace :one
INSERT INTO http_workspaces (workspace_id, user_id, name, description, default_auth, default_headers, default_vars)
VALUES ($1, $2, $3, $4, $5, $6, $7)
RETURNING *;

-- name: UpdateHTTPWorkspace :one
UPDATE http_workspaces
SET name = $3,
    description = $4,
    active_environment_id = $5,
    default_auth = $6,
    default_headers = $7,
    default_vars = $8,
    updated_at = now()
WHERE id = $1 AND workspace_id = $2
RETURNING *;

-- name: SetHTTPWorkspaceActiveEnvironment :one
UPDATE http_workspaces
SET active_environment_id = $3,
    updated_at = now()
WHERE id = $1 AND workspace_id = $2
RETURNING *;

-- name: DeleteHTTPWorkspace :execrows
DELETE FROM http_workspaces
WHERE id = $1 AND workspace_id = $2;

-- name: ListHTTPEnvironments :many
SELECT * FROM http_environments
WHERE http_workspace_id = $1
ORDER BY sort_order, created_at;

-- name: GetHTTPEnvironment :one
SELECT e.* FROM http_environments e
JOIN http_workspaces w ON w.id = e.http_workspace_id
WHERE e.id = $1 AND w.workspace_id = $2;

-- name: CreateHTTPEnvironment :one
INSERT INTO http_environments (http_workspace_id, name, color, variables, sort_order)
VALUES ($1, $2, $3, $4, $5)
RETURNING *;

-- name: UpdateHTTPEnvironment :one
UPDATE http_environments e
SET name = $3,
    color = $4,
    variables = $5,
    sort_order = $6,
    updated_at = now()
FROM http_workspaces w
WHERE e.id = $1 AND e.http_workspace_id = w.id AND w.workspace_id = $2
RETURNING e.*;

-- name: DeleteHTTPEnvironment :execrows
DELETE FROM http_environments e
USING http_workspaces w
WHERE e.id = $1 AND e.http_workspace_id = w.id AND w.workspace_id = $2;

-- name: ListHTTPFolders :many
SELECT * FROM http_folders
WHERE http_workspace_id = $1
ORDER BY sort_order, created_at;

-- name: GetHTTPFolder :one
SELECT f.* FROM http_folders f
JOIN http_workspaces w ON w.id = f.http_workspace_id
WHERE f.id = $1 AND w.workspace_id = $2;

-- name: CreateHTTPFolder :one
INSERT INTO http_folders (http_workspace_id, parent_folder_id, name, default_auth, default_headers, sort_order)
VALUES ($1, $2, $3, $4, $5, $6)
RETURNING *;

-- name: UpdateHTTPFolder :one
UPDATE http_folders f
SET parent_folder_id = $3,
    name = $4,
    default_auth = $5,
    default_headers = $6,
    sort_order = $7,
    updated_at = now()
FROM http_workspaces w
WHERE f.id = $1 AND f.http_workspace_id = w.id AND w.workspace_id = $2
RETURNING f.*;

-- name: DeleteHTTPFolder :execrows
DELETE FROM http_folders f
USING http_workspaces w
WHERE f.id = $1 AND f.http_workspace_id = w.id AND w.workspace_id = $2;

-- name: ListHTTPRequests :many
SELECT * FROM http_requests
WHERE http_workspace_id = $1
ORDER BY sort_order, created_at;

-- name: GetHTTPRequest :one
SELECT r.* FROM http_requests r
JOIN http_workspaces w ON w.id = r.http_workspace_id
WHERE r.id = $1 AND w.workspace_id = $2;

-- name: CreateHTTPRequest :one
INSERT INTO http_requests (
  http_workspace_id, folder_id, name, method, url, params, headers, auth,
  body_mode, body, body_form, timeout_ms, follow_redirects, sort_order
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
RETURNING *;

-- name: UpdateHTTPRequest :one
UPDATE http_requests r
SET folder_id = $3,
    name = $4,
    method = $5,
    url = $6,
    params = $7,
    headers = $8,
    auth = $9,
    body_mode = $10,
    body = $11,
    body_form = $12,
    timeout_ms = $13,
    follow_redirects = $14,
    sort_order = $15,
    updated_at = now()
FROM http_workspaces w
WHERE r.id = $1 AND r.http_workspace_id = w.id AND w.workspace_id = $2
RETURNING r.*;

-- name: DeleteHTTPRequest :execrows
DELETE FROM http_requests r
USING http_workspaces w
WHERE r.id = $1 AND r.http_workspace_id = w.id AND w.workspace_id = $2;

-- name: CreateHTTPExecution :one
INSERT INTO http_executions (
  http_workspace_id, request_id, environment_id, environment_name,
  method, resolved_url, request_headers, request_body,
  status_code, status_text, duration_ms, size_bytes,
  response_headers, response_body, response_truncated, error
)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16)
RETURNING *;

-- name: ListHTTPExecutionsByWorkspace :many
SELECT e.* FROM http_executions e
JOIN http_workspaces w ON w.id = e.http_workspace_id
WHERE e.http_workspace_id = $1 AND w.workspace_id = $2
ORDER BY e.created_at DESC
LIMIT $3;

-- name: ListHTTPExecutionsByRequest :many
SELECT e.* FROM http_executions e
JOIN http_workspaces w ON w.id = e.http_workspace_id
WHERE e.request_id = $1 AND w.workspace_id = $2
ORDER BY e.created_at DESC
LIMIT $3;

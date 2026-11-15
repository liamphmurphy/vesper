-- User-built custom apps: one owner (workspace_id, user_id) per app.

-- name: ListCustomApps :many
SELECT a.*, db.size_bytes,
       (COALESCE(v.bundle_mcp_js, '') <> '')::bool AS has_mcp_server,
       COALESCE(v.mcp_tools, '[]'::jsonb)::jsonb AS mcp_tools
FROM custom_apps a
LEFT JOIN custom_app_databases db ON db.app_id = a.id
LEFT JOIN custom_app_versions v ON v.app_id = a.id AND v.seq = a.current_seq
WHERE a.workspace_id = $1 AND a.user_id = $2
ORDER BY lower(a.name), a.id;

-- name: GetCustomAppBySlug :one
SELECT a.*, db.size_bytes,
       (COALESCE(v.bundle_mcp_js, '') <> '')::bool AS has_mcp_server,
       COALESCE(v.mcp_tools, '[]'::jsonb)::jsonb AS mcp_tools
FROM custom_apps a
LEFT JOIN custom_app_databases db ON db.app_id = a.id
LEFT JOIN custom_app_versions v ON v.app_id = a.id AND v.seq = a.current_seq
WHERE a.workspace_id = $1 AND a.user_id = $2 AND a.slug = $3;

-- name: ListCustomAppsWithMCP :many
SELECT a.id, a.slug, a.name, a.description, a.manifest, a.capabilities, a.current_seq, v.bundle_mcp_js, v.mcp_tools
FROM custom_apps a
JOIN custom_app_versions v ON v.app_id = a.id AND v.seq = a.current_seq
WHERE a.workspace_id = $1 AND a.user_id = $2 AND v.bundle_mcp_js <> ''
ORDER BY lower(a.name), a.id;

-- name: GetCustomAppWithMCPBySlug :one
SELECT a.id, a.workspace_id, a.user_id, a.slug, a.name, a.description, a.manifest, a.capabilities, a.current_seq, v.bundle_mcp_js, v.mcp_tools
FROM custom_apps a
JOIN custom_app_versions v ON v.app_id = a.id AND v.seq = a.current_seq
WHERE a.workspace_id = $1 AND a.user_id = $2 AND a.slug = $3;

-- name: GetCustomAppForUpdate :one
SELECT * FROM custom_apps
WHERE workspace_id = $1 AND user_id = $2 AND slug = $3
FOR UPDATE;

-- name: InsertCustomApp :one
INSERT INTO custom_apps (workspace_id, user_id, slug, name, description, icon, space_id, current_seq, manifest, capabilities)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
RETURNING *;

-- name: UpdateCustomAppHead :one
UPDATE custom_apps
SET name = $2, description = $3, icon = $4, current_seq = $5, manifest = $6, capabilities = $7, updated_at = now()
WHERE id = $1
RETURNING *;

-- name: UpdateCustomAppCapabilities :one
UPDATE custom_apps
SET capabilities = $2, updated_at = now()
WHERE workspace_id = $1 AND user_id = $3 AND slug = $4
RETURNING *;

-- name: DeleteCustomApp :one
DELETE FROM custom_apps
WHERE workspace_id = $1 AND user_id = $2 AND slug = $3
RETURNING *;

-- name: InsertCustomAppVersion :one
INSERT INTO custom_app_versions (app_id, seq, note, author_type, agent_id, manifest, files, bundle_js, bundle_css, bundle_mcp_js, mcp_tools)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
RETURNING *;

-- name: GetCustomAppVersion :one
SELECT * FROM custom_app_versions
WHERE app_id = $1 AND seq = $2;

-- name: ListCustomAppVersions :many
SELECT id, app_id, seq, note, author_type, agent_id, created_at
FROM custom_app_versions
WHERE app_id = $1
ORDER BY seq DESC;

-- name: EnsureCustomAppDatabase :exec
INSERT INTO custom_app_databases (app_id)
VALUES ($1)
ON CONFLICT (app_id) DO NOTHING;

-- name: GetCustomAppDatabase :one
SELECT app_id, sqlite_bytes, size_bytes, updated_at
FROM custom_app_databases
WHERE app_id = $1;

-- name: GetCustomAppDatabaseForUpdate :one
SELECT app_id, sqlite_bytes, size_bytes, updated_at
FROM custom_app_databases
WHERE app_id = $1
FOR UPDATE;

-- name: UpdateCustomAppDatabase :exec
UPDATE custom_app_databases
SET sqlite_bytes = $2, size_bytes = $3, updated_at = now()
WHERE app_id = $1;

-- name: SyncAppSpaceMeta :exec
UPDATE chat_spaces
SET name = $2, instructions = $3, updated_at = now()
WHERE id = $1;

-- name: DeleteCustomAppSpace :exec
DELETE FROM chat_spaces
WHERE id = $1;

-- name: DeleteCustomAppDockChats :exec
DELETE FROM dock_chats
WHERE workspace_id = $1 AND user_id = $2 AND scope = $3;

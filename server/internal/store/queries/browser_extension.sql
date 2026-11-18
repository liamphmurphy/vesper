-- The Safari extension (docs/dev/safari-extension.md). Shares belong to one
-- person: every query filters on user_id (and workspace_id where it has one).

-- name: SetBrowserExtensionToken :exec
INSERT INTO browser_extension_tokens (user_id, token_hash) VALUES ($1, $2)
ON CONFLICT (user_id) DO UPDATE SET token_hash = EXCLUDED.token_hash, created_at = now();

-- name: BrowserExtensionTokenUser :one
SELECT user_id FROM browser_extension_tokens WHERE token_hash = $1;

-- name: ListBrowserNeverShare :many
SELECT host FROM browser_never_share WHERE user_id = $1 ORDER BY host;

-- name: AddBrowserNeverShare :exec
INSERT INTO browser_never_share (user_id, host) VALUES ($1, $2) ON CONFLICT DO NOTHING;

-- name: RemoveBrowserNeverShare :execrows
DELETE FROM browser_never_share WHERE user_id = $1 AND host = $2;

-- name: RecentBrowserShareChats :many
-- The chats a tab can be shared with: the person's most recent visible ones.
SELECT id, title, persona_id, last_message_at FROM chat_sessions
WHERE workspace_id = $1 AND created_by = $2 AND NOT archived AND NOT hidden AND NOT temporary
ORDER BY last_message_at DESC NULLS LAST, created_at DESC
LIMIT 8;

-- name: StopBrowserSharesForTab :exec
-- A tab is shared with one chat at a time; sharing it again ends the last.
UPDATE browser_shares SET stopped_at = now(), stop_reason = 'replaced'
WHERE user_id = $1 AND tab_id = $2 AND stopped_at IS NULL;

-- name: StopBrowserSharesForChat :exec
-- A chat shows one shared tab at a time; a new share ends the last.
UPDATE browser_shares SET stopped_at = now(), stop_reason = 'replaced'
WHERE chat_id = $1 AND stopped_at IS NULL;

-- name: CreateBrowserShare :one
INSERT INTO browser_shares (workspace_id, user_id, chat_id, tab_id, start_url, until, include_screenshot, url, title, page_text, snapshot_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $5, $8, $9, now())
RETURNING *;

-- name: GetBrowserShare :one
SELECT * FROM browser_shares WHERE id = $1 AND user_id = $2;

-- name: ActiveBrowserShares :many
SELECT * FROM browser_shares WHERE user_id = $1 AND stopped_at IS NULL ORDER BY started_at DESC;

-- name: ActiveBrowserShareForChat :one
SELECT * FROM browser_shares WHERE chat_id = $1 AND user_id = $2 AND stopped_at IS NULL;

-- name: LatestBrowserShareForChat :one
-- The chat banner's share: the active one, else the last to end (so it can say
-- sharing stopped).
SELECT * FROM browser_shares WHERE chat_id = $1 AND user_id = $2
ORDER BY (stopped_at IS NULL) DESC, started_at DESC
LIMIT 1;

-- name: UpdateBrowserShareSnapshot :one
UPDATE browser_shares SET url = $3, title = $4, page_text = $5, snapshot_at = now()
WHERE id = $1 AND user_id = $2 AND stopped_at IS NULL
RETURNING *;

-- name: StopBrowserShare :one
UPDATE browser_shares SET stopped_at = now(), stop_reason = $3
WHERE id = $1 AND user_id = $2 AND stopped_at IS NULL
RETURNING *;

-- name: SetBrowserShareScreenshot :exec
INSERT INTO browser_share_screenshots (share_id, jpeg) VALUES ($1, $2)
ON CONFLICT (share_id) DO UPDATE SET jpeg = EXCLUDED.jpeg;

-- name: ClearBrowserShareScreenshot :exec
DELETE FROM browser_share_screenshots WHERE share_id = $1;

-- name: GetBrowserShareScreenshot :one
SELECT jpeg FROM browser_share_screenshots WHERE share_id = $1;

-- name: RecordBrowserShareRead :one
INSERT INTO browser_share_reads (share_id, chat_id, persona_id, url) VALUES ($1, $2, $3, $4)
RETURNING *;

-- name: ListBrowserShareReads :many
SELECT r.id, r.url, r.read_at, coalesce(p.name, '')::text AS persona_name
FROM browser_share_reads r LEFT JOIN personas p ON p.id = r.persona_id
WHERE r.share_id = $1
ORDER BY r.read_at DESC
LIMIT 20;

-- Chat spaces. Every query is scoped to one person: (workspace_id, user_id)
-- or a space id already checked to be theirs.

-- name: GetAppSpace :one
SELECT * FROM chat_spaces WHERE workspace_id = @workspace_id AND user_id = @user_id AND app = @app_name::text;

-- name: CreateAppSpace :one
-- ON CONFLICT: two tabs opening the app at once get the same space.
INSERT INTO chat_spaces (workspace_id, user_id, name, description, color, instructions, connector_ids, space_memory, app)
VALUES (@workspace_id, @user_id, @name, @description, @color, @instructions, '{}', true, @app_name::text)
ON CONFLICT (workspace_id, user_id, app) WHERE app IS NOT NULL DO UPDATE SET updated_at = chat_spaces.updated_at
RETURNING *;

-- name: CreateChatSpace :one
INSERT INTO chat_spaces (workspace_id, user_id, name, description, color, instructions, persona_id, project_id, connector_ids, space_memory)
VALUES (@workspace_id, @user_id, @name, @description, @color, @instructions, sqlc.narg(persona_id), sqlc.narg(project_id), @connector_ids::uuid[], @space_memory)
RETURNING *;

-- name: GetChatSpace :one
SELECT * FROM chat_spaces WHERE id = @id AND workspace_id = @workspace_id AND user_id = @user_id;

-- name: GetChatSpaceByID :one
-- For a chat's own space, whose owner is the chat's creator.
SELECT * FROM chat_spaces WHERE id = @id;

-- name: ListChatSpaces :many
-- The person's spaces, oldest first: the order they're listed in the menu.
-- An app's space (app IS NOT NULL) is left out: the person reaches it through
-- the app, and it doesn't count toward their limit.
SELECT * FROM chat_spaces WHERE workspace_id = @workspace_id AND user_id = @user_id AND app IS NULL ORDER BY created_at, id;

-- name: ChatSpacesByIDs :many
SELECT * FROM chat_spaces WHERE id = ANY(@ids::uuid[]) AND workspace_id = @workspace_id AND user_id = @user_id;

-- name: UpdateChatSpace :one
-- Absent fields keep their value. clear_persona and clear_project reset those
-- defaults (the default persona; no project).
UPDATE chat_spaces SET
  name = coalesce(sqlc.narg(name), name),
  description = coalesce(sqlc.narg(description), description),
  color = coalesce(sqlc.narg(color), color),
  instructions = coalesce(sqlc.narg(instructions), instructions),
  persona_id = CASE WHEN @clear_persona::bool THEN NULL ELSE coalesce(sqlc.narg(persona_id), persona_id) END,
  project_id = CASE WHEN @clear_project::bool THEN NULL ELSE coalesce(sqlc.narg(project_id), project_id) END,
  connector_ids = coalesce(sqlc.narg(connector_ids)::uuid[], connector_ids),
  space_memory = coalesce(sqlc.narg(space_memory), space_memory),
  updated_at = now()
WHERE id = @id AND workspace_id = @workspace_id AND user_id = @user_id
RETURNING *;

-- name: DeleteChatSpace :many
-- Removes one of the person's spaces with its sources and memories; its chats
-- stay, outside any space. Returns the blob keys of the sources' files.
WITH d AS (
  DELETE FROM chat_spaces WHERE chat_spaces.id = @id AND chat_spaces.workspace_id = @workspace_id AND chat_spaces.user_id = @user_id RETURNING chat_spaces.id
)
SELECT s.blob_key::text FROM chat_space_sources s JOIN d ON d.id = s.space_id WHERE s.blob_key IS NOT NULL;

-- name: ChatSpaceStats :many
-- Per space: active chats, sources, live memories, repos, knowledge links and open tasks.
SELECT s.id,
  (SELECT count(*) FROM chat_sessions c WHERE c.space_id = s.id AND NOT c.archived AND NOT c.hidden)::int AS chat_count,
  (SELECT count(*) FROM chat_space_sources x WHERE x.space_id = s.id)::int AS source_count,
  (SELECT count(*) FROM memories m WHERE m.space_id = s.id AND m.superseded_by IS NULL)::int AS memory_count,
  (SELECT count(*) FROM chat_space_repositories r WHERE r.space_id = s.id)::int AS repo_count,
  (SELECT count(*) FROM chat_space_knowledge_links k WHERE k.space_id = s.id)::int AS knowledge_count,
  (SELECT count(*) FROM chat_space_tasks t WHERE t.space_id = s.id AND NOT t.done)::int AS open_task_count
FROM chat_spaces s WHERE s.id = ANY(@ids::uuid[]);

-- name: ListChatSpaceRepositories :many
SELECT * FROM chat_space_repositories WHERE space_id = @space_id ORDER BY created_at, id;

-- name: ListChatSpaceRepositoriesBySpaceIDs :many
SELECT * FROM chat_space_repositories WHERE space_id = ANY(@space_ids::uuid[]) ORDER BY space_id, created_at, id;

-- name: AddChatSpaceRepository :one
INSERT INTO chat_space_repositories (space_id, repo_url, read_only)
VALUES (@space_id, @repo_url, @read_only)
RETURNING *;

-- name: UpdateChatSpaceRepository :one
UPDATE chat_space_repositories
SET read_only = coalesce(sqlc.narg(read_only), read_only)
WHERE id = @id AND space_id = @space_id
RETURNING *;

-- name: DeleteChatSpaceRepository :one
DELETE FROM chat_space_repositories WHERE id = @id AND space_id = @space_id RETURNING *;

-- name: ListChatSpaceKnowledgeLinks :many
SELECT * FROM chat_space_knowledge_links WHERE space_id = @space_id ORDER BY created_at, id;

-- name: ListChatSpaceKnowledgeLinksBySpaceIDs :many
SELECT * FROM chat_space_knowledge_links WHERE space_id = ANY(@space_ids::uuid[]) ORDER BY space_id, created_at, id;

-- name: AddChatSpaceKnowledgeLink :one
INSERT INTO chat_space_knowledge_links (space_id, kind, path, is_default_target, pinned)
VALUES (@space_id, @kind, @path, @is_default_target, @pinned)
RETURNING *;

-- name: ClearSpaceDefaultKnowledgeTarget :exec
UPDATE chat_space_knowledge_links
SET is_default_target = false
WHERE space_id = @space_id AND is_default_target = true;

-- name: UpdateChatSpaceKnowledgeLink :one
UPDATE chat_space_knowledge_links
SET is_default_target = coalesce(sqlc.narg(is_default_target), is_default_target),
    pinned = coalesce(sqlc.narg(pinned), pinned)
WHERE id = @id AND space_id = @space_id
RETURNING *;

-- name: DeleteChatSpaceKnowledgeLink :one
DELETE FROM chat_space_knowledge_links WHERE id = @id AND space_id = @space_id RETURNING *;

-- name: RenameSpaceKnowledgeLinksFolder :exec
UPDATE chat_space_knowledge_links l
SET path = CASE
  WHEN l.path = @from_path::text THEN @to_path::text
  ELSE @to_path::text || substring(l.path FROM length(@from_path::text) + 1)
END
FROM chat_spaces s
WHERE l.space_id = s.id
  AND s.workspace_id = @workspace_id
  AND s.user_id = @user_id
  AND (l.path = @from_path::text OR l.path LIKE @from_path::text || '/%');

-- name: RenameSpaceKnowledgeLinksPage :exec
UPDATE chat_space_knowledge_links l
SET path = @to_path::text
FROM chat_spaces s
WHERE l.space_id = s.id
  AND s.workspace_id = @workspace_id
  AND s.user_id = @user_id
  AND l.kind = 'page'
  AND l.path = @from_path::text;

-- name: CountNotesInFolderPrefix :one
SELECT count(*)::int FROM artifacts a
WHERE a.workspace_id = @workspace_id
  AND a.type = 'note'
  AND a.path IS NOT NULL
  AND (a.owner_user_id IS NULL OR a.owner_user_id = @user_id)
  AND (a.path = @folder::text OR a.path LIKE @folder::text || '/%');

-- name: ListChatSpaceTasks :many
SELECT t.*, c.title AS chat_title
FROM chat_space_tasks t
LEFT JOIN chat_sessions c ON c.id = t.chat_id
WHERE t.space_id = @space_id
ORDER BY t.done ASC, t.position ASC, t.created_at ASC, t.id ASC;

-- name: GetChatSpaceTask :one
SELECT t.*, c.title AS chat_title
FROM chat_space_tasks t
LEFT JOIN chat_sessions c ON c.id = t.chat_id
WHERE t.id = @id AND t.space_id = @space_id;

-- name: CreateChatSpaceTask :one
INSERT INTO chat_space_tasks (space_id, title, notes, position)
VALUES (
  @space_id,
  @title,
  @notes,
  COALESCE((SELECT max(position) + 1 FROM chat_space_tasks WHERE space_id = @space_id), 0)
)
RETURNING *;

-- name: UpdateChatSpaceTask :one
UPDATE chat_space_tasks
SET title = coalesce(sqlc.narg(title), title),
    notes = coalesce(sqlc.narg(notes), notes),
    done = coalesce(sqlc.narg(done), done),
    chat_id = CASE WHEN @clear_chat::bool THEN NULL ELSE coalesce(sqlc.narg(chat_id), chat_id) END,
    position = coalesce(sqlc.narg(position), position),
    updated_at = now()
WHERE id = @id AND space_id = @space_id
RETURNING *;

-- name: LinkChatSpaceTaskChat :exec
UPDATE chat_space_tasks
SET chat_id = @chat_id, updated_at = now()
WHERE id = @id AND space_id = @space_id;

-- name: DeleteChatSpaceTask :one
DELETE FROM chat_space_tasks WHERE id = @id AND space_id = @space_id RETURNING *;

-- name: ListChatSpacePushRequests :many
SELECT pr.id, pr.chat_id, c.title AS chat_title, pr.repo_url, pr.branch, pr.title AS pr_title,
       pr.state, pr.pr_url, pr.pr_number, pr.created_at, pr.decided_at
FROM push_requests pr
JOIN chat_sessions c ON c.id = pr.chat_id
WHERE c.space_id = @space_id AND c.workspace_id = @workspace_id AND c.created_by = @user_id AND NOT c.hidden
ORDER BY pr.created_at DESC
LIMIT 50;

-- name: ListChatSpaceCodeReviews :many
SELECT cr.chat_id, c.title AS chat_title, cr.repo_url, cr.branch, cr.dirty, cr.live, cr.updated_at
FROM chat_code_reviews cr
JOIN chat_sessions c ON c.id = cr.chat_id
WHERE c.space_id = @space_id AND c.workspace_id = @workspace_id AND c.created_by = @user_id AND NOT c.hidden
  AND cr.branch IS NOT NULL AND cr.branch <> ''
ORDER BY cr.updated_at DESC
LIMIT 50;

-- name: CreateChatSpaceSource :one
INSERT INTO chat_space_sources (space_id, kind, title, url, body, filename, content_type, size_bytes, blob_key, tokens)
VALUES (@space_id, @kind, @title, sqlc.narg(url), @body, sqlc.narg(filename), @content_type, @size_bytes, sqlc.narg(blob_key), @tokens)
RETURNING *;

-- name: CreateResearchSpaceSource :one
-- A research report as a source. A report already added is left alone.
INSERT INTO chat_space_sources (space_id, kind, title, body, content_type, size_bytes, tokens, research_job_id, chat_id)
VALUES (@space_id, 'research', @title, @body, 'text/markdown', @size_bytes, @tokens, @research_job_id, @chat_id)
ON CONFLICT (research_job_id) DO NOTHING
RETURNING *;

-- name: ListChatSpaceSources :many
-- Oldest first: the order the inline budget is filled in.
SELECT * FROM chat_space_sources WHERE space_id = @space_id ORDER BY created_at, id;

-- name: CountChatSpaceSources :one
SELECT count(*)::int FROM chat_space_sources WHERE space_id = @space_id;

-- name: DeleteChatSpaceSource :one
DELETE FROM chat_space_sources WHERE id = @id AND space_id = @space_id RETURNING *;

-- name: SetChatSpace :one
UPDATE chat_sessions SET space_id = sqlc.narg(space_id) WHERE id = @id RETURNING *;

-- name: ChatLastReplies :many
-- The newest assistant reply of each chat, for a one-line preview.
SELECT DISTINCT ON (session_id) session_id, left(body_md, 600)::text AS body
FROM chat_messages WHERE session_id = ANY(@ids::uuid[]) AND role = 'assistant'
ORDER BY session_id, seq DESC;

-- name: ListUserCanvases :many
-- The person's canvases across their chats, most recently changed first.
SELECT cv.id, cv.kind, cv.title, cv.updated_at, c.id AS chat_id, c.title AS chat_title
FROM chat_canvases cv JOIN chat_sessions c ON c.id = cv.session_id
WHERE c.workspace_id = @workspace_id AND c.created_by = @user_id AND NOT c.hidden
ORDER BY cv.updated_at DESC, cv.id DESC
LIMIT 100;

-- name: GetMyCanvas :one
-- One of the person's canvases, with the chat it lives in.
SELECT cv.id, cv.kind, cv.title, cv.updated_at, cv.reviewed_seq, c.id AS chat_id, c.title AS chat_title
FROM chat_canvases cv JOIN chat_sessions c ON c.id = cv.session_id
WHERE cv.id = @id AND c.workspace_id = @workspace_id AND c.created_by = @user_id AND NOT c.hidden;

-- name: MarkMyCanvasReviewed :one
-- Records that the person has reviewed one of their canvases up to a version
-- it has. Never moves back, so a stale tab can't reopen a finished review.
UPDATE chat_canvases cv SET reviewed_seq = GREATEST(cv.reviewed_seq, @seq::int)
FROM chat_sessions c
WHERE cv.id = @id AND c.id = cv.session_id AND c.workspace_id = @workspace_id AND c.created_by = @user_id AND NOT c.hidden
  AND @seq::int <= (SELECT max(seq) FROM chat_canvas_versions WHERE canvas_id = cv.id)
RETURNING cv.reviewed_seq;

-- name: GetUserCanvas :one
-- One of the person's canvases with its current text.
SELECT cv.id, cv.kind, cv.title, v.body
FROM chat_canvases cv JOIN chat_sessions c ON c.id = cv.session_id
JOIN LATERAL (SELECT body FROM chat_canvas_versions WHERE canvas_id = cv.id ORDER BY seq DESC LIMIT 1) v ON true
WHERE cv.id = @id AND c.workspace_id = @workspace_id AND c.created_by = @user_id;

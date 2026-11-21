-- name: ListRepositorySources :many
SELECT * FROM repository_sources WHERE workspace_id = $1 AND user_id = $2 ORDER BY kind, name;

-- name: AddRepositorySource :exec
INSERT INTO repository_sources (workspace_id, user_id, kind, name) VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING;

-- name: DeleteRepositorySource :exec
DELETE FROM repository_sources WHERE workspace_id = $1 AND user_id = $2 AND kind = $3 AND name = $4;

-- name: ChatRepositories :many
SELECT * FROM chat_repositories WHERE chat_id = $1 ORDER BY directory;

-- name: AttachChatRepository :one
INSERT INTO chat_repositories (chat_id, repo_url, directory) VALUES ($1, $2, $3)
ON CONFLICT (chat_id, repo_url) DO UPDATE SET repo_url = excluded.repo_url RETURNING *;

-- name: AttachChatRepositoryWithFork :one
INSERT INTO chat_repositories (chat_id, repo_url, directory, checkpoint_branch, fork_branch)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (chat_id, repo_url) DO UPDATE
SET checkpoint_branch = excluded.checkpoint_branch, fork_branch = excluded.fork_branch
RETURNING *;

-- name: ActivateChatRepository :one
UPDATE chat_sessions SET repo_url = r.repo_url, work_branches = r.work_branches, revision = revision + 1, updated_at = now()
FROM chat_repositories r WHERE chat_sessions.id = $1 AND r.chat_id = chat_sessions.id AND r.repo_url = $2
RETURNING chat_sessions.*;

-- name: SaveRepositoryBranches :exec
UPDATE chat_repositories SET work_branches = (
 SELECT coalesce(array_agg(b ORDER BY first), '{}') FROM (
  SELECT b, min(n) AS first FROM unnest(work_branches || @branches::text[]) WITH ORDINALITY AS t(b,n)
  GROUP BY b ORDER BY first LIMIT 50
 ) kept
) WHERE chat_id = @chat_id AND repo_url = @repo_url;

-- name: SetRepositoryCheckpoint :exec
UPDATE chat_repositories SET checkpoint_branch = $3 WHERE chat_id = $1 AND repo_url = $2;

-- name: QueueChatRepository :one
UPDATE chat_sessions SET pending_repo_url = $2, revision = revision + 1, updated_at = now() WHERE id = $1 RETURNING *;

-- name: RefreshChatRepositoryBranches :exec
UPDATE chat_sessions SET work_branches = r.work_branches FROM chat_repositories r
WHERE chat_sessions.id = $1 AND r.chat_id = chat_sessions.id AND r.repo_url = chat_sessions.repo_url;

-- name: ClearPendingChatRepository :exec
UPDATE chat_sessions SET pending_repo_url = NULL WHERE id = $1;

-- name: PreviousChatWorkspaces :many
SELECT * FROM runs r WHERE r.id <> @run_id AND r.purpose = 'chat'
AND r.state IN ('completed', 'failed', 'cancelled') AND r.workspace_volume IS NOT NULL AND r.checkpoint_at IS NULL
AND r.id IN (SELECT m.run_id FROM chat_messages m WHERE m.session_id = @chat_id)
ORDER BY r.ended_at, r.id;

-- name: ChatRepositoriesForChats :many
SELECT * FROM chat_repositories WHERE chat_id = ANY($1::uuid[]) ORDER BY chat_id, directory;

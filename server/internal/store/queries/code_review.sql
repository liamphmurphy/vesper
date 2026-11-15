-- name: UpsertChatCodeReview :exec
INSERT INTO chat_code_reviews (chat_id, repo_url, branch, base_sha, head_sha, commits, files, dirty, live, tree, tree_truncated, updated_at)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, now())
ON CONFLICT (chat_id, repo_url) DO UPDATE SET
  branch = EXCLUDED.branch, base_sha = EXCLUDED.base_sha, head_sha = EXCLUDED.head_sha,
  commits = EXCLUDED.commits, files = EXCLUDED.files, dirty = EXCLUDED.dirty,
  live = EXCLUDED.live, tree = EXCLUDED.tree, tree_truncated = EXCLUDED.tree_truncated, updated_at = now();

-- name: SetChatCodeReviewsSettled :exec
-- A turn ended: nothing is changing the workspace any more.
UPDATE chat_code_reviews SET live = false WHERE chat_id = $1 AND live;

-- name: ChatCodeReviews :many
SELECT * FROM chat_code_reviews WHERE chat_id = $1 ORDER BY repo_url;

-- name: GetRepositoryPushPolicy :one
SELECT * FROM repository_push_policies WHERE user_id = $1 AND repo_url = $2;

-- name: SetRepositoryPushPolicy :one
INSERT INTO repository_push_policies (workspace_id, user_id, repo_url, auto_push, updated_at)
VALUES ($1, $2, $3, $4, now())
ON CONFLICT (user_id, repo_url) DO UPDATE SET auto_push = EXCLUDED.auto_push, updated_at = now()
RETURNING *;

-- name: ListRepositoryPushPolicies :many
SELECT * FROM repository_push_policies WHERE workspace_id = $1 AND user_id = $2 AND auto_push ORDER BY repo_url;

-- name: CreatePushRequest :one
INSERT INTO push_requests (workspace_id, user_id, chat_id, run_id, persona_id, agent_id, repo_url, branch, title, body, draft)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11) RETURNING *;

-- name: CountOpenPushRequests :one
SELECT count(*)::int FROM push_requests WHERE chat_id = $1 AND state IN ('staging', 'pending');

-- name: SupersedePushRequests :many
-- A newer request for the same branch replaces any that still wait.
UPDATE push_requests SET state = 'declined', error = 'Replaced by a newer request for this branch.', decided_at = now()
WHERE chat_id = $1 AND repo_url = $2 AND branch = $3 AND state IN ('staging', 'pending') AND id <> $4
RETURNING *;

-- name: StagingPushRequests :many
-- What a chat asked to push and the runner hasn't staged yet, oldest first.
SELECT * FROM push_requests WHERE chat_id = $1 AND state = 'staging' ORDER BY created_at, id;

-- name: SetPushRequestStaged :one
UPDATE push_requests SET state = 'pending', base_branch = $2, base_sha = $3, head_sha = $4, staging_ref = $5, commits = $6, files = $7
WHERE id = $1 AND state = 'staging' RETURNING *;

-- name: ClaimPushRequest :one
-- Approving moves a waiting request to pushing; only one click wins. The
-- person may edit the pull request's title, body and draft flag on the card.
UPDATE push_requests SET state = 'pushing', title = $4, body = $5, draft = $6, auto = $7, decided_at = now()
WHERE id = $1 AND workspace_id = $2 AND user_id = $3 AND state = 'pending' RETURNING *;

-- name: ClaimStagedPushRequest :one
-- The runner's own claim for a repository the person always allows.
UPDATE push_requests SET state = 'pushing', auto = true, decided_at = now()
WHERE id = $1 AND state = 'pending' RETURNING *;

-- name: FinishPushRequest :one
UPDATE push_requests SET state = $2, error = $3, pr_url = $4, pr_number = $5, decided_at = coalesce(decided_at, now())
WHERE id = $1 RETURNING *;

-- name: DeclinePushRequest :one
UPDATE push_requests SET state = 'declined', decided_at = now()
WHERE id = $1 AND workspace_id = $2 AND user_id = $3 AND state = 'pending' RETURNING *;

-- name: GetPushRequest :one
SELECT * FROM push_requests WHERE id = $1 AND workspace_id = $2 AND user_id = $3;

-- name: ChatPushRequests :many
-- The cards a chat shows: every request still open, and the latest decided ones.
SELECT * FROM (
  SELECT * FROM push_requests WHERE chat_id = $1
  ORDER BY (state IN ('staging', 'pending', 'pushing')) DESC, created_at DESC LIMIT 20
) r ORDER BY created_at, id;

-- name: AddChatWorkBranch :exec
-- A branch Vesper pushed for the chat, so later turns may build on it.
UPDATE chat_repositories SET work_branches = array_append(work_branches, sqlc.arg(branch)::text)
WHERE chat_id = $1 AND repo_url = $2 AND NOT (sqlc.arg(branch)::text = ANY(work_branches));

-- name: RecordRunCheckpoint :exec
INSERT INTO run_checkpoints (workspace_id, run_id, chat_id, ticket_id, repo_url, branch, commit_sha, tree_sha, source_branch, has_uncommitted)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
ON CONFLICT (repo_url, branch) DO UPDATE SET
  run_id = coalesce(EXCLUDED.run_id, run_checkpoints.run_id),
  commit_sha = coalesce(EXCLUDED.commit_sha, run_checkpoints.commit_sha),
  tree_sha = coalesce(EXCLUDED.tree_sha, run_checkpoints.tree_sha),
  source_branch = CASE WHEN EXCLUDED.source_branch <> '' THEN EXCLUDED.source_branch ELSE run_checkpoints.source_branch END,
  has_uncommitted = EXCLUDED.has_uncommitted,
  deleted_at = NULL,
  last_checked_pr_sha = NULL;

-- name: OpenChatCheckpoints :many
SELECT * FROM run_checkpoints
WHERE chat_id = sqlc.arg(chat_id)::uuid AND repo_url = sqlc.arg(repo_url) AND deleted_at IS NULL
ORDER BY created_at, id;

-- name: OpenTicketCheckpoints :many
SELECT * FROM run_checkpoints
WHERE ticket_id = sqlc.arg(ticket_id)::uuid AND deleted_at IS NULL
ORDER BY created_at, id;

-- name: MarkCheckpointRecovered :exec
UPDATE run_checkpoints
SET recovered_by_run_id = sqlc.arg(recovered_by_run_id)::uuid
WHERE repo_url = sqlc.arg(repo_url) AND branch = sqlc.arg(branch) AND deleted_at IS NULL;

-- name: MarkCheckpointDeleted :exec
UPDATE run_checkpoints SET deleted_at = now()
WHERE id = $1 AND deleted_at IS NULL;

-- name: MarkCheckpointCheckedPR :exec
UPDATE run_checkpoints SET last_checked_pr_sha = $2
WHERE id = $1 AND deleted_at IS NULL;

-- name: ClearRepositoryCheckpointIfMatches :exec
UPDATE chat_repositories SET checkpoint_branch = NULL
WHERE chat_id = $1 AND repo_url = $2 AND checkpoint_branch = $3;

-- name: ClearRunCheckpointIfMatches :exec
UPDATE runs SET checkpoint_branch = NULL
WHERE id = $1 AND checkpoint_branch = $2;

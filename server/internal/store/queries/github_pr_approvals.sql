-- name: WorkspacesWithGitHubToken :many
-- Workspaces that stored a workspace-wide git:pat, the token the PR feeds use.
SELECT DISTINCT workspace_id FROM secrets WHERE name = 'git:pat' AND project_id IS NULL;

-- name: UpsertGitHubPRApproval :exec
-- Only a newer approval moves approved_at, so re-polling the same one changes nothing.
INSERT INTO github_pr_approvals (workspace_id, repository, number, title, url, approver, approved_at)
VALUES ($1, $2, $3, $4, $5, $6, $7)
ON CONFLICT (workspace_id, repository, number) DO UPDATE
SET title = EXCLUDED.title, url = EXCLUDED.url, approver = EXCLUDED.approver, approved_at = EXCLUDED.approved_at
WHERE EXCLUDED.approved_at > github_pr_approvals.approved_at;

-- +goose Up
-- Pull requests the connected GitHub user authored that a reviewer approved. The
-- poller (githubpr.ApprovalSyncer) upserts a row whenever it sees an open PR with
-- an approving review and no outstanding changes request; approved_at is the
-- latest approving review's time, so a fresh approval is a new inbox item.
CREATE TABLE github_pr_approvals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  repository text NOT NULL,
  number integer NOT NULL,
  title text NOT NULL,
  url text NOT NULL,
  approver text NOT NULL DEFAULT '',
  approved_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, repository, number)
);
CREATE INDEX github_pr_approvals_recent_idx ON github_pr_approvals (workspace_id, approved_at DESC);

-- +goose Down
DROP TABLE github_pr_approvals;

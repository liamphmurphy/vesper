-- +goose Up
-- Tracks every vesper-checkpoint/... branch Vesper pushes for a chat repository
-- or ticket run so all of them can be verified and deleted once a successful PR
-- contains their changes (chat_repositories.checkpoint_branch only holds the
-- latest segment's branch, and runs.checkpoint_branch only holds one per run).
CREATE TABLE run_checkpoints (
  id                  uuid PRIMARY KEY DEFAULT uuid_v7(),
  workspace_id        uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  run_id              uuid REFERENCES runs(id) ON DELETE SET NULL,
  chat_id             uuid REFERENCES chat_sessions(id) ON DELETE CASCADE,
  ticket_id           uuid REFERENCES tickets(id) ON DELETE CASCADE,
  repo_url            text NOT NULL,
  branch              text NOT NULL,
  commit_sha          text,
  tree_sha            text,
  source_branch       text NOT NULL DEFAULT '',
  has_uncommitted     boolean NOT NULL DEFAULT false,
  recovered_by_run_id uuid REFERENCES runs(id) ON DELETE SET NULL,
  last_checked_pr_sha text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,
  UNIQUE (repo_url, branch),
  CHECK (chat_id IS NOT NULL OR ticket_id IS NOT NULL)
);

CREATE INDEX run_checkpoints_chat_open
  ON run_checkpoints (chat_id, repo_url)
  WHERE deleted_at IS NULL AND chat_id IS NOT NULL;

CREATE INDEX run_checkpoints_ticket_open
  ON run_checkpoints (ticket_id)
  WHERE deleted_at IS NULL AND ticket_id IS NOT NULL;

-- Backfill existing chat repository checkpoints.
INSERT INTO run_checkpoints (workspace_id, chat_id, repo_url, branch)
SELECT cs.workspace_id, cr.chat_id, cr.repo_url, cr.checkpoint_branch
FROM chat_repositories cr
JOIN chat_sessions cs ON cs.id = cr.chat_id
WHERE cr.checkpoint_branch IS NOT NULL
ON CONFLICT (repo_url, branch) DO NOTHING;

-- Backfill earlier-segment chat checkpoints recorded on runs whose
-- chat_repositories.checkpoint_branch was later overwritten.
INSERT INTO run_checkpoints (workspace_id, run_id, chat_id, repo_url, branch)
SELECT DISTINCT ON (cr.repo_url, r.checkpoint_branch)
  r.workspace_id, r.id, cr.chat_id, cr.repo_url, r.checkpoint_branch
FROM runs r
JOIN chat_messages m ON m.run_id = r.id
JOIN chat_repositories cr ON cr.chat_id = m.session_id
WHERE r.purpose = 'chat'
  AND r.checkpoint_branch IS NOT NULL
  AND split_part(r.checkpoint_branch, '/', 2) = 'chat'
  AND split_part(r.checkpoint_branch, '/', 3) = left(encode(sha256(convert_to(cr.repo_url, 'UTF8')), 'hex'), 16)
ON CONFLICT (repo_url, branch) DO NOTHING;

-- Backfill existing ticket run checkpoints.
INSERT INTO run_checkpoints (workspace_id, run_id, ticket_id, repo_url, branch)
SELECT r.workspace_id, r.id, r.ticket_id, p.repo_url, r.checkpoint_branch
FROM runs r
JOIN tickets t ON t.id = r.ticket_id
JOIN projects p ON p.id = t.project_id
WHERE r.purpose = 'ticket'
  AND r.checkpoint_branch IS NOT NULL
  AND r.ticket_id IS NOT NULL
  AND p.repo_url IS NOT NULL
  AND p.repo_url <> ''
ON CONFLICT (repo_url, branch) DO NOTHING;

-- +goose Down
DROP TABLE run_checkpoints;

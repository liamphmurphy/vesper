-- +goose Up
ALTER TABLE dev_workspaces
  DROP CONSTRAINT IF EXISTS dev_workspaces_action_check,
  ADD CONSTRAINT dev_workspaces_action_check
    CHECK (action IS NULL OR action IN ('start', 'rebuild', 'sync', 'stop', 'open_branch')),
  ADD COLUMN target_repo text,
  ADD COLUMN target_branch text,
  ADD COLUMN target_pr_number integer;

ALTER TABLE push_requests
  ADD COLUMN pr_state text
    CHECK (pr_state IS NULL OR pr_state IN ('draft', 'open', 'merged', 'closed')),
  ADD COLUMN pr_synced_at timestamptz;

UPDATE push_requests
SET pr_state = CASE WHEN draft THEN 'draft' ELSE 'open' END
WHERE state = 'pushed' AND pr_url IS NOT NULL AND pr_state IS NULL;

-- +goose Down
ALTER TABLE push_requests
  DROP COLUMN IF EXISTS pr_synced_at,
  DROP COLUMN IF EXISTS pr_state;

ALTER TABLE dev_workspaces
  DROP COLUMN IF EXISTS target_pr_number,
  DROP COLUMN IF EXISTS target_branch,
  DROP COLUMN IF EXISTS target_repo,
  DROP CONSTRAINT IF EXISTS dev_workspaces_action_check,
  ADD CONSTRAINT dev_workspaces_action_check
    CHECK (action IS NULL OR action IN ('start', 'rebuild', 'sync', 'stop'));

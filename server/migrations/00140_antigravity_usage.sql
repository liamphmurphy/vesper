-- +goose Up
-- Allow queued Antigravity usage checks alongside Claude Code and Codex.
ALTER TABLE harness_usage_checks DROP CONSTRAINT IF EXISTS harness_usage_checks_harness_check;
ALTER TABLE harness_usage_checks ADD CONSTRAINT harness_usage_checks_harness_check
  CHECK (harness IN ('claude-code', 'codex', 'antigravity'));

-- +goose Down
DELETE FROM harness_usage_checks WHERE harness = 'antigravity';
ALTER TABLE harness_usage_checks DROP CONSTRAINT IF EXISTS harness_usage_checks_harness_check;
ALTER TABLE harness_usage_checks ADD CONSTRAINT harness_usage_checks_harness_check
  CHECK (harness IN ('claude-code', 'codex'));

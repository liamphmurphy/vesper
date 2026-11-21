-- +goose Up
ALTER TABLE chat_sessions
  ADD COLUMN compact_pending BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN compact_focus TEXT NOT NULL DEFAULT '',
  ADD COLUMN auto_rollover_tokens BIGINT,
  ADD COLUMN forked_from_chat_id UUID REFERENCES chat_sessions(id) ON DELETE SET NULL,
  ADD COLUMN forked_from_message_id UUID;

ALTER TABLE chat_repositories
  ADD COLUMN fork_branch TEXT;

ALTER TABLE chat_messages
  ADD COLUMN git_branch TEXT,
  ADD COLUMN git_commit_sha TEXT;

CREATE INDEX chat_sessions_forked_from_idx
  ON chat_sessions(forked_from_chat_id) WHERE forked_from_chat_id IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS chat_sessions_forked_from_idx;
ALTER TABLE chat_messages
  DROP COLUMN IF EXISTS git_commit_sha,
  DROP COLUMN IF EXISTS git_branch;
ALTER TABLE chat_repositories
  DROP COLUMN IF EXISTS fork_branch;
ALTER TABLE chat_sessions
  DROP COLUMN IF EXISTS forked_from_message_id,
  DROP COLUMN IF EXISTS forked_from_chat_id,
  DROP COLUMN IF EXISTS auto_rollover_tokens,
  DROP COLUMN IF EXISTS compact_focus,
  DROP COLUMN IF EXISTS compact_pending;

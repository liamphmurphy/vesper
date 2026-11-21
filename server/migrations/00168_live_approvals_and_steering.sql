-- +goose Up
-- Live in-turn tool approvals for chats (nullable ticket_id, optional chat_id)
-- and mid-turn steering queue for active chat turns.

ALTER TABLE approval_requests
  ALTER COLUMN ticket_id DROP NOT NULL,
  ADD COLUMN chat_id uuid REFERENCES chat_sessions(id) ON DELETE CASCADE,
  ADD CONSTRAINT approval_requests_owner_check CHECK (ticket_id IS NOT NULL OR chat_id IS NOT NULL);

CREATE INDEX approval_requests_chat_pending_idx
  ON approval_requests (chat_id, created_at)
  WHERE chat_id IS NOT NULL AND state = 'pending';

CREATE TABLE chat_steers (
  id           uuid PRIMARY KEY DEFAULT uuid_v7(),
  session_id   uuid NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  run_id       uuid NOT NULL REFERENCES runs(id) ON DELETE CASCADE,
  message_id   uuid NOT NULL REFERENCES chat_messages(id) ON DELETE CASCADE,
  body         text NOT NULL CHECK (length(body) >= 1 AND length(body) <= 20000),
  state        text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'delivered', 'fallback', 'expired')),
  created_at   timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz
);

CREATE INDEX chat_steers_pending_idx
  ON chat_steers (run_id, created_at)
  WHERE state = 'pending';

-- +goose Down
DROP INDEX IF EXISTS chat_steers_pending_idx;
DROP TABLE IF EXISTS chat_steers;
DROP INDEX IF EXISTS approval_requests_chat_pending_idx;
ALTER TABLE approval_requests
  DROP CONSTRAINT IF EXISTS approval_requests_owner_check,
  DROP COLUMN IF EXISTS chat_id,
  ALTER COLUMN ticket_id SET NOT NULL;

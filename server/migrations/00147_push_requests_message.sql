-- +goose Up
-- Anchor push requests to the turn and reply message that asked for them,
-- so cards stay at their place in the chat history instead of stacking at the bottom.
ALTER TABLE push_requests
  ADD COLUMN turn_id uuid REFERENCES run_turns(id) ON DELETE SET NULL,
  ADD COLUMN message_id uuid REFERENCES chat_messages(id) ON DELETE SET NULL;

CREATE INDEX push_requests_message ON push_requests (message_id) WHERE message_id IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS push_requests_message;
ALTER TABLE push_requests
  DROP COLUMN IF EXISTS message_id,
  DROP COLUMN IF EXISTS turn_id;

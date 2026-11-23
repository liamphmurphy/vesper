-- +goose Up
-- Persisted tick state for interactive markdown checklists in assistant chat
-- messages, keyed by 0-based task item index (e.g. {"0": true, "2": false}).
ALTER TABLE chat_messages ADD COLUMN checklist_state jsonb NOT NULL DEFAULT '{}'::jsonb;

-- +goose Down
ALTER TABLE chat_messages DROP COLUMN checklist_state;

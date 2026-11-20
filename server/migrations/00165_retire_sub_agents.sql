-- +goose Up
-- "sub" agents (personas that "help on runs") existed only to be delegate
-- targets; delegate now starts a fresh copy of the lead instead. A persona
-- that helped stops working: its record is archived, as turning its work off
-- would, so its runs and history stay, and it becomes a main record, so
-- turning its work back on makes it take tickets.
UPDATE agents SET archived_at = coalesce(archived_at, now()), kind = 'main' WHERE kind = 'sub';
ALTER TABLE agents DROP CONSTRAINT agents_kind_check;
ALTER TABLE agents ADD CONSTRAINT agents_kind_check CHECK (kind IN ('main', 'assistant'));

-- +goose Down
-- Which records were helpers isn't kept; only the constraint comes back.
ALTER TABLE agents DROP CONSTRAINT agents_kind_check;
ALTER TABLE agents ADD CONSTRAINT agents_kind_check CHECK (kind IN ('main', 'sub', 'assistant'));

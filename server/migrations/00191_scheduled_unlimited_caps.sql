-- +goose Up
-- Scheduled tasks default to unlimited time and spend (NULL), matching
-- subscription harnesses that have no per-run API bill, while still allowing
-- optional per-task caps.
ALTER TABLE scheduled_tasks
  ALTER COLUMN max_minutes DROP NOT NULL,
  ALTER COLUMN max_minutes DROP DEFAULT,
  ALTER COLUMN max_cost_micros DROP NOT NULL,
  ALTER COLUMN max_cost_micros DROP DEFAULT;

-- +goose Down
UPDATE scheduled_tasks SET max_minutes = 15 WHERE max_minutes IS NULL;
UPDATE scheduled_tasks SET max_cost_micros = 1000000 WHERE max_cost_micros IS NULL;
ALTER TABLE scheduled_tasks
  ALTER COLUMN max_minutes SET DEFAULT 15,
  ALTER COLUMN max_minutes SET NOT NULL,
  ALTER COLUMN max_cost_micros SET DEFAULT 1000000,
  ALTER COLUMN max_cost_micros SET NOT NULL;

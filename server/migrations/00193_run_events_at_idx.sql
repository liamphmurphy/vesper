-- +goose Up
-- Speeds up turn-windowed GET /runs/{id}/events?since=<timestamp> queries on long chat runs.
CREATE INDEX IF NOT EXISTS run_events_run_at_idx
    ON run_events (run_id, at, seq);

-- +goose Down
DROP INDEX IF EXISTS run_events_run_at_idx;

-- +goose Up
-- A temporary cap on how many runs a runner takes at once, below its
-- max_concurrent (RUNNER_MAX_CONCURRENT). The desktop app sets it while the Mac
-- is under thermal pressure or in Low Power Mode and clears it after. It lives
-- on the runner's registration, which is deleted when the runner stops, so a
-- cap can't outlive the process that set it.
ALTER TABLE runners ADD COLUMN slot_limit integer CHECK (slot_limit BETWEEN 1 AND 32);

-- +goose Down
ALTER TABLE runners DROP COLUMN slot_limit;

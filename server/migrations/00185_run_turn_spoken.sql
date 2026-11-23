-- +goose Up
-- Whether the person said this turn's message out loud in Live Voice, so the
-- runner voices only spoken turns' replies ahead of the client asking.
ALTER TABLE run_turns ADD COLUMN spoken boolean NOT NULL DEFAULT false;

-- +goose Down
ALTER TABLE run_turns DROP COLUMN spoken;

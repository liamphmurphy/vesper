-- +goose Up
-- How long each of a persona's state loops is. Omni pins a clip's first and
-- last frames (which makes it loop) for 3-10s clips; 8s fits two or three
-- natural beats per generation, which matters when the daily generation
-- quota, not tokens, is the limit.
ALTER TABLE personas ADD COLUMN loop_seconds integer NOT NULL DEFAULT 8 CHECK (loop_seconds BETWEEN 4 AND 10);

-- +goose Down
ALTER TABLE personas DROP COLUMN loop_seconds;

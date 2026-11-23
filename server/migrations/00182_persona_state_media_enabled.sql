-- +goose Up
-- Whether a persona's generated state loops are displayed. Turning it off
-- keeps the stored loops and blobs intact so re-enabling brings them back.
ALTER TABLE personas ADD COLUMN state_media_enabled boolean NOT NULL DEFAULT true;

-- +goose Down
ALTER TABLE personas DROP COLUMN state_media_enabled;

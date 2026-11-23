-- +goose Up
-- Whether a persona's generated state loops are displayed. Turning it off
-- keeps the stored loops and blobs intact so re-enabling brings them back.
-- Originally numbered 00182, colliding with 00182_idle_notify_triggers; a
-- database migrated from that branch already has the column, hence IF NOT EXISTS.
ALTER TABLE personas ADD COLUMN IF NOT EXISTS state_media_enabled boolean NOT NULL DEFAULT true;

-- +goose Down
ALTER TABLE personas DROP COLUMN IF EXISTS state_media_enabled;

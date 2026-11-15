-- +goose Up
-- A second opinion is a read-only aside run on a chosen harness/model with the
-- conversation and branch diff snapshot while keeping the parent chat's active
-- harness session and prompt cache untouched.
ALTER TABLE chat_sessions ADD COLUMN second_opinion boolean NOT NULL DEFAULT false;

-- +goose Down
ALTER TABLE chat_sessions DROP COLUMN IF EXISTS second_opinion;

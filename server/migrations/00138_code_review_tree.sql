-- +goose Up
ALTER TABLE chat_code_reviews
    ADD COLUMN tree jsonb NOT NULL DEFAULT '[]',
    ADD COLUMN tree_truncated boolean NOT NULL DEFAULT false;

-- +goose Down
ALTER TABLE chat_code_reviews
    DROP COLUMN tree_truncated,
    DROP COLUMN tree;

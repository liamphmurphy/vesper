-- +goose Up
-- Persisted bookmark flag for pinning key messages inside a chat thread, and
-- allow direct raster image previews in link_previews for gallery/product cards.
ALTER TABLE chat_messages ADD COLUMN bookmarked boolean NOT NULL DEFAULT false;
ALTER TABLE chat_messages ADD COLUMN bookmarked_at timestamptz;

ALTER TABLE link_previews DROP CONSTRAINT IF EXISTS link_previews_kind_check;
ALTER TABLE link_previews ADD CONSTRAINT link_previews_kind_check CHECK (kind IN ('site', 'video', 'image'));

-- +goose Down
ALTER TABLE link_previews DROP CONSTRAINT IF EXISTS link_previews_kind_check;
ALTER TABLE link_previews ADD CONSTRAINT link_previews_kind_check CHECK (kind IN ('site', 'video'));

ALTER TABLE chat_messages DROP COLUMN bookmarked_at;
ALTER TABLE chat_messages DROP COLUMN bookmarked;

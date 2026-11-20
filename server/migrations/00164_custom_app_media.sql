-- +goose Up
-- Video files a custom app downloaded into Vesper's blob store (app.media:download),
-- so they play locally instead of streaming from the original site.
CREATE TABLE custom_app_media (
  id           uuid PRIMARY KEY DEFAULT uuid_v7(),
  app_id       uuid NOT NULL REFERENCES custom_apps(id) ON DELETE CASCADE,
  source_url   text NOT NULL,
  state        text NOT NULL CHECK (state IN ('downloading', 'done', 'failed')),
  blob_key     text NOT NULL,
  content_type text NOT NULL DEFAULT '',
  bytes_done   bigint NOT NULL DEFAULT 0,
  bytes_total  bigint,
  error        text NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX custom_app_media_app ON custom_app_media (app_id, created_at DESC);

-- +goose Down
DROP TABLE IF EXISTS custom_app_media;

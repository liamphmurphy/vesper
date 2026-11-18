-- +goose Up
-- The Safari extension bundled in Vesper.app (docs/dev/safari-extension.md).

-- Its credential: one per person, minted by the Mac app at launch (rotating the
-- last) and handed to the extension through a file only they can read. It
-- reaches /api/v1/browser-extension/* and nothing else.
CREATE TABLE browser_extension_tokens (
  user_id uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  token_hash bytea NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Sites the person added to the never-share list, on top of the built-in ones
-- (browserext.BuiltinNeverShare). A host also covers its subdomains.
CREATE TABLE browser_never_share (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  host text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, host)
);

-- A Safari tab shared with one chat. The extension pushes snapshots of it; the
-- chat's persona reads the latest with browser_snapshot. until = 'page' stops
-- the share when the tab leaves start_url, 'stop' only on Stop.
CREATE TABLE browser_shares (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  chat_id uuid NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  tab_id text NOT NULL,
  start_url text NOT NULL,
  until text NOT NULL CHECK (until IN ('page', 'stop')),
  include_screenshot boolean NOT NULL DEFAULT false,
  url text NOT NULL,
  title text NOT NULL DEFAULT '',
  page_text text NOT NULL DEFAULT '',
  snapshot_at timestamptz,
  started_at timestamptz NOT NULL DEFAULT now(),
  stopped_at timestamptz,
  stop_reason text NOT NULL DEFAULT ''
);
CREATE UNIQUE INDEX browser_shares_active_chat_idx ON browser_shares (chat_id) WHERE stopped_at IS NULL;
CREATE UNIQUE INDEX browser_shares_active_tab_idx ON browser_shares (user_id, tab_id) WHERE stopped_at IS NULL;

-- The latest screenshot of a share, apart from browser_shares so the realtime
-- trigger below never serializes a JPEG.
CREATE TABLE browser_share_screenshots (
  share_id uuid PRIMARY KEY REFERENCES browser_shares(id) ON DELETE CASCADE,
  jpeg bytea NOT NULL
);

-- Each time a persona read a share, for the popover's log and the chat.
CREATE TABLE browser_share_reads (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  share_id uuid NOT NULL REFERENCES browser_shares(id) ON DELETE CASCADE,
  chat_id uuid NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  persona_id uuid REFERENCES personas(id) ON DELETE SET NULL,
  url text NOT NULL,
  read_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX browser_share_reads_share_idx ON browser_share_reads (share_id, read_at DESC);

CREATE TRIGGER realtime_change_ins AFTER INSERT ON browser_shares REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION notify_chat_change('browser_share.updated', 'chat_id');
CREATE TRIGGER realtime_change_upd AFTER UPDATE ON browser_shares REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION notify_chat_change('browser_share.updated', 'chat_id');
CREATE TRIGGER realtime_change_ins AFTER INSERT ON browser_share_reads REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION notify_chat_change('browser_share.updated', 'chat_id');

-- +goose Down
DROP TABLE browser_share_reads;
DROP TABLE browser_share_screenshots;
DROP TABLE browser_shares;
DROP TABLE browser_never_share;
DROP TABLE browser_extension_tokens;

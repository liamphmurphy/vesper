-- +goose Up
-- User-built custom apps: versioned TSX/CSS/SQL bundles, per-app capability
-- permissions, and an embedded SQLite database persisted per app.

CREATE TABLE custom_apps (
  id           uuid PRIMARY KEY DEFAULT uuid_v7(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slug         text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,47}$' AND slug NOT IN ('docs', 'slides', 'designs', 'new')),
  name         text NOT NULL,
  description  text NOT NULL DEFAULT '',
  icon         text NOT NULL DEFAULT 'dashboard',
  space_id     uuid REFERENCES chat_spaces(id) ON DELETE SET NULL,
  current_seq  integer NOT NULL DEFAULT 1,
  manifest     jsonb NOT NULL DEFAULT '{}'::jsonb,
  capabilities jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, user_id, slug)
);
CREATE INDEX custom_apps_owner ON custom_apps (workspace_id, user_id, updated_at DESC);

CREATE TABLE custom_app_versions (
  id          uuid PRIMARY KEY DEFAULT uuid_v7(),
  app_id      uuid NOT NULL REFERENCES custom_apps(id) ON DELETE CASCADE,
  seq         integer NOT NULL CHECK (seq >= 1),
  note        text NOT NULL DEFAULT '',
  author_type text NOT NULL CHECK (author_type IN ('user', 'persona')),
  agent_id    uuid REFERENCES agents(id) ON DELETE SET NULL,
  manifest    jsonb NOT NULL,
  files       jsonb NOT NULL,
  bundle_js   text NOT NULL,
  bundle_css  text NOT NULL DEFAULT '',
  created_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (app_id, seq)
);

CREATE TABLE custom_app_databases (
  app_id       uuid PRIMARY KEY REFERENCES custom_apps(id) ON DELETE CASCADE,
  sqlite_bytes bytea NOT NULL DEFAULT ''::bytea,
  size_bytes   integer NOT NULL DEFAULT 0,
  updated_at   timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE chat_spaces DROP CONSTRAINT chat_spaces_app_check;
ALTER TABLE chat_spaces ADD CONSTRAINT chat_spaces_app_check
  CHECK (app IN ('docs', 'slides', 'designs') OR app ~ '^custom:[a-z0-9][a-z0-9-]{0,47}$');

ALTER TABLE dock_chats DROP CONSTRAINT dock_chats_scope_check;
ALTER TABLE dock_chats ADD CONSTRAINT dock_chats_scope_check
  CHECK (scope ~ '^(page|app):[A-Za-z0-9_:-]+$');

CREATE TRIGGER realtime_change_ins AFTER INSERT ON custom_apps REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION notify_entity_change('custom_app.updated', 'id');
CREATE TRIGGER realtime_change_upd AFTER UPDATE ON custom_apps REFERENCING NEW TABLE AS new_rows FOR EACH STATEMENT EXECUTE FUNCTION notify_entity_change('custom_app.updated', 'id');
CREATE TRIGGER realtime_change_del AFTER DELETE ON custom_apps REFERENCING OLD TABLE AS old_rows FOR EACH STATEMENT EXECUTE FUNCTION notify_entity_change('custom_app.updated', 'id');

-- +goose Down
DROP TRIGGER IF EXISTS realtime_change_del ON custom_apps;
DROP TRIGGER IF EXISTS realtime_change_upd ON custom_apps;
DROP TRIGGER IF EXISTS realtime_change_ins ON custom_apps;

DROP TABLE IF EXISTS custom_app_databases;
DROP TABLE IF EXISTS custom_app_versions;
DROP TABLE IF EXISTS custom_apps;

DELETE FROM dock_chats WHERE scope LIKE 'app:custom:%';
DELETE FROM chat_sessions WHERE space_id IN (SELECT id FROM chat_spaces WHERE app LIKE 'custom:%');
DELETE FROM chat_spaces WHERE app LIKE 'custom:%';

ALTER TABLE dock_chats DROP CONSTRAINT dock_chats_scope_check;
ALTER TABLE dock_chats ADD CONSTRAINT dock_chats_scope_check
  CHECK (scope ~ '^(page|app):[A-Za-z0-9_-]+$');

ALTER TABLE chat_spaces DROP CONSTRAINT chat_spaces_app_check;
ALTER TABLE chat_spaces ADD CONSTRAINT chat_spaces_app_check CHECK (app IN ('docs', 'slides', 'designs'));

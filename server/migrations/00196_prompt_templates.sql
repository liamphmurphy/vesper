-- +goose Up
-- Reusable personal, per-persona, and per-space prompt templates triggered via
-- custom `/` or `#` commands in the chat composer.

CREATE TABLE prompt_templates (
  id           uuid PRIMARY KEY DEFAULT uuid_v7(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  slug         text NOT NULL CHECK (slug ~ '^[a-z][a-z0-9-]{0,47}$'),
  title        text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 120),
  description  text NOT NULL DEFAULT '' CHECK (length(description) <= 300),
  body         text NOT NULL CHECK (length(btrim(body)) BETWEEN 1 AND 16000),
  persona_id   uuid REFERENCES personas(id) ON DELETE CASCADE,
  space_id     uuid REFERENCES chat_spaces(id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX prompt_templates_owner_idx
  ON prompt_templates (workspace_id, user_id, slug);

CREATE UNIQUE INDEX prompt_templates_scope_slug_uidx
  ON prompt_templates (
    workspace_id,
    user_id,
    COALESCE(persona_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(space_id, '00000000-0000-0000-0000-000000000000'::uuid),
    slug
  );

-- +goose Down
DROP TABLE prompt_templates;

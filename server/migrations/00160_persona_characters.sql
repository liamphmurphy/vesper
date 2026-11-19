-- +goose Up
-- Optional animated SVG characters for personas (and chat proposals to design/update them).

ALTER TABLE personas ADD COLUMN character_svg text;
ALTER TABLE personas ADD CONSTRAINT personas_character_svg_len CHECK (character_svg IS NULL OR octet_length(character_svg) <= 32768);

ALTER TABLE persona_proposals ADD COLUMN character_svg text
  CHECK (character_svg IS NULL OR octet_length(character_svg) <= 32768);

CREATE TABLE persona_character_proposals (
  id                uuid PRIMARY KEY DEFAULT uuid_v7(),
  chat_id           uuid NOT NULL REFERENCES chat_sessions(id) ON DELETE CASCADE,
  run_id            uuid REFERENCES runs(id) ON DELETE SET NULL,
  proposed_by       uuid REFERENCES personas(id) ON DELETE SET NULL,
  target_persona_id uuid NOT NULL REFERENCES personas(id) ON DELETE CASCADE,
  character_svg     text NOT NULL CHECK (octet_length(character_svg) BETWEEN 1 AND 32768),
  summary           text NOT NULL DEFAULT '' CHECK (length(summary) <= 500),
  state             text NOT NULL DEFAULT 'pending' CHECK (state IN ('pending', 'approved', 'declined', 'superseded')),
  created_at        timestamptz NOT NULL DEFAULT now(),
  decided_at        timestamptz
);

CREATE INDEX persona_character_proposals_chat ON persona_character_proposals (chat_id, created_at);
CREATE INDEX persona_character_proposals_pending_idx ON persona_character_proposals (chat_id) WHERE state = 'pending';

-- +goose Down
DROP INDEX IF EXISTS persona_character_proposals_pending_idx;
DROP INDEX IF EXISTS persona_character_proposals_chat;
DROP TABLE persona_character_proposals;
ALTER TABLE persona_proposals DROP COLUMN character_svg;
ALTER TABLE personas DROP CONSTRAINT personas_character_svg_len;
ALTER TABLE personas DROP COLUMN character_svg;

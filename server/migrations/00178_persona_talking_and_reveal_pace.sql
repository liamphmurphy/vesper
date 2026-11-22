-- +goose Up
-- A talking loop, played while a reply is revealed, and each persona's reveal
-- pace for that. 'auto' lets the clients decide: a paced reveal when the
-- persona has a talking loop, instant text otherwise.
ALTER TABLE persona_state_media DROP CONSTRAINT persona_state_media_state_check;
ALTER TABLE persona_state_media ADD CONSTRAINT persona_state_media_state_check
  CHECK (state IN ('idle', 'thinking', 'reading', 'coding', 'creating', 'needs_you', 'talking'));

ALTER TABLE personas ADD COLUMN reveal_pace text NOT NULL DEFAULT 'auto'
  CHECK (reveal_pace IN ('auto', 'off', 'relaxed', 'natural', 'deliberate'));

-- +goose Down
ALTER TABLE personas DROP COLUMN reveal_pace;
DELETE FROM persona_state_media WHERE state = 'talking';
ALTER TABLE persona_state_media DROP CONSTRAINT persona_state_media_state_check;
ALTER TABLE persona_state_media ADD CONSTRAINT persona_state_media_state_check
  CHECK (state IN ('idle', 'thinking', 'reading', 'coding', 'creating', 'needs_you'));

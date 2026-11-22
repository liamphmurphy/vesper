-- +goose Up
-- A complete loop: the persona's brief, pleased beat when a turn that did
-- work finishes, before it settles back to idle.
ALTER TABLE persona_state_media DROP CONSTRAINT persona_state_media_state_check;
ALTER TABLE persona_state_media ADD CONSTRAINT persona_state_media_state_check
  CHECK (state IN ('idle', 'thinking', 'reading', 'coding', 'creating', 'needs_you', 'talking', 'complete'));

-- +goose Down
DELETE FROM persona_state_media WHERE state = 'complete';
ALTER TABLE persona_state_media DROP CONSTRAINT persona_state_media_state_check;
ALTER TABLE persona_state_media ADD CONSTRAINT persona_state_media_state_check
  CHECK (state IN ('idle', 'thinking', 'reading', 'coding', 'creating', 'needs_you', 'talking'));

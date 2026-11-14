-- +goose Up
-- A persona's design_patch calls during one chat turn collect in a draft the
-- person never sees; when the turn ends the draft becomes one suggestion of its
-- net changes (or a version, for direct edit and a persona's first draft).
ALTER TABLE design_proposals ADD COLUMN turn_id uuid;
ALTER TABLE design_proposals DROP CONSTRAINT design_proposals_status_check;
ALTER TABLE design_proposals ADD CONSTRAINT design_proposals_status_check
  CHECK (status IN ('draft', 'pending', 'resolved', 'applied', 'withdrawn'));
CREATE UNIQUE INDEX design_proposals_turn_draft ON design_proposals (canvas_id, turn_id) WHERE status = 'draft';

-- +goose Down
DELETE FROM design_proposals WHERE status = 'draft';
DROP INDEX design_proposals_turn_draft;
ALTER TABLE design_proposals DROP CONSTRAINT design_proposals_status_check;
ALTER TABLE design_proposals ADD CONSTRAINT design_proposals_status_check
  CHECK (status IN ('pending', 'resolved', 'applied', 'withdrawn'));
ALTER TABLE design_proposals DROP COLUMN turn_id;

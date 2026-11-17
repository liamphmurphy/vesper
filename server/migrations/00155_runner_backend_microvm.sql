-- +goose Up
-- Allow the microvm runner backend alongside docker and fake.
ALTER TABLE runners
  DROP CONSTRAINT runners_backend_check,
  ADD CONSTRAINT runners_backend_check CHECK (backend IN ('docker', 'microvm', 'fake'));

-- +goose Down
DELETE FROM runners WHERE backend = 'microvm';
ALTER TABLE runners
  DROP CONSTRAINT runners_backend_check,
  ADD CONSTRAINT runners_backend_check CHECK (backend IN ('docker', 'fake'));

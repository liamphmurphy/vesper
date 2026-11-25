-- +goose Up
-- The PNG a person saw when they reviewed a mockup version, so runs build from
-- exactly the approved picture (docs/dev/mockup-svg-profile.md). The blob lives
-- in the artifacts bucket; renderer and source hash say what drew it from what.
ALTER TABLE artifact_versions
    ADD COLUMN review_snapshot_key text,
    ADD COLUMN review_snapshot_renderer text,
    ADD COLUMN review_snapshot_sha256 text;

-- +goose Down
ALTER TABLE artifact_versions
    DROP COLUMN review_snapshot_sha256,
    DROP COLUMN review_snapshot_renderer,
    DROP COLUMN review_snapshot_key;

-- +goose Up
-- Custom apps now keep only their newest 10 versions (customapps.MaxStoredVersions);
-- each version stores full sources and bundles. Trim apps saved before that rule.
DELETE FROM custom_app_versions v
USING custom_apps a
WHERE v.app_id = a.id AND v.seq <= a.current_seq - 10;

-- +goose Down
-- Pruned versions can't be restored; nothing to undo.
SELECT 1;

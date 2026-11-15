-- +goose Up
ALTER TABLE custom_app_versions
    ADD COLUMN bundle_mcp_js text NOT NULL DEFAULT '',
    ADD COLUMN mcp_tools jsonb NOT NULL DEFAULT '[]'::jsonb;

-- +goose Down
ALTER TABLE custom_app_versions
    DROP COLUMN IF EXISTS mcp_tools,
    DROP COLUMN IF EXISTS bundle_mcp_js;

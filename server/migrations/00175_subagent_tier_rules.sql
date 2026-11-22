-- +goose Up
-- Workspace-level toggle and optional per-harness model ladders for in-turn
-- MCP subagent tier routing. When subagent_tier_routing is false, personas
-- skip tier routing and behave as before (helper inherits parent model and
-- effort; explorer uses its explorer_model or harness default).
ALTER TABLE workspaces
  ADD COLUMN subagent_tier_routing boolean NOT NULL DEFAULT true,
  ADD COLUMN subagent_tier_models jsonb NOT NULL DEFAULT '{}'::jsonb;

-- +goose Down
ALTER TABLE workspaces
  DROP COLUMN subagent_tier_models,
  DROP COLUMN subagent_tier_routing;

-- +goose Up
ALTER TABLE scheduled_tasks DROP CONSTRAINT scheduled_tasks_kind_check;
ALTER TABLE scheduled_tasks ADD CONSTRAINT scheduled_tasks_kind_check CHECK (kind IN ('prompt', 'workflow', 'custom_app'));
ALTER TABLE scheduled_tasks
  ADD COLUMN custom_app_id uuid REFERENCES custom_apps(id) ON DELETE CASCADE,
  ADD COLUMN custom_app_tool text NOT NULL DEFAULT '',
  ADD COLUMN custom_app_args jsonb NOT NULL DEFAULT '{}'::jsonb;
CREATE INDEX scheduled_tasks_custom_app ON scheduled_tasks (custom_app_id) WHERE custom_app_id IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS scheduled_tasks_custom_app;
ALTER TABLE scheduled_tasks
  DROP COLUMN IF EXISTS custom_app_args,
  DROP COLUMN IF EXISTS custom_app_tool,
  DROP COLUMN IF EXISTS custom_app_id;
ALTER TABLE scheduled_tasks DROP CONSTRAINT scheduled_tasks_kind_check;
ALTER TABLE scheduled_tasks ADD CONSTRAINT scheduled_tasks_kind_check CHECK (kind IN ('prompt', 'workflow'));

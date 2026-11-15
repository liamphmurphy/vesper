-- +goose Up
-- Scope run.events notifications to the affected run_id instead of waking
-- every view on every streamed line, and index chat run lookups so
-- OwnsChatRun / ChatSessionOfRun / ListRuns resolve run_id in O(1).
DROP TRIGGER IF EXISTS realtime_change ON run_events;
CREATE TRIGGER realtime_change_ins AFTER INSERT ON run_events
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION notify_entity_change('run.events', 'run_id');
CREATE TRIGGER realtime_change_upd AFTER UPDATE ON run_events
  REFERENCING NEW TABLE AS new_rows
  FOR EACH STATEMENT EXECUTE FUNCTION notify_entity_change('run.events', 'run_id');
CREATE TRIGGER realtime_change_del AFTER DELETE ON run_events
  REFERENCING OLD TABLE AS old_rows
  FOR EACH STATEMENT EXECUTE FUNCTION notify_entity_change('run.events', 'run_id');

CREATE INDEX chat_sessions_current_run_idx
  ON chat_sessions (current_run_id)
  WHERE current_run_id IS NOT NULL;
CREATE INDEX chat_messages_run_idx
  ON chat_messages (run_id, session_id)
  WHERE run_id IS NOT NULL;

-- +goose Down
DROP INDEX IF EXISTS chat_messages_run_idx;
DROP INDEX IF EXISTS chat_sessions_current_run_idx;
DROP TRIGGER IF EXISTS realtime_change_del ON run_events;
DROP TRIGGER IF EXISTS realtime_change_upd ON run_events;
DROP TRIGGER IF EXISTS realtime_change_ins ON run_events;
CREATE TRIGGER realtime_change AFTER INSERT OR DELETE OR UPDATE ON run_events
  FOR EACH STATEMENT EXECUTE FUNCTION notify_change('run.events');

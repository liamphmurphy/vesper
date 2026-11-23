-- +goose Up
-- Replace the statement-level work_notify triggers from 00182 with row-level
-- triggers guarded by WHEN clauses. In PostgreSQL, FOR EACH STATEMENT triggers
-- fire even when an UPDATE matches 0 rows, so idle Claim* queries emitted
-- vesper_work NOTIFYs on every tick and spun the runner and vault worker in a
-- tight loop. Row-level triggers execute 0 times for 0-row statements, only
-- fire when work is actually queued (not when claimed/finished), and
-- pg_notify deduplicates identical (channel, payload) notifications within a
-- transaction.

-- A database migrated by the branch whose 00182 was persona_state_media_enabled
-- (since renumbered to 00184) recorded version 182 without running
-- 00182_idle_notify_triggers, so define notify_work here too. Same body as 00182.
-- +goose StatementBegin
CREATE OR REPLACE FUNCTION public.notify_work() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_notify('vesper_work', TG_ARGV[0]);
  RETURN NULL;
END;
$$;
-- +goose StatementEnd

DROP TRIGGER IF EXISTS work_notify ON public.sign_ins;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.sign_ins
  FOR EACH ROW WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION public.notify_work('sign_in');

DROP TRIGGER IF EXISTS work_notify ON public.harness_model_listings;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.harness_model_listings
  FOR EACH ROW WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION public.notify_work('model_listing');

DROP TRIGGER IF EXISTS work_notify ON public.harness_usage_checks;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.harness_usage_checks
  FOR EACH ROW WHEN (NEW.status = 'pending')
  EXECUTE FUNCTION public.notify_work('usage_check');

DROP TRIGGER IF EXISTS work_notify ON public.dev_workspaces;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.dev_workspaces
  FOR EACH ROW WHEN (NEW.action IS NOT NULL)
  EXECUTE FUNCTION public.notify_work('dev_workspace');

DROP TRIGGER IF EXISTS work_notify ON public.knowledge_imports;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.knowledge_imports
  FOR EACH ROW WHEN (NEW.state IN ('queued', 'queued_commit'))
  EXECUTE FUNCTION public.notify_work('knowledge_import');

DROP TRIGGER IF EXISTS work_notify ON public.scheduled_tasks;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.scheduled_tasks
  FOR EACH ROW WHEN (NEW.enabled)
  EXECUTE FUNCTION public.notify_work('scheduled_task');

DROP TRIGGER IF EXISTS work_notify ON public.runners;
CREATE TRIGGER work_notify AFTER UPDATE OF slot_limit ON public.runners
  FOR EACH ROW WHEN (OLD.slot_limit IS DISTINCT FROM NEW.slot_limit)
  EXECUTE FUNCTION public.notify_work('slot_limit');

-- +goose Down
DROP TRIGGER IF EXISTS work_notify ON public.runners;
CREATE TRIGGER work_notify AFTER UPDATE OF slot_limit ON public.runners
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('slot_limit');

DROP TRIGGER IF EXISTS work_notify ON public.scheduled_tasks;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.scheduled_tasks
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('scheduled_task');

DROP TRIGGER IF EXISTS work_notify ON public.knowledge_imports;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.knowledge_imports
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('knowledge_import');

DROP TRIGGER IF EXISTS work_notify ON public.dev_workspaces;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.dev_workspaces
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('dev_workspace');

DROP TRIGGER IF EXISTS work_notify ON public.harness_usage_checks;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.harness_usage_checks
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('usage_check');

DROP TRIGGER IF EXISTS work_notify ON public.harness_model_listings;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.harness_model_listings
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('model_listing');

DROP TRIGGER IF EXISTS work_notify ON public.sign_ins;
CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.sign_ins
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('sign_in');

-- +goose Up
-- Emit internal worker wakeups on a dedicated channel (`vesper_work`) so the
-- runner and vault worker can back off to slow idle polling without flooding
-- browser/desktop SSE subscribers on `lazyagents_changes`.
-- +goose StatementBegin
CREATE FUNCTION public.notify_work() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM pg_notify('vesper_work', TG_ARGV[0]);
  RETURN NULL;
END;
$$;
-- +goose StatementEnd

CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.sign_ins
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('sign_in');

CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.harness_model_listings
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('model_listing');

CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.harness_usage_checks
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('usage_check');

CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.dev_workspaces
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('dev_workspace');

CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.knowledge_imports
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('knowledge_import');

CREATE TRIGGER work_notify AFTER INSERT OR UPDATE ON public.scheduled_tasks
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('scheduled_task');

CREATE TRIGGER work_notify AFTER UPDATE OF slot_limit ON public.runners
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_work('slot_limit');

-- +goose Down
DROP TRIGGER IF EXISTS work_notify ON public.runners;
DROP TRIGGER IF EXISTS work_notify ON public.scheduled_tasks;
DROP TRIGGER IF EXISTS work_notify ON public.knowledge_imports;
DROP TRIGGER IF EXISTS work_notify ON public.dev_workspaces;
DROP TRIGGER IF EXISTS work_notify ON public.harness_usage_checks;
DROP TRIGGER IF EXISTS work_notify ON public.harness_model_listings;
DROP TRIGGER IF EXISTS work_notify ON public.sign_ins;
DROP FUNCTION IF EXISTS public.notify_work();

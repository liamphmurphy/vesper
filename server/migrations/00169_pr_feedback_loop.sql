-- +goose Up
-- Cached GitHub check runs and unresolved review threads for Vesper-tracked
-- pull requests, polled conditionally via ETags by prsync.
CREATE TABLE pr_feedback (
  workspace_id        uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  pr_url              text NOT NULL,
  head_sha            text NOT NULL DEFAULT '',
  pr_etag             text NOT NULL DEFAULT '',
  checks_etag         text NOT NULL DEFAULT '',
  reviews_etag        text NOT NULL DEFAULT '',
  ci_state            text NOT NULL DEFAULT 'unknown'
    CHECK (ci_state IN ('unknown', 'pending', 'passing', 'failing')),
  failed_checks_count integer NOT NULL DEFAULT 0,
  failed_checks       jsonb NOT NULL DEFAULT '[]',
  unresolved_threads  integer NOT NULL DEFAULT 0,
  review_threads      jsonb NOT NULL DEFAULT '[]',
  ci_failed_at        timestamptz,
  review_updated_at   timestamptz,
  updated_at          timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workspace_id, pr_url)
);

CREATE INDEX pr_feedback_attention_idx
  ON pr_feedback (workspace_id)
  WHERE ci_state = 'failing' OR unresolved_threads > 0;

CREATE TRIGGER realtime_change
  AFTER INSERT OR DELETE OR UPDATE ON public.pr_feedback
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_change('pr_feedback.updated');

-- +goose Down
DROP TRIGGER IF EXISTS realtime_change ON public.pr_feedback;
DROP INDEX IF EXISTS pr_feedback_attention_idx;
DROP TABLE IF EXISTS pr_feedback;

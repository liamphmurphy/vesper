-- name: GetPRFeedback :one
SELECT * FROM pr_feedback WHERE workspace_id = $1 AND pr_url = $2;

-- name: ListPRFeedbackByURLs :many
SELECT * FROM pr_feedback
WHERE workspace_id = $1 AND pr_url = ANY(sqlc.arg(pr_urls)::text[]);

-- name: UpsertPRFeedback :one
INSERT INTO pr_feedback (
  workspace_id, pr_url, head_sha, pr_etag, checks_etag, reviews_etag,
  ci_state, failed_checks_count, failed_checks, unresolved_threads, review_threads,
  ci_failed_at, review_updated_at, updated_at
) VALUES (
  $1, $2, $3, $4, $5, $6,
  $7, $8, $9, $10, $11,
  $12, $13, now()
)
ON CONFLICT (workspace_id, pr_url) DO UPDATE SET
  head_sha            = EXCLUDED.head_sha,
  pr_etag             = EXCLUDED.pr_etag,
  checks_etag         = EXCLUDED.checks_etag,
  reviews_etag        = EXCLUDED.reviews_etag,
  ci_state            = EXCLUDED.ci_state,
  failed_checks_count = EXCLUDED.failed_checks_count,
  failed_checks       = EXCLUDED.failed_checks,
  unresolved_threads  = EXCLUDED.unresolved_threads,
  review_threads      = EXCLUDED.review_threads,
  ci_failed_at        = EXCLUDED.ci_failed_at,
  review_updated_at   = EXCLUDED.review_updated_at,
  updated_at          = now()
RETURNING *;

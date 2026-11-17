-- name: ExpireSignIns :exec
-- Ends sign-ins that ran out of time or whose runner stopped heartbeating.
UPDATE sign_ins SET status = 'failed', pasted_code = NULL, updated_at = now(),
  error = CASE WHEN expires_at <= now() THEN 'The sign-in timed out. Start it again.'
               ELSE 'The runner stopped during sign-in. Start it again.' END
WHERE status IN ('pending', 'running', 'verifying')
  AND (expires_at <= now()
       OR (runner_id IS NOT NULL AND runner_id NOT IN (
             SELECT id FROM runners WHERE heartbeat_at > now() - interval '45 seconds')));

-- name: CancelActiveSignIns :exec
UPDATE sign_ins SET status = 'cancelled', pasted_code = NULL, updated_at = now()
WHERE workspace_id = $1 AND provider = $2 AND status IN ('pending', 'running', 'verifying');

-- name: CreateSignIn :one
INSERT INTO sign_ins (workspace_id, provider, requested_by, expires_at)
VALUES ($1, $2, $3, $4) RETURNING *;

-- name: GetSignIn :one
SELECT * FROM sign_ins WHERE id = $1 AND workspace_id = $2;

-- name: SubmitSignInCode :one
-- Only while the CLI is waiting for it: after it printed its link.
UPDATE sign_ins SET pasted_code = $3, updated_at = now()
WHERE id = $1 AND workspace_id = $2 AND provider IN ('claude', 'antigravity') AND status = 'running' AND url <> ''
RETURNING *;

-- name: CancelSignIn :execrows
UPDATE sign_ins SET status = 'cancelled', pasted_code = NULL, updated_at = now()
WHERE id = $1 AND workspace_id = $2 AND status IN ('pending', 'running', 'verifying');

-- name: LiveIsolatingRunnerExists :one
SELECT EXISTS (SELECT 1 FROM runners WHERE backend IN ('docker', 'microvm') AND heartbeat_at > now() - interval '45 seconds');

-- name: ClaimSignIn :one
UPDATE sign_ins SET status = 'running', runner_id = $1, updated_at = now()
WHERE id = (SELECT s.id FROM sign_ins s WHERE s.status = 'pending' AND s.expires_at > now()
            ORDER BY s.created_at LIMIT 1 FOR UPDATE SKIP LOCKED)
RETURNING *;

-- name: SetSignInPrompt :exec
UPDATE sign_ins SET url = $2, user_code = $3, updated_at = now()
WHERE id = $1 AND status = 'running';

-- name: TakeSignInCode :one
-- Hands the pasted code to the runner once and forgets it.
UPDATE sign_ins s SET pasted_code = NULL, status = 'verifying', updated_at = now()
FROM (SELECT o.id AS old_id, o.pasted_code FROM sign_ins o
      WHERE o.id = $1 AND o.status = 'running' AND o.pasted_code IS NOT NULL FOR UPDATE) old
WHERE s.id = old.old_id
RETURNING old.pasted_code::text AS code;

-- name: SignInStatus :one
SELECT status FROM sign_ins WHERE id = $1;

-- name: FinishSignIn :exec
UPDATE sign_ins SET status = $2, error = $3, pasted_code = NULL, updated_at = now()
WHERE id = $1 AND status IN ('pending', 'running', 'verifying');

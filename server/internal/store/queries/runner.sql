-- The runner (docs/dev/plan.md §6.4–6.6): queue, turns, heartbeats, PR sync.

-- name: ClaimQueuedRun :one
-- The oldest queued run whose agent has a free slot (max_concurrency from
-- the frozen definition; waiting runs don't hold a slot). A ticket run whose
-- blocker tickets aren't Done stays queued.
UPDATE runs SET state = 'starting', runner_id = sqlc.arg(runner_id),
  execution_token = sqlc.narg(execution_token), execution_expires_at = sqlc.narg(execution_expires_at)
WHERE id = (
  SELECT r.id FROM runs r
  WHERE r.state = 'queued'
    AND NOT EXISTS (SELECT 1 FROM run_turns b WHERE b.run_id = r.parent_run_id AND (b.status = 'running' OR b.execution_expires_at > now()))
    AND (r.parent_run_id IS NOT NULL OR NOT EXISTS (
      SELECT 1 FROM ticket_dependencies d JOIN tickets bt ON bt.id = d.blocker_id
      WHERE d.ticket_id = r.ticket_id AND bt.status <> 'done'))
    AND (r.purpose = 'chat' OR (SELECT count(*) FROM runs o WHERE o.agent_id = r.agent_id AND o.purpose <> 'chat' AND o.state IN ('starting', 'running'))
        < greatest(coalesce((r.resolved_spec->>'max_concurrency')::int, 1), 1))
  -- Research waits behind every other kind of run.
  ORDER BY r.purpose IN ('research', 'workflow', 'learning'), r.started_at
  FOR UPDATE SKIP LOCKED
  LIMIT 1
)
RETURNING *;

-- name: ClaimPendingTurn :one
-- The next turn to execute: a pending turn of a running managed run whose
-- previous turn has exited (a reply can arrive while the agent is still
-- ending its turn; one process per workspace at a time).
UPDATE run_turns SET status = 'running', process_started_at = now(),
  execution_token = sqlc.narg(execution_token), execution_expires_at = sqlc.narg(execution_expires_at)
WHERE status = 'pending' AND id = (
  SELECT t.id FROM run_turns t JOIN runs r ON r.id = t.run_id
  WHERE t.status = 'pending' AND r.mode = 'managed' AND r.state = 'running'
    AND (r.execution_expires_at IS NULL OR r.execution_expires_at <= now())
    AND NOT EXISTS (SELECT 1 FROM run_turns b WHERE b.run_id = t.run_id AND (b.status = 'running' OR b.execution_expires_at > now()))
    -- A delegated run shares its parent's checkout: wait for the parent's process to exit.
    AND NOT EXISTS (SELECT 1 FROM run_turns b WHERE b.run_id = r.parent_run_id AND (b.status = 'running' OR b.execution_expires_at > now()))
    AND NOT EXISTS (
      SELECT 1 FROM run_turns b JOIN runs c ON c.id = b.run_id
      WHERE c.parent_run_id = r.id AND (b.status = 'running' OR b.execution_expires_at > now()))
  ORDER BY t.seq
  FOR UPDATE OF t SKIP LOCKED
  LIMIT 1
)
RETURNING *;

-- name: FinishTurn :exec
UPDATE run_turns SET status = 'done', ended_at = coalesce(ended_at, now()), exit_code = coalesce(exit_code, sqlc.narg(exit_code)),
  log_key = sqlc.narg(log_key), usage = sqlc.arg(usage)
WHERE id = $1;

-- name: DropPendingTurns :exec
-- A run that ended can't execute queued turns.
UPDATE run_turns SET status = 'done', ended_at = coalesce(ended_at, now()) WHERE run_id = $1 AND status = 'pending';

-- name: GetTurn :one
SELECT * FROM run_turns WHERE id = $1;

-- name: SetRunSession :exec
UPDATE runs SET harness_session_id = $2 WHERE id = $1;

-- name: SetRunRolloverRequested :exec
UPDATE runs SET rollover_requested = $2 WHERE id = $1;

-- name: SetRunContextTokens :exec
UPDATE runs SET context_tokens = $2 WHERE id = $1;

-- name: SetRunReport :exec
UPDATE runs SET report = $2 WHERE id = $1;

-- name: SetRunWorkspace :exec
UPDATE runs SET workspace_volume = $2 WHERE id = $1;

-- name: SetRunWorkspaceHostPath :exec
UPDATE runs SET workspace_host_path = $2 WHERE id = $1;

-- name: HostFolderWorkspaces :one
SELECT host_folder_workspaces FROM workspaces WHERE id = $1;

-- name: SetHostFolderWorkspaces :exec
UPDATE workspaces SET host_folder_workspaces = $2, updated_at = now() WHERE id = $1;

-- name: RunWorkspaceHostPaths :many
-- Host folders of runs that still have their workspace.
SELECT id, workspace_host_path::text AS path FROM runs
WHERE id = ANY(sqlc.arg(ids)::uuid[]) AND workspace_host_path IS NOT NULL AND workspace_volume IS NOT NULL;

-- name: SetIdleTurns :exec
UPDATE runs SET idle_turns = $2 WHERE id = $1;

-- name: SetRunCost :exec
-- Harness-reported cost replaces computed or self-reported cost.
UPDATE runs SET cost_source = $2 WHERE id = $1;

-- name: RunActiveSeconds :one
-- Time the harness actually ran, across turns (waits don't count).
SELECT count(*)::int AS turns,
  coalesce(sum(extract(epoch FROM (coalesce(ended_at, now()) - process_started_at))), 0)::float8 AS seconds
FROM run_turns WHERE run_id = $1 AND process_started_at IS NOT NULL;

-- name: RequeueInterrupted :exec
-- On every poll: expired worker leases run again (the harness resumes).
-- Unleased records from older runners use their owner's heartbeat instead.
UPDATE run_turns SET status = 'pending', process_started_at = NULL, ended_at = NULL, exit_code = NULL,
  execution_token = NULL, execution_expires_at = NULL
WHERE status = 'running' AND (
  (execution_token IS NOT NULL AND execution_expires_at <= now()) OR
  (execution_token IS NULL AND run_id IN (
  SELECT r.id FROM runs r WHERE r.runner_id = sqlc.arg(runner_id) OR r.runner_id IS NULL
    OR r.runner_id NOT IN (SELECT id FROM runners WHERE heartbeat_at > now() - interval '45 seconds'))))
  -- Paused chats are settled with their session lock and interruption below.
  -- Ended runs must also release stale running rows so workspace cleanup works.
  AND run_id IN (SELECT id FROM runs WHERE state <> 'paused');

-- name: StrandedRuns :many
-- Managed runs left running with no turn to execute and no live delegated run:
-- a runner shut down mid-turn and finished the turn instead of leaving it for
-- RequeueInterrupted. Only this runner's and dead runners' runs, since a live
-- runner may be between a turn and its follow-up.
SELECT r.id FROM runs r
WHERE r.mode = 'managed' AND r.state = 'running' AND r.purpose <> 'chat'
  AND (r.runner_id = sqlc.arg(runner_id) OR r.runner_id IS NULL
    OR r.runner_id NOT IN (SELECT id FROM runners WHERE heartbeat_at > now() - interval '45 seconds'))
  AND NOT EXISTS (SELECT 1 FROM run_turns t WHERE t.run_id = r.id AND t.status IN ('pending', 'running'))
  AND (r.execution_expires_at IS NULL OR r.execution_expires_at <= now())
  AND NOT EXISTS (SELECT 1 FROM run_turns t WHERE t.run_id = r.id AND t.execution_expires_at > now())
  AND NOT EXISTS (SELECT 1 FROM runs c WHERE c.parent_run_id = r.id AND c.state NOT IN ('completed', 'failed', 'cancelled'));

-- name: RequeueStarting :exec
UPDATE runs SET state = 'queued', execution_token = NULL, execution_expires_at = NULL
WHERE state = 'starting' AND (
  (execution_token IS NOT NULL AND execution_expires_at <= now()) OR
  (execution_token IS NULL AND (runner_id = sqlc.arg(runner_id) OR runner_id IS NULL
    OR runner_id NOT IN (SELECT id FROM runners WHERE heartbeat_at > now() - interval '45 seconds'))));

-- name: RenewSetupExecution :one
UPDATE runs SET execution_expires_at = sqlc.arg(expires_at)
WHERE id = sqlc.arg(id) AND execution_token = sqlc.arg(token) AND execution_expires_at > now()
RETURNING execution_expires_at;

-- name: RenewTurnExecution :one
UPDATE run_turns SET execution_expires_at = sqlc.arg(expires_at)
WHERE id = sqlc.arg(id) AND execution_token = sqlc.arg(token) AND execution_expires_at > now()
RETURNING execution_expires_at;

-- name: ReleaseSetupExecution :exec
UPDATE runs SET execution_expires_at = now() WHERE id = $1 AND execution_token = $2;

-- name: ReleaseTurnExecution :exec
UPDATE run_turns SET execution_expires_at = now() WHERE id = $1 AND execution_token = $2;

-- name: LockTurn :one
SELECT * FROM run_turns WHERE id = $1 FOR UPDATE;

-- name: OwnsRunExecution :one
SELECT EXISTS (
  SELECT 1 FROM runs r WHERE r.id = sqlc.arg(run_id) AND r.execution_token = sqlc.arg(token) AND r.execution_expires_at > now()
  UNION ALL
  SELECT 1 FROM run_turns t WHERE t.run_id = sqlc.arg(run_id) AND t.execution_token = sqlc.arg(token) AND t.execution_expires_at > now()
)::bool;

-- name: AbandonedChatCancellations :many
SELECT r.id, r.workspace_id FROM runs r JOIN chat_sessions c ON c.current_run_id = r.id
WHERE r.purpose = 'chat' AND r.state = 'paused'
  AND (r.execution_expires_at IS NULL OR r.execution_expires_at <= now())
  AND NOT EXISTS (SELECT 1 FROM run_turns t WHERE t.run_id = r.id AND t.execution_expires_at > now())
  AND (r.execution_token IS NOT NULL
    OR EXISTS (SELECT 1 FROM run_turns t WHERE t.run_id = r.id AND t.execution_token IS NOT NULL)
    OR r.runner_id = sqlc.arg(runner_id) OR r.runner_id IS NULL
    OR r.runner_id NOT IN (SELECT id FROM runners WHERE heartbeat_at > now() - interval '45 seconds'));

-- name: Heartbeat :exec
INSERT INTO runners (id, backend, max_concurrent, running, version, host_workspaces_dir)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (id) DO UPDATE SET backend = EXCLUDED.backend, max_concurrent = EXCLUDED.max_concurrent,
  running = EXCLUDED.running, version = EXCLUDED.version, host_workspaces_dir = EXCLUDED.host_workspaces_dir,
  heartbeat_at = now();

-- name: DeleteRunner :exec
DELETE FROM runners WHERE id = $1;

-- name: LiveRunners :many
SELECT * FROM runners WHERE heartbeat_at > now() - interval '45 seconds' ORDER BY started_at;

-- name: LiveWorkRunsCount :one
-- Runs in flight for the Runs nav count; Personal Assistant chats belong to Chat.
SELECT count(*)::int FROM runs WHERE state IN ('starting', 'running') AND purpose NOT IN ('chat', 'research', 'workflow', 'learning');

-- name: QueuedRunsCount :one
SELECT count(*)::int FROM runs WHERE state = 'queued';

-- name: SecretsForRun :many
-- Workspace secrets plus the project's own; a project secret shadows the
-- workspace one with the same name.
SELECT DISTINCT ON (name) id, name, grants_scope, project_id FROM secrets
WHERE workspace_id = $1 AND (project_id IS NULL OR project_id = sqlc.narg(project_id))
ORDER BY name, project_id NULLS LAST;

-- name: TicketsWithOpenPRs :many
SELECT t.id, t.workspace_id, t.key, t.epic_id, t.pr_url, t.pr_number, t.pr_state, t.status, t.project_id
FROM tickets t
WHERE t.pr_url IS NOT NULL AND coalesce(t.pr_state, 'open') IN ('draft', 'open')
  AND (t.pr_synced_at IS NULL OR t.pr_synced_at < now() - make_interval(secs => sqlc.arg(min_age_s)::int))
ORDER BY t.pr_synced_at NULLS FIRST
LIMIT 50;

-- name: UpdatePRSync :exec
UPDATE tickets SET pr_state = $2, pr_additions = $3, pr_deletions = $4, pr_synced_at = now(),
  pr_closed_unmerged = $5
WHERE id = $1;

-- name: TouchPRSync :exec
UPDATE tickets SET pr_synced_at = now() WHERE id = $1;

-- name: PushRequestsWithOpenPRs :many
SELECT p.id, p.workspace_id, p.chat_id, p.pr_url, p.pr_number, p.pr_state, cs.project_id
FROM push_requests p
JOIN chat_sessions cs ON cs.id = p.chat_id
WHERE p.pr_url IS NOT NULL AND coalesce(p.pr_state, 'open') IN ('draft', 'open')
  AND (p.pr_synced_at IS NULL OR p.pr_synced_at < now() - make_interval(secs => sqlc.arg(min_age_s)::int))
ORDER BY p.pr_synced_at NULLS FIRST
LIMIT 50;

-- name: UpdatePushRequestPRSync :exec
UPDATE push_requests SET pr_state = $2, pr_synced_at = now()
WHERE id = $1;

-- name: TouchPushRequestPRSync :exec
UPDATE push_requests SET pr_synced_at = now() WHERE id = $1;

-- name: SetRunDispatcher :exec
UPDATE runs SET dispatched_by_user_id = $2 WHERE id = $1;

-- name: LockRunNoWait :one
-- Plain read used by the runner (it locks inside its own transactions).
SELECT * FROM runs WHERE id = $1;

-- name: HasPendingTurn :one
SELECT EXISTS (SELECT 1 FROM run_turns WHERE run_id = $1 AND status = 'pending')::bool;

-- name: EndedRunsWithWorkspace :many
-- Workspaces of runs that completed while no turn was running; the runner
-- removes them. Failed and cancelled runs keep theirs (unpushed work), except
-- chat runs: their scratch workspace never holds work worth keeping.
SELECT id FROM runs r
WHERE r.workspace_volume IS NOT NULL
  AND (r.state = 'completed' OR (r.purpose = 'chat' AND r.state IN ('failed', 'cancelled')))
  AND NOT EXISTS (SELECT 1 FROM run_turns t WHERE t.run_id = r.id AND t.status = 'running')
  AND r.id <> ALL(sqlc.arg(skip)::uuid[]) -- workspaces on another backend
ORDER BY r.checkpoint_error IS NOT NULL -- a stuck checkpoint must not starve the rest
LIMIT 20;

-- name: RunnerEnvironments :many
-- Latest observed setup per runner and project, or the exact run requested.
SELECT * FROM (
  SELECT DISTINCT ON (coalesce(nullif(e.payload->>'runner_id', ''), r.runner_id, ''), t.project_id)
    r.id AS run_id, coalesce(nullif(e.payload->>'runner_id', ''), r.runner_id, '')::text AS runner_id,
    e.at AS recorded_at, e.payload,
    t.key AS ticket_key, p.key AS project_key, p.name AS project_name
  FROM run_events e
  JOIN runs r ON r.id = e.run_id
  JOIN tickets t ON t.id = r.ticket_id
  JOIN projects p ON p.id = t.project_id
  WHERE r.workspace_id = sqlc.arg(workspace_id)
    AND e.type = 'lifecycle' AND e.payload->>'state' = 'environment_snapshot'
    AND (sqlc.narg(run_id)::uuid IS NULL OR r.id = sqlc.narg(run_id))
  ORDER BY coalesce(nullif(e.payload->>'runner_id', ''), r.runner_id, ''), t.project_id, e.at DESC, e.seq DESC
) AS snapshots
ORDER BY recorded_at DESC
LIMIT 50;

-- name: IdleChatRuns :many
-- Chat segments waiting on the person with no activity since the cutoff and
-- no turn queued or running; the runner ends them so their workspace is freed.
SELECT r.id, r.workspace_id FROM runs r
WHERE r.purpose = 'chat' AND r.state = 'waiting' AND r.updated_at < sqlc.arg(cutoff)::timestamptz
  AND NOT EXISTS (SELECT 1 FROM run_turns t WHERE t.run_id = r.id AND t.status IN ('pending', 'running'))
ORDER BY r.updated_at
LIMIT 20;

-- name: HoldRun :one
-- Holds a run at a provider limit. The first hold of an episode starts the
-- max-hold clock; later ones keep it.
UPDATE runs SET state = 'waiting_for_quota', wait_reason = NULL, hold_until = sqlc.arg(hold_until),
  hold_reset_known = sqlc.arg(hold_reset_known), hold_attempts = hold_attempts + 1,
  hold_started_at = coalesce(hold_started_at, now())
WHERE id = sqlc.arg(id) RETURNING *;

-- name: DueHeldRuns :many
-- Held runs to resume now, or to fail because they have been held too long.
SELECT id FROM runs
WHERE state = 'waiting_for_quota' AND (hold_until <= now() OR hold_started_at <= sqlc.arg(expired_before)::timestamptz)
ORDER BY hold_until LIMIT 50;

-- name: ClearRunHold :exec
-- A turn got past the limit: the next hold is a new episode.
UPDATE runs SET hold_until = NULL, hold_started_at = NULL, hold_attempts = 0, hold_reset_known = false
WHERE id = $1 AND hold_started_at IS NOT NULL;

-- name: RequestHoldResume :exec
-- A person asked to try now; the runner resumes it on its next tick.
UPDATE runs SET hold_until = now() WHERE id = $1;

-- name: SetRunCheckpoint :exec
UPDATE runs SET checkpoint_branch = sqlc.narg(branch), checkpoint_at = now(), checkpoint_error = NULL WHERE id = sqlc.arg(id);

-- name: SetRunCheckpointError :exec
UPDATE runs SET checkpoint_error = sqlc.arg(error) WHERE id = sqlc.arg(id);

-- name: RunsToCheckpoint :many
-- Earlier ended runs of a ticket whose workspace has not been checkpointed; a new run on the ticket would otherwise start without them.
SELECT id FROM runs
WHERE ticket_id = sqlc.arg(ticket_id) AND id <> sqlc.arg(id) AND parent_run_id IS NULL AND purpose = 'ticket'
  AND state IN ('completed', 'failed', 'cancelled') AND workspace_volume IS NOT NULL AND checkpoint_at IS NULL
ORDER BY started_at;

-- name: LatestTicketCheckpoint :one
-- The checkpoint a new run on the ticket recovers from: only the latest earlier
-- run's, since a later run that left no checkpoint has superseded older ones.
SELECT coalesce(checkpoint_branch, '')::text FROM runs
WHERE ticket_id = sqlc.arg(ticket_id) AND id <> sqlc.arg(id) AND parent_run_id IS NULL AND purpose = 'ticket'
ORDER BY started_at DESC LIMIT 1;

-- name: RunToolOutputBytes :one
-- What filled a run's context: its turns' tool output bytes, by group.
SELECT
  coalesce(sum((usage->>'explore_output_bytes')::bigint), 0)::bigint AS explore_output_bytes,
  coalesce(sum((usage->>'shell_output_bytes')::bigint), 0)::bigint AS shell_output_bytes,
  coalesce(sum((usage->>'other_output_bytes')::bigint), 0)::bigint AS other_output_bytes
FROM run_turns WHERE run_id = $1;

-- name: ClaimChecksRun :one
-- A delegated run that called complete_run and waits on its checks, once its
-- harness process has exited: this runner leases it to check the result. Only
-- runs this runner or a dead runner last held.
UPDATE runs SET runner_id = sqlc.arg(runner_id),
  execution_token = sqlc.narg(execution_token), execution_expires_at = sqlc.narg(execution_expires_at)
WHERE id = (
  SELECT r.id FROM runs r
  WHERE r.state = 'waiting' AND r.wait_reason = 'checks' AND r.parent_run_id IS NOT NULL
    AND (r.execution_expires_at IS NULL OR r.execution_expires_at <= now())
    AND (r.runner_id = sqlc.arg(runner_id) OR r.runner_id IS NULL
      OR r.runner_id NOT IN (SELECT id FROM runners WHERE heartbeat_at > now() - interval '45 seconds'))
    AND NOT EXISTS (SELECT 1 FROM run_turns b WHERE b.run_id = r.id AND (b.status = 'running' OR b.execution_expires_at > now()))
  ORDER BY r.started_at
  LIMIT 1
  FOR UPDATE SKIP LOCKED
)
RETURNING *;

-- name: WorkspaceImageEngine :one
SELECT image_engine FROM workspaces WHERE id = $1;

-- name: SetWorkspaceImageEngine :exec
UPDATE workspaces SET image_engine = $2, updated_at = now() WHERE id = $1;

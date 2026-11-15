-- name: CreateRun :one
INSERT INTO runs (workspace_id, ticket_id, agent_id, mode, state, resolved_spec, definition_version_id, harness, model, parent_run_id, purpose)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, sqlc.narg(parent_run_id), sqlc.arg(purpose)) RETURNING *;

-- name: GetRun :one
SELECT * FROM runs WHERE id = $1 AND workspace_id = $2;

-- name: LockRun :one
SELECT * FROM runs WHERE id = $1 FOR UPDATE;

-- name: ActiveRunForTicket :one
-- The ticket's top-level run; delegated runs belong to it.
SELECT * FROM runs WHERE ticket_id = $1 AND parent_run_id IS NULL AND state NOT IN ('completed', 'failed', 'cancelled');

-- name: ActiveChildRun :one
SELECT * FROM runs WHERE parent_run_id = $1 AND state NOT IN ('completed', 'failed', 'cancelled') ORDER BY started_at DESC LIMIT 1;

-- name: HasLiveChild :one
SELECT EXISTS(SELECT 1 FROM runs WHERE parent_run_id = $1 AND state NOT IN ('completed', 'failed', 'cancelled'));

-- name: CountChildRuns :one
SELECT count(*) FROM runs WHERE parent_run_id = $1;

-- name: ChildRuns :many
SELECT * FROM runs WHERE parent_run_id = $1 ORDER BY started_at;

-- name: LatestRunForTicket :one
SELECT * FROM runs WHERE ticket_id = $1 AND parent_run_id IS NULL ORDER BY started_at DESC LIMIT 1;

-- name: ActiveRunsForAgent :many
SELECT r.*, coalesce(t.key, 'Planning')::text AS ticket_key FROM runs r LEFT JOIN tickets t ON t.id = r.ticket_id
WHERE r.agent_id = $1 AND r.state NOT IN ('completed', 'failed', 'cancelled')
ORDER BY r.started_at;

-- name: SetRunState :one
UPDATE runs SET state = $2, wait_reason = $3,
  ended_at = CASE WHEN $2 IN ('completed', 'failed', 'cancelled') THEN now() ELSE ended_at END,
  outcome = coalesce(sqlc.narg(outcome), outcome)
WHERE id = $1 RETURNING *;

-- name: AddRunUsage :one
UPDATE runs SET tool_calls = tool_calls + $2, input_tokens = input_tokens + $3, output_tokens = output_tokens + $4,
  cost_usd_micros = cost_usd_micros + sqlc.arg(cost_usd_micros),
  cost_source = CASE WHEN cost_source IN ('unknown','partial') OR sqlc.narg(cost_source)::text = 'unknown' THEN
    CASE WHEN cost_usd_micros + sqlc.arg(cost_usd_micros) > 0 THEN 'partial' ELSE 'unknown' END
    ELSE coalesce(cost_source, sqlc.narg(cost_source)) END
WHERE id = $1 RETURNING *;

-- name: StartTurn :one
-- Managed turns wait for the runner (pending); unmanaged turns are records.
-- The turn keeps the run's current effort: a later turn may change the spec's.
-- effort_level is the level an automatic chat aimed for. A message ('comment')
-- turn sets its own; a resume or follow-up runs on at the previous turn's.
INSERT INTO run_turns (run_id, seq, trigger, input_message, status, effort, effort_level)
VALUES ($1, (SELECT coalesce(max(seq), 0) + 1 FROM run_turns WHERE run_id = $1), $2, $3,
  CASE WHEN (SELECT mode FROM runs WHERE id = $1) = 'managed' THEN 'pending' ELSE 'done' END,
  (SELECT resolved_spec->'harness_options'->>'effort' FROM runs WHERE id = $1),
  CASE WHEN $2 = 'comment' THEN sqlc.narg(effort_level)::text
    ELSE coalesce(sqlc.narg(effort_level)::text, (SELECT effort_level FROM run_turns WHERE run_id = $1 ORDER BY seq DESC LIMIT 1)) END)
RETURNING *;

-- name: SetTurnEffortReasons :exec
UPDATE run_turns SET effort_reasons = sqlc.arg(reasons)::text[] WHERE id = $1;

-- name: EndOpenTurn :exec
UPDATE run_turns SET ended_at = now(), exit_code = $2 WHERE run_id = $1 AND ended_at IS NULL;

-- name: ListTurns :many
SELECT * FROM run_turns WHERE run_id = $1 ORDER BY seq;

-- name: AddRunEvent :exec
INSERT INTO run_events (run_id, type, payload) VALUES ($1, $2, $3);

-- name: AddRunEvents :exec
INSERT INTO run_events (run_id, type, payload)
SELECT sqlc.arg(run_id)::uuid, t.typ, p.payload::jsonb
FROM unnest(sqlc.arg(types)::text[]) WITH ORDINALITY AS t(typ, i)
JOIN unnest(sqlc.arg(payloads)::text[]) WITH ORDINALITY AS p(payload, i) USING (i)
ORDER BY t.i;

-- name: ListRunEvents :many
SELECT * FROM run_events WHERE run_id = $1 AND seq > $2 ORDER BY seq LIMIT 1000;

-- name: DeletePlan :exec
DELETE FROM plan_steps WHERE run_id = $1;

-- name: InsertPlanStep :exec
INSERT INTO plan_steps (run_id, position, text, state) VALUES ($1, $2, $3, $4);

-- name: ListPlan :many
SELECT * FROM plan_steps WHERE run_id = $1 ORDER BY position;

-- name: SetStepState :execrows
UPDATE plan_steps SET state = $3 WHERE run_id = $1 AND position = $2;

-- name: SetStepNote :exec
UPDATE plan_steps SET note = $3 WHERE run_id = $1 AND position = $2;

-- name: ClearCurrentStep :exec
UPDATE plan_steps SET state = 'pending' WHERE run_id = $1 AND state = 'current' AND position <> $2;

-- name: SetAgentStatus :exec
UPDATE agents SET status = $2 WHERE id = $1;

-- name: CreateApproval :one
INSERT INTO approval_requests (workspace_id, run_id, ticket_id, agent_id, scope, action_summary, action_detail, risk_summary)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING *;

-- name: GetApproval :one
SELECT * FROM approval_requests WHERE id = $1 AND workspace_id = $2;

-- name: LockApproval :one
SELECT * FROM approval_requests WHERE id = $1 AND workspace_id = $2 FOR UPDATE;

-- name: DecideApproval :one
UPDATE approval_requests SET state = $2, decided_by_user_id = $3, decided_at = now(), decision_note = $4
WHERE id = $1 AND state = 'pending' RETURNING *;

-- name: MarkApprovalExecuted :one
UPDATE approval_requests SET executed_at = now(), result = $2
WHERE id = $1 AND state = 'approved' AND executed_at IS NULL RETURNING *;

-- name: ExpireRunApprovals :exec
UPDATE approval_requests SET state = 'expired' WHERE run_id = $1 AND state = 'pending';

-- name: PendingApprovalsForTicket :many
SELECT * FROM approval_requests WHERE ticket_id = $1 AND state = 'pending' ORDER BY created_at;

-- name: CountPendingApprovals :one
SELECT count(*)::int FROM approval_requests WHERE workspace_id = $1 AND state = 'pending';

-- name: SetTicketBranch :exec
UPDATE tickets SET branch = $2 WHERE id = $1;

-- name: SetTicketPR :exec
UPDATE tickets SET pr_number = $2, pr_url = $3, pr_state = coalesce($4, pr_state, 'open') WHERE id = $1;

-- name: GetCriterionByPosition :one
SELECT * FROM acceptance_criteria WHERE ticket_id = $1 ORDER BY position, created_at OFFSET $2 LIMIT 1;

-- name: ClaimApprovalExecution :one
-- Marks an approved request as executing exactly once (concurrent callers lose).
UPDATE approval_requests SET executed_at = now()
WHERE id = $1 AND run_id = $2 AND state = 'approved' AND executed_at IS NULL
RETURNING *;

-- name: SetApprovalResult :exec
UPDATE approval_requests SET result = $2 WHERE id = $1;

-- name: DecidedApprovalsSince :many
SELECT * FROM approval_requests WHERE run_id = $1 AND decided_at > $2 ORDER BY decided_at;

-- name: ListApprovalsForRun :many
SELECT * FROM approval_requests WHERE run_id = $1 ORDER BY created_at;

-- name: ReleaseApprovalExecution :exec
-- Nothing ran (e.g. the secret was missing): the approval can be used again.
UPDATE approval_requests SET executed_at = NULL WHERE id = $1 AND result IS NULL;


-- name: SetRunModel :exec
-- Same-harness model switch: keeps the session id and workspace.
UPDATE runs SET model = sqlc.arg(model)::text,
  resolved_spec = jsonb_set(resolved_spec, '{model}', to_jsonb(sqlc.arg(model)::text))
WHERE id = sqlc.arg(id);

-- name: SetRunEffort :exec
-- Same-harness effort switch: keeps the session id and workspace. An empty
-- effort removes the option so the harness uses its own default.
UPDATE runs SET resolved_spec = CASE WHEN sqlc.arg(effort)::text = ''
  THEN resolved_spec #- '{harness_options,effort}'
  ELSE jsonb_set(resolved_spec, '{harness_options}', coalesce(resolved_spec->'harness_options', '{}'::jsonb) || jsonb_build_object('effort', sqlc.arg(effort)::text))
  END
WHERE id = sqlc.arg(id);

-- name: RunVerdict :one
-- The review verdict ("" if none) a delegated run reported when it completed.
SELECT coalesce(payload->>'verdict', '')::text AS verdict FROM run_events WHERE run_id = $1 AND type = 'lifecycle' AND payload->>'state' = 'completed' ORDER BY seq DESC LIMIT 1;

-- name: SetRunContract :one
UPDATE runs SET contract = $2 WHERE id = $1 RETURNING *;

-- name: SetRunChecks :exec
UPDATE runs SET checks = $2 WHERE id = $1;

-- name: AddRunTiming :exec
-- Adds wall-clock milliseconds to a run's phase timings (NULL counts as 0).
UPDATE runs SET setup_ms = coalesce(setup_ms, 0) + sqlc.arg(setup_ms)::bigint,
  harness_ms = coalesce(harness_ms, 0) + sqlc.arg(harness_ms)::bigint,
  checks_ms = coalesce(checks_ms, 0) + sqlc.arg(checks_ms)::bigint
WHERE id = $1;

-- name: DelegationEfficiency :many
-- Per sub agent: what delegating to it costs and how often its first attempt
-- passes the runner's checks. A first pass also needs zero bounces (the server
-- never sent a check failure back to the sub agent). A repair loop is a later delegation to the same
-- agent under the same parent run.
-- checked counts delegations the runner checked (checks is not null; older runs
-- were never checked); first-pass rate is first_pass / checked.
-- parent_cost_usd_micros attributes each parent run's cost evenly across its
-- child runs (parent cost / number of child runs of that parent, finished or not), summed over this agent's children, so a parent that
-- delegated to several agents is not counted in full in each row.
-- avg_*_seconds average the phase timings over child runs that have them.
WITH kids AS (
  SELECT r.*, lead(r.id) OVER (PARTITION BY r.parent_run_id, r.agent_id ORDER BY r.started_at) AS repaired_by,
    (SELECT count(*) FROM runs c WHERE c.parent_run_id = r.parent_run_id) AS siblings
  FROM runs r
  WHERE r.workspace_id = $1 AND r.parent_run_id IS NOT NULL AND r.state IN ('completed', 'failed', 'cancelled')
)
SELECT k.agent_id,
  count(*)::bigint AS delegations,
  count(*) FILTER (WHERE k.checks IS NOT NULL)::bigint AS checked,
  count(*) FILTER (WHERE k.checks->>'passed' = 'true' AND coalesce((k.checks->>'bounces')::int, 0) = 0 AND k.repaired_by IS NULL)::bigint AS first_pass,
  count(*) FILTER (WHERE k.repaired_by IS NOT NULL)::bigint AS repair_loops,
  coalesce(sum(coalesce((k.checks->>'bounces')::int, 0)), 0)::bigint AS bounces,
  coalesce(sum(k.cost_usd_micros), 0)::bigint AS child_cost_usd_micros,
  floor(coalesce(sum(p.cost_usd_micros::float8 / k.siblings), 0))::bigint AS parent_cost_usd_micros,
  coalesce(sum(extract(epoch FROM (k.ended_at - k.started_at))), 0)::float8 AS child_seconds,
  (coalesce(avg(k.setup_ms), 0) / 1000)::float8 AS avg_setup_seconds,
  (coalesce(avg(k.harness_ms), 0) / 1000)::float8 AS avg_harness_seconds,
  (coalesce(avg(k.checks_ms), 0) / 1000)::float8 AS avg_checks_seconds
FROM kids k LEFT JOIN runs p ON p.id = k.parent_run_id GROUP BY k.agent_id;

-- name: ListMockupWaitingRuns :many
-- Top-level runs parked on a mockup review, with their ticket.
SELECT r.* FROM runs r
WHERE r.workspace_id = $1 AND r.parent_run_id IS NULL AND r.state = 'waiting' AND r.wait_reason = 'mockup_review';

-- name: CacheUsageForRuns :many
-- New turns explicitly record cache coverage; older Codex/Claude turns can be
-- recovered from the saved counters. Unsupported/unmanaged input stays unknown.
WITH counters AS (
  SELECT t.run_id,
    greatest(coalesce((t.usage->>'input_tokens')::bigint, 0), 0) AS input,
    greatest(coalesce((t.usage->>'cached_tokens')::bigint, 0), 0) AS cached,
    CASE WHEN t.usage ? 'cache_reported_input_tokens'
      THEN greatest(coalesce((t.usage->>'cache_reported_input_tokens')::bigint, 0), 0)
      WHEN t.usage ? 'cached_tokens' AND (t.usage ? 'session_input_tokens' OR t.usage->>'cost_source' = 'harness')
        AND r.harness IN ('codex','claude-code')
      THEN greatest(coalesce((t.usage->>'input_tokens')::bigint, 0), 0)
      ELSE 0 END AS reported
  FROM run_turns t JOIN runs r ON r.id=t.run_id
  WHERE t.run_id = ANY(sqlc.arg(run_ids)::uuid[])
)
SELECT run_id, sum(least(cached, reported, input))::bigint AS cached_input_tokens,
  sum(least(reported, input))::bigint AS reported_input_tokens
FROM counters GROUP BY run_id;

-- name: ListRuns :many
-- Top-level runs for the Runs index. A run's project comes from its ticket,
-- planning session or chat session; delegated runs are left to their parent
-- unless the list is filtered to one ticket, where every run is listed.
-- hide_chat leaves out Personal Assistant chat runs (they live in Chat).
SELECT r.* FROM runs r
LEFT JOIN tickets t ON t.id = r.ticket_id
LEFT JOIN planning_sessions ps ON ps.run_id = r.id
LEFT JOIN LATERAL (
  SELECT c.project_id FROM chat_sessions c
  WHERE r.purpose = 'chat' AND (c.current_run_id = r.id OR c.id IN (SELECT m.session_id FROM chat_messages m WHERE m.run_id = r.id))
  LIMIT 1
) cs ON true
WHERE r.workspace_id = sqlc.arg(workspace_id)
  AND (r.parent_run_id IS NULL OR sqlc.narg(ticket_id)::uuid IS NOT NULL)
  AND (sqlc.narg(ticket_id)::uuid IS NULL OR r.ticket_id = sqlc.narg(ticket_id))
  AND r.state = ANY(sqlc.arg(states)::text[])
  AND (sqlc.narg(agent_id)::uuid IS NULL OR r.agent_id = sqlc.narg(agent_id))
  AND (sqlc.narg(purpose)::text IS NULL OR r.purpose = sqlc.narg(purpose))
  AND (NOT sqlc.arg(hide_chat)::bool OR r.purpose NOT IN ('chat', 'research', 'workflow', 'learning'))
  AND (sqlc.narg(project_id)::uuid IS NULL OR coalesce(t.project_id, ps.project_id, cs.project_id) = sqlc.narg(project_id))
ORDER BY r.started_at DESC, r.id DESC
LIMIT 51 OFFSET sqlc.arg(skip)::int;

-- name: ChatSessionOfRun :one
-- The chat a chat run belongs to: its current run or an earlier segment.
SELECT * FROM (
  SELECT * FROM chat_sessions WHERE current_run_id = sqlc.arg(run_id)::uuid
  UNION ALL
  SELECT s.* FROM chat_messages m JOIN chat_sessions s ON s.id = m.session_id WHERE m.run_id = sqlc.arg(run_id)::uuid
) matched
LIMIT 1;

-- name: RunsTicketsByIDs :many
SELECT * FROM tickets WHERE workspace_id = sqlc.arg(workspace_id) AND id = ANY(sqlc.arg(ids)::uuid[]);

-- name: ProjectsByIDs :many
SELECT * FROM projects WHERE workspace_id = sqlc.arg(workspace_id) AND id = ANY(sqlc.arg(ids)::uuid[]);

-- name: ChildRunCounts :many
SELECT r.parent_run_id::uuid AS run_id, count(*)::bigint AS count
FROM runs r
WHERE r.parent_run_id = ANY(sqlc.arg(run_ids)::uuid[])
GROUP BY r.parent_run_id;

-- name: PlansForRuns :many
SELECT * FROM plan_steps WHERE run_id = ANY(sqlc.arg(run_ids)::uuid[]) ORDER BY run_id, position;

-- name: PlanningSessionsForRuns :many
SELECT * FROM planning_sessions WHERE run_id = ANY(sqlc.arg(run_ids)::uuid[]);

-- name: ResearchRunsMeta :many
SELECT t.run_id, c.id AS chat_id, j.title, c.project_id
FROM research_tasks t
JOIN research_jobs j ON j.id = t.job_id
JOIN chat_sessions c ON c.id = j.chat_id AND c.workspace_id = j.workspace_id
WHERE t.run_id = ANY(sqlc.arg(run_ids)::uuid[]);

-- name: LearningRunsMeta :many
SELECT lr.run_id, l.topic AS title, c.project_id
FROM learning_runs lr
JOIN learning_courses l ON l.id = lr.course_id
JOIN chat_sessions c ON c.id = l.chat_id AND c.workspace_id = l.workspace_id
WHERE lr.run_id = ANY(sqlc.arg(run_ids)::uuid[]);

-- name: WorkflowRunsMeta :many
SELECT s.agent_run_id::uuid AS run_id, r.chat_id, r.name AS title, r.project_id
FROM workflow_steps s
JOIN workflow_runs r ON r.id = s.run_id
WHERE s.agent_run_id = ANY(sqlc.arg(run_ids)::uuid[]);

-- name: ChatSessionsOfRuns :many
SELECT DISTINCT ON (matched.run_id) matched.run_id::uuid AS run_id, matched.chat_id, matched.title, matched.project_id
FROM (
  SELECT c.current_run_id AS run_id, c.id AS chat_id, c.title, c.project_id, 0 AS prio
  FROM chat_sessions c
  WHERE c.current_run_id = ANY(sqlc.arg(run_ids)::uuid[])
  UNION ALL
  SELECT m.run_id AS run_id, c.id AS chat_id, c.title, c.project_id, 1 AS prio
  FROM chat_messages m
  JOIN chat_sessions c ON c.id = m.session_id
  WHERE m.run_id = ANY(sqlc.arg(run_ids)::uuid[])
) matched
ORDER BY matched.run_id, matched.prio;

-- name: RunParentID :one
SELECT parent_run_id FROM runs WHERE id = $1;

-- name: RunEfficiencyEvents :many
-- The main agent's tool calls and results plus setup lifecycle events, slim:
-- what get_run's efficiency summary is computed from.
SELECT seq, type, at,
  coalesce(payload->>'state', '')::text AS state,
  coalesce(payload->>'id', '')::text AS call_id,
  coalesce(payload->>'tool', '')::text AS tool,
  coalesce(payload->'input'->>'command', '')::text AS command,
  coalesce((payload->>'context_tokens')::bigint, 0)::bigint AS context_tokens
FROM run_events
WHERE run_id = $1 AND type IN ('lifecycle', 'tool_call', 'tool_result')
  AND coalesce((payload->>'subagent')::boolean, false) = false
ORDER BY seq;

-- name: SetRunSpec :exec
-- A chat segment's capabilities refreshed in place: the CLI session and
-- workspace stay, the next invocation reads the new spec.
UPDATE runs SET resolved_spec = sqlc.arg(resolved_spec) WHERE id = sqlc.arg(id);

-- name: SetRunChatTools :exec
UPDATE runs SET chat_tool_names = sqlc.arg(names)::text[] WHERE id = sqlc.arg(id);

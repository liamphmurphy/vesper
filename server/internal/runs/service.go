// Package runs is the run lifecycle shared by the Agent API (MCP and REST)
// and the people supervising it (docs/dev/plan.md §5.2, §6.4): claiming tickets,
// plans, usage, approvals and the run_gated broker, waiting and resuming.
package runs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/repositories"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/transcript"
)

// Timeline verbs written by runs (see tracker/activity.go for the rest).
const (
	VerbRunStarted        = "run_started"        // {run_id, mode}
	VerbPlanPosted        = "plan_posted"        // {run_id, steps}
	VerbTestsRan          = "tests_ran"          // {run_id, passed, failed, duration_s}
	VerbBranchSet         = "branch_set"         // {branch}
	VerbPROpened          = "pr_opened"          // {number, url}
	VerbApprovalRequested = "approval_requested" // {approval_id, scope, summary}
	VerbApprovalApproved  = "approval_approved"  // {approval_id, scope, note}
	VerbApprovalDenied    = "approval_denied"    // {approval_id, scope, note}
	VerbGatedRan          = "gated_action_ran"   // {approval_id, scope, ok, summary}
	VerbWaitingForHuman   = "waiting_for_human"  // {run_id, reason}
	VerbRunPaused         = "run_paused"
	VerbRunResumed        = "run_resumed"
	VerbRunCancelled      = "run_cancelled"
	VerbRunCompleted      = "run_completed" // {run_id, outcome}
	VerbDispatched        = "dispatched"    // {run_id, agent_id, agent_name}
	VerbRunFailed         = "run_failed"    // {run_id, reason}
	VerbPRMerged          = "pr_merged"     // {number, url} (system)
	VerbPRClosed          = "pr_closed"     // {number, url} (system)
)

var Terminal = []string{"completed", "failed", "cancelled"}

type Service struct {
	RepositoryCatalog *repositories.Service
	Pool              *pgxpool.Pool
	Secrets           *secrets.Service
	Artifacts         *artifacts.Service
	Tracker           *tracker.Service
	CustomApps        *customapps.Service
	// RequireHarnessKey mirrors the runner's setting: chats can't select a
	// harness whose API-key secret is missing.
	RequireHarnessKey bool
	// ModelDiscovery overrides live provider discovery for embedded backends and tests.
	ModelDiscovery func(context.Context, string, string) ([]chatmodels.Model, error)
	// PlanModels lists plan-login models through a runner (chatmodels.Catalog.PlanModels).
	PlanModels func(context.Context, uuid.UUID, string, bool) ([]chatmodels.Model, error)
	// Poll is how often waits re-check state (tests shorten it).
	Poll time.Duration
	// HandoffChars bounds the prior transcript handed to a chat segment started
	// by a harness switch (0: DefaultHandoffChars).
	HandoffChars int
	// Transcripts fetches a chat message's YouTube links ahead of its turn; nil
	// leaves that to the chat's own tool call.
	Transcripts *transcript.YouTube
	// RolloverContextTokens mirrors the runner's setting (ROLLOVER_CONTEXT_TOKENS):
	// a main agent at least this large continues in a fresh session. 0 is off.
	RolloverContextTokens int64
}

type Caller = agents.Caller

func (s *Service) tx(ctx context.Context, fn func(q *store.Queries) error) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error { return fn(store.New(tx)) })
}

func agentActor(c Caller) tracker.Actor { return tracker.AgentActor(c.Agent.ID) }

func event(ctx context.Context, q *store.Queries, runID uuid.UUID, typ string, payload map[string]any) error {
	raw, _ := json.Marshal(payload)
	return q.AddRunEvent(ctx, store.AddRunEventParams{RunID: runID, Type: typ, Payload: raw})
}

// RecomputeAgentStatus derives running/waiting/blocked/idle from live runs.
func RecomputeAgentStatus(ctx context.Context, q *store.Queries, agentID uuid.UUID) error {
	live, err := q.ActiveRunsForAgent(ctx, agentID)
	if err != nil {
		return err
	}
	status := "idle"
	rank := map[string]int{"idle": 0, "waiting": 1, "blocked": 2, "running": 3}
	for _, r := range live {
		if r.Purpose == "chat" && r.State == "waiting" {
			continue // idle chats do not make the ticket agent busy
		}
		st := "running"
		switch r.State {
		case "queued":
			continue // dispatched, not started: the agent isn't busy yet
		case "waiting", "waiting_for_quota", "paused":
			st = "waiting"
		case "blocked":
			st = "blocked"
		}
		if rank[st] > rank[status] {
			status = st
		}
	}
	return q.SetAgentStatus(ctx, store.SetAgentStatusParams{ID: agentID, Status: status})
}

// ---------------------------------------------------------------- claiming

// Claim opens a run on a ticket assigned to the calling agent, freezing the
// resolved definition (§6.4). Claiming a ticket the agent already runs
// returns the live run, so reconnecting sessions can pick up where they were.
func (s *Service) Claim(ctx context.Context, c Caller, key string) (store.Run, error) {
	ws := c.Agent.WorkspaceID
	var run store.Run
	moved := false
	err := s.tx(ctx, func(q *store.Queries) error {
		if err := tracker.LockTicketProjects(ctx, q, ws, []string{key}); err != nil {
			if errors.Is(err, tracker.ErrNotFound) {
				return apperr.Invalid("ticket", "no ticket %s", key)
			}
			return err
		}
		t, err := q.LockTicketByKey(ctx, store.LockTicketByKeyParams{WorkspaceID: ws, Key: strings.ToUpper(strings.TrimSpace(key))})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Invalid("ticket", "no ticket %s", key)
		} else if err != nil {
			return err
		}
		if c.Agent.Kind == agents.KindSub {
			return apperr.Conflict("@%s is a sub agent: it runs when a main agent delegates to it, not from a ticket", c.Agent.Handle)
		}
		// A delegated copy runs as its lead's agent, which holds the ticket:
		// claiming would hand it the lead's run.
		if c.RunID != nil {
			own, err := q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: ws})
			if err != nil {
				return err
			}
			if own.ParentRunID != nil {
				return apperr.Conflict("a delegated run works under its main agent's claim; finish with complete_run instead")
			}
		}
		if t.AssigneeAgentID == nil || *t.AssigneeAgentID != c.Agent.ID {
			return apperr.Conflict("%s isn't assigned to @%s. A person assigns tickets; ask for it in a comment.", t.Key, c.Agent.Handle)
		}
		if t.Status == "canceled" {
			return apperr.Conflict("%s is canceled", t.Key)
		}
		if live, err := q.ActiveRunForTicket(ctx, &t.ID); err == nil {
			if live.AgentID != c.Agent.ID {
				return apperr.Conflict("%s already has a run by another agent", t.Key)
			}
			if c.RunID != nil && *c.RunID != live.ID {
				return apperr.Conflict("this token belongs to a different run")
			}
			if live.Mode == "managed" && c.RunID == nil {
				return apperr.Conflict("%s was dispatched to the runner; it runs there, not in this session", t.Key)
			}
			run = live
			return nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if t.Status == "done" {
			return apperr.Conflict("%s is done", t.Key)
		}
		p, err := q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: ws})
		if err != nil {
			return err
		}
		blockers, err := tracker.DispatchBlockers(ctx, q, t)
		if err != nil {
			return err
		}
		if len(blockers) > 0 {
			return apperr.Conflict("%s", strings.Join(blockers, "; "))
		}
		resolved, err := agents.Resolve(ctx, q, ws, c.Agent, p.Key)
		if err != nil {
			return err
		}
		if resolved.Repository, err = RepositoryFor(ctx, q, p, t); err != nil {
			return err
		}
		raw, _ := json.Marshal(resolved)
		mode := "managed"
		if c.Kind == "unmanaged" {
			mode = "unmanaged"
		}
		run, err = q.CreateRun(ctx, store.CreateRunParams{
			WorkspaceID: ws, TicketID: &t.ID, AgentID: c.Agent.ID, Mode: mode, State: "running",
			ResolvedSpec: raw, DefinitionVersionID: c.Agent.CurrentDefinitionVersionID, Harness: resolved.Harness, Model: resolved.Model, Purpose: "ticket",
		})
		if err != nil {
			return err
		}
		if _, err := q.StartTurn(ctx, store.StartTurnParams{RunID: run.ID, Trigger: "start"}); err != nil {
			return err
		}
		if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "running", "mode": mode}); err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, ws, t.ID, t.EpicID, agentActor(c), VerbRunStarted, map[string]any{"run_id": run.ID, "mode": mode}, nil); err != nil {
			return err
		}
		moved = t.Status == "backlog" || t.Status == "todo"
		return RecomputeAgentStatus(ctx, q, c.Agent.ID)
	})
	if err == nil && moved {
		st := "in_progress"
		_, err = s.Tracker.Update(ctx, ws, agentActor(c), key, tracker.Patch{Status: &st})
	}
	return run, err
}

// Dispatch queues managed runs for tickets' assigned agents (§6.6): a
// person's check before any agent runs. All or nothing.
func (s *Service) Dispatch(ctx context.Context, ws, userID uuid.UUID, keys []string) ([]store.Run, error) {
	if len(keys) == 0 {
		return nil, apperr.Invalid("keys", "pick at least one ticket")
	}
	var out []store.Run
	err := s.tx(ctx, func(q *store.Queries) error {
		if err := tracker.LockTicketProjects(ctx, q, ws, keys); err != nil {
			if errors.Is(err, tracker.ErrNotFound) {
				return apperr.Invalid("keys", "unknown ticket")
			}
			return err
		}
		for _, key := range keys {
			run, err := dispatchTicket(ctx, q, ws, userID, key, "keys")
			if err != nil {
				return err
			}
			out = append(out, run)
		}
		return nil
	})
	return out, err
}

// dispatchTicket queues one ticket's managed run inside the caller's
// transaction, which must already hold the ticket's project lock
// (tracker.LockTicketProjects). field names the request field in errors.
func dispatchTicket(ctx context.Context, q *store.Queries, ws, userID uuid.UUID, key, field string) (store.Run, error) {
	t, err := q.LockTicketByKey(ctx, store.LockTicketByKeyParams{WorkspaceID: ws, Key: strings.ToUpper(strings.TrimSpace(key))})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.Run{}, apperr.Invalid(field, "no ticket %s", key)
	} else if err != nil {
		return store.Run{}, err
	}
	if t.AssigneeAgentID == nil {
		return store.Run{}, apperr.Invalid(field, "%s has no agent; assign one first", t.Key)
	}
	if t.Status == "done" || t.Status == "canceled" {
		return store.Run{}, apperr.Conflict("%s is %s", t.Key, t.Status)
	}
	if live, err := q.ActiveRunForTicket(ctx, &t.ID); err == nil {
		return store.Run{}, apperr.Conflict("%s already has a %s run", t.Key, live.State)
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return store.Run{}, err
	}
	agent, err := q.GetAgent(ctx, store.GetAgentParams{ID: *t.AssigneeAgentID, WorkspaceID: ws})
	if err != nil {
		return store.Run{}, err
	}
	if agent.Kind == agents.KindSub {
		return store.Run{}, apperr.Conflict("%s is assigned to @%s, a sub agent; assign a main agent, which can delegate to it", t.Key, agent.Handle)
	}
	p, err := q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: ws})
	if err != nil {
		return store.Run{}, err
	}
	// Unfinished dependencies don't refuse the dispatch: the run stays
	// queued until its blockers are Done (see ClaimQueuedRun).
	blockers, err := tracker.HardBlockers(ctx, q, t)
	if err != nil {
		return store.Run{}, err
	}
	if len(blockers) > 0 {
		return store.Run{}, apperr.Conflict("%s: %s", t.Key, strings.Join(blockers, "; "))
	}
	resolved, err := agents.ResolveRunnable(ctx, q, ws, agent, p.Key)
	if err != nil {
		return store.Run{}, err
	}
	if resolved.Repository, err = RepositoryFor(ctx, q, p, t); err != nil {
		return store.Run{}, err
	}
	raw, _ := json.Marshal(resolved)
	run, err := q.CreateRun(ctx, store.CreateRunParams{
		WorkspaceID: ws, TicketID: &t.ID, AgentID: agent.ID, Mode: "managed", State: "queued",
		ResolvedSpec: raw, DefinitionVersionID: agent.CurrentDefinitionVersionID, Harness: resolved.Harness, Model: resolved.Model, Purpose: "ticket",
	})
	if err != nil {
		return store.Run{}, err
	}
	if err := q.SetRunDispatcher(ctx, store.SetRunDispatcherParams{ID: run.ID, DispatchedByUserID: &userID}); err != nil {
		return store.Run{}, err
	}
	if _, err := q.StartTurn(ctx, store.StartTurnParams{RunID: run.ID, Trigger: "start", InputMessage: StartPrompt(t.Key)}); err != nil {
		return store.Run{}, err
	}
	if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "queued", "mode": "managed"}); err != nil {
		return store.Run{}, err
	}
	if err := tracker.Record(ctx, q, ws, t.ID, t.EpicID, tracker.UserActor(userID), VerbDispatched,
		map[string]any{"run_id": run.ID, "agent_id": agent.ID, "agent_name": agent.Name}, nil); err != nil {
		return store.Run{}, err
	}
	if err := RecomputeAgentStatus(ctx, q, agent.ID); err != nil {
		return store.Run{}, err
	}
	return run, nil
}

// StartPrompt is the first message of a managed run. The rest of what the
// agent needs is in AGENTS.md and the Vesper tools.
func StartPrompt(key string) string {
	return "You've been dispatched to work on " + key + ". Follow AGENTS.md: call claim_ticket(\"" + key +
		"\") first, use relevant context already available in AGENTS.md, post_plan, then work directly. When you need a person, " +
		"call request_approval or await_human and end your turn. Verify every acceptance criterion; implement or delegate any gaps. " +
		"Once all criteria are verified and checked, commit and push any changes within your authorized scopes, record the PR, obtain independent review when required by the run policy or risk, and finish with complete_run(status=done)."
}

// Active resolves which run a tool call acts on: the token's run, the run on
// the named ticket, or the caller's only live run.
func (s *Service) Active(ctx context.Context, q *store.Queries, c Caller, ticketKey string) (store.Run, store.Ticket, error) {
	ws := c.Agent.WorkspaceID
	var run store.Run
	var err error
	switch {
	case c.RunID != nil:
		run, err = q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: ws})
	case ticketKey != "":
		var t store.Ticket
		t, err = tracker.Get(ctx, q, ws, strings.ToUpper(strings.TrimSpace(ticketKey)))
		if err != nil {
			return run, t, apperr.Invalid("ticket", "no ticket %s", ticketKey)
		}
		run, err = q.ActiveRunForTicket(ctx, &t.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			return run, t, apperr.Conflict("no live run on %s: call claim_ticket first", t.Key)
		}
	default:
		live, lerr := q.ActiveRunsForAgent(ctx, c.Agent.ID)
		if lerr != nil {
			return run, store.Ticket{}, lerr
		}
		switch len(live) {
		case 0:
			return run, store.Ticket{}, apperr.Conflict("no live run: call claim_ticket first")
		case 1:
			run, err = q.GetRun(ctx, store.GetRunParams{ID: live[0].ID, WorkspaceID: ws})
		default:
			keys := make([]string, len(live))
			for i, r := range live {
				keys[i] = r.TicketKey
			}
			return run, store.Ticket{}, apperr.Invalid("ticket", "you have several live runs (%s): pass ticket", strings.Join(keys, ", "))
		}
	}
	if err != nil {
		return run, store.Ticket{}, err
	}
	if run.AgentID != c.Agent.ID {
		return run, store.Ticket{}, apperr.ErrNotFound
	}
	if run.TicketID == nil {
		return run, store.Ticket{}, apperr.Conflict("planning runs use propose_tickets")
	}
	t, err := q.GetTicketByID(ctx, *run.TicketID)
	return run, t, err
}

// running loads the active run and requires it to be running.
func (s *Service) running(ctx context.Context, q *store.Queries, c Caller, key string) (store.Run, store.Ticket, error) {
	run, t, err := s.Active(ctx, q, c, key)
	if err != nil {
		return run, t, err
	}
	switch run.State {
	case "running":
		return run, t, nil
	case "waiting":
		if deref(run.WaitReason) == "checks" {
			return run, t, apperr.Conflict("you already called complete_run and the server is checking your work; end your turn")
		}
		return run, t, apperr.Conflict("the run is waiting for a person (%s); call await_signal", deref(run.WaitReason))
	case "paused":
		return run, t, apperr.Conflict("a person paused this run; stop and call await_signal")
	case "waiting_for_quota":
		return run, t, apperr.Conflict("the run is waiting for provider usage to reset; stop and call await_signal")
	default:
		return run, t, apperr.Conflict("the run is %s", run.State)
	}
}

func deref[T any](p *T) T {
	var z T
	if p == nil {
		return z
	}
	return *p
}

// Spec decodes a run's frozen resolved definition.
func Spec(run store.Run) (agentdef.Resolved, error) {
	var r agentdef.Resolved
	err := json.Unmarshal(run.ResolvedSpec, &r)
	return r, err
}

// ---------------------------------------------------------------- plan

func (s *Service) PostPlan(ctx context.Context, c Caller, key string, steps []string) ([]store.PlanStep, error) {
	clean := make([]string, 0, len(steps))
	for _, st := range steps {
		if st = strings.TrimSpace(st); st != "" {
			if len([]rune(st)) > 500 {
				return nil, apperr.Invalid("steps", "each step is limited to 500 characters")
			}
			clean = append(clean, st)
		}
	}
	if len(clean) == 0 || len(clean) > 30 {
		return nil, apperr.Invalid("steps", "post 1–30 steps")
	}
	var out []store.PlanStep
	err := s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		if err := q.DeletePlan(ctx, run.ID); err != nil {
			return err
		}
		for i, st := range clean {
			state := "pending"
			if i == 0 {
				state = "current"
			}
			if err := q.InsertPlanStep(ctx, store.InsertPlanStepParams{RunID: run.ID, Position: int32(i + 1), Text: st, State: state}); err != nil {
				return err
			}
		}
		if err := event(ctx, q, run.ID, "message", map[string]any{"kind": "plan", "steps": clean}); err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, agentActor(c), VerbPlanPosted, map[string]any{"run_id": run.ID, "steps": len(clean)}, nil); err != nil {
			return err
		}
		out, err = q.ListPlan(ctx, run.ID)
		return err
	})
	return out, err
}

var stepStates = []string{"pending", "current", "done", "needs_human", "failed"}

// StepNoteLimit bounds a step's handoff note, in runes.
const StepNoteLimit = 1500

// StepResult is what UpdateStep did.
type StepResult struct {
	// Current is the step promoted to current (0 when nothing advanced).
	Current int
	// Rollover asks the agent to end its turn: its next turn starts in a
	// fresh session (runs.rollover_requested). ContextTokens is the size that
	// triggered it.
	Rollover      bool
	ContextTokens int64
}

// UpdateStep sets one step's state and, when note is non-empty, its handoff
// note. Marking a step current clears any other current step, so the plan
// always shows one place the agent is at. Marking a step done while nothing is
// current promotes the next pending step. When that happens on a lead ticket
// run whose context is at least RolloverContextTokens, it also flags the run
// to continue in a fresh session (see wantsRollover).
func (s *Service) UpdateStep(ctx context.Context, c Caller, key string, n int, state, note string) (StepResult, error) {
	var res StepResult
	if !slices.Contains(stepStates, state) {
		return res, apperr.Invalid("state", "must be one of %s", strings.Join(stepStates, ", "))
	}
	note = strings.TrimSpace(note)
	if utf8.RuneCountInString(note) > StepNoteLimit {
		return res, apperr.Invalid("note", "must be at most %d characters", StepNoteLimit)
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		run, _, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		if state == "current" {
			if err := q.ClearCurrentStep(ctx, store.ClearCurrentStepParams{RunID: run.ID, Position: int32(n)}); err != nil {
				return err
			}
		}
		rows, err := q.SetStepState(ctx, store.SetStepStateParams{RunID: run.ID, Position: int32(n), State: state})
		if err != nil {
			return err
		}
		if rows == 0 {
			return apperr.Invalid("step", "no step %d in the plan", n)
		}
		if note != "" {
			if err := q.SetStepNote(ctx, store.SetStepNoteParams{RunID: run.ID, Position: int32(n), Note: &note}); err != nil {
				return err
			}
		}
		ev := map[string]any{"kind": "step", "step": n, "state": state}
		if note != "" {
			ev["note"] = note
		}
		if err := event(ctx, q, run.ID, "message", ev); err != nil {
			return err
		}
		if state != "done" {
			return nil
		}
		plan, err := q.ListPlan(ctx, run.ID)
		if err != nil {
			return err
		}
		next := int32(0)
		for _, st := range plan {
			if st.State == "current" {
				return nil
			}
			if st.State == "pending" && int(st.Position) > n && (next == 0 || st.Position < next) {
				next = st.Position
			}
		}
		if next == 0 {
			return nil
		}
		if _, err := q.SetStepState(ctx, store.SetStepStateParams{RunID: run.ID, Position: next, State: "current"}); err != nil {
			return err
		}
		res.Current = int(next)
		if err := event(ctx, q, run.ID, "message", map[string]any{"kind": "step", "step": res.Current, "state": "current"}); err != nil {
			return err
		}
		if !s.wantsRollover(run) {
			return nil
		}
		if err := q.SetRunRolloverRequested(ctx, store.SetRunRolloverRequestedParams{ID: run.ID, RolloverRequested: true}); err != nil {
			return err
		}
		res.Rollover, res.ContextTokens = true, run.ContextTokens
		return nil
	})
	return res, err
}

// wantsRollover reports whether a run that just finished a plan step should
// continue in a fresh session: the setting is on, it's a managed lead ticket
// run (delegated runs are short and their sessions are continued by the
// parent), and its last recorded context is at least the setting.
func (s *Service) wantsRollover(run store.Run) bool {
	limit := s.RolloverContextTokens
	return limit > 0 && run.ParentRunID == nil && run.Purpose == "ticket" && run.Mode == "managed" &&
		run.ContextTokens >= limit
}

// ---------------------------------------------------------------- events

// LogEvent records a rich timeline event. kind "test_run" takes
// {passed, failed, duration_s, command}; anything else goes to the run log only.
func (s *Service) LogEvent(ctx context.Context, c Caller, key, kind string, payload map[string]any) error {
	kind = strings.TrimSpace(kind)
	if kind == "" || len(kind) > 40 {
		return apperr.Invalid("kind", "is required")
	}
	if payload == nil {
		payload = map[string]any{}
	}
	return s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		if err := event(ctx, q, run.ID, "message", map[string]any{"kind": kind, "payload": payload}); err != nil {
			return err
		}
		if kind != "test_run" {
			return nil
		}
		num := func(k string) any {
			if v, ok := payload[k].(float64); ok {
				return v
			}
			return 0
		}
		p := map[string]any{"run_id": run.ID, "passed": num("passed"), "failed": num("failed"), "duration_s": num("duration_s")}
		if cmd, ok := payload["command"].(string); ok {
			p["command"] = cmd
		}
		return tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, agentActor(c), VerbTestsRan, p, nil)
	})
}

// ReportUsage adds self-reported usage. Only unmanaged sessions report;
// managed runs read usage from the harness stream (Phase 5).
func (s *Service) ReportUsage(ctx context.Context, c Caller, key string, toolCalls, inTok, outTok int64, costUSD float64) error {
	if toolCalls < 0 || inTok < 0 || outTok < 0 || costUSD < 0 {
		return apperr.Invalid("usage", "values can't be negative")
	}
	return s.tx(ctx, func(q *store.Queries) error {
		run, _, err := s.Active(ctx, q, c, key)
		if err != nil {
			return err
		}
		if run.Mode != "unmanaged" {
			return apperr.Conflict("managed runs get usage from the harness")
		}
		src := "reported"
		_, err = q.AddRunUsage(ctx, store.AddRunUsageParams{ID: run.ID, ToolCalls: int32(toolCalls), InputTokens: inTok, OutputTokens: outTok,
			CostUsdMicros: int64(costUSD * 1e6), CostSource: &src})
		return err
	})
}

var branchRe = regexp.MustCompile(`^[A-Za-z0-9._/-]{1,200}$`)

func (s *Service) SetBranch(ctx context.Context, c Caller, key, branch string) error {
	branch = strings.TrimSpace(branch)
	if !branchRe.MatchString(branch) || strings.Contains(branch, "..") {
		return apperr.Invalid("branch", "isn't a valid branch name")
	}
	return s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		if err := q.SetTicketBranch(ctx, store.SetTicketBranchParams{ID: t.ID, Branch: &branch}); err != nil {
			return err
		}
		return tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, agentActor(c), VerbBranchSet, map[string]any{"branch": branch}, nil)
	})
}

var prURLRe = regexp.MustCompile(`^https://github\.com/[\w.-]+/[\w.-]+/pull/(\d+)$`)

// SetPR records the ticket's pull request. The PR sync job (Phase 5) then
// keeps its state and diff stats current.
func (s *Service) SetPR(ctx context.Context, c Caller, key, url string, draft bool) error {
	if _, _, err := ParsePRURL(url); err != nil {
		return err
	}
	return s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		if err := requireMockup(ctx, q, run, t); err != nil {
			return err
		}
		return LinkPR(ctx, q, t, agentActor(c), url, draft)
	})
}

// ParsePRURL reads a GitHub pull request URL: its number and the URL itself.
func ParsePRURL(url string) (int32, string, error) {
	m := prURLRe.FindStringSubmatch(strings.TrimSpace(url))
	if m == nil {
		return 0, "", apperr.Invalid("url", "must be a GitHub pull request URL")
	}
	var num int32
	fmt.Sscan(m[1], &num)
	return num, m[0], nil
}

// LinkPR records t's pull request inside the caller's transaction, so the PR
// sync job follows it from now on: a merge moves the ticket to Done. Work done
// outside a ticket run (a persona coding in a chat) links its PR this way.
func LinkPR(ctx context.Context, q *store.Queries, t store.Ticket, actor tracker.Actor, url string, draft bool) error {
	num, u, err := ParsePRURL(url)
	if err != nil {
		return err
	}
	state := "open"
	if draft {
		state = "draft"
	}
	if err := q.SetTicketPR(ctx, store.SetTicketPRParams{ID: t.ID, PrNumber: &num, PrUrl: &u, PrState: &state}); err != nil {
		return err
	}
	return tracker.Record(ctx, q, t.WorkspaceID, t.ID, t.EpicID, actor, VerbPROpened, map[string]any{"number": num, "url": u, "draft": draft}, nil)
}

// CheckCriterion ticks acceptance criterion n (1-based, in display order).
func (s *Service) CheckCriterion(ctx context.Context, c Caller, key string, n int, done bool) error {
	return s.CheckCriteria(ctx, c, key, []int{n}, done)
}

// CheckCriteria ticks (or unticks) several criteria at once. Every number is
// validated first, so one bad number leaves all of them untouched.
func (s *Service) CheckCriteria(ctx context.Context, c Caller, key string, ns []int, done bool) error {
	var ids []uuid.UUID
	err := s.tx(ctx, func(q *store.Queries) error {
		ids = ids[:0]
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		if done {
			if err := requireMockup(ctx, q, run, t); err != nil {
				return err
			}
		}
		seen := map[int]bool{}
		for _, n := range ns {
			if n < 1 {
				return apperr.Invalid("n", "criteria are numbered from 1")
			}
			if seen[n] {
				continue
			}
			seen[n] = true
			cr, err := q.GetCriterionByPosition(ctx, store.GetCriterionByPositionParams{TicketID: t.ID, Offset: int32(n - 1)})
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Invalid("n", "no criterion %d", n)
			}
			if err != nil {
				return err
			}
			ids = append(ids, cr.ID)
		}
		return nil
	})
	if err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := s.Tracker.UpdateCriterion(ctx, c.Agent.WorkspaceID, agentActor(c), id, nil, &done); err != nil {
			return err
		}
	}
	return nil
}

// CreateReport stores an agent-authored REPORT and attaches it to the ticket
// as generated output ("Generated by Atlas").
func (s *Service) CreateReport(ctx context.Context, c Caller, key, title, body string) (store.Artifact, error) {
	var t store.Ticket
	var projectKey string
	err := s.tx(ctx, func(q *store.Queries) error {
		var err error
		_, t, err = s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		p, err := q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: t.WorkspaceID})
		projectKey = p.Key
		return err
	})
	if err != nil {
		return store.Artifact{}, err
	}
	a, err := s.Artifacts.Create(ctx, t.WorkspaceID, artifacts.Actor{Type: "agent", ID: c.Agent.ID}, artifacts.NewArtifact{
		ProjectKey: projectKey, Type: "report", Title: title, EpicID: t.EpicID, Content: artifacts.Content{BodyMD: &body},
	})
	if err != nil {
		return a, err
	}
	return a, s.Tracker.AttachArtifact(ctx, t.WorkspaceID, agentActor(c), t.Key, a.ID, "generated")
}

// Comment posts as the agent.
func (s *Service) Comment(ctx context.Context, c Caller, key, body string) (store.ActivityEvent, error) {
	var t store.Ticket
	err := s.tx(ctx, func(q *store.Queries) error {
		var err error
		_, t, err = s.Active(ctx, q, c, key)
		return err
	})
	if err != nil {
		return store.ActivityEvent{}, err
	}
	return s.Tracker.Comment(ctx, t.WorkspaceID, agentActor(c), t.Key, tracker.NewComment{BodyMd: body})
}

// ---------------------------------------------------------------- finishing

// Review verdicts a delegated reviewer or QA run reports with complete_run.
const (
	VerdictApproved         = "approved"
	VerdictChangesRequested = "changes_requested"
)

// ReviewClear requires independent approval only when configured. Any existing
// reviewer rejection remains a veto, even for a run with optional review.
func ReviewClear(ctx context.Context, q *store.Queries, run store.Run) error {
	children, err := q.ChildRuns(ctx, &run.ID)
	if err != nil {
		return err
	}
	latest := map[uuid.UUID]string{}
	for _, ch := range children {
		if ch.State != "completed" {
			continue
		}
		v, err := q.RunVerdict(ctx, ch.ID)
		if errors.Is(err, pgx.ErrNoRows) || v == "" {
			continue
		} else if err != nil {
			return err
		}
		if v == VerdictChangesRequested && reproCleared(ch) {
			v = VerdictApproved
		}
		latest[ch.AgentID] = v
	}
	spec, err := Spec(run)
	if err != nil {
		return err
	}
	if len(latest) == 0 && spec.ReviewRequired {
		return apperr.Conflict("a ticket can only be marked done after a delegated reviewer or QA agent gives the all clear (complete_run with verdict=approved). Delegate a review first, or finish with status in_review")
	}
	for _, v := range latest {
		if v != VerdictApproved {
			return apperr.Conflict("a reviewer requested changes; address them and have it re-review, or finish with status in_review")
		}
	}
	return nil
}

// reproCleared reports a review whose findings the server verified fixed: the
// reviewer said its repro_command covers every blocking finding, and
// recheck_review ran it green on the main agent's branch.
func reproCleared(ch store.Run) bool {
	var contract Contract
	var checks Checks
	if len(ch.Contract) == 0 || len(ch.Checks) == 0 || json.Unmarshal(ch.Contract, &contract) != nil || json.Unmarshal(ch.Checks, &checks) != nil {
		return false
	}
	return contract.ReproCoversAll && contract.ReproCommand != "" && checks.ReproFixed
}

// MaxReportRunes caps a delegated run's complete_run report.
const MaxReportRunes = 8000

// Repro is what a delegated reviewer reports about the failing tests it
// committed (complete_run repro_command and repro_covers_all).
type Repro struct {
	Command   string
	CoversAll bool
}

// Complete ends the run and moves the ticket (default: In Review). Done needs
// configured independent-review approval; existing review rejections always block Done.
func (s *Service) Complete(ctx context.Context, c Caller, key, outcome, report, status, verdict string) error {
	return s.CompleteWithRepro(ctx, c, key, outcome, report, status, verdict, Repro{})
}

// CompleteWithRepro is Complete for a delegated reviewer that also reports
// its repro command.
func (s *Service) CompleteWithRepro(ctx context.Context, c Caller, key, outcome, report, status, verdict string, repro Repro) error {
	repro.Command = strings.TrimSpace(repro.Command)
	if len([]rune(repro.Command)) > maxContractRunes {
		return apperr.Invalid("repro_command", "must be at most %d characters", maxContractRunes)
	}
	if repro.CoversAll && repro.Command == "" {
		return apperr.Invalid("repro_covers_all", "needs repro_command")
	}
	if status == "" {
		status = "in_review"
	}
	if status != "in_review" && status != "done" && status != "todo" {
		return apperr.Invalid("status", "must be in_review, done, or todo (to hand back)")
	}
	if verdict != "" && verdict != VerdictApproved && verdict != VerdictChangesRequested {
		return apperr.Invalid("verdict", "must be approved or changes_requested")
	}
	outcome = strings.TrimSpace(outcome)
	report = strings.TrimSpace(report)
	if n := utf8.RuneCountInString(report); n > MaxReportRunes {
		return apperr.Invalid("report", "is %d characters; keep it to %d", n, MaxReportRunes)
	}
	if c.RunID != nil {
		// A delegated run reports back to its parent instead of moving the ticket.
		var delegated bool
		if err := s.tx(ctx, func(q *store.Queries) error {
			r, err := q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
			delegated = err == nil && r.ParentRunID != nil
			return nil
		}); err != nil {
			return err
		}
		if delegated {
			return s.completeChild(ctx, c, key, outcome, report, verdict, repro)
		}
	}
	if report != "" {
		return apperr.Invalid("report", "only a delegated run sends a report")
	}
	if repro.Command != "" {
		return apperr.Invalid("repro_command", "only a delegated reviewer or QA run reports a repro_command")
	}
	var t store.Ticket
	err := s.tx(ctx, func(q *store.Queries) error {
		run, tk, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		t = tk
		if verdict != "" {
			return apperr.Invalid("verdict", "only a delegated reviewer or QA run reports a verdict")
		}
		if status == "in_review" || status == "done" {
			if err := requireMockup(ctx, q, run, tk); err != nil {
				return err
			}
			criteria, err := q.ListCriteria(ctx, tk.ID)
			if err != nil {
				return err
			}
			var unfinished []string
			for i, criterion := range criteria {
				if !criterion.Done {
					unfinished = append(unfinished, fmt.Sprintf("%d", i+1))
				}
			}
			if len(unfinished) > 0 {
				return apperr.Conflict("acceptance criteria %s are unchecked; verify each criterion and call check_criterion only when satisfied. Implement missing work yourself or delegate it, then retry complete_run. If blocked on a person, use await_human or request_approval; use status=todo only to explicitly hand back unfinished work", strings.Join(unfinished, ", "))
			}
		}
		if status == "done" {
			if err := ReviewClear(ctx, q, run); err != nil {
				return err
			}
		}
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "completed", Outcome: &outcome}); err != nil {
			return err
		}
		if err := q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
			return err
		}
		if err := q.ExpireRunApprovals(ctx, run.ID); err != nil {
			return err
		}
		if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "completed", "outcome": outcome}); err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, agentActor(c), VerbRunCompleted, map[string]any{"run_id": run.ID, "outcome": outcome}, nil); err != nil {
			return err
		}
		return RecomputeAgentStatus(ctx, q, c.Agent.ID)
	})
	if err != nil {
		return err
	}
	_, err = s.Tracker.Update(ctx, t.WorkspaceID, agentActor(c), t.Key, tracker.Patch{Status: &status})
	return err
}

func ptr[T any](v T) *T { return &v }

// RepositoryFor freezes the project's repository configuration for a ticket
// run. A ticket in an epic stacks on the epic's shared branch, so the whole
// epic ships as one pull request.
func RepositoryFor(ctx context.Context, q *store.Queries, p store.Project, t store.Ticket) (*agentdef.Repository, error) {
	repo := &agentdef.Repository{URL: p.RepoUrl, DefaultBranch: p.DefaultBranch}
	if t.EpicID == nil {
		return repo, nil
	}
	e, err := q.GetEpic(ctx, store.GetEpicParams{ID: *t.EpicID, WorkspaceID: t.WorkspaceID})
	if err != nil {
		return nil, err
	}
	repo.EpicBranch, repo.EpicName = agentdef.EpicBranch(p.Key, e.ID.String()), e.Name
	if !t.EpicReview {
		return repo, nil
	}
	rows, err := q.ListEpicReviewTickets(ctx, t.EpicID)
	if err != nil {
		return nil, err
	}
	repo.EpicReview = true
	for _, r := range rows {
		repo.EpicTickets = append(repo.EpicTickets, agentdef.EpicTicket{
			Key: r.Key, Title: r.Title, Status: r.Status,
			Branch: deref(r.Branch), PRURL: deref(r.PrUrl), PRState: deref(r.PrState),
		})
	}
	return repo, nil
}

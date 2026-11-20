package runner

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"math"
	"path"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/slides"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// Config tunes a runner.
type Config struct {
	ID            string        // unique per runner process
	MaxConcurrent int           // processes at once (RUNNER_MAX_CONCURRENT)
	MCPURL        string        // Vesper's /mcp as turns reach it
	GitHubAPIURL  string        // GitHub's REST API for shipping approved pushes; api.github.com when empty (tests point elsewhere)
	Poll          time.Duration // queue poll interval
	Grace         time.Duration // after SIGINT, before SIGKILL (pause, cancel)
	LogBucket     string        // raw harness logs (run-logs)
	// AttachmentBucket holds chat attachments (the artifact bucket).
	AttachmentBucket string
	Version          string
	// RequireHarnessKey refuses to start a run without the harness's API
	// key secret. MicroVM runs need it; local runs can use the host's login.
	RequireHarnessKey bool
	ModelPrices       map[string]harness.Price
	// ChatIdleTTL ends a chat segment idle this long so its workspace is
	// freed; the chat's next message starts a new segment. 0 means
	// DefaultChatIdleTTL.
	ChatIdleTTL time.Duration
	// ChatImageTimeout bounds one Codex image step for a chat on another
	// harness. 0 means DefaultChatImageTimeout.
	ChatImageTimeout time.Duration
	// MaxHold, MaxHoldAttempts and HoldBackoff bound a run held at a provider
	// limit (see hold.go). 0 means the Default of each.
	MaxHold         time.Duration
	MaxHoldAttempts int
	HoldBackoff     time.Duration
	// Playgrounds serves chats' playgrounds (microVM backend only).
	Playgrounds PlaygroundConfig
	// RolloverContextTokens continues a main agent whose context is at least
	// this many tokens in a fresh session at a delegation wake (rollover.go).
	// 0 never rolls over.
	RolloverContextTokens int64
	// RepoMap delivers a generated map of a ticket run's repository at its
	// base commit as a context file (repomap.go, RUNNER_REPO_MAP).
	RepoMap bool
}

// DefaultChatIdleTTL is how long an idle chat segment keeps its workspace.
const DefaultChatIdleTTL = 4 * time.Hour

// Blobs stores raw logs and generated chat images (blob.Store).
type Blobs interface {
	Put(ctx context.Context, bucket, key string, body io.Reader, size int64, contentType string) error
	Delete(ctx context.Context, bucket, key string) error
}

// AttachmentStore reads chat attachments and deletes stale ones (blob.Store).
type AttachmentStore interface {
	Get(ctx context.Context, bucket, key string) (blob.Object, error)
	Delete(ctx context.Context, bucket, key string) error
}

type Runner struct {
	// listings counts the model listings in flight (capped by tickModelListings).
	listings atomic.Int32
	// usageChecks counts the usage checks in flight (capped by tickUsageChecks).
	usageChecks atomic.Int32
	// otherBackend are ended runs whose workspace is on the other backend, so
	// they don't crowd this runner's sweeps. Only Sweep touches it.
	otherBackend []uuid.UUID
	Cfg          Config
	Pool         *pgxpool.Pool
	Backend      Backend
	Secrets      Revealer
	Tracker      *tracker.Service
	Blobs        Blobs // nil: raw logs aren't kept
	// Attachments reads chat attachments (blob.Store); nil: they're named in
	// the prompt but not delivered, and stale uploads aren't swept.
	Attachments AttachmentStore
	// Workflows moves workflow runs on when a step ends; nil leaves that to the API.
	Workflows *runs.WorkflowEngine
	// Scheduled starts and settles scheduled tasks; nil leaves them idle.
	Scheduled *runs.Service
	// devWSBusy is set while tickDevWorkspace's worker runs.
	devWSBusy atomic.Bool
	// Designs draws and inspects design frames linked to a ticket, which its
	// runs receive as context; nil delivers only a note for each frame.
	Designs DesignRenderer
	// StoreSecret saves logins from sign-ins started in Settings; nil leaves
	// them to another runner.
	StoreSecret SecretStorer
	// OnHeartbeat runs after a heartbeat succeeds; vesper app uses it to
	// clear its startup flag once the runner is visible in LiveRunners.
	OnHeartbeat func()
	Log         *slog.Logger

	mu     sync.Mutex
	active int
	// slotLimit is a temporary cap below Cfg.MaxConcurrent (0: none), read
	// from the runner's registration on each heartbeat (PUT /runner/slot-limit).
	slotLimit int
	wg        sync.WaitGroup
	// sweeping keeps Run to one Sweep in flight (Sweep alone owns otherBackend).
	sweeping atomic.Bool
	// scheduling keeps Run to one scheduled tick in flight off the poll loop.
	scheduling atomic.Bool
	// playgrounds is what this process serves of chats' playgrounds; nil
	// when it serves none.
	playgrounds *playgroundHost
	// wtLocks serialises worktree creation, merges and removal per workspace
	// within this runner process. Git locks and the run state machine cover
	// cross-process operations.
	wtLocks sync.Map
	// repoMaps are generated repo maps by repository and commit (repomap.go).
	repoMaps repoMapCache
}

const tokenEnv = "LAZYAGENTS_TOKEN"

func (r *Runner) q() *store.Queries { return store.New(r.Pool) }

func (r *Runner) system() tracker.Actor { return tracker.Actor{Type: "system"} }

// Run polls until ctx is cancelled. In-flight processes are killed on exit;
// their turns run again when a runner starts (the harness resumes).
func (r *Runner) Run(ctx context.Context) error {
	if r.Cfg.Poll <= 0 {
		r.Cfg.Poll = time.Second
	}
	if err := r.Recover(ctx); err != nil {
		return err
	}
	if w, ok := r.Backend.(SpareWarmer); ok {
		w.WarmSpares() // after Recover, which clears spares a previous runner left
	}
	r.expireModelListings(ctx)
	r.ServePlaygrounds(ctx)
	r.InitDevWorkspaces(ctx)
	beat := time.NewTicker(10 * time.Second)
	defer beat.Stop()
	sweep := time.NewTicker(30 * time.Second)
	defer sweep.Stop()
	poll := time.NewTicker(r.Cfg.Poll)
	defer poll.Stop()
	schedule := time.NewTicker(15 * time.Second)
	defer schedule.Stop()
	r.heartbeat(ctx)
	// Before waiting on the ticker: anything missed while Vesper was off runs once now.
	r.scheduleTickAsync(ctx)
	for {
		select {
		case <-ctx.Done():
			r.wg.Wait()
			qctx, cancel := context.WithTimeout(context.Background(), controlTimeout)
			_ = r.q().DeleteRunner(qctx, r.Cfg.ID)
			cancel()
			return nil
		case <-beat.C:
			r.heartbeat(ctx)
		case <-sweep.C:
			// Off this loop: a sweep runs checkpoint pushes, and while one is
			// slow nothing would be claimed and no heartbeat sent. One at a time.
			if r.sweeping.CompareAndSwap(false, true) {
				r.wg.Add(1)
				go func() {
					defer r.wg.Done()
					defer r.sweeping.Store(false)
					r.Sweep(ctx)
				}()
			}
		case <-poll.C:
			r.Tick(ctx)
		case <-schedule.C:
			r.scheduleTickAsync(ctx)
		}
	}
}

// Recover requeues work a dead runner left half-done.
func (r *Runner) Recover(ctx context.Context) error {
	if err := r.Backend.Cleanup(ctx); err != nil {
		r.Log.Warn("runner cleanup", "err", err)
	}
	return r.reconcile(ctx)
}

// StrandedResumeMessage continues a run whose last turn a runner shutdown cut short.
const StrandedResumeMessage = "Vesper's runner restarted while your last turn was running, so it was cut short. " +
	"Continue where you left off, in the same checkout."

// resumeStranded gives a run left running with no turn (see StrandedRuns) a
// turn that continues its session; otherwise it would hold its agent's slot
// forever and every later run of that agent would stay queued.
func (r *Runner) resumeStranded(ctx context.Context) error {
	ids, err := r.q().StrandedRuns(ctx, &r.Cfg.ID)
	if err != nil {
		return err
	}
	for _, id := range ids {
		err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
			q := store.New(tx)
			run, err := q.LockRun(ctx, id)
			if err != nil || run.State != "running" {
				return err
			}
			if pending, err := q.HasPendingTurn(ctx, id); err != nil || pending {
				return err
			}
			if _, err := q.StartTurn(ctx, store.StartTurnParams{RunID: id, Trigger: "resume", InputMessage: StrandedResumeMessage}); err != nil {
				return err
			}
			b, _ := json.Marshal(map[string]any{"state": "stranded_resumed", "runner": r.Cfg.ID})
			return q.AddRunEvent(ctx, store.AddRunEventParams{RunID: id, Type: "lifecycle", Payload: b})
		})
		if err != nil {
			return fmt.Errorf("resume stranded run %s: %w", id, err)
		}
	}
	return nil
}

// scheduleTickAsync starts tickScheduled off the main event loop so a
// long-running custom app tool sync never stalls heartbeats or polling.
func (r *Runner) scheduleTickAsync(ctx context.Context) {
	if r.Scheduled == nil || !r.scheduling.CompareAndSwap(false, true) {
		return
	}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer r.scheduling.Store(false)
		r.tickScheduled(ctx)
	}()
}

// tickScheduled starts tasks that are due and records runs that have ended.
func (r *Runner) tickScheduled(ctx context.Context) {
	if r.Scheduled == nil {
		return
	}
	if err := r.Scheduled.RunDueScheduled(ctx); err != nil && ctx.Err() == nil {
		r.Log.Error("start scheduled tasks", "err", err)
	}
	if err := r.Scheduled.SettleScheduled(ctx); err != nil && ctx.Err() == nil {
		r.Log.Error("settle scheduled tasks", "err", err)
	}
}

func (r *Runner) heartbeat(ctx context.Context) {
	ctx, cancel := context.WithTimeout(ctx, controlTimeout)
	defer cancel()
	r.mu.Lock()
	n := r.active
	r.mu.Unlock()
	hostDir := ""
	if hf, ok := r.Backend.(HostFolders); ok {
		hostDir = hf.HostWorkspacesDir()
	}
	if err := r.q().Heartbeat(ctx, store.HeartbeatParams{ID: r.Cfg.ID, Backend: r.Backend.Name(),
		MaxConcurrent: int32(r.Cfg.MaxConcurrent), Running: int32(n), Version: r.Cfg.Version, HostWorkspacesDir: hostDir}); err != nil {
		if ctx.Err() == nil {
			r.Log.Warn("heartbeat", "err", err)
		}
		return
	}
	if r.OnHeartbeat != nil {
		r.OnHeartbeat()
	}
	limit, err := r.q().RunnerSlotLimit(ctx, r.Cfg.ID)
	if err != nil {
		// Keep the last known cap: a failed read must not lift a thermal cap.
		if ctx.Err() == nil {
			r.Log.Warn("read slot limit", "err", err)
		}
		return
	}
	r.mu.Lock()
	r.slotLimit = 0
	if limit != nil {
		r.slotLimit = int(*limit)
	}
	r.mu.Unlock()
}

// capacity is how many runs this runner takes at once right now: its
// MaxConcurrent, or a lower slot limit while one is set. Work already running
// over a new cap finishes; the runner just claims nothing more until below it.
func (r *Runner) capacity() int {
	if r.slotLimit > 0 && r.slotLimit < r.Cfg.MaxConcurrent {
		return r.slotLimit
	}
	return r.Cfg.MaxConcurrent
}

func (r *Runner) slot() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.active >= r.capacity() {
		return false
	}
	r.active++
	return true
}

func (r *Runner) release() {
	r.mu.Lock()
	r.active--
	r.mu.Unlock()
	r.wg.Done()
}

// Tick starts what it can: queued runs first (workspace setup), then
// pending turns of running runs. Work runs in goroutines; Wait waits.
func (r *Runner) Tick(ctx context.Context) {
	if err := r.reconcile(ctx); err != nil {
		if ctx.Err() == nil {
			r.Log.Warn("reconcile runner work", "err", err)
		}
		return
	}
	q := r.q()
	r.tickSignIns(ctx)
	r.tickModelListings(ctx)
	r.tickUsageChecks(ctx)
	r.resumeHeld(ctx)
	r.tickPlaygrounds(ctx)
	r.tickDevWorkspace(ctx)
	r.tickChecks(ctx)
	for r.slot() {
		token, expires := uuid.New(), time.Now().Add(executionTTL)
		claimCtx, cancel := context.WithTimeout(ctx, controlTimeout)
		run, err := q.ClaimQueuedRun(claimCtx, store.ClaimQueuedRunParams{RunnerID: &r.Cfg.ID, ExecutionToken: &token, ExecutionExpiresAt: &expires})
		cancel()
		if err != nil {
			r.mu.Lock()
			r.active--
			r.mu.Unlock()
			if !errors.Is(err, pgx.ErrNoRows) && ctx.Err() == nil {
				r.Log.Error("claim run", "err", err)
			}
			break
		}
		r.wg.Add(1)
		go func() {
			defer r.release()
			r.execute(ctx, run.ID, false, run.ExecutionToken, run.ExecutionExpiresAt, func(ctx context.Context) { r.start(ctx, run) })
		}()
	}
	for r.slot() {
		token, expires := uuid.New(), time.Now().Add(executionTTL)
		claimCtx, cancel := context.WithTimeout(ctx, controlTimeout)
		turn, err := q.ClaimPendingTurn(claimCtx, store.ClaimPendingTurnParams{ExecutionToken: &token, ExecutionExpiresAt: &expires})
		cancel()
		if err != nil {
			r.mu.Lock()
			r.active--
			r.mu.Unlock()
			if !errors.Is(err, pgx.ErrNoRows) && ctx.Err() == nil {
				r.Log.Error("claim turn", "err", err)
			}
			break
		}
		r.wg.Add(1)
		go func() {
			defer r.release()
			r.execute(ctx, turn.ID, true, turn.ExecutionToken, turn.ExecutionExpiresAt, func(ctx context.Context) { r.turn(ctx, turn) })
		}()
	}
}

// Wait blocks until in-flight work finishes (tests).
func (r *Runner) Wait() { r.wg.Wait() }

// ---------------------------------------------------------------- context

type runCtx struct {
	run             store.Run
	ticket          store.Ticket
	agent           store.Agent
	project         store.Project
	spec            agentdef.Resolved
	chatRepoAtStart *string
	isolateGit      bool // see isolatedGitConfig
}

func (r *Runner) load(ctx context.Context, runID uuid.UUID) (runCtx, error) {
	q := r.q()
	c := runCtx{isolateGit: r.isolatesGit()}
	var err error
	if c.run, err = q.LockRunNoWait(ctx, runID); err != nil {
		return c, err
	}
	if c.run.Purpose == "ticket" && c.run.TicketID != nil {
		if c.ticket, err = q.GetTicketByID(ctx, *c.run.TicketID); err != nil {
			return c, err
		}
	} else if c.run.Purpose == "chat" {
		chat, err := q.ChatSessionForRun(ctx, &c.run.ID)
		if err != nil {
			return c, err
		}
		selected := ""
		if chat.RepoUrl != nil {
			selected = *chat.RepoUrl
		}
		c.chatRepoAtStart = &selected
		c.ticket = store.Ticket{WorkspaceID: chat.WorkspaceID, ProjectID: runs.ProjectIDOrNil(chat.ProjectID), Key: "CHAT-" + chat.ID.String()[:8], Title: chat.Title}
	} else if c.run.Purpose == runs.PurposeResearch {
		job, err := q.ResearchJobForRun(ctx, c.run.ID)
		if err != nil {
			return c, err
		}
		chat, err := q.GetChatSession(ctx, store.GetChatSessionParams{ID: job.ChatID, WorkspaceID: job.WorkspaceID})
		if err != nil {
			return c, err
		}
		c.ticket = store.Ticket{WorkspaceID: job.WorkspaceID, ProjectID: runs.ProjectIDOrNil(chat.ProjectID), Key: "RES-" + job.ID.String()[:8], Title: job.Title}
	} else if c.run.Purpose == runs.PurposeLearning {
		course, err := q.LearningCourseForRun(ctx, c.run.ID)
		if err != nil {
			return c, err
		}
		chat, err := q.GetChatSession(ctx, store.GetChatSessionParams{ID: course.ChatID, WorkspaceID: course.WorkspaceID})
		if err != nil {
			return c, err
		}
		c.ticket = store.Ticket{WorkspaceID: course.WorkspaceID, ProjectID: runs.ProjectIDOrNil(chat.ProjectID), Key: "LRN-" + course.ID.String()[:8], Title: course.Topic}
	} else if c.run.Purpose == runs.PurposeWorkflow {
		wf, err := q.WorkflowRunForAgentRun(ctx, &c.run.ID)
		if err != nil {
			return c, err
		}
		c.ticket = store.Ticket{WorkspaceID: wf.WorkspaceID, ProjectID: runs.ProjectIDOrNil(wf.ProjectID), Key: "WF-" + wf.ID.String()[:8], Title: wf.Name}
	} else {
		plan, err := q.PlanningSessionForRun(ctx, c.run.ID)
		if err != nil {
			return c, err
		}
		c.ticket = store.Ticket{WorkspaceID: plan.WorkspaceID, ProjectID: plan.ProjectID, EpicID: plan.EpicID, Key: "PLAN-" + plan.ID.String()[:8], Title: plan.Goal}
	}
	if c.agent, err = q.GetAgent(ctx, store.GetAgentParams{ID: c.run.AgentID, WorkspaceID: c.run.WorkspaceID}); err != nil {
		return c, err
	}
	// Chats and their workflows may have no project: c.project stays zero, and
	// its uuid.Nil id matches only workspace-level secrets.
	if c.ticket.ProjectID != uuid.Nil {
		if c.project, err = q.GetProject(ctx, store.GetProjectParams{ID: c.ticket.ProjectID, WorkspaceID: c.run.WorkspaceID}); err != nil {
			return c, err
		}
	}
	c.spec, err = runs.Spec(c.run)
	if c.spec.Repository != nil {
		c.project.RepoUrl = c.spec.Repository.URL
		c.project.DefaultBranch = c.spec.Repository.DefaultBranch
	}
	return c, err
}

// addTiming adds to a run's cumulative phase timings. It is best-effort and
// uses its own context so a shutting-down runner still records the phase.
func (r *Runner) addTiming(runID uuid.UUID, setup, harness, checks time.Duration) {
	ctx, cancel := context.WithTimeout(context.Background(), controlTimeout)
	defer cancel()
	err := r.q().AddRunTiming(ctx, store.AddRunTimingParams{ID: runID,
		SetupMs: setup.Milliseconds(), HarnessMs: harness.Milliseconds(), ChecksMs: checks.Milliseconds()})
	if err != nil {
		r.Log.Warn("record timing", "run", runID, "err", err)
	}
}

func (r *Runner) event(ctx context.Context, runID uuid.UUID, typ string, payload map[string]any) {
	b, _ := json.Marshal(payload)
	r.eventJSON(ctx, runID, typ, b)
}

// eventJSON records an event whose payload is already encoded.
func (r *Runner) eventJSON(ctx context.Context, runID uuid.UUID, typ string, b []byte) {
	if err := r.q().AddRunEvent(ctx, store.AddRunEventParams{RunID: runID, Type: typ, Payload: b}); err != nil && ctx.Err() == nil {
		r.Log.Warn("run event", "run", runID, "err", err)
	}
}

const (
	runEventBatchMaxEvents = 64
	runEventBatchMaxBytes  = 512 << 10
	runEventBatchFlushWait = 50 * time.Millisecond
)

type pendingRunEvent struct {
	typ     string
	payload []byte
}

// eventsJSON records a batch of encoded events in order.
func (r *Runner) eventsJSON(ctx context.Context, runID uuid.UUID, evs []pendingRunEvent) {
	if len(evs) == 0 {
		return
	}
	if len(evs) == 1 {
		r.eventJSON(ctx, runID, evs[0].typ, evs[0].payload)
		return
	}
	types := make([]string, len(evs))
	payloads := make([]string, len(evs))
	for i, ev := range evs {
		types[i] = ev.typ
		if len(ev.payload) == 0 {
			payloads[i] = "{}"
		} else {
			payloads[i] = string(ev.payload)
		}
	}
	if err := r.q().AddRunEvents(ctx, store.AddRunEventsParams{RunID: runID, Types: types, Payloads: payloads}); err != nil && ctx.Err() == nil {
		r.Log.Warn("run events", "run", runID, "count", len(evs), "err", err)
	}
}

func (r *Runner) flushRunEvents(ctx context.Context, runID uuid.UUID, ch <-chan pendingRunEvent) {
	var buf []pendingRunEvent
	var bufferedBytes int
	var timer *time.Timer
	var timerC <-chan time.Time
	stopTimer := func() {
		if timer == nil {
			return
		}
		if !timer.Stop() {
			select {
			case <-timer.C:
			default:
			}
		}
		timer = nil
		timerC = nil
	}
	flush := func(flushCtx context.Context) {
		stopTimer()
		if len(buf) == 0 {
			return
		}
		wctx, cancel := context.WithTimeout(flushCtx, controlTimeout)
		r.eventsJSON(wctx, runID, buf)
		cancel()
		clear(buf)
		buf = buf[:0]
		bufferedBytes = 0
	}
	for {
		select {
		case ev, ok := <-ch:
			if !ok {
				flush(context.WithoutCancel(ctx))
				return
			}
			buf = append(buf, ev)
			bufferedBytes += len(ev.payload)
			if len(buf) >= runEventBatchMaxEvents || bufferedBytes >= runEventBatchMaxBytes {
				flush(ctx)
			} else if timer == nil {
				timer = time.NewTimer(runEventBatchFlushWait)
				timerC = timer.C
			}
		case <-timerC:
			timer = nil
			timerC = nil
			flush(ctx)
		}
	}
}

// end finishes a run the runner had to stop (failure or a guard), with a
// timeline entry and the workspace removed.
func (r *Runner) end(ctx context.Context, c runCtx, state, outcome, verb string) {
	if c.run.Purpose == "chat" {
		r.failChat(ctx, c, outcome)
		return
	}
	err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		run, err := q.LockRun(ctx, c.run.ID)
		if err != nil {
			return err
		}
		if run.State == "completed" || run.State == "failed" || run.State == "cancelled" {
			return nil
		}
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: state, Outcome: &outcome}); err != nil {
			return err
		}
		if err := q.DropPendingTurns(ctx, run.ID); err != nil {
			return err
		}
		if err := q.ExpireRunApprovals(ctx, run.ID); err != nil {
			return err
		}
		b, _ := json.Marshal(map[string]any{"state": state, "reason": outcome})
		if err := q.AddRunEvent(ctx, store.AddRunEventParams{RunID: run.ID, Type: "lifecycle", Payload: b}); err != nil {
			return err
		}
		if err := runnerRecord(ctx, q, c.run.WorkspaceID, c.ticket.ID, c.ticket.EpicID, r.system(), verb,
			map[string]any{"run_id": run.ID, "reason": outcome}, nil); err != nil {
			return err
		}
		// A delegated run reports to its parent; a parent takes its delegated runs down with it.
		if err := runs.CancelChildren(ctx, q, run.ID, "The main agent's run ended: "+outcome); err != nil {
			return err
		}
		if err := runs.RecomputeAgentStatus(ctx, q, run.AgentID); err != nil {
			return err
		}
		return runs.WakeParent(ctx, q, run, state, outcome)
	})
	if err != nil {
		r.Log.Error("end run", "run", c.run.ID, "err", err)
	}
	// Only a successful run's workspace goes: a failed or cancelled one keeps
	// its checkout (unpushed commits included) for a retry or a person.
	if c.run.ParentRunID == nil && (state == "completed" || c.run.Purpose == runs.PurposeResearch || c.run.Purpose == runs.PurposeWorkflow || c.run.Purpose == runs.PurposeLearning) {
		r.cleanup(context.Background(), c.run.ID) // a delegated run has no workspace of its own
	}
	if c.run.Purpose == runs.PurposeResearch {
		r.advanceResearch(context.Background())
	}
	if c.run.Purpose == runs.PurposeResearch || c.run.Purpose == runs.PurposeLearning {
		r.advanceLearning(context.Background())
	}
	if c.run.Purpose == runs.PurposeWorkflow {
		r.advanceWorkflows(context.Background())
	}
}

func (r *Runner) advanceWorkflows(ctx context.Context) {
	if r.Workflows == nil {
		return
	}
	if err := r.Workflows.AdvanceAll(ctx); err != nil && ctx.Err() == nil {
		r.Log.Warn("advance workflows", "err", err)
	}
}

func (r *Runner) advanceLearning(ctx context.Context) {
	if err := runs.AdvanceLearningCourses(ctx, r.Pool); err != nil && ctx.Err() == nil {
		r.Log.Warn("advance learning", "err", err)
	}
}

// advanceChatTicketRuns tells chats about the runs they started. A ticket
// turn ending is when there's news (a wait on the person, or the end); a chat
// turn ending is when a chat that was busy can hear it.
func (r *Runner) advanceChatTicketRuns(ctx context.Context) {
	if err := runs.AdvanceChatTicketRuns(ctx, r.Pool); err != nil && ctx.Err() == nil {
		r.Log.Warn("advance chat ticket runs", "err", err)
	}
}

func (r *Runner) advanceResearch(ctx context.Context) {
	if err := runs.AdvanceResearchJobs(ctx, r.Pool); err != nil && ctx.Err() == nil {
		r.Log.Warn("advance research", "err", err)
	}
}

// ensureWorkspace creates a run's workspace: in a folder on the person's
// machine when they turned host folders on and this runner has a folder
// configured, otherwise as the backend always has.
func (r *Runner) ensureWorkspace(ctx context.Context, run store.Run) error {
	hf, ok := r.Backend.(HostFolders)
	if !ok || hf.HostWorkspacesDir() == "" {
		return r.Backend.EnsureWorkspace(ctx, run.ID.String())
	}
	on, err := r.q().HostFolderWorkspaces(ctx, run.WorkspaceID)
	if err != nil {
		return err
	}
	if !on {
		return r.Backend.EnsureWorkspace(ctx, run.ID.String())
	}
	folder, err := hf.EnsureHostWorkspace(ctx, run.ID.String())
	if err != nil || folder == "" {
		return err
	}
	return r.q().SetRunWorkspaceHostPath(ctx, store.SetRunWorkspaceHostPathParams{ID: run.ID, WorkspaceHostPath: &folder})
}

// cleanup discards a run's workspace once its work is safe. A failed checkpoint
// keeps the workspace; the sweep tries again.
func (r *Runner) cleanup(ctx context.Context, runID uuid.UUID) {
	if err := r.checkpoint(ctx, runID); err != nil {
		r.Log.Warn("checkpoint before discarding workspace", "run", runID, "err", err)
		return
	}
	r.removeWorktrees(ctx, runID)
	r.stopRunPlaygrounds(ctx, runID)
	if err := r.Backend.RemoveWorkspace(ctx, runID.String()); err != nil {
		r.Log.Warn("remove workspace", "run", runID, "err", err)
		return
	}
	_ = r.q().SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: runID, WorkspaceVolume: nil})
}

// Sweep ends idle chat segments and removes workspaces of runs that ended
// between turns.
func (r *Runner) Sweep(ctx context.Context) {
	defer r.sweepChatAttachments(ctx)
	defer r.sweepPlaygrounds(ctx)
	defer r.sweepTemporaryChats(ctx)
	defer r.sweepChatVideos(ctx)
	defer r.sweepDeckBlobs(ctx)
	defer r.sweepLinkPreviews(ctx)
	defer r.advanceLearning(ctx)
	defer r.advanceResearch(ctx)
	defer r.advanceWorkflows(ctx)
	defer r.advanceChatTicketRuns(ctx)
	defer r.refreshChatSuggestions(ctx, time.Now())
	r.expireIdleChats(ctx)
	ids, err := r.q().EndedRunsWithWorkspace(ctx, append([]uuid.UUID{}, r.otherBackend...))
	if err != nil {
		return
	}
	for _, id := range ids {
		// Only the backend holding a workspace can save and remove it.
		if has, err := r.Backend.HasWorkspace(ctx, id.String()); err == nil && !has {
			r.otherBackend = append(r.otherBackend, id)
			continue
		}
		r.cleanup(ctx, id)
	}
}

// TemporaryChatTTL is how long a temporary chat may sit idle before the sweep
// deletes it.
const TemporaryChatTTL = 24 * time.Hour

// sweepTemporaryChats deletes a batch of temporary chats idle for
// TemporaryChatTTL. Deleting goes through runs.Service so a chat is removed
// exactly as the person deleting it would.
func (r *Runner) sweepTemporaryChats(ctx context.Context) {
	if r.Scheduled == nil {
		return
	}
	cutoff := time.Now().Add(-TemporaryChatTTL)
	rows, err := r.q().ExpiredTemporaryChats(ctx, store.ExpiredTemporaryChatsParams{Cutoff: &cutoff, RowLimit: 50})
	if err != nil {
		r.Log.Warn("sweep temporary chats", "err", err)
		return
	}
	for _, row := range rows {
		if ctx.Err() != nil {
			return
		}
		if _, err := r.Scheduled.DeleteIdleTemporaryChat(ctx, row.WorkspaceID, row.ID, cutoff); err != nil {
			r.Log.Warn("delete temporary chat", "chat", row.ID, "err", err)
		}
	}
}

// StaleChatAttachmentAge is how long an upload may sit unsent (or detached by
// its chat's deletion) before the sweep deletes it and its object.
const StaleChatAttachmentAge = 24 * time.Hour

// sweepChatAttachments deletes a batch of stale uploads: the rows first, so
// one can't be bound to a message after its object is gone. An object whose
// delete fails is logged and left behind.
func (r *Runner) sweepChatAttachments(ctx context.Context) {
	if r.Attachments == nil {
		return
	}
	keys, err := r.q().DeleteStaleChatAttachments(ctx, store.DeleteStaleChatAttachmentsParams{Cutoff: time.Now().Add(-StaleChatAttachmentAge), RowLimit: 200})
	if err != nil {
		r.Log.Warn("sweep chat attachments", "err", err)
		return
	}
	for _, k := range keys {
		if err := r.Attachments.Delete(ctx, r.Cfg.AttachmentBucket, k); err != nil {
			r.Log.Warn("delete chat attachment object", "key", k, "err", err)
		}
	}
}

// sweepChatVideos removes a batch of videos whose chat was deleted, with the
// objects only they held (their frames, and their video unless the Library
// keeps it).
func (r *Runner) sweepChatVideos(ctx context.Context) {
	if r.Attachments == nil {
		return
	}
	keys, err := r.q().DeleteDetachedChatVideoJobs(ctx, 50)
	if err != nil {
		r.Log.Warn("sweep chat videos", "err", err)
		return
	}
	audio, err := r.q().DeleteDetachedChatAudioJobs(ctx, 50)
	if err != nil {
		r.Log.Warn("sweep chat audio", "err", err)
	}
	for _, k := range append(keys, audio...) {
		if err := r.Attachments.Delete(ctx, r.Cfg.AttachmentBucket, k); err != nil {
			r.Log.Warn("delete chat video object", "key", k, "err", err)
		}
	}
}

// sweepDeckBlobs deletes a batch of Slides image blobs no deck uses any more
// (slides.SweepBlobs). A failed delete is logged and retried by a later sweep.
func (r *Runner) sweepDeckBlobs(ctx context.Context) {
	if r.Attachments == nil {
		return
	}
	if _, err := slides.SweepBlobs(ctx, r.Pool, r.Attachments, r.Cfg.AttachmentBucket, time.Now().Add(-slides.BlobSweepDelay), 100); err != nil {
		r.Log.Warn("sweep deck blobs", "err", err)
	}
}

// StaleLinkPreviewAge is how long a fetched preview is kept. A reply opened
// after that just fetches its card again.
const StaleLinkPreviewAge = 90 * 24 * time.Hour

// sweepLinkPreviews retires a batch of old link previews and their images.
func (r *Runner) sweepLinkPreviews(ctx context.Context) {
	if r.Attachments == nil {
		return
	}
	keys, err := r.q().DeleteStaleLinkPreviews(ctx, store.DeleteStaleLinkPreviewsParams{Before: time.Now().Add(-StaleLinkPreviewAge), RowLimit: 100})
	if err != nil {
		r.Log.Warn("sweep link previews", "err", err)
		return
	}
	for _, k := range keys {
		if k == "" {
			continue
		}
		if err := r.Attachments.Delete(ctx, r.Cfg.AttachmentBucket, k); err != nil {
			r.Log.Warn("delete link preview object", "key", k, "err", err)
		}
	}
}

// wsID names the workspace a run executes in: a delegated run uses its
// parent's checkout.
func wsID(run store.Run) string {
	if run.ParentRunID != nil {
		return run.ParentRunID.String()
	}
	return run.ID.String()
}

// childDir is the directory of the parent's workspace a delegated run works
// in (its git worktree); "" for any other run.
func childDir(run store.Run) string {
	if run.ParentRunID == nil {
		return ""
	}
	var contract runs.Contract
	if len(run.Contract) > 0 {
		_ = json.Unmarshal(run.Contract, &contract)
	}
	return contract.Worktree
}

// startChild readies a delegated run. There's no clone or setup: it gets its
// own git worktree and branch in the parent's workspace, cut from the branch
// the parent left committed (or the worktree of the run it continues).
func (r *Runner) startChild(ctx context.Context, c runCtx) {
	run := c.run
	fail := func(msg string) {
		r.Log.Warn("delegated run failed to start", "run", run.ID, "reason", msg)
		r.end(ctx, c, "failed", msg, runs.VerbRunFailed)
	}
	parent, err := r.q().GetRun(ctx, store.GetRunParams{ID: *run.ParentRunID, WorkspaceID: run.WorkspaceID})
	if err != nil || parent.WorkspaceVolume == nil || slices.Contains(runs.Terminal, parent.State) {
		fail("The main agent's workspace is gone, so the delegated run can't start.")
		return
	}
	if err := r.checkSpec(c.spec); err != nil {
		fail(err.Error())
		return
	}
	plan, err := PlanSecrets(ctx, r.q(), run.WorkspaceID, &c.project.ID, c.spec)
	if err != nil {
		fail("Couldn't read secrets: " + err.Error())
		return
	}
	if key, _ := HarnessKey(c.spec); r.Cfg.RequireHarnessKey && !hasSecret(plan, key.Secret) {
		fail(fmt.Sprintf("No %s secret: add an API key in Settings → Connections & secrets.", key.Secret))
		return
	}
	setupStart := time.Now()
	contract, err := r.prepareWorktree(ctx, c, map[string]string{})
	if err != nil {
		fail("Couldn't start the delegated run: " + err.Error())
		return
	}
	rawContract, _ := json.Marshal(contract)
	r.addTiming(run.ID, time.Since(setupStart), 0, 0)
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		cur, err := q.LockRun(ctx, run.ID)
		if err != nil {
			return err
		}
		if cur.State != "starting" {
			return nil // cancelled while queued
		}
		if _, err := q.SetRunContract(ctx, store.SetRunContractParams{ID: run.ID, Contract: rawContract}); err != nil {
			return err
		}
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "running"}); err != nil {
			return err
		}
		b, _ := json.Marshal(map[string]any{"state": "running", "mode": "managed", "parent_run_id": parent.ID, "branch": contract.Branch, "worktree": contract.Worktree})
		if err := q.AddRunEvent(ctx, store.AddRunEventParams{RunID: run.ID, Type: "lifecycle", Payload: b}); err != nil {
			return err
		}
		if err := runnerRecord(ctx, q, run.WorkspaceID, c.ticket.ID, c.ticket.EpicID, tracker.AgentActor(c.agent.ID), runs.VerbRunStarted,
			map[string]any{"run_id": run.ID, "mode": "managed", "harness": c.spec.Harness, "delegated": true}, nil); err != nil {
			return err
		}
		return runs.RecomputeAgentStatus(ctx, q, c.agent.ID)
	})
	if err != nil {
		r.Log.Error("mark delegated run running", "run", run.ID, "err", err)
	}
}

// ---------------------------------------------------------------- start

// start prepares a queued run's workspace and marks it running; its first
// turn (created at dispatch) is picked up by the next Tick.
func (r *Runner) start(ctx context.Context, run store.Run) {
	c, err := r.load(ctx, run.ID)
	if err != nil {
		r.Log.Error("load run", "run", run.ID, "err", err)
		return
	}
	if c.run.ParentRunID != nil {
		r.startChild(ctx, c)
		return
	}
	log := r.Log.With("run", run.ID, "ticket", c.ticket.Key)
	fail := func(msg string) {
		log.Warn("run failed to start", "reason", msg)
		r.end(ctx, c, "failed", msg, runs.VerbRunFailed)
	}
	if c.run.Purpose == "ticket" && c.run.TicketID != nil {
		blockers, err := tracker.DispatchBlockers(ctx, r.q(), c.ticket)
		if err != nil {
			fail("Could not check dependencies: " + err.Error())
			return
		}
		if len(blockers) > 0 {
			fail(strings.Join(blockers, "; "))
			return
		}
	}
	if err := r.checkSpec(c.spec); err != nil {
		fail(err.Error())
		return
	}
	plan, err := PlanSecrets(ctx, r.q(), run.WorkspaceID, &c.project.ID, c.spec)
	if err != nil {
		fail("Couldn't read secrets: " + err.Error())
		return
	}

	if c.run.Purpose == "chat" {
		plan = ChatSecretPlan(plan, c.spec)
	}
	key, _ := HarnessKey(c.spec)
	if r.Cfg.RequireHarnessKey && !hasSecret(plan, key.Secret) {
		fail(fmt.Sprintf("No %s secret: add an API key in Settings → Connections & secrets, then dispatch again.", key.Secret))
		return
	}
	env, err := SecretEnv(ctx, r.Secrets, run.WorkspaceID, &c.project.ID, plan)
	if err != nil {
		fail("Couldn't decrypt secrets: " + err.Error())
		return
	}
	// Setup may clone a private repo even when the agent can only read it.
	if gh := env["GH_TOKEN"]; gh == "" && (allowedScope(c.spec, "repo:read") || allowedScope(c.spec, "repo:write")) {
		if v, err := r.Secrets.Reveal(ctx, run.WorkspaceID, &c.project.ID, "git:pat"); err == nil {
			env["GH_TOKEN"] = v
		}
	}
	// Same for the SSH key: setup clones over SSH even when the agent only reads.
	if env[SSHKeyEnv] == "" && (allowedScope(c.spec, "repo:read") || allowedScope(c.spec, "repo:write")) {
		if v, err := r.Secrets.Reveal(ctx, run.WorkspaceID, &c.project.ID, "git:ssh"); err == nil {
			env[SSHKeyEnv] = v
		}
	}
	if c.run.Purpose == "chat" {
		if !allowedScope(c.spec, "repo:write") {
			ScrubChatGitEnv(env, "")
		}
	}
	setupStart := time.Now()
	checkpoint := ""
	if c.run.Purpose == "ticket" && c.run.TicketID != nil {
		if checkpoint, err = r.recoverTicketWork(ctx, c); err != nil {
			if ctx.Err() != nil {
				return // shutting down: the run goes back to the queue on the next start
			}
			fail("Couldn't save an earlier run's unpushed work, so this run did not start: " + err.Error())
			return
		}
	}
	if c.run.Purpose == "chat" {
		chat, e := r.q().ChatSessionForRun(ctx, &c.run.ID)
		if e != nil {
			fail("Could not find the chat for recovery.")
			return
		}
		previous, e := r.q().PreviousChatWorkspaces(ctx, store.PreviousChatWorkspacesParams{RunID: c.run.ID, ChatID: chat.ID})
		if e != nil {
			fail("Could not find earlier workspaces.")
			return
		}
		for _, old := range previous {
			if e = r.checkpoint(ctx, old.ID); e != nil {
				fail("Could not save an earlier chat workspace: " + e.Error())
				return
			}
		}
	}
	// Recovering earlier work can take minutes; a run cancelled meanwhile must
	// not get a workspace nobody records, so it would never be removed.
	if cur, err := r.q().LockRunNoWait(ctx, run.ID); err != nil || cur.State != "starting" {
		if err != nil {
			log.Error("recheck run before setup", "err", err)
		}
		return
	}
	if err := r.ensureWorkspace(ctx, run); err != nil {
		fail("Couldn't create the workspace: " + err.Error())
		return
	}
	branch := BranchName(c.agent.Handle, c.ticket.Key, c.ticket.Title)
	if c.ticket.Branch != nil && *c.ticket.Branch != "" {
		branch = *c.ticket.Branch
	}
	repo := ""
	if c.run.Purpose == "ticket" && c.run.TicketID != nil && c.project.RepoUrl != nil {
		repo = *c.project.RepoUrl
	}
	base, epic := "", ""
	if c.run.Purpose == "ticket" && c.run.TicketID != nil {
		base = c.project.DefaultBranch
		if c.spec.Repository != nil {
			epic = c.spec.Repository.EpicBranch
		}
	}
	ident, err := runCommitEnv(ctx, r.q(), c)
	if err != nil {
		fail("Couldn't load the commit author: " + err.Error())
		return
	}
	maps.Copy(env, ident)
	script := SetupScriptWithCheckpoint(repo, base, epic, checkpoint, branch, ident["GIT_AUTHOR_NAME"], ident["GIT_AUTHOR_EMAIL"], c.spec.Setup)
	if r.wantsRepoMap(c) {
		script += "\n" + baseCommitScript(base, epic)
	}
	if c.run.Purpose == "chat" {
		if script, err = chatSetupScript(ctx, r.q(), c); err != nil {
			fail("Couldn't prepare the chat workspace: " + err.Error())
			return
		}
	}
	// The repository's test environment: install its tools, or, the first
	// time, report the files a first recipe is inferred from.
	testRepo := testEnvRepo(ctx, r.q(), c)
	recipe, hasRecipe := r.loadTestEnv(ctx, c, testRepo)
	if c.run.Purpose == "chat" {
		script += "\n" + chatSetupCredentialsDone(c) + r.chatTestEnvironmentScript(ctx, c)
	} else {
		script += "\n" + recipe.NixInstallScript()
		if testRepo != "" && !hasRecipe && len(c.spec.Services) == 0 {
			script += testFilesScript()
		}
	}
	r.event(ctx, run.ID, "lifecycle", map[string]any{"state": "starting", "runner": r.Cfg.ID, "backend": r.Backend.Name(), "branch": branch})
	proc, err := r.Backend.Start(ctx, run.ID.String(), ExecSpec{
		Name: "lazyagents-setup-" + run.ID.String(), Argv: []string{"sh", "-c", script}, Env: env,
	})
	if err != nil {
		fail("Couldn't start the workspace setup: " + err.Error())
		return
	}
	stop := r.supervise(ctx, c, proc, ScriptTimeout, nil)
	output, code, err := captureProcess(ctx, proc)
	expired, _ := stop()
	if ctx.Err() != nil {
		return
	}
	if c.run.Purpose == "chat" && r.finishStoppedChatSetup(ctx, c) {
		return
	}
	if expired {
		err = errors.Join(err, errors.New("workspace setup timed out"))
	}
	r.addTiming(run.ID, time.Since(setupStart), 0, 0)
	output, testFiles := takeTestFiles(redact(output, env))
	output, baseCommit, baseRef := takeBaseCommit(output)
	output = r.recordEnvironment(ctx, c, output, err != nil || code != 0)
	tail := lastLines(output, 30)
	if err != nil || code != 0 {
		fail(fmt.Sprintf("Workspace setup failed (exit %d):\n%s", code, tail))
		return
	}
	r.inferTestEnv(ctx, c, testRepo, testFiles)
	if checkpoint != "" && strings.Contains(output, checkpointRecovered) {
		r.event(ctx, run.ID, "lifecycle", map[string]any{"state": "checkpoint_recovered", "branch": checkpoint})
		if repo != "" {
			_ = r.q().MarkCheckpointRecovered(ctx, store.MarkCheckpointRecoveredParams{
				RepoUrl:          repo,
				Branch:           checkpoint,
				RecoveredByRunID: run.ID,
			})
		}
	}
	if c.run.Purpose == "chat" {
		r.recordRecoveredChatCheckpoints(ctx, run.ID, output)
	}
	if baseCommit != "" {
		r.event(ctx, run.ID, "lifecycle", map[string]any{"state": repoMapEvent, "commit": baseCommit, "ref": baseRef})
	}
	r.event(ctx, run.ID, "lifecycle", map[string]any{"state": "workspace_ready", "branch": branch, "log": tail})

	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		var chat store.ChatSession
		if c.run.Purpose == "chat" {
			var err error
			chat, err = lockRunChat(ctx, q, c.run)
			if err != nil {
				return err
			}
		}
		cur, err := q.LockRun(ctx, run.ID)
		if err != nil {
			return err
		}
		if token := executionToken(ctx); token != nil && (cur.ExecutionToken == nil || *cur.ExecutionToken != *token || cur.ExecutionExpiresAt == nil || !cur.ExecutionExpiresAt.After(time.Now())) {
			return errors.New("setup execution lease was lost")
		}
		if c.run.Purpose == "chat" && cur.State == "paused" {
			vol := run.ID.String()
			if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: run.ID, WorkspaceVolume: &vol}); err != nil {
				return err
			}
			if err := idleChat(ctx, q, chat, cur, "idle"); err != nil {
				return err
			}
			return runs.ResumeInterruptedChat(ctx, q, chat.ID, run.ID, nil, 0)
		}
		if cur.State != "starting" {
			return nil // cancelled while setting up
		}
		vol := run.ID.String()
		if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: run.ID, WorkspaceVolume: &vol}); err != nil {
			return err
		}
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "running"}); err != nil {
			return err
		}
		if err := q.SetTicketBranch(ctx, store.SetTicketBranchParams{ID: c.ticket.ID, Branch: &branch}); err != nil {
			return err
		}
		b, _ := json.Marshal(map[string]any{"state": "running", "mode": "managed"})
		if err := q.AddRunEvent(ctx, store.AddRunEventParams{RunID: run.ID, Type: "lifecycle", Payload: b}); err != nil {
			return err
		}
		if err := runnerRecord(ctx, q, run.WorkspaceID, c.ticket.ID, c.ticket.EpicID, tracker.AgentActor(c.agent.ID), runs.VerbRunStarted,
			map[string]any{"run_id": run.ID, "mode": "managed", "harness": c.spec.Harness}, nil); err != nil {
			return err
		}
		return runs.RecomputeAgentStatus(ctx, q, c.agent.ID)
	})
	if err != nil {
		log.Error("mark running", "err", err)
		return
	}
	if c.ticket.Status == "backlog" || c.ticket.Status == "todo" {
		st := "in_progress"
		if _, err := r.Tracker.Update(ctx, run.WorkspaceID, tracker.AgentActor(c.agent.ID), c.ticket.Key, tracker.Patch{Status: &st}); err != nil {
			log.Warn("move ticket", "err", err)
		}
	}
	log.Info("run started", "branch", branch)
}

func hasSecret(plan []SecretDecision, name string) bool {
	for _, d := range plan {
		if d.Name == name && d.Injected {
			return true
		}
	}
	return false
}

func allowedScope(spec agentdef.Resolved, scope string) bool {
	for _, s := range spec.Scopes {
		if s.Scope == scope {
			return s.Mode == agentdef.Allowed
		}
	}
	return false
}

// redact removes secret values from text shown to people.
func redact(s string, env map[string]string) string {
	for _, v := range env {
		if len(v) >= 6 {
			s = strings.ReplaceAll(s, v, "[redacted]")
		}
	}
	return s
}

func lastLines(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}

// ---------------------------------------------------------------- turns

// PlanRolloverInput continues a run that ended its turn for a plan-step rollover.
const PlanRolloverInput = "Continue with the plan."

// IdleNudge resumes a turn that ended without the agent saying what's next.
const IdleNudge = "You ended your turn without calling complete_run, await_human or request_approval. " +
	"If the work is done, call complete_run. If you need a person, call await_human or request_approval. Otherwise, continue."

// sessionBaseline finds the session's running usage totals in the latest of
// turns before seq that recorded them, and reports whether one did.
func sessionBaseline(turns []store.RunTurn, seq int32, harnessName, session string) (harness.Usage, bool) {
	for i := len(turns) - 1; i >= 0; i-- {
		if turns[i].Seq >= seq || len(turns[i].Usage) == 0 {
			continue
		}
		var usage harness.Usage
		if json.Unmarshal(turns[i].Usage, &usage) != nil {
			continue
		}
		var saved map[string]json.RawMessage
		_ = json.Unmarshal(turns[i].Usage, &saved)
		if _, modern := saved["cache_reported_input_tokens"]; !modern && usage.SessionInputTokens > 0 {
			usage.SessionCacheKnown = true // legacy Codex stored explicit cached counters
		}
		if usage.SessionID == session {
			return usage, true
		}
		// Older Codex turns stored cumulative usage without a session marker.
		if harnessName == agentdef.HarnessCodex && usage.SessionID == "" && usage.CostSource != "harness" && usage.InputTokens > 0 {
			return harness.Usage{SessionID: session, SessionInputTokens: usage.InputTokens, SessionOutputTokens: usage.OutputTokens, SessionCachedTokens: usage.CachedTokens, SessionCacheKnown: true}, true
		}
		// Older Claude turns stored the session's total_cost_usd as the turn's cost.
		if harnessName == agentdef.HarnessClaudeCode && usage.SessionID == "" && usage.CostSource == "harness" && usage.CostUSD > 0 {
			return harness.Usage{SessionID: session, SessionCostUSD: usage.CostUSD}, true
		}
	}
	return harness.Usage{}, false
}

func (r *Runner) turn(ctx context.Context, turn store.RunTurn) {
	c, err := r.load(ctx, turn.RunID)
	if err != nil {
		r.Log.Error("load run", "run", turn.RunID, "err", err)
		return
	}
	if c.run.Purpose == "ticket" || c.run.Purpose == "chat" {
		// Once the turn has settled the run's state: see advanceChatTicketRuns.
		defer func() {
			qctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), controlTimeout)
			defer cancel()
			r.advanceChatTicketRuns(qctx)
		}()
	}
	q := r.q()
	log := r.Log.With("run", c.run.ID, "ticket", c.ticket.Key, "turn", turn.Seq)
	if c.run.State != "running" {
		if c.run.Purpose == "chat" && c.run.State == "paused" {
			r.finishChatTurn(ctx, c, turn, harness.Result{}, 130, nil, nil, chatTurnCode{}, chatImages{})
			return
		}
		_ = q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")})
		return
	}

	if c.run.Purpose == "chat" && c.run.WorkspaceVolume != nil {
		// Started on the other backend: nothing of it is here to continue.
		has, err := r.Backend.HasWorkspace(ctx, wsID(c.run))
		if err == nil && !has && r.restartChatSegment(ctx, c, turn, 0, nil) {
			return
		}
	}

	// Ticket/planning budgets accumulate harness time. Chat runtime is per
	// invocation, and long conversations have no cumulative turn limit.
	var maxRuntime time.Duration
	if c.spec.Budget.MaxRuntime != "" {
		maxRuntime, _ = time.ParseDuration(c.spec.Budget.MaxRuntime)
	}
	var used time.Duration
	if c.run.Purpose != "chat" {
		act, err := q.RunActiveSeconds(ctx, c.run.ID)
		if err != nil {
			log.Error("budget", "err", err)
			return
		}
		if mt := c.spec.Budget.MaxTurns; mt > 0 && int(act.Turns) > mt {
			_ = q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")})
			r.end(ctx, c, "cancelled", fmt.Sprintf("Stopped: reached the %d-turn limit.", mt), runs.VerbRunCancelled)
			return
		}
		used = time.Duration(act.Seconds * float64(time.Second))
		if maxRuntime > 0 && used >= maxRuntime {
			_ = q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")})
			r.end(ctx, c, "cancelled", "Stopped: reached the "+c.spec.Budget.MaxRuntime+" runtime limit.", runs.VerbRunCancelled)
			return
		}
	}

	// A plan step asked this run to continue in a fresh session: drop the
	// session before the usage baseline, so this turn is billed from zero.
	// It's recorded once the prompt is built (takePlanStepRollover), so a
	// turn that stops before then rolls over next time instead.
	planRollover := c.run.RolloverRequested
	if planRollover {
		c.run.HarnessSessionID = nil
	}
	// Skip a harness another run already found exhausted instead of burning a failing turn on it.
	handoff, err := r.selectHarness(ctx, &c, turn)
	if err != nil {
		log.Warn("avoid limited harness", "err", err)
	}
	h, err := harness.For(c.spec.Harness)
	if c.spec.Harness == agentdef.HarnessCodex || c.spec.Harness == agentdef.HarnessClaudeCode {
		// Both CLIs report some usage for the whole session when resumed;
		// the parser subtracts the previous turn's session totals.
		baseline := harness.Usage{}
		if c.run.HarnessSessionID != nil {
			turns, err := q.ListTurns(ctx, c.run.ID)
			if err != nil {
				log.Error("load usage baseline", "err", err)
				return
			}
			var ok bool
			baseline, ok = sessionBaseline(turns, turn.Seq, c.spec.Harness, *c.run.HarnessSessionID)
			// A continued delegated run resumes the earlier run's session, whose
			// running totals are in that run's turns.
			var contract runs.Contract
			if !ok && len(c.run.Contract) > 0 && json.Unmarshal(c.run.Contract, &contract) == nil && contract.ContinueRunID != "" {
				if prev, err := uuid.Parse(contract.ContinueRunID); err == nil {
					prevTurns, err := q.ListTurns(ctx, prev)
					if err != nil {
						log.Error("load usage baseline", "err", err)
						return
					}
					baseline, _ = sessionBaseline(prevTurns, math.MaxInt32, c.spec.Harness, *c.run.HarnessSessionID)
				}
			}
		}
		if c.spec.Harness == agentdef.HarnessCodex {
			h = harness.Codex{Prices: r.Cfg.ModelPrices, Baseline: baseline}
		} else {
			h = harness.ClaudeCode{Baseline: baseline}
		}
	}
	if err != nil {
		r.end(ctx, c, "failed", err.Error(), runs.VerbRunFailed)
		return
	}
	plan, err := PlanSecrets(ctx, q, c.run.WorkspaceID, &c.project.ID, c.spec)
	if err != nil {
		if c.run.Purpose == "chat" {
			r.failChat(ctx, c, "Could not load chat credentials.")
			return
		}
		log.Error("secrets", "err", err)
		return
	}
	if c.run.Purpose == "chat" {
		plan = ChatSecretPlan(plan, c.spec)
	}
	env, err := SecretEnv(ctx, r.Secrets, c.run.WorkspaceID, &c.project.ID, plan)
	if err != nil {
		r.end(ctx, c, "failed", "Couldn't decrypt secrets: "+err.Error(), runs.VerbRunFailed)
		return
	}
	if c.run.Purpose == "chat" {
		if !allowedScope(c.spec, "repo:write") {
			ScrubChatGitEnv(env, "")
		}
	}

	if c.run.Purpose == "chat" {
		// A runner that died mid image step left its job running, which would
		// keep granting the step's allowances to this turn.
		if err := q.FailStaleChatImageJobs(ctx, c.run.ID); err != nil {
			log.Warn("stale image jobs", "err", err)
		}
	}
	// A token for this turn only; revoked when the process exits.
	expires := time.Now().Add(24 * time.Hour)
	token, tok, err := agents.IssueToken(ctx, q, c.agent.ID, "run", "run "+c.run.ID.String()[:8]+" turn "+fmt.Sprint(turn.Seq), &c.run.ID, nil, &expires)
	if err != nil {
		if c.run.Purpose == "chat" {
			r.failChat(ctx, c, "Could not issue a chat turn token.")
			return
		}
		log.Error("token", "err", err)
		return
	}
	defer func() {
		qctx, cancel := context.WithTimeout(context.Background(), controlTimeout)
		defer cancel()
		_ = agents.RevokeToken(qctx, q, c.agent.ID, tok.ID)
	}()

	var environment *turnEnvironment
	if c.run.Purpose == "chat" && allowedScope(c.spec, "repo:write") && c.chatRepoAtStart != nil && *c.chatRepoAtStart != "" {
		// A repository without a recipe yet gets one inferred from this
		// setup's output, so only a known recipe's services start alongside it.
		if _, known := r.loadTestEnv(ctx, c, testEnvRepo(ctx, q, c)); known {
			environment = r.startTurnEnvironment(ctx, c, turn)
			defer environment.stop()
		}
		script, err := chatSetupScript(ctx, q, c)
		if err != nil {
			r.failChat(ctx, c, "Could not prepare attached repositories.")
			return
		}
		script += "\n" + chatSetupCredentialsDone(c) + r.chatTestEnvironmentScript(ctx, c)
		output, setupErr := r.runScript(ctx, c.run.ID, "chat-repositories", script, env)
		if err = setupErr; err != nil {
			r.failChat(ctx, c, "Could not prepare attached repositories: "+err.Error())
			return
		}
		_, testFiles := takeTestFiles(output)
		r.inferTestEnv(ctx, c, testEnvRepo(ctx, q, c), testFiles)
		r.recordRecoveredChatCheckpoints(ctx, c.run.ID, output)
	}
	ctxFiles, err := ContextFiles(ctx, q, c.agent, c.ticket, c.spec.Memory)
	if err != nil {
		log.Warn("context files", "err", err)
	}
	if c.run.Purpose == "ticket" && c.run.TicketID != nil {
		// Linked design frames (ADR-designs §3.11); bounded so a slow renderer can't hold the turn.
		dctx, cancel := context.WithTimeout(ctx, designContextTimeout)
		frames, err := DesignFrameFiles(dctx, q, r.Designs, c.ticket)
		cancel()
		if err != nil {
			log.Warn("design frames", "err", err)
		}
		ctxFiles = append(ctxFiles, frames...)
		if m, err := r.repoMapFile(ctx, q, c, env); err != nil {
			log.Warn("repo map", "err", err)
		} else if m != nil {
			ctxFiles = append(ctxFiles, *m)
		}
	}
	if c.run.Purpose == "planning" {
		source, err := PlanningContextFile(ctx, q, c.run)
		if err != nil {
			r.end(ctx, c, "failed", "Could not load planning source: "+err.Error(), runs.VerbRunFailed)
			return
		}
		if source != nil {
			ctxFiles = append(ctxFiles, *source)
		}
		refFiles, err := PlanningRefFiles(ctx, q, c.run)
		if err != nil {
			r.end(ctx, c, "failed", "Could not load the plan's attached context: "+err.Error(), runs.VerbRunFailed)
			return
		}
		ctxFiles = append(ctxFiles, refFiles...)
	}
	prompt := turn.InputMessage
	if handoff != "" {
		prompt = handoff
	}
	if turn.Trigger == "delegation" {
		parked, err := r.parkDelegation(ctx, c.run, turn)
		if err != nil {
			log.Error("park delegation report", "err", err)
			return
		}
		if parked {
			return
		}
		prompt += r.delegationReport(ctx, c, env, int(turn.Seq))
		if planRollover && handoff == "" {
			// The session is already gone: brief the fresh one like a delegation rollover.
			if brief, err := r.rolloverPrompt(ctx, c, turn.Seq, prompt, env); err != nil {
				log.Warn("rollover brief", "err", err)
			} else {
				prompt = brief
			}
		} else if r.shouldRollOver(c) {
			// Continue in a fresh session: everything the main agent needs next
			// is in the run's state, git and the report, and its checkout was
			// clean when its children started.
			brief, err := r.rolloverPrompt(ctx, c, turn.Seq, prompt, env)
			if err != nil {
				log.Warn("rollover brief; resuming the session", "err", err)
			} else if err := q.SetRunSession(ctx, store.SetRunSessionParams{ID: c.run.ID, HarnessSessionID: nil}); err != nil {
				log.Warn("rollover: clear session; resuming it", "err", err)
			} else {
				r.resetContextTokens(ctx, c)
				r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "session_rollover", "reason": "delegation", "context_tokens": c.run.ContextTokens})
				c.run.HarnessSessionID = nil
				prompt = brief
				// The fresh session's usage starts from zero.
				switch c.spec.Harness {
				case agentdef.HarnessCodex:
					h = harness.Codex{Prices: r.Cfg.ModelPrices}
				case agentdef.HarnessClaudeCode:
					h = harness.ClaudeCode{}
				}
			}
		}
	}
	if planRollover {
		if handoff == "" && turn.Trigger != "delegation" {
			if brief, err := r.planStepPrompt(ctx, c, prompt, env); err != nil {
				log.Warn("rollover brief", "err", err)
			} else {
				prompt = brief
			}
		}
		r.takePlanStepRollover(ctx, c)
	}
	if c.run.ParentRunID != nil && turn.Seq == 1 {
		prompt += r.checkoutSection(ctx, c, env)
	}
	var unpackedFiles map[string][]byte // a zip's files: delivered, but not listed in ## Context
	if c.run.Purpose == "chat" {
		// The files this turn's message attached, listed in its prompt.
		refFiles, refPrompt, err := ChatTurnContext(ctx, q, c.run, turn)
		if err != nil {
			r.failChat(ctx, c, "Could not load the message's attached context.")
			return
		}
		ctxFiles = append(ctxFiles, refFiles...)
		prompt += refPrompt
		var attFiles []ContextFile
		var attPrompt string
		attFiles, unpackedFiles, attPrompt, err = r.chatTurnAttachments(ctx, q, turn)
		if err != nil {
			log.Warn("chat attachments", "err", err)
			r.failChat(ctx, c, "Could not load the message's attached files.")
			return
		}
		ctxFiles = append(ctxFiles, attFiles...)
		prompt += attPrompt
		if turn.Trigger == runs.TriggerImageFollowup {
			// The images (and failures) the previous turn's generate_image calls made.
			imgFiles, imgPrompt, err := r.imageFollowup(ctx, q, turn)
			if err != nil {
				log.Warn("image follow-up", "err", err)
				r.failChat(ctx, c, "Could not load the generated images.")
				return
			}
			ctxFiles = append(ctxFiles, imgFiles...)
			prompt += imgPrompt
		}
	}
	// Reference images aren't context files: they stay out of the AGENTS.md list.
	var refFiles map[string][]byte
	if c.run.Purpose == "chat" {
		var refPrompt string
		refFiles, refPrompt = r.chatTurnReferences(ctx, q, c)
		// The image follow-up can't make images, so it doesn't need the hint.
		if turn.Trigger != runs.TriggerImageFollowup {
			prompt += refPrompt
		}
	}
	paths := make([]string, len(ctxFiles))
	files := map[string][]byte{}
	for k, v := range refFiles {
		files[k] = v
	}
	for k, v := range unpackedFiles {
		files[k] = v
	}
	if c.run.Purpose == "chat" {
		// The space's sources; its instructions list them, not ## Context.
		spaceFiles, err := r.spaceSourceFiles(ctx, q, c.run)
		if err != nil {
			log.Warn("space sources", "err", err)
			r.failChat(ctx, c, "Could not load the space's sources.")
			return
		}
		for k, v := range spaceFiles {
			files[k] = v
		}
	}
	for i, f := range ctxFiles {
		paths[i] = f.Path
		files[f.Path] = f.Body
	}
	session := ""
	if c.run.HarnessSessionID != nil {
		session = *c.run.HarnessSessionID
	}
	var inputImages []harness.InlineImage
	var inputPaths []string
	if c.run.Purpose == runs.PurposeWorkflow {
		var imgFiles map[string][]byte
		var failure string
		imgFiles, inputPaths, inputImages, failure = r.workflowTurnImages(ctx, q, c)
		if failure != "" {
			_ = q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")})
			r.end(ctx, c, "failed", failure, runs.VerbRunFailed)
			return
		}
		for k, v := range imgFiles {
			files[k] = v
		}
	}
	dir := childDir(c.run)
	wsDir := r.Backend.WorkspaceDir(wsID(c.run))
	if dir != "" {
		wsDir = path.Join(wsDir, dir)
	}
	cacheDir := ""
	if backend, ok := r.Backend.(CacheBackend); ok {
		cacheDir = backend.DependencyCacheDir()
	}
	section, skills, failMsg, err := agentsSection(ctx, q, c, paths)
	if err != nil {
		r.Log.Warn("agents section", "run", c.run.ID, "err", err)
		r.failChat(ctx, c, failMsg)
		return
	}
	// A chat's feature playbooks reach the harness as skills for this turn
	// only; the run's stored spec keeps the persona's own.
	turnSpec := c.spec
	if len(skills) > 0 {
		turnSpec.Skills = append(slices.Clone(c.spec.Skills), skills...)
	}
	inv, err := h.Invocation(harness.Workspace{
		DependencyCacheDir: cacheDir, Dir: wsDir, MCPURL: r.Cfg.MCPURL, Token: token, TokenEnv: tokenEnv, ContainerSandbox: r.Backend.Isolates(),
	}, harness.Turn{Spec: turnSpec, Prompt: prompt, SessionID: session, Images: inputPaths, InlineImages: inputImages})
	if err != nil {
		r.end(ctx, c, "failed", err.Error(), runs.VerbRunFailed)
		return
	}
	for k, v := range inv.Files {
		files[k] = v
	}
	placed, exclude := harness.InstructionFiles(c.spec.Harness, section)
	for k, v := range placed {
		files[k] = v
	}
	if len(exclude) > 0 {
		files[harness.SkillsExcludeFile] = append(files[harness.SkillsExcludeFile], []byte(strings.Join(exclude, "\n")+"\n")...)
	}
	for k, v := range inv.Env {
		env[k] = v
	}
	// Only secrets and the token are scrubbed from events, not every env
	// value (the ticket key is in env too).
	sensitive := sensitiveEnv(env)
	env["LAZYAGENTS_RUN_ID"] = c.run.ID.String()
	env["LAZYAGENTS_TICKET"] = c.ticket.Key
	if c.run.Purpose != "chat" || allowedScope(c.spec, "repo:write") {
		// After sensitiveEnv: the person's name and email aren't secrets to
		// scrub from the transcript.
		ident, err := runCommitEnv(ctx, q, c)
		if err != nil {
			if c.run.Purpose == "chat" {
				r.failChat(ctx, c, "Could not load the chat's commit author.")
			} else {
				r.end(ctx, c, "failed", "Could not load the commit author: "+err.Error(), runs.VerbRunFailed)
			}
			return
		}
		maps.Copy(env, ident)
	}
	argv := append(append([]string{}, TurnWrapper...), inv.Argv...)

	// A coding chat's turn is reported as what changed since this commit,
	// remembered here rather than in a file the agent could edit.
	codeBase := ""
	var repositoryBases map[string]string
	if c.run.Purpose == "chat" && allowedScope(c.spec, "repo:write") {
		codeBase = r.workspaceBase(ctx, wsID(c.run))
		repositoryBases = r.chatRepositoryBases(ctx, c)
	}
	if environment == nil {
		environment = r.startTurnEnvironment(ctx, c, turn)
		defer environment.stop()
	}
	var networks []string
	if gateEnv, closeGate, gated := r.gateTurn(ctx, c, turn, environment); gated {
		defer closeGate()
		maps.Copy(env, gateEnv)
	} else {
		var failure string
		if networks, failure = environment.wait(env); failure != "" {
			if ctx.Err() != nil {
				return // shutting down: the turn re-runs on the next runner start
			}
			if c.run.Purpose == "chat" {
				r.failChat(ctx, c, failure)
				return
			}
			_ = q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")})
			r.end(ctx, c, "failed", failure, runs.VerbRunFailed)
			return
		}
	}
	networks = append(networks, r.turnPlayground(ctx, c, env, sensitive)...)
	// instruction_bytes and skills feed get_run's efficiency summary: what each
	// harness had to read before its first tool call (LAZYAGENTS-257).
	r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "turn_started", "turn": turn.Seq, "trigger": turn.Trigger,
		"harness": c.spec.Harness, "resume": session != "", "instruction_bytes": len(section), "skills": len(turnSpec.Skills)})
	turnEnv := env
	if c.run.Purpose == "chat" && allowedScope(c.spec, "repo:write") {
		// Pushing waits for the person: the persona asks with request_push.
		turnEnv = withoutPushCredentials(env)
	}
	proc, err := r.Backend.Start(ctx, wsID(c.run), ExecSpec{
		Name: fmt.Sprintf("lazyagents-turn-%s-%d", c.run.ID, turn.Seq), Argv: argv, Env: turnEnv, Dir: dir, Files: files, Networks: networks,
	})
	if err != nil {
		_ = q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")})
		r.end(ctx, c, "failed", "Couldn't start the harness: "+err.Error(), runs.VerbRunFailed)
		return
	}
	// The first turn delivers context files: each counts as one read (§6.5).
	if turn.Trigger == "start" || (c.run.Purpose == "chat" && turn.Seq == 1) {
		now := time.Now()
		if c.run.Purpose == "chat" {
			// Delivered context still counts as a read, but sits just before the turn so
			// it isn't cited as something the assistant looked up (see runs.ChatCitations).
			now = turn.StartedAt.Add(-time.Millisecond)
		}
		for _, f := range ctxFiles {
			if a, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: f.ArtifactID, WorkspaceID: c.run.WorkspaceID, Viewer: pageview.From(ctx).UserID}); err == nil {
				if f.VersionID != nil {
					a.CurrentVersionID = f.VersionID
				}
				_ = artifacts.RecordRead(ctx, q, a, c.agent.ID, &c.run.ID, "", &now)
			}
		}
	}

	harnessStart := time.Now()
	var videos *videoSync
	stopVideos := func() {}
	if c.run.Purpose == "chat" {
		// A coding chat may render videos during the turn; their files are
		// copied while it works so the chat can follow along.
		videos, stopVideos = r.startVideoSync(ctx, c, sensitive)
	}
	reviewCache, stopReview := r.watchCodeReview(ctx, c, sensitive)
	res, raw, code, waitErr := r.watch(ctx, c, proc, h.NewParser(c.spec.Model), sensitive, maxRuntime-used)
	stopReview()
	r.addTiming(c.run.ID, 0, time.Since(harnessStart), 0)
	r.learnTestEnv(ctx, c, proc)
	if videos != nil {
		if ctx.Err() != nil {
			stopVideos() // shutting down: the turn re-runs and its jobs carry on
		} else {
			r.finishVideoSync(ctx, videos, stopVideos)
		}
	}
	// Some CLI failures only reach stderr, without a JSON error event.
	limitMsg := res.Error + " " + res.Final
	if code != 0 && !res.UsageLimited {
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(line, "[stderr] ") && harness.UsageLimit(line) {
				res.UsageLimited = true
				limitMsg = strings.TrimPrefix(line, "[stderr] ")
				break
			}
		}
	}
	if res.UsageLimited {
		r.markProviderLimited(ctx, c, limitMsg)
	}
	r.recordUsage(ctx, c, res.RateLimits)
	if code != 0 && res.Error == "" && (c.run.ParentRunID != nil || c.run.Purpose == "chat") {
		// A session the CLI can't resume is reported on stderr only.
		for _, line := range strings.Split(string(raw), "\n") {
			if strings.HasPrefix(line, "[stderr] ") && sessionGone.MatchString(line) {
				res.Error = strings.TrimPrefix(line, "[stderr] ")
				break
			}
		}
	}
	logKey := r.saveLog(ctx, c.run.ID, turn.Seq, raw)
	if c.run.Purpose == "chat" {
		if ctx.Err() == nil {
			if session != "" && (code != 0 || res.IsError) && sessionGone.MatchString(res.Error) && r.restartChatSegment(ctx, c, turn, code, logKey) {
				return
			}
			var images chatImages
			if c.spec.Harness != agentdef.HarnessCodex && waitErr == nil && code == 0 && !res.IsError && !res.UsageLimited {
				images = r.runChatImageJobs(ctx, c, turn, token)
			}
			if ctx.Err() != nil {
				return // shutting down: the turn re-runs on the next runner start
			}
			changes := r.chatRepositoryCodeChanges(ctx, c, repositoryBases, codeBase, sensitive, res, code, waitErr)
			if allowedScope(c.spec, "repo:write") {
				r.saveCodeReviews(ctx, c, sensitive, false, reviewCache)
				r.stagePushRequests(ctx, c)
			}
			r.finishChatTurn(ctx, c, turn, res, code, waitErr, logKey, chatTurnCode{changes: changes, repositoryBranches: r.chatRepositoryBranches(ctx, c)}, images)
		}
		return
	}
	if ctx.Err() != nil {
		// Shutting down killed the harness: leave the turn claimed so the next
		// runner's Recover re-runs it. Finishing it here would strand the run.
		return
	}
	usage, _ := json.Marshal(res.Usage)
	exit := int32(code)
	if err := q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, ExitCode: &exit, LogKey: logKey, Usage: usage}); err != nil {
		log.Error("finish turn", "err", err)
	}
	if res.Usage != (harness.Usage{}) {
		src := res.Usage.CostSource
		var srcp *string
		if src != "" {
			srcp = &src
		}
		_, usageErr := q.AddRunUsage(ctx, store.AddRunUsageParams{ID: c.run.ID, ToolCalls: int32(res.Usage.ToolCalls),
			InputTokens: res.Usage.InputTokens, OutputTokens: res.Usage.OutputTokens, CostUsdMicros: int64(res.Usage.CostUSD * 1e6), CostSource: srcp})
		if usageErr != nil {
			log.Error("record usage", "err", usageErr)
		}
	}
	r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "turn_ended", "turn": turn.Seq, "exit_code": code})
	if ctx.Err() != nil {
		return // shut down after the turn finished: Recover's resumeStranded continues the run
	}
	if c.run.Purpose == runs.PurposeWorkflow && c.spec.HarnessOptions[agentdef.OptionImageGeneration] == "true" {
		if failure := r.finishWorkflowImageStep(ctx, c, res, code, waitErr, sensitive); failure != "" {
			r.end(ctx, c, "failed", failure, runs.VerbRunFailed)
			return
		}
	}
	r.afterTurn(ctx, c.run.ID, res, limitMsg, code, waitErr)
}

// watch streams a turn's output into events, enforces pause/cancel and the
// runtime guard, and returns what the parser learned.
func (r *Runner) watch(ctx context.Context, c runCtx, proc Process, p harness.Parser, env map[string]string, remaining time.Duration) (harness.Result, []byte, int, error) {
	write := func(wctx context.Context, n int64) {
		qctx, cancel := context.WithTimeout(wctx, controlTimeout)
		defer cancel()
		if err := r.q().SetRunContextTokens(qctx, store.SetRunContextTokensParams{ID: c.run.ID, ContextTokens: n}); err != nil {
			r.Log.Warn("record context tokens", "run", c.run.ID, "err", err)
		}
	}
	cp := &contextParser{Parser: p, write: func(n int64) { write(ctx, n) }}
	res, raw, code, err := r.watchSession(ctx, c, proc, cp, env, remaining, func(s string) {
		qctx, cancel := context.WithTimeout(ctx, controlTimeout)
		defer cancel()
		_ = r.q().SetRunSession(qctx, store.SetRunSessionParams{ID: c.run.ID, HarnessSessionID: &s})
	})
	// At turn end, the final value. A Claude turn that never reached a request
	// (a rejected resume, an early crash) keeps the last known size; a Codex
	// turn writes 0, since its context is unknown.
	if n := res.Usage.ContextTokens; n > 0 || c.spec.Harness == agentdef.HarnessCodex || c.spec.Harness == agentdef.HarnessAntigravity {
		write(context.WithoutCancel(ctx), n)
	}
	return res, raw, code, err
}

// contextWriteEvery bounds how often a streaming turn writes runs.context_tokens.
const contextWriteEvery = 15 * time.Second

// contextParser records the main agent's context size while a turn streams,
// at most once every contextWriteEvery, so MCP handlers can read a recent
// value mid-turn. Line is called from one goroutine only.
type contextParser struct {
	harness.Parser
	write   func(int64)
	last    int64
	written time.Time
}

func (cp *contextParser) Line(b []byte) []harness.Event {
	evs := cp.Parser.Line(b)
	if n := cp.Parser.Result().Usage.ContextTokens; n > 0 && n != cp.last && time.Since(cp.written) >= contextWriteEvery {
		cp.last, cp.written = n, time.Now()
		cp.write(n)
	}
	return evs
}

// watchSession is watch with the choice of what to do when the harness reports
// its session id. The run's own turn records it as the run's resumable
// session; a side step (an image job's Codex) must not.
func (r *Runner) watchSession(ctx context.Context, c runCtx, proc Process, p harness.Parser, env map[string]string, remaining time.Duration, onSession func(string)) (harness.Result, []byte, int, error) {
	readCtx, cancelReads := context.WithCancel(ctx)
	defer cancelReads()
	var raw bytes.Buffer
	var rawMu sync.Mutex
	appendRaw := func(prefix string, b []byte) {
		rawMu.Lock()
		defer rawMu.Unlock()
		if raw.Len() < 64<<20 {
			raw.WriteString(prefix)
			raw.Write(b)
			raw.WriteByte('\n')
		}
	}
	var opening openingLine // written by the stdout reader, read after readers.Wait
	streamErrors := make(chan error, 2)
	var readers sync.WaitGroup
	readers.Add(2)
	go func() {
		defer readers.Done()
		sc := bufio.NewScanner(proc.Stderr())
		sc.Buffer(make([]byte, 64<<10), 4<<20)
		for sc.Scan() {
			appendRaw("[stderr] ", sc.Bytes())
		}
		if err := sc.Err(); err != nil {
			streamErrors <- streamError("stderr", err)
			_, _ = io.Copy(io.Discard, proc.Stderr())
		}
	}()
	go func() {
		defer readers.Done()
		ch := make(chan pendingRunEvent, runEventBatchMaxEvents*2)
		var flusher sync.WaitGroup
		flusher.Add(1)
		go func() {
			defer flusher.Done()
			r.flushRunEvents(readCtx, c.run.ID, ch)
		}()
		defer func() {
			close(ch)
			flusher.Wait()
		}()
		sc := bufio.NewScanner(proc.Stdout())
		sc.Buffer(make([]byte, 256<<10), 32<<20)
		session := ""
		for sc.Scan() {
			line := sc.Bytes()
			appendRaw("", line)
			if readCtx.Err() != nil {
				_, _ = io.Copy(io.Discard, proc.Stdout())
				return
			}
			for _, e := range p.Line(line) {
				payload, b := redactPayload(e.Payload, env)
				opening.see(e.Type, payload)
				select {
				case ch <- pendingRunEvent{typ: e.Type, payload: b}:
				case <-readCtx.Done():
					_, _ = io.Copy(io.Discard, proc.Stdout())
					return
				}
			}
			if s := p.Result().SessionID; s != "" && s != session {
				session = s
				onSession(s)
			}
		}
		if err := sc.Err(); err != nil {
			streamErrors <- streamError("stdout", err)
			_, _ = io.Copy(io.Discard, proc.Stdout())
		}

	}()

	stop := r.supervise(ctx, c, proc, remaining, streamErrors)
	code, err := proc.Wait()
	drainErr := drainProcess(proc, &readers, cancelReads)
	expired, readErr := stop()
	for len(streamErrors) > 0 {
		readErr = errors.Join(readErr, <-streamErrors)
	}
	if expired && c.run.Purpose != "chat" {
		endCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), controlTimeout)
		r.end(endCtx, c, "cancelled", "Stopped: reached the "+c.spec.Budget.MaxRuntime+" runtime limit.", runs.VerbRunCancelled)
		cancel()
	}
	err = errors.Join(err, drainErr, readErr)
	res := p.Result()
	res.Opening = opening.line
	return res, raw.Bytes(), code, err
}

// redactPayload returns an event payload with secrets scrubbed, and its JSON.
// Payloads rarely hold a secret, so the encoding is checked first and reused:
// each streamed event is marshalled once, not twice.
func redactPayload(p map[string]any, env map[string]string) (map[string]any, []byte) {
	b, _ := json.Marshal(p)
	if !containsSecret(b, env) {
		return p, b
	}
	var out map[string]any
	_ = json.Unmarshal([]byte(redact(string(b), env)), &out)
	b, _ = json.Marshal(out)
	return out, b
}

// containsSecret reports whether redact would change b.
func containsSecret(b []byte, env map[string]string) bool {
	for _, v := range env {
		if len(v) >= 6 && bytes.Contains(b, []byte(v)) {
			return true
		}
	}
	return false
}

func (r *Runner) saveLog(ctx context.Context, runID uuid.UUID, seq int32, raw []byte) *string {
	if r.Blobs == nil || len(raw) == 0 {
		return nil
	}
	key := fmt.Sprintf("runs/%s/turn-%03d.jsonl", runID, seq)
	if err := r.Blobs.Put(ctx, r.Cfg.LogBucket, key, bytes.NewReader(raw), int64(len(raw)), "application/x-ndjson"); err != nil {
		r.Log.Warn("save raw log", "run", runID, "err", err)
		return nil
	}
	return &key
}

// afterTurn decides what follows a turn (§6.4):
//   - completed, failed or cancelled: the workspace goes;
//   - waiting or paused: nothing until a person acts (that queues a turn);
//   - still running: the harness failed, or the agent stopped without
//     saying what's next. That gets one nudge, then a person.
func (r *Runner) afterTurn(ctx context.Context, runID uuid.UUID, res harness.Result, limitMsg string, code int, waitErr error) {
	c, err := r.load(ctx, runID)
	if err != nil {
		r.Log.Error("load run", "run", runID, "err", err)
		return
	}
	q := r.q()
	if !res.UsageLimited && c.run.HoldStartedAt != nil {
		if err := q.ClearRunHold(ctx, runID); err != nil {
			r.Log.Warn("clear run hold", "run", runID, "err", err)
		}
		c.run.HoldStartedAt, c.run.HoldAttempts = nil, 0
	}
	switch c.run.State {
	case "completed", "failed", "cancelled":
		if c.run.ParentRunID == nil && c.run.State == "completed" {
			r.cleanup(ctx, runID) // failed and cancelled runs keep their checkout
		}
		return
	case "waiting", "paused":
		_ = q.SetIdleTurns(ctx, store.SetIdleTurnsParams{ID: runID, IdleTurns: 0})
		return
	case "running":
	default:
		return
	}
	pending, err := q.HasPendingTurn(ctx, runID)
	if err != nil || pending {
		return // a person already resumed it (a reply arrived mid-turn)
	}
	if res.UsageLimited && len(c.spec.Fallbacks) > 0 {
		switched, err := r.fallback(ctx, c, res)
		if err != nil {
			r.end(ctx, c, "failed", "Could not switch to fallback: "+err.Error(), runs.VerbRunFailed)
			return
		}
		if switched {
			return
		}
	}
	if res.UsageLimited {
		r.hold(ctx, c, limitMsg)
		return
	}
	if (waitErr != nil || code != 0 || res.IsError) && r.retryFreshSession(ctx, c, res) {
		return
	}
	if waitErr != nil || code != 0 || res.IsError {
		msg := res.Error
		if msg == "" && waitErr != nil {
			msg = waitErr.Error()
		}
		if msg == "" {
			msg = fmt.Sprintf("the harness exited with code %d", code)
		}
		r.end(ctx, c, "failed", "Harness error: "+msg, runs.VerbRunFailed)
		return
	}
	// A researcher reports through its tool, so a clean exit is the end of it.
	if c.run.Purpose == runs.PurposeResearch {
		r.end(ctx, c, "completed", "Research finished.", runs.VerbRunCompleted)
		return
	}
	// So does a course's run; the course checks what arrived.
	if c.run.Purpose == runs.PurposeLearning {
		r.end(ctx, c, "completed", "Course step finished.", runs.VerbRunCompleted)
		return
	}
	// So does a workflow step; the engine checks that it did.
	if c.run.Purpose == runs.PurposeWorkflow {
		r.end(ctx, c, "completed", "Workflow step finished.", runs.VerbRunCompleted)
		return
	}
	// It ended its turn because update_step asked it to: continue in a fresh
	// session (takePlanStepRollover). That isn't an idle stop.
	if c.run.RolloverRequested {
		if _, err := q.StartTurn(ctx, store.StartTurnParams{RunID: runID, Trigger: "resume", InputMessage: PlanRolloverInput}); err != nil {
			r.Log.Error("rollover turn", "run", runID, "err", err)
		}
		return
	}
	if c.run.IdleTurns < 1 {
		err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
			q := store.New(tx)
			if err := q.SetIdleTurns(ctx, store.SetIdleTurnsParams{ID: runID, IdleTurns: c.run.IdleTurns + 1}); err != nil {
				return err
			}
			_, err := q.StartTurn(ctx, store.StartTurnParams{RunID: runID, Trigger: "resume", InputMessage: func() string {
				if c.run.Purpose == "planning" {
					return "You stopped without submitting a draft. Finish this planning run with propose_tickets; do not use complete_run or claim_ticket."
				}
				return IdleNudge
			}()})
			return err
		})
		if err != nil {
			r.Log.Error("nudge", "run", runID, "err", err)
		}
		return
	}
	if c.run.Purpose == "planning" {
		r.end(ctx, c, "failed", "The planner stopped without submitting proposals. Start a new plan to retry.", runs.VerbRunFailed)
		return
	}
	if c.run.ParentRunID != nil {
		// Nobody to hand it to but the main agent, which gets told it didn't finish.
		r.end(ctx, c, "failed", "The sub agent stopped without calling complete_run. Last message: "+lastLines(res.Final, 8), runs.VerbRunFailed)
		return
	}
	// Second idle turn: hand it to a person; an @mention resumes it.
	reason := "The agent stopped without finishing. Reply with @" + c.agent.Handle + " to continue."
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		wait := "human_reply"
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: runID, State: "waiting", WaitReason: &wait}); err != nil {
			return err
		}
		if err := q.SetIdleTurns(ctx, store.SetIdleTurnsParams{ID: runID, IdleTurns: 0}); err != nil {
			return err
		}
		if err := runnerRecord(ctx, q, c.run.WorkspaceID, c.ticket.ID, c.ticket.EpicID, r.system(), runs.VerbWaitingForHuman,
			map[string]any{"run_id": runID, "reason": reason, "last_message": lastLines(res.Final, 8)}, nil); err != nil {
			return err
		}
		return runs.RecomputeAgentStatus(ctx, q, c.agent.ID)
	})
	if err != nil {
		r.Log.Error("hand to person", "run", runID, "err", err)
	}
}

func runnerRecord(ctx context.Context, q *store.Queries, ws, ticket uuid.UUID, epic *uuid.UUID, actor tracker.Actor, verb string, payload map[string]any, at *time.Time) error {
	if ticket == uuid.Nil {
		return nil
	}
	return tracker.Record(ctx, q, ws, ticket, epic, actor, verb, payload, at)
}

// sessionGone matches the CLIs' errors for a session id they can't resume.
var sessionGone = regexp.MustCompile(`(?i)no conversation found|session[^\n]{0,40}(not found|expired|invalid|unknown)|(cannot|could not|couldn't|unable to) (resume|find)[^\n]{0,40}(session|thread|conversation)|thread[^\n]{0,20}not found`)

// retryFreshSession handles a delegated run that continues an earlier run and
// whose first turn failed because the harness could not resume that run's
// session (expired, or lost with a volume): it forgets the session and starts
// the turn again fresh, once. The worktree still holds the earlier work.
// Detection is by error text, so an unrecognised message just fails the run.
func (r *Runner) retryFreshSession(ctx context.Context, c runCtx, res harness.Result) bool {
	var contract runs.Contract
	if c.run.ParentRunID == nil || json.Unmarshal(c.run.Contract, &contract) != nil || !contract.ResumeSession || !sessionGone.MatchString(res.Error) {
		return false
	}
	turns, err := r.q().ListTurns(ctx, c.run.ID)
	if err != nil || len(turns) != 1 {
		return false
	}
	contract.ResumeSession = false
	raw, _ := json.Marshal(contract)
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if err := q.SetRunSession(ctx, store.SetRunSessionParams{ID: c.run.ID, HarnessSessionID: nil}); err != nil {
			return err
		}
		if _, err := q.SetRunContract(ctx, store.SetRunContractParams{ID: c.run.ID, Contract: raw}); err != nil {
			return err
		}
		_, err := q.StartTurn(ctx, store.StartTurnParams{RunID: c.run.ID, Trigger: "resume", InputMessage: turns[0].InputMessage +
			"\n\n(Your earlier conversation could not be resumed, so this is a fresh session. Your earlier work is still in this worktree: check git log and git diff before you start.)"})
		return err
	})
	if err != nil {
		r.Log.Error("fresh session retry", "run", c.run.ID, "err", err)
		return false
	}
	r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "session_reset", "reason": res.Error})
	return true
}

// checkSpec refuses specs the runner cannot execute, before any credential or
// workspace is touched.
func (r *Runner) checkSpec(spec agentdef.Resolved) error {
	if err := spec.Validate(); err != nil {
		return fmt.Errorf("Invalid run definition: %w", err)
	}
	return nil
}

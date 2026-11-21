package runs

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/broker"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// ApprovalOutcome is what request_approval returns to the agent.
type ApprovalOutcome struct {
	Approval    *store.ApprovalRequest
	NotRequired bool // the scope is allowed: go ahead without asking
}

// RequestApproval asks a person before a requires_approval scope (§5.2).
// The run waits; it resumes when someone approves or denies. For brokered
// scopes, detail is exactly what run_gated will execute once approved.
func (s *Service) RequestApproval(ctx context.Context, c Caller, key, scope, summary string, detail map[string]any, risk string) (ApprovalOutcome, error) {
	scope = strings.TrimSpace(scope)
	summary = strings.TrimSpace(summary)
	if summary == "" || len([]rune(summary)) > 300 {
		return ApprovalOutcome{}, apperr.Invalid("action", "describe the exact action in at most 300 characters")
	}
	if detail == nil {
		detail = map[string]any{}
	}
	var out ApprovalOutcome
	err := s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		spec, err := Spec(run)
		if err != nil {
			return err
		}
		switch spec.Mode(scope) {
		case agentdef.Allowed:
			out.NotRequired = true
			return nil
		case agentdef.Denied:
			return apperr.Invalid("scope", "%s is denied for @%s in this project; don't attempt it", scope, c.Agent.Handle)
		}
		if a, ok := broker.For(scope); ok {
			if err := a.Validate(detail); err != nil {
				return apperr.Invalid("detail", "%v", err)
			}
		}
		raw, _ := json.Marshal(detail)
		ap, err := q.CreateApproval(ctx, store.CreateApprovalParams{
			WorkspaceID: run.WorkspaceID, RunID: run.ID, TicketID: &t.ID, AgentID: c.Agent.ID,
			Scope: scope, ActionSummary: summary, ActionDetail: raw, RiskSummary: strings.TrimSpace(risk),
		})
		if err != nil {
			return err
		}
		out.Approval = &ap
		wait := "approval"
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &wait}); err != nil {
			return err
		}
		if err := q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
			return err
		}
		if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "waiting", "reason": "approval", "approval_id": ap.ID, "scope": scope}); err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, agentActor(c), VerbApprovalRequested,
			map[string]any{"approval_id": ap.ID, "scope": scope, "summary": summary}, nil); err != nil {
			return err
		}
		return RecomputeAgentStatus(ctx, q, c.Agent.ID)
	})
	return out, err
}

func (s *Service) poll() time.Duration {
	if s.Poll > 0 {
		return s.Poll
	}
	return 500 * time.Millisecond
}

// MaxWait bounds long-polls below typical MCP tool-call timeouts; agents
// call again on timeout (§5.2).
const MaxWait = 50 * time.Second

// WaitApproval long-polls until a person decides, or the timeout passes.
func (s *Service) WaitApproval(ctx context.Context, c Caller, id uuid.UUID, timeout time.Duration) (store.ApprovalRequest, error) {
	if timeout <= 0 || timeout > MaxWait {
		timeout = MaxWait
	}
	deadline := time.Now().Add(timeout)
	q := store.New(s.Pool)
	for {
		ap, err := q.GetApproval(ctx, store.GetApprovalParams{ID: id, WorkspaceID: c.Agent.WorkspaceID})
		if err != nil || ap.AgentID != c.Agent.ID {
			return ap, apperr.ErrNotFound
		}
		if ap.State != "pending" || time.Now().After(deadline) {
			return ap, nil
		}
		select {
		case <-ctx.Done():
			return ap, ctx.Err()
		case <-time.After(s.poll()):
		}
	}
}

// RunGated executes an approved brokered action server-side, once. The
// agent passes only the approval id: what runs is what the person approved.
func (s *Service) RunGated(ctx context.Context, c Caller, key string, approvalID uuid.UUID) (broker.Result, error) {
	var ap store.ApprovalRequest
	var run store.Run
	var t store.Ticket
	err := s.tx(ctx, func(q *store.Queries) error {
		var err error
		run, t, err = s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		cur, err := q.GetApproval(ctx, store.GetApprovalParams{ID: approvalID, WorkspaceID: run.WorkspaceID})
		if err != nil || cur.RunID != run.ID {
			return apperr.Invalid("approval_id", "no such approval on this run")
		}
		switch {
		case cur.State == "pending":
			return apperr.Conflict("not approved yet; wait for a person")
		case cur.State != "approved":
			return apperr.Conflict("this request was %s", cur.State)
		case cur.ExecutedAt != nil:
			return apperr.Conflict("this approval was already used; request a new one")
		}
		if _, ok := broker.For(cur.Scope); !ok {
			return apperr.Conflict("%s isn't brokered: you have approval, so do it yourself", cur.Scope)
		}
		ap, err = q.ClaimApprovalExecution(ctx, store.ClaimApprovalExecutionParams{ID: approvalID, RunID: run.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("this approval was already used")
		}
		return err
	})
	if err != nil {
		return broker.Result{}, err
	}

	action, _ := broker.For(ap.Scope)
	secret, err := s.Secrets.Reveal(ctx, run.WorkspaceID, &t.ProjectID, action.Secret())
	if err != nil {
		// Nothing ran, so the approval stays usable once a person adds the secret.
		_ = store.New(s.Pool).ReleaseApprovalExecution(ctx, ap.ID)
		return broker.Result{}, apperr.Conflict("the %s secret isn't set (Settings → Connections & secrets); ask a person to add it, then call run_gated again", action.Secret())
	}
	res := action.Run(ctx, secret, broker.DetailMap(ap.ActionDetail))
	// The secret can appear in driver errors (e.g. a DSN); never return it.
	res.Error = strings.ReplaceAll(res.Error, secret, "[secret]")
	raw, _ := json.Marshal(res)
	err = s.tx(ctx, func(q *store.Queries) error {
		if err := q.SetApprovalResult(ctx, store.SetApprovalResultParams{ID: ap.ID, Result: raw}); err != nil {
			return err
		}
		if err := event(ctx, q, run.ID, "tool_result", map[string]any{"tool": "run_gated", "scope": ap.Scope, "ok": res.OK, "summary": res.Summary, "duration_ms": res.DurationMS}); err != nil {
			return err
		}
		return tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, agentActor(c), VerbGatedRan,
			map[string]any{"approval_id": ap.ID, "scope": ap.Scope, "ok": res.OK, "summary": res.Summary, "error": res.Error}, nil)
	})
	return res, err
}

// AwaitHuman ends the turn until a person replies (a comment resumes it).
func (s *Service) AwaitHuman(ctx context.Context, c Caller, key, reason string) error {
	reason = strings.TrimSpace(reason)
	if reason == "" {
		return apperr.Invalid("reason", "say what you need from a person")
	}
	return s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		wait := "human_reply"
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &wait}); err != nil {
			return err
		}
		if err := q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, agentActor(c), VerbWaitingForHuman, map[string]any{"run_id": run.ID, "reason": reason}, nil); err != nil {
			return err
		}
		return RecomputeAgentStatus(ctx, q, c.Agent.ID)
	})
}

// Signal is what an unmanaged session sees while it waits (§5.2).
type Signal struct {
	State      string
	WaitReason string
	Comments   []store.HumanCommentsSinceRow
	Decisions  []store.ApprovalRequest
	// Mockup reviews on the ticket's gate candidates, oldest first.
	MockupReviews []store.MockupReviewsSinceRow
	Cursor        time.Time
}

// AwaitSignal long-polls for anything a person did: a decision, a comment,
// a pause, resume or cancel. Pass the previous Cursor to get only new things.
func (s *Service) AwaitSignal(ctx context.Context, c Caller, key string, since time.Time, timeout time.Duration) (Signal, error) {
	if timeout <= 0 || timeout > MaxWait {
		timeout = MaxWait
	}
	deadline := time.Now().Add(timeout)
	q := store.New(s.Pool)
	for {
		now := time.Now()
		run, t, err := s.Active(ctx, q, c, key)
		if err != nil {
			// A finished run has no Active; report it as such.
			return Signal{State: "ended", Cursor: since}, err
		}
		comments, err := q.HumanCommentsSince(ctx, store.HumanCommentsSinceParams{TicketID: t.ID, CreatedAt: since})
		if err != nil {
			return Signal{}, err
		}
		decided, err := q.DecidedApprovalsSince(ctx, store.DecidedApprovalsSinceParams{RunID: run.ID, DecidedAt: &since})
		if err != nil {
			return Signal{}, err
		}
		reviews, err := q.MockupReviewsSince(ctx, store.MockupReviewsSinceParams{WorkspaceID: t.WorkspaceID, Since: since, TicketID: t.ID, EpicID: t.EpicID})
		if err != nil {
			return Signal{}, err
		}
		// The cursor only advances to timestamps the database wrote. A host
		// clock would drift from Postgres's (Docker Desktop runs it in a VM)
		// and a reply stamped just behind it would be skipped forever.
		cursor := since
		for _, cm := range comments {
			if cm.CreatedAt.After(cursor) {
				cursor = cm.CreatedAt
			}
		}
		for _, ap := range decided {
			if ap.DecidedAt != nil && ap.DecidedAt.After(cursor) {
				cursor = *ap.DecidedAt
			}
		}
		for _, rv := range reviews {
			if rv.ReviewedAt != nil && rv.ReviewedAt.After(cursor) {
				cursor = *rv.ReviewedAt
			}
		}
		sig := Signal{State: run.State, WaitReason: deref(run.WaitReason), Comments: comments, Decisions: decided, MockupReviews: reviews, Cursor: cursor}
		changed := len(comments) > 0 || len(decided) > 0 || len(reviews) > 0 || run.State == "running" || run.State == "cancelled"
		if changed || now.After(deadline) {
			return sig, nil
		}
		select {
		case <-ctx.Done():
			return sig, ctx.Err()
		case <-time.After(s.poll()):
		}
	}
}

// ---------------------------------------------------------------- people

// Decide approves or denies a pending request. Either way the run resumes
// with a new turn carrying the decision (§6.4).
func (s *Service) Decide(ctx context.Context, ws, userID uuid.UUID, approvalID uuid.UUID, approve bool, note string) (store.ApprovalRequest, error) {
	var ap store.ApprovalRequest
	var chatBump *uuid.UUID
	err := s.tx(ctx, func(q *store.Queries) error {
		cur, err := q.LockApproval(ctx, store.LockApprovalParams{ID: approvalID, WorkspaceID: ws})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		} else if err != nil {
			return err
		}
		if cur.State != "pending" {
			return apperr.Conflict("this request was already %s", cur.State)
		}
		if cur.ChatID != nil {
			chat, err := q.GetChatSession(ctx, store.GetChatSessionParams{ID: *cur.ChatID, WorkspaceID: ws})
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && chat.CreatedBy != userID) {
				return apperr.ErrNotFound
			}
			if err != nil {
				return err
			}
			chatBump = &chat.ID
		}
		state, verb := "denied", VerbApprovalDenied
		if approve {
			state, verb = "approved", VerbApprovalApproved
		}
		note = strings.TrimSpace(note)
		ap, err = q.DecideApproval(ctx, store.DecideApprovalParams{ID: cur.ID, State: state, DecidedByUserID: &userID, DecisionNote: note})
		if err != nil {
			return err
		}
		if cur.TicketID == nil {
			return nil
		}
		run, err := q.LockRun(ctx, cur.RunID)
		if err != nil {
			return err
		}
		t, err := q.GetTicketByID(ctx, *cur.TicketID)
		if err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, ws, t.ID, t.EpicID, tracker.UserActor(userID), verb,
			map[string]any{"approval_id": ap.ID, "scope": ap.Scope, "note": note, "summary": ap.ActionSummary}, nil); err != nil {
			return err
		}
		if run.State != "waiting" || deref(run.WaitReason) != "approval" {
			return nil // the run moved on (cancelled, etc.) or is blocked live in CheckTool
		}
		msg := "Approved: " + ap.ActionSummary
		if !approve {
			msg = "Denied: " + ap.ActionSummary + ". Don't attempt it; adjust the plan or ask in a comment."
		}
		if note != "" {
			msg += "\nNote from the reviewer: " + note
		}
		return resume(ctx, q, run, "approval", msg)
	})
	if err == nil && chatBump != nil {
		// Bump after releasing the approval lock so chat_sessions and approval_requests
		// locks never invert with deleteChat (chat_sessions -> approval_requests).
		_, _ = store.New(s.Pool).BumpChatRevision(ctx, *chatBump)
	}
	return ap, err
}

func resume(ctx context.Context, q *store.Queries, run store.Run, trigger, msg string) error {
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "running"}); err != nil {
		return err
	}
	if _, err := q.StartTurn(ctx, store.StartTurnParams{RunID: run.ID, Trigger: trigger, InputMessage: msg}); err != nil {
		return err
	}
	if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "running", "trigger": trigger, "message": msg}); err != nil {
		return err
	}
	return RecomputeAgentStatus(ctx, q, run.AgentID)
}

// SetRunControl handles Pause, Resume and Cancel from people.
// retry dispatches a fresh run for the ticket of a failed or cancelled run, as
// the person pressing Retry on the run log. The ticket's current assignee runs
// it, and the usual dispatch checks apply (blockers queue it).
func (s *Service) retry(ctx context.Context, ws, userID uuid.UUID, run store.Run) (store.Run, error) {
	if run.Purpose != "ticket" || run.TicketID == nil || run.ParentRunID != nil {
		return store.Run{}, apperr.Conflict("only a ticket run can be retried")
	}
	if run.State != "failed" && run.State != "cancelled" {
		return store.Run{}, apperr.Conflict("only a failed or cancelled run can be retried")
	}
	t, err := store.New(s.Pool).GetTicketByID(ctx, *run.TicketID)
	if err != nil {
		return store.Run{}, err
	}
	out, err := s.Dispatch(ctx, ws, userID, []string{t.Key})
	if err != nil {
		return store.Run{}, err
	}
	return out[0], nil
}

func (s *Service) SetRunControl(ctx context.Context, ws, userID, runID uuid.UUID, action string) (store.Run, error) {
	// Chat cancellation is turn-scoped and uses session-before-run lock order.
	run, err := store.New(s.Pool).GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: ws})
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return store.Run{}, apperr.ErrNotFound
		}
		return store.Run{}, err
	}
	if action == "retry" {
		return s.retry(ctx, ws, userID, run)
	}
	if run.Purpose == "chat" {
		if action != "cancel" {
			return store.Run{}, apperr.Conflict("chat runs resume through messages; only cancel is supported")
		}
		chat, err := store.New(s.Pool).ChatSessionForRun(ctx, &runID)
		if err != nil {
			return store.Run{}, err
		}
		if _, err = s.CancelChat(ctx, ws, userID, chat.ID); err != nil {
			return store.Run{}, err
		}
		return store.New(s.Pool).GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: ws})
	}
	var out store.Run
	err = s.tx(ctx, func(q *store.Queries) error {
		run, err := q.LockRun(ctx, runID)
		if err != nil || run.WorkspaceID != ws {
			return apperr.ErrNotFound
		}
		var t store.Ticket
		if run.TicketID != nil {
			t, err = q.GetTicketByID(ctx, *run.TicketID)
			if err != nil {
				return err
			}
		}
		actor := tracker.UserActor(userID)
		switch action {
		case "pause":
			if run.State != "running" && run.State != "waiting" {
				return apperr.Conflict("only a running or waiting run can be paused")
			}
			if run.State == "waiting" && deref(run.WaitReason) == "checks" {
				// It already called complete_run; pausing would lose that.
				return apperr.Conflict("the server is checking this delegated run's result; it finishes on its own (cancel it to stop it)")
			}
			wait := "pause"
			if out, err = q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "paused", WaitReason: &wait}); err != nil {
				return err
			}
			_ = q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](130)})
			if err := runRecord(ctx, q, ws, t.ID, t.EpicID, actor, VerbRunPaused, map[string]any{"run_id": run.ID}, nil); err != nil {
				return err
			}
			return RecomputeAgentStatus(ctx, q, run.AgentID)
		case "resume":
			if run.State == "waiting_for_quota" {
				if err := q.RequestHoldResume(ctx, run.ID); err != nil {
					return err
				}
				if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "quota_resume_requested", "user_id": userID}); err != nil {
					return err
				}
				out, err = q.GetRun(ctx, store.GetRunParams{ID: run.ID, WorkspaceID: ws})
				return err
			}
			if run.State != "paused" {
				return apperr.Conflict("only a paused run can be resumed")
			}
			if err := runRecord(ctx, q, ws, t.ID, t.EpicID, actor, VerbRunResumed, map[string]any{"run_id": run.ID}, nil); err != nil {
				return err
			}
			live, err := q.HasLiveChild(ctx, &run.ID)
			if err != nil {
				return err
			}
			if live {
				wait := "delegation" // the delegated run is still going; its result resumes the parent
				if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &wait}); err != nil {
					return err
				}
				out, err = q.GetRun(ctx, store.GetRunParams{ID: run.ID, WorkspaceID: ws})
				return err
			}
			trigger, msg := "resume", "You were paused; continue."
			if wake, ok, err := delegationWakeMessage(ctx, q, run); err != nil {
				return err
			} else if ok {
				trigger, msg = "delegation", wake
			}
			if err := resume(ctx, q, run, trigger, msg); err != nil {
				return err
			}
			out, err = q.GetRun(ctx, store.GetRunParams{ID: run.ID, WorkspaceID: ws})
			return err
		case "cancel":
			if slices.Contains(Terminal, run.State) {
				return apperr.Conflict("the run already ended")
			}
			// Name who did it: a run cancelled before it started has nothing
			// else to show, and "ended without an outcome" reads as a crash.
			reason := "Cancelled by a person."
			if u, err := q.GetUser(ctx, store.GetUserParams{ID: userID, WorkspaceID: ws}); err == nil && u.Name != "" {
				reason = "Cancelled by " + u.Name + "."
			}
			if run.State == "queued" || run.State == "starting" {
				reason = strings.TrimSuffix(reason, ".") + " before it started."
			}
			if out, err = q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "cancelled", Outcome: &reason}); err != nil {
				return err
			}
			_ = q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](143)})
			if err := q.ExpireRunApprovals(ctx, run.ID); err != nil {
				return err
			}
			if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "cancelled", "reason": reason, "user_id": userID}); err != nil {
				return err
			}
			if err := runRecord(ctx, q, ws, t.ID, t.EpicID, actor, VerbRunCancelled, map[string]any{"run_id": run.ID}, nil); err != nil {
				return err
			}
			if err := CancelChildren(ctx, q, run.ID, "The main agent's run was cancelled."); err != nil {
				return err
			}
			if err := RecomputeAgentStatus(ctx, q, run.AgentID); err != nil {
				return err
			}
			return WakeParent(ctx, q, out, "cancelled", "a person cancelled it")
		}
		return apperr.Invalid("action", "must be pause, resume or cancel")
	})
	return out, err
}

// OnHumanComment resumes a run waiting for a reply when a person mentions
// its agent (§4 comments: "a mention of an assigned agent queues a resume").
func (s *Service) OnHumanComment(ctx context.Context, ws uuid.UUID, ticketKey, body string) error {
	return s.tx(ctx, func(q *store.Queries) error {
		t, err := tracker.Get(ctx, q, ws, ticketKey)
		if err != nil {
			return err
		}
		run, err := q.ActiveRunForTicket(ctx, &t.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil
		} else if err != nil {
			return err
		}
		if run.State == "waiting" && deref(run.WaitReason) == "delegation" {
			// A mention reaches every child of that agent waiting for a human reply.
			kids, err := q.ChildRuns(ctx, &run.ID)
			if err != nil {
				return err
			}
			for _, child := range kids {
				if child.State != "waiting" || deref(child.WaitReason) != "human_reply" {
					continue
				}
				a, err := q.GetAgent(ctx, store.GetAgentParams{ID: child.AgentID, WorkspaceID: ws})
				if err != nil {
					return err
				}
				if !Mentions(body, a.Handle) {
					continue
				}
				child, err = q.LockRun(ctx, child.ID)
				if err != nil {
					return err
				}
				if child.State == "waiting" && deref(child.WaitReason) == "human_reply" {
					if err := resume(ctx, q, child, "comment", body); err != nil {
						return err
					}
				}
			}
			return nil
		}
		if run.State != "waiting" || deref(run.WaitReason) != "human_reply" {
			return nil
		}
		a, err := q.GetAgent(ctx, store.GetAgentParams{ID: run.AgentID, WorkspaceID: ws})
		if err != nil {
			return err
		}
		if !Mentions(body, a.Handle) {
			return nil
		}
		run, err = q.LockRun(ctx, run.ID)
		if err != nil {
			return err
		}
		if run.State != "waiting" || deref(run.WaitReason) != "human_reply" {
			return nil
		}
		return resume(ctx, q, run, "comment", body)
	})
}

// Mentions reports whether text @-mentions handle as a whole word.
func Mentions(text, handle string) bool {
	re := regexp.MustCompile(`(?i)(^|[^\w@])@` + regexp.QuoteMeta(handle) + `\b`)
	return re.MatchString(text)
}

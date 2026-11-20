package runs_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// complete_run's repro fields are a delegated run's, recorded on its contract;
// recheck_review accepts only a lead's merged review with a repro, parks the
// lead and queues its next turn without starting a run.
func TestReproAndRecheckReview(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Poll: 20 * time.Millisecond}
	callerFor := func(a store.Agent, runID uuid.UUID) runs.Caller {
		e := time.Now().Add(time.Hour)
		tok, _, err := agents.IssueToken(ctx, q, a.ID, "run", "", &runID, nil, &e)
		if err != nil {
			t.Fatal(err)
		}
		c, err := agents.ResolveToken(ctx, q, tok)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	out, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	parent := out[0]
	vol := parent.ID.String()
	if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	main := callerFor(atlas, parent.ID)

	if err := svc.CompleteWithRepro(ctx, main, "", "x", "", "in_review", "", runs.Repro{Command: "go test"}); !isInvalid(err) || !strings.Contains(err.Error(), "repro_command") {
		t.Fatalf("lead reported a repro: %v", err)
	}
	if err := svc.CompleteWithRepro(ctx, main, "", "x", "", "in_review", "", runs.Repro{CoversAll: true}); !isInvalid(err) {
		t.Fatalf("covers_all without a command: %v", err)
	}

	d, err := svc.DelegateWithContract(ctx, main, "", "Review it", runs.Contract{AllowedPaths: []string{"*_test.go"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: d.Run.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	sub := callerFor(atlas, d.Run.ID)
	if err := svc.RecheckReview(ctx, sub, "", d.Run.ID.String()); !isConflict(err) {
		t.Fatalf("sub agent rechecked: %v", err)
	}
	if err := svc.CompleteWithRepro(ctx, sub, "", "Found a bug", "details", "", runs.VerdictChangesRequested, runs.Repro{Command: " go test -run TestBug ", CoversAll: true}); err != nil {
		t.Fatal(err)
	}
	if r, _ := q.GetRun(ctx, store.GetRunParams{ID: d.Run.ID, WorkspaceID: ws}); r.State != "waiting" || deref(r.WaitReason) != "checks" {
		t.Fatalf("review run %s/%s, want waiting on checks", r.State, deref(r.WaitReason))
	}
	// Pausing would lose the completion it's waiting to report.
	if _, err := svc.SetRunControl(ctx, ws, me.ID, d.Run.ID, "pause"); !isConflict(err) || !strings.Contains(err.Error(), "checking") {
		t.Fatalf("paused a run waiting on checks: %v", err)
	}
	if err := svc.Complete(ctx, sub, "", "again", "", "", ""); !isConflict(err) || !strings.Contains(err.Error(), "already called complete_run") {
		t.Fatalf("tool call while waiting on checks: %v", err)
	}
	var ct runs.Contract
	// Sent back (say for an uncommitted file), it reports again without
	// repeating its repro: the repro is kept, so its failing tests stay expected.
	if err := pgx.BeginFunc(ctx, pool, func(tx pgx.Tx) error {
		ok, err := runs.BounceChild(ctx, store.New(tx), d.Run.ID, "fix it")
		if err == nil && !ok {
			t.Fatal("bounce refused")
		}
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if err := svc.Complete(ctx, sub, "", "Found a bug", "details", "", runs.VerdictChangesRequested); err != nil {
		t.Fatal(err)
	}
	if r, _ := q.GetRun(ctx, store.GetRunParams{ID: d.Run.ID, WorkspaceID: ws}); r.State != "waiting" || deref(r.WaitReason) != "checks" ||
		json.Unmarshal(r.Contract, &ct) != nil || ct.ReproCommand != "go test -run TestBug" || ct.Bounces != 1 || ct.Verdict != runs.VerdictChangesRequested {
		t.Fatalf("bounced review %s/%s contract %s", r.State, deref(r.WaitReason), r.Contract)
	}
	passChecks(t, pool, d.Run.ID)
	child, _ := q.GetRun(ctx, store.GetRunParams{ID: d.Run.ID, WorkspaceID: ws})
	ct = runs.Contract{}
	if err := json.Unmarshal(child.Contract, &ct); err != nil || ct.ReproCommand != "go test -run TestBug" || !ct.ReproCoversAll || len(ct.AllowedPaths) != 1 {
		t.Fatalf("contract %s %v", child.Contract, err)
	}

	// The parent was woken with a pending delegation turn; the runner would run
	// it and record the checks. Simulate that turn having run.
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status='done', ended_at=now() WHERE run_id=$1", parent.ID); err != nil {
		t.Fatal(err)
	}
	recheck := func(id string) error { return svc.RecheckReview(ctx, callerFor(atlas, parent.ID), "", id) }
	if err := recheck(d.Run.ID.String()); !isInvalid(err) || !strings.Contains(err.Error(), "weren't merged") {
		t.Fatalf("unchecked review: %v", err)
	}
	merged, _ := json.Marshal(runs.Checks{Ran: true, Passed: true, Merged: true, ChildState: "completed", ReproCommand: ct.ReproCommand})
	if err := q.SetRunChecks(ctx, store.SetRunChecksParams{ID: d.Run.ID, Checks: merged}); err != nil {
		t.Fatal(err)
	}
	if err := recheck(uuid.NewString()); !isInvalid(err) {
		t.Fatalf("unknown run: %v", err)
	}
	if err := runs.ReviewClear(ctx, q, parentRun(t, q, ws, parent.ID)); !isConflict(err) {
		t.Fatalf("Done before the recheck: %v", err)
	}
	if err := recheck(d.Run.ID.String()); err != nil {
		t.Fatal(err)
	}
	p := parentRun(t, q, ws, parent.ID)
	turns, _ := q.ListTurns(ctx, parent.ID)
	last := turns[len(turns)-1]
	if p.State != "running" || last.Status != "pending" || last.Trigger != "delegation" || !strings.Contains(last.InputMessage, "go test -run TestBug") {
		t.Fatalf("parent %s, last turn %+v", p.State, last)
	}
	if kids, _ := q.ChildRuns(ctx, &parent.ID); len(kids) != 1 {
		t.Fatalf("recheck started a run: %d children", len(kids))
	}
	var k runs.Checks
	child, _ = q.GetRun(ctx, store.GetRunParams{ID: d.Run.ID, WorkspaceID: ws})
	if err := json.Unmarshal(child.Checks, &k); err != nil || !k.RecheckRequested || !k.Merged {
		t.Fatalf("checks %s", child.Checks)
	}
	// The runner records a passing recheck; then the review no longer blocks Done.
	k.RecheckRequested, k.ReproFixed = false, true
	raw, _ := json.Marshal(k)
	if err := q.SetRunChecks(ctx, store.SetRunChecksParams{ID: d.Run.ID, Checks: raw}); err != nil {
		t.Fatal(err)
	}
	if err := runs.ReviewClear(ctx, q, p); err != nil {
		t.Fatalf("Done after a passing recheck: %v", err)
	}
}

func parentRun(t *testing.T, q *store.Queries, ws, id uuid.UUID) store.Run {
	t.Helper()
	r, err := q.GetRun(context.Background(), store.GetRunParams{ID: id, WorkspaceID: ws})
	if err != nil {
		t.Fatal(err)
	}
	return r
}

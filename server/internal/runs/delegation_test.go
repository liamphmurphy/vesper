package runs_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestDelegationToSubagents(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: &artifacts.Service{Pool: pool}, Poll: 20 * time.Millisecond}
	callerFor := func(a store.Agent, runID *uuid.UUID) runs.Caller {
		kind := "unmanaged"
		var exp *time.Time
		if runID != nil {
			kind = "run"
			e := time.Now().Add(time.Hour)
			exp = &e
		}
		tok, _, err := agents.IssueToken(ctx, q, a.ID, kind, "", runID, nil, exp)
		if err != nil {
			t.Fatal(err)
		}
		c, err := agents.ResolveToken(ctx, q, tok)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}

	st := "PAY-214"
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})

	// A managed run for atlas whose workspace is ready.
	runsOut, err := svc.Dispatch(ctx, ws, me.ID, []string{st})
	if err != nil {
		t.Fatal(err)
	}
	parent := runsOut[0]
	vol := parent.ID.String()
	if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	main := callerFor(atlas, &parent.ID)
	tk, _ := tracker.Get(ctx, q, ws, st)

	if _, err := svc.Delegate(ctx, main, "", "  "); !isInvalid(err) {
		t.Fatalf("empty task: %v", err)
	}

	// The child is a fresh copy of the lead: its persona and its frozen spec.
	d, err := svc.Delegate(ctx, main, "", "Write the migration notes")
	if err != nil {
		t.Fatal(err)
	}
	child := d.Run
	if child.ParentRunID == nil || *child.ParentRunID != parent.ID || child.State != "queued" || *child.TicketID != tk.ID {
		t.Fatalf("child = %+v", child)
	}
	if child.AgentID != atlas.ID || d.Agent.ID != atlas.ID || d.ReadOnly || child.Harness != parent.Harness || child.Model != parent.Model {
		t.Fatalf("child isn't a copy of the lead: %+v (read-only %v)", child, d.ReadOnly)
	}
	parentSpec, _ := runs.Spec(parent)
	childSpec, _ := runs.Spec(child)
	if childSpec.Instructions != parentSpec.Instructions || childSpec.Mode("repo:write") != parentSpec.Mode("repo:write") {
		t.Fatalf("child spec %+v, parent spec %+v", childSpec, parentSpec)
	}
	p, _ := q.GetRun(ctx, store.GetRunParams{ID: parent.ID, WorkspaceID: ws})
	if p.State != "waiting" || deref(p.WaitReason) != "delegation" {
		t.Fatalf("parent = %s/%s", p.State, deref(p.WaitReason))
	}
	if _, err := svc.Delegate(ctx, callerFor(atlas, &parent.ID), "", "again"); !isConflict(err) {
		t.Fatalf("second live delegation: %v", err)
	}
	// The ticket's live run is still the parent's.
	if live, err := q.ActiveRunForTicket(ctx, &tk.ID); err != nil || live.ID != parent.ID {
		t.Fatalf("active run = %v, %v", live.ID, err)
	}
	// The copy can't claim the ticket (its agent holds it through the lead) or delegate.
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: child.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	sub := callerFor(atlas, &child.ID)
	if _, err := svc.Claim(ctx, sub, st); !isConflict(err) {
		t.Fatalf("delegated copy claimed: %v", err)
	}
	if _, err := svc.Delegate(ctx, sub, "", "x"); !isConflict(err) {
		t.Fatalf("delegated copy delegated: %v", err)
	}

	// Finishing reports to the parent and leaves the ticket where it was.
	before, _ := tracker.Get(ctx, q, ws, st)
	if err := svc.Complete(ctx, sub, "", "too long", strings.Repeat("é", 9000), "", ""); !isInvalid(err) || !strings.Contains(err.Error(), "report") {
		t.Fatalf("9,000-rune report: %v", err)
	}
	if err := svc.Complete(ctx, main, "", "not delegated", "a report", "todo", ""); !isInvalid(err) || !strings.Contains(err.Error(), "only a delegated run") {
		t.Fatalf("report from the main agent: %v", err)
	}
	report := strings.Repeat("x", runs.MaxReportRunes-40) + "\n- docs/migrations.md:12 FINDING"
	if err := svc.Complete(ctx, sub, "", "Wrote docs/migrations.md", "  "+report+"\n", "", ""); err != nil {
		t.Fatal(err)
	}
	after, _ := tracker.Get(ctx, q, ws, st)
	if after.Status != before.Status {
		t.Fatalf("ticket moved %s → %s", before.Status, after.Status)
	}
	c, _ := q.GetRun(ctx, store.GetRunParams{ID: child.ID, WorkspaceID: ws})
	p, _ = q.GetRun(ctx, store.GetRunParams{ID: parent.ID, WorkspaceID: ws})
	if c.State != "completed" || p.State != "running" {
		t.Fatalf("child %s, parent %s", c.State, p.State)
	}
	if deref(c.Report) != report {
		t.Fatalf("stored report = %.80q", deref(c.Report))
	}
	turns, _ := q.ListTurns(ctx, parent.ID)
	last := turns[len(turns)-1]
	if last.Trigger != "delegation" || !strings.Contains(last.InputMessage, "Wrote docs/migrations.md") || !strings.Contains(last.InputMessage, "@atlas") {
		t.Fatalf("parent turn = %+v", last)
	}
	if !strings.Contains(last.InputMessage, "Wrote docs/migrations.md\n\n#### Report\n\n"+report) {
		t.Fatalf("wake message lacks the report:\n%.300s", last.InputMessage)
	}

	// Direct work is the default; an explicit policy still requires review.
	if err := runs.ReviewClear(ctx, q, parent); err != nil {
		t.Fatalf("default direct review: %v", err)
	}
	if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=jsonb_set(resolved_spec,'{review_required}','true') WHERE id=$1", parent.ID); err != nil {
		t.Fatal(err)
	}
	parent, _ = q.GetRun(ctx, store.GetRunParams{ID: parent.ID, WorkspaceID: ws})
	// Done needs a reviewer's all clear: none yet, then a rejection, then approval.
	if err := svc.Complete(ctx, main, "", "all good", "", "done", ""); !isConflict(err) {
		t.Fatalf("done without a verdict: %v", err)
	}
	if err := runs.ReviewClear(ctx, q, parent); !isConflict(err) {
		t.Fatalf("clear without a verdict: %v", err)
	}
	if err := q.AddRunEvent(ctx, store.AddRunEventParams{RunID: child.ID, Type: "lifecycle", Payload: []byte(`{"state":"completed","verdict":"` + runs.VerdictChangesRequested + `"}`)}); err != nil {
		t.Fatal(err)
	}
	if err := runs.ReviewClear(ctx, q, parent); !isConflict(err) {
		t.Fatalf("clear after changes requested: %v", err)
	}
	optional := parent
	var optionalSpec map[string]any
	_ = json.Unmarshal(parent.ResolvedSpec, &optionalSpec)
	optionalSpec["review_required"] = false
	optional.ResolvedSpec, _ = json.Marshal(optionalSpec)
	if err := runs.ReviewClear(ctx, q, optional); !isConflict(err) {
		t.Fatalf("optional review ignored a rejection: %v", err)
	}

	if err := q.AddRunEvent(ctx, store.AddRunEventParams{RunID: child.ID, Type: "lifecycle", Payload: []byte(`{"state":"completed","verdict":"` + runs.VerdictApproved + `"}`)}); err != nil {
		t.Fatal(err)
	}
	if err := runs.ReviewClear(ctx, q, parent); err != nil {
		t.Fatalf("clear after approval: %v", err)
	}

	// The runner has consumed (and checked) the previous report before another delegation.
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status='done' WHERE run_id=$1", parent.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE runs SET checks='{"passed":true,"reported_turn":2}' WHERE id=$1`, child.ID); err != nil {
		t.Fatal(err)
	}
	firstWake := last.InputMessage
	if !strings.Contains(firstWake, "The server checks each delegated run") {
		t.Fatalf("first wake lacks the full guidance: %q", firstWake)
	}
	// A failed child tells the parent; cancelling a parent takes its child down.
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	d2, err := svc.Delegate(ctx, callerFor(atlas, &parent.ID), "", "Second task")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.SetRunControl(ctx, ws, me.ID, d2.Run.ID, "cancel"); err != nil {
		t.Fatal(err)
	}
	p, _ = q.GetRun(ctx, store.GetRunParams{ID: parent.ID, WorkspaceID: ws})
	if p.State != "running" {
		t.Fatalf("parent after child cancelled = %s", p.State)
	}
	turns, _ = q.ListTurns(ctx, parent.ID)
	if m := turns[len(turns)-1].InputMessage; !strings.Contains(m, "cancelled") {
		t.Fatalf("parent told %q", m)
	}
	// A later wake carries a one-sentence reminder instead of the full paragraph.
	if m := turns[len(turns)-1].InputMessage; !strings.HasSuffix(m, "Checks and merge results follow, as before.") ||
		strings.Contains(m, "The server checks each delegated run") || len(m) >= len(firstWake) {
		t.Fatalf("second wake %q isn't shorter than the first %q", m, firstWake)
	}
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status='done' WHERE run_id=$1", parent.ID); err != nil {
		t.Fatal(err)
	}
	d3, err := svc.DelegateWithContract(ctx, callerFor(atlas, &parent.ID), "", "Third task",
		runs.Contract{AcceptanceCriteria: []string{"docs updated"}, AllowedPaths: []string{"docs/"}, TestCommand: "make test"})
	if err != nil {
		t.Fatal(err)
	}
	var stored runs.Contract
	if err := json.Unmarshal(d3.Run.Contract, &stored); err != nil || len(stored.AllowedPaths) != 1 || stored.AllowedPaths[0] != "docs/" || stored.TestCommand != "make test" {
		t.Fatalf("contract not stored: %s (%v)", d3.Run.Contract, err)
	}
	if kidTurns, _ := q.ListTurns(ctx, d3.Run.ID); len(kidTurns) != 1 || !strings.Contains(kidTurns[0].InputMessage, "- docs updated") || !strings.Contains(kidTurns[0].InputMessage, "`make test`") {
		t.Fatalf("child prompt %+v", kidTurns)
	}
	if _, err := svc.SetRunControl(ctx, ws, me.ID, parent.ID, "cancel"); err != nil {
		t.Fatal(err)
	}
	c3, _ := q.GetRun(ctx, store.GetRunParams{ID: d3.Run.ID, WorkspaceID: ws})
	if c3.State != "cancelled" {
		t.Fatalf("child of a cancelled parent = %s", c3.State)
	}

	// Three finished delegations under one parent: the first two were followed by a repeat.
	eff, err := q.DelegationEfficiency(ctx, ws)
	if err != nil || len(eff) != 1 || eff[0].AgentID != atlas.ID || eff[0].Delegations != 3 || eff[0].RepairLoops != 2 || eff[0].FirstPass != 0 {
		t.Fatalf("efficiency %+v (%v)", eff, err)
	}

	// A person can retry the cancelled run straight from its log; delegated runs can't be.
	if _, err := svc.SetRunControl(ctx, ws, me.ID, c3.ID, "retry"); !isConflict(err) {
		t.Fatalf("retried a delegated run: %v", err)
	}
	again, err := svc.SetRunControl(ctx, ws, me.ID, parent.ID, "retry")
	if err != nil || again.ID == parent.ID || again.State != "queued" || *again.TicketID != tk.ID {
		t.Fatalf("retry = %+v, %v", again, err)
	}
	if _, err := svc.SetRunControl(ctx, ws, me.ID, parent.ID, "retry"); !isConflict(err) {
		t.Fatalf("second retry while one is live: %v", err)
	}
}

// A read-only copy is refused allowed_paths, runs without repo:write, is told
// it's read-only in its first prompt, and the lead learns it from the delegation.
func TestDelegateReadOnlyCopy(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: &artifacts.Service{Pool: pool}, Poll: 20 * time.Millisecond}
	runsOut, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	parent := runsOut[0]
	vol := parent.ID.String()
	if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	e := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &parent.ID, nil, &e)
	if err != nil {
		t.Fatal(err)
	}
	main, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	if spec, _ := runs.Spec(parent); spec.Mode("repo:write") != agentdef.Allowed {
		t.Fatalf("the lead can't write: %v", spec.Mode("repo:write"))
	}

	_, err = svc.DelegateWithContract(ctx, main, "", "Review the diff", runs.Contract{ReadOnly: true, AllowedPaths: []string{"docs/review.md"}})
	if !isInvalid(err) || !strings.Contains(err.Error(), "the copy can't change files (repo:write is denied)") {
		t.Fatalf("allowed_paths to a read-only copy: %v", err)
	}
	d, err := svc.DelegateWithContract(ctx, main, "", "Review the diff", runs.Contract{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	if !d.ReadOnly {
		t.Fatalf("delegation not marked read-only: %+v", d)
	}
	spec, _ := runs.Spec(d.Run)
	var stored runs.Contract
	if spec.Mode("repo:write") != agentdef.Denied || json.Unmarshal(d.Run.Contract, &stored) != nil || !stored.ReadOnly {
		t.Fatalf("read-only copy: repo:write %v, contract %s", spec.Mode("repo:write"), d.Run.Contract)
	}
	turns, _ := q.ListTurns(ctx, d.Run.ID)
	if len(turns) != 1 || !strings.Contains(turns[0].InputMessage, "You can't change files in this run (repo:write is not allowed)") {
		t.Fatalf("child turns = %+v", turns)
	}
}

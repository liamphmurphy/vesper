package runs_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

const testSVG = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200"><rect width="320" height="200" fill="#fff"/><text x="10" y="20">Checkout</text></svg>`

func TestMockupGateAndReview(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tr := &tracker.Service{Pool: pool}
	svc := &runs.Service{Pool: pool, Tracker: tr, Artifacts: &artifacts.Service{Pool: pool}}
	a, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	tok, _, err := agents.IssueToken(ctx, q, a.ID, "unmanaged", "", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	atlas, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	user := tracker.UserActor(me.ID)

	run, err := svc.Claim(ctx, atlas, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	state := func() (string, string) {
		r, _ := q.GetRun(ctx, store.GetRunParams{ID: run.ID, WorkspaceID: ws})
		w := ""
		if r.WaitReason != nil {
			w = *r.WaitReason
		}
		return r.State, w
	}

	// Not required: drafting a mockup doesn't pause the run.
	out, err := svc.CreateMockup(ctx, atlas, "", "Checkout", testSVG, "", nil)
	if err != nil || out.Waiting || out.Version.Label != "v1" {
		t.Fatalf("create when not required: %+v %v", out, err)
	}
	if s, _ := state(); s != "running" {
		t.Fatalf("state = %s", s)
	}
	mockup := out.Artifact
	if _, err := svc.CreateMockup(ctx, atlas, "", "Bad", `<svg onload="x()"/>`, "", nil); !isInvalid(err) {
		t.Fatalf("unsafe svg: %v", err)
	}

	// Flag the ticket: finishing is blocked until a person approves.
	yes := true
	if _, err := tr.Update(ctx, ws, user, "PAY-214", tracker.Patch{RequiresMockup: &yes}); err != nil {
		t.Fatal(err)
	}
	if err := svc.SetPR(ctx, atlas, "", "https://github.com/acme/ledger/pull/412", false); !isConflict(err) || !strings.Contains(err.Error(), "PAY-214 needs a person-approved UI mockup") {
		t.Fatalf("set_pr: %v", err)
	}
	if err := svc.CheckCriterion(ctx, atlas, "", 1, true); !isConflict(err) {
		t.Fatalf("check_criterion: %v", err)
	}
	if err := svc.CheckCriterion(ctx, atlas, "", 1, false); err != nil {
		t.Fatalf("unticking is allowed: %v", err)
	}
	for _, status := range []string{"in_review", "done"} {
		if err := svc.Complete(ctx, atlas, "", "done", "", status, ""); !isConflict(err) || !strings.Contains(err.Error(), "mockup") {
			t.Fatalf("complete %s: %v", status, err)
		}
	}
	// A revision of a mockup that isn't this ticket's is refused.
	other, _ := svc.Artifacts.Create(ctx, ws, artifacts.Actor{Type: "user", ID: me.ID}, artifacts.NewArtifact{ProjectKey: "PAY", Type: "mockup", Title: "Elsewhere", Content: artifacts.Content{BodyMD: ptr(testSVG)}})
	if _, err := svc.CreateMockup(ctx, atlas, "", "", testSVG, "", &other.ID); !isInvalid(err) {
		t.Fatalf("foreign mockup_id: %v", err)
	}

	// Revising pauses the run until a person reviews.
	out, err = svc.CreateMockup(ctx, atlas, "", "", testSVG+"<!-- r2 -->", "bigger button", &mockup.ID)
	if err != nil || !out.Waiting || out.Version.Label != "v2" {
		t.Fatalf("revise: %+v %v", out, err)
	}
	if s, w := state(); s != "waiting" || w != "mockup_review" {
		t.Fatalf("state = %s/%s", s, w)
	}
	ag, _ := q.GetAgent(ctx, store.GetAgentParams{ID: a.ID, WorkspaceID: ws})
	if ag.Status != "waiting" {
		t.Fatalf("agent status = %s", ag.Status)
	}
	m, _ := q.GetArtifact(ctx, store.GetArtifactParams{ID: mockup.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	v2 := *m.CurrentVersionID

	// Review validation.
	other1, _ := q.GetArtifact(ctx, store.GetArtifactParams{ID: mockup.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	vers, _ := q.ListArtifactVersions(ctx, store.ListArtifactVersionsParams{ArtifactID: other1.ID, Viewer: pageview.From(ctx).UserID})
	v1 := vers[len(vers)-1].ID
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup.ID, v1, "approved", "", nil); !isConflict(err) {
		t.Fatalf("reviewing a stale version: %v", err)
	}
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup.ID, v2, "changes_requested", "  ", nil); !isInvalid(err) {
		t.Fatalf("changes without a note: %v", err)
	}
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup.ID, v2, "maybe", "", nil); !isInvalid(err) {
		t.Fatalf("bad decision: %v", err)
	}
	var note store.Artifact
	if note, err = svc.Artifacts.Create(ctx, ws, artifacts.Actor{Type: "user", ID: me.ID}, artifacts.NewArtifact{ProjectKey: "PAY", Type: "note", Path: "Scratch/x", Content: artifacts.Content{BodyMD: ptr("hi")}}); err != nil {
		t.Fatal(err)
	}
	note, _ = q.GetArtifact(ctx, store.GetArtifactParams{ID: note.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, note.ID, *note.CurrentVersionID, "approved", "", nil); !isInvalid(err) {
		t.Fatalf("non-mockup: %v", err)
	}

	// Changes requested wake the run with the note.
	pins := []artifacts.ReviewPin{{X: 0.5, Y: 0.25, Text: "Here"}}
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup.ID, v2, "changes_requested", "Make the button bigger", pins); err != nil {
		t.Fatal(err)
	}
	if s, _ := state(); s != "running" {
		t.Fatalf("state after changes = %s", s)
	}
	turns, _ := q.ListTurns(ctx, run.ID)
	last := turns[len(turns)-1]
	if !strings.Contains(last.InputMessage, "Changes requested on mockup Checkout v2: Make the button bigger\n\nPinned comments") ||
		!strings.Contains(last.InputMessage, "1. (50%, 25%) Here\n\nRevise it with create_mockup") || !strings.Contains(last.InputMessage, mockup.ID.String()) {
		t.Fatalf("resume message = %q", last.InputMessage)
	}
	g, _ := artifacts.MockupGate(ctx, q, mustTicket(t, q, ws, "PAY-214"))
	if g.Approved || g.Mockups[0].ReviewState != "changes_requested" || g.Mockups[0].ReviewNote != artifacts.GatherReviewNote("Make the button bigger", pins) {
		t.Fatalf("gate = %+v", g)
	}

	// Revise again, then approve (re-deciding a version is allowed).
	if out, err = svc.CreateMockup(ctx, atlas, "", "", testSVG+"<!-- r3 -->", "", &mockup.ID); err != nil || !out.Waiting {
		t.Fatalf("revise 2: %+v %v", out, err)
	}
	m, _ = q.GetArtifact(ctx, store.GetArtifactParams{ID: mockup.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	v3 := *m.CurrentVersionID
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup.ID, v3, "changes_requested", "hmm", nil); err != nil {
		t.Fatal(err)
	}
	if s, _ := state(); s != "running" {
		t.Fatalf("state = %s", s)
	}
	if err := svc.SetPR(ctx, atlas, "", "https://github.com/acme/ledger/pull/412", false); !isConflict(err) {
		t.Fatal("changes_requested must not satisfy the gate")
	}
	if _, err := svc.CreateMockup(ctx, atlas, "", "", testSVG+"<!-- r4 -->", "", &mockup.ID); err != nil {
		t.Fatal(err)
	}
	m, _ = q.GetArtifact(ctx, store.GetArtifactParams{ID: mockup.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup.ID, *m.CurrentVersionID, "approved", "Ship it", nil); err != nil {
		t.Fatal(err)
	}
	if s, _ := state(); s != "running" {
		t.Fatalf("state after approval = %s", s)
	}
	turns, _ = q.ListTurns(ctx, run.ID)
	if msg := turns[len(turns)-1].InputMessage; !strings.Contains(msg, "Mockup approved: Checkout v4") || !strings.Contains(msg, "Ship it") {
		t.Fatalf("resume message = %q", msg)
	}
	if g, _ = artifacts.MockupGate(ctx, q, mustTicket(t, q, ws, "PAY-214")); !g.Approved {
		t.Fatalf("gate = %+v", g)
	}

	// Approved: the agent can finish.
	if err := svc.SetPR(ctx, atlas, "", "https://github.com/acme/ledger/pull/412", false); err != nil {
		t.Fatalf("set_pr after approval: %v", err)
	}
	crit, _ := q.ListCriteria(ctx, mustTicket(t, q, ws, "PAY-214").ID)
	for i := range crit {
		if err := svc.CheckCriterion(ctx, atlas, "", i+1, true); err != nil {
			t.Fatalf("check_criterion after approval: %v", err)
		}
	}
	if err := svc.Complete(ctx, atlas, "", "done", "", "in_review", ""); err != nil {
		t.Fatalf("complete after approval: %v", err)
	}

	// The timeline records requests and decisions.
	tk := mustTicket(t, q, ws, "PAY-214")
	evs, _ := q.ListTicketActivity(ctx, &tk.ID)
	seen := map[string]int{}
	for _, e := range evs {
		seen[e.Verb]++
	}
	if seen[tracker.VerbMockupReviewRequested] != 3 || seen[tracker.VerbMockupApproved] != 1 || seen[tracker.VerbMockupChangesRequested] != 2 || seen[tracker.VerbMockupRequirementChanged] != 1 {
		t.Fatalf("activity verbs = %v", seen)
	}
}

func mustTicket(t *testing.T, q *store.Queries, ws uuid.UUID, key string) store.Ticket {
	t.Helper()
	tk, err := tracker.Get(context.Background(), q, ws, key)
	if err != nil {
		t.Fatal(err)
	}
	return tk
}

func ptr[T any](v T) *T { return &v }

type mockupFixture struct {
	ctx   context.Context
	q     *store.Queries
	me    store.User
	ws    uuid.UUID
	tr    *tracker.Service
	svc   *runs.Service
	atlas runs.Caller
	run   store.Run
}

func newMockupFixture(t *testing.T, key string) *mockupFixture {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	f := &mockupFixture{ctx: ctx, q: store.New(pool)}
	f.me, _ = f.q.GetLocalUser(ctx)
	f.ws = f.me.WorkspaceID
	f.tr = &tracker.Service{Pool: pool}
	f.svc = &runs.Service{Pool: pool, Tracker: f.tr, Artifacts: &artifacts.Service{Pool: pool}}
	a, _ := f.q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: f.ws, Handle: "atlas"})
	tok, _, err := agents.IssueToken(ctx, f.q, a.ID, "unmanaged", "", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if f.atlas, err = agents.ResolveToken(ctx, f.q, tok); err != nil {
		t.Fatal(err)
	}
	if f.run, err = f.svc.Claim(ctx, f.atlas, key); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *mockupFixture) require(t *testing.T, key string) {
	t.Helper()
	yes := true
	if _, err := f.tr.Update(f.ctx, f.ws, tracker.UserActor(f.me.ID), key, tracker.Patch{RequiresMockup: &yes}); err != nil {
		t.Fatal(err)
	}
}

func (f *mockupFixture) runState(t *testing.T) string {
	t.Helper()
	r, _ := f.q.GetRun(f.ctx, store.GetRunParams{ID: f.run.ID, WorkspaceID: f.ws})
	return r.State
}

func TestMockupChildRunNeverWaits(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tr := &tracker.Service{Pool: pool}
	svc := &runs.Service{Pool: pool, Tracker: tr, Artifacts: &artifacts.Service{Pool: pool}}
	yes := true
	if _, err := tr.Update(ctx, ws, tracker.UserActor(me.ID), "PAY-214", tracker.Patch{RequiresMockup: &yes}); err != nil {
		t.Fatal(err)
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	runsOut, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	parent := runsOut[0]
	vol := parent.ID.String()
	_ = q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol})
	_, _ = q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"})
	exp := time.Now().Add(time.Hour)
	caller := func(a store.Agent, runID uuid.UUID) runs.Caller {
		tok, _, err := agents.IssueToken(ctx, q, a.ID, "run", "", &runID, nil, &exp)
		if err != nil {
			t.Fatal(err)
		}
		c, err := agents.ResolveToken(ctx, q, tok)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	d, err := svc.Delegate(ctx, caller(atlas, parent.ID), "", "Draft the screen")
	if err != nil {
		t.Fatal(err)
	}
	_, _ = q.SetRunState(ctx, store.SetRunStateParams{ID: d.Run.ID, State: "running"})
	out, err := svc.CreateMockup(ctx, caller(atlas, d.Run.ID), "", "Screen", testSVG, "", nil)
	if err != nil || out.Waiting || !out.ChildRun {
		t.Fatalf("child create: %+v %v", out, err)
	}
	c, _ := q.GetRun(ctx, store.GetRunParams{ID: d.Run.ID, WorkspaceID: ws})
	if c.State != "running" {
		t.Fatalf("child state = %s", c.State)
	}
}

func TestMockupAgentScopeAndReviewWake(t *testing.T) {
	f := newMockupFixture(t, "PAY-214")
	f.require(t, "PAY-214")
	out, err := f.svc.CreateMockup(f.ctx, f.atlas, "", "Checkout", testSVG, "", nil)
	if err != nil || !out.Waiting {
		t.Fatalf("create: %+v %v", out, err)
	}
	if out.Artifact.EpicID != nil {
		t.Fatalf("an agent's mockup must not be epic-wide: %v", out.Artifact.EpicID)
	}
	// Changes requested wake the run on the attached ticket.
	if _, err := f.svc.ReviewMockup(f.ctx, f.ws, f.me.ID, out.Artifact.ID, out.Version.ID, "changes_requested", "bigger", nil); err != nil {
		t.Fatal(err)
	}
	if s := f.runState(t); s != "running" {
		t.Fatalf("state = %s", s)
	}

	// Unmanaged sessions learn about the decision through await_signal.
	sig, err := f.svc.AwaitSignal(f.ctx, f.atlas, "", time.Time{}, time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if len(sig.MockupReviews) != 1 || sig.MockupReviews[0].ArtifactID != out.Artifact.ID || deref(sig.MockupReviews[0].ReviewState) != "changes_requested" || sig.MockupReviews[0].ReviewNote != "bigger" {
		t.Fatalf("reviews = %+v", sig.MockupReviews)
	}
	again, err := f.svc.AwaitSignal(f.ctx, f.atlas, "", sig.Cursor, time.Millisecond)
	if err != nil || len(again.MockupReviews) != 0 {
		t.Fatalf("cursor didn't advance: %+v %v", again.MockupReviews, err)
	}
}

func TestMockupRequirementClearedReleasesWaiter(t *testing.T) {
	f := newMockupFixture(t, "PAY-214")
	f.require(t, "PAY-214")
	if out, err := f.svc.CreateMockup(f.ctx, f.atlas, "", "Checkout", testSVG, "", nil); err != nil || !out.Waiting {
		t.Fatalf("create: %+v %v", out, err)
	}
	// Still required: nothing to release.
	if err := f.svc.ReleaseMockupWaiters(f.ctx, f.ws, []string{"PAY-214"}, nil, ""); err != nil {
		t.Fatal(err)
	}
	if s := f.runState(t); s != "waiting" {
		t.Fatalf("state = %s", s)
	}
	no := false
	if _, err := f.tr.Update(f.ctx, f.ws, tracker.UserActor(f.me.ID), "PAY-214", tracker.Patch{RequiresMockup: &no}); err != nil {
		t.Fatal(err)
	}
	if err := f.svc.ReleaseMockupWaiters(f.ctx, f.ws, []string{"PAY-214"}, nil, ""); err != nil {
		t.Fatal(err)
	}
	if s := f.runState(t); s != "running" {
		t.Fatalf("state = %s", s)
	}
	turns, _ := f.q.ListTurns(f.ctx, f.run.ID)
	if msg := turns[len(turns)-1].InputMessage; msg != "The mockup requirement was removed; continue." {
		t.Fatalf("message = %q", msg)
	}
}

func TestMockupDetachReleasesWaiter(t *testing.T) {
	f := newMockupFixture(t, "PAY-214")
	f.require(t, "PAY-214")
	out, err := f.svc.CreateMockup(f.ctx, f.atlas, "", "Checkout", testSVG, "", nil)
	if err != nil || !out.Waiting {
		t.Fatalf("create: %+v %v", out, err)
	}
	if err := f.tr.DetachArtifact(f.ctx, f.ws, tracker.UserActor(f.me.ID), "PAY-214", out.Artifact.ID); err != nil {
		t.Fatal(err)
	}
	if err := f.svc.ReleaseMockupWaiters(f.ctx, f.ws, []string{"PAY-214"}, nil, out.Artifact.Title); err != nil {
		t.Fatal(err)
	}
	turns, _ := f.q.ListTurns(f.ctx, f.run.ID)
	if msg := turns[len(turns)-1].InputMessage; msg != "Mockup Checkout was detached from PAY-214; draft a new one with create_mockup." {
		t.Fatalf("message = %q", msg)
	}
}

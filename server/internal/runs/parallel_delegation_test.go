package runs_test

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestPathsOverlap(t *testing.T) {
	for _, c := range []struct {
		a, b    []string
		overlap bool
	}{
		{[]string{"docs/"}, []string{"src/"}, false},
		{[]string{"docs/"}, []string{"docs/"}, true},
		{[]string{"docs"}, []string{"docs/guide.md"}, true},
		{[]string{"docs/guide.md"}, []string{"docs/"}, true},
		{[]string{"docs/a.md"}, []string{"docs/b.md"}, false},
		{[]string{"go.mod"}, []string{"docs/", "internal/"}, false},
		{[]string{"docs-extra/"}, []string{"docs/"}, false},
		{[]string{"docs/*.md"}, []string{"src/"}, false},
		{[]string{"docs/*.md"}, []string{"docs/x.go"}, true},
		{[]string{"*.md"}, []string{"src/"}, true},
		{[]string{"**/*.go"}, []string{"src/"}, true},
		{[]string{"src/"}, []string{"[a-z]*"}, true},
		{[]string{"a/", "b/"}, []string{"c/", "b/x"}, true},
	} {
		if got := runs.PathsOverlap(c.a, c.b); got != c.overlap || runs.PathsOverlap(c.b, c.a) != c.overlap {
			t.Errorf("PathsOverlap(%v, %v) = %v, want %v", c.a, c.b, got, c.overlap)
		}
	}
}

func TestParallelDelegationRulesAndWake(t *testing.T) {
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
		exp := time.Now().Add(time.Hour)
		tok, _, err := agents.IssueToken(ctx, q, a.ID, "run", "", runID, nil, &exp)
		if err != nil {
			t.Fatal(err)
		}
		c, err := agents.ResolveToken(ctx, q, tok)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
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
	main := callerFor(atlas, &parent.ID)
	delegate := func(task string, c runs.Contract) (runs.Delegation, error) {
		return svc.DelegateWithContract(ctx, main, "", task, c)
	}
	state := func(id uuid.UUID) store.Run {
		r, err := q.GetRun(ctx, store.GetRunParams{ID: id, WorkspaceID: ws})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}

	// First delegation, with paths, parks the parent.
	d1, err := delegate("docs", runs.Contract{AllowedPaths: []string{"docs/"}})
	if err != nil {
		t.Fatal(err)
	}
	if p := state(parent.ID); p.State != "waiting" {
		t.Fatalf("parent %s", p.State)
	}
	// A parked parent whose process has gone can't delegate again...
	if _, err := delegate("x", runs.Contract{AllowedPaths: []string{"src/"}}); !isConflict(err) {
		t.Fatalf("delegated from a parked parent with no live turn: %v", err)
	}
	// ...but within the same turn (process still running) it can.
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status = 'running' WHERE run_id = $1", parent.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := delegate("no paths", runs.Contract{}); err == nil || !strings.Contains(err.Error(), "allowed_paths") {
		t.Fatalf("concurrent child without allowed_paths: %v", err)
	}
	for _, overlap := range []string{"docs/guide.md", "docs", "*.md", "docs/*.md"} {
		if _, err := delegate("overlap", runs.Contract{AllowedPaths: []string{overlap}}); !isConflict(err) || !strings.Contains(err.Error(), "overlap") {
			t.Fatalf("overlapping %q: %v", overlap, err)
		}
	}
	d2, err := delegate("src", runs.Contract{AllowedPaths: []string{"src/"}, TestCommand: "go test ./..."})
	if err != nil {
		t.Fatal(err)
	}
	if p := state(parent.ID); p.State != "waiting" || deref(p.WaitReason) != "delegation" {
		t.Fatalf("parent %s/%s", p.State, deref(p.WaitReason))
	}
	d3, err := delegate("third", runs.Contract{AllowedPaths: []string{"web/"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := delegate("fourth", runs.Contract{AllowedPaths: []string{"api/"}}); !isConflict(err) || !strings.Contains(err.Error(), "limit") {
		t.Fatalf("4th concurrent child: %v", err)
	}

	// The parent stays parked until the last child ends, then resumes once.
	finish := func(d runs.Delegation, a store.Agent, outcome string, report ...string) {
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: d.Run.ID, State: "running"}); err != nil {
			t.Fatal(err)
		}
		if err := svc.Complete(ctx, callerFor(a, &d.Run.ID), "", outcome, strings.Join(report, ""), "", ""); err != nil {
			t.Fatal(err)
		}
		if r := state(d.Run.ID); r.State != "waiting" || deref(r.WaitReason) != "checks" {
			t.Fatalf("child with a contract %s/%s, want waiting on checks", r.State, deref(r.WaitReason))
		}
		passChecks(t, pool, d.Run.ID)
	}
	finish(d1, atlas, "docs done", "- docs/guide.md:3 DOCS-FINDING")
	finish(d3, atlas, "web done")
	if p := state(parent.ID); p.State != "waiting" {
		t.Fatalf("parent resumed with a child still live: %s", p.State)
	}
	finish(d2, atlas, "tests done", "- src/a.go:9 SRC-FINDING")
	if p := state(parent.ID); p.State != "running" {
		t.Fatalf("parent after all children: %s", p.State)
	}
	turns, _ := q.ListTurns(ctx, parent.ID)
	var wakes []store.RunTurn
	for _, tn := range turns {
		if tn.Trigger == "delegation" {
			wakes = append(wakes, tn)
		}
	}
	if len(wakes) != 1 {
		t.Fatalf("parent got %d delegation turns", len(wakes))
	}
	for _, want := range []string{"3 delegated runs have ended", "docs done", "web done", "tests done", "@atlas", "continue_run_id"} {
		if !strings.Contains(wakes[0].InputMessage, want) {
			t.Errorf("resume message lacks %q:\n%s", want, wakes[0].InputMessage)
		}
	}

	// Each report sits under its own child's heading; a child without one gets no Report section.
	sections := strings.Split(wakes[0].InputMessage, "\n\n### ")
	for outcome, want := range map[string]string{"docs done": "DOCS-FINDING", "tests done": "SRC-FINDING", "web done": ""} {
		var sec string
		for _, s := range sections {
			if strings.Contains(s, outcome) {
				sec = s
			}
		}
		n := strings.Count(sec, "#### Report")
		if want == "" && n != 0 || want != "" && (n != 1 || !strings.Contains(sec, "#### Report\n\n- ") || !strings.Contains(sec, want)) {
			t.Errorf("section for %q (want %q):\n%s", outcome, want, sec)
		}
	}

	// Simulate the runner consuming the delegation report.
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status = 'done' WHERE run_id = $1", parent.ID); err != nil {
		t.Fatal(err)
	}
	// continue_run_id: only a finished run of this parent that got a worktree.
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	cont := func(id string) error {
		_, err := delegate("fix it", runs.Contract{ContinueRunID: id})
		return err
	}
	for name, id := range map[string]string{
		"not a uuid":    "nope",
		"unknown run":   uuid.NewString(),
		"never started": d1.Run.ID.String(),
		"the parent":    parent.ID.String(),
	} {
		err := cont(id)
		if err == nil || isConflict(err) || !strings.Contains(err.Error(), "continue_run_id") {
			t.Errorf("%s: %v", name, err)
		}
	}
	if _, err := delegate("unchecked", runs.Contract{ContinueRunID: d1.Run.ID.String()}); err == nil || !strings.Contains(err.Error(), "hasn't been checked") {
		t.Fatalf("unchecked continuation: %v", err)
	}
	// Checked when it completed but not yet reported to the parent: still not continuable.
	if err := q.SetRunChecks(ctx, store.SetRunChecksParams{ID: d1.Run.ID, Checks: []byte(`{"ran":true}`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := delegate("unreported", runs.Contract{ContinueRunID: d1.Run.ID.String()}); err == nil || !strings.Contains(err.Error(), "hasn't been checked") {
		t.Fatalf("unreported continuation: %v", err)
	}
	if err := q.SetRunChecks(ctx, store.SetRunChecksParams{ID: d1.Run.ID, Checks: []byte(`{"ran":true,"reported_turn":2}`)}); err != nil {
		t.Fatal(err)
	}
	// Give d1 a worktree, a branch and a session, as the runner would.
	raw, _ := json.Marshal(runs.Contract{AllowedPaths: []string{"docs/"}, Branch: "atlas/pay-214--scribe-abc", Worktree: ".lazyagents/worktrees/" + d1.Run.ID.String()})
	if _, err := q.SetRunContract(ctx, store.SetRunContractParams{ID: d1.Run.ID, Contract: raw}); err != nil {
		t.Fatal(err)
	}
	sid := "session-1"
	if err := q.SetRunSession(ctx, store.SetRunSessionParams{ID: d1.Run.ID, HarnessSessionID: &sid}); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status='running' WHERE run_id=$1 AND seq=1", parent.ID); err != nil {
		t.Fatal(err)
	}
	d4, err := delegate("fix docs", runs.Contract{ContinueRunID: d1.Run.ID.String(), AllowedPaths: []string{"docs/"}})
	if err != nil {
		t.Fatal(err)
	}
	var c4 runs.Contract
	if err := json.Unmarshal(d4.Run.Contract, &c4); err != nil || c4.Worktree == "" || c4.Branch != "atlas/pay-214--scribe-abc" || c4.ContinueRunID != d1.Run.ID.String() || !c4.ResumeSession {
		t.Fatalf("continued contract %s (%v)", d4.Run.Contract, err)
	}
	if got := state(d4.Run.ID); deref(got.HarnessSessionID) != sid || got.ParentRunID == nil || *got.ParentRunID != parent.ID || got.ID == d1.Run.ID {
		t.Fatalf("continued run %+v", got)
	}
	// The same worktree can't be continued twice, nor while the continuation runs.
	if err := cont(d1.Run.ID.String()); err == nil || !strings.Contains(err.Error(), "continue_run_id") {
		t.Fatalf("second continuation of one run: %v", err)
	}
	if err := cont(d4.Run.ID.String()); err == nil || !strings.Contains(err.Error(), "still in progress") {
		t.Fatalf("continuing a live run: %v", err)
	}
	// A different harness starts fresh: no session is copied.
	finish(d4, atlas, "fixed")
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status = 'done' WHERE run_id = $1", parent.ID); err != nil {
		t.Fatal(err)
	}
	if err := q.SetRunChecks(ctx, store.SetRunChecksParams{ID: d4.Run.ID, Checks: []byte(`{"ran":true,"reported_turn":3}`)}); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "UPDATE runs SET harness = 'codex' WHERE id = $1", d4.Run.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	d5, err := delegate("again", runs.Contract{ContinueRunID: d4.Run.ID.String(), AllowedPaths: []string{"docs/"}})
	if err != nil {
		t.Fatal(err)
	}
	var c5 runs.Contract
	if err := json.Unmarshal(d5.Run.Contract, &c5); err != nil || c5.ResumeSession || c5.Worktree != c4.Worktree || state(d5.Run.ID).HarnessSessionID != nil {
		t.Fatalf("contract %s (%v)", d5.Run.Contract, err)
	}
}

func TestParallelDelegationLifecycle(t *testing.T) {
	for _, scenario := range []string{"concurrent wake", "paused resume", "two child reply", "all matching replies", "pending report", "cancel during delegation"} {
		t.Run(scenario, func(t *testing.T) {
			pool := testdb.New(t)
			ctx := context.Background()
			if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
				t.Fatal(err)
			}
			q := store.New(pool)
			me, _ := q.GetLocalUser(ctx)
			svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: &artifacts.Service{Pool: pool}}
			caller := func(a store.Agent, id uuid.UUID) runs.Caller {
				exp := time.Now().Add(time.Hour)
				tok, _, err := agents.IssueToken(ctx, q, a.ID, "run", "", &id, nil, &exp)
				if err != nil {
					t.Fatal(err)
				}
				c, err := agents.ResolveToken(ctx, q, tok)
				if err != nil {
					t.Fatal(err)
				}
				return c
			}
			atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: me.WorkspaceID, Handle: "atlas"})
			dispatched, err := svc.Dispatch(ctx, me.WorkspaceID, me.ID, []string{"PAY-214"})
			if err != nil {
				t.Fatal(err)
			}
			parent := dispatched[0]
			vol := parent.ID.String()
			if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol}); err != nil {
				t.Fatal(err)
			}
			if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
				t.Fatal(err)
			}
			main := caller(atlas, parent.ID)
			if scenario == "cancel during delegation" {
				tx, err := pool.Begin(ctx)
				if err != nil {
					t.Fatal(err)
				}
				defer tx.Rollback(ctx)
				tq := store.New(tx)
				if _, err := tq.LockRun(ctx, parent.ID); err != nil {
					t.Fatal(err)
				}
				done := make(chan error, 1)
				go func() { _, err := svc.Delegate(ctx, main, "", "docs"); done <- err }()
				deadline := time.Now().Add(5 * time.Second)
				for {
					var blocked bool
					if err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND wait_event_type='Lock')`).Scan(&blocked); err != nil {
						t.Fatal(err)
					}
					if blocked {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("delegate never waited on parent lock")
					}
					time.Sleep(10 * time.Millisecond)
				}
				if _, err := tq.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "cancelled"}); err != nil {
					t.Fatal(err)
				}
				if err := tx.Commit(ctx); err != nil {
					t.Fatal(err)
				}
				if err := <-done; !isConflict(err) || !strings.Contains(err.Error(), "no longer running") {
					t.Fatalf("delegate after cancellation: %v", err)
				}
				kids, err := q.ChildRuns(ctx, &parent.ID)
				if err != nil || len(kids) != 0 {
					t.Fatalf("children after cancellation %v: %v", kids, err)
				}
				return
			}
			d1, err := svc.DelegateWithContract(ctx, main, "", "docs", runs.Contract{AllowedPaths: []string{"docs/"}})
			if err != nil {
				t.Fatal(err)
			}
			if _, err := pool.Exec(ctx, "UPDATE run_turns SET status='running' WHERE run_id=$1", parent.ID); err != nil {
				t.Fatal(err)
			}
			d2, err := svc.DelegateWithContract(ctx, main, "", "src", runs.Contract{AllowedPaths: []string{"src/"}})
			if err != nil {
				t.Fatal(err)
			}
			c1, c2 := caller(atlas, d1.Run.ID), caller(atlas, d2.Run.ID)
			for _, id := range []uuid.UUID{d1.Run.ID, d2.Run.ID} {
				if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: id, State: "running"}); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "two child reply" || scenario == "all matching replies" {
				if err := svc.AwaitHuman(ctx, c1, "", "Which docs?"); err != nil {
					t.Fatal(err)
				}
				if scenario == "all matching replies" {
					if err := svc.AwaitHuman(ctx, c2, "", "Which source?"); err != nil {
						t.Fatal(err)
					}
				}
				if err := svc.OnHumanComment(ctx, me.WorkspaceID, "PAY-214", "@nobody hello"); err != nil {
					t.Fatal(err)
				}
				r, _ := q.GetRun(ctx, store.GetRunParams{ID: d1.Run.ID, WorkspaceID: me.WorkspaceID})
				if r.State != "waiting" {
					t.Fatalf("unmatched reply resumed child: %s", r.State)
				}
				if err := svc.OnHumanComment(ctx, me.WorkspaceID, "PAY-214", "@atlas the guide"); err != nil {
					t.Fatal(err)
				}
				turns, _ := q.ListTurns(ctx, d1.Run.ID)
				if len(turns) != 2 || turns[1].Trigger != "comment" || turns[1].Status != "pending" {
					t.Fatalf("reply turns %+v", turns)
				}
				turns, _ = q.ListTurns(ctx, d2.Run.ID)
				if scenario == "all matching replies" {
					if len(turns) != 2 || turns[1].Trigger != "comment" {
						t.Fatalf("second matching child missed reply: %+v", turns)
					}
				} else if len(turns) != 1 {
					t.Fatalf("other child got reply: %+v", turns)
				}
				return
			}
			if scenario == "paused resume" {
				if _, err := svc.SetRunControl(ctx, me.WorkspaceID, me.ID, parent.ID, "pause"); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "concurrent wake" {
				barrier := make(chan struct{})
				errs := make(chan error, 2)
				for _, c := range []runs.Caller{c1, c2} {
					go func(c runs.Caller) { <-barrier; errs <- svc.Complete(ctx, c, "", "done", "", "", "") }(c)
				}
				close(barrier)
				for i := 0; i < 2; i++ {
					if err := <-errs; err != nil {
						t.Fatal(err)
					}
				}
				// Both pass their checks at once: still one wake.
				barrier = make(chan struct{})
				for _, id := range []uuid.UUID{d1.Run.ID, d2.Run.ID} {
					go func(id uuid.UUID) { <-barrier; errs <- finishChecked(pool, id) }(id)
				}
				close(barrier)
				for i := 0; i < 2; i++ {
					if err := <-errs; err != nil {
						t.Fatal(err)
					}
				}
			} else {
				if err := svc.Complete(ctx, c1, "", "docs done", "", "", ""); err != nil {
					t.Fatal(err)
				}
				if err := svc.Complete(ctx, c2, "", "src done", "", "", ""); err != nil {
					t.Fatal(err)
				}
				passChecks(t, pool, d1.Run.ID, d2.Run.ID)
			}
			if scenario == "paused resume" {
				if _, err := svc.SetRunControl(ctx, me.WorkspaceID, me.ID, parent.ID, "resume"); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "pending report" {
				if _, err := svc.Delegate(ctx, main, "", "again"); !isConflict(err) || !strings.Contains(err.Error(), "end your turn") {
					t.Fatalf("delegate before report: %v", err)
				}
			}
			turns, err := q.ListTurns(ctx, parent.ID)
			if err != nil {
				t.Fatal(err)
			}
			count := 0
			for _, turn := range turns {
				if turn.Trigger == "delegation" {
					count++
					if turn.Status != "pending" {
						t.Fatalf("report status %s", turn.Status)
					}
				}
			}
			r, _ := q.GetRun(ctx, store.GetRunParams{ID: parent.ID, WorkspaceID: me.WorkspaceID})
			if count != 1 || r.State != "running" {
				t.Fatalf("reports=%d state=%s", count, r.State)
			}
		})
	}
}

// Delegated runs are copies of the lead's own agent: two parallel copies must
// both start even though the agent's max_concurrency is 1, as two different
// sub agents did before copies.
func TestParallelCopiesDontWaitForTheAgentSlot(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: &artifacts.Service{Pool: pool}}
	out, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	parent := out[0]
	if spec, _ := runs.Spec(parent); spec.MaxConcurrency != 1 {
		t.Fatalf("max_concurrency %d, want 1", spec.MaxConcurrency)
	}
	vol := parent.ID.String()
	if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	exp := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &parent.ID, nil, &exp)
	if err != nil {
		t.Fatal(err)
	}
	main, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	d1, err := svc.DelegateWithContract(ctx, main, "", "docs", runs.Contract{AllowedPaths: []string{"docs/"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status='running' WHERE run_id=$1", parent.ID); err != nil {
		t.Fatal(err)
	}
	d2, err := svc.DelegateWithContract(ctx, main, "", "src", runs.Contract{AllowedPaths: []string{"src/"}})
	if err != nil {
		t.Fatal(err)
	}
	// The lead's process has exited; the queue may start its children.
	if _, err := pool.Exec(ctx, "UPDATE run_turns SET status='done' WHERE run_id=$1", parent.ID); err != nil {
		t.Fatal(err)
	}
	started := map[uuid.UUID]bool{}
	for {
		r, err := q.ClaimQueuedRun(ctx, store.ClaimQueuedRunParams{})
		if err != nil {
			break
		}
		started[r.ID] = true
	}
	if !started[d1.Run.ID] || !started[d2.Run.ID] {
		t.Fatalf("started %v; want both copies %s and %s", started, d1.Run.ID, d2.Run.ID)
	}
}

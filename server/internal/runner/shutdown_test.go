package runner_test

import (
	"context"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/runner"
)

// A runner that shuts down mid-turn kills the harness; the turn must stay
// claimed so the next runner's Recover re-runs it. Marking it done stranded
// the run in "running" with no turn, holding its agent's only slot forever.
func TestShutdownMidTurnRequeuesTheTurn(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "slow")
	e.dispatch("PAY-224")
	run := e.run("PAY-224")

	ctx, shutdown := context.WithCancel(e.ctx)
	deadline := time.Now().Add(20 * time.Second)
	for !strings.Contains(e.eventTypes(run.ID), "tool_result:claim_ticket") {
		if time.Now().After(deadline) {
			t.Fatal("slow turn never started")
		}
		e.runner.Tick(ctx)
		time.Sleep(30 * time.Millisecond)
	}
	shutdown()
	e.runner.Wait()

	turns, err := e.q.ListTurns(e.ctx, run.ID)
	if err != nil || len(turns) != 1 {
		t.Fatalf("turns: %v %d", err, len(turns))
	}
	if turns[0].Status != "running" {
		t.Fatalf("interrupted turn is %q, want it left running for Recover", turns[0].Status)
	}
	if err := e.runner.Recover(e.ctx); err != nil {
		t.Fatal(err)
	}
	turns, _ = e.q.ListTurns(e.ctx, run.ID)
	if turns[0].Status != "pending" {
		t.Fatalf("after Recover the turn is %q, want pending", turns[0].Status)
	}
	if r := e.run("PAY-224"); r.State != "running" {
		t.Fatalf("run is %s, want running", r.State)
	}
}

// A run cancelled while it waits for a slot says so, rather than "ended
// without an outcome", and the runner never sets it up.
func TestCancelBeforeStartSaysWhy(t *testing.T) {
	e := setup(t)
	e.dispatch("PAY-214")
	run := e.run("PAY-214")
	got, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, run.ID, "cancel")
	if err != nil {
		t.Fatal(err)
	}
	if got.Outcome == nil || !strings.HasPrefix(*got.Outcome, "Cancelled by ") || !strings.HasSuffix(*got.Outcome, "before it started.") {
		t.Fatalf("outcome %v", got.Outcome)
	}
	e.runner.Tick(e.ctx)
	e.runner.Wait()
	if evs := e.eventTypes(run.ID); strings.Contains(evs, "lifecycle:starting") {
		t.Fatalf("a cancelled run was set up: %s", evs)
	}
}

type blockingCleanupBackend struct {
	runner.Backend
	cleaning chan struct{}
	release  chan struct{}
}

func (b *blockingCleanupBackend) Cleanup(ctx context.Context) error {
	close(b.cleaning)
	select {
	case <-b.release:
	case <-ctx.Done():
		return ctx.Err()
	}
	return b.Backend.Cleanup(ctx)
}

// OnHeartbeat must only clear the startup state after the first heartbeat row
// is in Postgres, so GET /api/v1/runner never flashes online=false, starting=false.
func TestRunnerOnHeartbeatClearsStartingAfterRegistration(t *testing.T) {
	e := setup(t)
	var starting atomic.Bool
	starting.Store(true)
	cleaning := make(chan struct{})
	release := make(chan struct{})
	e.runner.Backend = &blockingCleanupBackend{Backend: e.runner.Backend, cleaning: cleaning, release: release}
	e.runner.OnHeartbeat = func() { starting.Store(false) }

	ctx, cancel := context.WithCancel(e.ctx)
	defer cancel()
	errCh := make(chan error, 1)
	go func() { errCh <- e.runner.Run(ctx) }()

	<-cleaning
	if !starting.Load() {
		t.Fatal("starting cleared before first heartbeat")
	}
	if rs, err := e.q.LiveRunners(e.ctx); err != nil || len(rs) != 0 {
		t.Fatalf("live runners before heartbeat = %d err=%v", len(rs), err)
	}

	close(release)
	deadline := time.Now().Add(5 * time.Second)
	for starting.Load() {
		if time.Now().After(deadline) {
			t.Fatal("OnHeartbeat was not called after Cleanup finished")
		}
		time.Sleep(10 * time.Millisecond)
	}
	rs, err := e.q.LiveRunners(e.ctx)
	if err != nil || len(rs) != 1 || rs[0].ID != "test-runner" {
		t.Fatalf("live runners right after OnHeartbeat = %+v err=%v", rs, err)
	}

	cancel()
	if err := <-errCh; err != nil {
		t.Fatalf("runner.Run exit: %v", err)
	}
}

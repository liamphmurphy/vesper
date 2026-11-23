package runner

import (
	"context"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestRunnerAdaptivePollIntervals(t *testing.T) {
	r := &Runner{}
	active, idle := r.pollIntervals()
	if active != time.Second || idle != 30*time.Second {
		t.Fatalf("defaults = (%v, %v), want (1s, 30s)", active, idle)
	}
	if got := r.nextPollInterval(active, idle); got != active {
		t.Fatalf("with listener down: nextPoll = %v, want %v", got, active)
	}
	r.listenerUp.Store(true)
	if got := r.nextPollInterval(active, idle); got != idle {
		t.Fatalf("when idle + listener up: nextPoll = %v, want %v", got, idle)
	}
	r.active = 1
	if got := r.nextPollInterval(active, idle); got != active {
		t.Fatalf("with active run: nextPoll = %v, want %v", got, active)
	}
	r.active = 0
	r.usageChecks.Store(1)
	if got := r.nextPollInterval(active, idle); got != active {
		t.Fatalf("with usage check in flight: nextPoll = %v, want %v", got, active)
	}
	r.usageChecks.Store(0)
	if got := r.nextPollInterval(active, idle); got != idle {
		t.Fatalf("back to idle: nextPoll = %v, want %v", got, idle)
	}

	// Explicit short Poll (e.g. in tests) keeps idle equal to Poll unless IdlePoll is set.
	fast := &Runner{Cfg: Config{Poll: 25 * time.Millisecond}}
	fa, fi := fast.pollIntervals()
	if fa != 25*time.Millisecond || fi != 25*time.Millisecond {
		t.Fatalf("explicit poll = (%v, %v), want (25ms, 25ms)", fa, fi)
	}
}

func TestClassifyRunnerNotify(t *testing.T) {
	cases := []struct {
		channel, payload string
		tick, sched, cap bool
	}{
		{"vesper_work", "sign_in", true, false, false},
		{"vesper_work", "model_listing", true, false, false},
		{"vesper_work", "usage_check", true, false, false},
		{"vesper_work", "dev_workspace", true, false, false},
		{"vesper_work", "scheduled_task", false, true, false},
		{"vesper_work", "slot_limit", false, false, true},
		{"vesper_work", "knowledge_import", false, false, false},
		{"lazyagents_changes", `{"type":"run.updated","ids":["1"]}`, true, true, false},
		{"lazyagents_changes", `{"type":"chat.updated","ids":["1"]}`, true, false, false},
		{"lazyagents_changes", `{"type":"playground.updated","ids":["1"]}`, true, false, false},
		{"lazyagents_changes", `{"type":"ticket.updated","ids":["1"]}`, false, false, false},
	}
	for _, tc := range cases {
		tick, sched, slotCap := classifyRunnerNotify(tc.channel, tc.payload)
		if tick != tc.tick || sched != tc.sched || slotCap != tc.cap {
			t.Errorf("classifyRunnerNotify(%q, %q) = (%v,%v,%v), want (%v,%v,%v)",
				tc.channel, tc.payload, tick, sched, slotCap, tc.tick, tc.sched, tc.cap)
		}
	}
}

func TestWorkNotifyTriggersFireOnVesperWork(t *testing.T) {
	pool := testdb.New(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)

	conn, err := pool.Acquire(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = conn.Conn().Close(context.Background())
		conn.Release()
	}()
	if _, err := conn.Exec(ctx, "LISTEN vesper_work"); err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(ctx, "LISTEN lazyagents_changes"); err != nil {
		t.Fatal(err)
	}

	// Normal heartbeat writes must NOT fire slot_limit or lazyagents_changes.
	if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: "r-idle", Backend: "fake", MaxConcurrent: 2, Running: 0, Version: "dev"}); err != nil {
		t.Fatal(err)
	}
	// Updating slot_limit MUST fire vesper_work:'slot_limit' without touching lazyagents_changes.
	limit := int32(1)
	if err := q.SetRunnerSlotLimit(ctx, &limit); err != nil {
		t.Fatal(err)
	}
	n, err := conn.Conn().WaitForNotification(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n.Channel != "vesper_work" || n.Payload != "slot_limit" {
		t.Fatalf("got notification (%q, %q), want (vesper_work, slot_limit)", n.Channel, n.Payload)
	}

	// Sign-in inserts wake the runner via vesper_work:'sign_in'.
	user, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.CreateSignIn(ctx, store.CreateSignInParams{
		WorkspaceID: user.WorkspaceID,
		Provider:    "claude",
		RequestedBy: user.ID,
		ExpiresAt:   time.Now().Add(time.Minute),
	}); err != nil {
		t.Fatal(err)
	}
	n, err = conn.Conn().WaitForNotification(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if n.Channel != "vesper_work" || n.Payload != "sign_in" {
		t.Fatalf("got notification (%q, %q), want (vesper_work, sign_in)", n.Channel, n.Payload)
	}
}

package runner

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
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

	// Claiming and finishing that sign-in must NOT self-notify vesper_work.
	rid := "r-idle"
	claimed, err := q.ClaimSignIn(ctx, &rid)
	if err != nil {
		t.Fatal(err)
	}
	if err := q.FinishSignIn(ctx, store.FinishSignInParams{ID: claimed.ID, Status: "done"}); err != nil {
		t.Fatal(err)
	}
	quietCtx, quietCancel := context.WithTimeout(ctx, 150*time.Millisecond)
	if n, err := conn.Conn().WaitForNotification(quietCtx); !errors.Is(err, context.DeadlineExceeded) {
		quietCancel()
		t.Fatalf("claiming/finishing sign-in self-notified: (%q, %q) err=%v", n.Channel, n.Payload, err)
	}
	quietCancel()

	// Real queued work on the other work tables must still wake vesper_work,
	// while claiming/finishing them must stay silent.
	if err := q.RequestModelListing(ctx, store.RequestModelListingParams{WorkspaceID: user.WorkspaceID, Harness: "claude-code", LoginVersion: "v1"}); err != nil {
		t.Fatal(err)
	}
	if n, err := conn.Conn().WaitForNotification(ctx); err != nil || n.Channel != "vesper_work" || n.Payload != "model_listing" {
		t.Fatalf("model listing notify = (%+v, %v), want (vesper_work, model_listing)", n, err)
	}
	if ml, err := q.ClaimModelListing(ctx, &rid); err != nil {
		t.Fatal(err)
	} else if _, err := q.FinishModelListing(ctx, store.FinishModelListingParams{ClaimID: ml.ClaimID, Models: []byte("[]")}); err != nil {
		t.Fatal(err)
	}

	if err := q.RequestUsageCheck(ctx, store.RequestUsageCheckParams{WorkspaceID: user.WorkspaceID, Harness: "claude-code", LoginVersion: "v1"}); err != nil {
		t.Fatal(err)
	}
	if n, err := conn.Conn().WaitForNotification(ctx); err != nil || n.Channel != "vesper_work" || n.Payload != "usage_check" {
		t.Fatalf("usage check notify = (%+v, %v), want (vesper_work, usage_check)", n, err)
	}
	if uc, err := q.ClaimUsageCheck(ctx, &rid); err != nil {
		t.Fatal(err)
	} else if _, err := q.FinishUsageCheck(ctx, store.FinishUsageCheckParams{ClaimID: uc.ClaimID, RetryAfter: time.Now().Add(time.Minute)}); err != nil {
		t.Fatal(err)
	}

	action := "start"
	if _, err := q.UpsertDevWorkspace(ctx, store.UpsertDevWorkspaceParams{
		WorkspaceID:   user.WorkspaceID,
		UserID:        user.ID,
		Enabled:       true,
		NixMode:       "default",
		Repos:         []byte("[]"),
		ExtraPackages: []byte("[]"),
		TmuxPrefix:    "C-b",
		Action:        &action,
	}); err != nil {
		t.Fatal(err)
	}
	if n, err := conn.Conn().WaitForNotification(ctx); err != nil || n.Channel != "vesper_work" || n.Payload != "dev_workspace" {
		t.Fatalf("dev workspace notify = (%+v, %v), want (vesper_work, dev_workspace)", n, err)
	}
	stack := "local"
	if _, err := q.ClaimDevWorkspaceAction(ctx, store.ClaimDevWorkspaceActionParams{RunnerID: &rid, Stack: &stack}); err != nil {
		t.Fatal(err)
	}
	if err := q.UpdateDevWorkspaceState(ctx, store.UpdateDevWorkspaceStateParams{WorkspaceID: user.WorkspaceID, State: "ready"}); err != nil {
		t.Fatal(err)
	}

	quiet2, quiet2Cancel := context.WithTimeout(ctx, 150*time.Millisecond)
	defer quiet2Cancel()
	if n, err := conn.Conn().WaitForNotification(quiet2); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("claiming/updating work rows self-notified: (%q, %q) err=%v", n.Channel, n.Payload, err)
	}
}

func TestIdleMicroVMRunnerDoesNotSelfNotify(t *testing.T) {
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

	// MicroVM implements LoginStarter, ModelLister, UsageProber, DevWorkspaceBackend,
	// and PlaygroundBackend, exercising every Claim* query during Runner.Run.
	r := &Runner{
		Cfg: Config{
			ID:            "r-idle-loop",
			MaxConcurrent: 2,
		},
		Pool:    pool,
		Backend: &MicroVM{StateDir: t.TempDir()},
		Secrets: &secrets.Service{Q: q},
		StoreSecret: func(context.Context, uuid.UUID, uuid.UUID, string, string) error {
			return nil
		},
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
	}

	rctx, stop := context.WithCancel(ctx)
	done := make(chan error, 1)
	go func() {
		done <- r.Run(rctx)
	}()
	defer func() {
		stop()
		<-done
	}()

	// Wait for LISTEN to attach and the initial wake Tick to complete, then
	// ensure zero vesper_work / lazyagents_changes notifications are emitted.
	quietCtx, quietCancel := context.WithTimeout(ctx, 400*time.Millisecond)
	defer quietCancel()
	if n, err := conn.Conn().WaitForNotification(quietCtx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("idle MicroVM runner emitted self-notification: (%q, %q) err=%v", n.Channel, n.Payload, err)
	}
	if !r.listenerUp.Load() {
		t.Fatal("expected runner LISTEN connection to be active")
	}
}

func TestIdleClaimsDoNotFireVesperWork(t *testing.T) {
	pool := testdb.New(t)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	rid := "r-idle-claims"
	if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: rid, Backend: "fake", MaxConcurrent: 2, Running: 0, Version: "dev"}); err != nil {
		t.Fatal(err)
	}

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

	// Zero-row claim/poll queries run on every idle Tick and vault poll must
	// never emit NOTIFY (otherwise LISTEN wakes Tick in a tight busy-spin loop).
	if _, err := q.ClaimSignIn(ctx, &rid); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("ClaimSignIn: %v", err)
	}
	if _, err := q.ClaimModelListing(ctx, &rid); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("ClaimModelListing: %v", err)
	}
	if _, err := q.ClaimUsageCheck(ctx, &rid); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("ClaimUsageCheck: %v", err)
	}
	stack := "local"
	if _, err := q.ClaimDevWorkspaceAction(ctx, store.ClaimDevWorkspaceActionParams{RunnerID: &rid, Stack: &stack}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("ClaimDevWorkspaceAction: %v", err)
	}
	lease := uuid.New()
	if _, err := q.ClaimKnowledgeImport(ctx, &lease); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("ClaimKnowledgeImport: %v", err)
	}
	if _, err := q.ExpireModelListings(ctx); err != nil {
		t.Fatalf("ExpireModelListings: %v", err)
	}
	if err := q.SetRunnerSlotLimit(ctx, nil); err != nil {
		t.Fatalf("SetRunnerSlotLimit(nil -> nil): %v", err)
	}
	if _, err := pool.Exec(ctx, "UPDATE scheduled_tasks SET enabled = enabled WHERE false"); err != nil {
		t.Fatalf("empty scheduled_tasks update: %v", err)
	}

	quietCtx, quietCancel := context.WithTimeout(ctx, 200*time.Millisecond)
	defer quietCancel()
	if n, err := conn.Conn().WaitForNotification(quietCtx); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("idle claim queries fired unexpected notification: (%q, %q) err=%v", n.Channel, n.Payload, err)
	}
}

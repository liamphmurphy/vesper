package runs_test

import (
	"context"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// Pause a real operation with all its earlier FK/row locks still held.
type boardQueryBarrier struct {
	match            func(pgx.TraceQueryStartData) bool
	reached, release chan struct{}
	once             sync.Once
}

func (b *boardQueryBarrier) TraceQueryStart(ctx context.Context, _ *pgx.Conn, d pgx.TraceQueryStartData) context.Context {
	if b.match(d) {
		b.once.Do(func() {
			close(b.reached)
			select {
			case <-b.release:
			case <-ctx.Done():
			}
		})
	}
	return ctx
}
func (*boardQueryBarrier) TraceQueryEnd(context.Context, *pgx.Conn, pgx.TraceQueryEndData) {}
func boardTracedPool(t *testing.T, ctx context.Context, base *pgxpool.Pool, b *boardQueryBarrier) *pgxpool.Pool {
	t.Helper()
	cfg := base.Config()
	cfg.ConnConfig.Tracer = b
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}
func boardReached(t *testing.T, ctx context.Context, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
}
func boardWaitBlocked(t *testing.T, ctx context.Context, pool *pgxpool.Pool, marker string) {
	t.Helper()
	for {
		var blocked bool
		if err := pool.QueryRow(ctx, `SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid() AND query LIKE $1 AND cardinality(pg_blocking_pids(pid))>0)`, "%-- name: "+marker+" :%").Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			return
		}
		if ctx.Err() != nil {
			t.Fatal(ctx.Err())
		}
	}
}
func boardRaceFixture(t *testing.T) (*pgxpool.Pool, *runs.Service, store.User, store.Agent, store.Ticket) {
	t.Helper()
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	a, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: u.WorkspaceID, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}
	tr := &tracker.Service{Pool: pool}
	ticket, err := tr.Create(ctx, u.WorkspaceID, tracker.UserActor(u.ID), tracker.NewTicket{ProjectKey: "PAY", Title: "race", AssigneeAgentID: &a.ID})
	if err != nil {
		t.Fatal(err)
	}
	return pool, &runs.Service{Pool: pool, Tracker: tr}, u, a, ticket
}
func TestCompleteCannotUndoCancellation(t *testing.T) {
	pool, svc, u, a, ticket := boardRaceFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	caller := runs.Caller{Agent: a, Kind: "unmanaged"}
	run, err := svc.Claim(ctx, caller, ticket.Key)
	if err != nil {
		t.Fatal(err)
	}
	caller.RunID = &run.ID
	gate := &boardQueryBarrier{match: func(d pgx.TraceQueryStartData) bool { return strings.Contains(d.SQL, "-- name: LockProject :") }, reached: make(chan struct{}), release: make(chan struct{})}
	defer close(gate.release)
	svc.Tracker = &tracker.Service{Pool: boardTracedPool(t, ctx, pool, gate)}
	result := make(chan error, 1)
	go func() { result <- svc.Complete(ctx, caller, ticket.Key, "finished", "", "todo", "") }()
	boardReached(t, ctx, gate.reached) // run committed; final ticket PATCH has not locked project
	canceled := "canceled"
	if _, err = (&tracker.Service{Pool: pool}).Update(ctx, u.WorkspaceID, tracker.UserActor(u.ID), ticket.Key, tracker.Patch{Status: &canceled}); err != nil {
		t.Fatal(err)
	}
	gate.release <- struct{}{}
	if err = <-result; err != nil {
		t.Fatal(err)
	}
	current, err := tracker.Get(ctx, store.New(pool), u.WorkspaceID, ticket.Key)
	if err != nil {
		t.Fatal(err)
	}
	if current.Status != "canceled" {
		t.Fatalf("completion undid cancellation: %s", current.Status)
	}
}
func TestDelegationCancellationPatchLockOrder(t *testing.T) {
	pool, svc, u, a, ticket := boardRaceFixture(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	q := store.New(pool)
	dispatched, err := svc.Dispatch(ctx, u.WorkspaceID, u.ID, []string{ticket.Key})
	if err != nil {
		t.Fatal(err)
	}
	parent := dispatched[0]
	vol := parent.ID.String()
	if err = q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol}); err != nil {
		t.Fatal(err)
	}
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	if _, err = pool.Exec(ctx, `UPDATE run_turns SET status='running' WHERE run_id=$1`, parent.ID); err != nil {
		t.Fatal(err)
	}
	caller := runs.Caller{Agent: a, Kind: "run", RunID: &parent.ID}
	first, err := svc.DelegateWithContract(ctx, caller, ticket.Key, "first task", runs.Contract{AllowedPaths: []string{"first/"}})
	if err != nil {
		t.Fatal(err)
	}
	gate := &boardQueryBarrier{match: func(d pgx.TraceQueryStartData) bool {
		return strings.Contains(d.SQL, "-- name: LockRun :") && len(d.Args) > 0 && fmt.Sprint(d.Args[0]) == parent.ID.String()
	}, reached: make(chan struct{}), release: make(chan struct{})}
	defer close(gate.release)
	cancelSvc := *svc
	cancelSvc.Pool = boardTracedPool(t, ctx, pool, gate)
	cancelResult := make(chan error, 1)
	go func() {
		_, e := cancelSvc.SetRunControl(ctx, u.WorkspaceID, u.ID, first.Run.ID, "cancel")
		cancelResult <- e
	}()
	boardReached(t, ctx, gate.reached) // child + activity ticket FK KEY SHARE held
	patchResult := make(chan error, 1)
	title := "patch after cancel"
	go func() {
		_, e := svc.Tracker.Update(ctx, u.WorkspaceID, tracker.UserActor(u.ID), ticket.Key, tracker.Patch{Title: &title})
		patchResult <- e
	}()
	boardWaitBlocked(t, ctx, pool, "LockTicketByKey") // PATCH owns project, waits on FK
	delegateResult := make(chan error, 1)
	go func() {
		_, e := svc.DelegateWithContract(ctx, caller, ticket.Key, "second task", runs.Contract{AllowedPaths: []string{"second/"}})
		delegateResult <- e
	}()
	boardWaitBlocked(t, ctx, pool, "LockProject") // delegation must not yet own parent
	gate.release <- struct{}{}
	if err = <-cancelResult; err != nil {
		t.Fatalf("cancel: %v", err)
	}
	if err = <-patchResult; err != nil {
		t.Fatalf("patch: %v", err)
	}
	// A newly queued delegation resume can legitimately refuse the old turn.
	if err = <-delegateResult; err != nil && !isConflict(err) {
		t.Fatalf("delegate: %v", err)
	}
}
func TestTicketCancelSerializesWithClaimAndDispatch(t *testing.T) {
	for _, dispatch := range []bool{false, true} {
		for _, cancelWins := range []bool{false, true} {
			t.Run(fmt.Sprintf("dispatch=%v/cancelWins=%v", dispatch, cancelWins), func(t *testing.T) {
				pool, svc, u, a, ticket := boardRaceFixture(t)
				ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
				defer cancel()
				marker := "-- name: CreateRun :"
				if cancelWins {
					marker = "-- name: UpdateTicket :"
				}
				gate := &boardQueryBarrier{match: func(d pgx.TraceQueryStartData) bool { return strings.Contains(d.SQL, marker) }, reached: make(chan struct{}), release: make(chan struct{})}
				defer close(gate.release)
				traced := boardTracedPool(t, ctx, pool, gate)
				cancelTracker := &tracker.Service{Pool: pool}
				if cancelWins {
					cancelTracker.Pool = traced
				} else {
					svc.Pool = traced
				}
				action := func() error {
					if dispatch {
						_, e := svc.Dispatch(ctx, u.WorkspaceID, u.ID, []string{ticket.Key})
						return e
					}
					_, e := svc.Claim(ctx, runs.Caller{Agent: a, Kind: "unmanaged"}, ticket.Key)
					return e
				}
				cancelTicket := func() error {
					s := "canceled"
					_, e := cancelTracker.Update(ctx, u.WorkspaceID, tracker.UserActor(u.ID), ticket.Key, tracker.Patch{Status: &s})
					return e
				}
				winner, loser := action, cancelTicket
				if cancelWins {
					winner, loser = cancelTicket, action
				}
				winnerResult, loserResult := make(chan error, 1), make(chan error, 1)
				go func() { winnerResult <- winner() }()
				boardReached(t, ctx, gate.reached) // winner holds project/ticket before writing
				go func() { loserResult <- loser() }()
				boardWaitBlocked(t, ctx, pool, "LockProject")
				gate.release <- struct{}{}
				if err := <-winnerResult; err != nil {
					t.Fatalf("winner: %v", err)
				}
				if err := <-loserResult; !isConflict(err) {
					t.Fatalf("loser should conflict: %v", err)
				}
				current, err := tracker.Get(ctx, store.New(pool), u.WorkspaceID, ticket.Key)
				if err != nil {
					t.Fatal(err)
				}
				if (current.Status == "canceled") != cancelWins {
					t.Fatalf("wrong winning state: %s", current.Status)
				}
			})
		}
	}
}

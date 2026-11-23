package metrics

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"math"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/riverqueue/river"
)

func TestRecordedMetricsAndWindows(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	user, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ws := user.WorkspaceID
	now := time.Now().UTC().Truncate(time.Second)
	empty, err := Calculate(ctx, pool, ws, "7d", now)
	if err != nil {
		t.Fatal(err)
	}
	if empty.Performance.Completed != 0 || empty.Performance.MedianCycleSeconds != nil || len(empty.Daily) != 8 {
		t.Fatalf("empty metrics: %+v", empty)
	}
	project, err := q.CreateProject(ctx, store.CreateProjectParams{WorkspaceID: ws, Key: "MET", Name: "Metrics", Color: "#888888"})
	if err != nil {
		t.Fatal(err)
	}
	agent, err := q.CreateAgent(ctx, store.CreateAgentParams{WorkspaceID: ws, Name: "Metric", Handle: "metric", Status: "idle", Model: "fake"})
	if err != nil {
		t.Fatal(err)
	}
	ticket := func(number int, created time.Time) uuid.UUID {
		t.Helper()
		var id uuid.UUID
		err := pool.QueryRow(ctx, `INSERT INTO tickets(workspace_id,project_id,number,key,title,status,assignee_agent_id,created_at) VALUES($1,$2,$3::integer,'MET-'||($3::integer)::text,'Measured task','done',$4,$5) RETURNING id`, ws, project.ID, number, agent.ID, created).Scan(&id)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	event := func(id uuid.UUID, to string, at time.Time) {
		t.Helper()
		raw, _ := json.Marshal(map[string]string{"to": to})
		if _, err := q.InsertActivity(ctx, store.InsertActivityParams{WorkspaceID: ws, TicketID: &id, ActorType: "system", Verb: "status_changed", Payload: raw, CreatedAt: &at}); err != nil {
			t.Fatal(err)
		}
	}
	a := ticket(1, now.Add(-10*24*time.Hour))
	event(a, "in_progress", now.Add(-3*24*time.Hour))
	event(a, "done", now.Add(-2*24*time.Hour))
	event(a, "todo", now.Add(-2*time.Hour))
	event(a, "done", now.Add(-time.Hour))
	b := ticket(2, now.Add(-5*24*time.Hour))
	event(b, "done", now.Add(-4*24*time.Hour))
	c := ticket(3, now.Add(-25*24*time.Hour))
	event(c, "done", now.Add(-20*24*time.Hour))
	future := ticket(4, now)
	event(future, "done", now.Add(time.Hour))
	// Done, then canceled: throughput counts only tickets that are done now.
	canceled := ticket(5, now.Add(-6*24*time.Hour))
	event(canceled, "done", now.Add(-3*24*time.Hour))
	event(canceled, "canceled", now.Add(-3*time.Hour))
	if _, err = pool.Exec(ctx, "UPDATE tickets SET status='canceled' WHERE id=$1", canceled); err != nil {
		t.Fatal(err)
	}
	// A closed PR is counted once despite duplicate sync events.
	if _, err = pool.Exec(ctx, "UPDATE tickets SET pr_state='merged' WHERE id=$1", a); err != nil {
		t.Fatal(err)
	}
	for _, at := range []time.Time{now.Add(-2 * time.Hour), now.Add(-time.Hour)} {
		if _, err = q.InsertActivity(ctx, store.InsertActivityParams{WorkspaceID: ws, TicketID: &a, ActorType: "system", Verb: "pr_merged", Payload: json.RawMessage(`{}`), CreatedAt: &at}); err != nil {
			t.Fatal(err)
		}
	}
	for i, at := range []time.Time{now.Add(-2 * 24 * time.Hour), now.Add(-40 * 24 * time.Hour), now.Add(-time.Hour)} {
		costs := []int{4500000, 9000000, 1000000}
		if _, err = pool.Exec(ctx, `INSERT INTO runs(workspace_id,ticket_id,agent_id,mode,state,resolved_spec,harness,model,started_at,ended_at,cost_usd_micros,purpose) VALUES($1,$2,$3,'managed','completed','{}','codex','fake',$4,$4,$5,'ticket')`, ws, a, agent.ID, at, costs[i]); err != nil {
			t.Fatal(err)
		}
	}
	seven, err := Calculate(ctx, pool, ws, "7d", now)
	if err != nil {
		t.Fatal(err)
	}
	if seven.Performance.Completed != 2 || seven.Performance.MedianCycleSeconds == nil || math.Abs(*seven.Performance.MedianCycleSeconds-171000) > 0.1 || seven.Performance.SpendUSD != 5.5 || seven.Performance.MergedPRs != 1 || seven.Performance.ClosedPRs != 1 {
		t.Fatalf("7-day metrics: %+v", seven)
	}
	if seven.Agents[agent.ID].Completed != 2 {
		t.Fatal("agent stats lost completions")
	}
	sum := 0
	for _, d := range seven.Daily {
		sum += d.Count
	}
	if sum != seven.Performance.Completed {
		t.Fatal("daily bars disagree with KPI")
	}
	day, err := Calculate(ctx, pool, ws, "24h", now)
	if err != nil {
		t.Fatal(err)
	}
	if day.Performance.Completed != 1 || day.Performance.SpendUSD != 1 {
		t.Fatalf("24h: %+v", day)
	}
	month, err := Calculate(ctx, pool, ws, "30d", now)
	if err != nil {
		t.Fatal(err)
	}
	if month.Performance.Completed != 3 {
		t.Fatalf("30d: %+v", month)
	}
	other, err := q.CreateWorkspace(ctx, store.CreateWorkspaceParams{Name: "Other", Slug: "other"})
	if err != nil {
		t.Fatal(err)
	}
	isolated, err := Calculate(ctx, pool, other.ID, "30d", now)
	if err != nil {
		t.Fatal(err)
	}
	if isolated.Performance.Completed != 0 || isolated.Performance.SpendUSD != 0 {
		t.Fatal("metrics leaked workspace data")
	}
	if err = Refresh(ctx, pool); err != nil {
		t.Fatal(err)
	}
	cached, err := Get(ctx, pool, ws, "7d")
	if err != nil {
		t.Fatal(err)
	}
	if cached.Performance.Completed != 2 {
		t.Fatal("snapshot lost results")
	}
	// Edits alone must not manufacture completion timestamps.
	if _, err = pool.Exec(ctx, "UPDATE tickets SET title='Edited long after delivery' WHERE id=$1", a); err != nil {
		t.Fatal(err)
	}
	after, err := Calculate(ctx, pool, ws, "7d", now)
	if err != nil {
		t.Fatal(err)
	}
	if after.Performance.Completed != seven.Performance.Completed || *after.Performance.MedianCycleSeconds != *seven.Performance.MedianCycleSeconds {
		t.Fatal("unrelated edit changed delivery metrics")
	}
}

func TestRiverRollupRunsOnStart(t *testing.T) {
	pool := testdb.New(t)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	jobs, err := NewClient(pool, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	events, unsubscribe := jobs.Subscribe(river.EventKindJobCompleted)
	defer unsubscribe()
	if err = jobs.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer func() {
		stop, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := jobs.Stop(stop); err != nil {
			t.Error(err)
		}
	}()
	select {
	case event := <-events:
		if event.Job.Kind != "metrics_rollup" {
			t.Fatal(event.Job.Kind)
		}
	case <-ctx.Done():
		t.Fatal("River did not execute startup rollup")
	}
	var count int
	if err = pool.QueryRow(ctx, "SELECT count(*) FROM metric_snapshots").Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 3 {
		t.Fatalf("snapshots: %d", count)
	}
}

func TestRefreshSkipsUnchangedSnapshots(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	user, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ws := user.WorkspaceID

	if err := Refresh(ctx, pool); err != nil {
		t.Fatal(err)
	}
	first, err := q.GetMetricSnapshot(ctx, store.GetMetricSnapshotParams{WorkspaceID: ws, Range: "7d"})
	if err != nil {
		t.Fatal(err)
	}

	time.Sleep(25 * time.Millisecond)
	if err := Refresh(ctx, pool); err != nil {
		t.Fatal(err)
	}
	second, err := q.GetMetricSnapshot(ctx, store.GetMetricSnapshotParams{WorkspaceID: ws, Range: "7d"})
	if err != nil {
		t.Fatal(err)
	}
	if !second.GeneratedAt.Equal(first.GeneratedAt) {
		t.Fatalf("idle Refresh rewrote snapshot: first=%v second=%v", first.GeneratedAt, second.GeneratedAt)
	}

	// Recording new activity marks the workspace dirty so the next Refresh writes.
	if _, err := q.InsertActivity(ctx, store.InsertActivityParams{
		WorkspaceID: ws,
		ActorType:   "system",
		Verb:        "status_changed",
		Payload:     json.RawMessage(`{"to":"done"}`),
	}); err != nil {
		t.Fatal(err)
	}
	if err := Refresh(ctx, pool); err != nil {
		t.Fatal(err)
	}
	third, err := q.GetMetricSnapshot(ctx, store.GetMetricSnapshotParams{WorkspaceID: ws, Range: "7d"})
	if err != nil {
		t.Fatal(err)
	}
	if !third.GeneratedAt.After(first.GeneratedAt) {
		t.Fatalf("dirty Refresh did not advance snapshot: first=%v third=%v", first.GeneratedAt, third.GeneratedAt)
	}
}

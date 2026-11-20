package agents_test

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestDefinitionsVersionsAndOverrides(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &agents.Service{Pool: pool}
	atlas, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}

	// Seeded history matches agent-config.html: v7, two overrides.
	spec, cur, err := agents.CurrentSpec(ctx, q, atlas)
	if err != nil || cur.Version != 7 || spec.Scopes["db:migrate"] != agentdef.RequiresApproval {
		t.Fatalf("current = v%d %v %v", cur.Version, spec.Scopes, err)
	}
	pay, _ := agents.Resolve(ctx, q, ws, atlas, "PAY")
	if pay.Provenance["instructions"] != agentdef.FromProject || len(pay.MCPServers) != 2 {
		t.Fatalf("PAY resolved = %+v", pay)
	}
	bil, _ := agents.Resolve(ctx, q, ws, atlas, "BIL")
	if bil.Harness != agentdef.HarnessCodex || bil.Mode("prod:deploy") != agentdef.Denied {
		t.Fatalf("BIL resolved = %s", bil.Harness)
	}

	// Saving writes v8 and syncs the agent row.
	spec.Model = "opus-5.5-long"
	a, err := svc.SaveDefinition(ctx, ws, me.ID, "atlas", agents.Identity{Name: "Atlas", Role: "Backend", ColorIndex: 0}, spec, "Longer context")
	if err != nil {
		t.Fatal(err)
	}
	_, cur, _ = agents.CurrentSpec(ctx, q, a)
	if cur.Version != 8 || a.Model != "opus-5.5-long" || a.Role != "Backend" {
		t.Fatalf("after save: v%d model=%s role=%s", cur.Version, a.Model, a.Role)
	}

	// An override can't loosen db:migrate; resolving keeps the agent's mode.
	if err := svc.SetOverride(ctx, ws, me.ID, "atlas", "DOC", agentdef.Override{Scopes: map[string]agentdef.Mode{"db:migrate": agentdef.Allowed}}); err != nil {
		t.Fatal(err)
	}
	doc, _ := agents.Resolve(ctx, q, ws, a, "DOC")
	if doc.Mode("db:migrate") != agentdef.RequiresApproval {
		t.Fatalf("override loosened db:migrate: %s", doc.Mode("db:migrate"))
	}
	// An empty override removes the row.
	if err := svc.SetOverride(ctx, ws, me.ID, "atlas", "DOC", agentdef.Override{}); err != nil {
		t.Fatal(err)
	}
	overrides, _ := q.ListOverrides(ctx, a.ID)
	if len(overrides) != 2 {
		t.Fatalf("overrides = %d, want the 2 seeded", len(overrides))
	}

	// Validation surfaces as apperr for the API.
	bad := spec
	bad.Harness = "aider"
	_, err = svc.SaveDefinition(ctx, ws, me.ID, "atlas", agents.Identity{Name: "Atlas"}, bad, "")
	var ve *apperr.ValidationError
	if !errors.As(err, &ve) || ve.Field != "harness" {
		t.Fatalf("bad harness: %v", err)
	}
}

// workRecord makes a bare work record, as a persona's first work does.
func workRecord(t *testing.T, ctx context.Context, q *store.Queries, ws uuid.UUID, by uuid.UUID, handle string) store.Agent {
	t.Helper()
	a, err := q.CreateAgent(ctx, store.CreateAgentParams{WorkspaceID: ws, Name: "Temp", Handle: handle, Status: "idle", Model: agents.DefaultSpec().Model})
	if err != nil {
		t.Fatal(err)
	}
	if a, err = agents.WriteVersion(ctx, q, a, agents.Identity{Name: "Temp"}, agents.DefaultSpec(), "Created", &by, nil); err != nil {
		t.Fatal(err)
	}
	return a
}

func TestDeleteArchivesAgent(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &agents.Service{Pool: pool}
	workRecord(t, ctx, q, ws, me.ID, "temp")
	if err := svc.Delete(ctx, ws, "temp"); err != nil {
		t.Fatal(err)
	}
	if _, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "temp"}); err == nil {
		t.Fatal("archived agent still resolvable by handle")
	}
	all, _ := q.ListAllAgents(ctx, ws)
	live, _ := q.ListAgents(ctx, ws)
	if len(all) != len(live)+1 {
		t.Fatalf("all=%d live=%d", len(all), len(live))
	}
	if err := svc.Delete(ctx, ws, "temp"); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("second delete = %v", err)
	}
	// Seeded agents have open tickets.
	err := svc.Delete(ctx, ws, "atlas")
	var c *apperr.ConflictError
	if !errors.As(err, &c) {
		t.Fatalf("atlas delete = %v, want conflict", err)
	}
	// The archived record's handle is free again.
	if taken, err := q.AgentHandleTaken(ctx, store.AgentHandleTakenParams{WorkspaceID: ws, Handle: "temp"}); err != nil || taken {
		t.Fatalf("handle reuse: taken=%v %v", taken, err)
	}
}

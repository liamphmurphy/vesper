package agentapi

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// delegate hands work to a fresh copy of the caller: there's no roster to pick
// from, and read_only gives a copy without repo:write.
func TestDelegateToolStartsACopy(t *testing.T) {
	if _, ok := ByName["list_subagents"]; ok {
		t.Fatal("list_subagents is still a tool")
	}
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Poll: 20 * time.Millisecond}
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
	exp := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &parent.ID, nil, &exp)
	if err != nil {
		t.Fatal(err)
	}
	c, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	res, err := ByName["delegate"].call(ctx, Deps{Q: q, Runs: svc}, c, json.RawMessage(`{"task":"Review the diff","read_only":true}`))
	if err != nil {
		t.Fatal(err)
	}
	got := res.(map[string]any)
	if got["state"] != "delegated" || got["agent"] != "atlas" || got["read_only"] != true {
		t.Fatalf("delegate = %v", got)
	}
	child, err := q.GetRun(ctx, store.GetRunParams{ID: got["run_id"].(uuid.UUID), WorkspaceID: ws})
	if err != nil {
		t.Fatal(err)
	}
	spec, _ := runs.Spec(child)
	if child.AgentID != atlas.ID || child.ParentRunID == nil || *child.ParentRunID != parent.ID || spec.Mode("repo:write") != agentdef.Denied {
		t.Fatalf("child %+v, repo:write %v", child, spec.Mode("repo:write"))
	}
}

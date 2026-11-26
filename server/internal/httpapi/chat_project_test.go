package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// A chat with no default project reads workspace content, lists spaces, and
// refuses removed Work-mode tools.
func TestChatWithoutProjectReadsEveryProject(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	wk := &wiki.Service{Pool: pool, Artifacts: arts, Tracker: tr}
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts, Wiki: wk}).Handler()
	call := func(token, name string, args any) (int, map[string]any) {
		t.Helper()
		raw, _ := json.Marshal(args)
		req := httptest.NewRequest("POST", "/api/v1/agent/tools/"+name, bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}

	chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{Title: "Above projects", Message: &runs.ChatMessageInput{Body: "hello"}})
	if err != nil {
		t.Fatal(err)
	}
	if chat, err = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws}); err != nil || chat.CurrentRunID == nil {
		t.Fatalf("chat run: %v", err)
	}
	if chat.ProjectID != nil {
		t.Fatalf("project = %v, want none", chat.ProjectID)
	}
	runID := *chat.CurrentRunID
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: runID, State: "waiting"}); err != nil {
		t.Fatal(err)
	}
	if chat, err = q.SetChatRunState(ctx, store.SetChatRunStateParams{ID: chat.ID, CurrentRunID: &runID, State: "idle"}); err != nil {
		t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, q, chat.AgentID, "run", "chat", &runID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}

	if code, out := call(token, "list_spaces", map[string]any{}); code != 200 || out["spaces"] == nil {
		t.Fatalf("list_spaces = %d %v", code, out)
	}
	for _, removed := range []string{"list_projects", "get_ticket", "create_ticket", "create_epic", "list_epics", "list_runs"} {
		if code, out := call(token, removed, map[string]any{}); code != 409 && code != 404 {
			t.Fatalf("%s = %d %v, want refused or unknown", removed, code, out)
		}
	}

	// Attaching ends the segment so the next message starts fresh.
	pay := "PAY"
	attached, err := rs.UpdateChat(ctx, ws, me.ID, chat.ID, runs.ChatPatchInput{Revision: chat.Revision, Project: &pay})
	if err != nil {
		t.Fatal(err)
	}
	if attached.ProjectID == nil || attached.CurrentRunID != nil {
		t.Fatalf("after attach: project %v run %v", attached.ProjectID, attached.CurrentRunID)
	}
	run, err := q.GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: ws})
	if err != nil || run.State != "completed" {
		t.Fatalf("old segment = %s, %v", run.State, err)
	}

	// A repeat attach changes nothing; detaching clears it.
	same, err := rs.UpdateChat(ctx, ws, me.ID, chat.ID, runs.ChatPatchInput{Revision: attached.Revision, Project: &pay})
	if err != nil || same.ProjectID == nil {
		t.Fatalf("re-attach: %+v, %v", same.ProjectID, err)
	}
	none := ""
	detached, err := rs.UpdateChat(ctx, ws, me.ID, chat.ID, runs.ChatPatchInput{Revision: same.Revision, Project: &none})
	if err != nil || detached.ProjectID != nil {
		t.Fatalf("detach: %+v, %v", detached.ProjectID, err)
	}
	unknown := "NOPE"
	if _, err = rs.UpdateChat(ctx, ws, me.ID, chat.ID, runs.ChatPatchInput{Revision: detached.Revision, Project: &unknown}); err == nil {
		t.Fatal("attached an unknown project")
	}
}

func jsonString(v any) string {
	raw, _ := json.Marshal(v)
	return string(raw)
}

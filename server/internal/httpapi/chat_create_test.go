package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// A chat sets up spaces, scheduled tasks and learning modules for its person,
// owned by them and answered by the chat's persona, with no capability needed.
func TestChatCreatesSpacesTasksAndModules(t *testing.T) {
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
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()
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

	coach, err := q.CreatePersona(ctx, store.CreatePersonaParams{WorkspaceID: ws, UserID: me.ID, Name: "Coach", Tone: "neutral", Color: "#22aa66", Repos: []string{}})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{Title: "Health", PersonaID: &coach.ID, Message: &runs.ChatMessageInput{Body: "set me up"}})
	if err != nil {
		t.Fatal(err)
	}
	chat, err = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
	if err != nil || chat.CurrentRunID == nil {
		t.Fatalf("chat run: %v", err)
	}
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: *chat.CurrentRunID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, q, chat.AgentID, "run", "chat", chat.CurrentRunID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}

	code, out := call(token, "create_space", map[string]any{"name": "Health", "color": "teal", "instructions": "Coach me on food and training."})
	if code != 200 || !strings.HasPrefix(fmt.Sprint(out["href"]), "/spaces/") {
		t.Fatalf("create_space = %d %v", code, out)
	}
	spaces, err := q.ListChatSpaces(ctx, store.ListChatSpacesParams{WorkspaceID: ws, UserID: me.ID})
	// The seeded projects' spaces file under their own work; Health is the only other.
	spaces = slices.DeleteFunc(spaces, func(sp store.ChatSpace) bool { return sp.ProjectID != nil })
	if err != nil || len(spaces) != 1 || spaces[0].Name != "Health" || spaces[0].Color != "teal" || spaces[0].PersonaID == nil || *spaces[0].PersonaID != coach.ID {
		t.Fatalf("spaces = %+v, %v", spaces, err)
	}
	if code, out := call(token, "create_space", map[string]any{"name": "Bad", "color": "plaid"}); code != 422 {
		t.Fatalf("bad colour = %d %v", code, out)
	}

	task := map[string]any{"name": "Weekly check-in", "instructions": "Ask how training went this week.", "frequency": "weekly", "weekdays": []int{1}, "at_time": "08:00", "timezone": "America/Los_Angeles"}
	code, out = call(token, "create_scheduled_task", task)
	if code != 200 || out["next_run_at"] == nil {
		t.Fatalf("create_scheduled_task = %d %v", code, out)
	}
	tasks, err := q.ListScheduledTasks(ctx, store.ListScheduledTasksParams{WorkspaceID: ws, UserID: me.ID})
	if err != nil || len(tasks) != 1 || tasks[0].Kind != "prompt" || !tasks[0].Enabled || tasks[0].MaxMinutes != nil || tasks[0].MaxCostMicros != nil || tasks[0].PersonaID == nil || *tasks[0].PersonaID != coach.ID {
		t.Fatalf("tasks = %+v, %v", tasks, err)
	}
	task["timezone"] = ""
	if code, out := call(token, "create_scheduled_task", task); code != 422 {
		t.Fatalf("no time zone = %d %v", code, out)
	}

	code, out = call(token, "create_learning_module", map[string]any{"topic": "Strength training basics", "level": "new"})
	if code != 200 || out["state"] != "scoping" || !strings.HasPrefix(fmt.Sprint(out["href"]), "/learn/") {
		t.Fatalf("create_learning_module = %d %v", code, out)
	}
	if code, out := call(token, "create_learning_module", map[string]any{"topic": "x", "level": "expert"}); code != 422 {
		t.Fatalf("bad level = %d %v", code, out)
	}
}

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

// Personas can attach a work-tracking space by name, project key, or space UUID
// when creating or updating a scheduled task, clear it with "", or inherit the
// current chat's space when omitted.
func TestChatScheduledTaskSpace(t *testing.T) {
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

	pay, err := q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: "PAY"})
	if err != nil || pay.SpaceID == nil {
		t.Fatalf("seeded PAY project/space: %+v, %v", pay, err)
	}
	// A chat-only space with no project.
	personalSpaceName := "Personal Health"
	if _, err := rs.CreateSpace(ctx, ws, me.ID, runs.SpaceInput{Name: &personalSpaceName}); err != nil {
		t.Fatal(err)
	}

	// Start a chat outside any space/project.
	chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{Title: "Home", Message: &runs.ChatMessageInput{Body: "schedule"}})
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

	base := func(name string, extra map[string]any) map[string]any {
		m := map[string]any{
			"name":         name,
			"instructions": "Run audit.",
			"frequency":    "weekly",
			"weekdays":     []int{0},
			"at_time":      "08:00",
			"timezone":     "America/Los_Angeles",
		}
		for k, v := range extra {
			m[k] = v
		}
		return m
	}

	// 1. Set space by display name.
	code, out := call(token, "create_scheduled_task", base("By name", map[string]any{"space": pay.Name}))
	if code != 200 || out["project"] != pay.Key || out["space"] != pay.Name {
		t.Fatalf("create by name = %d %v", code, out)
	}
	byNameID := fmt.Sprint(out["task_id"])

	// 2. Set space by lowercase project key.
	code, out = call(token, "create_scheduled_task", base("By key", map[string]any{"space": strings.ToLower(pay.Key)}))
	if code != 200 || out["project"] != pay.Key || out["space"] != pay.Name {
		t.Fatalf("create by key = %d %v", code, out)
	}

	// 3. Set space by space UUID.
	code, out = call(token, "create_scheduled_task", base("By uuid", map[string]any{"space": pay.SpaceID.String()}))
	if code != 200 || out["project"] != pay.Key {
		t.Fatalf("create by space uuid = %d %v", code, out)
	}

	// 4. Reject non-project space, unknown space, and space on custom_app.
	if code, out := call(token, "create_scheduled_task", base("No proj", map[string]any{"space": personalSpaceName})); code != 422 {
		t.Fatalf("non-project space = %d %v, want 422", code, out)
	}
	if code, out := call(token, "create_scheduled_task", base("Unknown", map[string]any{"space": "DoesNotExist"})); code != 422 {
		t.Fatalf("unknown space = %d %v, want 422", code, out)
	}
	if code, out := call(token, "create_scheduled_task", map[string]any{
		"name": "App with space", "custom_app_slug": "feed", "custom_app_tool": "sync",
		"space": pay.Name, "frequency": "daily", "at_time": "08:00", "timezone": "UTC",
	}); code != 422 {
		t.Fatalf("custom_app with space = %d %v, want 422", code, out)
	}

	// 5. Update clears and re-attaches space.
	code, listed := call(token, "list_scheduled_tasks", map[string]any{})
	if code != 200 {
		t.Fatalf("list_scheduled_tasks = %d %v", code, listed)
	}
	var rev float64
	for _, raw := range listed["tasks"].([]any) {
		item := raw.(map[string]any)
		if item["task_id"] == byNameID {
			if item["project"] != pay.Key || item["space"] != pay.Name {
				t.Fatalf("listed task missing project/space: %v", item)
			}
			rev = item["revision"].(float64)
		}
	}
	code, out = call(token, "update_scheduled_task", map[string]any{"task_id": byNameID, "revision": rev, "space": ""})
	if code != 200 {
		t.Fatalf("clear space = %d %v", code, out)
	}
	taskMap := out["task"].(map[string]any)
	if taskMap["project"] != nil || taskMap["space"] != nil {
		t.Fatalf("expected cleared space, got %v", taskMap)
	}
	rev = taskMap["revision"].(float64)
	code, out = call(token, "update_scheduled_task", map[string]any{"task_id": byNameID, "revision": rev, "space": pay.Name})
	if code != 200 {
		t.Fatalf("re-set space = %d %v", code, out)
	}
	taskMap = out["task"].(map[string]any)
	if taskMap["project"] != pay.Key || taskMap["space"] != pay.Name {
		t.Fatalf("expected re-set space, got %v", taskMap)
	}

	// 6. A chat moved into a work-tracking space (space_id set, project_id nil)
	// inherits that space's project when space is omitted, and respects space: "".
	if _, err := q.SetChatSpace(ctx, store.SetChatSpaceParams{ID: chat.ID, SpaceID: pay.SpaceID}); err != nil {
		t.Fatal(err)
	}
	code, out = call(token, "create_scheduled_task", base("Inherited", nil))
	if code != 200 || out["project"] != pay.Key || out["space"] != pay.Name {
		t.Fatalf("inherited from chat space = %d %v", code, out)
	}
	code, out = call(token, "create_scheduled_task", base("Explicit none", map[string]any{"space": ""}))
	if code != 200 || out["project"] != nil || out["space"] != nil {
		t.Fatalf("explicit empty space = %d %v", code, out)
	}
}

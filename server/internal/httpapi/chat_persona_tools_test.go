package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// personaChat is a running chat on the demo workspace, answered by a persona,
// whose tools a test calls the way the harness does.
type personaChat struct {
	ctx     context.Context
	pool    *pgxpool.Pool
	q       *store.Queries
	rs      *runs.Service
	ws      uuid.UUID
	user    uuid.UUID
	persona uuid.UUID
	chat    store.ChatSession
	token   string
	handler http.Handler
}

func newPersonaChat(t *testing.T, project string) *personaChat {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	p, err := q.CreatePersona(ctx, store.CreatePersonaParams{WorkspaceID: me.WorkspaceID, UserID: me.ID, Name: "Hackerman", Tone: "neutral", Color: "#9b8cff", Repos: []string{}})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := rs.StartChat(ctx, me.WorkspaceID, me.ID, runs.ChatInput{Project: project, Title: "Tools", PersonaID: &p.ID, Message: &runs.ChatMessageInput{Body: "hello"}})
	if err != nil {
		t.Fatal(err)
	}
	if chat, err = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: me.WorkspaceID}); err != nil || chat.CurrentRunID == nil {
		t.Fatalf("chat run: %v", err)
	}
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: *chat.CurrentRunID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, q, chat.AgentID, "run", "chat", chat.CurrentRunID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()
	return &personaChat{ctx: ctx, pool: pool, q: q, rs: rs, ws: me.WorkspaceID, user: me.ID, persona: p.ID, chat: chat, token: token, handler: handler}
}

// call runs a tool and decodes its result.
func (c *personaChat) call(t *testing.T, name string, args any) (int, map[string]any) {
	t.Helper()
	raw, _ := json.Marshal(args)
	req := httptest.NewRequest("POST", "/api/v1/agent/tools/"+name, bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+c.token)
	w := httptest.NewRecorder()
	c.handler.ServeHTTP(w, req)
	var out map[string]any
	_ = json.Unmarshal(w.Body.Bytes(), &out)
	return w.Code, out
}

// list is one array of objects from a tool result.
func list(out map[string]any, field string) []map[string]any {
	items, _ := out[field].([]any)
	rows := make([]map[string]any, len(items))
	for i, it := range items {
		rows[i], _ = it.(map[string]any)
	}
	return rows
}

func TestChatListsTicketsAndProjects(t *testing.T) {
	c := newPersonaChat(t, "PAY")

	code, out := c.call(t, "list_tickets", map[string]any{})
	open := list(out, "tickets")
	if code != 200 || len(open) == 0 || out["total"] != float64(len(open)) || out["has_more"] != false {
		t.Fatalf("list_tickets = %d %v", code, out)
	}
	for _, tk := range open {
		if s := tk["status"]; s == "done" || s == "canceled" {
			t.Fatalf("default list has closed ticket %v", tk)
		}
	}

	code, out = c.call(t, "list_tickets", map[string]any{"status": []string{"in_review"}, "project": "pay"})
	for _, tk := range list(out, "tickets") {
		if tk["status"] != "in_review" || tk["project"] != "PAY" {
			t.Fatalf("status filter let through %v", tk)
		}
	}
	if code != 200 || len(list(out, "tickets")) == 0 {
		t.Fatalf("in_review = %d %v", code, out)
	}

	var agent string
	for _, tk := range open {
		if a, _ := tk["agent"].(string); a != "" {
			agent = a
			break
		}
	}
	code, out = c.call(t, "list_tickets", map[string]any{"agent": "@" + agent})
	if code != 200 || len(list(out, "tickets")) == 0 {
		t.Fatalf("agent %s = %d %v", agent, code, out)
	}
	for _, tk := range list(out, "tickets") {
		if tk["agent"] != agent {
			t.Fatalf("agent filter let through %v", tk)
		}
	}

	code, out = c.call(t, "list_tickets", map[string]any{"limit": 2, "offset": 1})
	page := list(out, "tickets")
	if code != 200 || len(page) != 2 || out["has_more"] != true || out["total"] != float64(len(open)) || page[0]["key"] != open[1]["key"] {
		t.Fatalf("page = %d %v", code, out)
	}

	if code, out = c.call(t, "list_tickets", map[string]any{"q": "PAY-21"}); code != 200 || len(list(out, "tickets")) == 0 {
		t.Fatalf("q = %d %v", code, out)
	}
	for _, bad := range []map[string]any{{"status": []string{"shipped"}}, {"project": "NOPE"}, {"agent": "nobody"}, {"limit": 500}} {
		if code, out := c.call(t, "list_tickets", bad); code != 422 {
			t.Errorf("list_tickets %v = %d %v, want 422", bad, code, out)
		}
	}

	// Across every project the board query stops at 500; the total says so.
	if _, err := c.pool.Exec(c.ctx, `INSERT INTO tickets (workspace_id, project_id, number, key, title)
		SELECT p.workspace_id, p.id, 1000 + n, 'BIL-' || (1000 + n), 'Bulk ' || n FROM projects p, generate_series(1, 500) n WHERE p.workspace_id = $1 AND p.key = 'BIL'`, c.ws); err != nil {
		t.Fatal(err)
	}
	if code, out := c.call(t, "list_tickets", map[string]any{}); code != 200 || out["total"] != "at least 500" || out["note"] == nil {
		t.Fatalf("capped total = %d %v", code, out["total"])
	}
	if code, out := c.call(t, "list_tickets", map[string]any{"project": "BIL", "limit": 1}); code != 200 || out["total"] != float64(500) {
		t.Fatalf("one project = %d %v", code, out["total"])
	}

	code, out = c.call(t, "list_projects", map[string]any{})
	projects := list(out, "projects")
	var keys []string
	for _, p := range projects {
		keys = append(keys, fmt.Sprint(p["key"]))
		if (p["key"] == "PAY") != (p["default"] == true) {
			t.Errorf("default flag on %v", p)
		}
	}
	if code != 200 || !strings.Contains(strings.Join(keys, ","), "PAY") || len(projects) < 2 {
		t.Fatalf("list_projects = %d %v", code, out)
	}
}

// A persona can fix what it scheduled: list, pause, move and delete the
// person's tasks, keeping what the person set in the app.
func TestChatManagesScheduledTasks(t *testing.T) {
	c := newPersonaChat(t, "PAY")
	code, out := c.call(t, "create_scheduled_task", map[string]any{"name": "Weekly check-in", "instructions": "Ask how the week went.", "frequency": "weekly", "weekdays": []int{1}, "at_time": "08:00", "timezone": "America/Los_Angeles"})
	if code != 200 {
		t.Fatalf("create_scheduled_task = %d %v", code, out)
	}
	id := fmt.Sprint(out["task_id"])
	// The person caps it in the app; a persona's change must keep that.
	task, err := c.q.GetScheduledTask(c.ctx, store.GetScheduledTaskParams{ID: uuid.MustParse(id), WorkspaceID: c.ws, UserID: c.user})
	if err != nil {
		t.Fatal(err)
	}
	maxMin := int32(30)
	maxCost := int64(2_000_000)
	if _, err := c.rs.UpdateScheduledTask(c.ctx, c.ws, c.user, task.ID, runs.ScheduledTaskInput{Revision: task.Revision, Name: task.Name, Kind: task.Kind, Instructions: task.Instructions, PersonaID: task.PersonaID, Project: "PAY",
		Enabled: true, MaxMinutes: &maxMin, MaxCostMicros: &maxCost, Schedule: runs.Schedule{Frequency: "weekly", Weekdays: []int32{1}, MonthDay: 1, AtTime: "08:00", Timezone: "America/Los_Angeles"}}); err != nil {
		t.Fatal(err)
	}

	code, out = c.call(t, "list_scheduled_tasks", map[string]any{})
	tasks := list(out, "tasks")
	if code != 200 || len(tasks) != 1 || tasks[0]["task_id"] != id || tasks[0]["at_time"] != "08:00" || tasks[0]["enabled"] != true || tasks[0]["project"] != "PAY" {
		t.Fatalf("list_scheduled_tasks = %d %v", code, out)
	}
	rev := tasks[0]["revision"]

	code, out = c.call(t, "update_scheduled_task", map[string]any{"task_id": id, "revision": rev, "enabled": false, "at_time": "07:30", "weekdays": []int{1, 4}})
	if code != 200 {
		t.Fatalf("update_scheduled_task = %d %v", code, out)
	}
	task, _ = c.q.GetScheduledTask(c.ctx, store.GetScheduledTaskParams{ID: task.ID, WorkspaceID: c.ws, UserID: c.user})
	if task.Enabled || task.AtTime != "07:30" || len(task.Weekdays) != 2 || task.NextRunAt != nil || task.Name != "Weekly check-in" || task.MaxMinutes == nil || *task.MaxMinutes != 30 || task.MaxCostMicros == nil || *task.MaxCostMicros != 2_000_000 || task.Instructions != "Ask how the week went." {
		t.Fatalf("after update: %+v", task)
	}
	if code, out := c.call(t, "update_scheduled_task", map[string]any{"task_id": id, "revision": rev, "name": "Stale"}); code != 409 {
		t.Fatalf("stale revision = %d %v", code, out)
	}
	if code, out := c.call(t, "update_scheduled_task", map[string]any{"task_id": id, "revision": task.Revision, "frequency": "hourly"}); code != 422 {
		t.Fatalf("bad frequency = %d %v", code, out)
	}

	if code, out := c.call(t, "delete_scheduled_task", map[string]any{"task_id": id}); code != 200 || out["state"] != "deleted" {
		t.Fatalf("delete_scheduled_task = %d %v", code, out)
	}
	if code, out := c.call(t, "delete_scheduled_task", map[string]any{"task_id": id}); code != 422 {
		t.Fatalf("delete again = %d %v", code, out)
	}
	if code, out := c.call(t, "list_scheduled_tasks", map[string]any{}); code != 200 || len(list(out, "tasks")) != 0 {
		t.Fatalf("after delete = %d %v", code, out)
	}
}

// A persona saves a link the person wants to keep and finds things in their
// Library again, but never their documents.
func TestChatSearchesLibraryAndSavesLinks(t *testing.T) {
	c := newPersonaChat(t, "")
	code, out := c.call(t, "save_link", map[string]any{"url": "https://www.youtube.com/watch?v=Z3Kal4Xazf4", "title": "Truth or Drink: Alan vs Sam", "note": "The one you said you'd rewatch."})
	if code != 200 || out["state"] != "saved" {
		t.Fatalf("save_link = %d %v", code, out)
	}
	saved := fmt.Sprint(out["item_id"])
	if code, out := c.call(t, "save_link", map[string]any{"url": "https://www.youtube.com/watch?v=Z3Kal4Xazf4"}); code != 200 || out["state"] != "already_saved" || fmt.Sprint(out["item_id"]) != saved {
		t.Fatalf("save again = %d %v", code, out)
	}
	if code, out := c.call(t, "save_link", map[string]any{"url": "https://example.com/rust/ownership/"}); code != 200 || out["title"] != "example.com/rust/ownership" {
		t.Fatalf("untitled link = %d %v", code, out)
	}
	for _, bad := range []string{"ftp://example.com/x", "https://user:pw@example.com/", "javascript:alert(1)", ""} {
		if code, out := c.call(t, "save_link", map[string]any{"url": bad}); code != 422 {
			t.Errorf("save_link %q = %d %v, want 422", bad, code, out)
		}
	}
	item, err := c.q.GetLibraryItem(c.ctx, store.GetLibraryItemParams{ID: uuid.MustParse(saved), WorkspaceID: c.ws, UserID: c.user})
	if err != nil || item.Kind != "link" || item.VideoID != "Z3Kal4Xazf4" || item.Site != "youtube.com" || item.LinkStatus != "to_read" || item.PersonaID == nil || *item.PersonaID != c.persona {
		t.Fatalf("saved item = %+v, %v", item, err)
	}

	// The person's own documents never reach a persona, even when they match.
	doc, err := c.q.CreateLibraryItem(c.ctx, store.CreateLibraryItemParams{WorkspaceID: c.ws, UserID: c.user, Kind: "document", Title: "Alan diary", Filename: "diary.md", ContentType: "text/markdown", SizeBytes: 12, BlobKey: "docs/diary"})
	if err != nil {
		t.Fatal(err)
	}
	code, out = c.call(t, "search_library", map[string]any{"q": "alan SAM"})
	items := list(out, "items")
	if code != 200 || len(items) != 1 || items[0]["item_id"] != saved || items[0]["link_status"] != "to_read" || items[0]["persona"] != "Hackerman" {
		t.Fatalf("search_library = %d %v", code, out)
	}
	if code, out := c.call(t, "search_library", map[string]any{"q": "alan"}); code != 200 || len(list(out, "items")) != 1 {
		t.Fatalf("documents leaked into search: %d %v", code, out)
	}
	if code, out := c.call(t, "search_library", map[string]any{"kind": "image"}); code != 200 || len(list(out, "items")) != 0 {
		t.Fatalf("kind filter = %d %v", code, out)
	}
	if code, out := c.call(t, "search_library", map[string]any{}); code != 200 || len(list(out, "items")) != 2 {
		t.Fatalf("newest = %d %v", code, out)
	}
	for _, bad := range []map[string]any{{"kind": "document"}, {"limit": 51}} {
		if code, out := c.call(t, "search_library", bad); code != 422 {
			t.Errorf("search_library %v = %d %v, want 422", bad, code, out)
		}
	}

	code, out = c.call(t, "read_library_item", map[string]any{"item_id": saved})
	got, _ := out["item"].(map[string]any)
	if code != 200 || got["note"] != "The one you said you'd rewatch." || got["chat_href"] != "/chat/"+c.chat.ID.String() || got["persona"] != "Hackerman" {
		t.Fatalf("read_library_item = %d %v", code, out)
	}
	if code, out := c.call(t, "read_library_item", map[string]any{"item_id": doc.ID}); code != 422 {
		t.Fatalf("read a document = %d %v", code, out)
	}
}

// A persona sees what's waiting on the person without deciding or marking
// anything.
func TestChatReadsTheInbox(t *testing.T) {
	c := newPersonaChat(t, "PAY")
	before, err := c.q.ListInbox(c.ctx, store.ListInboxParams{WorkspaceID: c.ws, UserID: c.user})
	if err != nil {
		t.Fatal(err)
	}
	open := 0
	kinds := map[string]int{}
	for _, r := range before {
		if !r.Resolved {
			open++
			kinds[r.Kind]++
		}
	}
	if open == 0 {
		t.Fatal("the demo workspace should have open Inbox items")
	}

	code, out := c.call(t, "list_inbox", map[string]any{"limit": 100})
	items := list(out, "items")
	if code != 200 || len(items) != min(open, 100) || out["unread"] != float64(before[0].UnreadCount) {
		t.Fatalf("list_inbox = %d %d items, want %d: %v", code, len(items), open, out["unread"])
	}
	for _, it := range items {
		if it["resolved"] == true || it["href"] == "" {
			t.Fatalf("item %v", it)
		}
	}
	var kind string
	for k := range kinds {
		kind = k
		break
	}
	if code, out := c.call(t, "list_inbox", map[string]any{"kind": kind, "limit": 100}); code != 200 || len(list(out, "items")) != kinds[kind] {
		t.Fatalf("kind %s = %d %v", kind, code, out)
	}
	code, out = c.call(t, "list_inbox", map[string]any{"project": "pay", "limit": 2})
	if code != 200 || len(list(out, "items")) > 2 {
		t.Fatalf("project = %d %v", code, out)
	}
	for _, it := range list(out, "items") {
		if it["project"] != "PAY" {
			t.Fatalf("project filter let through %v", it)
		}
	}
	for _, bad := range []map[string]any{{"project": "NOPE"}, {"limit": 101}} {
		if code, out := c.call(t, "list_inbox", bad); code != 422 {
			t.Errorf("list_inbox %v = %d %v, want 422", bad, code, out)
		}
	}

	after, err := c.q.ListInbox(c.ctx, store.ListInboxParams{WorkspaceID: c.ws, UserID: c.user})
	if err != nil {
		t.Fatal(err)
	}
	if len(after) == 0 || after[0].UnreadCount != before[0].UnreadCount {
		t.Fatalf("reading from chat changed what's unread: %d → %d", before[0].UnreadCount, after[0].UnreadCount)
	}
}

// The tutor can see where the person is: lessons finished, the one they're
// on, and checks they keep missing.
func TestChatReadsLearningProgress(t *testing.T) {
	c := newPersonaChat(t, "")
	code, out := c.call(t, "create_learning_module", map[string]any{"topic": "Rust ownership", "level": "some"})
	if code != 200 {
		t.Fatalf("create_learning_module = %d %v", code, out)
	}
	module := uuid.MustParse(fmt.Sprint(out["module_id"]))
	lesson := func(seq int32, key, status string) uuid.UUID {
		t.Helper()
		if err := c.q.CreateLearningLesson(c.ctx, store.CreateLearningLessonParams{CourseID: module, Seq: seq, Key: key, Title: "Lesson " + key, Objectives: []string{}, Prereqs: []string{}, Minutes: 10, Status: status}); err != nil {
			t.Fatal(err)
		}
		l, err := c.q.GetLearningLessonByKey(c.ctx, store.GetLearningLessonByKeyParams{CourseID: module, Key: key})
		if err != nil {
			t.Fatal(err)
		}
		return l.ID
	}
	check := func(lessonID uuid.UUID, prompt string, answers ...bool) {
		t.Helper()
		if err := c.q.CreateLearningCheck(c.ctx, store.CreateLearningCheckParams{LessonID: lessonID, Seq: 0, Objective: "o", Kind: "short", Prompt: prompt, Options: []string{}, Sources: []int32{}}); err != nil {
			t.Fatal(err)
		}
		ks, err := c.q.ListLearningChecks(c.ctx, module)
		if err != nil {
			t.Fatal(err)
		}
		for _, k := range ks {
			if k.Prompt != prompt {
				continue
			}
			for _, right := range answers {
				// Attempts read oldest first by id, which only orders across milliseconds.
				time.Sleep(2 * time.Millisecond)
				if _, err := c.q.CreateLearningAttempt(c.ctx, store.CreateLearningAttemptParams{CheckID: k.ID, UserID: c.user, Response: []string{"x"}, Correct: &right}); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	check(lesson(0, "borrow", "verified"), "Who owns the value after a move?", true)                  // right first time: solid
	check(lesson(1, "lifetimes", "verified"), "Why does this borrow outlive its owner?", false, true) // right in the end: complete
	check(lesson(2, "traits", "verified"), "What does Send promise?", false)                          // still missed
	lesson(3, "basics", "known")
	if _, err := c.q.SetLearningCourseState(c.ctx, store.SetLearningCourseStateParams{ID: module, State: "ready"}); err != nil {
		t.Fatal(err)
	}
	if err := c.q.SetLearningCurrentLesson(c.ctx, store.SetLearningCurrentLessonParams{ID: module, CurrentLesson: "traits"}); err != nil {
		t.Fatal(err)
	}

	code, out = c.call(t, "list_learning_modules", map[string]any{})
	mods := list(out, "modules")
	if code != 200 || len(mods) != 1 || mods[0]["topic"] != "Rust ownership" || mods[0]["current_lesson"] != "traits" || mods[0]["href"] != "/learn/"+module.String() {
		t.Fatalf("list_learning_modules = %d %v", code, out)
	}

	code, out = c.call(t, "get_learning_progress", map[string]any{"module_id": module})
	if code != 200 || out["studyable"] != float64(3) || out["complete"] != float64(2) || out["solid"] != float64(1) {
		t.Fatalf("get_learning_progress = %d %v", code, out)
	}
	progress := map[string]string{}
	for _, l := range list(out, "lessons") {
		progress[fmt.Sprint(l["key"])] = fmt.Sprint(l["progress"])
		if (l["key"] == "traits") != (l["current"] == true) {
			t.Errorf("current flag on %v", l)
		}
	}
	if progress["borrow"] != "solid" || progress["lifetimes"] != "complete" || progress["traits"] != "new" || progress["basics"] != "<nil>" {
		t.Fatalf("progress = %v", progress)
	}
	if missed, _ := out["still_missed"].([]any); len(missed) != 1 || missed[0] != "What does Send promise?" {
		t.Fatalf("still_missed = %v", out["still_missed"])
	}
	if code, out := c.call(t, "get_learning_progress", map[string]any{"module_id": uuid.New()}); code != 422 {
		t.Fatalf("unknown module = %d %v", code, out)
	}
}

// A persona sees what the person has connected, and which of it it may use
// here, without a connector's full address or any secret's value.
func TestChatListsConnectorsAndSecretNames(t *testing.T) {
	c := newPersonaChat(t, "")
	gh, err := c.q.CreateConnector(c.ctx, store.CreateConnectorParams{WorkspaceID: c.ws, UserID: c.user, Name: "GitHub", Slug: "github", Url: "https://api.githubcopilot.com/mcp/?token=leak-me", AuthKind: "token"})
	if err != nil {
		t.Fatal(err)
	}
	if err := c.q.AddConnectorPersona(c.ctx, store.AddConnectorPersonaParams{ConnectorID: gh.ID, PersonaID: c.persona}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.q.CreateConnector(c.ctx, store.CreateConnectorParams{WorkspaceID: c.ws, UserID: c.user, Name: "Calendar", Slug: "calendar", Url: "https://calendar.example.com/mcp", AuthKind: "oauth"}); err != nil {
		t.Fatal(err)
	}
	key, err := c.q.CreateUserSecret(c.ctx, store.CreateUserSecretParams{ID: uuid.New(), WorkspaceID: c.ws, UserID: c.user, Name: "Weather", Handle: "weather", Placement: "bearer", AllowedHosts: []string{"api.weather.example"},
		ReadPolicy: "allow", WritePolicy: "ask", Nonce: []byte("n"), Ciphertext: []byte("sealed-value")})
	if err != nil {
		t.Fatal(err)
	}
	if err := c.q.AddUserSecretPersona(c.ctx, store.AddUserSecretPersonaParams{SecretID: key.ID, PersonaID: c.persona}); err != nil {
		t.Fatal(err)
	}

	code, out := c.call(t, "list_connectors", map[string]any{})
	if raw, _ := json.Marshal(out); strings.Contains(string(raw), "leak-me") || strings.Contains(string(raw), "/mcp") {
		t.Fatalf("a connector's address leaked: %s", raw)
	}
	usable := map[string]bool{}
	for _, cn := range list(out, "connectors") {
		usable[fmt.Sprint(cn["slug"])] = cn["usable_here"] == true
		if cn["slug"] == "github" && (cn["host"] != "api.githubcopilot.com" || cn["status"] != "needs_sign_in") {
			t.Fatalf("github = %v", cn)
		}
	}
	if code != 200 || len(usable) != 2 || !usable["github"] || usable["calendar"] {
		t.Fatalf("list_connectors = %d %v", code, out)
	}

	code, out = c.call(t, "list_secret_names", map[string]any{})
	if raw, _ := json.Marshal(out); strings.Contains(string(raw), "sealed-value") {
		t.Fatalf("a secret leaked: %s", raw)
	}
	secrets := list(out, "secrets")
	if code != 200 || len(secrets) != 1 || secrets[0]["handle"] != "weather" || secrets[0]["usable_here"] != true || secrets[0]["expired"] != nil {
		t.Fatalf("list_secret_names = %d %v", code, out)
	}
}

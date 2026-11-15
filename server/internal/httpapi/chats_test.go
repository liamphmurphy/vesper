package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"maps"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/realtime"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

type chatEnv struct {
	t       *testing.T
	pool    *pgxpool.Pool
	q       *store.Queries
	srv     *httptest.Server
	hub     *realtime.Hub
	me      store.User
	payArt  uuid.UUID // a markdown artifact in PAY
	payKey  string    // a PAY ticket
	otherAr uuid.UUID // a markdown artifact in another project
	otherTk string    // a ticket in another project
	runs    *runs.Service
}

func newChatEnv(t *testing.T) *chatEnv { return newChatEnvWith(t, nil) }

// newChatEnvWith lets a test adjust the runs service (secrets, isolation).
func newChatEnvWith(t *testing.T, tweak func(*runs.Service)) *chatEnv {
	t.Helper()
	return newChatEnvServer(t, tweak, nil)
}

// newChatEnvServer also lets a test adjust the Server (e.g. blob storage)
// before it starts serving.
func newChatEnvServer(t *testing.T, tweak func(*runs.Service), tweakServer func(*Server)) *chatEnv {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	tr := &tracker.Service{Pool: pool}
	hub := realtime.New()
	hctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() { defer close(done); hub.Run(hctx, pool) }()
	t.Cleanup(func() { cancel(); <-done })
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts, ModelDiscovery: testChatModels}
	if tweak != nil {
		tweak(rs)
	}
	s := &Server{AnonymousAPI: true, Events: hub, Pool: pool, Q: q, Tracker: tr, Artifacts: arts, Agents: &agents.Service{Pool: pool}, Runs: rs,
		Wiki: &wiki.Service{Pool: pool, Artifacts: arts, Tracker: tr}, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	if tweakServer != nil {
		tweakServer(s)
	}
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	e := &chatEnv{t: t, pool: pool, q: q, srv: ts, hub: hub, me: me, runs: rs}
	scan := func(dst any, sql string) {
		if err := pool.QueryRow(ctx, sql).Scan(dst); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	scan(&e.payArt, `SELECT a.id FROM artifacts a JOIN artifact_versions v ON v.id=a.current_version_id JOIN projects p ON p.id=a.project_id
		WHERE p.key='PAY' AND v.body_md IS NOT NULL AND a.type<>'note' LIMIT 1`)
	scan(&e.payKey, `SELECT t.key FROM tickets t JOIN projects p ON p.id=t.project_id WHERE p.key='PAY' ORDER BY t.number LIMIT 1`)
	scan(&e.otherAr, `SELECT a.id FROM artifacts a JOIN artifact_versions v ON v.id=a.current_version_id JOIN projects p ON p.id=a.project_id
		WHERE p.key<>'PAY' AND v.body_md IS NOT NULL AND a.type<>'note' LIMIT 1`)
	// The demo's tickets are all in PAY: move one to another project.
	scan(&e.otherTk, `UPDATE tickets SET project_id=(SELECT id FROM projects WHERE key<>'PAY' ORDER BY key LIMIT 1)
		WHERE id=(SELECT t.id FROM tickets t JOIN projects p ON p.id=t.project_id WHERE p.key='PAY' AND t.key<>'`+e.payKey+`' ORDER BY t.number LIMIT 1) RETURNING key`)
	return e
}

func (e *chatEnv) do(method, path string, body any) (int, map[string]any) {
	e.t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, e.srv.URL+"/api/v1"+path, rd)
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(res.Body)
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

func (e *chatEnv) want(method, path string, body any, code int) map[string]any {
	e.t.Helper()
	got, out := e.do(method, path, body)
	if got != code {
		e.t.Fatalf("%s %s = %d, want %d: %v", method, path, got, code, out)
	}
	return out
}

func (e *chatEnv) invalid(method, path string, body any, field, contains string) {
	e.t.Helper()
	out := e.want(method, path, body, http.StatusUnprocessableEntity)
	if out["field"] != field || !strings.Contains(out["message"].(string), contains) {
		e.t.Fatalf("%s %s: field=%v message=%v, want field %q containing %q", method, path, out["field"], out["message"], field, contains)
	}
}

func (e *chatEnv) newChat(extra map[string]any) map[string]any {
	e.t.Helper()
	body := map[string]any{"project": "PAY"}
	maps.Copy(body, extra)
	return e.want("POST", "/chats", body, http.StatusCreated)
}

func ids(list any, key string) []string {
	var out []string
	for _, item := range list.([]any) {
		out = append(out, item.(map[string]any)[key].(string))
	}
	return out
}

func TestChatModelsCatalog(t *testing.T) {
	e := newChatEnv(t)
	res, err := http.Get(e.srv.URL + "/api/v1/chat-models")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var list []struct {
		Harness, Label    string
		Available         bool
		UnavailableReason string `json:"unavailable_reason"`
		Models            []struct {
			ID      string
			Default bool
			Efforts []string
		}
	}
	if err := json.NewDecoder(res.Body).Decode(&list); err != nil || res.StatusCode != 200 {
		t.Fatalf("%d %v", res.StatusCode, err)
	}
	if len(list) != 3 || list[0].Harness != "claude-code" || list[1].Harness != "codex" || list[2].Harness != "antigravity" || list[2].Label != "Antigravity" {
		t.Fatalf("catalog %+v", list)
	}
	for _, h := range list {
		defaults := 0
		for _, m := range h.Models {
			if m.Default {
				defaults++
			}
		}
		if !h.Available || defaults != 1 || len(h.Models) == 0 {
			t.Fatalf("harness %+v", h)
		}
	}
	if m := list[0].Models; len(m[0].Efforts) != len(agentdef.Efforts) || m[2].Efforts == nil || len(m[2].Efforts) != 0 {
		t.Fatalf("efforts %+v", m)
	}
}

func TestChatModelsReportsPendingDiscoveryAndRunnerCompletion(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	e.runs.RequireHarnessKey = true
	e.runs.ModelDiscovery = nil
	e.runs.Secrets = &secrets.Service{Q: e.q, Box: testBox(t)}
	l := &chatmodels.QueuedListings{Pool: e.pool, Wait: time.Millisecond, Poll: time.Millisecond}
	e.runs.PlanModels = l.Models
	if _, err := e.runs.Secrets.Set(ctx, e.me.WorkspaceID, e.me.ID, secrets.SetInput{Name: "harness:anthropic", Value: "sk-ant-oat01-test"}); err != nil {
		t.Fatal(err)
	}
	type harnessModels struct {
		Available bool                  `json:"available"`
		Checking  bool                  `json:"checking"`
		Models    []struct{ ID string } `json:"models"`
	}
	read := func() []harnessModels {
		t.Helper()
		res, err := http.Get(e.srv.URL + "/api/v1/chat-models")
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		var list []harnessModels
		if err := json.NewDecoder(res.Body).Decode(&list); err != nil || res.StatusCode != http.StatusOK || len(list) != 3 {
			t.Fatalf("catalog %d %+v err %v", res.StatusCode, list, err)
		}
		return list
	}
	list := read()
	if list[0].Available || !list[0].Checking || len(list[0].Models) != 0 || list[1].Checking {
		t.Fatalf("pending catalog %+v", list)
	}
	runnerID := "test-runner"
	claim, err := e.q.ClaimModelListing(ctx, &runnerID)
	if err != nil {
		t.Fatal(err)
	}
	models, _ := json.Marshal([]chatmodels.Model{{ID: "opus", Default: true}})
	if _, err := e.q.FinishModelListing(ctx, store.FinishModelListingParams{ClaimID: claim.ClaimID, Models: models}); err != nil {
		t.Fatal(err)
	}
	list = read()
	if !list[0].Available || list[0].Checking || len(list[0].Models) != 1 || list[0].Models[0].ID != "opus" {
		t.Fatalf("finished catalog %+v", list)
	}
}

func TestChatModelsUnavailableWithoutKey(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	cat := (&runs.Service{Pool: e.pool, RequireHarnessKey: true, ModelDiscovery: testChatModels}).ChatCatalog()
	list, err := cat.List(ctx, e.q, e.me.WorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	for _, h := range list[:2] {
		if h.Available || !strings.Contains(h.UnavailableReason, "harness:") {
			t.Fatalf("%+v should be unavailable", h)
		}
	}
	// Only the secret's existence is read: store one and codex turns available.
	if _, err := e.pool.Exec(ctx, `INSERT INTO secrets (workspace_id, name, nonce, ciphertext) VALUES ($1, 'harness:openai', '\x00', '\x00')`, e.me.WorkspaceID); err != nil {
		t.Fatal(err)
	}
	list, _ = cat.List(ctx, e.q, e.me.WorkspaceID)
	if list[0].Available || !list[1].Available || list[1].UnavailableReason != "" {
		t.Fatalf("after storing the codex key: %+v", list)
	}
}

func TestChatLifecycleAndArchive(t *testing.T) {
	e := newChatEnv(t)
	chat := e.newChat(map[string]any{"title": "Planning chat"})
	// Every chat runs as the workspace's Personal Assistant.
	def, err := e.q.AssistantAgent(context.Background(), e.me.WorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	id := chat["id"].(string)
	agent := chat["agent"].(map[string]any)
	if agent["id"] != def.ID.String() || chat["state"] != "idle" || chat["message_count"].(float64) != 0 || chat["project"] != "PAY" || chat["revision"].(float64) != 1 {
		t.Fatalf("created chat %v (default agent %s)", chat, def.ID)
	}
	if def.Kind != agents.KindAssistant {
		t.Fatalf("chat agent kind %q, want the assistant", def.Kind)
	}
	got := e.want("GET", "/chats/"+id, nil, 200)
	if got["title"] != "Planning chat" {
		t.Fatalf("get %v", got)
	}
	list := e.want("GET", "/chats", nil, 200)
	if cs := ids(list["chats"], "id"); len(cs) != 1 || cs[0] != id || list["has_more"] != false {
		t.Fatalf("list %v", list)
	}
	if n := len(e.want("GET", "/chats?project=BIL", nil, 200)["chats"].([]any)); n != 0 {
		t.Fatalf("project filter returned %d", n)
	}

	// Rename (revision-checked).
	renamed := e.want("PATCH", "/chats/"+id, map[string]any{"revision": 1, "title": "Renamed"}, 200)
	if renamed["title"] != "Renamed" || renamed["revision"].(float64) != 2 {
		t.Fatalf("rename %v", renamed)
	}
	e.want("PATCH", "/chats/"+id, map[string]any{"revision": 1, "title": "Stale"}, http.StatusConflict)
	e.invalid("PATCH", "/chats/"+id, map[string]any{"revision": 2, "title": "   "}, "title", "1–200")
	e.invalid("PATCH", "/chats/"+id, map[string]any{"revision": 2}, "title", "provide")

	// Global search (the ⌘K palette) finds the user's chats by title, scoped by project.
	chatHits := func(path string) (n int) {
		for _, h := range e.want("GET", path, nil, 200)["hits"].([]any) {
			if tg := h.(map[string]any)["target"].(map[string]any); tg["kind"] == "chat" && tg["href"] == "/chat/"+id {
				n++
			}
		}
		return n
	}
	if chatHits("/search?q=renam") != 1 || chatHits("/search?q=renam&project=PAY") != 1 || chatHits("/search?q=renam&project=BIL") != 0 {
		t.Fatal("search did not find the renamed chat in its project only")
	}

	// Archive: out of the default list, in ?archived=true; restore reverses it.
	e.want("PATCH", "/chats/"+id, map[string]any{"revision": 2, "archived": true}, 200)
	if n := len(e.want("GET", "/chats", nil, 200)["chats"].([]any)); n != 0 {
		t.Fatalf("archived chat still in the default list (%d)", n)
	}
	if chatHits("/search?q=renam") != 0 {
		t.Fatal("archived chat still in search")
	}
	arch := e.want("GET", "/chats?archived=true", nil, 200)
	if cs := ids(arch["chats"], "id"); len(cs) != 1 || cs[0] != id {
		t.Fatalf("archived list %v", arch)
	}
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi"}, http.StatusConflict) // archived
	e.want("PATCH", "/chats/"+id, map[string]any{"revision": 3, "archived": false}, 200)
	if cs := ids(e.want("GET", "/chats", nil, 200)["chats"], "id"); len(cs) != 1 {
		t.Fatalf("restored chat missing: %v", cs)
	}

	// Pagination: 51 chats → a page of 50 with has_more, then the rest at offset 50.
	for range 50 {
		e.newChat(nil)
	}
	page := e.want("GET", "/chats", nil, 200)
	if len(page["chats"].([]any)) != 50 || page["has_more"] != true {
		t.Fatalf("first page %d has_more=%v", len(page["chats"].([]any)), page["has_more"])
	}
	rest := e.want("GET", "/chats?offset=50", nil, 200)
	if len(rest["chats"].([]any)) != 1 || rest["has_more"] != false {
		t.Fatalf("second page %v", rest)
	}
	e.invalid("POST", "/chats", map[string]any{"project": "NOPE"}, "project", "unknown")
	e.invalid("POST", "/chats", map[string]any{"project": "PAY", "harness": "vim"}, "harness", "unknown")
	e.invalid("POST", "/chats", map[string]any{"project": "PAY", "model": "gpt-9000"}, "model", "unknown")
	e.invalid("POST", "/chats", map[string]any{"project": "PAY", "message": map[string]any{"body": "  "}}, "body", "1–100000")

	e.want("DELETE", "/chats/"+id, nil, http.StatusNoContent)
	e.want("GET", "/chats/"+id, nil, http.StatusNotFound)
}

func TestChatUnknownAndForeignChatsAre404(t *testing.T) {
	e := newChatEnv(t)
	other := uuid.New().String()
	for _, c := range []struct{ method, path string }{
		{"GET", "/chats/" + other}, {"PATCH", "/chats/" + other}, {"DELETE", "/chats/" + other},
		{"GET", "/chats/" + other + "/messages"}, {"POST", "/chats/" + other + "/messages"}, {"POST", "/chats/" + other + "/cancel"},
	} {
		e.want(c.method, c.path, map[string]any{"revision": 1, "title": "x", "body": "x"}, http.StatusNotFound)
	}
	// A chat created by someone else in the same workspace is also invisible.
	chat := e.newChat(map[string]any{"message": map[string]any{"body": "hello"}})
	id := chat["id"].(string)
	var stranger uuid.UUID
	if err := e.pool.QueryRow(context.Background(), "SELECT id FROM users WHERE id<>$1 AND workspace_id=$2 LIMIT 1", e.me.ID, e.me.WorkspaceID).Scan(&stranger); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET created_by=$1", stranger); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ method, path string }{
		{"GET", "/chats/" + id}, {"PATCH", "/chats/" + id}, {"DELETE", "/chats/" + id},
		{"GET", "/chats/" + id + "/messages"}, {"POST", "/chats/" + id + "/messages"}, {"POST", "/chats/" + id + "/cancel"},
	} {
		e.want(c.method, c.path, map[string]any{"revision": 1, "title": "x", "body": "x"}, http.StatusNotFound)
	}
	if n := len(e.want("GET", "/chats", nil, 200)["chats"].([]any)); n != 0 {
		t.Fatalf("list leaked %d foreign chats", n)
	}
	for _, h := range e.want("GET", "/search?q=hello", nil, 200)["hits"].([]any) {
		if h.(map[string]any)["target"].(map[string]any)["kind"] == "chat" {
			t.Fatalf("search leaked a foreign chat: %v", h)
		}
	}
}

func TestChatMessagesPostCancelAndHistory(t *testing.T) {
	e := newChatEnv(t)
	chat := e.newChat(map[string]any{"message": map[string]any{"body": "First question\nwith detail"}})
	id := chat["id"].(string)
	if chat["state"] != "running" || chat["title"] != "First question" || chat["message_count"].(float64) != 1 || chat["current_run_id"] == nil {
		t.Fatalf("chat with first message %v", chat)
	}
	// A turn is queued: posting again replaces it (an interruption before the
	// reply started), and history shows both user messages.
	second := e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "second"}, http.StatusAccepted)
	if m := second["message"].(map[string]any); second["chat"].(map[string]any)["state"] != "running" || m["run_id"] == nil {
		t.Fatalf("interrupting post %v", second)
	}
	hist := e.want("GET", "/chats/"+id+"/messages", nil, 200)
	msgs := hist["messages"].([]any)
	first := msgs[0].(map[string]any)
	if len(msgs) != 2 || first["role"] != "user" || first["seq"].(float64) != 1 || first["author"] == nil || hist["has_more"] != false ||
		first["harness"] == nil || first["model"] == nil || first["run_id"] == nil || len(first["context_refs"].([]any)) != 0 {
		t.Fatalf("history %v", hist)
	}

	// Cancel returns the chat to idle; a second cancel has nothing to stop.
	cancelled := e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	if cancelled["state"] != "idle" {
		t.Fatalf("cancel %v", cancelled)
	}
	e.want("POST", "/chats/"+id+"/cancel", nil, http.StatusConflict)

	// Post more messages; seq-based paging.
	for i := range 3 {
		res := e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "again"}, http.StatusAccepted)
		if res["chat"].(map[string]any)["state"] != "running" || res["message"].(map[string]any)["seq"].(float64) != float64(i+3) {
			t.Fatalf("post %d: %v", i, res)
		}
		e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	}
	seqs := func(path string) ([]float64, bool) {
		out := e.want("GET", path, nil, 200)
		var s []float64
		for _, m := range out["messages"].([]any) {
			s = append(s, m.(map[string]any)["seq"].(float64))
		}
		return s, out["has_more"].(bool)
	}
	if s, more := seqs("/chats/" + id + "/messages?limit=2"); len(s) != 2 || s[0] != 4 || s[1] != 5 || !more {
		t.Fatalf("newest page %v more=%v", s, more)
	}
	if s, more := seqs("/chats/" + id + "/messages?limit=2&before=3"); len(s) != 2 || s[0] != 1 || s[1] != 2 || more {
		t.Fatalf("older page %v more=%v", s, more)
	}
	if s, _ := seqs("/chats/" + id + "/messages?after=2"); len(s) != 3 || s[0] != 3 || s[2] != 5 {
		t.Fatalf("after %v", s)
	}
	e.want("GET", "/chats/"+id+"/messages?limit=0", nil, http.StatusUnprocessableEntity)
	e.want("GET", "/chats/"+id+"/messages?limit=1001", nil, http.StatusUnprocessableEntity)
	e.invalid("POST", "/chats/"+id+"/messages", map[string]any{"body": ""}, "body", "1–100000")
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "x", "context_refs": 5}, http.StatusBadRequest)

	// Delete cancels the running turn first and removes the messages; its run stays.
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "last"}, http.StatusAccepted)
	var run uuid.UUID
	_ = e.pool.QueryRow(context.Background(), "SELECT current_run_id FROM chat_sessions WHERE id=$1", id).Scan(&run)
	e.want("DELETE", "/chats/"+id, nil, http.StatusNoContent)
	var state string
	if err := e.pool.QueryRow(context.Background(), "SELECT state FROM runs WHERE id=$1", run).Scan(&state); err != nil || state != "cancelled" {
		t.Fatalf("run after delete: %q %v", state, err)
	}
	var n int
	_ = e.pool.QueryRow(context.Background(), "SELECT count(*) FROM chat_messages WHERE session_id=$1", id).Scan(&n)
	if n != 0 {
		t.Fatalf("%d messages survived delete", n)
	}
}

func TestChatSelectionValidation(t *testing.T) {
	e := newChatEnv(t)
	chat := e.newChat(nil)
	id := chat["id"].(string)
	harness0, model0 := chat["harness"], chat["model"]
	unchanged := func() {
		t.Helper()
		got := e.want("GET", "/chats/"+id, nil, 200)
		if got["harness"] != harness0 || got["model"] != model0 || got["state"] != "idle" || got["message_count"].(float64) != 0 {
			t.Fatalf("selection or state changed after a rejected post: %v", got)
		}
	}
	e.invalid("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "harness": "emacs"}, "harness", "unknown")
	unchanged()
	e.invalid("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "model": "not-a-model"}, "model", "unknown")
	unchanged()
	e.invalid("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "harness": "codex", "model": "opus-5.5"}, "model", "unknown")
	unchanged()

	// A valid selection is stored on the chat; the harness default model fills in.
	res := e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "harness": "codex"}, http.StatusAccepted)
	c := res["chat"].(map[string]any)
	if c["harness"] != "codex" || c["model"] != "gpt-5-codex" {
		t.Fatalf("stored selection %v", c)
	}
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	res = e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "model": "gpt-5-mini"}, http.StatusAccepted)
	if m := res["chat"].(map[string]any)["model"]; m != "gpt-5-mini" {
		t.Fatalf("model-only change %v", res)
	}
	// The segment run is created on the stored harness; a same-harness model
	// change keeps the run and records the last model used (LAZYAGENTS-10).
	var h, m string
	if err := e.pool.QueryRow(context.Background(), "SELECT harness, model FROM runs WHERE id=(SELECT current_run_id FROM chat_sessions WHERE id=$1)", id).Scan(&h, &m); err != nil || h != "codex" || m != "gpt-5-mini" {
		t.Fatalf("segment run %s/%s %v", h, m, err)
	}

	// Creating a chat validates and stores the selection too.
	created := e.newChat(map[string]any{"harness": "claude-code", "model": "haiku-5.5"})
	if created["harness"] != "claude-code" || created["model"] != "haiku-5.5" {
		t.Fatalf("create selection %v", created)
	}
}

func TestChatEffort(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	runEffort := func(id string) (runID, effort string) {
		t.Helper()
		if err := e.pool.QueryRow(ctx, `SELECT r.id::text, coalesce(r.resolved_spec->'harness_options'->>'effort', '')
			FROM runs r JOIN chat_sessions c ON c.current_run_id = r.id WHERE c.id = $1`, id).Scan(&runID, &effort); err != nil {
			t.Fatal(err)
		}
		return runID, effort
	}
	chat := e.newChat(map[string]any{"harness": "claude-code", "model": "opus-5.5", "effort": "xhigh"})
	id := chat["id"].(string)
	if chat["effort"] != "xhigh" {
		t.Fatalf("created effort %v", chat["effort"])
	}
	e.invalid("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "model": "haiku-5.5", "effort": "low"}, "effort", "doesn't offer")

	// The first segment runs at the chat's effort.
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi"}, http.StatusAccepted)
	run0, eff := runEffort(id)
	if eff != "xhigh" {
		t.Fatalf("segment effort %q", eff)
	}
	// A same-harness change keeps the segment and rewrites its spec.
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	res := e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "effort": "max"}, http.StatusAccepted)
	if res["chat"].(map[string]any)["effort"] != "max" {
		t.Fatalf("stored effort %v", res["chat"])
	}
	if run, eff := runEffort(id); run != run0 || eff != "max" {
		t.Fatalf("run %s effort %q, want %s max", run, eff, run0)
	}
	// default clears it: the chat goes automatic and "hi" runs at the lowest effort.
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	res = e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "effort": "default"}, http.StatusAccepted)
	if _, ok := res["chat"].(map[string]any)["effort"]; ok {
		t.Fatalf("effort not cleared %v", res["chat"])
	}
	if run, eff := runEffort(id); run != run0 || eff != "low" {
		t.Fatalf("run %s effort %q, want %s low", run, eff, run0)
	}
	// Switching to a model without the chat's effort drops it.
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "harness": "codex", "model": "gpt-5-codex", "effort": "max"}, http.StatusAccepted)
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	res = e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "model": "gpt-5-mini"}, http.StatusAccepted)
	if _, ok := res["chat"].(map[string]any)["effort"]; ok {
		t.Fatalf("unoffered effort kept %v", res["chat"])
	}
}

// An automatic chat starts a fresh session on the tier its message calls for,
// only moves up while the session runs, and stops routing once a model is picked.
func TestChatAutoModel(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	e.want("GET", "/chat-models", nil, 200) // lists the catalog AutoModel routes within
	runModel := func(id string) (runID, model string) {
		t.Helper()
		if err := e.pool.QueryRow(ctx, `SELECT r.id::text, r.model FROM runs r JOIN chat_sessions c ON c.current_run_id = r.id WHERE c.id = $1`, id).Scan(&runID, &model); err != nil {
			t.Fatal(err)
		}
		return runID, model
	}
	post := func(id string, body map[string]any) map[string]any {
		t.Helper()
		res := e.want("POST", "/chats/"+id+"/messages", body, http.StatusAccepted)
		return res["chat"].(map[string]any)
	}

	chat := e.newChat(map[string]any{"harness": "claude-code", "model": "auto"})
	id := chat["id"].(string)
	if chat["auto_model"] != true || chat["model"] != "opus-5.5" {
		t.Fatalf("created %v", chat)
	}
	// A greeting starts the session on the small model.
	if c := post(id, map[string]any{"body": "hi"}); c["model"] != "haiku-5.5" || c["auto_model"] != true {
		t.Fatalf("fresh light turn %v", c)
	}
	run0, m := runModel(id)
	if m != "haiku-5.5" {
		t.Fatalf("segment model %q", m)
	}
	// Real work moves the same session up.
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	post(id, map[string]any{"body": "fix the failing test in chat.go"})
	if run, m := runModel(id); run != run0 || m != "opus-5.5" {
		t.Fatalf("run %s model %q, want %s opus-5.5", run, m, run0)
	}
	// A light turn doesn't step back down mid-session.
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	post(id, map[string]any{"body": "thanks"})
	if _, m := runModel(id); m != "opus-5.5" {
		t.Fatalf("stepped down to %q", m)
	}
	// Picking a model turns routing off; auto turns it back on.
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	if c := post(id, map[string]any{"body": "hi", "model": "sonnet-5.5"}); c["auto_model"] != nil || c["model"] != "sonnet-5.5" {
		t.Fatalf("picked model %v", c)
	}
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	if c := post(id, map[string]any{"body": "fix it", "model": "auto"}); c["auto_model"] != true || c["model"] != "sonnet-5.5" {
		t.Fatalf("re-enabled %v", c)
	}

	// Without auto a chat keeps the model it was given.
	if c := e.newChat(nil); c["auto_model"] != nil {
		t.Fatalf("default chat routes its model: %v", c)
	}
}

// Each reply shows the effort its turn ran at, even after a later turn changes
// the run's, and an automatic chat's replies say why Vesper picked it.
func TestChatRepliesShowTheirTurnsEffort(t *testing.T) {
	e := newChatEnv(t)
	id := e.newChat(map[string]any{"harness": "claude-code", "model": "opus-5.5"})["id"].(string)
	// reply stands in for the runner: it ends the latest turn with a reply.
	reply := func() {
		t.Helper()
		var runID, turnID uuid.UUID
		if err := e.pool.QueryRow(t.Context(), `UPDATE run_turns SET status = 'done', ended_at = now() WHERE id = (
			SELECT t.id FROM run_turns t JOIN chat_sessions c ON c.current_run_id = t.run_id WHERE c.id = $1 ORDER BY t.seq DESC LIMIT 1)
			RETURNING run_id, id`, id).Scan(&runID, &turnID); err != nil {
			t.Fatal(err)
		}
		if _, err := e.q.AppendChatMessage(t.Context(), store.AppendChatMessageParams{SessionID: uuid.MustParse(id), Role: "assistant", BodyMd: "ok",
			RunID: &runID, RunTurnID: &turnID, ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
			t.Fatal(err)
		}
	}
	replies := func() []map[string]any {
		t.Helper()
		var out []map[string]any
		for _, m := range e.want("GET", "/chats/"+id+"/messages", nil, 200)["messages"].([]any) {
			if m := m.(map[string]any); m["role"] == "assistant" {
				out = append(out, m)
			}
		}
		return out
	}

	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi"}, http.StatusAccepted)
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	reply()
	// A retry steps the level up from the message's own.
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "that's wrong"}, http.StatusAccepted)
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	reply()
	// The runner's image follow-up runs on at the turn's effort and level.
	var runID uuid.UUID
	if err := e.pool.QueryRow(t.Context(), `SELECT current_run_id FROM chat_sessions WHERE id = $1`, id).Scan(&runID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.StartTurn(t.Context(), store.StartTurnParams{RunID: runID, Trigger: runs.TriggerImageFollowup}); err != nil {
		t.Fatal(err)
	}
	reply()
	// A chosen effort has no level: the person picked it.
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi", "effort": "max"}, http.StatusAccepted)
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	reply()

	got := replies()
	if len(got) != 4 {
		t.Fatalf("replies %v", got)
	}
	for i, want := range []struct{ effort, level, reasons any }{
		{"low", "low", nil},
		{"medium", "medium", []any{"effort_mismatch"}},
		{"medium", "medium", nil},
		{"max", nil, nil},
	} {
		m := got[i]
		if m["effort"] != want.effort || m["effort_level"] != want.level || fmt.Sprint(m["effort_reasons"]) != fmt.Sprint(want.reasons) {
			t.Errorf("reply %d: effort %v level %v reasons %v, want %v %v %v", i, m["effort"], m["effort_level"], m["effort_reasons"], want.effort, want.level, want.reasons)
		}
	}
}

func TestChatContextRefsResolveAcrossWorkspace(t *testing.T) {
	e := newChatEnv(t)
	id := e.newChat(nil)["id"].(string)
	post := func(refs ...map[string]any) (int, map[string]any) {
		return e.do("POST", "/chats/"+id+"/messages", map[string]any{"body": "look at these", "context_refs": refs})
	}
	count := func() int {
		var n int
		_ = e.pool.QueryRow(context.Background(), "SELECT count(*) FROM chat_messages WHERE session_id=$1", id).Scan(&n)
		return n
	}
	// The workspace is the boundary: an artifact in someone else's workspace
	// resolves as unknown.
	ctx := context.Background()
	var foreignWS, foreignProject, foreignArt uuid.UUID
	if err := e.pool.QueryRow(ctx, `INSERT INTO workspaces(name,slug) VALUES('Elsewhere','elsewhere') RETURNING id`).Scan(&foreignWS); err != nil {
		t.Fatal(err)
	}
	if err := e.pool.QueryRow(ctx, `INSERT INTO projects(workspace_id,key,name,color) VALUES($1,'ELSE','Elsewhere','green') RETURNING id`, foreignWS).Scan(&foreignProject); err != nil {
		t.Fatal(err)
	}
	if err := e.pool.QueryRow(ctx, `UPDATE artifacts SET workspace_id=$1, project_id=$2, epic_id=NULL
		WHERE id=(SELECT a.id FROM artifacts a JOIN artifact_versions v ON v.id=a.current_version_id
			WHERE a.type<>'note' AND v.body_md IS NOT NULL AND a.id NOT IN ($3,$4) LIMIT 1) RETURNING id`, foreignWS, foreignProject, e.payArt, e.otherAr).Scan(&foreignArt); err != nil {
		t.Fatal(err)
	}
	missing := uuid.New().String()
	for _, c := range []struct {
		name, contains string
		ref            map[string]any
	}{
		{"unknown artifact", missing, map[string]any{"kind": "artifact", "id": missing}},
		{"artifact in another workspace", foreignArt.String(), map[string]any{"kind": "artifact", "id": foreignArt.String()}},
		{"unknown ticket", "NOPE-1", map[string]any{"kind": "ticket", "key": "NOPE-1"}},
		{"unknown wiki path", "no/such/note", map[string]any{"kind": "page", "key": "no/such/note"}},
		{"section anchor not found", "nope-anchor", map[string]any{"kind": "section", "id": e.payArt.String(), "anchor": "nope-anchor"}},
		{"unknown kind", "epic", map[string]any{"kind": "epic", "key": "x"}},
		{"ticket with an id", "ticket", map[string]any{"kind": "ticket", "key": e.payKey, "id": missing}},
	} {
		code, out := post(c.ref)
		if code != http.StatusUnprocessableEntity || out["field"] != "context_refs" || !strings.Contains(out["message"].(string), c.contains) {
			t.Fatalf("%s: %d %v", c.name, code, out)
		}
	}
	// One bad ref among good ones queues nothing.
	code, _ := post(map[string]any{"kind": "artifact", "id": e.payArt.String()}, map[string]any{"kind": "ticket", "key": "NOPE-1"})
	if code != http.StatusUnprocessableEntity || count() != 0 {
		t.Fatalf("partial queue: %d, %d messages", code, count())
	}
	var runs int
	_ = e.pool.QueryRow(context.Background(), "SELECT count(*) FROM runs WHERE purpose='chat'").Scan(&runs)
	if runs != 0 {
		t.Fatalf("%d chat runs were created", runs)
	}
	many := make([]map[string]any, 21)
	for i := range many {
		many[i] = map[string]any{"kind": "ticket", "key": e.payKey}
	}
	if code, _ := post(many...); code != http.StatusUnprocessableEntity && code != http.StatusBadRequest {
		t.Fatalf("21 refs: %d", code)
	}

	// Good refs are stored normalized on the message.
	code, out := post(map[string]any{"kind": "artifact", "id": e.payArt.String()}, map[string]any{"kind": "ticket", "key": e.payKey})
	if code != http.StatusAccepted {
		t.Fatalf("good refs: %d %v", code, out)
	}
	refs := out["message"].(map[string]any)["context_refs"].([]any)
	if len(refs) != 2 || refs[0].(map[string]any)["kind"] != "artifact" || refs[1].(map[string]any)["key"] != e.payKey {
		t.Fatalf("stored refs %v", refs)
	}

	// The attached project doesn't limit what the person can attach: they can
	// open any project's documents anyway, so a chat can read them too.
	otherProject := []map[string]any{{"kind": "artifact", "id": e.otherAr.String()}, {"kind": "ticket", "key": e.otherTk}}
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "and these", "context_refs": otherProject}, http.StatusAccepted)
	noProject := e.want("POST", "/chats", map[string]any{}, http.StatusCreated)["id"].(string)
	payRefs := []map[string]any{{"kind": "artifact", "id": e.payArt.String()}, {"kind": "ticket", "key": e.payKey}}
	e.want("POST", "/chats/"+noProject+"/messages", map[string]any{"body": "look", "context_refs": payRefs}, http.StatusAccepted)
}

// sseEvents streams /events payloads.
func (e *chatEnv) sseEvents(ctx context.Context) <-chan map[string]any {
	e.t.Helper()
	req, _ := http.NewRequestWithContext(ctx, "GET", e.srv.URL+"/events", nil)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	ch := make(chan map[string]any, 256)
	go func() {
		defer res.Body.Close()
		sc := bufio.NewScanner(res.Body)
		for sc.Scan() {
			if data, ok := strings.CutPrefix(sc.Text(), "data: "); ok {
				var ev map[string]any
				if json.Unmarshal([]byte(data), &ev) == nil {
					ch <- ev
				}
			}
		}
		_ = sc.Err() // the stream ends when the test's context is cancelled
	}()
	return ch
}

func hasChat(ev map[string]any, id string) bool {
	if ev["type"] != "chat.updated" {
		return false
	}
	for _, v := range ev["ids"].([]any) {
		if v == id {
			return true
		}
	}
	return false
}

// waitChat reports whether a chat.updated for id arrives within d.
func waitChat(ch <-chan map[string]any, id string, d time.Duration) bool {
	timeout := time.After(d)
	for {
		select {
		case ev := <-ch:
			if hasChat(ev, id) {
				return true
			}
		case <-timeout:
			return false
		}
	}
}

func TestChatUpdatedReachesSSE(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	events := e.sseEvents(ctx)
	// The hub's LISTEN may still be starting: a zero-row statement fires the
	// statement trigger with no ids, so poll with it until an event arrives.
	ready := false
	for i := 0; i < 50 && !ready; i++ {
		if _, err := e.pool.Exec(ctx, "UPDATE chat_sessions SET title=title WHERE false"); err != nil {
			t.Fatal(err)
		}
		timeout := time.After(100 * time.Millisecond)
	wait:
		for {
			select {
			case ev := <-events:
				ready = ev["type"] == "chat.updated"
				if ready {
					break wait
				}
			case <-timeout:
				break wait
			}
		}
	}
	if !ready {
		t.Fatal("hub never started listening")
	}

	chat := e.newChat(nil)
	id := chat["id"].(string)
	// (the creating request returned; the commit has been notified within 1s)
	if !waitChat(events, id, time.Second) {
		t.Fatal("creating a chat produced no chat.updated with its id within 1s")
	}
	// Drain stragglers from the create so the post's event is its own.
	for waitChat(events, id, 150*time.Millisecond) {
	}
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hello"}, http.StatusAccepted)
	if !waitChat(events, id, time.Second) {
		t.Fatal("posting a message produced no chat.updated with the chat id within 1s")
	}
}

// Citation fields beyond target (version and section) survive the API so the
// Sources footer can link to the exact version that was read (LAZYAGENTS-13).
func TestChatMessageCitationFields(t *testing.T) {
	e := newChatEnv(t)
	id := e.newChat(nil)["id"].(string)
	cite := `[{"target":{"kind":"section","title":"Spec","anchor":"retries"},"artifact_id":"` + e.payArt.String() +
		`","title":"Spec","version_id":"` + e.payArt.String() + `","version":"v2","section":"retries"}]`
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO chat_messages (session_id, seq, role, body_md, context_refs, citations)
		VALUES ($1, 1, 'assistant', 'answer', '[]', $2)`, id, cite); err != nil {
		t.Fatal(err)
	}
	got := e.want("GET", "/chats/"+id+"/messages", nil, 200)
	c := got["messages"].([]any)[0].(map[string]any)["citations"].([]any)[0].(map[string]any)
	if c["version"] != "v2" || c["section"] != "retries" || c["version_id"] != e.payArt.String() || c["artifact_id"] != e.payArt.String() || c["target"].(map[string]any)["anchor"] != "retries" {
		t.Fatalf("citation %v", c)
	}
}

func TestChatRunDetail(t *testing.T) {
	e := newChatEnv(t)
	created := e.newChat(map[string]any{"message": map[string]any{"body": "hello"}})
	runID, ok := created["current_run_id"].(string)
	if !ok {
		t.Fatalf("chat has no run: %v", created)
	}
	detail := e.want("GET", "/runs/"+runID, nil, 200)
	run := detail["run"].(map[string]any)
	if run["id"] != runID {
		t.Fatalf("wrong run: %v", detail)
	}
	if _, ok := run["planning_id"]; ok {
		t.Fatalf("chat treated as a planning run: %v", run)
	}
}

// Model selection tests use a provider fixture instead of live credentials.
func testChatModels(_ context.Context, harness, _ string) ([]chatmodels.Model, error) {
	ids := []string{"opus-5.5", "sonnet-5.5", "haiku-5.5"}
	if harness == "codex" {
		ids = []string{"gpt-5-codex", "gpt-5-mini"}
	}
	models := []chatmodels.Model{}
	for i, id := range ids {
		efforts := agentdef.Efforts
		switch id {
		case "haiku-5.5":
			efforts = []string{}
		case "gpt-5-mini":
			efforts = []string{"low", "medium", "high"}
		}
		models = append(models, chatmodels.Model{ID: id, Label: id, Default: i == 0, Efforts: efforts})
	}
	return models, nil
}

// A turn that failed ends in a system message bound to that turn, which carries
// its turn_seq so the chat can keep the turn's steps beside it; a system note
// with no turn (a switch, a persona joining) has none, and neither has effort.
func TestFailedTurnSystemMessageCarriesItsTurn(t *testing.T) {
	e := newChatEnv(t)
	id := e.newChat(map[string]any{"harness": "claude-code", "model": "opus-5.5"})["id"].(string)
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "hi"}, http.StatusAccepted)
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	var runID, turnID uuid.UUID
	var seq int
	if err := e.pool.QueryRow(t.Context(), `SELECT t.run_id, t.id, t.seq FROM run_turns t JOIN chat_sessions c ON c.current_run_id = t.run_id
		WHERE c.id = $1 ORDER BY t.seq DESC LIMIT 1`, id).Scan(&runID, &turnID, &seq); err != nil {
		t.Fatal(err)
	}
	for _, p := range []store.AppendChatMessageParams{
		{SessionID: uuid.MustParse(id), Role: "system", BodyMd: "The chat turn stopped (exit 1).", RunID: &runID, RunTurnID: &turnID},
		{SessionID: uuid.MustParse(id), Role: "system", BodyMd: "Switched model.", RunID: &runID},
	} {
		p.ContextRefs, p.Citations = []byte("[]"), []byte("[]")
		if _, err := e.q.AppendChatMessage(t.Context(), p); err != nil {
			t.Fatal(err)
		}
	}
	var system []map[string]any
	for _, m := range e.want("GET", "/chats/"+id+"/messages", nil, 200)["messages"].([]any) {
		if m := m.(map[string]any); m["role"] == "system" {
			system = append(system, m)
		}
	}
	if len(system) < 2 {
		t.Fatalf("system messages %v", system)
	}
	failed, note := system[len(system)-2], system[len(system)-1]
	if failed["turn_seq"] != float64(seq) {
		t.Errorf("failed turn's message turn_seq = %v, want %d", failed["turn_seq"], seq)
	}
	if _, ok := failed["effort"]; ok {
		t.Errorf("a system message has no effort: %v", failed)
	}
	if _, ok := note["turn_seq"]; ok {
		t.Errorf("a note without a turn has no turn_seq: %v", note)
	}
}

func TestChatSecondOpinionEndpoint(t *testing.T) {
	e := newChatEnv(t)
	id := e.newChat(map[string]any{"harness": "claude-code", "model": "opus-5.5"})["id"].(string)
	e.want("POST", "/chats/"+id+"/messages", map[string]any{"body": "check mutex usage"}, http.StatusAccepted)
	chatUUID := uuid.MustParse(id)
	chatRow, err := e.q.GetChatSession(t.Context(), store.GetChatSessionParams{ID: chatUUID, WorkspaceID: e.me.WorkspaceID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.SetChatRunState(t.Context(), store.SetChatRunStateParams{ID: chatUUID, CurrentRunID: chatRow.CurrentRunID, State: "idle"}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.AppendChatMessage(t.Context(), store.AppendChatMessageParams{
		SessionID: chatUUID, Role: "assistant", BodyMd: "Looks safe.", ContextRefs: []byte("[]"), Citations: []byte("[]"),
	}); err != nil {
		t.Fatal(err)
	}

	created := e.want("POST", "/chats/"+id+"/asides", map[string]any{
		"body":           "double check edge cases",
		"harness":        "codex",
		"model":          "gpt-5-codex",
		"second_opinion": true,
	}, http.StatusCreated)
	if created["second_opinion"] != true || created["harness"] != "codex" || created["model"] != "gpt-5-codex" {
		t.Fatalf("unexpected POST aside response: %v", created)
	}
	if created["anchor_message_id"] == nil {
		t.Fatalf("expected auto-anchored second opinion: %v", created)
	}
	list := e.want("GET", "/chats/"+id+"/asides", nil, http.StatusOK)["asides"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["second_opinion"] != true {
		t.Fatalf("GET asides missing second_opinion: %v", list)
	}
	parent := e.want("GET", "/chats/"+id, nil, http.StatusOK)
	if parent["harness"] != "claude-code" || parent["model"] != "opus-5.5" {
		t.Fatalf("parent chat was mutated: %v", parent)
	}
}

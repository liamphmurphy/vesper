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

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// A chat run's token reaches context and tracker tools across every project.
func TestChatRunToolAuthorization(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
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

	// Content: the same word in a PAY page, a MOB page, a workspace-wide note and one ticket per project.
	const word = "zebrafoxtrot"
	md := "# Title\n\n## Findings\n\n" + word + " body\n"
	payDoc, err := arts.Create(ctx, ws, artifacts.Actor{Type: "user", ID: me.ID}, artifacts.NewArtifact{ProjectKey: "PAY", Type: "spec", Title: "Pay " + word, Content: artifacts.Content{BodyMD: &md}})
	if err != nil {
		t.Fatal(err)
	}
	mobDoc, err := arts.Create(ctx, ws, artifacts.Actor{Type: "user", ID: me.ID}, artifacts.NewArtifact{ProjectKey: "MOB", Type: "spec", Title: "Mob " + word, Content: artifacts.Content{BodyMD: &md}})
	if err != nil {
		t.Fatal(err)
	}
	note, err := wk.SaveAsUser(ctx, ws, me.ID, wiki.Save{Path: "Shared/Global " + word, Body: "workspace-wide " + word})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = wk.SaveAsUser(ctx, ws, me.ID, wiki.Save{Path: "Shared/Mob links " + word, ProjectKey: "MOB", Body: "secret " + word + " cites [[Pay " + word + "]]"}); err != nil {
		t.Fatal(err)
	}
	if _, err = wk.SaveAsUser(ctx, ws, me.ID, wiki.Save{Path: "Shared/Pay links " + word, ProjectKey: "PAY", Body: "public " + word + " cites [[Pay " + word + "]]"}); err != nil {
		t.Fatal(err)
	}

	// Exercise capability denials with an explicitly restricted persona; the
	// initial Assistant grants every capability on a fresh installation.
	reader, err := (&personas.Service{Pool: pool}).Create(ctx, personas.Owner{WorkspaceID: ws, UserID: me.ID}, personas.NewInput{Name: "Reader"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{Project: "PAY", Title: "Tools", PersonaID: &reader.ID, Message: &runs.ChatMessageInput{Body: "hello"}})
	if err != nil {
		t.Fatal(err)
	}
	chat, err = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
	if err != nil || chat.CurrentRunID == nil {
		t.Fatalf("chat run: %v", err)
	}
	runID := *chat.CurrentRunID
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: runID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	// Every chat runs as the workspace's Personal Assistant, not the agent that used to be picked.
	if chat.AgentID == atlas.ID {
		t.Fatal("chat runs as atlas, not the Personal Assistant")
	}
	assistant, err := q.GetAgent(ctx, store.GetAgentParams{ID: chat.AgentID, WorkspaceID: ws})
	if err != nil || assistant.Kind != agents.KindAssistant {
		t.Fatalf("chat agent = %+v, %v", assistant, err)
	}
	token, _, err := agents.IssueToken(ctx, q, assistant.ID, "run", "chat", &runID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}

	// Every registered tool: the allowlist works, everything else (including tools added later) is refused by name.
	req := httptest.NewRequest("GET", "/api/v1/agent/tools", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	var listed struct{ Tools []struct{ Name string } }
	if err := json.Unmarshal(w.Body.Bytes(), &listed); err != nil || len(listed.Tools) < 20 {
		t.Fatalf("tool list: %s %v", w.Body.String(), err)
	}
	// Chats read every project, so no tool may tell the persona it's confined to one.
	if strings.Contains(w.Body.String(), "current chat project") {
		t.Fatalf("a tool description still confines chats to their project: %s", w.Body.String())
	}
	allowed := map[string]any{
		"whoami": map[string]any{}, "search_knowledge": map[string]any{"q": word}, "read_page": map[string]any{"ref": *note.Note.Path},
		"read_artifact":         map[string]any{"artifact": payDoc.ID.String()},
		"get_backlinks":         map[string]any{"ref": payDoc.ID.String()},
		"list_spaces":           map[string]any{},
		"list_scheduled_tasks":  map[string]any{},
		"search_library":        map[string]any{},
		"list_inbox":            map[string]any{},
		"list_learning_modules": map[string]any{},
		"list_connectors":       map[string]any{},
		"list_secret_names":     map[string]any{},
		"search_repositories":   map[string]any{},
		"list_saved_links":      map[string]any{},
		"canvas_list":           map[string]any{},
		"list_workflows":        map[string]any{},
		"list_imports":          map[string]any{},
		"list_custom_apps":      map[string]any{},
		"http_list_workspaces":  map[string]any{},
		"set_plan":              map[string]any{"steps": []any{}},
	}
	// Allowed too, but they need arguments; they're exercised below or in the memory tests.
	needArgs := []string{"librarian_pass", "daily_note", "import_vault", "delete_page", "delete_folder", "list_page_versions", "restore_page_version", "file_capture", "attach_file", "list_page_reviews", "withdraw_suggestion", "set_page_controls", "attach_chat_to_page", "promote_canvas", "knowledge_graph", "confirm_import", "cancel_import", "undo_import", "list_pages", "page_outline", "patch_page", "set_properties", "move_page", "move_folder", "create_page", "capture_note", "suggest_links", "use_repository", "request_push", "submit_research_report", "search_memory", "read_memory", "search_chats", "read_chat", "save_memory", "update_memory", "forget_memory", "set_chat_title", "generate_image", "start_video", "update_video", "finish_video", "fail_video", "start_audio", "update_audio", "finish_audio", "fail_audio", "generate_music", "save_file", "render_pdf", "create_mockup", "get_video_transcript", "propose_persona", "propose_persona_character", "canvas_create", "canvas_patch", "canvas_read", "canvas_comment", "canvas_reply", "design_list", "design_outline", "design_read", "design_render", "design_patch", "design_import", "design_comments", "design_comment", "design_reply", "design_create", "write_note", "read_workflow", "propose_workflow_edit", "propose_connector", "propose_secret", "read_library_item", "save_link", "browser_snapshot", "create_space", "create_scheduled_task", "update_scheduled_task", "delete_scheduled_task", "create_learning_module", "get_learning_progress", "start_playground", "playground_status", "stop_playground", "set_playground_openapi", "design_flows", "design_components", "design_tokens", "design_inspect", "get_custom_app", "create_custom_app", "update_custom_app", "delete_custom_app", "custom_app_sql", "http_get_workspace", "http_save_request", "http_run_request", "run_subagent", "run_subagents"}
	seen := 0
	for _, tool := range listed.Tools {
		args, ok := allowed[tool.Name]
		code, out := call(token, tool.Name, args)
		if slices.Contains(needArgs, tool.Name) {
			seen++
			// This chat's persona lacks the capability, which is refused after the allowlist.
			noCapability := tool.Name == "propose_workflow_edit" && strings.Contains(fmt.Sprint(out["message"]), "can't create workflows")
			noCapability = noCapability || (tool.Name == "import_vault" && strings.Contains(fmt.Sprint(out["message"]), "vault storage is unavailable"))
			noCapability = noCapability || tool.Name == "propose_connector" || tool.Name == "use_repository" || tool.Name == "request_push"
			noCapability = noCapability || (tool.Name == "propose_secret" && strings.Contains(fmt.Sprint(out["message"]), "can't propose secrets"))
			// browser_snapshot needs a Safari tab shared with the chat.
			noCapability = noCapability || (tool.Name == "browser_snapshot" && strings.Contains(fmt.Sprint(out["message"]), "no Safari tab is shared"))
			// Playgrounds need a chat that can run code, and one started.
			noCapability = noCapability || (tool.Name == "start_playground" && strings.Contains(fmt.Sprint(out["message"]), "can run code"))
			noCapability = noCapability || strings.Contains(tool.Name, "playground") && strings.Contains(fmt.Sprint(out["message"]), "has no playground yet")
			if code == 409 && !noCapability {
				t.Errorf("%s: %d %v", tool.Name, code, out)
			}
			continue
		}
		if ok {
			seen++
			if code != 200 {
				t.Errorf("%s: %d %v", tool.Name, code, out)
			}
			continue
		}
		if code != 409 || out["message"] != tool.Name+" isn't available in chats" {
			t.Errorf("%s: %d %v", tool.Name, code, out)
		}
	}
	if seen != len(allowed)+len(needArgs) {
		t.Fatalf("allowed tools registered: %d of %d", seen, len(allowed)+len(needArgs))
	}

	// New chat pages are private and published directly for their owner;
	// another agent's memory stays off limits.
	code, wn := call(token, "write_note", map[string]any{"path": "Payments/Chat runbook " + word, "body": "Found in chat"})
	if code != 200 || wn["state"] != "published" {
		t.Fatalf("chat write_note = %d %v, want a private direct edit", code, wn)
	}
	if code, out := call(token, "write_note", map[string]any{"path": "agents/someone-else/x", "body": "x"}); code != 422 {
		t.Fatalf("write_note into another agent's memory = %d %v", code, out)
	}

	if code, out := call(token, "propose_workflow_edit", map[string]any{"summary": "Add a step", "name": "New", "ops": []any{}}); code != 409 || !strings.Contains(fmt.Sprint(out), "can't create workflows") {
		t.Fatalf("propose_workflow_edit without the capability = %d %v", code, out)
	}

	// whoami is chat-specific: no ticket queue, chat named.
	_, who := call(token, "whoami", map[string]any{})
	ins := fmt.Sprint(who["instructions"])
	if who["chat_id"] != chat.ID.String() || !strings.Contains(ins, "[[") || len(who["queue"].([]any)) != 0 || len(who["live_runs"].([]any)) != 0 {
		t.Fatalf("chat whoami = %v", who)
	}

	// Search covers every project; a project argument narrows it.
	titles := func(args map[string]any) string {
		code, out := call(token, "search_knowledge", args)
		if code != 200 {
			t.Fatalf("search %v: %d %v", args, code, out)
		}
		var ts []string
		for _, r := range out["results"].([]any) {
			ts = append(ts, r.(map[string]any)["title"].(string))
		}
		slices.Sort(ts)
		return strings.Join(ts, "|")
	}
	got := titles(map[string]any{"q": word})
	if !strings.Contains(got, "Pay "+word) || !strings.Contains(got, "Global "+word) || !strings.Contains(got, "Mob "+word) {
		t.Fatalf("workspace search = %s", got)
	}
	if narrowed := titles(map[string]any{"q": word, "project": "pay"}); !strings.Contains(narrowed, "Pay "+word) || strings.Contains(narrowed, "Mob") {
		t.Fatalf("search narrowed to PAY = %s", narrowed)
	}
	if code, out := call(token, "search_knowledge", map[string]any{"q": word, "project": "NOPE"}); code != 422 {
		t.Fatalf("unknown project search = %d %v", code, out)
	}

	// Another project's content reads like the chat's own.
	if code, out := call(token, "read_artifact", map[string]any{"artifact": mobDoc.ID.String()}); code != 200 {
		t.Fatalf("other project's artifact = %d %v", code, out)
	}
	if code, out := call(token, "read_page", map[string]any{"ref": mobDoc.ID.String()}); code != 200 {
		t.Fatalf("other project's page = %d %v", code, out)
	}
	_, bl := call(token, "get_backlinks", map[string]any{"ref": payDoc.ID.String()})
	linked := fmt.Sprint(bl["linked_from"])
	if !strings.Contains(linked, "Pay links") || !strings.Contains(linked, "Mob links") {
		t.Fatalf("backlinks from every project: %v", bl)
	}

	// Reads are attributed to the chat run, with the section read.
	if code, out := call(token, "read_artifact", map[string]any{"artifact": payDoc.ID.String(), "section": "findings"}); code != 200 {
		t.Fatalf("section read = %d %v", code, out)
	}
	if code, out := call(token, "read_page", map[string]any{"ref": *note.Note.Path}); code != 200 {
		t.Fatalf("note read = %d %v", code, out)
	}
	var n int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM artifact_reads WHERE run_id=$1", runID).Scan(&n); err != nil || n < 4 {
		t.Fatalf("reads attributed to chat run = %d, %v", n, err)
	}

	// The assistant's tokens work only inside chat runs.
	payTicket, err := tracker.Get(ctx, q, ws, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	payRun, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, TicketID: &payTicket.ID, AgentID: atlas.ID, Mode: "managed", State: "running",
		ResolvedSpec: json.RawMessage(`{}`), Harness: "codex", Model: "m", Purpose: "ticket"})
	if err != nil {
		t.Fatal(err)
	}
	payRunID := payRun.ID
	for _, rid := range []*uuid.UUID{nil, &payRunID} {
		kind := "run"
		if rid == nil {
			kind = "unmanaged"
		}
		tok, _, err := agents.IssueToken(ctx, q, assistant.ID, kind, "chat", rid, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		if code, out := call(tok, "get_ticket", map[string]any{"ticket": "PAY-214"}); code != 409 || !strings.Contains(fmt.Sprint(out["message"]), "only works inside chats") {
			t.Fatalf("assistant outside a chat (run %v) = %d %v", rid, code, out)
		}
	}

	// A finished chat run is refused even for allowed tools.
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: runID, State: "failed"}); err != nil {
		t.Fatal(err)
	}
	if code, out := call(token, "whoami", map[string]any{}); code != 409 || !strings.Contains(fmt.Sprint(out["message"]), "chat run is failed") {
		t.Fatalf("failed chat run = %d %v", code, out)
	}
}

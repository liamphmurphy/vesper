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
	mt, err := tr.Create(ctx, ws, tracker.UserActor(me.ID), tracker.NewTicket{ProjectKey: "MOB", Title: "Mobile " + word})
	if err != nil {
		t.Fatal(err)
	}
	mobTicket := mt.Key

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
		"read_artifact": map[string]any{"artifact": payDoc.ID.String()}, "get_ticket": map[string]any{"ticket": "PAY-214"},
		"get_backlinks":         map[string]any{"ref": payDoc.ID.String()},
		"create_ticket":         map[string]any{"title": "Chat-created ticket"},
		"create_epic":           map[string]any{"name": "Chat-created epic"},
		"list_epics":            map[string]any{},
		"list_tickets":          map[string]any{},
		"list_projects":         map[string]any{},
		"list_scheduled_tasks":  map[string]any{},
		"search_library":        map[string]any{},
		"list_inbox":            map[string]any{},
		"list_learning_modules": map[string]any{},
		"list_connectors":       map[string]any{},
		"list_secret_names":     map[string]any{},
		"list_runs":             map[string]any{},
		"search_repositories":   map[string]any{},
		"list_saved_links":      map[string]any{},
		"canvas_list":           map[string]any{},
		"list_workflows":        map[string]any{},
		"list_imports":          map[string]any{},
		"list_custom_apps":      map[string]any{},
		"http_list_workspaces":  map[string]any{},
	}
	// Allowed too, but they need arguments; they're exercised below or in the memory tests.
	needArgs := []string{"librarian_pass", "daily_note", "import_vault", "delete_page", "delete_folder", "list_page_versions", "restore_page_version", "file_capture", "attach_file", "list_page_reviews", "withdraw_suggestion", "set_page_controls", "attach_chat_to_page", "promote_canvas", "knowledge_graph", "confirm_import", "cancel_import", "undo_import", "list_pages", "page_outline", "patch_page", "set_properties", "move_page", "move_folder", "create_page", "capture_note", "suggest_links", "use_repository", "request_push", "update_ticket", "comment_ticket", "update_ticket_blockers", "get_epic", "update_epic", "submit_research_report", "get_run", "reply_to_run", "search_memory", "read_memory", "search_chats", "read_chat", "save_memory", "update_memory", "forget_memory", "set_chat_title", "generate_image", "start_video", "update_video", "finish_video", "fail_video", "start_audio", "update_audio", "finish_audio", "fail_audio", "save_file", "render_pdf", "get_video_transcript", "propose_persona", "canvas_create", "canvas_patch", "canvas_read", "canvas_comment", "canvas_reply", "design_list", "design_outline", "design_read", "design_render", "design_patch", "design_import", "design_comments", "design_comment", "design_reply", "design_create", "write_note", "read_workflow", "propose_workflow_edit", "propose_connector", "propose_secret", "read_library_item", "save_link", "browser_snapshot", "create_space", "create_scheduled_task", "update_scheduled_task", "delete_scheduled_task", "create_learning_module", "get_learning_progress", "start_playground", "playground_status", "stop_playground", "set_playground_openapi", "design_flows", "design_components", "design_tokens", "design_inspect", "design_link_ticket", "get_custom_app", "create_custom_app", "update_custom_app", "delete_custom_app", "custom_app_sql", "http_get_workspace", "http_save_request", "http_run_request"}
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

	// Writes use the chat project, without needing an execution ticket.
	code, created := call(token, "create_epic", map[string]any{"name": "Chat planning"})
	if code != 200 {
		t.Fatalf("create epic = %d %v", code, created)
	}
	epicID := created["epic_id"]
	code, created = call(token, "create_ticket", map[string]any{"title": "Planned in chat", "epic_id": epicID})
	if code != 200 {
		t.Fatalf("create ticket = %d %v", code, created)
	}
	key := fmt.Sprint(created["ticket"])
	if !strings.HasPrefix(key, "PAY-") {
		t.Fatalf("wrong project: %v", created)
	}
	foreignEpic, err := q.CreateEpic(ctx, store.CreateEpicParams{WorkspaceID: ws, ProjectID: mt.ProjectID, Name: "Foreign epic", Health: "on_track"})
	if err != nil {
		t.Fatal(err)
	}
	if code, out := call(token, "create_ticket", map[string]any{"title": "Wrong project", "epic_id": foreignEpic.ID}); code != 422 {
		t.Fatalf("foreign epic = %d %v", code, out)
	}
	// Naming a project or an agent overrides the default and assigns the ticket.
	if code, out := call(token, "create_ticket", map[string]any{"title": "Mobile fix", "project": "mob", "agent": "@atlas"}); code != 200 || !strings.HasPrefix(fmt.Sprint(out["ticket"]), "MOB-") {
		t.Fatalf("create_ticket in MOB = %d %v", code, out)
	} else {
		mobFix, err := tracker.Get(ctx, q, ws, fmt.Sprint(out["ticket"]))
		if err != nil || mobFix.AssigneeAgentID == nil || *mobFix.AssigneeAgentID != atlas.ID {
			t.Fatalf("assignee = %+v, %v", mobFix.AssigneeAgentID, err)
		}
	}
	if code, out := call(token, "create_ticket", map[string]any{"title": "Self-assigned", "agent": assistant.Handle}); code != 422 || !strings.Contains(fmt.Sprint(out), "can't take tickets") {
		t.Fatalf("assign to the assistant = %d %v", code, out)
	}
	if code, out := call(token, "create_ticket", map[string]any{"title": "Nowhere", "project": "NOPE"}); code != 422 {
		t.Fatalf("unknown project = %d %v", code, out)
	}
	if code, out := call(token, "create_epic", map[string]any{"name": "Mobile epic", "project": "MOB"}); code != 200 || out["project"] != "MOB" {
		t.Fatalf("create_epic in MOB = %d %v", code, out)
	}
	if code, out := call(token, "propose_workflow_edit", map[string]any{"summary": "Add a step", "name": "New", "ops": []any{}}); code != 409 || !strings.Contains(fmt.Sprint(out), "can't create workflows") {
		t.Fatalf("propose_workflow_edit without the capability = %d %v", code, out)
	}

	// create_epic takes optional criteria, all or nothing; list_epics shows counts.
	if code, out := call(token, "create_epic", map[string]any{"name": "Bad criteria", "criteria": []string{"ok", "  "}}); code != 422 || !strings.Contains(fmt.Sprint(out), "criteria") {
		t.Fatalf("blank criterion = %d %v", code, out)
	}
	code, created = call(token, "create_epic", map[string]any{"name": "With criteria", "criteria": []string{"Board ships", "Docs updated"}})
	if code != 200 || created["criteria"] != float64(2) {
		t.Fatalf("create epic with criteria = %d %v", code, created)
	}
	_, listed2 := call(token, "list_epics", map[string]any{})
	var withCriteria map[string]any
	for _, e := range listed2["epics"].([]any) {
		em := e.(map[string]any)
		if em["Name"] == "Bad criteria" {
			t.Fatalf("partial epic created: %v", em)
		}
		if em["Name"] == "With criteria" {
			withCriteria = em
		}
	}
	if withCriteria == nil || withCriteria["CriteriaTotal"] != float64(2) || withCriteria["CriteriaDone"] != float64(0) || withCriteria["Status"] != "open" || withCriteria["PointsTotal"] != float64(0) {
		t.Fatalf("list_epics row = %v", withCriteria)
	}

	// whoami is chat-specific: no ticket queue, project and chat named.
	_, who := call(token, "whoami", map[string]any{})
	ins := fmt.Sprint(who["instructions"])
	if who["project"] != "PAY" || who["chat_id"] != chat.ID.String() || !strings.Contains(ins, "Never claim tickets") || !strings.Contains(ins, "[[") || len(who["queue"].([]any)) != 0 || len(who["live_runs"].([]any)) != 0 {
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
	if code, out := call(token, "get_ticket", map[string]any{"ticket": mobTicket}); code != 200 || out["key"] != mobTicket {
		t.Fatalf("other project's ticket = %d %v", code, out)
	}
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

	// Runs: ticket runs of every project, or one; delegated runs show under their parent.
	payTicket, err := tracker.Get(ctx, q, ws, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	mkRun := func(ticket *store.Ticket, parent *uuid.UUID, state, purpose string) store.Run {
		t.Helper()
		var tid *uuid.UUID
		if ticket != nil {
			tid = &ticket.ID
		}
		r, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, TicketID: tid, AgentID: atlas.ID, Mode: "managed", State: state,
			ResolvedSpec: json.RawMessage(`{}`), Harness: "codex", Model: "m", ParentRunID: parent, Purpose: purpose})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	payRun := mkRun(&payTicket, nil, "running", "ticket")
	child := mkRun(&payTicket, &payRun.ID, "completed", "ticket")
	doneRun := mkRun(&payTicket, nil, "completed", "ticket")
	mobRun := mkRun(&mt, nil, "running", "ticket")
	planRun := mkRun(nil, nil, "running", "planning")
	runIDs := func(args map[string]any) []string {
		t.Helper()
		code, out := call(token, "list_runs", args)
		if code != 200 {
			t.Fatalf("list_runs %v = %d %v", args, code, out)
		}
		var ids []string
		for _, r := range out["runs"].([]any) {
			ids = append(ids, r.(map[string]any)["id"].(string))
		}
		return ids
	}
	if ids := runIDs(map[string]any{}); !slices.Contains(ids, payRun.ID.String()) || slices.Contains(ids, doneRun.ID.String()) {
		t.Fatalf("live runs = %v", ids)
	}
	if ids := runIDs(map[string]any{"state": "finished"}); !slices.Contains(ids, doneRun.ID.String()) || slices.Contains(ids, payRun.ID.String()) {
		t.Fatalf("finished runs = %v", ids)
	}
	for _, ids := range [][]string{runIDs(map[string]any{"state": "all"}), runIDs(map[string]any{"state": "all", "agent": "atlas"})} {
		if !slices.Contains(ids, mobRun.ID.String()) {
			t.Fatalf("list_runs misses another project's run: %v", ids)
		}
		for _, hidden := range []uuid.UUID{child.ID, planRun.ID, runID} {
			if slices.Contains(ids, hidden.String()) {
				t.Fatalf("list_runs leaks %s: %v", hidden, ids)
			}
		}
	}
	if ids := runIDs(map[string]any{"state": "all", "ticket": "pay-214"}); !slices.Contains(ids, child.ID.String()) {
		t.Fatalf("a ticket's runs include delegated ones: %v", ids)
	}
	if ids := runIDs(map[string]any{"state": "all", "project": "pay"}); !slices.Contains(ids, payRun.ID.String()) || slices.Contains(ids, mobRun.ID.String()) {
		t.Fatalf("runs narrowed to PAY = %v", ids)
	}
	if ids := runIDs(map[string]any{"ticket": mobTicket}); !slices.Contains(ids, mobRun.ID.String()) {
		t.Fatalf("other project's ticket runs = %v", ids)
	}
	// get_run reports the latest context size and what filled it, summed over turns.
	if err := q.SetRunContextTokens(ctx, store.SetRunContextTokensParams{ID: payRun.ID, ContextTokens: 123456}); err != nil {
		t.Fatal(err)
	}
	for _, u := range []string{`{"explore_output_bytes": 100, "shell_output_bytes": 7}`, `{"explore_output_bytes": 20, "other_output_bytes": 3}`} {
		if _, err := pool.Exec(ctx, `INSERT INTO run_turns (run_id, seq, trigger, usage) VALUES ($1, coalesce((SELECT max(seq) FROM run_turns WHERE run_id = $1), 0) + 1, 'start', $2)`, payRun.ID, u); err != nil {
			t.Fatal(err)
		}
	}
	// Its efficiency summary comes from the main agent's events; a sub
	// agent's tool calls don't count.
	for _, e := range []struct{ typ, payload string }{
		{"lifecycle", `{"state": "starting"}`},
		{"lifecycle", `{"state": "workspace_ready"}`},
		{"tool_call", `{"id": "a", "tool": "Read", "input": {}, "context_tokens": 50000}`},
		{"tool_call", `{"id": "s", "tool": "Edit", "input": {}, "subagent": true}`},
		{"tool_call", `{"id": "b", "tool": "Bash", "input": {"command": "go test ./..."}, "context_tokens": 110000}`},
		{"tool_result", `{"id": "b", "tool": "Bash", "output": "ok"}`},
		{"tool_call", `{"id": "c", "tool": "Edit", "input": {}, "context_tokens": 120000}`},
	} {
		if err := q.AddRunEvent(ctx, store.AddRunEventParams{RunID: payRun.ID, Type: e.typ, Payload: []byte(e.payload)}); err != nil {
			t.Fatal(err)
		}
	}
	code, got2 := call(token, "get_run", map[string]any{"id": payRun.ID.String()})
	if eff, _ := got2["efficiency"].(map[string]any); eff == nil || eff["setups"] != float64(1) || eff["tool_calls"] != float64(3) ||
		eff["calls_before_first_edit"] != float64(2) || eff["test_runs"] != float64(1) || eff["peak_context_tokens"] != float64(120000) {
		t.Fatalf("get_run efficiency = %v", got2["efficiency"])
	}
	if code != 200 || got2["run"].(map[string]any)["ticket"] != "PAY-214" || len(got2["delegated_runs"].([]any)) != 1 {
		t.Fatalf("get_run = %d %v", code, got2)
	}
	if got2["context_tokens"] != float64(123456) || got2["explore_output_bytes"] != float64(120) || got2["shell_output_bytes"] != float64(7) || got2["other_output_bytes"] != float64(3) {
		t.Fatalf("get_run context = %v", got2)
	}
	if code, out := call(token, "get_run", map[string]any{"id": mobRun.ID.String()}); code != 200 {
		t.Fatalf("get_run other project = %d %v", code, out)
	}
	for _, hidden := range []uuid.UUID{planRun.ID, runID} {
		if code, out := call(token, "get_run", map[string]any{"id": hidden.String()}); code != 422 {
			t.Fatalf("get_run %s = %d %v", hidden, code, out)
		}
	}

	// The assistant's tokens work only inside chat runs.
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

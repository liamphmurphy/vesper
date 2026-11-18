package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agentapi"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// Each caller kind is served its own tool set and instructions.
func TestMCPProfiles(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	tr := &tracker.Service{Pool: pool}
	srv := &Server{
		AnonymousAPI: true,
		Version:      "test", Pool: pool, Q: q, Tracker: tr, Artifacts: arts, Agents: &agents.Service{Pool: pool},
		Log:  slog.New(slog.NewTextHandler(io.Discard, nil)),
		Runs: &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts},
		Wiki: &wiki.Service{Pool: pool, Artifacts: arts, Tracker: tr},
	}
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ticket, err := tr.Create(ctx, ws, tracker.UserActor(me.ID), tracker.NewTicket{ProjectKey: "PAY", Title: "Profiles"})
	if err != nil {
		t.Fatal(err)
	}
	mkRun := func(ticketID, parent *uuid.UUID, purpose string) string {
		t.Helper()
		run, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, TicketID: ticketID, AgentID: atlas.ID, Mode: "managed", State: "running", ResolvedSpec: json.RawMessage(`{}`), Harness: "claude", Model: "test", ParentRunID: parent, Purpose: purpose})
		if err != nil {
			t.Fatal(err)
		}
		tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "profiles", &run.ID, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		return tok
	}
	lead, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, TicketID: &ticket.ID, AgentID: atlas.ID, Mode: "managed", State: "running", ResolvedSpec: json.RawMessage(`{}`), Harness: "claude", Model: "test", Purpose: "ticket"})
	if err != nil {
		t.Fatal(err)
	}
	leadTok, _, _ := agents.IssueToken(ctx, q, atlas.ID, "run", "lead", &lead.ID, nil, nil)
	unmanaged, _, _ := agents.IssueToken(ctx, q, atlas.ID, "unmanaged", "profiles", nil, nil, nil)

	var all []string
	for _, tl := range agentapi.Tools {
		all = append(all, tl.Name)
	}
	without := func(hide ...string) []string {
		return slices.DeleteFunc(slices.Clone(all), func(n string) bool { return slices.Contains(hide, n) })
	}
	subTools := []string{"get_ticket", "search_memory", "read_memory", "read_artifact", "create_artifact", "comment", "request_approval", "wait_for_approval", "run_gated", "await_human", "search_knowledge", "find_pattern", "propose_pattern", "list_proposed_patterns", "read_page", "write_note", "get_backlinks", "complete_run"}
	chatTools := []string{"whoami", "search_knowledge", "read_page", "read_artifact", "get_ticket", "get_backlinks", "create_ticket", "update_ticket", "comment_ticket", "update_ticket_blockers", "create_epic", "get_epic", "update_epic", "list_epics", "list_tickets", "list_projects", "list_runs", "get_run", "reply_to_run",
		"librarian_pass", "daily_note", "import_vault", "list_pages", "page_outline", "patch_page", "set_properties", "move_page", "move_folder", "delete_page", "delete_folder", "list_page_versions", "restore_page_version", "file_capture", "attach_file", "list_page_reviews", "withdraw_suggestion", "set_page_controls", "attach_chat_to_page", "promote_canvas", "knowledge_graph", "list_imports", "confirm_import", "cancel_import", "undo_import", "create_page", "capture_note", "suggest_links", "propose_connector", "propose_secret", "write_note", "search_memory", "read_memory", "save_memory", "update_memory", "forget_memory", "search_chats", "read_chat", "search_repositories", "use_repository", "request_push", "set_chat_title", "generate_image", "start_video", "update_video", "finish_video", "fail_video", "start_audio", "update_audio", "finish_audio", "fail_audio", "save_file", "start_playground", "playground_status", "stop_playground", "set_playground_openapi", "get_video_transcript", "propose_persona", "list_saved_links", "save_link", "browser_snapshot", "search_library", "read_library_item", "list_inbox", "submit_research_report", "canvas_create", "canvas_patch", "canvas_read", "canvas_list", "canvas_comment", "canvas_reply", "design_list", "design_outline", "design_read", "design_render", "design_patch", "design_import", "design_comments", "design_comment", "design_reply", "design_create", "list_workflows", "read_workflow", "propose_workflow_edit", "list_connectors", "list_secret_names", "create_space", "create_scheduled_task", "list_scheduled_tasks", "update_scheduled_task", "delete_scheduled_task", "create_learning_module", "list_learning_modules", "get_learning_progress", "design_flows", "design_components", "design_tokens", "design_inspect", "design_link_ticket", "list_custom_apps", "get_custom_app", "create_custom_app", "update_custom_app", "delete_custom_app", "custom_app_sql", "http_list_workspaces", "http_get_workspace", "http_save_request", "http_run_request"}
	planTools := []string{"whoami", "get_ticket", "read_artifact", "search_knowledge", "read_page", "get_backlinks", "propose_tickets"}

	connect := func(tok string) *mcp.ClientSession {
		t.Helper()
		client := mcp.NewClient(&mcp.Implementation{Name: "test-agent", Version: "1"}, nil)
		sess, err := client.Connect(ctx, &mcp.StreamableClientTransport{
			Endpoint: ts.URL + "/mcp", HTTPClient: &http.Client{Transport: bearer{tok, http.DefaultTransport}}, DisableStandaloneSSE: true,
		}, nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = sess.Close() })
		return sess
	}
	names := func(sess *mcp.ClientSession) []string {
		t.Helper()
		res, err := sess.ListTools(ctx, nil)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, tl := range res.Tools {
			out = append(out, tl.Name)
		}
		slices.Sort(out)
		return out
	}
	check := func(label string, sess *mcp.ClientSession, want []string) {
		t.Helper()
		want = slices.Sorted(slices.Values(want))
		if got := names(sess); !slices.Equal(got, want) {
			t.Errorf("%s tools = %v, want %v", label, got, want)
		}
	}

	sub := connect(mkRun(&ticket.ID, &lead.ID, "ticket"))
	leadSess := connect(leadTok)
	check("subagent", sub, subTools)
	check("lead", leadSess, without("submit_outline", "submit_lesson", "submit_review", "submit_workflow_output", "list_workflows", "read_workflow", "propose_workflow_edit", "submit_findings", "submit_research_report", "list_saved_links", "save_link", "browser_snapshot", "search_library", "read_library_item", "list_inbox", "report_usage", "next_ticket", "save_memory", "update_memory", "forget_memory", "search_chats", "read_chat", "search_repositories", "use_repository", "request_push", "set_chat_title", "list_tickets", "list_projects", "list_runs", "get_run", "generate_image", "start_video", "update_video", "finish_video", "fail_video", "start_audio", "update_audio", "finish_audio", "fail_audio", "save_file", "start_playground", "playground_status", "stop_playground", "set_playground_openapi", "get_video_transcript", "propose_persona", "canvas_create", "canvas_patch", "canvas_read", "canvas_list", "canvas_comment", "canvas_reply", "design_list", "design_outline", "design_read", "design_render", "design_patch", "design_import", "design_comments", "design_comment", "design_reply", "design_create", "list_connectors", "list_secret_names", "create_space", "create_scheduled_task", "list_scheduled_tasks", "update_scheduled_task", "delete_scheduled_task", "create_learning_module", "list_learning_modules", "get_learning_progress", "design_flows", "design_components", "design_tokens", "design_inspect", "design_link_ticket", "list_custom_apps", "get_custom_app", "create_custom_app", "update_custom_app", "delete_custom_app", "custom_app_sql", "http_list_workspaces", "http_get_workspace", "http_save_request", "http_run_request"))
	check("chat", connect(mkRun(nil, nil, "chat")), chatTools)
	check("planning", connect(mkRun(nil, nil, "planning")), planTools)
	check("course run", connect(mkRun(nil, nil, "learning")), []string{"submit_outline", "submit_lesson", "submit_review"})
	check("workflow step", connect(mkRun(nil, nil, "workflow")), []string{"submit_workflow_output", "search_knowledge", "read_page", "read_artifact", "get_ticket", "get_backlinks"})
	// A step that reads the web gets nothing from the workspace.
	webRun, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, AgentID: atlas.ID, Mode: "managed", State: "running", ResolvedSpec: json.RawMessage(`{"harness_options":{"web_search":"true"}}`), Harness: "claude", Model: "test", Purpose: "workflow"})
	if err != nil {
		t.Fatal(err)
	}
	webTok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "profiles", &webRun.ID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	check("web workflow step", connect(webTok), []string{"submit_workflow_output"})
	check("unmanaged", connect(unmanaged), all)

	subIns, leadIns := sub.InitializeResult().Instructions, leadSess.InitializeResult().Instructions
	if subIns == leadIns || strings.Contains(subIns, "skip get_ticket") || !strings.Contains(leadIns, "skip get_ticket") {
		t.Errorf("instructions not per profile:\nsub: %s\nlead: %s", subIns, leadIns)
	}

	// The profile check refuses hidden tools by name, and leaves allowed ones alone.
	for _, name := range []string{"post_plan", "claim_ticket"} {
		res, err := sub.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: map[string]any{}})
		if err == nil && !res.IsError {
			t.Errorf("delegated run called %s without error", name)
		}
	}
	callRaw := func(tok, name string, args any) (int, string) {
		raw, _ := json.Marshal(args)
		req, _ := http.NewRequest("POST", ts.URL+"/api/v1/agent/tools/"+name, strings.NewReader(string(raw)))
		req.Header.Set("Authorization", "Bearer "+tok)
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		b, _ := io.ReadAll(res.Body)
		return res.StatusCode, string(b)
	}
	subTok := mkRun(&ticket.ID, &lead.ID, "ticket")
	if code, body := callRaw(subTok, "post_plan", map[string]any{}); code != 409 || !strings.Contains(body, "isn't available to delegated runs") {
		t.Errorf("post_plan = %d %s", code, body)
	}
	if code, body := callRaw(subTok, "get_ticket", map[string]any{"ticket": ticket.Key}); code != 200 {
		t.Errorf("get_ticket = %d %s", code, body)
	}
	if code, body := callRaw(subTok, "complete_run", map[string]any{"status": "done", "summary": "ok"}); strings.Contains(body, "isn't available") {
		t.Errorf("complete_run blocked by profile: %d %s", code, body)
	}
}

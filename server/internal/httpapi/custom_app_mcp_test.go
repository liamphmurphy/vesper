package httpapi

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

func TestCustomAppMCPServerEndToEnd(t *testing.T) {
	var apiSrv *Server
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: testBox(t)}
		apiSrv = s
	})
	ctx := context.Background()
	ws := e.me.WorkspaceID

	const secretVal = "drive-oauth-token-xyz-123"
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"files":[{"name":"Q4 Plan.gdoc","id":"f1"}],"echoAuth":"`+r.Header.Get("Authorization")+`"}`)
	}))
	t.Cleanup(upstream.Close)

	sec, err := apiSrv.userSecrets().Create(ctx, ws, e.me.ID, usersecrets.Input{
		Name:         "Drive Token",
		Value:        secretVal,
		Placement:    usersecrets.PlacementBearer,
		AllowedHosts: []string{"127.0.0.1"},
		ReadPolicy:   usersecrets.PolicyAllow,
		WritePolicy:  usersecrets.PolicyAllow,
	})
	if err != nil {
		t.Fatal(err)
	}

	// Create a Custom App with a server.ts MCP server.
	createPayload := map[string]any{
		"slug": "drive-mcp",
		"name": "Drive MCP",
		"manifest": map[string]any{
			"entry":      "app.tsx",
			"mcp_entry":  "server.ts",
			"tool_scope": "chats",
			"requested_capabilities": map[string]any{
				"secret:" + sec.Handle: "requires_approval",
			},
		},
		"files": map[string]string{
			"schema.sql": `CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, title TEXT NOT NULL);`,
			"app.tsx":    `export default function App() { return null; }`,
			"server.ts": `
import { defineServer, sql, secretFetch } from "@vesper/server";

export default defineServer({
  tools: {
    record_note: {
      description: "Save a note in app SQLite",
      inputSchema: { type: "object", properties: { title: { type: "string" } }, required: ["title"] },
      handler: async ({ title }: { title: string }) => {
        await sql("INSERT INTO notes (title) VALUES (?)", [title]);
        return await sql("SELECT title FROM notes ORDER BY id");
      },
    },
    list_drive_files: {
      description: "List files from Drive API via Vesper secret",
      inputSchema: { type: "object", properties: {} },
      handler: async () => {
        const res = await secretFetch("` + sec.Handle + `", "` + upstream.URL + `/drive/v3/files");
        return await res.json();
      },
    },
  },
});`,
		},
	}

	created := e.want("POST", "/custom-apps", createPayload, http.StatusCreated)
	if created["has_mcp_server"] != true {
		t.Fatalf("expected has_mcp_server=true, got %v", created)
	}
	mcpTools := created["mcp_tools"].([]any)
	if len(mcpTools) != 2 {
		t.Fatalf("expected 2 extracted mcp_tools, got %v", mcpTools)
	}
	spaceID := created["space_id"].(string)

	// 1. UI invocation: SQL tool succeeds immediately.
	noteOut := e.want("POST", "/custom-apps/drive-mcp/invoke", map[string]any{
		"kind":      "mcp",
		"connector": "self",
		"tool":      "record_note",
		"arguments": map[string]any{"title": "hello"},
	}, http.StatusOK)
	if noteOut["status"] != "ok" {
		t.Fatalf("noteOut = %v", noteOut)
	}

	// 2. UI invocation: secretFetch tool pauses for approval first, then Always allow promotes capability!
	prompt := e.want("POST", "/custom-apps/drive-mcp/invoke", map[string]any{
		"kind":      "mcp",
		"connector": "self",
		"tool":      "list_drive_files",
	}, http.StatusOK)
	if prompt["status"] != "approval_required" || prompt["capability"] != "secret:"+sec.Handle {
		t.Fatalf("expected approval_required for secret, got %v", prompt)
	}

	approvedOut := e.want("POST", "/custom-apps/drive-mcp/invoke", map[string]any{
		"kind":         "mcp",
		"connector":    "self",
		"tool":         "list_drive_files",
		"approved":     true,
		"always_allow": true,
	}, http.StatusOK)
	if approvedOut["status"] != "ok" {
		t.Fatalf("approvedOut = %v", approvedOut)
	}
	resMap := approvedOut["result"].(map[string]any)
	if strings.Contains(resMap["echoAuth"].(string), secretVal) {
		t.Fatalf("raw secret leaked in response: %v", resMap)
	}
	if !strings.Contains(resMap["echoAuth"].(string), "‹"+sec.Handle+"›") {
		t.Fatalf("expected masked secret handle in response, got %v", resMap)
	}

	// 3. Persona chat receives app_drive-mcp and can call its MCP tools over /mcp/connectors/app_drive-mcp.
	persona, err := (&personas.Service{Pool: e.pool}).Create(ctx, personas.Owner{WorkspaceID: ws, UserID: e.me.ID}, personas.NewInput{Name: "DriveBot"})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := e.runs.StartChat(ctx, ws, e.me.ID, runs.ChatInput{PersonaID: &persona.ID, Title: "C", Message: &runs.ChatMessageInput{Body: "hi"}})
	if err != nil {
		t.Fatal(err)
	}
	chat, _ = e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
	if chat.CurrentRunID == nil {
		t.Fatal("expected current run ID")
	}
	run, err := e.q.GetRun(ctx, store.GetRunParams{ID: *chat.CurrentRunID, WorkspaceID: ws})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(run.ResolvedSpec), agentdef.CustomAppMCPPrefix+"drive-mcp") {
		t.Fatalf("expected app_drive-mcp in run ResolvedSpec MCPServers, got %s", string(run.ResolvedSpec))
	}

	token, _, err := agents.IssueToken(ctx, e.q, chat.AgentID, "run", "chat", chat.CurrentRunID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	dial := func(tok string) (*mcp.ClientSession, error) {
		c := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "1"}, nil)
		return c.Connect(ctx, &mcp.StreamableClientTransport{
			Endpoint:             e.srv.URL + "/mcp/connectors/" + agentdef.CustomAppMCPPrefix + "drive-mcp",
			DisableStandaloneSSE: true,
			MaxRetries:           -1,
			HTTPClient:           &http.Client{Transport: runBearer{tok}},
		}, nil)
	}

	sess, err := dial(token)
	if err != nil {
		t.Fatalf("MCP connect to app_drive-mcp failed: %v", err)
	}
	defer sess.Close()

	toolsList, err := sess.ListTools(ctx, nil)
	if err != nil || len(toolsList.Tools) != 2 {
		t.Fatalf("ListTools = %+v, err=%v", toolsList, err)
	}
	callOut, err := sess.CallTool(ctx, &mcp.CallToolParams{Name: "list_drive_files"})
	if err != nil || callOut.IsError {
		t.Fatalf("CallTool list_drive_files failed: %+v, err=%v", callOut, err)
	}
	txt := callOut.Content[0].(*mcp.TextContent).Text
	if !strings.Contains(txt, "Q4 Plan.gdoc") || strings.Contains(txt, secretVal) {
		t.Fatalf("unexpected MCP tool result: %s", txt)
	}

	// 4. Switching tool_scope to app_only blocks unrelated chats, while the app's dock chat still connects.
	e.want("PATCH", "/custom-apps/drive-mcp", map[string]any{
		"manifest": map[string]any{
			"entry":      "app.tsx",
			"mcp_entry":  "server.ts",
			"tool_scope": "app_only",
		},
	}, http.StatusOK)

	if s2, err := dial(token); err == nil {
		s2.Close()
		t.Fatal("unrelated chat connected to app_only custom app MCP server")
	}

	dockID := uuid.MustParse(e.newChat(map[string]any{"space_id": spaceID, "hidden": true})["id"].(string))
	dockTok := e.canvasToken(dockID)
	sDock, err := dial(dockTok)
	if err != nil {
		t.Fatalf("app dock chat should still connect when tool_scope=app_only: %v", err)
	}
	_ = sDock.Close()
}

func TestScheduledCustomAppToolRun(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()

	e.want("POST", "/custom-apps", map[string]any{
		"slug": "feed-sync",
		"name": "Feed Sync",
		"manifest": map[string]any{
			"entry":      "app.tsx",
			"mcp_entry":  "server.ts",
			"tool_scope": "app_only",
		},
		"files": map[string]string{
			"schema.sql": `CREATE TABLE IF NOT EXISTS synced (id INTEGER PRIMARY KEY, label TEXT NOT NULL);`,
			"app.tsx":    `export default function App() { return null; }`,
			"server.ts": `
import { defineServer, sql } from "@vesper/server";

export default defineServer({
  tools: {
    sync_items: {
      description: "Insert a synced row into SQLite",
      inputSchema: { type: "object", properties: { label: { type: "string" } } },
      handler: async ({ label }: { label?: string }) => {
        const val = label || "default";
        await sql("INSERT INTO synced (label) VALUES (?)", [val]);
        return { synced: val };
      },
    },
    fail_sync: {
      description: "Always fail to verify Inbox alerting",
      inputSchema: { type: "object", properties: {} },
      handler: async () => {
        throw new Error("upstream feed 503");
      },
    },
  },
});`,
		},
	}, http.StatusCreated)

	// Invalid app slug or unknown tool returns 422.
	e.invalid("POST", "/scheduled-tasks", map[string]any{
		"name":            "Bad app",
		"kind":            "custom_app",
		"custom_app_slug": "missing-app",
		"custom_app_tool": "sync_items",
		"frequency":       "daily",
		"at_time":         "08:00",
		"timezone":        "UTC",
		"enabled":         true,
	}, "custom_app_slug", "MCP server")

	e.invalid("POST", "/scheduled-tasks", map[string]any{
		"name":            "Bad tool",
		"kind":            "custom_app",
		"custom_app_slug": "feed-sync",
		"custom_app_tool": "nonexistent_tool",
		"frequency":       "daily",
		"at_time":         "08:00",
		"timezone":        "UTC",
		"enabled":         true,
	}, "custom_app_tool", "MCP tools")

	created := e.want("POST", "/scheduled-tasks", map[string]any{
		"name":            "Sync feed",
		"kind":            "custom_app",
		"custom_app_slug": "feed-sync",
		"custom_app_tool": "sync_items",
		"custom_app_args": map[string]any{"label": "Morning"},
		"frequency":       "daily",
		"at_time":         "08:00",
		"timezone":        "UTC",
		"enabled":         true,
	}, http.StatusOK)
	taskID := uuid.MustParse(created["id"].(string))

	// Move next_run_at to the past and execute via RunDueScheduled.
	past := time.Now().Add(-time.Hour)
	if err := e.q.AdvanceScheduledTask(ctx, store.AdvanceScheduledTaskParams{ID: taskID, NextRunAt: &past}); err != nil {
		t.Fatal(err)
	}
	if err := e.runs.RunDueScheduled(ctx); err != nil {
		t.Fatal(err)
	}

	listed := e.want("GET", "/scheduled-tasks", nil, http.StatusOK)
	taskRow := listed["tasks"].([]any)[0].(map[string]any)
	runsList := taskRow["runs"].([]any)
	if len(runsList) != 1 {
		t.Fatalf("expected 1 run, got %v", taskRow)
	}
	firstRun := runsList[0].(map[string]any)
	if firstRun["state"] != "done" || firstRun["cost_micros"] != float64(0) || firstRun["href"] != "/apps/feed-sync" || !strings.Contains(firstRun["summary"].(string), "Morning") {
		t.Fatalf("unexpected custom_app run = %v", firstRun)
	}

	// Verify SQLite write landed without an LLM turn.
	sqlRes := e.want("POST", "/custom-apps/feed-sync/invoke", map[string]any{
		"kind":  "sql",
		"query": "SELECT label FROM synced",
	}, http.StatusOK)
	rows := sqlRes["result"].(map[string]any)["rows"].([]any)
	if len(rows) != 1 || rows[0].(map[string]any)["label"] != "Morning" {
		t.Fatalf("expected SQLite row Morning, got %v", sqlRes)
	}

	// Quiet success does NOT appear in Inbox.
	inboxQuiet := e.want("GET", "/inbox", nil, http.StatusOK)
	for _, it := range inboxQuiet["items"].([]any) {
		item := it.(map[string]any)
		if item["kind"] == "scheduled" && item["title"] == "Sync feed" {
			t.Fatalf("routine custom_app success should stay out of Inbox: %v", item)
		}
	}

	// Update to fail_sync and trigger Run Now -> failure DOES appear in Inbox linking to /apps/feed-sync.
	rev := int(taskRow["revision"].(float64))
	e.want("PUT", "/scheduled-tasks/"+taskID.String(), map[string]any{
		"revision":        rev,
		"name":            "Sync feed",
		"kind":            "custom_app",
		"custom_app_slug": "feed-sync",
		"custom_app_tool": "fail_sync",
		"frequency":       "daily",
		"at_time":         "08:00",
		"timezone":        "UTC",
		"enabled":         true,
	}, http.StatusOK)

	afterFail := e.want("POST", "/scheduled-tasks/"+taskID.String()+"/run", nil, http.StatusOK)
	failRun := afterFail["runs"].([]any)[0].(map[string]any)
	if failRun["state"] != "failed" || !strings.Contains(failRun["error"].(string), "upstream feed 503") {
		t.Fatalf("expected failed run with error, got %v", failRun)
	}

	inboxFail := e.want("GET", "/inbox", nil, http.StatusOK)
	foundFail := false
	for _, it := range inboxFail["items"].([]any) {
		item := it.(map[string]any)
		if item["kind"] == "scheduled" && item["title"] == "Sync feed" {
			foundFail = true
			if item["href"] != "/apps/feed-sync" || !strings.Contains(item["summary"].(string), "upstream feed 503") {
				t.Fatalf("unexpected failed inbox item: %v", item)
			}
		}
	}
	if !foundFail {
		t.Fatal("failed custom_app scheduled run missing from Inbox")
	}

	// Chat tools: create, list, and update (preserving custom_app_slug/tool/args) work cleanly.
	chatID := uuid.MustParse(e.newChat(nil)["id"].(string))
	chatTok := e.canvasToken(chatID)
	code, chatCreated := e.tool(chatTok, "create_scheduled_task", map[string]any{
		"name":            "Hourly sync",
		"custom_app_slug": "feed-sync",
		"custom_app_tool": "sync_items",
		"custom_app_args": map[string]any{"label": "Chat"},
		"frequency":       "cron",
		"cron":            "0 * * * *",
		"timezone":        "UTC",
	})
	if code != http.StatusOK {
		t.Fatalf("chat create_scheduled_task = %d %v", code, chatCreated)
	}
	chatTaskID := chatCreated["task_id"].(string)

	code, chatListed := e.tool(chatTok, "list_scheduled_tasks", map[string]any{})
	if code != http.StatusOK {
		t.Fatalf("chat list_scheduled_tasks = %d %v", code, chatListed)
	}
	var chatRev any
	for _, raw := range chatListed["tasks"].([]any) {
		m := raw.(map[string]any)
		if m["task_id"] == chatTaskID {
			chatRev = m["revision"]
			if m["kind"] != "custom_app" || m["custom_app_slug"] != "feed-sync" || m["custom_app_tool"] != "sync_items" {
				t.Fatalf("unexpected chat scheduled task: %v", m)
			}
		}
	}
	if chatRev == nil {
		t.Fatalf("chat task missing from list_scheduled_tasks: %v", chatListed)
	}

	code, badEdit := e.tool(chatTok, "update_scheduled_task", map[string]any{
		"task_id":      chatTaskID,
		"revision":     chatRev,
		"instructions": "nope",
	})
	if code != http.StatusUnprocessableEntity {
		t.Fatalf("instructions on custom_app task = %d %v, want 422", code, badEdit)
	}

	code, chatUpdated := e.tool(chatTok, "update_scheduled_task", map[string]any{
		"task_id":  chatTaskID,
		"revision": chatRev,
		"enabled":  false,
	})
	if code != http.StatusOK {
		t.Fatalf("chat update_scheduled_task = %d %v", code, chatUpdated)
	}
	updatedMap := chatUpdated["task"].(map[string]any)
	if updatedMap["enabled"] != false || updatedMap["custom_app_slug"] != "feed-sync" || updatedMap["custom_app_tool"] != "sync_items" {
		t.Fatalf("custom_app fields lost on update: %v", updatedMap)
	}

	// Deleting the Custom App cascades and removes its scheduled tasks.
	e.want("DELETE", "/custom-apps/feed-sync", nil, http.StatusNoContent)
	afterDel := e.want("GET", "/scheduled-tasks", nil, http.StatusOK)
	if len(afterDel["tasks"].([]any)) != 0 {
		t.Fatalf("expected scheduled tasks deleted with custom app, got %v", afterDel)
	}
}

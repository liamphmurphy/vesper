package httpapi

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

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

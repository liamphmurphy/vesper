package httpapi

import (
	"encoding/json"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"strings"
	"testing"
)

// Exercise the actual REST/MCP tool boundary: identity must come from chat
// ownership, and caller-supplied audience/owner fields never grant sharing.
func TestWikiAudienceToolBoundary(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	ws := e.me.WorkspaceID
	private := e.want("POST", "/wiki/pages", map[string]any{"path": "Old private alias", "body_md": "Private payload 75b4"}, 201)
	id := private["id"].(string)
	if private["audience"] != "private" {
		t.Fatalf("new page default: %v", private)
	}
	e.want("PUT", "/wiki/pages/"+id, map[string]any{"path": "Vault/Secret title 4218"}, 200)
	shared := e.want("POST", "/wiki/pages", map[string]any{"path": "Shared entry", "body_md": "See [[Old private alias]].", "audience": "shared"}, 201)
	atlas, err := e.q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}
	tk, err := e.q.GetTicketByKey(ctx, store.GetTicketByKeyParams{WorkspaceID: ws, Key: e.payKey})
	if err != nil {
		t.Fatal(err)
	}
	run, err := e.q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, TicketID: &tk.ID, AgentID: atlas.ID, Mode: "managed", State: "running", Purpose: "ticket", Harness: "claude", Model: "test", ResolvedSpec: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, e.q, atlas.ID, "run", "audience", &run.ID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	code, out := e.tool(token, "read_page", map[string]any{"ref": "Shared entry"})
	raw, _ := json.Marshal(out)
	if code != 200 || !strings.Contains(string(raw), "Old private alias") || strings.Contains(string(raw), "Secret title") || strings.Contains(string(raw), "Private payload") || strings.Contains(string(raw), id) {
		t.Fatalf("ghost link response: %d %s", code, raw)
	}
	for _, ref := range []string{id, "Old private alias", "Vault/Secret title 4218"} {
		if code, out := e.tool(token, "read_page", map[string]any{"ref": ref}); code == 200 {
			t.Fatalf("run read private page: %v", out)
		}
	}
	// An agent cannot turn a shared page private via an extra tool argument.
	if code, out := e.tool(token, "write_note", map[string]any{"path": "Shared entry", "body": "Agent version", "audience": "private", "owner_user_id": e.me.ID.String()}); code != 200 {
		t.Fatalf("agent write: %d %v", code, out)
	}
	if got := e.want("GET", "/wiki/page?path=Shared%20entry", nil, 200); got["audience"] != "shared" {
		t.Fatalf("agent changed audience: %v", got)
	}
	chat := e.newChat(nil)
	chatID := uuid.MustParse(chat["id"].(string))
	persona := e.canvasToken(chatID)
	if code, out := e.tool(persona, "read_page", map[string]any{"ref": id}); code != 200 {
		t.Fatalf("owner's persona cannot read: %d %v", code, out)
	}
	if code, out := e.tool(persona, "write_note", map[string]any{"path": "Vault/Secret title 4218", "body": "Persona private edit", "audience": "shared"}); code != 200 {
		t.Fatalf("persona edit: %d %v", code, out)
	}
	if got := e.want("GET", "/wiki/page?path=Vault/Secret%20title%204218", nil, 200); got["audience"] != "private" || got["body_md"] != "Persona private edit" {
		t.Fatalf("persona changed audience or didn't edit directly: %v", got)
	}
	// Sharing is an explicit person action on the REST API.
	e.want("PUT", "/wiki/pages/"+id, map[string]any{"audience": "shared"}, 200)
	if code, out := e.tool(token, "read_page", map[string]any{"ref": id}); code != 200 {
		t.Fatalf("shared page unavailable: %d %v", code, out)
	}
	// Agent knowledge discovery is opt-in for the person's API requests.
	if code, out := e.tool(token, "write_note", map[string]any{"path": "agents/atlas/Discoveryneedle", "body": "Discoveryneedle [[Shared entry]]"}); code != 200 {
		t.Fatalf("agent memory: %d %v", code, out)
	}
	for _, route := range []string{"/knowledge/search?q=Discoveryneedle", "/knowledge/suggest?q=Discoveryneedle", "/knowledge/graph?kind=artifact&id=" + shared["id"].(string)} {
		hidden := e.want("GET", route, nil, 200)
		included := e.want("GET", route+"&include_agent=true", nil, 200)
		a, _ := json.Marshal(hidden)
		b, _ := json.Marshal(included)
		if strings.Contains(string(a), "Discoveryneedle") || !strings.Contains(string(b), "Discoveryneedle") {
			t.Fatalf("discovery %s: hidden=%s included=%s", route, a, b)
		}
	}
}

func TestWikiAudienceSavesUsePageID(t *testing.T) {
	e := newChatEnv(t)
	shared := e.want("POST", "/wiki/pages", map[string]any{"path": "Overlapping path", "body_md": "Shared body", "audience": "shared"}, 201)
	private := e.want("POST", "/wiki/pages", map[string]any{"path": "Overlapping path", "body_md": "Private body"}, 201)
	sid := shared["id"].(string)
	pid := private["id"].(string)
	e.want("PUT", "/wiki/pages/"+sid, map[string]any{"body_md": "Updated shared body"}, 200)
	if got := e.want("GET", "/artifacts/"+sid, nil, 200); got["body_md"] != "Updated shared body" || got["audience"] != "shared" {
		t.Fatalf("wrong shared save: %v", got)
	}
	if got := e.want("GET", "/artifacts/"+pid, nil, 200); got["body_md"] != "Private body" || got["audience"] != "private" {
		t.Fatalf("private page was overwritten: %v", got)
	}
	e.want("PUT", "/wiki/pages/"+pid, map[string]any{"audience": "shared"}, 409)
}

func TestWikiAudienceMentionEditsUseSourceID(t *testing.T) {
	e := newChatEnv(t)
	target := e.want("POST", "/wiki/pages", map[string]any{"path": "Mention target", "body_md": "Target", "audience": "shared"}, 201)
	shared := e.want("POST", "/wiki/pages", map[string]any{"path": "Mention overlap", "body_md": "See Mention target", "audience": "shared"}, 201)
	private := e.want("POST", "/wiki/pages", map[string]any{"path": "Mention overlap", "body_md": "Private sentinel"}, 201)
	e.want("POST", "/knowledge/link-mention", map[string]any{"target_kind": "artifact", "target_id": target["id"], "source_kind": "artifact", "source_id": shared["id"]}, 204)
	if got := e.want("GET", "/artifacts/"+shared["id"].(string), nil, 200); got["body_md"] != "See [[Mention target]]" {
		t.Fatalf("shared source not edited: %v", got)
	}
	if got := e.want("GET", "/artifacts/"+private["id"].(string), nil, 200); got["body_md"] != "Private sentinel" {
		t.Fatalf("private page overwritten: %v", got)
	}
}

func TestWikiAudienceLibraryIncludesOwnedPrivatePages(t *testing.T) {
	e := newChatEnv(t)
	private := e.want("POST", "/wiki/pages", map[string]any{"path": "Libraryprivateneedle175", "body_md": "Private sentinel"}, 201)
	out := e.want("GET", "/artifacts?type=note&q=Libraryprivateneedle175", nil, 200)
	rows := out["artifacts"].([]any)
	if len(rows) != 1 || rows[0].(map[string]any)["id"] != private["id"] || out["counts"].(map[string]any)["note"] != float64(1) {
		t.Fatalf("owner's Library list/count lost private page: %v", out)
	}
	// A different person's private page must not enter either the list or count.
	other := uuid.New()
	if _, err := e.pool.Exec(t.Context(), `INSERT INTO users(id,workspace_id,name,email,initials,password_hash) VALUES($1,$2,'Other','other175@example.com','O','x')`, other, e.me.WorkspaceID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(t.Context(), `UPDATE artifacts SET owner_user_id=$2 WHERE id=$1`, private["id"], other); err != nil {
		t.Fatal(err)
	}
	out = e.want("GET", "/artifacts?type=note&q=Libraryprivateneedle175", nil, 200)
	if len(out["artifacts"].([]any)) != 0 || out["counts"].(map[string]any)["note"] != float64(0) {
		t.Fatalf("other owner's page leaked: %v", out)
	}
}

// The owner authorizes a deterministic terminal write at the gate. The model
// never gets a person viewer or the existing private body as step context.
func TestWikiAudienceWorkflowTerminalWritesAsOwner(t *testing.T) {
	for _, mode := range []string{"replace", "append"} {
		t.Run(mode, func(t *testing.T) {
			e := newChatEnv(t)
			private := e.want("POST", "/wiki/pages", map[string]any{"path": "Workflows/Result", "body_md": "Private workflow sentinel 175"}, 201)
			graph := gatedWorkflowGraph()
			for _, node := range graph["nodes"].([]map[string]any) {
				if node["id"] == "page" {
					node["config"].(map[string]any)["mode"] = mode
				}
			}
			wf := e.want("POST", "/workflows", map[string]any{"name": "Owner-authorized output"}, 201)["id"].(string)
			e.want("PATCH", "/workflows/"+wf, map[string]any{"graph": graph}, 200)
			e.want("POST", "/workflows/"+wf+"/publish", nil, 200)
			chat := e.newChat(nil)["id"].(string)
			run := e.want("POST", "/chats/"+chat+"/workflows", map[string]any{"workflow_id": wf, "input": "Write new text"}, 201)
			id := run["id"].(string)
			run = e.finishWFStep(t, id, "brief", "New brief")
			var prompt string
			if err := e.pool.QueryRow(t.Context(), `SELECT input_message FROM run_turns WHERE run_id=$1`, e.wfStep(run, "work")["agent_run_id"]).Scan(&prompt); err != nil {
				t.Fatal(err)
			}
			if strings.Contains(prompt, "Private workflow sentinel") {
				t.Fatal("private body reached the model")
			}
			e.finishWFStep(t, id, "work", "New workflow text")
			if got := e.want("GET", "/artifacts/"+private["id"].(string), nil, 200); got["body_md"] != "Private workflow sentinel 175" {
				t.Fatal("output ran before approval")
			}
			run = e.want("POST", "/workflow-runs/"+id+"/gate", map[string]any{"node_id": "review", "decision": "approve"}, 200)
			if run["state"] != "done" {
				t.Fatalf("terminal output didn't finish: %v", run)
			}
			raw, _ := json.Marshal(run)
			if strings.Contains(string(raw), "Private workflow sentinel") {
				t.Fatalf("private body reached workflow step output: %s", raw)
			}
			want := "New workflow text"
			if mode == "append" {
				want = "Private workflow sentinel 175\n\nNew workflow text"
			}
			if got := e.want("GET", "/artifacts/"+private["id"].(string), nil, 200); got["audience"] != "private" || got["body_md"] != want {
				t.Fatalf("owner's %s output: %v", mode, got)
			}
		})
	}
}

func TestWikiAudiencePropertyReaders(t *testing.T) {
	e := newChatEnv(t)
	page := e.want("POST", "/wiki/pages", map[string]any{"path": "Private metadata page", "body_md": "Private metadata body", "aliases": []string{"Private metadata alias 175"}, "tags": []string{"privatetag175"}}, 201)
	id := uuid.MustParse(page["id"].(string))
	ctx := t.Context()
	ws := e.me.WorkspaceID
	if a, err := e.q.FindNoteByAlias(ctx, store.FindNoteByAliasParams{WorkspaceID: ws, Path: "Private metadata alias 175"}); err != pgx.ErrNoRows {
		t.Fatalf("run private alias lookup: %+v %v", a, err)
	}
	if taken, err := e.q.PropertyAliasTaken(ctx, store.PropertyAliasTakenParams{WorkspaceID: ws, Path: "Private metadata alias 175"}); err != nil || taken {
		t.Fatalf("private alias existence leaked: %v %v", taken, err)
	}
	if tags, err := e.q.PageTags(ctx, store.PageTagsParams{ArtifactID: id}); err != nil || len(tags) != 0 {
		t.Fatalf("private tags leaked: %v %v", tags, err)
	}
	tags, err := e.q.PageTags(ctx, store.PageTagsParams{ArtifactID: id, Viewer: &e.me.ID})
	if err != nil || len(tags) != 1 || tags[0] != "privatetag175" {
		t.Fatalf("owner tags: %v %v", tags, err)
	}
	tag := "privatetag175"
	if rows, err := e.q.ListNotes(ctx, store.ListNotesParams{WorkspaceID: ws, Tag: &tag, IncludeAgent: true}); err != nil || len(rows) != 0 {
		t.Fatalf("tag discovery leaked private page: %v %v", rows, err)
	}
}

func TestWikiAudiencePersonaCreatesInAgentAndMovesToPersonal(t *testing.T) {
	e := newChatEnv(t)
	chat := e.newChat(nil)
	personaToken := e.canvasToken(uuid.MustParse(chat["id"].(string)))

	code, created := e.tool(personaToken, "create_page", map[string]any{
		"title": "Persona Draft",
		"body":  "Drafted in chat",
	})
	if code != 200 {
		t.Fatalf("create_page = %d %v", code, created)
	}
	id := created["id"].(string)

	page := e.want("GET", "/knowledge/pages/"+id, nil, 200)
	if page["audience"] != "agent" {
		t.Fatalf("persona-created page audience = %v, want agent", page["audience"])
	}

	// Person can promote the persona-created page to Personal (private).
	moved := e.want("PUT", "/wiki/pages/"+id, map[string]any{"audience": "private"}, 200)
	if moved["audience"] != "private" {
		t.Fatalf("moved page audience = %v, want private", moved["audience"])
	}

	// And can move it back to Personas (agent) if desired.
	back := e.want("PUT", "/wiki/pages/"+id, map[string]any{"audience": "agent"}, 200)
	if back["audience"] != "agent" {
		t.Fatalf("moved-back page audience = %v, want agent", back["audience"])
	}
}

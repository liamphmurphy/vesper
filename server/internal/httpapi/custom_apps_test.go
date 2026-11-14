package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
)

func TestCustomAppsHTTPInvokeAndCapabilities(t *testing.T) {
	e := newChatEnv(t)

	// Reserved built-in routes are refused; "finance" is explicitly allowed.
	e.invalid("POST", "/custom-apps", map[string]any{
		"slug": "slides",
		"name": "Bad Slug",
	}, "slug", "reserved")

	// Broken TSX reports compiler errors with 422.
	e.invalid("POST", "/custom-apps", map[string]any{
		"slug": "broken",
		"name": "Broken",
		"files": map[string]string{
			"app.tsx": "export default function () { return <div }",
		},
	}, "files", "compile error")

	created := e.want("POST", "/custom-apps", map[string]any{
		"slug":     "finance",
		"name":     "Finance",
		"template": "ledger",
	}, http.StatusCreated)
	if created["slug"] != "finance" || created["current_seq"] != float64(1) || created["space_id"] == nil {
		t.Fatalf("created = %v", created)
	}
	spaceID := created["space_id"].(string)

	// List & get.
	listed := e.want("GET", "/custom-apps", nil, http.StatusOK)
	apps := listed["apps"].([]any)
	if len(apps) != 1 || apps[0].(map[string]any)["slug"] != "finance" {
		t.Fatalf("listed = %v", listed)
	}
	got := e.want("GET", "/custom-apps/finance", nil, http.StatusOK)
	cur := got["current"].(map[string]any)
	if !strings.Contains(cur["bundle_js"].(string), "vesper:custom-app") {
		t.Fatalf("bundle_js missing runtime")
	}

	// Default app.sql:write and app.sql:read are allowed.
	e.want("POST", "/custom-apps/finance/invoke", map[string]any{
		"kind":   "sql",
		"query":  "INSERT INTO entries (label, category, amount) VALUES (?, ?, ?)",
		"params": []any{"Rent", "housing", 1800},
	}, http.StatusOK)
	sqlOut := e.want("POST", "/custom-apps/finance/invoke", map[string]any{
		"kind":  "sql",
		"query": "SELECT label, category, amount FROM entries",
	}, http.StatusOK)
	rows := sqlOut["result"].(map[string]any)["rows"].([]any)
	if len(rows) != 1 || rows[0].(map[string]any)["label"] != "Rent" {
		t.Fatalf("sqlOut = %v", sqlOut)
	}

	// Default vesper.api:read is denied (403).
	code, deniedOut := e.do("POST", "/custom-apps/finance/invoke", map[string]any{
		"kind":   "api",
		"method": "GET",
		"path":   "/api/v1/tickets",
	})
	if code != http.StatusForbidden {
		t.Fatalf("default vesper.api:read = %d %v, want 403", code, deniedOut)
	}

	// Enable vesper.api:read as requires_approval -> prompt -> approved + always_allow.
	e.want("PATCH", "/custom-apps/finance", map[string]any{
		"capabilities": map[string]any{
			"app.sql:read":    "allowed",
			"app.sql:write":   "allowed",
			"vesper.api:read": "requires_approval",
		},
	}, http.StatusOK)

	prompt := e.want("POST", "/custom-apps/finance/invoke", map[string]any{
		"kind":   "api",
		"method": "GET",
		"path":   "/api/v1/projects",
	}, http.StatusOK)
	if prompt["status"] != "approval_required" || prompt["capability"] != "vesper.api:read" {
		t.Fatalf("prompt = %v", prompt)
	}

	okRes := e.want("POST", "/custom-apps/finance/invoke", map[string]any{
		"kind":         "api",
		"method":       "GET",
		"path":         "/api/v1/projects",
		"approved":     true,
		"always_allow": true,
	}, http.StatusOK)
	if okRes["status"] != "ok" || okRes["result"] == nil {
		t.Fatalf("approved api = %v", okRes)
	}

	// Subsequent call runs directly without approval prompt.
	okAgain := e.want("POST", "/custom-apps/finance/invoke", map[string]any{
		"kind":   "api",
		"method": "GET",
		"path":   "/api/v1/projects",
	}, http.StatusOK)
	if okAgain["status"] != "ok" {
		t.Fatalf("second api invoke = %v", okAgain)
	}

	// Restricted endpoints & path traversal are refused with 422.
	e.invalid("POST", "/custom-apps/finance/invoke", map[string]any{
		"kind":   "api",
		"method": "GET",
		"path":   "/api/v1/tickets/../custom-apps",
	}, "path", "restricted")

	// Update code (v2), read v1, and restore v1 -> v3.
	v2 := e.want("PATCH", "/custom-apps/finance", map[string]any{
		"files": map[string]string{"app.tsx": "export default function App() { return <div>v2</div>; }"},
		"note":  "second version",
	}, http.StatusOK)
	if v2["current_seq"] != float64(2) {
		t.Fatalf("v2 = %v", v2)
	}
	v1 := e.want("GET", "/custom-apps/finance/versions/1", nil, http.StatusOK)
	if v1["seq"] != float64(1) {
		t.Fatalf("v1 = %v", v1)
	}
	v3 := e.want("PATCH", "/custom-apps/finance", map[string]any{"restore_seq": 1}, http.StatusOK)
	if v3["current_seq"] != float64(3) {
		t.Fatalf("v3 = %v", v3)
	}

	// Dock chats support app:custom:<slug> scope, and space chats work on the app's hidden space.
	dockChat := e.newChat(map[string]any{"space_id": spaceID, "hidden": true})["id"].(string)
	e.want("POST", "/dock-chats", map[string]any{"scope": "app:custom:finance", "chat_id": dockChat}, http.StatusNoContent)
	dockList := e.want("GET", "/dock-chats?scope=app:custom:finance", nil, http.StatusOK)
	if len(dockList["chats"].([]any)) != 1 {
		t.Fatalf("dockList = %v", dockList)
	}

	// Delete cleans up the app and its dock chats.
	e.want("DELETE", "/custom-apps/finance", nil, http.StatusNoContent)
	if code, _ := e.do("GET", "/custom-apps/finance", nil); code != http.StatusNotFound {
		t.Fatalf("GET after delete = %d, want 404", code)
	}
	dockAfter := e.want("GET", "/dock-chats?scope=app:custom:finance", nil, http.StatusOK)
	if len(dockAfter["chats"].([]any)) != 0 {
		t.Fatalf("dockAfter delete = %v, want empty", dockAfter)
	}
}

func TestCustomAppMCPToolsAndScope(t *testing.T) {
	e := newChatEnv(t)

	otherChat := uuid.MustParse(e.newChat(nil)["id"].(string))
	otherToken := e.canvasToken(otherChat)

	// Persona creates an app via create_custom_app.
	code, created := e.tool(otherToken, "create_custom_app", map[string]any{
		"slug":     "habits",
		"name":     "Habits",
		"template": "tracker",
		"manifest": map[string]any{
			"entry":      "app.tsx",
			"tool_scope": "app_only",
		},
	})
	if code != http.StatusOK || created["slug"] != "habits" || created["version"] != float64(1) {
		t.Fatalf("create_custom_app = %d %v", code, created)
	}

	// General chat cannot call custom_app_sql when tool_scope is app_only.
	code, out := e.tool(otherToken, "custom_app_sql", map[string]any{
		"slug":  "habits",
		"query": "SELECT count(*) AS n FROM items",
	})
	if code != http.StatusConflict || !strings.Contains(out["message"].(string), "app's own dock chat") {
		t.Fatalf("out-of-scope custom_app_sql = %d %v, want 409", code, out)
	}

	// Fetch the app's space_id and open a dock chat inside that space.
	appDetail := e.want("GET", "/custom-apps/habits", nil, http.StatusOK)
	spaceID := appDetail["space_id"].(string)
	appChatID := uuid.MustParse(e.newChat(map[string]any{"space_id": spaceID, "hidden": true})["id"].(string))
	appToken := e.canvasToken(appChatID)

	code, sqlRes := e.tool(appToken, "custom_app_sql", map[string]any{
		"slug":   "habits",
		"query":  "INSERT INTO items (title) VALUES (?)",
		"params": []any{"Read 20 pages"},
	})
	if code != http.StatusOK || sqlRes["changes"] != float64(1) {
		t.Fatalf("in-scope insert = %d %v", code, sqlRes)
	}

	// Update and get work cleanly from agent tools.
	code, upRes := e.tool(appToken, "update_custom_app", map[string]any{
		"slug":  "habits",
		"files": map[string]string{"app.tsx": "export default function App() { return <div>Updated</div>; }"},
		"note":  "persona edit",
	})
	if code != http.StatusOK || upRes["version"] != float64(2) {
		t.Fatalf("update_custom_app = %d %v", code, upRes)
	}

	code, got := e.tool(appToken, "get_custom_app", map[string]any{"slug": "habits"})
	if code != http.StatusOK || got["version"] != float64(2) || len(got["schema"].([]any)) == 0 {
		t.Fatalf("get_custom_app = %d %v", code, got)
	}

	code, listRes := e.tool(appToken, "list_custom_apps", map[string]any{})
	if code != http.StatusOK || len(listRes["apps"].([]any)) != 1 {
		t.Fatalf("list_custom_apps = %d %v", code, listRes)
	}

	// Verify agent_id attribution was recorded as persona on v2.
	versions := appDetail["versions"].([]any)
	_ = versions
	latestDetail := e.want("GET", "/custom-apps/habits", nil, http.StatusOK)
	v2Summary := latestDetail["versions"].([]any)[0].(map[string]any)
	if v2Summary["author_type"] != "persona" || v2Summary["agent_id"] == nil {
		t.Fatalf("expected persona author on v2, got %v", v2Summary)
	}

	_ = agents.Caller{}
	_ = context.Background()

	code, delRes := e.tool(appToken, "delete_custom_app", map[string]any{"slug": "habits"})
	if code != http.StatusOK || delRes["deleted"] != "habits" {
		t.Fatalf("delete_custom_app = %d %v", code, delRes)
	}
}

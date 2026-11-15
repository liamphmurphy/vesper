package httpapi

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/connectors"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

// An app's server.ts reaches an API through an OAuth secret whose token has
// already lapsed: Vesper refreshes it on the way, and the app never sees a
// token, a refresh token or the client secret.
func TestOAuthApiSecretSignInAndRefreshThroughAppServer(t *testing.T) {
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: testBox(t)}
		s.PublicURL = "https://vesper.example.ts.net"
	})

	var mu sync.Mutex
	var grants []url.Values
	issued := 0
	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = r.ParseForm()
		mu.Lock()
		grants = append(grants, r.PostForm)
		issued++
		n := strconv.Itoa(issued)
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		// 30 s is inside the refresh margin, so the next request must refresh.
		_, _ = io.WriteString(w, `{"access_token":"access-`+n+`","refresh_token":"refresh-1","expires_in":30}`)
	}))
	t.Cleanup(provider.Close)
	var sentAuth string
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		sentAuth = r.Header.Get("Authorization")
		mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"auth":"`+r.Header.Get("Authorization")+`"}`)
	}))
	t.Cleanup(api.Close)

	created := e.want("POST", "/api-secrets", map[string]any{
		"name": "Google Drive", "placement": "bearer", "allowed_hosts": []string{"127.0.0.1"}, "read_policy": "allow",
		"oauth": map[string]any{"authorize_url": "https://accounts.example.com/o/oauth2/auth", "token_url": provider.URL + "/token",
			"client_id": "client-123", "client_secret": "client-secret-xyz", "scopes": []string{"drive.readonly"}},
	}, http.StatusOK)
	id, handle := created["id"].(string), created["handle"].(string)
	oauth, _ := created["oauth"].(map[string]any)
	if created["kind"] != "oauth" || oauth == nil || oauth["has_client_secret"] != true || oauth["signed_in_at"] != nil {
		t.Fatalf("created = %v", created)
	}
	if raw, _ := json.Marshal(e.want("GET", "/api-secrets", nil, http.StatusOK)); strings.Contains(string(raw), "client-secret-xyz") {
		t.Fatal("client secret returned by the API")
	}
	e.invalid("PATCH", "/api-secrets/"+id, map[string]any{"revision": created["revision"], "value": "pasted"}, "value", "sign in")

	signIn := e.want("POST", "/api-secrets/"+id+"/sign-in", nil, http.StatusOK)
	link, _ := url.Parse(signIn["authorize_url"].(string))
	aq := link.Query()
	if aq.Get("redirect_uri") != "https://vesper.example.ts.net"+connectors.CallbackPath || aq.Get("client_id") != "client-123" {
		t.Fatalf("authorize_url = %s", link)
	}

	// The provider sends the browser back to the callback connectors share.
	res, err := http.Get(e.srv.URL + connectors.CallbackPath + "?state=" + url.QueryEscape(aq.Get("state")) + "&code=the-code")
	if err != nil {
		t.Fatal(err)
	}
	page, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if !strings.Contains(string(page), "Signed in") {
		t.Fatalf("callback page: %s", page)
	}
	list := e.want("GET", "/api-secrets", nil, http.StatusOK)
	if list["oauth_redirect_uri"] != aq.Get("redirect_uri") {
		t.Fatalf("oauth_redirect_uri = %v, sign-in used %q", list["oauth_redirect_uri"], aq.Get("redirect_uri"))
	}
	listed := list["secrets"].([]any)[0].(map[string]any)
	if listed["oauth"].(map[string]any)["signed_in_at"] == nil {
		t.Fatalf("not signed in after callback: %v", listed)
	}

	e.want("POST", "/custom-apps", map[string]any{
		"slug": "drive", "name": "Drive",
		"manifest": map[string]any{"entry": "app.tsx", "mcp_entry": "server.ts", "tool_scope": "chats",
			"requested_capabilities": map[string]any{"secret:" + handle: "allowed"}},
		"files": map[string]string{
			"app.tsx": `export default function App() { return null; }`,
			"server.ts": `import { defineServer, secretFetch } from "@vesper/server";
export default defineServer({ tools: { whoami: { description: "echo auth", inputSchema: { type: "object", properties: {} },
  handler: async () => (await secretFetch("` + handle + `", "` + api.URL + `/drive/v3/about")).json() } } });`,
		},
	}, http.StatusCreated)
	out := e.want("POST", "/custom-apps/drive/invoke", map[string]any{"kind": "mcp", "connector": "self", "tool": "whoami", "approved": true, "always_allow": true}, http.StatusOK)
	if out["status"] != "ok" {
		t.Fatalf("invoke = %v", out)
	}
	// Masked, so the app can't read it; the refresh is what this checks.
	if auth := out["result"].(map[string]any)["auth"]; auth != "Bearer ‹"+handle+"›" {
		t.Fatalf("upstream auth as the app sees it = %v", auth)
	}
	mu.Lock()
	defer mu.Unlock()
	if sentAuth != "Bearer access-2" {
		t.Fatalf("upstream got %q, want the refreshed token", sentAuth)
	}
	if len(grants) != 2 || grants[0].Get("grant_type") != "authorization_code" || grants[0].Get("code") != "the-code" ||
		grants[1].Get("grant_type") != "refresh_token" || grants[1].Get("refresh_token") != "refresh-1" || grants[1].Get("client_secret") != "client-secret-xyz" {
		t.Fatalf("token endpoint saw %v", grants)
	}
}

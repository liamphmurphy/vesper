package connectors

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// A tool whose schema marks parameters with x-mcp-header gets the matching
// Mcp-Param-<name> headers, which servers such as GitHub's reject calls without.
func TestCallSendsParamHeaders(t *testing.T) {
	ctx := context.Background()
	srv := mcp.NewServer(&mcp.Implementation{Name: "up", Version: "1"}, nil)
	schema := json.RawMessage(`{"type":"object","properties":{
		"owner":{"type":"string","x-mcp-header":"owner"},
		"repo":{"type":"string","x-mcp-header":"repo"},
		"state":{"type":"string"}},"required":["owner","repo"]}`)
	var got http.Header
	srv.AddTool(&mcp.Tool{Name: "list_issues", InputSchema: schema}, func(_ context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: "ok"}}}, nil
	})
	// Stateless, like GitHub's hosted server: only then does the session use
	// protocol 2026-07-28, where the server checks Mcp-Param-* headers.
	h := mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return srv }, &mcp.StreamableHTTPOptions{Stateless: true, DisableLocalhostProtection: true})
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Mcp-Method") == "tools/call" {
			got = r.Header.Clone()
		}
		h.ServeHTTP(w, r)
	}))
	t.Cleanup(up.Close)

	svc := &Service{}
	sess, _, err := svc.open(ctx, up.URL, "")
	if err != nil {
		t.Fatal(err)
	}
	tools, err := list(ctx, sess)
	sess.Close()
	if err != nil {
		t.Fatal(err)
	}
	raw, _ := json.Marshal(tools)
	c := store.Connector{Name: "Up", Url: up.URL, AuthKind: AuthNone, Tools: raw}

	res, err := svc.Call(ctx, c, "list_issues", json.RawMessage(`{"owner":"liamphmurphy","repo":"Vesper","state":"open"}`))
	if err != nil {
		t.Fatal(err)
	}
	if res.IsError {
		t.Fatalf("call failed: %+v", res.Content[0])
	}
	if got.Get("Mcp-Param-owner") != "liamphmurphy" || got.Get("Mcp-Param-repo") != "Vesper" {
		t.Fatalf("headers = %v", got)
	}
}

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func jsonHTTPResponse(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func TestPresetsIncludeGoogleDrive(t *testing.T) {
	presets := Presets()
	var foundGoogle bool
	for _, p := range presets {
		if p.ID == "google-drive" {
			foundGoogle = true
			if p.URL != "https://drivemcp.googleapis.com/mcp/v1" {
				t.Fatalf("unexpected google-drive URL: %q", p.URL)
			}
			if p.AuthKind != AuthOAuth || !p.OAuthClientRequired {
				t.Fatalf("unexpected google-drive auth config: auth=%q required=%v", p.AuthKind, p.OAuthClientRequired)
			}
			if !slices.Contains(p.DefaultScopes, "https://www.googleapis.com/auth/drive.readonly") {
				t.Fatalf("missing drive.readonly default scope: %v", p.DefaultScopes)
			}
			if !slices.Contains(p.DefaultScopes, "https://www.googleapis.com/auth/drive.file") {
				t.Fatalf("missing drive.file default scope: %v", p.DefaultScopes)
			}
			if p.SetupHint == "" {
				t.Fatal("expected non-empty setup hint for google-drive")
			}
		}
	}
	if !foundGoogle {
		t.Fatal("google-drive preset not found")
	}

	if p, ok := PresetForURL("https://DRIVEMCP.googleapis.com/mcp/v1/"); !ok || p.ID != "google-drive" {
		t.Fatalf("PresetForURL mismatch: ok=%v id=%q", ok, p.ID)
	}

	gotScopes := NormalizeScopes([]string{"https://a, https://b\nhttps://a  https://c"})
	wantScopes := []string{"https://a", "https://b", "https://c"}
	if !slices.Equal(gotScopes, wantScopes) {
		t.Fatalf("NormalizeScopes = %v, want %v", gotScopes, wantScopes)
	}
}

func TestDiscoverPrefersProtectedResourceScopes(t *testing.T) {
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch r.URL.String() {
		case "https://drivemcp.googleapis.com/.well-known/oauth-protected-resource/mcp/v1",
			"https://drivemcp.googleapis.com/.well-known/oauth-protected-resource":
			return jsonHTTPResponse(http.StatusOK, `{
				"resource": "https://drivemcp.googleapis.com/mcp/v1",
				"authorization_servers": ["https://accounts.google.com/"],
				"scopes_supported": [
					"https://www.googleapis.com/auth/drive.readonly",
					"https://www.googleapis.com/auth/drive.file"
				]
			}`), nil
		case "https://accounts.google.com/.well-known/oauth-authorization-server":
			return jsonHTTPResponse(http.StatusNotFound, `{}`), nil
		case "https://accounts.google.com/.well-known/openid-configuration":
			return jsonHTTPResponse(http.StatusOK, `{
				"authorization_endpoint": "https://accounts.google.com/o/oauth2/v2/auth",
				"token_endpoint": "https://oauth2.googleapis.com/token",
				"scopes_supported": ["openid", "email", "profile"]
			}`), nil
		default:
			return jsonHTTPResponse(http.StatusNotFound, `{}`), nil
		}
	})

	svc := &Service{HTTP: transport}
	as, err := svc.discover(context.Background(), "https://drivemcp.googleapis.com/mcp/v1")
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	if as.AuthorizationEndpoint != "https://accounts.google.com/o/oauth2/v2/auth" {
		t.Fatalf("unexpected authorization_endpoint: %q", as.AuthorizationEndpoint)
	}
	if as.TokenEndpoint != "https://oauth2.googleapis.com/token" {
		t.Fatalf("unexpected token_endpoint: %q", as.TokenEndpoint)
	}
	if as.RegistrationEndpoint != "" {
		t.Fatalf("expected empty registration_endpoint, got %q", as.RegistrationEndpoint)
	}
	wantScopes := []string{
		"https://www.googleapis.com/auth/drive.readonly",
		"https://www.googleapis.com/auth/drive.file",
	}
	if !slices.Equal(as.ScopesSupported, wantScopes) {
		t.Fatalf("ScopesSupported = %v, want %v", as.ScopesSupported, wantScopes)
	}
}

func TestOAuthPreRegisteredClientAndScopes(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	q := store.New(pool)
	me, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatalf("GetLocalUser: %v", err)
	}
	box, err := secrets.NewBox("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
	if err != nil {
		t.Fatalf("NewBox: %v", err)
	}

	var tokenRequests []url.Values
	transport := roundTripFunc(func(r *http.Request) (*http.Response, error) {
		switch {
		case strings.HasPrefix(r.URL.String(), "https://drivemcp.googleapis.com/.well-known/oauth-protected-resource"):
			return jsonHTTPResponse(http.StatusOK, `{
				"resource": "https://drivemcp.googleapis.com/mcp/v1",
				"authorization_servers": ["https://accounts.google.com"],
				"scopes_supported": [
					"https://www.googleapis.com/auth/drive.readonly",
					"https://www.googleapis.com/auth/drive.file"
				]
			}`), nil
		case r.URL.String() == "https://accounts.google.com/.well-known/oauth-authorization-server":
			return jsonHTTPResponse(http.StatusNotFound, `{}`), nil
		case r.URL.String() == "https://accounts.google.com/.well-known/openid-configuration":
			return jsonHTTPResponse(http.StatusOK, `{
				"authorization_endpoint": "https://accounts.google.com/o/oauth2/v2/auth",
				"token_endpoint": "https://oauth2.googleapis.com/token",
				"scopes_supported": ["openid", "email", "profile"]
			}`), nil
		case r.URL.String() == "https://oauth2.googleapis.com/token":
			body, err := io.ReadAll(r.Body)
			if err != nil {
				return nil, err
			}
			vals, err := url.ParseQuery(string(body))
			if err != nil {
				return nil, err
			}
			tokenRequests = append(tokenRequests, vals)
			if vals.Get("grant_type") == "refresh_token" {
				return jsonHTTPResponse(http.StatusOK, `{
					"access_token": "refreshed-access-token",
					"expires_in": 3600,
					"token_type": "Bearer"
				}`), nil
			}
			return jsonHTTPResponse(http.StatusOK, `{
				"access_token": "initial-access-token",
				"refresh_token": "initial-refresh-token",
				"expires_in": 3600,
				"token_type": "Bearer"
			}`), nil
		case r.URL.String() == "https://drivemcp.googleapis.com/mcp/v1":
			if r.Method != http.MethodPost || r.Body == nil {
				return jsonHTTPResponse(http.StatusOK, `{}`), nil
			}
			body, err := io.ReadAll(r.Body)
			if err != nil {
				return nil, err
			}
			var req struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
			}
			_ = json.Unmarshal(body, &req)
			id := string(req.ID)
			if id == "" {
				id = "null"
			}
			switch req.Method {
			case "initialize":
				resp := jsonHTTPResponse(http.StatusOK, `{"jsonrpc":"2.0","id":`+id+`,"result":{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"drive","version":"1"}}}`)
				resp.Header.Set("Mcp-Session-Id", "sess-1")
				return resp, nil
			case "notifications/initialized":
				return jsonHTTPResponse(http.StatusAccepted, ""), nil
			case "tools/list":
				return jsonHTTPResponse(http.StatusOK, `{"jsonrpc":"2.0","id":`+id+`,"result":{"tools":[]}}`), nil
			default:
				return jsonHTTPResponse(http.StatusOK, `{"jsonrpc":"2.0","id":`+id+`,"result":{}}`), nil
			}
		default:
			return jsonHTTPResponse(http.StatusNotFound, `{}`), nil
		}
	})

	svc := &Service{
		Q:         q,
		Box:       box,
		PublicURL: "http://localhost:8000",
		HTTP:      transport,
	}

	c, authURL, err := svc.Create(ctx, me.WorkspaceID, me.ID, CreateInput{
		Name:         "Google Drive",
		URL:          "https://drivemcp.googleapis.com/mcp/v1",
		Auth:         AuthOAuth,
		ClientID:     "client-123.apps.googleusercontent.com",
		ClientSecret: "super-secret-oauth-client-secret",
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if strings.Contains(string(c.Oauth), "super-secret-oauth-client-secret") {
		t.Fatal("client secret leaked into plaintext oauth JSONB column")
	}
	gotClientID, hasSecret, gotScopes := OAuthConfig(c)
	wantScopes := []string{
		"https://www.googleapis.com/auth/drive.readonly",
		"https://www.googleapis.com/auth/drive.file",
	}
	if gotClientID != "client-123.apps.googleusercontent.com" || !hasSecret || !slices.Equal(gotScopes, wantScopes) {
		t.Fatalf("OAuthConfig = (%q, %v, %v), want (%q, true, %v)", gotClientID, hasSecret, gotScopes, "client-123.apps.googleusercontent.com", wantScopes)
	}

	parsedAuthURL, err := url.Parse(authURL)
	if err != nil {
		t.Fatalf("url.Parse(authURL): %v", err)
	}
	aq := parsedAuthURL.Query()
	if aq.Get("client_id") != "client-123.apps.googleusercontent.com" {
		t.Fatalf("authorize client_id = %q", aq.Get("client_id"))
	}
	if aq.Get("scope") != strings.Join(wantScopes, " ") {
		t.Fatalf("authorize scope = %q, want %q", aq.Get("scope"), strings.Join(wantScopes, " "))
	}
	if aq.Get("access_type") != "offline" || aq.Get("prompt") != "consent" {
		t.Fatalf("expected offline+consent params, got access_type=%q prompt=%q", aq.Get("access_type"), aq.Get("prompt"))
	}
	if aq.Get("redirect_uri") != "http://localhost:8000"+CallbackPath {
		t.Fatalf("redirect_uri = %q", aq.Get("redirect_uri"))
	}

	finished, err := svc.FinishOAuth(ctx, aq.Get("state"), "google-auth-code")
	if err != nil {
		t.Fatalf("FinishOAuth: %v", err)
	}
	if len(tokenRequests) != 1 {
		t.Fatalf("expected 1 token request, got %d", len(tokenRequests))
	}
	ex := tokenRequests[0]
	if ex.Get("client_id") != "client-123.apps.googleusercontent.com" ||
		ex.Get("client_secret") != "super-secret-oauth-client-secret" ||
		ex.Get("code") != "google-auth-code" {
		t.Fatalf("unexpected token exchange params: %v", ex)
	}

	cred, err := svc.unseal(finished)
	if err != nil {
		t.Fatalf("unseal: %v", err)
	}
	if cred.AccessToken != "initial-access-token" || cred.RefreshToken != "initial-refresh-token" || cred.ClientSecret != "super-secret-oauth-client-secret" {
		t.Fatalf("unexpected sealed credential fields: access=%q refresh=%q secret=%q", cred.AccessToken, cred.RefreshToken, cred.ClientSecret)
	}

	refreshed, err := svc.refreshOAuth(ctx, finished, cred)
	if err != nil {
		t.Fatalf("refreshOAuth: %v", err)
	}
	if refreshed.AccessToken != "refreshed-access-token" || refreshed.RefreshToken != "initial-refresh-token" || refreshed.ClientSecret != "super-secret-oauth-client-secret" {
		t.Fatalf("unexpected refreshed credential fields: access=%q refresh=%q secret=%q", refreshed.AccessToken, refreshed.RefreshToken, refreshed.ClientSecret)
	}
	if len(tokenRequests) != 2 {
		t.Fatalf("expected 2 token requests, got %d", len(tokenRequests))
	}
	rf := tokenRequests[1]
	if rf.Get("grant_type") != "refresh_token" || rf.Get("client_id") != "client-123.apps.googleusercontent.com" || rf.Get("client_secret") != "super-secret-oauth-client-secret" {
		t.Fatalf("unexpected refresh params: %v", rf)
	}
}

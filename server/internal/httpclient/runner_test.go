package httpclient

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestResolveInheritance(t *testing.T) {
	wsID := uuid.New()
	rootID := uuid.New()
	subID := uuid.New()

	ws := Workspace{
		ID:          wsID,
		DefaultAuth: AuthConfig{Type: AuthBearer, Token: "{{ws_token}}"},
		DefaultHeaders: []KeyValue{
			{Key: "X-App", Value: "vesper", Enabled: true},
			{Key: "Accept", Value: "application/json", Enabled: true},
		},
	}
	folders := []Folder{
		{
			ID:              rootID,
			HTTPWorkspaceID: wsID,
			Name:            "Admin",
			DefaultAuth:     AuthConfig{Type: AuthInherit},
			DefaultHeaders: []KeyValue{
				{Key: "x-app", Value: "vesper-admin", Enabled: true},
				{Key: "X-Folder", Value: "root", Enabled: true},
			},
		},
		{
			ID:              subID,
			HTTPWorkspaceID: wsID,
			ParentFolderID:  &rootID,
			Name:            "Keys",
			DefaultAuth:     AuthConfig{Type: AuthAPIKey, APIKeyName: "X-Admin-Key", APIKeyValue: "k123", APIKeyIn: APIKeyInHeader},
		},
	}

	// Inherit from workspace through root folder.
	reqRoot := Request{FolderID: &rootID, Auth: AuthConfig{Type: AuthInherit}, Headers: []KeyValue{{Key: "X-Req", Value: "1", Enabled: true}}}
	auth, hdrs := ResolveInheritance(ws, folders, reqRoot)
	if auth.Type != AuthBearer || auth.Token != "{{ws_token}}" {
		t.Fatalf("expected inherited bearer auth, got %+v", auth)
	}
	if len(hdrs) != 4 || hdrs[0].Value != "vesper-admin" {
		t.Fatalf("expected merged headers with folder override, got %+v", hdrs)
	}

	// Subfolder overrides workspace auth; request inherits subfolder auth.
	reqSub := Request{FolderID: &subID, Auth: AuthConfig{Type: AuthInherit}}
	auth, _ = ResolveInheritance(ws, folders, reqSub)
	if auth.Type != AuthAPIKey || auth.APIKeyName != "X-Admin-Key" {
		t.Fatalf("expected subfolder apikey auth, got %+v", auth)
	}

	// Request explicitly overrides to none.
	reqNone := Request{FolderID: &subID, Auth: AuthConfig{Type: AuthNone}}
	auth, _ = ResolveInheritance(ws, folders, reqNone)
	if auth.Type != AuthNone {
		t.Fatalf("expected explicit none override, got %+v", auth)
	}
}

func TestSSRFBlocksInternalTargets(t *testing.T) {
	for _, raw := range []string{
		"http://localhost:8080/health",
		"http://127.0.0.1:8000/api",
		"http://169.254.169.254/latest/meta-data",
		"http://10.0.0.5/internal",
		"http://[::1]:8000/",
		"https://service.local/api",
		"ftp://example.com/file",
	} {
		if _, err := parseExternalURL(raw); err == nil {
			t.Fatalf("expected %q to be blocked", raw)
		}
	}

	// Also verify SafeTransport blocks private DNS answers at dial time.
	svc := &Service{
		LookupIP: func(ctx context.Context, host string) ([]net.IP, error) {
			return []net.IP{net.ParseIP("10.1.2.3")}, nil
		},
	}
	client := svc.httpClient(true, defaultTimeoutMS)
	req, _ := http.NewRequest(http.MethodGet, "https://api.example.com/test", nil)
	_, err := client.Do(req)
	var blocked *usersecrets.Blocked
	if !errors.As(err, &blocked) {
		t.Fatalf("expected usersecrets.Blocked on private DNS answer, got %v", err)
	}
}

func TestExecuteInheritanceSecretsAndEnvironments(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID

	box, err := secrets.NewBox("MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=")
	if err != nil {
		t.Fatal(err)
	}
	us := &usersecrets.Service{Q: q, Box: box}
	nonprodSecret, err := us.Create(ctx, ws, me.ID, usersecrets.Input{
		Name:         "Nonprod API Token",
		Value:        "super-secret-nonprod-token",
		Placement:    usersecrets.PlacementBearer,
		AllowedHosts: []string{"api.nonprod.example.com"},
	})
	if err != nil {
		t.Fatal(err)
	}

	var calls int
	var gotAuth, gotURL, gotHeader string
	svc := &Service{
		Q:       q,
		Secrets: us,
		HTTP: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			calls++
			if r.URL.Path == "/oauth/token" {
				return &http.Response{
					StatusCode: http.StatusOK,
					Status:     "200 OK",
					Header:     http.Header{"Content-Type": []string{"application/json"}},
					Body:       io.NopCloser(strings.NewReader(`{"access_token":"oauth-live-tok","expires_in":3600}`)),
				}, nil
			}
			gotAuth = r.Header.Get("Authorization")
			gotURL = r.URL.String()
			gotHeader = r.Header.Get("X-App-Env")
			return &http.Response{
				StatusCode: http.StatusOK,
				Status:     "200 OK",
				Header:     http.Header{"Content-Type": []string{"application/json"}},
				Body:       io.NopCloser(strings.NewReader(`{"echo_token":"super-secret-nonprod-token","ok":true}`)),
			}, nil
		}),
	}

	bundle, err := svc.CreateWorkspace(ctx, ws, me.ID, WorkspaceInput{
		Name: "Billing",
		DefaultAuth: AuthConfig{
			Type:  AuthBearer,
			Token: "{{api_token}}",
		},
		DefaultHeaders: []KeyValue{{Key: "X-App-Env", Value: "{{env_tag}}", Enabled: true}},
		DefaultVars:    []EnvVar{{Key: "env_tag", Value: "default", Enabled: true}},
	})
	if err != nil {
		t.Fatal(err)
	}

	nonprodEnv, err := svc.CreateEnvironment(ctx, ws, bundle.Workspace.ID, EnvironmentInput{
		Name:  "nonprod",
		Color: "green",
		Variables: []EnvVar{
			{Key: "base_url", Value: "https://api.nonprod.example.com", Enabled: true},
			{Key: "api_token", SecretHandle: nonprodSecret.Handle, Enabled: true},
			{Key: "env_tag", Value: "nonprod", Enabled: true},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	prodEnv, err := svc.CreateEnvironment(ctx, ws, bundle.Workspace.ID, EnvironmentInput{
		Name:  "prod",
		Color: "red",
		Variables: []EnvVar{
			{Key: "base_url", Value: "https://api.prod.example.com", Enabled: true},
			{Key: "api_token", Value: "prod-plain-tok", Enabled: true},
			{Key: "env_tag", Value: "prod", Enabled: true},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.SetActiveEnvironment(ctx, ws, bundle.Workspace.ID, &nonprodEnv.ID); err != nil {
		t.Fatal(err)
	}

	reqItem, err := svc.CreateRequest(ctx, ws, bundle.Workspace.ID, RequestInput{
		Name:   "Get invoices",
		Method: "GET",
		URL:    "{{base_url}}/v1/invoices",
		Params: []KeyValue{{Key: "limit", Value: "10", Enabled: true}},
	})
	if err != nil {
		t.Fatal(err)
	}

	exec, err := svc.RunSavedRequest(ctx, ws, me.ID, reqItem.ID, RunOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer super-secret-nonprod-token" || gotHeader != "nonprod" || gotURL != "https://api.nonprod.example.com/v1/invoices?limit=10" {
		t.Fatalf("unexpected nonprod request: auth=%q hdr=%q url=%q", gotAuth, gotHeader, gotURL)
	}
	if strings.Contains(exec.ResponseBody, "super-secret-nonprod-token") || strings.Contains(jsonString(exec.RequestHeaders), "super-secret-nonprod-token") {
		t.Fatalf("secret leaked into persisted execution: %+v", exec)
	}

	// Override environment to prod without changing workspace active env.
	_, err = svc.RunSavedRequest(ctx, ws, me.ID, reqItem.ID, RunOptions{EnvironmentID: &prodEnv.ID})
	if err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer prod-plain-tok" || gotHeader != "prod" || !strings.HasPrefix(gotURL, "https://api.prod.example.com/") {
		t.Fatalf("unexpected prod request: auth=%q hdr=%q url=%q", gotAuth, gotHeader, gotURL)
	}

	// Folder with OAuth2 client_credentials should fetch & cache token.
	oauthFolder, err := svc.CreateFolder(ctx, ws, bundle.Workspace.ID, FolderInput{
		Name: "OAuth Calls",
		DefaultAuth: AuthConfig{
			Type: AuthOAuth2,
			OAuth2: &OAuth2Config{
				GrantType:    "client_credentials",
				TokenURL:     "{{base_url}}/oauth/token",
				ClientID:     "cid",
				ClientSecret: "csec",
			},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	oauthReq, err := svc.CreateRequest(ctx, ws, bundle.Workspace.ID, RequestInput{
		FolderID: &oauthFolder.ID,
		Name:     "Protected",
		Method:   "GET",
		URL:      "{{base_url}}/v1/protected",
	})
	if err != nil {
		t.Fatal(err)
	}
	before := calls
	if _, err := svc.RunSavedRequest(ctx, ws, me.ID, oauthReq.ID, RunOptions{}); err != nil {
		t.Fatal(err)
	}
	if gotAuth != "Bearer oauth-live-tok" || calls-before != 2 {
		t.Fatalf("expected token fetch + API call (2 calls), got auth=%q delta=%d", gotAuth, calls-before)
	}
	// Second run reuses cached OAuth token (1 call).
	before = calls
	if _, err := svc.RunSavedRequest(ctx, ws, me.ID, oauthReq.ID, RunOptions{}); err != nil {
		t.Fatal(err)
	}
	if calls-before != 1 {
		t.Fatalf("expected cached oauth token (1 call), got %d", calls-before)
	}

	// SSRF URL rejected with 422 validation error.
	_, err = svc.RunAdHocRequest(ctx, ws, me.ID, bundle.Workspace.ID, AdHocRunInput{
		Request: RequestInput{Method: "GET", URL: "http://127.0.0.1:8000/api/v1/health"},
	})
	var ve *apperr.ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("expected ValidationError for loopback URL, got %v", err)
	}
}

func jsonString(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}

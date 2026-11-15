package usersecrets

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// tokenServer stands in for a provider's token endpoint. It records every
// form it gets, and answers with whatever reply says for that grant.
type tokenServer struct {
	mu    sync.Mutex
	forms []url.Values
	reply func(form url.Values) (int, string)
}

func (ts *tokenServer) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.String() != "https://oauth2.example.com/token" {
		return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(strings.NewReader("{}")), Request: r}, nil
	}
	raw, _ := io.ReadAll(r.Body)
	form, _ := url.ParseQuery(string(raw))
	ts.mu.Lock()
	ts.forms = append(ts.forms, form)
	ts.mu.Unlock()
	status, body := ts.reply(form)
	return &http.Response{StatusCode: status, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
}

func (ts *tokenServer) grants() []url.Values {
	ts.mu.Lock()
	defer ts.mu.Unlock()
	return append([]url.Values(nil), ts.forms...)
}

type oauthFixture struct {
	ctx   context.Context
	svc   *Service
	q     *store.Queries
	ts    *tokenServer
	clock time.Time
	sec   store.UserSecret
}

func newOAuthFixture(t *testing.T) *oauthFixture {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	f := &oauthFixture{ctx: ctx, q: q, clock: time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC)}
	issued := 0
	f.ts = &tokenServer{reply: func(form url.Values) (int, string) {
		issued++
		n := strconv.Itoa(issued)
		if form.Get("grant_type") == "authorization_code" {
			return 200, `{"access_token":"access-` + n + `","refresh_token":"refresh-1","expires_in":3600}`
		}
		return 200, `{"access_token":"access-` + n + `","expires_in":3600}`
	}}
	f.svc = &Service{Q: q, Box: box(t), HTTP: f.ts, Now: func() time.Time { return f.clock }}
	sec, err := f.svc.Create(ctx, me.WorkspaceID, me.ID, Input{Name: "Google Drive", AllowedHosts: []string{"www.googleapis.com"}, ReadPolicy: PolicyAllow,
		OAuth: &OAuthInput{AuthorizeURL: "https://accounts.example.com/o/oauth2/auth", TokenURL: "https://oauth2.example.com/token",
			ClientID: "client-123", ClientSecret: "client-secret-xyz", Scopes: []string{"drive.readonly, drive.file"}}})
	if err != nil {
		t.Fatal(err)
	}
	f.sec = sec
	return f
}

// signIn runs the browser half of a sign-in: Begin, then the provider's redirect.
func (f *oauthFixture) signIn(t *testing.T) url.Values {
	t.Helper()
	link, err := f.svc.BeginOAuth(f.ctx, f.sec, "https://vesper.example.ts.net/api/v1/connector-oauth/callback")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(link)
	aq := u.Query()
	if f.sec, err = f.svc.FinishOAuth(f.ctx, aq.Get("state"), "auth-code"); err != nil {
		t.Fatalf("FinishOAuth: %v", err)
	}
	return aq
}

func TestOAuthSecretBeforeSignIn(t *testing.T) {
	f := newOAuthFixture(t)
	sec := f.sec
	if sec.Kind != KindOAuth || sec.Placement != PlacementBearer || sec.SignedInAt != nil {
		t.Fatalf("stored kind=%s placement=%s signed_in=%v", sec.Kind, sec.Placement, sec.SignedInAt)
	}
	if strings.Contains(string(sec.Oauth), "client-secret-xyz") || strings.Contains(string(sec.Ciphertext), "client-secret-xyz") {
		t.Fatal("client secret stored in plain text")
	}
	st := Settings(sec)
	if st.ClientID != "client-123" || !st.HasClientSecret || strings.Join(st.Scopes, " ") != "drive.readonly drive.file" {
		t.Fatalf("settings = %+v", st)
	}
	var b *Blocked
	if _, err := f.svc.Check(sec, Request{URL: "https://www.googleapis.com/drive/v3/files"}); !errors.As(err, &b) || !strings.Contains(b.Reason, "isn't signed in") {
		t.Fatalf("check before sign-in: %v", err)
	}
	if _, err := f.svc.Value(f.ctx, sec); !errors.As(err, &b) {
		t.Fatalf("value before sign-in: %v", err)
	}
	// The sealed credential holds the client secret: it must never be sent as a value.
	if _, err := f.svc.Reveal(sec); err == nil {
		t.Fatal("Reveal opened an OAuth credential")
	}
	if _, err := f.svc.SetValue(f.ctx, sec, PlacementBearer, "pasted-token"); err == nil {
		t.Fatal("SetValue replaced an OAuth credential")
	}
}

func TestOAuthSecretRejectsBadSetup(t *testing.T) {
	f := newOAuthFixture(t)
	me, _ := f.q.GetLocalUser(f.ctx)
	good := OAuthInput{AuthorizeURL: "https://a.example.com/auth", TokenURL: "https://a.example.com/token", ClientID: "c"}
	var ve *apperr.ValidationError
	for name, in := range map[string]Input{
		"value too":       {Name: "x", Value: "v", AllowedHosts: []string{"a.com"}, OAuth: &good},
		"header":          {Name: "x", Placement: PlacementHeader, PlacementKey: "X-Key", AllowedHosts: []string{"a.com"}, OAuth: &good},
		"http token url":  {Name: "x", AllowedHosts: []string{"a.com"}, OAuth: &OAuthInput{AuthorizeURL: good.AuthorizeURL, TokenURL: "http://a.example.com/token", ClientID: "c"}},
		"no client id":    {Name: "x", AllowedHosts: []string{"a.com"}, OAuth: &OAuthInput{AuthorizeURL: good.AuthorizeURL, TokenURL: good.TokenURL}},
		"creds in url":    {Name: "x", AllowedHosts: []string{"a.com"}, OAuth: &OAuthInput{AuthorizeURL: "https://u:p@a.example.com/auth", TokenURL: good.TokenURL, ClientID: "c"}},
		"no allowed host": {Name: "x", OAuth: &good},
	} {
		if _, err := f.svc.Create(f.ctx, me.WorkspaceID, me.ID, in); !errors.As(err, &ve) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestOAuthSignInExchangesCodeWithPKCE(t *testing.T) {
	f := newOAuthFixture(t)
	aq := f.signIn(t)
	for k, want := range map[string]string{"client_id": "client-123", "redirect_uri": "https://vesper.example.ts.net/api/v1/connector-oauth/callback",
		"scope": "drive.readonly drive.file", "access_type": "offline", "prompt": "consent", "code_challenge_method": "S256", "response_type": "code"} {
		if aq.Get(k) != want {
			t.Errorf("authorize %s = %q, want %q", k, aq.Get(k), want)
		}
	}
	grants := f.ts.grants()
	if len(grants) != 1 {
		t.Fatalf("token requests = %d, want 1", len(grants))
	}
	ex := grants[0]
	if ex.Get("grant_type") != "authorization_code" || ex.Get("code") != "auth-code" || ex.Get("client_secret") != "client-secret-xyz" ||
		ex.Get("code_verifier") == "" || ex.Get("redirect_uri") != aq.Get("redirect_uri") {
		t.Fatalf("exchange = %v", ex)
	}
	if f.sec.SignedInAt == nil || f.sec.OauthState != nil || strings.Contains(string(f.sec.Oauth), "verifier") {
		t.Fatalf("after sign-in: signed_in=%v state=%v oauth=%s", f.sec.SignedInAt, f.sec.OauthState, f.sec.Oauth)
	}
	// The state is single-use.
	if _, err := f.svc.FinishOAuth(f.ctx, aq.Get("state"), "auth-code"); !errors.Is(err, ErrUnknownState) {
		t.Fatalf("replayed state: %v", err)
	}
	if _, err := f.svc.Check(f.sec, Request{URL: "https://www.googleapis.com/drive/v3/files"}); err != nil {
		t.Fatalf("check after sign-in: %v", err)
	}
}

// The reason this exists: a token that came from signing in still works after
// it expires, because Vesper refreshes it, and only when it has to.
func TestOAuthValueRefreshesAnExpiringToken(t *testing.T) {
	f := newOAuthFixture(t)
	f.signIn(t)
	if v, err := f.svc.Value(f.ctx, f.sec); err != nil || v != "access-1" {
		t.Fatalf("fresh value = %q, %v", v, err)
	}
	if n := len(f.ts.grants()); n != 1 {
		t.Fatalf("a fresh token was refreshed: %d token requests", n)
	}

	f.clock = f.clock.Add(59*time.Minute + 30*time.Second) // inside the last minute
	v, err := f.svc.Value(f.ctx, f.sec)
	if err != nil || v != "access-2" {
		t.Fatalf("refreshed value = %q, %v", v, err)
	}
	grants := f.ts.grants()
	if len(grants) != 2 {
		t.Fatalf("token requests = %d, want 2", len(grants))
	}
	if r := grants[1]; r.Get("grant_type") != "refresh_token" || r.Get("refresh_token") != "refresh-1" || r.Get("client_secret") != "client-secret-xyz" {
		t.Fatalf("refresh = %v", r)
	}
	// The new token is stored, and the refresh token kept when none came back.
	if v, err := f.svc.Value(f.ctx, f.sec); err != nil || v != "access-2" || len(f.ts.grants()) != 2 {
		t.Fatalf("stored refresh: %q %v (%d requests)", v, err, len(f.ts.grants()))
	}
	f.clock = f.clock.Add(time.Hour)
	if _, err := f.svc.Value(f.ctx, f.sec); err != nil || f.ts.grants()[2].Get("refresh_token") != "refresh-1" {
		t.Fatalf("second refresh: %v", err)
	}
	// Refreshing isn't the person's edit: the revision they'd save against stays.
	now, _ := f.q.UserSecretByID(f.ctx, f.sec.ID)
	if now.Revision != f.sec.Revision {
		t.Fatalf("revision moved from %d to %d", f.sec.Revision, now.Revision)
	}
}

func TestOAuthConcurrentRequestsRefreshOnce(t *testing.T) {
	f := newOAuthFixture(t)
	f.signIn(t)
	f.clock = f.clock.Add(2 * time.Hour)
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for range 8 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := f.svc.Value(f.ctx, f.sec); err != nil {
				errs <- err
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
	if n := len(f.ts.grants()); n != 2 {
		t.Fatalf("token requests = %d, want the exchange and one refresh", n)
	}
}

func TestOAuthRevokedGrantStopsRequests(t *testing.T) {
	f := newOAuthFixture(t)
	f.signIn(t)
	f.ts.reply = func(url.Values) (int, string) { return 400, `{"error":"invalid_grant"}` }
	f.clock = f.clock.Add(2 * time.Hour)
	var b *Blocked
	if _, err := f.svc.Value(f.ctx, f.sec); !errors.As(err, &b) || !strings.Contains(b.Reason, "invalid_grant") || !strings.Contains(b.Reason, "sign in") {
		t.Fatalf("revoked: %v", err)
	}
	sec, _ := f.q.UserSecretByID(f.ctx, f.sec.ID)
	if !strings.Contains(sec.OauthError, "invalid_grant") {
		t.Fatalf("oauth_error = %q", sec.OauthError)
	}
	if _, err := f.svc.Check(sec, Request{URL: "https://www.googleapis.com/drive/v3/files"}); !errors.As(err, &b) {
		t.Fatalf("check after revoke: %v", err)
	}
	// Signing in again clears it.
	f.ts.reply = func(url.Values) (int, string) {
		return 200, `{"access_token":"access-new","refresh_token":"refresh-2","expires_in":3600}`
	}
	f.sec = sec
	f.signIn(t)
	if f.sec.OauthError != "" {
		t.Fatalf("oauth_error after sign-in = %q", f.sec.OauthError)
	}
	if v, err := f.svc.Value(f.ctx, f.sec); err != nil || v != "access-new" {
		t.Fatalf("after re-sign-in: %q %v", v, err)
	}
}

func TestOAuthNetworkFailureKeepsTheGrant(t *testing.T) {
	f := newOAuthFixture(t)
	f.signIn(t)
	f.svc.HTTP = roundTripFunc(func(*http.Request) (*http.Response, error) { return nil, errors.New("dial tcp: connection refused") })
	f.clock = f.clock.Add(2 * time.Hour)
	if _, err := f.svc.Value(f.ctx, f.sec); err == nil {
		t.Fatal("refresh without a network succeeded")
	}
	// A provider outage isn't a revoked grant: the next request tries again.
	if sec, _ := f.q.UserSecretByID(f.ctx, f.sec.ID); sec.OauthError != "" {
		t.Fatalf("network failure recorded as a lapsed sign-in: %q", sec.OauthError)
	}
}

func TestOAuthSignInWithoutRefreshTokenFails(t *testing.T) {
	f := newOAuthFixture(t)
	f.ts.reply = func(url.Values) (int, string) { return 200, `{"access_token":"short-lived","expires_in":3600}` }
	link, err := f.svc.BeginOAuth(f.ctx, f.sec, "https://vesper.example/cb")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(link)
	if _, err := f.svc.FinishOAuth(f.ctx, u.Query().Get("state"), "code"); err == nil || !strings.Contains(err.Error(), "refresh token") {
		t.Fatalf("expiring token without refresh: %v", err)
	}
	if sec, _ := f.q.UserSecretByID(f.ctx, f.sec.ID); sec.SignedInAt != nil {
		t.Fatal("marked signed in without a way to stay signed in")
	}
}

func TestStaticSecretValueIsTheStoredValue(t *testing.T) {
	f := newOAuthFixture(t)
	me, _ := f.q.GetLocalUser(f.ctx)
	sec, err := f.svc.Create(f.ctx, me.WorkspaceID, me.ID, Input{Name: "Plain", Value: "sk_live_abc", Placement: PlacementBearer, AllowedHosts: []string{"a.com"}})
	if err != nil {
		t.Fatal(err)
	}
	if sec.Kind != KindStatic {
		t.Fatalf("kind = %q", sec.Kind)
	}
	if v, err := f.svc.Value(f.ctx, sec); err != nil || v != "sk_live_abc" {
		t.Fatalf("value = %q, %v", v, err)
	}
}

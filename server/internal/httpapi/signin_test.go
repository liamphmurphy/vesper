package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/connectors"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// newSignedInServer is a server as `vesper serve` builds it: no AnonymousAPI.
func newSignedInServer(t *testing.T) (*store.Queries, http.Handler) {
	pool := testdb.New(t)
	if _, err := seed.Run(context.Background(), pool, seed.Options{UserName: "Liam"}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	s := &Server{Pool: pool, Q: q, Tracker: &tracker.Service{Pool: pool}, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	return q, s.Handler()
}

func getWithCookie(h http.Handler, path string, c *http.Cookie) *httptest.ResponseRecorder {
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if c != nil {
		req.AddCookie(c)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// wantsBrowserSession reports whether the sign-in check refused rec (the
// agent API answers a missing bearer token with the same code).
func wantsBrowserSession(rec *httptest.ResponseRecorder) bool {
	var e struct{ Code, Message string }
	_ = json.Unmarshal(rec.Body.Bytes(), &e)
	return rec.Code == http.StatusUnauthorized && e.Code == "unauthenticated" && e.Message == signInMessage
}

// signIn opens a fresh sign-in link and returns the session cookie it set.
func signIn(t *testing.T, q *store.Queries, h http.Handler) *http.Cookie {
	t.Helper()
	code, err := auth.NewSignInCode(context.Background(), q)
	if err != nil {
		t.Fatal(err)
	}
	rec := getWithCookie(h, SignInPath+"?code="+code, nil)
	if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/" {
		t.Fatalf("sign-in link: %d to %q, want 303 to /", rec.Code, rec.Header().Get("Location"))
	}
	for _, c := range rec.Result().Cookies() {
		if c.Name == auth.SessionCookie {
			return c
		}
	}
	t.Fatal("sign-in link set no session cookie")
	return nil
}

// Anything that can reach the API, an agent container included, used to act
// as the person. Now only a signed-in browser can.
func TestPersonFacingAPIRequiresBrowserSession(t *testing.T) {
	q, h := newSignedInServer(t)

	for _, path := range []string{"/api/v1/bootstrap", "/api/v1/secrets", "/events"} {
		rec := getWithCookie(h, path, nil)
		if !wantsBrowserSession(rec) {
			t.Errorf("GET %s without a session = %d %s, want 401 unauthenticated", path, rec.Code, rec.Body)
		}
	}
	forged := &http.Cookie{Name: auth.SessionCookie, Value: "not-a-session"}
	if rec := getWithCookie(h, "/api/v1/bootstrap", forged); !wantsBrowserSession(rec) {
		t.Errorf("forged session = %d, want 401", rec.Code)
	}

	// Probes, agents (bearer tokens) and the OAuth callback (state-protected,
	// and a cross-site redirect that carries no SameSite=Strict cookie) stay open.
	for _, path := range []string{"/api/v1/health", "/api/v1/agent/tools/whoami", connectors.CallbackPath} {
		if rec := getWithCookie(h, path, nil); wantsBrowserSession(rec) {
			t.Errorf("GET %s was refused for want of a browser session", path)
		}
	}

	// An exempt prefix mustn't open the rest of the API by path tricks.
	for _, path := range []string{"/api/v1/agent/../bootstrap", "/api/v1/agent/%2e%2e/bootstrap", "/api/v1/health/../bootstrap"} {
		if rec := getWithCookie(h, path, nil); rec.Code == http.StatusOK {
			t.Errorf("GET %s without a session = 200", path)
		}
	}

	cookie := signIn(t, q, h)
	if !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode || cookie.Path != "/" {
		t.Errorf("session cookie = %+v, want HttpOnly, SameSite=Strict, Path=/", cookie)
	}
	if rec := getWithCookie(h, "/api/v1/bootstrap", cookie); rec.Code != http.StatusOK {
		t.Fatalf("signed in: GET /bootstrap = %d %s", rec.Code, rec.Body)
	}
}

func TestSignInLinkWorksOnce(t *testing.T) {
	q, h := newSignedInServer(t)
	code, err := auth.NewSignInCode(context.Background(), q)
	if err != nil {
		t.Fatal(err)
	}
	if rec := getWithCookie(h, SignInPath+"?code="+code, nil); rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != "/" {
		t.Fatalf("first use: %d to %q", rec.Code, rec.Header().Get("Location"))
	}
	for _, path := range []string{SignInPath + "?code=" + code, SignInPath + "?code=made-up", SignInPath} {
		rec := getWithCookie(h, path, nil)
		if rec.Code != http.StatusSeeOther || rec.Header().Get("Location") != SignInPage+"?error=invalid" {
			t.Errorf("GET %s = %d to %q, want 303 to the sign-in page", path, rec.Code, rec.Header().Get("Location"))
		}
		if len(rec.Result().Cookies()) > 0 {
			t.Errorf("GET %s set a cookie", path)
		}
	}
	if rec := getWithCookie(h, SignInPage, nil); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), "Sign in to Vesper") {
		t.Errorf("GET %s = %d %q, want 200 embedded sign-in page", SignInPage, rec.Code, rec.Body.String())
	}
	if rec := getWithCookie(h, SignInPage+"?error=invalid", nil); rec.Code != http.StatusOK || !strings.Contains(rec.Header().Get("Content-Type"), "text/html") {
		t.Errorf("GET %s?error=invalid = %d ct=%q, want 200 text/html", SignInPage, rec.Code, rec.Header().Get("Content-Type"))
	}
}

// A playground is served from Vesper's own host on another port, so the
// browser sends it the session cookie (SameSite counts sites, not ports) and
// its scripts could otherwise write through the API as the person.
func TestPersonFacingAPIRefusesCrossOriginWrites(t *testing.T) {
	q, h := newSignedInServer(t)
	cookie := signIn(t, q, h)
	send := func(method, site string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, "/api/v1/runner/test-environments", strings.NewReader(`{}`))
		req.Header.Set("Content-Type", "application/json")
		if site != "" {
			req.Header.Set("Sec-Fetch-Site", site)
		}
		req.AddCookie(cookie)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	for _, site := range []string{"same-site", "cross-site"} {
		if rec := send(http.MethodPut, site); rec.Code != http.StatusForbidden {
			t.Errorf("PUT from a %s page = %d %s, want 403", site, rec.Code, rec.Body)
		}
	}
	// The app itself, a typed URL, and clients that aren't browsers.
	for _, site := range []string{"same-origin", "none", ""} {
		if rec := send(http.MethodPut, site); rec.Code == http.StatusForbidden {
			t.Errorf("PUT with Sec-Fetch-Site %q = 403, want it through", site)
		}
	}
	// Reads stay readable only by the origin, which CORS already enforces.
	if rec := send(http.MethodGet, "same-site"); rec.Code == http.StatusForbidden {
		t.Errorf("GET from a same-site page = 403; reads aren't writes")
	}
}

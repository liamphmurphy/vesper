package main

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeDist(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range map[string]string{
		"index.html":           "<!doctype html><div id=root></div>",
		"favicon.ico":          "ico",
		"assets/app-abc.js":    "console.log(1)",
		"assets/app-abc.css":   "body{}",
		"fonts/ui/inter.woff2": "font",
	} {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// A secret next to the dist dir must never be reachable through "..".
	if err := os.WriteFile(filepath.Join(filepath.Dir(dir), "secret.txt"), []byte("secret"), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

func get(h http.Handler, method, target string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, target, nil))
	return rec
}

func TestStaticSPAHandler(t *testing.T) {
	h := staticSPAHandler(writeDist(t))
	for _, tc := range []struct {
		name, path string
		code       int
		body       string // substring
		cache      string
	}{
		{"root is the app", "/", 200, "id=root", "no-cache"},
		{"client route falls back to the app", "/tickets/ABC-1", 200, "id=root", "no-cache"},
		{"deep dynamic route", "/knowledge/6f1c9a52-0000-4000-8000-000000000000/some-slug", 200, "id=root", "no-cache"},
		{"catch-all route with a dot in a segment", "/wiki/a/b.md", 200, "id=root", "no-cache"},
		{"index.html itself", "/index.html", 200, "id=root", "no-cache"},
		{"hashed asset is immutable", "/assets/app-abc.js", 200, "console.log", "public, max-age=31536000, immutable"},
		{"hashed css", "/assets/app-abc.css", 200, "body{}", "public, max-age=31536000, immutable"},
		{"public file revalidates", "/favicon.ico", 200, "ico", "no-cache"},
		{"font file", "/fonts/ui/inter.woff2", 200, "font", "no-cache"},
		{"missing asset is a 404, not the app", "/assets/old-123.js", 404, "", ""},
		{"missing font is a 404", "/fonts/nope.woff2", 404, "", ""},
		{"traversal can't leave the dist dir", "/../secret.txt", 200, "id=root", "no-cache"},
		{"encoded traversal", "/..%2f..%2fsecret.txt", 200, "id=root", "no-cache"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			rec := get(h, http.MethodGet, tc.path)
			if rec.Code != tc.code {
				t.Fatalf("GET %s: status %d, want %d", tc.path, rec.Code, tc.code)
			}
			if !strings.Contains(rec.Body.String(), tc.body) {
				t.Fatalf("GET %s: body %q lacks %q", tc.path, rec.Body.String(), tc.body)
			}
			if strings.Contains(rec.Body.String(), "secret") {
				t.Fatalf("GET %s leaked a file outside the dist dir", tc.path)
			}
			if got := rec.Header().Get("Cache-Control"); got != tc.cache {
				t.Fatalf("GET %s: Cache-Control %q, want %q", tc.path, got, tc.cache)
			}
		})
	}

	if rec := get(h, http.MethodHead, "/assets/app-abc.js"); rec.Code != 200 || rec.Body.Len() != 0 {
		t.Fatalf("HEAD asset: %d with %d body bytes", rec.Code, rec.Body.Len())
	}
	if rec := get(h, http.MethodPost, "/"); rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("POST /: %d, want 405", rec.Code)
	}
	if ct := get(h, http.MethodGet, "/assets/app-abc.js").Header().Get("Content-Type"); !strings.Contains(ct, "javascript") {
		t.Fatalf("js Content-Type %q", ct)
	}
}

func TestAppMuxRoutes(t *testing.T) {
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Served-By", "api")
		w.WriteHeader(http.StatusNoContent)
	})
	h := buildAppMux(api, staticSPAHandler(writeDist(t)), nil)
	for _, tc := range []struct {
		path string
		code int
		by   string
	}{
		{"/api/v1/health", 204, "api"},
		{"/mcp", 204, "api"},
		{"/mcp/x", 204, "api"},
		{"/events", 204, "api"},
		{"/internal/designs/render", 404, ""},
		{"/internal", 404, ""},
		{"/", 200, ""},
		{"/tickets/ABC-1", 200, ""},
		{"/assets/app-abc.js", 200, ""},
	} {
		rec := get(h, http.MethodGet, tc.path)
		if rec.Code != tc.code || rec.Header().Get("X-Served-By") != tc.by {
			t.Errorf("GET %s: %d by %q, want %d by %q", tc.path, rec.Code, rec.Header().Get("X-Served-By"), tc.code, tc.by)
		}
	}
	// With no UI configured (the headless build) non-API paths stay a 404.
	if rec := get(buildAppMux(api, nil, nil), http.MethodGet, "/"); rec.Code != http.StatusNotFound {
		t.Errorf("no web dir: GET / = %d, want 404", rec.Code)
	}
}

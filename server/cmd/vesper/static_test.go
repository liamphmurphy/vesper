package main

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func get(h http.Handler, method, target string) *httptest.ResponseRecorder {
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(method, target, nil))
	return rec
}

func TestAppMuxRoutes(t *testing.T) {
	api := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("X-Served-By", "api")
		w.WriteHeader(http.StatusNoContent)
	})
	h := buildAppMux(api, nil)
	for _, tc := range []struct {
		path string
		code int
		by   string
	}{
		{"/api/v1/health", 204, "api"},
		{"/mcp", 204, "api"},
		{"/mcp/x", 204, "api"},
		{"/events", 204, "api"},
		{"/sign-in", 204, "api"},
		{"/internal/designs/render", 404, ""},
		{"/internal", 404, ""},
		{"/", 404, ""},
		{"/assets/app-abc.js", 404, ""},
	} {
		rec := get(h, http.MethodGet, tc.path)
		if rec.Code != tc.code || rec.Header().Get("X-Served-By") != tc.by {
			t.Errorf("GET %s: %d by %q, want %d by %q", tc.path, rec.Code, rec.Header().Get("X-Served-By"), tc.code, tc.by)
		}
	}
}

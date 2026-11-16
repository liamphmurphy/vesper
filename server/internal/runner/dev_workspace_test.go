package runner

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/playground"
)

func TestParseArch(t *testing.T) {
	cases := map[string]string{
		"nix done\nx86_64\n":  "x86_64-linux",
		"nix done\naarch64\n": "aarch64-linux",
		"arm64\n":             "aarch64-linux",
		"mips\n":              "",
		"":                    "",
	}
	for in, want := range cases {
		if got := parseArch(in); got != want {
			t.Fatalf("parseArch(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDevWorkspaceHandlerRejectsUnauthenticated(t *testing.T) {
	r := &Runner{}
	h := r.devWorkspaceHandler(uuid.New())
	req := httptest.NewRequest(http.MethodGet, "/ws", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

func TestGatewayCustomHandlerLifecycle(t *testing.T) {
	gw := &playground.Gateway{}
	const port = 8090
	gw.RegisterCustomHandler(port, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))
	rec := httptest.NewRecorder()
	gw.Handler(port).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ws", nil))
	if rec.Code != http.StatusTeapot {
		t.Fatalf("custom handler status = %d, want 418", rec.Code)
	}

	gw.UnregisterCustomHandler(port)
	rec2 := httptest.NewRecorder()
	gw.Handler(port).ServeHTTP(rec2, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec2.Code != http.StatusServiceUnavailable {
		t.Fatalf("after unregister status = %d, want 503", rec2.Code)
	}
}

package agentapi

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type failedTokenDB struct {
	store.DBTX
	err error
}

type failedTokenRow struct{ err error }

func (r failedTokenRow) Scan(...any) error { return r.err }
func (d failedTokenDB) QueryRow(context.Context, string, ...any) pgx.Row {
	return failedTokenRow{d.err}
}

func TestAuthenticationFailureCategories(t *testing.T) {
	for _, backendFailure := range []bool{false, true} {
		err := pgx.ErrNoRows
		if backendFailure {
			err = errors.New("private database failure detail")
		}
		d := Deps{Q: store.New(failedTokenDB{err: err})}
		for _, transport := range []struct {
			name string
			h    http.Handler
			code int
		}{{"policy", RESTHandler(d), 503}, {"mcp", MCPHandler(d, "test", nil), 500}, {"connector", ConnectorHandler(d, "test"), 500}} {
			t.Run(transport.name+"/"+err.Error(), func(t *testing.T) {
				req := httptest.NewRequest("POST", "/api/v1/agent/tool-policy", strings.NewReader(`{}`))
				req.Header.Set("Authorization", "Bearer vsp_fake-test-token")
				w := httptest.NewRecorder()
				transport.h.ServeHTTP(w, req)
				want := http.StatusUnauthorized
				if backendFailure {
					want = transport.code
				}
				if w.Code != want {
					t.Fatalf("status %d, want %d: %s", w.Code, want, w.Body.String())
				}
				if strings.Contains(w.Body.String(), "private database") || strings.Contains(w.Body.String(), "vsp_fake") {
					t.Fatalf("authentication response disclosed private details: %s", w.Body.String())
				}
			})
		}
	}
}

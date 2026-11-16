package pushreq

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestParseRepo(t *testing.T) {
	for in, want := range map[string]string{
		"https://github.com/acme/app.git": "acme/app",
		"https://github.com/acme/app":     "acme/app",
		"git@github.com:acme/app.git":     "acme/app",
		"ssh://git@github.com/acme/app":   "acme/app",
		"https://gitlab.com/acme/app":     "",
		"https://github.com/acme":         "",
	} {
		o, n, ok := ParseRepo(in)
		if got := o + "/" + n; ok && got != want || !ok && want != "" {
			t.Errorf("ParseRepo(%q) = %q %v, want %q", in, got, ok, want)
		}
	}
}

func staged() store.PushRequest {
	sha, base, ref := "abc123", "main", StagingBranch(uuid.Nil)
	return store.PushRequest{RepoUrl: "https://github.com/acme/app.git", Branch: "feat/x", HeadSha: &sha, BaseBranch: &base, StagingRef: &ref, Title: "T"}
}

// A branch that moved on GitHub since staging is refused with a reason the
// person can act on, and nothing else happens: no force-push, no pull request.
func TestShipRefusesABranchThatMoved(t *testing.T) {
	var calls []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.Method+" "+r.URL.Path)
		switch r.Method {
		case "GET":
			_ = json.NewEncoder(w).Encode(map[string]any{"object": map[string]any{"sha": "other"}})
		case "PATCH":
			var in map[string]any
			_ = json.NewDecoder(r.Body).Decode(&in)
			if in["force"] != false {
				t.Errorf("shipping must never force: %v", in)
			}
			w.WriteHeader(422)
			_, _ = w.Write([]byte(`{"message":"Update is not a fast forward"}`))
		default:
			t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
		}
	}))
	defer srv.Close()
	_, err := Ship(context.Background(), &GitHub{BaseURL: srv.URL, Token: "t"}, staged())
	var refusal *Refusal
	if !errors.As(err, &refusal) || !strings.Contains(refusal.Reason, "never force-pushes") {
		t.Fatalf("err = %v", err)
	}
	if strings.Join(calls, ",") != "GET /repos/acme/app/git/ref/heads/feat/x,PATCH /repos/acme/app/git/refs/heads/feat/x" {
		t.Fatalf("calls = %v", calls)
	}
}

func TestShipExplainsABadToken(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
		_, _ = w.Write([]byte(`{"message":"Bad credentials"}`))
	}))
	defer srv.Close()
	_, err := Ship(context.Background(), &GitHub{BaseURL: srv.URL, Token: "t"}, staged())
	var refusal *Refusal
	if !errors.As(err, &refusal) || !strings.Contains(refusal.Reason, "git:pat") || !strings.Contains(refusal.Reason, "Bad credentials") {
		t.Fatalf("err = %v", err)
	}
}

func TestShipRefusesAnUnstagedRequest(t *testing.T) {
	r := staged()
	r.HeadSha = nil
	if _, err := Ship(context.Background(), &GitHub{BaseURL: "http://127.0.0.1:1"}, r); err == nil || !strings.Contains(err.Error(), "never staged") {
		t.Fatalf("err = %v", err)
	}
	r = staged()
	r.RepoUrl = "https://gitlab.com/acme/app"
	if _, err := Ship(context.Background(), &GitHub{BaseURL: "http://127.0.0.1:1"}, r); err == nil || !strings.Contains(err.Error(), "github.com") {
		t.Fatalf("err = %v", err)
	}
}

func TestShipSetsPRState(t *testing.T) {
	for _, draft := range []bool{false, true} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			switch {
			case r.Method == "GET" && strings.Contains(r.URL.Path, "/git/ref/"):
				_ = json.NewEncoder(w).Encode(map[string]any{"object": map[string]any{"sha": "abc123"}})
			case r.Method == "GET" && strings.HasSuffix(r.URL.Path, "/pulls"):
				_, _ = w.Write([]byte(`[]`))
			case r.Method == "POST" && strings.HasSuffix(r.URL.Path, "/pulls"):
				_ = json.NewEncoder(w).Encode(map[string]any{"number": 7, "html_url": "https://github.com/acme/app/pull/7", "draft": draft})
			case r.Method == "DELETE":
				w.WriteHeader(204)
			default:
				t.Errorf("unexpected %s %s", r.Method, r.URL.Path)
			}
		}))
		req := staged()
		req.Draft = draft
		res, err := Ship(context.Background(), &GitHub{BaseURL: srv.URL, Token: "t"}, req)
		srv.Close()
		if err != nil {
			t.Fatalf("draft=%v: %v", draft, err)
		}
		want := "open"
		if draft {
			want = "draft"
		}
		if res.PRState != want {
			t.Fatalf("draft=%v: PRState=%q, want %q", draft, res.PRState, want)
		}
	}
}

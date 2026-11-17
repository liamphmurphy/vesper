package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestSignInLifecycle(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, _ := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	h := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Secrets: &secrets.Service{Q: q, Box: box}}).Handler()
	do := func(method, path, body string, want int) map[string]any {
		t.Helper()
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(method, "/api/v1"+path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		h.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("%s %s: %d %s", method, path, rec.Code, rec.Body.String())
		}
		var out map[string]any
		_ = json.Unmarshal(rec.Body.Bytes(), &out)
		return out
	}

	// Without an isolating runner nobody would pick it up.
	if l := do("GET", "/secrets", "", 200); l["sign_in_available"] != false {
		t.Fatalf("available without a runner: %v", l)
	}
	do("POST", "/sign-ins", `{"provider":"claude"}`, 409)
	if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: "r1", Backend: "fake", MaxConcurrent: 1, Version: "t"}); err != nil {
		t.Fatal(err)
	}
	do("POST", "/sign-ins", `{"provider":"claude"}`, 409) // a fake runner can't
	if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: "r-vm", Backend: "microvm", MaxConcurrent: 1, Version: "t"}); err != nil {
		t.Fatal(err)
	}
	if l := do("GET", "/secrets", "", 200); l["sign_in_available"] != true {
		t.Fatalf("not available with a microvm runner: %v", l)
	}
	if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: "r2", Backend: "docker", MaxConcurrent: 1, Version: "t"}); err != nil {
		t.Fatal(err)
	}
	if l := do("GET", "/secrets", "", 200); l["sign_in_available"] != true {
		t.Fatalf("not available with a Docker runner: %v", l)
	}
	do("POST", "/sign-ins", `{"provider":"nope"}`, 422)

	first := do("POST", "/sign-ins", `{"provider":"claude"}`, 201)
	if first["status"] != "pending" || first["needs_code"] != false {
		t.Fatalf("start = %v", first)
	}
	// Starting again replaces the one in progress.
	second := do("POST", "/sign-ins", `{"provider":"claude"}`, 201)
	if got := do("GET", "/sign-ins/"+first["id"].(string), "", 200); got["status"] != "cancelled" {
		t.Fatalf("first = %v", got)
	}
	id := second["id"].(string)

	// No code before the CLI showed its link.
	do("POST", "/sign-ins/"+id+"/code", `{"code":"abc"}`, 409)
	s, err := q.ClaimSignIn(ctx, ptr("r2"))
	if err != nil || s.ID.String() != id {
		t.Fatalf("claim %v %v", s.ID, err)
	}
	if err := q.SetSignInPrompt(ctx, store.SetSignInPromptParams{ID: s.ID, Url: "https://claude.com/x"}); err != nil {
		t.Fatal(err)
	}
	if got := do("GET", "/sign-ins/"+id, "", 200); got["needs_code"] != true || got["url"] != "https://claude.com/x" {
		t.Fatalf("waiting = %v", got)
	}
	do("POST", "/sign-ins/"+id+"/code", `{"code":"two\nlines"}`, 422)
	if got := do("POST", "/sign-ins/"+id+"/code", `{"code":" abc#def "}`, 200); got["needs_code"] != false {
		t.Fatalf("after code = %v", got)
	}
	if code, err := q.TakeSignInCode(ctx, s.ID); err != nil || code != "abc#def" {
		t.Fatalf("take = %q %v", code, err)
	}
	if _, err := q.TakeSignInCode(ctx, s.ID); err == nil {
		t.Fatal("the code was handed over twice")
	}

	do("DELETE", "/sign-ins/"+id, "", 204)
	if got := do("GET", "/sign-ins/"+id, "", 200); got["status"] != "cancelled" {
		t.Fatalf("cancelled = %v", got)
	}
	do("GET", "/sign-ins/00000000-0000-0000-0000-000000000000", "", 404)

	// Antigravity also uses the paste-back code flow.
	agy := do("POST", "/sign-ins", `{"provider":"antigravity"}`, 201)
	agyRow, err := q.ClaimSignIn(ctx, ptr("r2"))
	if err != nil || agyRow.ID.String() != agy["id"].(string) {
		t.Fatalf("claim antigravity %v %v", agyRow.ID, err)
	}
	if err := q.SetSignInPrompt(ctx, store.SetSignInPromptParams{ID: agyRow.ID, Url: "https://accounts.google.com/o/oauth2/auth?x=1"}); err != nil {
		t.Fatal(err)
	}
	if got := do("GET", "/sign-ins/"+agyRow.ID.String(), "", 200); got["needs_code"] != true {
		t.Fatalf("antigravity waiting = %v", got)
	}
	if got := do("POST", "/sign-ins/"+agyRow.ID.String()+"/code", `{"code":"4/0A-code"}`, 200); got["needs_code"] != false {
		t.Fatalf("antigravity after code = %v", got)
	}
	if code, err := q.TakeSignInCode(ctx, agyRow.ID); err != nil || code != "4/0A-code" {
		t.Fatalf("antigravity take = %q %v", code, err)
	}
}

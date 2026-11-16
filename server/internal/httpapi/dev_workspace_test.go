package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestOpenDevWorkspaceBranch(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()

	do := func(method, path string, body any) (int, map[string]any) {
		t.Helper()
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest(method, path, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}

	// Disabled / not configured returns 409.
	if code, _ := do("POST", "/api/v1/dev-workspace/open-branch", map[string]any{
		"repository": "https://github.com/acme/alpha.git",
		"branch":     "feat/x",
	}); code != 409 {
		t.Fatalf("when disabled: status = %d, want 409", code)
	}

	// Enable dev workspace.
	if code, _ := do("PATCH", "/api/v1/dev-workspace", map[string]any{
		"enabled": true,
		"repos":   []string{"https://github.com/acme/alpha.git"},
	}); code != 200 {
		t.Fatalf("enable dev workspace: status = %d", code)
	}

	// Invalid branch is rejected.
	if code, _ := do("POST", "/api/v1/dev-workspace/open-branch", map[string]any{
		"repository": "https://github.com/acme/alpha.git",
		"branch":     "bad..branch",
	}); code < 400 || code >= 500 {
		t.Fatalf("invalid branch: status = %d, want 4xx", code)
	}

	// Valid request queues open_branch and exposes target on ClaimDevWorkspaceAction.
	code, out := do("POST", "/api/v1/dev-workspace/open-branch", map[string]any{
		"repository": "https://github.com/acme/alpha.git",
		"branch":     "feat/open-pr",
		"pr_number":  42,
	})
	if code != 200 {
		t.Fatalf("open-branch: status = %d %v", code, out)
	}
	if out["state"] != "starting" || out["action"] != "open_branch" {
		t.Fatalf("unexpected response: %v", out)
	}

	runnerID := "test-runner"
	claimed, err := q.ClaimDevWorkspaceAction(ctx, store.ClaimDevWorkspaceActionParams{RunnerID: &runnerID})
	if err != nil {
		t.Fatalf("claim: %v", err)
	}
	if claimed.ClaimedAction == nil || *claimed.ClaimedAction != "open_branch" {
		t.Fatalf("claimed action = %v", claimed.ClaimedAction)
	}
	if claimed.ClaimedRepo == nil || *claimed.ClaimedRepo != "https://github.com/acme/alpha.git" {
		t.Fatalf("claimed repo = %v", claimed.ClaimedRepo)
	}
	if claimed.ClaimedBranch == nil || *claimed.ClaimedBranch != "feat/open-pr" {
		t.Fatalf("claimed branch = %v", claimed.ClaimedBranch)
	}
	if claimed.ClaimedPrNumber == nil || *claimed.ClaimedPrNumber != 42 {
		t.Fatalf("claimed pr_number = %v", claimed.ClaimedPrNumber)
	}
}

package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

func TestOnboardingCompleteIsRecordedOnce(t *testing.T) {
	e := newChatEnv(t)
	me := e.want("GET", "/me", nil, http.StatusOK)
	if me["onboarded_at"] != nil || me["harness_connected"] != true {
		t.Fatalf("fresh profile %v: want no onboarded_at and harness_connected (local CLI logins)", me)
	}
	first := e.want("POST", "/me/onboarding/complete", nil, http.StatusOK)["onboarded_at"]
	if first == nil {
		t.Fatal("onboarded_at not set")
	}
	// Running setup again from Settings keeps the first completion.
	if again := e.want("POST", "/me/onboarding/complete", nil, http.StatusOK)["onboarded_at"]; again != first {
		t.Fatalf("onboarded_at moved from %v to %v", first, again)
	}
	boot := e.want("GET", "/bootstrap", nil, http.StatusOK)
	if boot["me"].(map[string]any)["onboarded_at"] != first {
		t.Fatalf("bootstrap me %v", boot["me"])
	}
	// Teammates never see it.
	for _, u := range boot["users"].([]any) {
		if _, ok := u.(map[string]any)["onboarded_at"]; ok {
			t.Fatalf("teammate %v carries onboarded_at", u)
		}
	}
}

// With API-key runs (the Docker backend), Verify stores the pasted key as the
// harness secret and discovers models with it.
func TestVerifyHarnessStoresKeyAndDiscovers(t *testing.T) {
	var seen []string
	var srv *Server
	e := newChatEnvServer(t, func(rs *runs.Service) {
		rs.RequireHarnessKey = true
		rs.ModelDiscovery = func(_ context.Context, h, key string) ([]chatmodels.Model, error) {
			seen = append(seen, h+"="+key)
			if key == "sk-ant-api03-revoked" || key == "sk-ant-oat01-expired" || strings.Contains(key, "expired") {
				return nil, context.DeadlineExceeded
			}
			if strings.Contains(key, "pending") {
				return nil, chatmodels.ErrStillChecking
			}
			return []chatmodels.Model{{ID: "opus", Label: "Opus", Default: true}, {ID: "sonnet", Label: "Sonnet"}, {ID: "haiku", Label: "Haiku"}}, nil
		}
	}, func(s *Server) { srv = s })
	if me := e.want("GET", "/me", nil, http.StatusOK); me["harness_connected"] != false {
		t.Fatalf("no key yet, got %v", me["harness_connected"])
	}
	key := map[string]any{"kind": "api_key", "credential": "sk-ant-api03-good"}
	// Secrets off: explained, nothing stored.
	if out := e.want("POST", "/harness/claude-code/verify", key, http.StatusConflict); out["message"] == nil {
		t.Fatalf("secrets off: %v", out)
	}
	box := &secrets.Service{Q: e.q, Box: testBox(t)}
	e.runs.Secrets = box
	srv.Secrets = box

	e.invalid("POST", "/harness/claude-code/verify", map[string]any{"kind": "subscription", "credential": "sk-ant-api03-good"}, "credential", "sk-ant-oat")
	e.invalid("POST", "/harness/claude-code/verify", map[string]any{"kind": "api_key", "credential": "sk-ant-oat01-x"}, "credential", "sk-ant-")
	e.invalid("POST", "/harness/codex/verify", map[string]any{"kind": "subscription", "credential": "sk-proj-1"}, "credential", "auth.json")
	e.invalid("POST", "/harness/codex/verify", map[string]any{"kind": "api_key", "credential": "nope"}, "credential", "sk-")
	if len(seen) != 0 {
		t.Fatalf("a malformed credential reached discovery: %v", seen)
	}

	out := e.want("POST", "/harness/claude-code/verify", key, http.StatusOK)
	if out["ok"] != true || len(out["models"].([]any)) != 3 || out["error"] != nil || out["credential"] != nil {
		t.Fatalf("verify: %v", out)
	}
	if got, err := box.Reveal(context.Background(), e.me.WorkspaceID, nil, "harness:anthropic"); err != nil || got != "sk-ant-api03-good" {
		t.Fatalf("stored %q, %v", got, err)
	}
	if seen[len(seen)-1] != "claude-code=sk-ant-api03-good" {
		t.Fatalf("discovery saw %v", seen)
	}
	if me := e.want("GET", "/me", nil, http.StatusOK); me["harness_connected"] != true {
		t.Fatalf("after verify, harness_connected = %v", me["harness_connected"])
	}

	stored := func(name string) string {
		t.Helper()
		v, err := box.Reveal(context.Background(), e.me.WorkspaceID, nil, name)
		if err != nil {
			return ""
		}
		return v
	}
	// A key the provider refuses: not ok, a public reason, never the key, and
	// the working key stays.
	out = e.want("POST", "/harness/claude-code/verify", map[string]any{"kind": "api_key", "credential": "sk-ant-api03-revoked"}, http.StatusOK)
	if out["ok"] != false || out["error"] == nil || len(out["models"].([]any)) != 0 || strings.Contains(fmt.Sprint(out), "revoked") {
		t.Fatalf("refused key: %v", out)
	}
	if got := stored("harness:anthropic"); got != "sk-ant-api03-good" {
		t.Fatalf("a refused key replaced the working one: %q", got)
	}
	// A plan login is stored to be listed; when the listing fails, the earlier key comes back.
	out = e.want("POST", "/harness/claude-code/verify", map[string]any{"kind": "subscription", "credential": "sk-ant-oat01-expired"}, http.StatusOK)
	if out["ok"] != false || stored("harness:anthropic") != "sk-ant-api03-good" {
		t.Fatalf("failed plan login: %v, stored %q", out, stored("harness:anthropic"))
	}
	// A login the runner hasn't listed yet doesn't replace a working one either.
	if _, err := box.Set(context.Background(), e.me.WorkspaceID, e.me.ID, secrets.SetInput{Name: "harness:openai", Value: "sk-proj-working"}); err != nil {
		t.Fatal(err)
	}
	pending := `{"auth_mode":"chatgpt","tokens":{"refresh_token":"pending","account_id":"a"}}`
	out = e.want("POST", "/harness/codex/verify", map[string]any{"kind": "subscription", "credential": pending}, http.StatusOK)
	if out["ok"] != false || out["checking"] != nil || !strings.Contains(fmt.Sprint(out["error"]), "working one stays") || stored("harness:openai") != "sk-proj-working" {
		t.Fatalf("pending replacement: %v, stored %q", out, stored("harness:openai"))
	}
	if _, err := e.pool.Exec(context.Background(), `DELETE FROM secrets WHERE name = 'harness:openai'`); err != nil {
		t.Fatal(err)
	}
	// ...and with nothing before it, it is removed again.
	login := `{"auth_mode":"chatgpt","tokens":{"refresh_token":"expired","account_id":"a"}}`
	out = e.want("POST", "/harness/codex/verify", map[string]any{"kind": "subscription", "credential": login}, http.StatusOK)
	if ok, _, _ := e.runs.ChatCatalog().Check(context.Background(), e.q, e.me.WorkspaceID, "codex"); out["ok"] != false || ok.Available {
		t.Fatalf("failed codex login: %v, catalog %+v", out, ok)
	}
	if got := stored("harness:openai"); got != "" {
		t.Fatalf("a failed first login stayed stored")
	}
	// Codex has no key: checking without a credential reports why.
	out = e.want("POST", "/harness/codex/verify", nil, http.StatusOK)
	if out["ok"] != false || out["error"] != "no harness:openai secret" {
		t.Fatalf("codex without key: %v", out)
	}
}

// With the host's CLI logins (the local backend), Verify asks the CLI over its
// control protocol: here the repository's fake-harness standing in for both.
func TestVerifyHarnessAgainstFakeHarness(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "fake-harness")
	if out, err := exec.Command("go", "build", "-o", bin, "github.com/liamphmurphy/vesper/server/cmd/fake-harness").CombinedOutput(); err != nil {
		t.Fatalf("build fake-harness: %v\n%s", err, out)
	}
	t.Setenv("RUNNER_CLAUDE_BIN", bin)
	t.Setenv("RUNNER_CODEX_BIN", bin)
	e := newChatEnvWith(t, func(rs *runs.Service) { rs.ModelDiscovery = nil })
	for harness, model := range map[string]string{"claude-code": "sonnet", "codex": "gpt-5-codex"} {
		out := e.want("POST", "/harness/"+harness+"/verify", nil, http.StatusOK)
		models, _ := out["models"].([]any)
		if out["ok"] != true || len(models) != 1 || models[0].(map[string]any)["id"] != model {
			t.Fatalf("%s: %v", harness, out)
		}
	}
	// Antigravity: the fake answers `agy models`, and only under the name agy.
	agy := filepath.Join(dir, "agy")
	if err := os.Symlink(bin, agy); err != nil {
		t.Fatal(err)
	}
	t.Setenv("RUNNER_ANTIGRAVITY_BIN", agy)
	out := e.want("POST", "/harness/antigravity/verify", nil, http.StatusOK)
	models, _ := out["models"].([]any)
	if out["ok"] != true || len(models) != 2 || models[0].(map[string]any)["id"] != "gemini-3.8-flash" {
		t.Fatalf("antigravity: %v", out)
	}
	t.Setenv("RUNNER_ANTIGRAVITY_BIN", "")
	if out := e.want("POST", "/harness/antigravity/verify", nil, http.StatusOK); out["ok"] != false || out["error"] == nil {
		t.Fatalf("antigravity without a stand-in must be unavailable, not an error: %v", out)
	}
	// Runs here use the CLI sign-in, so there is no key to paste.
	e.invalid("POST", "/harness/claude-code/verify", map[string]any{"kind": "subscription", "credential": "sk-ant-oat01-x"}, "credential", "sign-ins on its host")
	t.Setenv("RUNNER_CLAUDE_BIN", filepath.Join(dir, "missing"))
	if out := e.want("POST", "/harness/claude-code/verify", nil, http.StatusOK); out["ok"] != false || out["error"] == nil {
		t.Fatalf("missing CLI: %v", out)
	}
}

// Antigravity uses a native Antigravity login bundle stored in
// harness:google, checked through the runner's `agy models` listing rather than
// a Gemini API key.
func TestVerifyHarnessAntigravityTakesNativeSignIn(t *testing.T) {
	var asked []string
	var srv *Server
	e := newChatEnvServer(t, func(rs *runs.Service) {
		rs.RequireHarnessKey = true
		rs.ModelDiscovery = nil
		l := &chatmodels.QueuedListings{Pool: rs.Pool, Wait: time.Millisecond, Poll: time.Millisecond}
		rs.PlanModels = func(ctx context.Context, ws uuid.UUID, h string, wait bool) ([]chatmodels.Model, error) {
			asked = append(asked, h)
			return l.Models(ctx, ws, h, wait)
		}
	}, func(s *Server) { srv = s })
	box := &secrets.Service{Q: e.q, Box: testBox(t)}
	e.runs.Secrets = box
	srv.Secrets = box

	e.invalid("POST", "/harness/antigravity/verify", map[string]any{"kind": "api_key", "credential": "AIzaSyExample"}, "credential", "native Google Antigravity sign-in")
	e.invalid("POST", "/harness/antigravity/verify", map[string]any{"kind": "subscription", "credential": "AIzaSyExample"}, "credential", "Antigravity login")
	if len(asked) != 0 {
		t.Fatalf("a malformed credential reached discovery: %v", asked)
	}
	bundle := `{"v":1,"files":{".config/antigravity/plugin-secrets.json":"{\"token\":\"ok\"}"}}`
	out := e.want("POST", "/harness/antigravity/verify", map[string]any{"kind": "subscription", "credential": bundle}, http.StatusOK)
	// No runner is present to complete listing; first login stays pending without hitting AI Studio HTTP discovery.
	if out["ok"] != false || out["checking"] != true || len(asked) != 1 || asked[0] != "antigravity" {
		t.Fatalf("unexpected verify result: %v asked=%v", out, asked)
	}
	// Verifying with nothing configured reports no harness:google secret once rolled back.
	if _, err := e.pool.Exec(context.Background(), `DELETE FROM secrets WHERE name = 'harness:google'`); err != nil {
		t.Fatal(err)
	}
	out = e.want("POST", "/harness/antigravity/verify", nil, http.StatusOK)
	if out["ok"] != false || out["error"] != "no harness:google secret" {
		t.Fatalf("antigravity without key: %v", out)
	}
}

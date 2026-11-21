package harness

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

func TestPolicyHookFailsClosed(t *testing.T) {
	for _, mode := range []string{"allow", "deny", "unavailable", "redirect"} {
		t.Run(mode, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer fake-run-token" {
					t.Error("missing run token")
				}
				switch mode {
				case "unavailable":
					w.WriteHeader(503)
				case "redirect":
					http.Redirect(w, r, "https://example.com/", 302)
				default:
					_ = json.NewEncoder(w).Encode(map[string]string{"decision": mode, "reason": "Exact action needs approval"})
				}
			}))
			defer s.Close()
			file := filepath.Join(t.TempDir(), "hook.py")
			if err := os.WriteFile(file, toolHook, 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("python3", file)
			cmd.Env = append(os.Environ(), "LAZYAGENTS_POLICY_URL="+s.URL, "LAZYAGENTS_POLICY_TOKEN=fake-run-token")
			cmd.Stdin = strings.NewReader(`{"tool_name":"Bash","tool_input":{"command":"go test ./..."}}`)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("hook: %v %s", err, out)
			}
			var decision struct {
				Hook struct {
					Decision string `json:"permissionDecision"`
				} `json:"hookSpecificOutput"`
			}
			if err := json.Unmarshal(out, &decision); err != nil {
				t.Fatal(err)
			}
			if mode == "allow" && decision.Hook.Decision != "" || mode != "allow" && decision.Hook.Decision != "deny" {
				t.Fatalf("mode=%s output=%s", mode, out)
			}
			if strings.Contains(string(out), "fake-run-token") {
				t.Fatal("token leaked")
			}
		})
	}
}

func TestCodexPreflightRejectsUnreviewedHooks(t *testing.T) {
	expected := "python3 '/generated/policy.py'"
	own := `{"enabled":true,"source":"sessionFlags","handlerType":"command","command":"python3 '/generated/policy.py'","eventName":"preToolUse","matcher":"*","trustStatus":"untrusted"}`
	check := func(hooks ...string) error {
		return validateCodexHooks(json.RawMessage(`{"data":[{"errors":[],"hooks":[`+strings.Join(hooks, ",")+`]}]}`), expected)
	}
	if err := check(own); err != nil {
		t.Fatalf("own hook rejected: %v", err)
	}
	if err := check(own, `{"enabled":true,"trustStatus":"trusted"}`); err != nil {
		t.Fatalf("own + trusted hook rejected: %v", err)
	}
	for _, tc := range []struct {
		name  string
		hooks []string
	}{
		{"empty", nil},
		{"untrusted", []string{own, `{"enabled":true,"trustStatus":"untrusted"}`}},
		{"modified", []string{own, `{"enabled":true,"trustStatus":"modified"}`}},
		{"wrong_cmd", []string{`{"enabled":true,"source":"sessionFlags","handlerType":"command","command":"unexpected","eventName":"preToolUse","matcher":"*","trustStatus":"untrusted"}`}},
		{"async", []string{`{"enabled":true,"source":"sessionFlags","handlerType":"command","command":"python3 '/generated/policy.py'","eventName":"preToolUse","matcher":"*","async":true,"trustStatus":"untrusted"}`}},
	} {
		if err := check(tc.hooks...); err == nil {
			t.Errorf("%s: unreviewed or missing hook was accepted", tc.name)
		}
	}
}

// The fake backend defaults to a relative data directory. The hook executes
// after the child has changed into that workspace, so resolve it before launch.
func TestPolicyHookWithRelativeWorkspace(t *testing.T) {
	var calls atomic.Int32
	service := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/v1/agent/tool-policy" {
			t.Errorf("unexpected policy path %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer fake-run-token" {
			t.Error("missing run token")
		}
		var check struct {
			Tool string `json:"tool"`
		}
		if err := json.NewDecoder(r.Body).Decode(&check); err != nil || check.Tool != "mcp__lazyagents__whoami" {
			t.Errorf("preflight must only check read-only MCP access: %s %v", check.Tool, err)
		}
		calls.Add(1)
		_, _ = w.Write([]byte(`{"decision":"allow"}`))
	}))
	defer service.Close()
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	workspace := filepath.Join(t.TempDir(), "run's workspace with spaces")
	if err := os.MkdirAll(filepath.Join(workspace, ".lazyagents"), 0700); err != nil {
		t.Fatal(err)
	}
	relative, err := filepath.Rel(cwd, workspace)
	if err != nil {
		t.Fatal(err)
	}
	for _, adapter := range []Harness{ClaudeCode{}, Codex{}} {
		for _, session := range []string{"", "existing-session"} {
			t.Run(adapter.Name()+"/"+session, func(t *testing.T) {
				inv, err := adapter.Invocation(Workspace{Dir: relative, MCPURL: service.URL + "/mcp", Token: "fake-run-token", TokenEnv: "LA_TOKEN"}, Turn{Spec: spec(), Prompt: "continue", SessionID: session})
				if err != nil {
					t.Fatal(err)
				}
				path := inv.Env["LAZYAGENTS_POLICY_HOOK_PATH"]
				expected, err := filepath.Abs(filepath.Join(workspace, toolHookPath))
				if err != nil {
					t.Fatal(err)
				}
				if !filepath.IsAbs(path) || path != expected {
					t.Fatalf("hook path must resolve before chdir: %q want %q", path, expected)
				}
				if err := os.WriteFile(filepath.Join(workspace, toolHookPath), inv.Files[toolHookPath], 0600); err != nil {
					t.Fatal(err)
				}
				cmd := exec.Command("sh", "-c", inv.Env["LAZYAGENTS_POLICY_HOOK_COMMAND"]+" --check")
				cmd.Dir = workspace
				cmd.Env = os.Environ()
				for key, value := range inv.Env {
					cmd.Env = append(cmd.Env, key+"="+value)
				}
				out, err := cmd.CombinedOutput()
				if err != nil {
					t.Fatalf("relative-workspace hook: %v %s", err, out)
				}
				if strings.TrimSpace(string(out)) != "{}" {
					t.Fatalf("hook check failed: %s", out)
				}
			})
		}
	}
	if calls.Load() != 4 {
		t.Fatalf("expected every new/resumed harness to reach the policy service; calls=%d", calls.Load())
	}
}

func TestCodexPreflightRejectsHookGroupErrors(t *testing.T) {
	raw := json.RawMessage(`{"data":[{"errors":["invalid config"],"hooks":[{"enabled":true,"source":"sessionFlags","handlerType":"command","command":"python3 '/ws/.lazyagents/tool-policy.py'","eventName":"preToolUse","matcher":"*","trustStatus":"untrusted"}]}]}`)
	if err := validateCodexHooks(raw, "python3 '/ws/.lazyagents/tool-policy.py'"); err == nil {
		t.Fatal("expected group error in hooks/list to be rejected")
	}
}

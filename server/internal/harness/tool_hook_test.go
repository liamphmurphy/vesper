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
	for name, script := range map[string][]byte{"claude-codex": toolHook, "antigravity": agyPolicyHook} {
		t.Run(name, func(t *testing.T) { testPolicyHookFailures(t, script) })
	}
}

func testPolicyHookFailures(t *testing.T, script []byte) {
	for _, mode := range []string{"allow", "deny", "unauthenticated", "unavailable", "network", "redirect"} {
		t.Run(mode, func(t *testing.T) {
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.Header.Get("Authorization") != "Bearer fake-run-token" {
					t.Error("missing run token")
				}
				switch mode {
				case "unauthenticated":
					w.WriteHeader(401)
					_, _ = w.Write([]byte("fake-run-token")) // Never echo a server's error body.
				case "unavailable":
					w.WriteHeader(503)
				case "redirect":
					http.Redirect(w, r, "https://example.com/", 302)
				default:
					_ = json.NewEncoder(w).Encode(map[string]string{"decision": mode, "reason": "Exact action needs approval"})
				}
			}))
			defer s.Close()
			if mode == "network" {
				s.Close()
			}
			file := filepath.Join(t.TempDir(), "hook.py")
			if err := os.WriteFile(file, script, 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("python3", file)
			cmd.Env = append(os.Environ(), "LAZYAGENTS_POLICY_URL="+s.URL, "LAZYAGENTS_POLICY_TOKEN=fake-run-token")
			cmd.Stdin = strings.NewReader(`{"tool_name":"Bash","tool_input":{"command":"go test ./..."},"toolCall":{"name":"run_command","args":{"CommandLine":"go test ./..."}}}`)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("hook: %v %s", err, out)
			}
			var decision struct {
				Decision string `json:"decision"`
				Reason   string `json:"reason"`
				Hook     struct {
					Decision string `json:"permissionDecision"`
					Reason   string `json:"permissionDecisionReason"`
				} `json:"hookSpecificOutput"`
			}
			if err := json.Unmarshal(out, &decision); err != nil {
				t.Fatal(err)
			}
			if decision.Decision == "deny" {
				decision.Hook.Decision, decision.Hook.Reason = decision.Decision, decision.Reason
			}
			if mode == "allow" && decision.Hook.Decision != "" || mode != "allow" && decision.Hook.Decision != "deny" {
				t.Fatalf("mode=%s output=%s", mode, out)
			}
			if strings.Contains(string(out), "fake-run-token") {
				t.Fatal("token leaked")
			}
			category := map[string]string{"unauthenticated": "HTTP 401", "unavailable": "HTTP 503", "network": "unreachable"}[mode]
			if category != "" && !strings.Contains(decision.Hook.Reason, category) {
				t.Fatalf("missing failure category %q: %s", category, out)
			}
		})
	}
}

func TestCodexPreflightRejectsUnreviewedHooks(t *testing.T) {
	file := filepath.Join(t.TempDir(), "launcher.py")
	if err := os.WriteFile(file, codexLauncher, 0600); err != nil {
		t.Fatal(err)
	}
	script := `import runpy,sys
validate=runpy.run_path(sys.argv[1])["validate_hooks"]
expected="python3 '/generated/policy.py'"
own={"enabled":True,"source":"sessionFlags","handlerType":"command","command":expected,"eventName":"preToolUse","matcher":"*","trustStatus":"untrusted"}
def check(hooks):
    validate({"data":[{"errors":[],"hooks":hooks}]},expected)
check([own])
check([own,{"enabled":True,"trustStatus":"trusted"}])
for hooks in ([],[own,{"enabled":True,"trustStatus":"untrusted"}],[own,{"enabled":True,"trustStatus":"modified"}],[dict(own,command="unexpected")],[dict(own,**{"async":True})]):
    try:
        check(hooks)
    except RuntimeError:
        continue
    raise AssertionError("unreviewed or missing hook was accepted")
`
	cmd := exec.Command("python3", "-B", "-c", script, file)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("trust preflight: %v %s", err, out)
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

func TestCodexPreflightRejectsMissingHookBeforeStartingCLI(t *testing.T) {
	dir := t.TempDir()
	launcher := filepath.Join(dir, "launcher.py")
	if err := os.WriteFile(launcher, codexLauncher, 0600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("python3", launcher, "this-program-must-never-start", "exec", "unused-prompt")
	cmd.Env = append(os.Environ(), "LAZYAGENTS_POLICY_HOOK_PATH="+filepath.Join(dir, "missing.py"), "LAZYAGENTS_POLICY_HOOK_COMMAND=python3 missing.py")
	out, err := cmd.Output()
	if err == nil {
		t.Fatal("missing hook was accepted")
	}
	var event struct{ Type, Message string }
	if err := json.Unmarshal(out, &event); err != nil {
		t.Fatalf("missing actionable error event: %s", out)
	}
	if event.Type != "error" || !strings.Contains(event.Message, "Policy hook script is missing") {
		t.Fatalf("unexpected failure: %s", out)
	}
}

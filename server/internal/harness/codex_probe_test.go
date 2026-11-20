package harness

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

func TestCodexHooksValidation(t *testing.T) {
	expected := "python3 '/ws/.lazyagents/tool-policy.py'"
	valid := json.RawMessage(`{"data":[{"errors":[],"hooks":[{"enabled":true,"source":"sessionFlags","handlerType":"command","command":"python3 '/ws/.lazyagents/tool-policy.py'","eventName":"preToolUse","matcher":"*","async":false,"trustStatus":"untrusted"}]}]}`)
	if err := validateCodexHooks(valid, expected); err != nil {
		t.Fatalf("expected valid hook config to pass, got %v", err)
	}

	untrustedOther := json.RawMessage(`{"data":[{"errors":[],"hooks":[{"enabled":true,"source":"sessionFlags","handlerType":"command","command":"python3 '/ws/.lazyagents/tool-policy.py'","eventName":"preToolUse","matcher":"*","async":false,"trustStatus":"untrusted"},{"enabled":true,"source":"project","handlerType":"command","command":"evil","eventName":"preToolUse","matcher":"*","async":false,"trustStatus":"untrusted"}]}]}`)
	if err := validateCodexHooks(untrustedOther, expected); err == nil {
		t.Fatal("expected untrusted third-party hook to be rejected")
	}

	missingVesper := json.RawMessage(`{"data":[{"errors":[],"hooks":[{"enabled":true,"source":"project","handlerType":"command","command":"ok","eventName":"preToolUse","matcher":"*","async":false,"trustStatus":"trusted"}]}]}`)
	if err := validateCodexHooks(missingVesper, expected); err == nil {
		t.Fatal("expected missing Vesper hook to be rejected")
	}
}

func TestCodexProbe(t *testing.T) {
	bin := os.Getenv("CODEX_BIN")
	if os.Getenv("CODEX_PROBE") != "1" || bin == "" {
		t.Skip("set CODEX_PROBE=1 and CODEX_BIN to probe the real codex")
	}
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	if out, err := exec.Command(bin, "--version").CombinedOutput(); err != nil {
		t.Fatalf("codex --version: %v\n%s", err, out)
	} else {
		t.Logf("codex --version: %s", strings.TrimSpace(string(out)))
	}

	runTurn := func(t *testing.T, c Codex, dir, codexHome, vesperURL, apiURL, cacheDir string, turn Turn) (Result, []Event, string) {
		t.Helper()
		ws := Workspace{
			Dir:                dir,
			MCPURL:             vesperURL + "/mcp",
			Token:              "probe-token",
			TokenEnv:           "LAZYAGENTS_TOKEN",
			DependencyCacheDir: cacheDir,
		}
		inv, err := c.SessionInvocation(ws, turn)
		if err != nil {
			t.Fatal(err)
		}
		for rel, body := range inv.Files {
			p := filepath.Join(dir, rel)
			if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(p, body, 0o644); err != nil {
				t.Fatal(err)
			}
		}
		argv := append(append([]string(nil), inv.Argv[1:]...),
			"-c", `model_provider="probe"`,
			"-c", fmt.Sprintf(`model_providers.probe={name="probe",base_url=%q,env_key="OPENAI_API_KEY",wire_api="responses"}`, apiURL+"/v1"),
		)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, bin, argv...)
		cmd.Dir = dir
		cmd.Env = []string{
			"HOME=" + codexHome,
			"CODEX_HOME=" + codexHome,
			"PATH=/usr/local/bin:/usr/bin:/bin",
			"OPENAI_API_KEY=sk-probe-not-a-key",
		}
		for k, v := range inv.Env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		stdin, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			t.Fatal(err)
		}
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		var mu sync.Mutex
		var events []Event
		var sid string
		res, runErr := c.RunSession(ctx, stdin, stdout, ws, turn, SessionCallbacks{
			OnEvent: func(ev Event) {
				mu.Lock()
				events = append(events, ev)
				mu.Unlock()
			},
			OnSession: func(id string) {
				mu.Lock()
				sid = id
				mu.Unlock()
			},
			CheckTool: func(_ context.Context, _ string, _ map[string]any) (bool, string) {
				return true, ""
			},
		})
		waitErr := cmd.Wait()
		if runErr != nil || waitErr != nil {
			t.Fatalf("runErr=%v waitErr=%v res=%+v stderr=%s", runErr, waitErr, res, stderr.String())
		}
		return res, events, sid
	}

	t.Run("session_and_resume", func(t *testing.T) {
		dir := t.TempDir()
		codexHome := t.TempDir()
		cacheDir := t.TempDir()

		policy := &agyPolicyStub{denied: []string{"Bash"}}
		mcp := &agyMCPStub{}
		mux := http.NewServeMux()
		mux.Handle("/api/v1/agent/tool-policy", policy)
		mux.Handle("/mcp", mcp)
		vesper := httptest.NewServer(mux)
		t.Cleanup(vesper.Close)

		api := &codexResponsesStub{}
		openai := httptest.NewServer(api)
		t.Cleanup(openai.Close)

		s := spec("repo:read", "allowed", "repo:write", "allowed", "tests:run", "allowed")
		s.Harness = agentdef.HarnessCodex
		s.Model = "gpt-5"
		s.HarnessOptions[agentdef.OptionNoMCP] = "true"
		res1, evs1, sid1 := runTurn(t, Codex{}, dir, codexHome, vesper.URL, openai.URL, cacheDir, Turn{
			Spec:         s,
			Prompt:       "PROBE_CODEX_1: try command then answer.",
			SystemAppend: "CODEX_SYSTEM_APPEND",
			ConfigTag:    "probe-codex",
		})
		if res1.IsError || res1.SessionID == "" || sid1 == "" {
			t.Fatalf("turn 1 failed: res=%+v sid=%q", res1, sid1)
		}
		if res1.Final != "Codex turn 1 done." {
			t.Fatalf("turn 1 Final=%q, want %q", res1.Final, "Codex turn 1 done.")
		}
		if res1.Usage.ContextTokens <= 0 || res1.Usage.InputTokens <= 0 {
			t.Fatalf("expected ContextTokens and InputTokens > 0, got %+v", res1.Usage)
		}
		if _, err := os.Stat(filepath.Join(dir, "blocked.txt")); !os.IsNotExist(err) {
			t.Fatalf("blocked.txt should not exist; err=%v", err)
		}
		if got := policy.tools(); !slices.Contains(got, "Bash") {
			t.Fatalf("expected Bash in policy hook checks, got %v (events=%v)", got, evs1)
		}
		if mcp.calls("initialize") != 0 {
			t.Fatalf("expected OptionNoMCP not to initialize lazyagents MCP server, got %d calls", mcp.calls("initialize"))
		}
		if !api.sawText("CODEX_SYSTEM_APPEND") {
			t.Errorf("developerInstructions SystemAppend missing from API request")
		}

		// Resume the session and confirm Baseline subtracts cumulative session usage.
		res2, _, sid2 := runTurn(t, Codex{Baseline: res1.Usage}, dir, codexHome, vesper.URL, openai.URL, cacheDir, Turn{
			Spec:      s,
			Prompt:    "PROBE_CODEX_2: reply directly.",
			SessionID: res1.SessionID,
		})
		if res2.IsError || sid2 != res1.SessionID {
			t.Fatalf("turn 2 failed: res=%+v sid2=%q sid1=%q", res2, sid2, res1.SessionID)
		}
		if res2.Final != "Codex turn 2 done." {
			t.Fatalf("turn 2 Final=%q", res2.Final)
		}
		if res2.Usage.SessionInputTokens <= res1.Usage.SessionInputTokens {
			t.Errorf("expected cumulative session tokens to grow: turn1=%d turn2=%d", res1.Usage.SessionInputTokens, res2.Usage.SessionInputTokens)
		}
		if res2.Usage.InputTokens <= 0 || res2.Usage.InputTokens >= res2.Usage.SessionInputTokens {
			t.Errorf("expected delta InputTokens after Baseline subtraction, got turn2=%+v (turn1=%+v)", res2.Usage, res1.Usage)
		}
	})
}

type codexResponsesStub struct {
	mu   sync.Mutex
	reqs []string
}

func (s *codexResponsesStub) sawText(sub string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.reqs {
		if strings.Contains(r, sub) {
			return true
		}
	}
	return false
}

func (s *codexResponsesStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	raw := string(body)
	s.mu.Lock()
	s.reqs = append(s.reqs, raw)
	s.mu.Unlock()

	type outAction struct {
		callID  string
		command string
		text    string
	}
	var act outAction
	switch {
	case strings.Contains(raw, "PROBE_CODEX_2"):
		act.text = "Codex turn 2 done."
	case strings.Contains(raw, "PROBE_CODEX_1") && !strings.Contains(raw, `"call_id":"call_bash_1"`):
		act.callID = "call_bash_1"
		act.command = "echo bad > blocked.txt"
	default:
		act.text = "Codex turn 1 done."
	}

	w.Header().Set("Content-Type", "text/event-stream")
	emit := func(typ string, payload map[string]any) {
		payload["type"] = typ
		b, _ := json.Marshal(payload)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", typ, b)
	}
	respID := fmt.Sprintf("resp_%d", len(raw))
	emit("response.created", map[string]any{"response": map[string]any{"id": respID, "object": "response", "status": "in_progress"}})

	var outItems []any
	if act.callID != "" {
		args, _ := json.Marshal(map[string]any{"cmd": act.command})
		item := map[string]any{
			"id":        "fc_1",
			"type":      "function_call",
			"call_id":   act.callID,
			"name":      "exec_command",
			"arguments": string(args),
			"status":    "completed",
		}
		outItems = append(outItems, item)
		emit("response.output_item.added", map[string]any{"output_index": 0, "item": item})
		emit("response.output_item.done", map[string]any{"output_index": 0, "item": item})
	} else {
		item := map[string]any{
			"id":      "msg_1",
			"type":    "message",
			"role":    "assistant",
			"status":  "completed",
			"content": []any{map[string]any{"type": "output_text", "text": act.text}},
		}
		outItems = append(outItems, item)
		emit("response.output_item.added", map[string]any{"output_index": 0, "item": item})
		emit("response.output_text.delta", map[string]any{"item_id": "msg_1", "output_index": 0, "content_index": 0, "delta": act.text})
		emit("response.output_item.done", map[string]any{"output_index": 0, "item": item})
	}
	emit("response.completed", map[string]any{
		"response": map[string]any{
			"id":     respID,
			"object": "response",
			"status": "completed",
			"output": outItems,
			"usage": map[string]any{
				"input_tokens":  100,
				"output_tokens": 20,
				"total_tokens":  120,
				"input_tokens_details": map[string]any{
					"cached_tokens": 20,
				},
			},
		},
	})
}

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

// TestClaudeProbe runs the real claude CLI against a stub Messages API over
// Claude Code's bidirectional stream-json stdio protocol, verifying CheckTool
// policy gating, inline image blocks, SystemAppend, and OptionNoMCP.
func TestClaudeProbe(t *testing.T) {
	bin := os.Getenv("CLAUDE_BIN")
	if os.Getenv("CLAUDE_PROBE") != "1" || bin == "" {
		t.Skip("set CLAUDE_PROBE=1 and CLAUDE_BIN to probe the real claude")
	}
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	if out, err := exec.Command(bin, "--version").CombinedOutput(); err != nil {
		t.Fatalf("claude --version: %v\n%s", err, out)
	} else {
		t.Logf("claude --version: %s", strings.TrimSpace(string(out)))
	}

	t.Run("session", func(t *testing.T) {
		api := &claudeSessionStub{}
		dir := t.TempDir()
		if err := os.WriteFile(filepath.Join(dir, "hello.txt"), []byte("hello-session\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		vesper := httptest.NewServer(http.NotFoundHandler())
		t.Cleanup(vesper.Close)
		anthropic := httptest.NewServer(api)
		t.Cleanup(anthropic.Close)

		s := spec("repo:read", "allowed", "repo:write", "allowed", "tests:run", "allowed")
		s.HarnessOptions[agentdef.OptionNoMCP] = "true"
		turn := Turn{
			Spec:         s,
			Prompt:       "PROBE_SESSION_TASK: run blocked bash then read.",
			SystemAppend: "APPEND_SYSTEM_MARKER",
			ConfigTag:    "probe-sess",
			InlineImages: []InlineImage{{
				MediaType: "image/png",
				Data:      tinyProbePNG(),
			}},
		}
		inv, err := ClaudeCode{}.SessionInvocation(Workspace{
			Dir:      dir,
			MCPURL:   vesper.URL + "/mcp",
			Token:    "probe-token",
			TokenEnv: "LAZYAGENTS_TOKEN",
		}, turn)
		if err != nil {
			t.Fatal(err)
		}
		for rel, body := range inv.Files {
			path := filepath.Join(dir, rel)
			if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(path, body, 0o644); err != nil {
				t.Fatal(err)
			}
		}

		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
		defer cancel()
		cmd := exec.CommandContext(ctx, bin, inv.Argv[1:]...)
		cmd.Dir = dir
		cmd.Env = []string{"HOME=" + t.TempDir(), "PATH=/usr/local/bin:/usr/bin:/bin", "ANTHROPIC_API_KEY=sk-probe-not-a-key", "ANTHROPIC_BASE_URL=" + anthropic.URL}
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
		var checked []string
		var gotSession string
		var gotEvents []Event
		res, runErr := ClaudeCode{}.RunSession(ctx, stdin, stdout, Workspace{Dir: dir}, turn, SessionCallbacks{
			OnEvent: func(ev Event) {
				mu.Lock()
				gotEvents = append(gotEvents, ev)
				mu.Unlock()
			},
			OnSession: func(sid string) {
				mu.Lock()
				gotSession = sid
				mu.Unlock()
			},
			CheckTool: func(_ context.Context, tool string, input map[string]any) (bool, string) {
				mu.Lock()
				checked = append(checked, tool)
				mu.Unlock()
				if tool == "Bash" {
					return false, "blocked by probe policy"
				}
				return true, ""
			},
		})
		waitErr := cmd.Wait()
		if runErr != nil || waitErr != nil {
			t.Fatalf("runErr=%v waitErr=%v stderr=%s", runErr, waitErr, stderr.String())
		}
		if res.Final != "Session done." || gotSession == "" || len(gotEvents) == 0 {
			t.Fatalf("unexpected result=%+v session=%q events=%d", res, gotSession, len(gotEvents))
		}
		if _, err := os.Stat(filepath.Join(dir, "blocked.txt")); !os.IsNotExist(err) {
			t.Fatalf("blocked.txt should not exist; err=%v", err)
		}
		mu.Lock()
		gotChecked := slices.Clone(checked)
		mu.Unlock()
		if !slices.Contains(gotChecked, "Bash") || !slices.Contains(gotChecked, "Read") {
			t.Fatalf("expected Bash and Read to hit CheckTool, got %v", gotChecked)
		}
		if len(api.reqs) == 0 {
			t.Fatal("API never received a request")
		}
		firstReq := api.reqs[0]
		if !strings.Contains(string(firstReq.System), "APPEND_SYSTEM_MARKER") {
			t.Errorf("SystemAppend missing from API system prompt: %s", string(firstReq.System))
		}
		if !strings.Contains(firstReq.raw, "data:image/png") && !strings.Contains(firstReq.raw, `"type":"image"`) {
			t.Errorf("inline image missing from API request")
		}
		for _, tn := range firstReq.toolNames() {
			if strings.HasPrefix(tn, "mcp__") {
				t.Errorf("expected noMCP to omit mcp tool %q", tn)
			}
		}
	})
}

func tinyProbePNG() []byte {
	// Valid 1x1 transparent PNG.
	return []byte{
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
		0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
		0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
		0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4,
		0x89, 0x00, 0x00, 0x00, 0x0a, 0x49, 0x44, 0x41,
		0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
		0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00,
		0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae,
		0x42, 0x60, 0x82,
	}
}

type claudeSessionStub struct {
	mu   sync.Mutex
	reqs []*claudeRequest
}

func (s *claudeSessionStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	if !strings.HasPrefix(r.URL.Path, "/v1/messages") || strings.Contains(r.URL.Path, "count_tokens") {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"input_tokens":10}`)
		return
	}
	req := &claudeRequest{raw: string(body)}
	_ = json.Unmarshal(body, req)
	s.mu.Lock()
	s.reqs = append(s.reqs, req)
	s.mu.Unlock()

	var block map[string]any
	switch {
	case !strings.Contains(req.raw, "PROBE_SESSION_TASK"):
		block = map[string]any{"type": "text", "text": "ok"}
	case !strings.Contains(req.raw, "toolu_bash_1"):
		block = map[string]any{"type": "tool_use", "id": "toolu_bash_1", "name": "Bash", "input": map[string]any{"command": "echo bad > blocked.txt", "description": "Blocked"}}
	case !strings.Contains(req.raw, "toolu_read_1"):
		block = map[string]any{"type": "tool_use", "id": "toolu_read_1", "name": "Read", "input": map[string]any{"file_path": "hello.txt"}}
	default:
		block = map[string]any{"type": "text", "text": "Session done."}
	}

	w.Header().Set("Content-Type", "text/event-stream")
	event := func(v map[string]any) {
		b, _ := json.Marshal(v)
		fmt.Fprintf(w, "event: %s\ndata: %s\n\n", v["type"], b)
	}
	event(map[string]any{"type": "message_start", "message": map[string]any{"id": "msg_probe", "type": "message", "role": "assistant", "model": req.Model, "content": []any{}, "usage": map[string]any{"input_tokens": 10, "output_tokens": 1}}})
	if block["type"] == "text" {
		event(map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "text", "text": ""}})
		event(map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "text_delta", "text": block["text"]}})
	} else {
		input, _ := json.Marshal(block["input"])
		event(map[string]any{"type": "content_block_start", "index": 0, "content_block": map[string]any{"type": "tool_use", "id": block["id"], "name": block["name"], "input": map[string]any{}}})
		event(map[string]any{"type": "content_block_delta", "index": 0, "delta": map[string]any{"type": "input_json_delta", "partial_json": string(input)}})
	}
	event(map[string]any{"type": "content_block_stop", "index": 0})
	stop := "end_turn"
	if block["type"] == "tool_use" {
		stop = "tool_use"
	}
	event(map[string]any{"type": "message_delta", "delta": map[string]any{"stop_reason": stop}, "usage": map[string]any{"output_tokens": 5}})
	event(map[string]any{"type": "message_stop"})
}

type claudeRequest struct {
	Model    string            `json:"model"`
	System   json.RawMessage   `json:"system"`
	Messages []json.RawMessage `json:"messages"`
	Tools    []struct {
		Name string `json:"name"`
	} `json:"tools"`
	raw string
}

func (r *claudeRequest) toolNames() []string {
	var names []string
	for _, tool := range r.Tools {
		names = append(names, tool.Name)
	}
	slices.Sort(names)
	return names
}

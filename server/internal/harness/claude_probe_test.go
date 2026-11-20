package harness

import (
	"bufio"
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

// TestClaudeProbe runs the real claude CLI against a stub Messages API, as
// TestAgyProbe does for agy. It checks what Vesper's sub agents rely on:
// a sub agent's own tool calls reach the policy hook, and with background
// tasks off the lead waits for the report within one turn and one result.
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

	t.Run("helper", func(t *testing.T) {
		api := &claudeStub{}
		policy, mcp := &agyPolicyStub{}, &agyMCPStub{}
		dir := t.TempDir()
		mux := http.NewServeMux()
		mux.Handle("/api/v1/agent/tool-policy", policy)
		mux.Handle("/mcp", mcp)
		vesper := httptest.NewServer(mux)
		t.Cleanup(vesper.Close)
		anthropic := httptest.NewServer(api)
		t.Cleanup(anthropic.Close)

		s := spec("repo:read", "allowed", "repo:write", "allowed", "tests:run", "allowed")
		inv, err := ClaudeCode{}.Invocation(Workspace{Dir: dir, MCPURL: vesper.URL + "/mcp", Token: "probe-token", TokenEnv: "LAZYAGENTS_TOKEN"},
			Turn{Spec: s, Prompt: "Do the probe task."})
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
		var stdout, stderr bytes.Buffer
		cmd.Stdin, cmd.Stdout, cmd.Stderr = strings.NewReader(""), &stdout, &stderr
		if err := cmd.Run(); err != nil || ctx.Err() != nil {
			t.Fatalf("claude: %v\nstderr: %s", err, stderr.String())
		}

		parser := ClaudeCode{}.NewParser("")
		results := 0
		sc := bufio.NewScanner(&stdout)
		sc.Buffer(make([]byte, 1<<20), 8<<20)
		for sc.Scan() {
			var l struct {
				Type string `json:"type"`
			}
			if json.Unmarshal(sc.Bytes(), &l) == nil && l.Type == "result" {
				results++
			}
			parser.Line(sc.Bytes())
		}
		if results != 1 {
			t.Errorf("want exactly one result line, got %d: the lead didn't wait for its sub agent", results)
		}
		if res := parser.Result(); res.Final != "Lead done." || res.Usage.SubagentToolCalls != 1 {
			t.Errorf("result %+v", res)
		}
		if got := policy.tools(); !slices.Equal(got, []string{"Agent", "Bash"}) || policy.input(0)["subagent_type"] != agentdef.HelperAgent ||
			!strings.Contains(fmt.Sprint(policy.input(1)["command"]), "from-helper") {
			t.Errorf("policy saw %v %v", got, policy.inputs)
		}
		lead, helper := api.request("Do the probe task."), api.request(agentdef.HelperPrompt)
		if lead == nil || helper == nil {
			t.Fatal("the lead or the helper never reached the API")
		}
		if helper.Model != lead.Model {
			t.Errorf("helper on %s, lead on %s: the helper inherits the lead's model", helper.Model, lead.Model)
		}
		if names := helper.toolNames(); !slices.Equal(names, []string{"Bash", "Edit", "Glob", "Grep", "Read", "Write"}) {
			t.Errorf("helper tools %v", names)
		}
	})
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

// claudeStub is the Messages API: the lead starts the helper and finishes once
// it reports; the helper runs one command and reports; anything else (a title,
// a summary) gets "ok".
type claudeStub struct {
	mu   sync.Mutex
	reqs []*claudeRequest
}

func (s *claudeStub) request(marker string) *claudeRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.reqs {
		if strings.Contains(r.raw, marker) {
			return r
		}
	}
	return nil
}

func (s *claudeStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
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
	var first string
	if len(req.Messages) > 0 {
		first = string(req.Messages[0])
	}
	var block map[string]any
	switch {
	case strings.Contains(string(req.System), agentdef.HelperPrompt) || strings.Contains(first, "PROBE_HELPER_TASK"):
		if strings.Contains(req.raw, "toolu_helper_1") {
			block = map[string]any{"type": "text", "text": "Ran it: from-helper."}
		} else {
			block = map[string]any{"type": "tool_use", "id": "toolu_helper_1", "name": "Bash", "input": map[string]any{"command": "echo from-helper", "description": "Probe"}}
		}
	case strings.Contains(first, "Do the probe task."):
		if strings.Contains(req.raw, "toolu_lead_1") {
			block = map[string]any{"type": "text", "text": "Lead done."}
		} else {
			block = map[string]any{"type": "tool_use", "id": "toolu_lead_1", "name": "Agent", "input": map[string]any{"subagent_type": agentdef.HelperAgent, "description": "Probe", "prompt": "PROBE_HELPER_TASK: run the probe command."}}
		}
	default:
		block = map[string]any{"type": "text", "text": "ok"}
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

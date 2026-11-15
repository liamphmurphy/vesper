package harness

import (
	"encoding/json"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// antigravity-turn.jsonl is a real agy 1.5.8 read-only chat turn recorded by
// TestAgyProbe: an MCP call, a read, a command and a subagent the policy
// denied, and a write the static deny rule stopped (testdata/README.md).
func TestAntigravityTurn(t *testing.T) {
	evs, res := parse(t, Antigravity{}, "antigravity-turn.jsonl", "")
	want := "lifecycle message tool_call:list_tickets tool_result:list_tickets tool_call:Read tool_result:Read tool_call:Bash tool_result:Bash tool_call:Write tool_result:Write tool_call:Agent tool_result:Agent message usage"
	if got := types(evs); got != want {
		t.Fatalf("events:\n got %s\nwant %s", got, want)
	}
	if res.SessionID != "e94c1262-923f-4bbb-bf7f-2d9cd9792aa9" || res.Final != "Done.\n" || res.IsError {
		t.Fatalf("result = %+v", res)
	}
	if evs[0].Payload["session_id"] != res.SessionID {
		t.Fatalf("init carries the conversation id: %+v", evs[0].Payload)
	}
	results := map[string]map[string]any{}
	for _, e := range evs {
		if e.Type == "tool_result" {
			results[e.Payload["tool"].(string)] = e.Payload
		}
	}
	if results["list_tickets"]["is_error"] != false || results["list_tickets"]["output"] != "LAZYAGENTS-1 probe ticket" || results["Read"]["is_error"] != false {
		t.Fatalf("allowed tools: %v", results)
	}
	// A step that ends in ERROR is a failed call, not a missing one.
	if r := results["Bash"]; r["is_error"] != true || !strings.Contains(r["output"].(string), "denied by pre-tool hook: probe policy") {
		t.Fatalf("denied command: %v", r)
	}
	if r := results["Write"]; r["is_error"] != true || !strings.Contains(r["output"].(string), "Matches user-configured deny rule") {
		t.Fatalf("statically denied write: %v", r)
	}
	if r := results["Agent"]; r["is_error"] != true {
		t.Fatalf("denied subagent: %v", r)
	}
	// Six requests of 200 uncached + 1000 cached input and 37 output (30 + 7
	// thinking) each, as the stub's usageMetadata said.
	u := res.Usage
	if u.ToolCalls != 5 || u.InputTokens != 7200 || u.CachedTokens != 6000 || u.CacheReportedInputTokens != 7200 || u.OutputTokens != 222 || u.ContextTokens != 1200 || u.CostSource != "unknown" {
		t.Fatalf("usage = %+v", u)
	}
	for _, e := range evs {
		if e.Type == "usage" {
			if _, ok := e.Payload["cost_usd"]; ok || e.Payload["cost_known"] != false {
				t.Fatalf("agy reports no cost: %+v", e.Payload)
			}
		}
	}
}

// A resumed conversation's result.usage also counts its earlier turns (seen
// with --conversation against the stub): only this process's steps are billed.
func TestAntigravityResumedTurnCountsOnlyItsOwnRequests(t *testing.T) {
	p := (Antigravity{}).NewParser("")
	for _, l := range []string{
		`{"event":"init","conversation_id":"c","init":{"cwd":"/workspace"}}`,
		`{"event":"step_update","step_update":{"conversation_id":"c","step_index":4,"state":"DONE","step_type":"agent_response","text_delta":"resumed\n","usage":{"input_tokens":200,"output_tokens":37,"thinking_tokens":7,"cache_read_tokens":1000,"total_tokens":237}}}`,
		`{"event":"result","result":{"conversation_id":"c","status":"SUCCESS","response":"resumed\n","num_turns":2,"usage":{"input_tokens":400,"output_tokens":74,"thinking_tokens":14,"cache_read_tokens":2000,"total_tokens":474}}}`,
	} {
		p.Line([]byte(l))
	}
	if u := p.Result().Usage; u.InputTokens != 1200 || u.OutputTokens != 37 || u.CachedTokens != 1000 {
		t.Fatalf("usage = %+v, want this turn's one request", u)
	}
	// A failure before any request reports no usage, not the earlier turns'.
	p = (Antigravity{}).NewParser("")
	evs := p.Line([]byte(`{"event":"result","result":{"conversation_id":"c","status":"ERROR","error":"Error 503","usage":{"input_tokens":400,"output_tokens":74}}}`))
	if u := p.Result().Usage; u.InputTokens != 0 || u.OutputTokens != 0 || types(evs) != "error" {
		t.Fatalf("usage = %+v, events %s", u, types(evs))
	}
}

func TestAntigravityQuotaFailureIsALimit(t *testing.T) {
	_, res := parse(t, Antigravity{}, "antigravity-error.jsonl", "")
	if !res.IsError || !strings.Contains(res.Error, "exceeded your current quota") || !res.UsageLimited {
		t.Fatalf("a quota failure must be a usage limit so fallbacks apply: %+v", res)
	}
	now := time.Now()
	if at, ok := LimitReset(res.Error, now); !ok || !at.Equal(now.Add(41*time.Second)) {
		t.Fatalf("the RetryInfo delay is the reset time: %v %v", at, ok)
	}
	p := (Antigravity{}).NewParser("")
	// As agy 1.5.8 prints it on stderr.
	evs := p.Line([]byte(`AGY_ERROR: {"short_error":"agent executor error: model overloaded","status":"UNAVAILABLE","error_code":503,"code_kind":"http","retryable":true,"error_id":"e-1"}`))
	if len(evs) != 1 || evs[0].Type != "error" || p.Result().Error != "agent executor error: model overloaded" {
		t.Fatalf("AGY_ERROR line: %+v %+v", evs, p.Result())
	}
}

func TestAntigravityRememberImagesTheToolSaved(t *testing.T) {
	p := (Antigravity{}).NewParser("")
	p.Line([]byte(`{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"DONE","step_type":"tool","tool_info":{"name":"generate_image","parameters":{"prompt":"a fox"},"output":"Saved /home/agent/.gemini/antigravity-cli/artifacts/c/fox.png and /etc/cron.d/x.sh"}}}`))
	if got := p.Result().Images; !slices.Equal(got, []string{"/home/agent/.gemini/antigravity-cli/artifacts/c/fox.png"}) {
		t.Fatalf("images = %v: only image files count, the runner decides where they may come from", got)
	}
}

func TestAntigravityRememberImagesInAssistantText(t *testing.T) {
	p := (Antigravity{}).NewParser("")
	p.Line([]byte(`{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"DONE","step_type":"agent_response","text_delta":"Saved to /home/agent/.gemini/antigravity-cli/brain/sub-123/fox.png"}}`))
	if got := p.Result().Images; !slices.Equal(got, []string{"/home/agent/.gemini/antigravity-cli/brain/sub-123/fox.png"}) {
		t.Fatalf("images = %v", got)
	}
}

type agyConfigFile struct {
	Install     bool           `json:"install"`
	TokenEnv    string         `json:"token_env"`
	HookCommand string         `json:"hook_command"`
	Settings    map[string]any `json:"settings"`
	MCPServers  map[string]any `json:"mcp_servers"`
}

func agyInvocation(t *testing.T, s agentdef.Resolved, turn Turn) (Invocation, agyConfigFile) {
	t.Helper()
	s.Harness, s.Model = agentdef.HarnessAntigravity, "gemini-3.8-flash"
	turn.Spec = s
	inv, err := (Antigravity{}).Invocation(ws, turn)
	if err != nil {
		t.Fatal(err)
	}
	var cfg agyConfigFile
	if err := json.Unmarshal(inv.Files[agyConfigPath], &cfg); err != nil {
		t.Fatal(err)
	}
	return inv, cfg
}

func rules(cfg agyConfigFile, list string) []string {
	var out []string
	for _, r := range cfg.Settings["permissions"].(map[string]any)[list].([]any) {
		out = append(out, r.(string))
	}
	return out
}

func TestAntigravityInvocation(t *testing.T) {
	s := spec("repo:read", "allowed")
	s.HarnessOptions["effort"] = "high"
	inv, cfg := agyInvocation(t, s, Turn{Prompt: "go", SessionID: "conv-9"})
	if !slices.Equal(inv.Argv[:3], []string{"python3", agyLaunchPath, "agy"}) || flag(inv.Argv, "--output-format") != "stream-json" ||
		flag(inv.Argv, "--model") != "gemini-3.8-flash" || flag(inv.Argv, "--effort") != "high" || flag(inv.Argv, "--conversation") != "conv-9" {
		t.Fatalf("argv = %q", inv.Argv)
	}
	// A legacy model slug carrying its own effort suffix is stripped when
	// --effort is also passed, because agy rejects conflicting combinations.
	sLegacy := s
	sLegacy.Harness, sLegacy.Model = agentdef.HarnessAntigravity, "gemini-3.8-flash-medium"
	if invLegacy, err := (Antigravity{}).Invocation(ws, Turn{Spec: sLegacy, Prompt: "go"}); err != nil || flag(invLegacy.Argv, "--model") != "gemini-3.8-flash" || flag(invLegacy.Argv, "--effort") != "high" {
		t.Fatalf("legacy model+effort = %v (%q)", err, invLegacy.Argv)
	}
	if i := slices.Index(inv.Argv, "-p"); i < 0 || !strings.HasSuffix(inv.Argv[i+1], "go") || !strings.Contains(inv.Argv[i+1], "AGENTS.md") {
		t.Fatalf("prompt = %q", inv.Argv)
	}
	if slices.Contains(inv.Argv, "--dangerously-skip-permissions") {
		t.Fatal("approving every tool would defeat the policy hook and the deny rules")
	}
	if inv.Env["LAZYAGENTS_TOKEN"] != "la_tok" || inv.Env["LAZYAGENTS_POLICY_TOKEN"] != "la_tok" || !strings.HasSuffix(inv.Env["LAZYAGENTS_POLICY_HOOK_COMMAND"], "agy-policy.py'") {
		t.Fatalf("env = %v", inv.Env)
	}
	if _, hasProvider := cfg.Settings["modelProvider"]; hasProvider || cfg.Settings["toolPermission"] != "request-review" || cfg.Settings["agentMode"] != "" || cfg.Settings["enableTerminalSandbox"] != false || cfg.Install {
		t.Fatalf("settings = %v install=%v", cfg.Settings, cfg.Install)
	}
	// The token reaches agy only through the launcher, never a workspace file.
	for p, body := range inv.Files {
		if strings.Contains(string(body), "la_tok") {
			t.Errorf("%s contains the run token", p)
		}
	}
	srv := cfg.MCPServers["lazyagents"].(map[string]any)
	if srv["serverUrl"] != "http://api:8000/mcp" || srv["headers"].(map[string]any)["Authorization"] != "Bearer {{token}}" {
		t.Fatalf("mcp = %v", srv)
	}
	if !slices.Contains(rules(cfg, "allow"), "mcp(lazyagents/*)") {
		t.Fatalf("allow = %v", rules(cfg, "allow"))
	}
}

func TestAntigravityDenyRulesFollowTheSpec(t *testing.T) {
	cases := []struct {
		name    string
		spec    agentdef.Resolved
		want    []string
		notWant []string
	}{
		{"read-only chat", func() agentdef.Resolved {
			s := spec("repo:read", "allowed")
			s.HarnessOptions["readonly"] = "true"
			return s
		}(), []string{"command(*)", "write_file(*)", "read_url(*)"}, nil},
		{"coding run", spec("repo:read", "allowed", "repo:write", "allowed", "tests:run", "allowed", "web:read", "allowed"), nil, []string{"command(*)", "write_file(*)", "read_url(*)"}},
		{"approval-gated writes stay denied until approved", spec("repo:read", "allowed", "repo:write", "requires_approval", "tests:run", "allowed"), []string{"write_file(*)"}, []string{"command(*)"}},
		{"image step writes elsewhere", func() agentdef.Resolved {
			s := spec()
			s.HarnessOptions["readonly"], s.HarnessOptions[agentdef.OptionImageGeneration] = "true", "true"
			return s
		}(), []string{"command(*)"}, []string{"write_file(*)"}},
		{"no tools", func() agentdef.Resolved {
			s := spec("repo:read", "allowed")
			s.HarnessOptions[agentdef.OptionNoTools] = "true"
			return s
		}(), []string{"command(*)", "read_file(*)", "write_file(*)", "mcp(*)"}, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			_, cfg := agyInvocation(t, c.spec, Turn{Prompt: "x"})
			deny := rules(cfg, "deny")
			for _, w := range c.want {
				if !slices.Contains(deny, w) {
					t.Errorf("deny %v lacks %s", deny, w)
				}
			}
			for _, w := range c.notWant {
				if slices.Contains(deny, w) {
					t.Errorf("deny %v has %s", deny, w)
				}
			}
		})
	}
	// A no-tools turn gets no MCP server at all and isn't told to read AGENTS.md.
	s := spec("repo:read", "allowed")
	s.HarnessOptions[agentdef.OptionNoTools] = "true"
	inv, cfg := agyInvocation(t, s, Turn{Prompt: "summarize"})
	if len(cfg.MCPServers) != 0 || inv.Argv[slices.Index(inv.Argv, "-p")+1] != "summarize" {
		t.Fatalf("no-tools turn: mcp=%v argv=%q", cfg.MCPServers, inv.Argv)
	}
}

func TestAntigravityConnectorsAndInstallInContainers(t *testing.T) {
	s := spec("repo:read", "allowed")
	s.MCPServers = []agentdef.MCPServer{{Name: "github", Connector: true}, {Name: "docs", URL: "https://docs.example/mcp"}}
	c := ws
	c.ContainerSandbox = true
	s.Harness, s.Model = agentdef.HarnessAntigravity, "m"
	inv, err := (Antigravity{}).Invocation(c, Turn{Spec: s, Prompt: "x"})
	if err != nil {
		t.Fatal(err)
	}
	var cfg agyConfigFile
	_ = json.Unmarshal(inv.Files[agyConfigPath], &cfg)
	gh, docs := cfg.MCPServers["github"].(map[string]any), cfg.MCPServers["docs"].(map[string]any)
	if !cfg.Install || gh["serverUrl"] != "http://api:8000/mcp/connectors/github" || gh["headers"] == nil || docs["serverUrl"] != "https://docs.example/mcp" || docs["headers"] != nil {
		t.Fatalf("install=%v mcp=%v", cfg.Install, cfg.MCPServers)
	}
	if !slices.Contains(rules(cfg, "allow"), "mcp(github/*)") || !slices.Contains(rules(cfg, "allow"), "mcp(docs/*)") {
		t.Fatalf("allow = %v", rules(cfg, "allow"))
	}
}

func TestAntigravityReferenceImagesAreNamedInThePrompt(t *testing.T) {
	inv, _ := agyInvocation(t, spec("repo:read", "allowed"), Turn{Prompt: "draw", Images: []string{".lazyagents/references/persona.png"}})
	if p := inv.Argv[slices.Index(inv.Argv, "-p")+1]; !strings.Contains(p, ".lazyagents/references/persona.png") {
		t.Fatalf("prompt = %q", p)
	}
}

// TestAgyPolicyHookAgreesWithTheParser runs the real hook script against a stub
// policy server: each tool call must reach the policy as the same name and input
// the parser shows in the run's events, and Vesper's answer maps to agy's.
func TestAgyPolicyHookAgreesWithTheParser(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	var got struct {
		Tool  string         `json:"tool"`
		Input map[string]any `json:"input"`
	}
	answer := `{"decision":"allow"}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer la_tok" {
			t.Errorf("auth = %q", r.Header.Get("Authorization"))
		}
		_ = json.NewDecoder(r.Body).Decode(&got)
		w.Write([]byte(answer))
	}))
	defer srv.Close()
	dir := t.TempDir()
	script := filepath.Join(dir, "agy-policy.py")
	if err := os.WriteFile(script, agyPolicyHook, 0o644); err != nil {
		t.Fatal(err)
	}
	run := func(name string, args map[string]any, url string) map[string]any {
		event, _ := json.Marshal(map[string]any{"toolCall": map[string]any{"name": name, "args": args}})
		cmd := exec.Command("python3", "-I", script)
		cmd.Stdin = strings.NewReader(string(event))
		cmd.Env = []string{"LAZYAGENTS_POLICY_URL=" + url, "LAZYAGENTS_POLICY_TOKEN=la_tok"}
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		var d map[string]any
		if err := json.Unmarshal(out, &d); err != nil {
			t.Fatalf("%s printed %q", name, out)
		}
		return d
	}
	for _, c := range []struct {
		name string
		args map[string]any
	}{
		// The tools agy 1.5.8 declares to the model, with their real argument keys.
		{"run_command", map[string]any{"CommandLine": "go test ./...", "toolSummary": "Run tests", "WaitMsBeforeAsync": 500.0}},
		{"read_file", map[string]any{"Path": "/workspace/a.go", "StartLine": 1.0}},
		{"write_file", map[string]any{"Path": "/workspace/b.go", "Content": "package b"}},
		{"edit_file", map[string]any{"Path": "/workspace/c.go", "Target": "a", "Replacement": "b"}},
		{"call_mcp_tool", map[string]any{"ServerName": "lazyagents", "ToolName": "get_ticket", "Arguments": map[string]any{"ticket": "X-1"}}},
		{"call_mcp_tool", map[string]any{"ServerName": "lazyagents"}},
		{"invoke_subagent", map[string]any{"TypeName": "general", "Role": "helper", "Prompt": "run ls"}},
		{"swarm", map[string]any{"action": "add"}},
		{"search_web", map[string]any{"query": "go slog"}},
		// agy's internal names (init's tool list), should a step report one.
		{"view_file", map[string]any{"AbsolutePath": "/workspace/a.go"}},
		{"write_to_file", map[string]any{"TargetFile": "/workspace/b.go"}},
		{"replace_file_content", map[string]any{"TargetFile": "/workspace/c.go"}},
		{"list_dir", map[string]any{"DirectoryPath": "/workspace"}},
		{"grep_search", map[string]any{"Query": "TODO", "SearchPath": "/workspace"}},
		{"find_by_name", map[string]any{"Pattern": "*.go", "SearchPath": "/workspace"}},
		{"read_url_content", map[string]any{"Url": "https://go.dev"}},
		{"mcp_lazyagents_get_ticket", map[string]any{"ticket": "X-1"}},
		{"browser_subagent", map[string]any{"Task": "x"}},
	} {
		got.Tool, got.Input = "", nil
		d := run(c.name, c.args, srv.URL)
		wantTool, wantInput := antigravityTool(c.name, c.args)
		wantJSON, _ := json.Marshal(wantInput)
		gotJSON, _ := json.Marshal(got.Input)
		if got.Tool != wantTool || string(gotJSON) != string(wantJSON) {
			t.Errorf("%s: hook sent %s %s, parser says %s %s", c.name, got.Tool, gotJSON, wantTool, wantJSON)
		}
		if d["decision"] != "auto_approve" {
			t.Errorf("%s: allow became %v", c.name, d)
		}
		if c.name == "run_command" {
			ov, _ := d["overwrite"].(map[string]any)
			if ov["BypassSandbox"] != true {
				t.Errorf("run_command allow overwrite = %v, want BypassSandbox=true", d["overwrite"])
			}
		} else if _, has := d["overwrite"]; has {
			t.Errorf("%s unexpected overwrite = %v", c.name, d["overwrite"])
		}
	}
	if d := run("run_command", map[string]any{"CommandLine": "go test ./...", "BypassSandbox": true}, srv.URL); d["overwrite"] != nil {
		t.Fatalf("run_command with BypassSandbox already true = %v", d)
	}
	answer = `{"decision":"deny","reason":"repo:write is denied for this run"}`
	if d := run("write_to_file", map[string]any{"TargetFile": "x"}, srv.URL); d["decision"] != "deny" || d["reason"] != "repo:write is denied for this run" || d["overwrite"] != nil {
		t.Fatalf("deny = %v", d)
	}
	// Anything but an explicit allow, and any failure, denies.
	answer = `{"decision":"ask"}`
	if d := run("run_command", map[string]any{}, srv.URL); d["decision"] != "deny" {
		t.Fatalf("unknown answer = %v", d)
	}
	if d := run("run_command", map[string]any{}, "http://127.0.0.1:1/"); d["decision"] != "deny" {
		t.Fatalf("unreachable policy = %v", d)
	}
}

func TestAntigravityToolNamesInEvents(t *testing.T) {
	for in, want := range map[string]string{
		"run_command": "Bash", "read_file": "Read", "write_file": "Write", "edit_file": "Edit", "invoke_subagent": "Agent",
		"view_file": "Read", "write_to_file": "Write", "replace_file_content": "Edit", "call_mcp_tool": "call_mcp_tool",
		"mcp_lazyagents_search_knowledge": "mcp__lazyagents_search_knowledge", "browser_subagent": "browser_subagent",
	} {
		if got, _ := antigravityTool(in, nil); got != want {
			t.Errorf("%s → %s, want %s", in, got, want)
		}
	}
	// Every MCP tool arrives through call_mcp_tool; the policy must see it as
	// that server's tool, or a read-only chat is refused its own tools.
	tool, input := antigravityTool("call_mcp_tool", map[string]any{"ServerName": "lazyagents", "ToolName": "list_tickets", "Arguments": map[string]any{"q": "x"}})
	if tool != "mcp__lazyagents__list_tickets" || input["q"] != "x" {
		t.Fatalf("call_mcp_tool → %s %v", tool, input)
	}
}

// agy 1.5.8 lists .agents/skills/<name>/SKILL.md to the model, as Codex reads
// it (TestAgyProbe checks the real CLI), so skills go there and the chat's
// AGENTS.md doesn't point at a copy elsewhere.
func TestAntigravitySkillsAreNative(t *testing.T) {
	s := spec("repo:read", "allowed")
	s.Skills = []agentdef.Skill{{Name: "review", Description: "Review a diff", Body: "Read it all."}}
	inv, _ := agyInvocation(t, s, Turn{Prompt: "go"})
	if len(inv.Files[".agents/skills/review/SKILL.md"]) == 0 || !strings.Contains(string(inv.Files[SkillsExcludeFile]), "/.agents/skills/review/") {
		t.Fatalf("files = %v", slices.Collect(maps.Keys(inv.Files)))
	}
	if _, ok := inv.Files[".lazyagents/skills/review/SKILL.md"]; ok {
		t.Fatal("a second copy outside the native location")
	}
	s.Harness = agentdef.HarnessAntigravity
	if md := string(ChatAgentsMD(s, nil, "PAY", "", nil)); strings.Contains(md, "## Skills") {
		t.Fatalf("the index would point at files that aren't there:\n%s", md)
	}
}

// TestAgyLauncherNamesAMissingBinary: an agent image built without agy must say
// so, not fail with execvp's bare "No such file or directory".
func TestAgyLauncherNamesAMissingBinary(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 is not installed")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "agy-launch.py")
	if err := os.WriteFile(script, agyLauncher, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "agy-config.json"), []byte(`{"install": false}`), 0o644); err != nil {
		t.Fatal(err)
	}
	python, _ := exec.LookPath("python3")
	cmd := exec.Command(python, "-I", script, "agy", "-p", "hi")
	cmd.Env = []string{"PATH=" + t.TempDir()} // an empty PATH: no agy anywhere
	out, err := cmd.Output()
	if code := cmd.ProcessState.ExitCode(); err == nil || code != 1 {
		t.Fatalf("exit = %d, err = %v", code, err)
	}
	var line struct {
		Result struct{ Status, Error string } `json:"result"`
	}
	if err := json.Unmarshal(out, &line); err != nil {
		t.Fatalf("stdout %q: %v", out, err)
	}
	if line.Result.Status != "ERROR" || line.Result.Error != "Vesper Antigravity setup: agy isn't installed in the agent image; rebuild agent-base" {
		t.Fatalf("result = %+v", line.Result)
	}
}

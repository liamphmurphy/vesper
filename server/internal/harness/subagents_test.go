package harness

import (
	"encoding/json"
	"slices"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

func explorerSpec(opts ...string) agentdef.Resolved {
	s := spec("repo:write", "allowed", "tests:run", "allowed")
	for i := 0; i+1 < len(opts); i += 2 {
		s.HarnessOptions[opts[i]] = opts[i+1]
	}
	return s
}

func TestNoNativeSubagentConfigsAcrossHarnesses(t *testing.T) {
	for _, tc := range []struct {
		name string
		h    Harness
		s    func() agentdef.Resolved
	}{
		{"claude", ClaudeCode{}, func() agentdef.Resolved { return explorerSpec() }},
		{"codex", Codex{}, func() agentdef.Resolved {
			s := explorerSpec()
			s.Harness, s.Model = agentdef.HarnessCodex, "gpt-5-codex"
			return s
		}},
		{"antigravity", Antigravity{}, func() agentdef.Resolved {
			s := explorerSpec()
			s.Harness, s.Model = agentdef.HarnessAntigravity, "gemini-3.8-flash"
			return s
		}},
	} {
		inv, err := tc.h.Invocation(ws, Turn{Spec: tc.s(), Prompt: "go"})
		if err != nil {
			t.Fatalf("%s Invocation: %v", tc.name, err)
		}
		if slices.Contains(inv.Argv, "--agents") || inv.Env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] != "" {
			t.Errorf("%s emitted native subagent flags/env: argv=%v env=%v", tc.name, inv.Argv, inv.Env)
		}
		if slices.Contains(strings.Split(flag(inv.Argv, "--allowedTools"), ","), "Agent") {
			t.Errorf("%s allowed native Agent tool: %v", tc.name, inv.Argv)
		}
		for path := range inv.Files {
			if strings.Contains(path, "claude-agents.json") || strings.Contains(path, ".agents/agents/") {
				t.Errorf("%s wrote native subagent file %q", tc.name, path)
			}
		}
	}
}

func TestIsolatedSubagentSessionConfigs(t *testing.T) {
	const tag = "subagent-job123"
	wsSandbox := ws
	wsSandbox.ContainerSandbox = true

	// Claude Code: isolated config paths and no MCP servers.
	cs := explorerSpec(agentdef.OptionNoMCP, "true", agentdef.OptionSubagents, "false")
	cInv, err := (ClaudeCode{}).SessionInvocation(wsSandbox, Turn{Spec: cs, Prompt: "read x", ConfigTag: tag})
	if err != nil {
		t.Fatal(err)
	}
	wantClaudeMCP := ".lazyagents/" + tag + "-mcp.json"
	if flag(cInv.Argv, "--mcp-config") != wantClaudeMCP || flag(cInv.Argv, "--settings") != ".lazyagents/"+tag+"-claude-settings.json" {
		t.Fatalf("claude tagged argv = %v", cInv.Argv)
	}
	var cMCP struct {
		MCPServers map[string]any `json:"mcpServers"`
	}
	if err := json.Unmarshal(cInv.Files[wantClaudeMCP], &cMCP); err != nil || len(cMCP.MCPServers) != 0 {
		t.Fatalf("claude OptionNoMCP mcpServers = %v (%v)", cMCP.MCPServers, err)
	}

	// Codex: isolated hook path and no lazyagents MCP server.
	xs := explorerSpec(agentdef.OptionNoMCP, "true", agentdef.OptionSubagents, "false")
	xs.Harness, xs.Model = agentdef.HarnessCodex, "gpt-5-mini"
	xInv, err := (Codex{}).SessionInvocation(wsSandbox, Turn{Spec: xs, Prompt: "read x", ConfigTag: tag})
	if err != nil {
		t.Fatal(err)
	}
	wantCodexHook := ".lazyagents/" + tag + "-tool-policy.py"
	if len(xInv.Files[wantCodexHook]) == 0 || xInv.Files[toolHookPath] != nil {
		t.Fatalf("codex tagged hook files missing %s: %v", wantCodexHook, xInv.Files)
	}
	for _, a := range xInv.Argv {
		if strings.Contains(a, "mcp_servers.lazyagents") {
			t.Fatalf("codex OptionNoMCP registered MCP server: %v", xInv.Argv)
		}
	}

	// Antigravity: isolated config/policy files, isolated_home flag, and no MCP servers.
	as := explorerSpec(agentdef.OptionNoMCP, "true", agentdef.OptionSubagents, "false")
	as.Harness, as.Model = agentdef.HarnessAntigravity, "gemini-3.8-flash"
	aInv, err := (Antigravity{}).SessionInvocation(wsSandbox, Turn{Spec: as, Prompt: "read x", ConfigTag: tag})
	if err != nil {
		t.Fatal(err)
	}
	wantAgyCfg := ".lazyagents/" + tag + "-agy-config.json"
	wantAgyPolicy := ".lazyagents/" + tag + "-agy-policy.py"
	if flag(aInv.Argv, "--config") != wantAgyCfg || len(aInv.Files[wantAgyPolicy]) == 0 || aInv.Files[agyConfigPath] != nil {
		t.Fatalf("agy tagged invocation = %v", aInv.Argv)
	}
	var aCfg struct {
		IsolatedHome bool           `json:"isolated_home"`
		MCPServers   map[string]any `json:"mcp_servers"`
	}
	if err := json.Unmarshal(aInv.Files[wantAgyCfg], &aCfg); err != nil || !aCfg.IsolatedHome || len(aCfg.MCPServers) != 0 {
		t.Fatalf("agy tagged config = %+v (%v)", aCfg, err)
	}
}

func TestClaudeSubagentMessagesAreNotTheReply(t *testing.T) {
	lines := []string{
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Let me ask the explorer."},{"type":"tool_use","id":"a1","name":"Agent","input":{"subagent_type":"explorer","prompt":"where?"}}]}}`,
		`{"type":"user","parent_tool_use_id":"a1","message":{"content":"where?"}}`,
		`{"type":"assistant","parent_tool_use_id":"a1","message":{"content":[{"type":"tool_use","id":"s1","name":"Grep","input":{}},{"type":"tool_use","id":"s2","name":"Read","input":{}}]}}`,
		`{"type":"user","parent_tool_use_id":"a1","message":{"content":[{"type":"tool_result","tool_use_id":"s1","content":"x.go:1"},{"type":"tool_result","tool_use_id":"s2","content":"package x"}]}}`,
		`{"type":"assistant","parent_tool_use_id":"a1","message":{"content":[{"type":"text","text":"It's in x.go:1."}]}}`,
		`{"type":"assistant","parent_tool_use_id":"a1","message":{"content":"plain sub agent text"}}`,
		`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"a1","content":"It's in x.go:1."}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"text","text":"Found it in x.go."}]}}`,
	}
	p := ClaudeCode{}.NewParser("")
	var evs []Event
	for _, l := range lines {
		evs = append(evs, p.Line([]byte(l))...)
	}
	res := p.Result()
	if res.Final != "Found it in x.go." {
		t.Errorf("Final = %q", res.Final)
	}
	if res.Usage.ToolCalls != 1 || res.Usage.SubagentToolCalls != 2 {
		t.Errorf("tool calls lead=%d sub=%d, want 1/2", res.Usage.ToolCalls, res.Usage.SubagentToolCalls)
	}
	if res.Usage.ExploreOutputBytes != 0 {
		t.Errorf("sub agent output counted as the lead's: %d", res.Usage.ExploreOutputBytes)
	}
	want := "message tool_call:Agent tool_call:Grep tool_call:Read tool_result:Grep tool_result:Read tool_result:Agent message"
	if types(evs) != want {
		t.Fatalf("events:\n got %s\nwant %s", types(evs), want)
	}
	for i, e := range evs {
		sub := i >= 2 && i <= 5
		if (e.Payload["subagent"] == true) != sub {
			t.Errorf("event %d %s subagent=%v", i, types([]Event{e}), e.Payload["subagent"])
		}
	}
}

func TestSubagentGuideInPrompts(t *testing.T) {
	guide := agentdef.SubagentGuide(explorerSpec())
	if guide == "" {
		t.Fatal("no guide")
	}
	if !strings.Contains(string(AgentsMD("", explorerSpec(), nil, "T-1")), "## Subagents\n\n"+guide) {
		t.Error("lead run: no sub agent guide")
	}
	if !strings.Contains(string(SubagentAgentsMD("", explorerSpec(), nil, "T-1")), "## Subagents\n\n"+guide) {
		t.Error("delegated run: no sub agent guide")
	}
	if strings.Contains(string(AgentsMD("", explorerSpec(agentdef.OptionSubagents, "false"), nil, "T-1")), "run_subagent") {
		t.Error("subagents: false still mentions them")
	}
	// Codex now gets the same Vesper MCP run_subagent/run_subagents guide as Claude and Antigravity.
	codex := explorerSpec()
	codex.Harness = agentdef.HarnessCodex
	if md := string(AgentsMD("", codex, nil, "T-1")); !strings.Contains(md, "run_subagent") || !strings.Contains(md, "run_subagents") {
		t.Error("codex run missing run_subagent/run_subagents guide")
	}
	// A chat encourages its own sub agents instead of forbidding delegation;
	// a chat without them still says not to delegate.
	for _, h := range []string{agentdef.HarnessClaudeCode, agentdef.HarnessCodex, agentdef.HarnessAntigravity} {
		chat := explorerSpec("readonly", "true")
		chat.Harness = h
		md := string(ChatAgentsMD(chat, nil, "", "", nil))
		if !strings.Contains(md, "## Subagents\n\n"+agentdef.SubagentGuide(chat)) || strings.Contains(md, "Do not delegate work") || strings.Contains(md, "share your checkout") {
			t.Errorf("%s read-only chat:\n%s", h, md)
		}
	}
	off := explorerSpec("readonly", "true", agentdef.OptionSubagents, "false")
	if md := string(ChatAgentsMD(off, nil, "", "", nil)); !strings.Contains(md, "Do not delegate work") || strings.Contains(md, "run_subagent") {
		t.Errorf("subagents off chat:\n%s", md)
	}
}

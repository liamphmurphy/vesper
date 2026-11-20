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

func claudeRoster(t *testing.T, inv Invocation) map[string]struct {
	Description, Prompt, Model string
	Tools                      []string
} {
	t.Helper()
	var agents map[string]struct {
		Description, Prompt, Model string
		Tools                      []string
	}
	if err := json.Unmarshal(inv.Files[claudeAgentsFile], &agents); err != nil {
		t.Fatalf("agents file %q: %v", inv.Files[claudeAgentsFile], err)
	}
	return agents
}

func TestClaudeSubagentsInvocation(t *testing.T) {
	web := explorerSpec()
	web.Scopes = append(web.Scopes, agentdef.ResolvedScope{Scope: "web:read", Mode: agentdef.Allowed})
	inv, err := ClaudeCode{}.Invocation(ws, Turn{Spec: web, Prompt: "go"})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(strings.Split(flag(inv.Argv, "--allowedTools"), ","), "Agent") || flag(inv.Argv, "--agents") != claudeAgentsFile {
		t.Fatalf("argv %v", inv.Argv)
	}
	// In the background the lead would end its turn before a sub agent reports.
	if inv.Env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] != "1" {
		t.Errorf("sub agents run in the background: env %v", inv.Env)
	}
	agents := claudeRoster(t, inv)
	ex, ok := agents[agentdef.ExplorerAgent]
	if len(agents) != 2 || !ok || ex.Model != "claude-haiku-5-5" || !slices.Equal(ex.Tools, []string{"Read", "Grep", "Glob"}) || ex.Description == "" || ex.Prompt == "" {
		t.Fatalf("agents file %s", inv.Files[claudeAgentsFile])
	}
	// The helper has the lead's model and its file, shell and web tools, but
	// never Vesper's MCP tools or another Agent.
	h := agents[agentdef.HelperAgent]
	if h.Model != "inherit" || h.Description != agentdef.HelperDescription || h.Prompt != agentdef.HelperPrompt ||
		!slices.Equal(h.Tools, []string{"Read", "Grep", "Glob", "Edit", "Write", "Bash", "WebSearch", "WebFetch"}) {
		t.Fatalf("helper %+v", h)
	}
	// The explorer's model is configurable.
	inv, _ = ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec(agentdef.OptionExplorerModel, "sonnet-5.5"), Prompt: "go"})
	if !strings.Contains(string(inv.Files[claudeAgentsFile]), `"claude-sonnet-5-5"`) {
		t.Fatalf("agents file %s", inv.Files[claudeAgentsFile])
	}
	// explorer: "false" leaves the helper.
	inv, _ = ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec(agentdef.OptionExplorer, "false"), Prompt: "go"})
	if agents := claudeRoster(t, inv); len(agents) != 1 || agents[agentdef.HelperAgent].Prompt == "" {
		t.Fatalf("agents file %s", inv.Files[claudeAgentsFile])
	}
}

// A read-only chat or planning run gets read-only sub agents: Agent comes off
// the deny list, and the helper gets none of the denied tools.
func TestClaudeReadonlySubagents(t *testing.T) {
	inv, err := ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec("readonly", "true", agentdef.OptionWebSearch, "true"), Prompt: "go"})
	if err != nil {
		t.Fatal(err)
	}
	allow, deny := strings.Split(flag(inv.Argv, "--allowedTools"), ","), strings.Split(flag(inv.Argv, "--disallowedTools"), ",")
	if !slices.Contains(allow, "Agent") || slices.Contains(deny, "Agent") {
		t.Fatalf("allow %v deny %v", allow, deny)
	}
	if h := claudeRoster(t, inv)[agentdef.HelperAgent]; !slices.Equal(h.Tools, []string{"Read", "Grep", "Glob", "WebSearch", "WebFetch"}) {
		t.Fatalf("read-only helper tools %v", h.Tools)
	}
}

func TestClaudeWithoutSubagents(t *testing.T) {
	// subagents: "false" gives the invocation a run had before they existed.
	base, _ := ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec(agentdef.OptionSubagents, "false"), Prompt: "go"})
	codex := explorerSpec()
	codex.Harness, codex.Model = agentdef.HarnessCodex, "gpt-5-codex"
	codexOff := spec("repo:write", "allowed", "tests:run", "allowed")
	codexOff.Harness, codexOff.Model = agentdef.HarnessCodex, "gpt-5-codex"
	for name, c := range map[string]struct {
		h    Harness
		turn Turn
	}{
		"option off": {ClaudeCode{}, Turn{Spec: explorerSpec(agentdef.OptionSubagents, "false"), Prompt: "go"}},
		"no tools":   {ClaudeCode{}, Turn{Spec: explorerSpec(agentdef.OptionNoTools, "true"), Prompt: "go"}},
		"aside":      {ClaudeCode{}, Turn{Spec: explorerSpec(agentdef.OptionAside, "true"), Prompt: "go"}},
		"codex":      {Codex{}, Turn{Spec: codex, Prompt: "go"}},
	} {
		inv, err := c.h.Invocation(ws, c.turn)
		if err != nil {
			t.Fatal(err)
		}
		if slices.Contains(inv.Argv, "--agents") || inv.Files[claudeAgentsFile] != nil || slices.Contains(strings.Split(flag(inv.Argv, "--allowedTools"), ","), "Agent") || inv.Env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] != "" {
			t.Errorf("%s: sub agents present: %v", name, inv.Argv)
		}
		if name == "option off" && !slices.Equal(inv.Argv, base.Argv) {
			t.Errorf("%s: argv changed", name)
		}
		if name == "codex" {
			off, _ := Codex{}.Invocation(ws, Turn{Spec: codexOff, Prompt: "go"})
			if !slices.Equal(inv.Argv, off.Argv) {
				t.Errorf("codex argv changed by the options")
			}
		}
	}
}

// agy gets the same roster as custom agent files, kept out of git;
// TestAgyProbe/explorer and TestAgyProbe/helper run them against the real agy.
func TestAntigravitySubagentsInvocation(t *testing.T) {
	agy := func(opts ...string) agentdef.Resolved {
		s := explorerSpec(opts...)
		s.Harness, s.Model = agentdef.HarnessAntigravity, "gemini-3.8-flash"
		return s
	}
	inv, err := Antigravity{}.Invocation(ws, Turn{Spec: agy(), Prompt: "go"})
	if err != nil {
		t.Fatal(err)
	}
	md := string(inv.Files[agyExplorerPath])
	for _, want := range []string{"name: explorer\n", "subagent: true\n", "mainAgent: false\n", "inheritMcp: false\n", "model: flash\n", "tools: [read_file]\n", agentdef.ExplorerDescription, agentdef.ExplorerPrompt} {
		if !strings.Contains(md, want) {
			t.Errorf("explorer agent missing %q:\n%s", want, md)
		}
	}
	helper := string(inv.Files[agyHelperPath])
	for _, want := range []string{"name: helper\n", "subagent: true\n", "mainAgent: false\n", "inheritMcp: false\n", "tools: [read_file, write_file, edit_file, run_command]\n", agentdef.HelperPrompt} {
		if !strings.Contains(helper, want) {
			t.Errorf("helper agent missing %q:\n%s", want, helper)
		}
	}
	if strings.Contains(helper, "model:") {
		t.Errorf("the helper runs on the lead's model:\n%s", helper)
	}
	for _, path := range []string{agyExplorerPath, agyHelperPath} {
		if !strings.Contains(string(inv.Files[SkillsExcludeFile]), "/"+path) {
			t.Errorf("%s isn't excluded from git: %q", path, inv.Files[SkillsExcludeFile])
		}
	}
	inv, _ = Antigravity{}.Invocation(ws, Turn{Spec: agy("readonly", "true"), Prompt: "go"})
	if h := string(inv.Files[agyHelperPath]); !strings.Contains(h, "tools: [read_file]\n") {
		t.Errorf("read-only helper:\n%s", h)
	}
	inv, _ = Antigravity{}.Invocation(ws, Turn{Spec: agy(agentdef.OptionExplorer, "false"), Prompt: "go"})
	if inv.Files[agyExplorerPath] != nil || inv.Files[agyHelperPath] == nil {
		t.Error("explorer: false must drop only the explorer")
	}
	inv, _ = Antigravity{}.Invocation(ws, Turn{Spec: agy(agentdef.OptionSubagents, "false"), Prompt: "go"})
	if inv.Files[agyExplorerPath] != nil || inv.Files[agyHelperPath] != nil || strings.Contains(string(inv.Files[SkillsExcludeFile]), ".agents/agents/") {
		t.Error("subagents: false must drop both")
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
	if !strings.Contains(string(AgentsMD("", explorerSpec(), nil, "T-1")), guide) {
		t.Error("lead run: no sub agent guide")
	}
	if !strings.Contains(string(SubagentAgentsMD("", explorerSpec(), nil, "T-1")), guide) {
		t.Error("delegated run: no sub agent guide")
	}
	if strings.Contains(string(AgentsMD("", explorerSpec(agentdef.OptionSubagents, "false"), nil, "T-1")), "Agent tool") {
		t.Error("subagents: false still mentions them")
	}
	codex := explorerSpec()
	codex.Harness = agentdef.HarnessCodex
	if strings.Contains(string(AgentsMD("", codex, nil, "T-1")), "Agent tool") {
		t.Error("codex run mentions sub agents")
	}
	// A chat encourages its own sub agents instead of forbidding delegation;
	// a chat without them still says not to delegate.
	chat := explorerSpec("readonly", "true")
	md := string(ChatAgentsMD(chat, nil, "", "", nil))
	if !strings.Contains(md, agentdef.SubagentGuide(chat)) || strings.Contains(md, "Do not delegate work") || strings.Contains(md, "share your checkout") {
		t.Errorf("read-only chat:\n%s", md)
	}
	codex.HarnessOptions["readonly"] = "true"
	if md := string(ChatAgentsMD(codex, nil, "", "", nil)); !strings.Contains(md, "Do not delegate work") || strings.Contains(md, "Agent tool") {
		t.Errorf("codex chat:\n%s", md)
	}
}

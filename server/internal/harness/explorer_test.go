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

func TestClaudeExplorerInvocation(t *testing.T) {
	inv, err := ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec(), Prompt: "go", Lead: true})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.Contains(strings.Split(flag(inv.Argv, "--allowedTools"), ","), "Agent") || flag(inv.Argv, "--agents") != claudeAgentsFile {
		t.Fatalf("argv %v", inv.Argv)
	}
	var agents map[string]struct {
		Description, Prompt, Model string
		Tools                      []string
	}
	if err := json.Unmarshal(inv.Files[claudeAgentsFile], &agents); err != nil {
		t.Fatal(err)
	}
	ex, ok := agents["explorer"]
	if len(agents) != 1 || !ok || ex.Model != "claude-haiku-5-5" || !slices.Equal(ex.Tools, []string{"Read", "Grep", "Glob"}) || ex.Description == "" || ex.Prompt == "" {
		t.Fatalf("agents file %s", inv.Files[claudeAgentsFile])
	}
	// The model is configurable.
	inv, _ = ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec(agentdef.OptionExplorerModel, "sonnet-5.5"), Prompt: "go", Lead: true})
	if !strings.Contains(string(inv.Files[claudeAgentsFile]), `"claude-sonnet-5-5"`) {
		t.Fatalf("agents file %s", inv.Files[claudeAgentsFile])
	}
}

func TestClaudeExplorerOnlyForLeads(t *testing.T) {
	// The explorer is on by default; explorer: "false" gives the invocation
	// a run had before it existed.
	base, _ := ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec(agentdef.OptionExplorer, "false"), Prompt: "go", Lead: true})
	codex := explorerSpec()
	codex.Harness, codex.Model = agentdef.HarnessCodex, "gpt-5-codex"
	codexOff := spec("repo:write", "allowed", "tests:run", "allowed")
	codexOff.Harness, codexOff.Model = agentdef.HarnessCodex, "gpt-5-codex"
	for name, c := range map[string]struct {
		h    Harness
		turn Turn
		want Invocation
	}{
		"option off":             {ClaudeCode{}, Turn{Spec: explorerSpec(agentdef.OptionExplorer, "false"), Prompt: "go", Lead: true}, base},
		"option true, delegated": {ClaudeCode{}, Turn{Spec: explorerSpec(agentdef.OptionExplorer, "true"), Prompt: "go"}, base},
		"delegated":              {ClaudeCode{}, Turn{Spec: explorerSpec(), Prompt: "go"}, base},
		"readonly":               {ClaudeCode{}, Turn{Spec: explorerSpec("readonly", "true"), Prompt: "go", Lead: true}, Invocation{}},
		"no tools":               {ClaudeCode{}, Turn{Spec: explorerSpec(agentdef.OptionNoTools, "true"), Prompt: "go", Lead: true}, Invocation{}},
		"codex":                  {Codex{}, Turn{Spec: codex, Prompt: "go", Lead: true}, Invocation{}},
	} {
		inv, err := c.h.Invocation(ws, c.turn)
		if err != nil {
			t.Fatal(err)
		}
		if slices.Contains(inv.Argv, "--agents") || inv.Files[claudeAgentsFile] != nil || slices.Contains(strings.Split(flag(inv.Argv, "--allowedTools"), ","), "Agent") {
			t.Errorf("%s: explorer present: %v", name, inv.Argv)
		}
		if c.want.Argv != nil && !slices.Equal(inv.Argv, c.want.Argv) {
			t.Errorf("%s: argv changed:\n got %v\nwant %v", name, inv.Argv, c.want.Argv)
		}
		if name == "codex" {
			off, _ := Codex{}.Invocation(ws, Turn{Spec: codexOff, Prompt: "go", Lead: true})
			if !slices.Equal(inv.Argv, off.Argv) {
				t.Errorf("codex argv changed by the option")
			}
		}
	}
	// readonly and no_tools: same invocation as without the option.
	for _, opt := range []string{"readonly", agentdef.OptionNoTools} {
		off := spec("repo:write", "allowed", "tests:run", "allowed")
		off.HarnessOptions[opt] = "true"
		want, _ := ClaudeCode{}.Invocation(ws, Turn{Spec: off, Prompt: "go", Lead: true})
		got, _ := ClaudeCode{}.Invocation(ws, Turn{Spec: explorerSpec(opt, "true"), Prompt: "go", Lead: true})
		if !slices.Equal(got.Argv, want.Argv) {
			t.Errorf("%s: argv changed by the option", opt)
		}
	}
}

// agy gets the same explorer as a custom agent file, for leads only, kept out
// of git; TestAgyProbe/explorer runs it against the real agy.
func TestAntigravityExplorerInvocation(t *testing.T) {
	agy := func(opts ...string) agentdef.Resolved {
		s := explorerSpec(opts...)
		s.Harness, s.Model = agentdef.HarnessAntigravity, "gemini-3.8-flash"
		return s
	}
	inv, err := Antigravity{}.Invocation(ws, Turn{Spec: agy(), Prompt: "go", Lead: true})
	if err != nil {
		t.Fatal(err)
	}
	md := string(inv.Files[agyExplorerPath])
	for _, want := range []string{"name: explorer\n", "subagent: true\n", "mainAgent: false\n", "inheritMcp: false\n", "model: flash\n", "tools: [read_file]\n", agentdef.ExplorerDescription, agentdef.ExplorerPrompt} {
		if !strings.Contains(md, want) {
			t.Errorf("explorer agent missing %q:\n%s", want, md)
		}
	}
	if !strings.Contains(string(inv.Files[SkillsExcludeFile]), "/"+agyExplorerPath) {
		t.Errorf("explorer agent isn't excluded from git: %q", inv.Files[SkillsExcludeFile])
	}
	for name, turn := range map[string]Turn{
		"delegated":  {Spec: agy(), Prompt: "go"},
		"option off": {Spec: agy(agentdef.OptionExplorer, "false"), Prompt: "go", Lead: true},
		"readonly":   {Spec: agy("readonly", "true"), Prompt: "go", Lead: true},
	} {
		inv, err := Antigravity{}.Invocation(ws, turn)
		if err != nil {
			t.Fatal(err)
		}
		if inv.Files[agyExplorerPath] != nil || strings.Contains(string(inv.Files[SkillsExcludeFile]), agyExplorerPath) {
			t.Errorf("%s: explorer present", name)
		}
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

func TestExplorerInAgentsMD(t *testing.T) {
	const line = "Use the explorer sub agent"
	if !strings.Contains(string(AgentsMD("", spec(), nil, "T-1")), line) {
		t.Error("lead by default: no explorer line")
	}
	if strings.Contains(string(AgentsMD("", explorerSpec(agentdef.OptionExplorer, "false"), nil, "T-1")), line) {
		t.Error("lead with explorer: false mentions the explorer")
	}
	if strings.Contains(string(SubagentAgentsMD("", explorerSpec(), nil, "T-1")), line) {
		t.Error("delegated run mentions the explorer")
	}
	codex := explorerSpec()
	codex.Harness = agentdef.HarnessCodex
	if strings.Contains(string(AgentsMD("", codex, nil, "T-1")), line) {
		t.Error("codex lead mentions the explorer")
	}
}

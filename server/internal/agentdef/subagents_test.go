package agentdef

import (
	"slices"
	"strings"
	"testing"
)

func TestSubagentTypes(t *testing.T) {
	both := []string{ExplorerAgent, HelperAgent}
	for _, c := range []struct {
		name    string
		harness string
		opts    map[string]string
		want    []string
	}{
		{"default on for Claude Code", HarnessClaudeCode, nil, both},
		{"readonly chat or planning run", HarnessClaudeCode, map[string]string{"readonly": "true"}, both},
		{"explorer off keeps the helper", HarnessClaudeCode, map[string]string{OptionExplorer: "false"}, []string{HelperAgent}},
		{"sub agents off", HarnessClaudeCode, map[string]string{OptionSubagents: "false"}, nil},
		{"sub agents off beats explorer on", HarnessClaudeCode, map[string]string{OptionSubagents: "false", OptionExplorer: "true"}, nil},
		{"no tools", HarnessClaudeCode, map[string]string{OptionNoTools: "true"}, nil},
		{"aside", HarnessClaudeCode, map[string]string{OptionAside: "true"}, nil},
		{"antigravity", HarnessAntigravity, nil, both},
		{"antigravity explorer off", HarnessAntigravity, map[string]string{OptionExplorer: "false"}, []string{HelperAgent}},
		{"codex", HarnessCodex, nil, both},
		{"codex with options on", HarnessCodex, map[string]string{OptionSubagents: "true", OptionExplorer: "true"}, both},
		{"codex explorer off", HarnessCodex, map[string]string{OptionExplorer: "false"}, []string{HelperAgent}},
		{"no MCP", HarnessClaudeCode, map[string]string{OptionNoMCP: "true"}, nil},
	} {
		spec := Resolved{Harness: c.harness, HarnessOptions: c.opts}
		if got := SubagentTypes(spec); !slices.Equal(got, c.want) {
			t.Errorf("%s: SubagentTypes = %v, want %v", c.name, got, c.want)
		}
		if got := ExplorerOn(spec); got != slices.Contains(c.want, ExplorerAgent) {
			t.Errorf("%s: ExplorerOn = %v", c.name, got)
		}
		guide := SubagentGuide(spec)
		if (guide != "") != (c.want != nil) || strings.Contains(guide, "`"+ExplorerAgent+"`") != slices.Contains(c.want, ExplorerAgent) {
			t.Errorf("%s: SubagentGuide = %q", c.name, guide)
		}
		if c.want != nil {
			for _, token := range []string{"`run_subagents`", "`tasks`", "`tier`", "`fast`", "`standard`", "`deep`", "`reason`"} {
				if !strings.Contains(guide, token) {
					t.Errorf("%s: SubagentGuide missing %q: %q", c.name, token, guide)
				}
			}
			wantAgy := c.harness == HarnessAntigravity
			for _, token := range []string{"mcp_lazyagents_run_subagent", "mcp_lazyagents_run_subagents", "invoke_subagent", "run_workflow", "schedule"} {
				if strings.Contains(guide, token) != wantAgy {
					t.Errorf("%s: SubagentGuide contains %q = %v, want %v", c.name, token, !wantAgy, wantAgy)
				}
			}
		}
	}
}

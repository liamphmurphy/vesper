package agentdef

import "testing"

func TestExplorerOn(t *testing.T) {
	for _, c := range []struct {
		name    string
		harness string
		opts    map[string]string
		lead    bool
		want    bool
	}{
		{"default on for a Claude Code lead", HarnessClaudeCode, nil, true, true},
		{"explicit true", HarnessClaudeCode, map[string]string{OptionExplorer: "true"}, true, true},
		{"explicit false", HarnessClaudeCode, map[string]string{OptionExplorer: "false"}, true, false},
		{"sub agent or chat run", HarnessClaudeCode, nil, false, false},
		{"sub agent with option true", HarnessClaudeCode, map[string]string{OptionExplorer: "true"}, false, false},
		{"readonly", HarnessClaudeCode, map[string]string{"readonly": "true"}, true, false},
		{"no tools", HarnessClaudeCode, map[string]string{OptionNoTools: "true"}, true, false},
		{"codex", HarnessCodex, nil, true, false},
		{"codex with option true", HarnessCodex, map[string]string{OptionExplorer: "true"}, true, false},
		{"antigravity lead", HarnessAntigravity, nil, true, true},
		{"antigravity sub agent or chat run", HarnessAntigravity, nil, false, false},
		{"antigravity explicit false", HarnessAntigravity, map[string]string{OptionExplorer: "false"}, true, false},
	} {
		spec := Resolved{Harness: c.harness, HarnessOptions: c.opts}
		if got := ExplorerOn(spec, c.lead); got != c.want {
			t.Errorf("%s: ExplorerOn = %v, want %v", c.name, got, c.want)
		}
	}
}

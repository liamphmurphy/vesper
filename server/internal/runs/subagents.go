package runs

import (
	"fmt"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// SubagentSpec builds the isolated harness spec for an in-turn Vesper MCP
// subagent (`explorer` or `helper`). Every subagent runs with OptionNoMCP and
// OptionSubagents="false" so state and orchestration stay with the parent turn.
func SubagentSpec(parent agentdef.Resolved, agentType string) (agentdef.Resolved, error) {
	opts := map[string]string{
		agentdef.OptionNoMCP:     "true",
		agentdef.OptionSubagents: "false",
	}
	switch agentType {
	case agentdef.ExplorerAgent:
		opts["readonly"] = "true"
		opts["sandbox"] = "read-only"
		model := parent.HarnessOptions[agentdef.OptionExplorerModel]
		if model == "" {
			switch parent.Harness {
			case agentdef.HarnessCodex:
				model = "gpt-5-mini"
			case agentdef.HarnessAntigravity:
				model = "gemini-3.8-flash"
			default:
				model = agentdef.DefaultExplorerModel
			}
		}
		return agentdef.Resolved{
			Harness: parent.Harness,
			Model:   model,
			Scopes: []agentdef.ResolvedScope{
				{Scope: "repo:read", Mode: parent.Mode("repo:read"), Source: agentdef.FromAgent},
			},
			HarnessOptions: opts,
		}, nil

	case agentdef.HelperAgent:
		for _, k := range []string{"readonly", "sandbox", "effort", "permission_mode", agentdef.OptionWebSearch} {
			if v := parent.HarnessOptions[k]; v != "" {
				opts[k] = v
			}
		}
		var scopes []agentdef.ResolvedScope
		for _, sc := range []string{"repo:read", "repo:write", "tests:run", "web:read"} {
			if m := parent.Mode(sc); m != agentdef.Denied {
				scopes = append(scopes, agentdef.ResolvedScope{Scope: sc, Mode: m, Source: agentdef.FromAgent})
			}
		}
		return agentdef.Resolved{
			Harness:        parent.Harness,
			Model:          parent.Model,
			Scopes:         scopes,
			HarnessOptions: opts,
		}, nil

	default:
		return agentdef.Resolved{}, fmt.Errorf("unknown subagent type %q", agentType)
	}
}

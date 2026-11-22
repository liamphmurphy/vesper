package runs

import (
	"fmt"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

const (
	DefaultMaxConcurrentSubagents = 3
	MinConcurrentSubagents        = 1
	MaxConcurrentSubagentsCap     = 16
)

// ClampConcurrentSubagents normalizes a stored limit into [MinConcurrentSubagents, MaxConcurrentSubagentsCap],
// defaulting non-positive values to DefaultMaxConcurrentSubagents.
func ClampConcurrentSubagents(n int) int {
	if n < MinConcurrentSubagents {
		return DefaultMaxConcurrentSubagents
	}
	if n > MaxConcurrentSubagentsCap {
		return MaxConcurrentSubagentsCap
	}
	return n
}

// SubagentSpec builds the isolated harness spec for an in-turn Vesper MCP
// subagent (`explorer` or `helper`). Every subagent runs with OptionNoMCP and
// OptionSubagents="false" so state and orchestration stay with the parent turn.
func SubagentSpec(parent agentdef.Resolved, agentType string) (agentdef.Resolved, error) {
	return SubagentSpecForJob(parent, agentType, "", "")
}

// SubagentSpecForJob builds the isolated harness spec for an in-turn Vesper MCP
// subagent job, applying resolved model and effort overrides when non-empty.
func SubagentSpecForJob(parent agentdef.Resolved, agentType, model, effort string) (agentdef.Resolved, error) {
	opts := map[string]string{
		agentdef.OptionNoMCP:     "true",
		agentdef.OptionSubagents: "false",
	}
	var spec agentdef.Resolved
	switch agentType {
	case agentdef.ExplorerAgent:
		opts["readonly"] = "true"
		opts["sandbox"] = "read-only"
		exModel := parent.HarnessOptions[agentdef.OptionExplorerModel]
		if exModel == "" {
			switch parent.Harness {
			case agentdef.HarnessCodex:
				exModel = "gpt-5-mini"
			case agentdef.HarnessAntigravity:
				exModel = "gemini-3.8-flash"
			default:
				exModel = agentdef.DefaultExplorerModel
			}
		}
		spec = agentdef.Resolved{
			Harness: parent.Harness,
			Model:   exModel,
			Scopes: []agentdef.ResolvedScope{
				{Scope: "repo:read", Mode: parent.Mode("repo:read"), Source: agentdef.FromAgent},
			},
			HarnessOptions: opts,
		}

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
		spec = agentdef.Resolved{
			Harness:        parent.Harness,
			Model:          parent.Model,
			Scopes:         scopes,
			HarnessOptions: opts,
		}

	default:
		return agentdef.Resolved{}, fmt.Errorf("unknown subagent type %q", agentType)
	}

	if model != "" {
		spec.Model = model
		if effort != "" {
			spec.HarnessOptions["effort"] = effort
		} else {
			// Clear inherited parent effort when routing onto another model whose effort
			// support may differ (e.g. a haiku model without effort levels).
			delete(spec.HarnessOptions, "effort")
		}
	} else if effort != "" {
		spec.HarnessOptions["effort"] = effort
	}
	return spec, nil
}

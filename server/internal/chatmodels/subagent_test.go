package chatmodels

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

func TestResolveSubagentClaudeCode(t *testing.T) {
	allEfforts := agentdef.Efforts
	withFable := []Model{
		{ID: "default", Label: "Default (recommended)", Default: true, Efforts: allEfforts},
		{ID: "opus", Label: "Opus 5.5", Efforts: allEfforts},
		{ID: "fable", Label: "Fable 5.2", Efforts: allEfforts},
		{ID: "sonnet", Label: "Sonnet 5.5", Efforts: allEfforts},
		{ID: "haiku", Label: "Haiku 5.5"},
	}

	cases := []struct {
		name        string
		models      []Model
		parentModel string
		parentEff   string
		agentType   string
		reqTier     string
		want        SubagentModelResult
	}{
		// Fable parent can delegate fast, standard, and deep.
		{"fable explorer default", withFable, "fable", "xhigh", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "haiku", ""}},
		{"fable helper fast", withFable, "fable", "xhigh", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "haiku", ""}},
		{"fable helper default standard", withFable, "fable", "xhigh", agentdef.HelperAgent, "", SubagentModelResult{"standard", "sonnet", "medium"}},
		{"fable helper deep", withFable, "fable", "xhigh", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "fable", "high"}},

		// Opus/default with Fable present classify as standard and cannot escalate to Fable.
		{"opus helper deep capped at standard", withFable, "opus", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "opus", "medium"}},
		{"opus helper fast", withFable, "opus", "high", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "haiku", ""}},
		{"default helper deep capped at standard", withFable, "default", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "default", "medium"}},

		// Sonnet parent caps deep at standard.
		{"sonnet helper fast", withFable, "sonnet", "high", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "haiku", ""}},
		{"sonnet helper standard", withFable, "sonnet", "high", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "sonnet", "medium"}},
		{"sonnet helper deep capped", withFable, "sonnet", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "sonnet", "medium"}},

		// Haiku parent caps everything at fast.
		{"haiku helper standard capped", withFable, "haiku", "", agentdef.HelperAgent, "standard", SubagentModelResult{"fast", "haiku", ""}},
		{"haiku helper deep capped", withFable, "haiku", "", agentdef.HelperAgent, "deep", SubagentModelResult{"fast", "haiku", ""}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSubagentFromModels(agentdef.HarnessClaudeCode, tc.parentModel, tc.parentEff, tc.agentType, tc.reqTier, "", tc.models)
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}

	// API-key catalog without Fable treats claude-opus-4-6 as deep.
	apiModels := []Model{
		{ID: "claude-opus-4-6", Label: "Claude Opus 4.6", Efforts: allEfforts},
		{ID: "claude-sonnet-4-6", Label: "Claude Sonnet 4.6", Default: true, Efforts: allEfforts},
		{ID: "claude-haiku-4-5", Label: "Claude Haiku 4.5"},
	}
	for _, tc := range []struct {
		name, parentModel, reqTier string
		want                       SubagentModelResult
	}{
		{"api opus fast", "claude-opus-4-6", "fast", SubagentModelResult{"fast", "claude-haiku-4-5", ""}},
		{"api opus standard", "claude-opus-4-6", "standard", SubagentModelResult{"standard", "claude-sonnet-4-6", "medium"}},
		{"api opus deep", "claude-opus-4-6", "deep", SubagentModelResult{"deep", "claude-opus-4-6", "high"}},
		{"api sonnet deep capped", "claude-sonnet-4-6", "deep", SubagentModelResult{"standard", "claude-sonnet-4-6", "medium"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSubagentFromModels(agentdef.HarnessClaudeCode, tc.parentModel, "high", agentdef.HelperAgent, tc.reqTier, "", apiModels)
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestResolveSubagentCodex(t *testing.T) {
	allEfforts := []string{"low", "medium", "high", "xhigh"}
	twoTier := []Model{
		{ID: "gpt-6-codex", Label: "GPT-6 Codex", Default: true, Efforts: allEfforts},
		{ID: "gpt-6-codex-mini", Label: "GPT-6 Codex Mini", Efforts: []string{"medium", "high"}},
	}
	threeTier := append(slicesCloneModels(twoTier), Model{ID: "gpt-6-pro", Label: "GPT-6 Pro", Efforts: allEfforts})

	cases := []struct {
		name        string
		models      []Model
		parentModel string
		parentEff   string
		reqTier     string
		want        SubagentModelResult
	}{
		// 2-tier catalog: no deep model exists, so deep stays on codex and raises effort up to parent's effort.
		{"2tier codex xhigh fast clamps to mini lowest supported effort", twoTier, "gpt-6-codex", "xhigh", "fast", SubagentModelResult{"fast", "gpt-6-codex-mini", "medium"}},
		{"2tier codex xhigh standard", twoTier, "gpt-6-codex", "xhigh", "standard", SubagentModelResult{"standard", "gpt-6-codex", "medium"}},
		{"2tier codex xhigh deep raises effort", twoTier, "gpt-6-codex", "xhigh", "deep", SubagentModelResult{"standard", "gpt-6-codex", "high"}},
		{"2tier codex medium deep capped by parent effort", twoTier, "gpt-6-codex", "medium", "deep", SubagentModelResult{"standard", "gpt-6-codex", "medium"}},

		// 3-tier catalog: gpt-6-pro unlocks deep, while gpt-6-codex cannot escalate up to gpt-6-pro.
		{"3tier pro fast", threeTier, "gpt-6-pro", "xhigh", "fast", SubagentModelResult{"fast", "gpt-6-codex-mini", "medium"}},
		{"3tier pro standard", threeTier, "gpt-6-pro", "xhigh", "standard", SubagentModelResult{"standard", "gpt-6-codex", "medium"}},
		{"3tier pro deep", threeTier, "gpt-6-pro", "xhigh", "deep", SubagentModelResult{"deep", "gpt-6-pro", "high"}},
		{"3tier codex deep never escalates to pro", threeTier, "gpt-6-codex", "xhigh", "deep", SubagentModelResult{"standard", "gpt-6-codex", "medium"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSubagentFromModels(agentdef.HarnessCodex, tc.parentModel, tc.parentEff, agentdef.HelperAgent, tc.reqTier, "", tc.models)
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestResolveSubagentAntigravity(t *testing.T) {
	const agyListing = `
gemini-4-neon-low	Gemini 4 Neon (Low)
gemini-4-neon-medium	Gemini 4 Neon (Medium)
gemini-4-neon-high	Gemini 4 Neon (High)
gemini-4-neon-xhigh	Gemini 4 Neon (XHigh)
gemini-4-carbon-low	Gemini 4 Carbon (Low)
gemini-4-carbon-medium	Gemini 4 Carbon (Medium)
gemini-4-carbon-high	Gemini 4 Carbon (High)
gemini-4-argon-medium	Gemini 4 Argon (Medium)
gemini-4-hydrogen-high	Gemini 4 Hydrogen (High)
gemini-pro-orchestrator-neon	Orchestrator (Neon)
gemini-pro-orchestrator	Orchestrator (Carbon)
gemini-pro-orchestrator-argon	Orchestrator (Argon)
gemini-3.8-flash-low	Gemini 3.8 Flash (Low)
gemini-3.8-flash-medium	Gemini 3.8 Flash (Medium)
gemini-3.8-flash-high	Gemini 3.8 Flash (High)
claude-opus-5-5-low	Claude Opus 5.5 (Low)
claude-opus-5-5-medium	Claude Opus 5.5 (Medium)
claude-opus-5-5-high	Claude Opus 5.5 (High)
claude-sonnet-5-5-low	Claude Sonnet 5.5 (Low)
claude-sonnet-5-5-medium	Claude Sonnet 5.5 (Medium)
claude-sonnet-5-5-high	Claude Sonnet 5.5 (High)
gpt-oss-120b-medium	GPT-OSS 120B (Medium)
`
	models, err := ParseAgyModels(strings.NewReader(agyListing))
	if err != nil {
		t.Fatalf("ParseAgyModels: %v", err)
	}

	cases := []struct {
		name        string
		parentModel string
		parentEff   string
		agentType   string
		reqTier     string
		want        SubagentModelResult
	}{
		// Orchestrator (Neon) delegates to non-orchestrator Gemini models per tier.
		{"orch-neon explorer default", "gemini-pro-orchestrator-neon", "", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "gemini-3.8-flash", "low"}},
		{"orch-neon helper fast", "gemini-pro-orchestrator-neon", "", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gemini-3.8-flash", "low"}},
		{"orch-neon helper standard", "gemini-pro-orchestrator-neon", "", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gemini-4-carbon", "medium"}},
		{"orch-neon helper deep", "gemini-pro-orchestrator-neon", "", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "gemini-4-neon", "high"}},

		// Orchestrator (Carbon) is standard and never escalates to Neon.
		{"orch-carbon standard", "gemini-pro-orchestrator", "", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gemini-4-carbon", "medium"}},
		{"orch-carbon deep capped", "gemini-pro-orchestrator", "", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "gemini-4-carbon", "medium"}},

		// Non-orchestrator Gemini Neon parent.
		{"neon fast", "gemini-4-neon", "high", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gemini-3.8-flash", "low"}},
		{"neon standard", "gemini-4-neon", "high", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gemini-4-carbon", "medium"}},
		{"neon deep", "gemini-4-neon", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "gemini-4-neon", "high"}},

		// Cross-family within Antigravity: Claude Opus prefers Claude Sonnet at standard, Flash at fast.
		{"agy claude-opus fast", "claude-opus-5-5", "high", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gemini-3.8-flash", "low"}},
		{"agy claude-opus standard keeps claude family", "claude-opus-5-5", "high", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "claude-sonnet-5-5", "medium"}},
		{"agy claude-opus deep", "claude-opus-5-5", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "claude-opus-5-5", "high"}},

		// Standard and fast Antigravity parents cannot escalate upward.
		{"carbon deep capped", "gemini-4-carbon", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "gemini-4-carbon", "medium"}},
		{"flash standard capped", "gemini-3.8-flash", "high", agentdef.HelperAgent, "standard", SubagentModelResult{"fast", "gemini-3.8-flash", "low"}},
		{"flash deep capped", "gemini-3.8-flash", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"fast", "gemini-3.8-flash", "low"}},

		// Effort ceiling: low-effort Neon parent clamps child effort to low.
		{"neon low-effort caps deep child effort", "gemini-4-neon", "low", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "gemini-4-neon", "low"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSubagentFromModels(agentdef.HarnessAntigravity, tc.parentModel, tc.parentEff, tc.agentType, tc.reqTier, "", models)
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestResolveSubagentOverridesAndColdFallback(t *testing.T) {
	withFable := []Model{
		{ID: "fable", Label: "Fable 5.2", Efforts: agentdef.Efforts},
		{ID: "sonnet", Label: "Sonnet 5.5", Default: true, Efforts: agentdef.Efforts},
		{ID: "haiku", Label: "Haiku 5.5"},
	}

	// ExplorerModelOverride applies when tier is omitted or fast; explicit standard overrides it.
	if got := ResolveSubagentFromModels(agentdef.HarnessClaudeCode, "fable", "high", agentdef.ExplorerAgent, "", "custom-fast", withFable); got != (SubagentModelResult{"fast", "custom-fast", ""}) {
		t.Fatalf("explorer override omitted tier = %+v", got)
	}
	if got := ResolveSubagentFromModels(agentdef.HarnessClaudeCode, "fable", "high", agentdef.ExplorerAgent, "fast", "custom-fast", withFable); got != (SubagentModelResult{"fast", "custom-fast", ""}) {
		t.Fatalf("explorer override fast tier = %+v", got)
	}
	if got := ResolveSubagentFromModels(agentdef.HarnessClaudeCode, "fable", "high", agentdef.ExplorerAgent, "standard", "custom-fast", withFable); got != (SubagentModelResult{"standard", "sonnet", "medium"}) {
		t.Fatalf("explorer explicit standard tier = %+v", got)
	}

	// Cold catalog fallback preserves static explorer defaults and parent model.
	for _, tc := range []struct {
		name, harness, parent, pEff, typ, tier string
		want                                   SubagentModelResult
	}{
		{"cold claude fast", agentdef.HarnessClaudeCode, "opus-5.5", "high", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", agentdef.DefaultExplorerModel, ""}},
		{"cold codex fast", agentdef.HarnessCodex, "gpt-5-codex", "xhigh", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "gpt-5-mini", ""}},
		{"cold agy fast", agentdef.HarnessAntigravity, "gemini-4-neon", "high", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "gemini-3.8-flash", ""}},
		{"cold helper keeps parent", agentdef.HarnessCodex, "gpt-5-codex", "xhigh", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gpt-5-codex", "medium"}},
		{"cold fast parent capped", agentdef.HarnessCodex, "gpt-5-mini", "", agentdef.HelperAgent, "deep", SubagentModelResult{"fast", "gpt-5-mini", ""}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSubagentFromModels(tc.harness, tc.parent, tc.pEff, tc.typ, tc.tier, "", nil)
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestModelsForHarnessCaching(t *testing.T) {
	ws := uuid.New()
	calls := 0
	cat := Catalog{
		Discover: func(_ context.Context, h, _ string) ([]Model, error) {
			calls++
			if h != agentdef.HarnessCodex {
				t.Fatalf("unexpected harness discovery %q (want single harness only)", h)
			}
			return []Model{{ID: "gpt-6-codex", Default: true, Efforts: []string{"low", "medium", "high"}}}, nil
		},
	}

	first := cat.ModelsForHarness(context.Background(), nil, ws, agentdef.HarnessCodex)
	if calls != 1 || len(first) != 1 || first[0].ID != "gpt-6-codex" {
		t.Fatalf("first ModelsForHarness: calls=%d models=%+v", calls, first)
	}
	second := cat.ModelsForHarness(context.Background(), nil, ws, agentdef.HarnessCodex)
	if calls != 1 || len(second) != 1 || second[0].ID != "gpt-6-codex" {
		t.Fatalf("second ModelsForHarness (should hit cache): calls=%d models=%+v", calls, second)
	}

	// Mutating returned slice must not corrupt cache.
	first[0].ID = "corrupted"
	third := cat.ModelsForHarness(context.Background(), nil, ws, agentdef.HarnessCodex)
	if third[0].ID != "gpt-6-codex" {
		t.Fatalf("cache corrupted by caller mutation: %+v", third)
	}
}

func slicesCloneModels(in []Model) []Model {
	out := make([]Model, len(in))
	copy(out, in)
	return out
}

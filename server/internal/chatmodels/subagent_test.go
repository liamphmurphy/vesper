package chatmodels

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

func TestResolveSubagentEffortOnlyDefault(t *testing.T) {
	allEfforts := agentdef.Efforts
	claudeModels := []Model{
		{ID: "default", Label: "Default (recommended)", Default: true, Efforts: allEfforts},
		{ID: "opus", Label: "Opus 5.5", Efforts: allEfforts},
		{ID: "fable", Label: "Fable 5.2", Efforts: allEfforts},
		{ID: "sonnet", Label: "Sonnet 5.5", Efforts: allEfforts},
		{ID: "haiku", Label: "Haiku 5.5"},
	}
	codexModels := []Model{
		{ID: "gpt-6-codex", Label: "GPT-6 Codex", Default: true, Efforts: []string{"low", "medium", "high", "xhigh"}},
		{ID: "gpt-6-codex-mini", Label: "GPT-6 Codex Mini", Efforts: []string{"medium", "high"}},
	}
	agyModels := []Model{
		{ID: "gemini-4-carbon", Label: "Gemini 4 Carbon", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-4-neon", Label: "Gemini 4 Neon", Efforts: []string{"low", "medium", "high", "xhigh"}},
		{ID: "gemini-4-hydrogen", Label: "Gemini 4 Hydrogen", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-5-xenon", Label: "Gemini 5 Xenon", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-pro-orchestrator", Label: "Orchestrator (Carbon)"},
		{ID: "gemini-pro-orchestrator-neon", Label: "Orchestrator (Neon)"},
		{ID: "gemini-pro-orchestrator-xenon", Label: "Orchestrator (Xenon)"},
	}

	cases := []struct {
		name        string
		harness     string
		models      []Model
		parentModel string
		parentEff   string
		agentType   string
		reqTier     string
		want        SubagentModelResult
	}{
		// By default (zero custom rule), subagents keep the parent model and scale effort.
		{"claude fable keeps model and scales effort", agentdef.HarnessClaudeCode, claudeModels, "fable", "xhigh", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "fable", "low"}},
		{"claude fable standard", agentdef.HarnessClaudeCode, claudeModels, "fable", "xhigh", agentdef.HelperAgent, "", SubagentModelResult{"standard", "fable", "medium"}},
		{"claude fable deep", agentdef.HarnessClaudeCode, claudeModels, "fable", "xhigh", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "fable", "high"}},
		{"claude explorer stays on parent model with low effort", agentdef.HarnessClaudeCode, claudeModels, "sonnet", "high", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "sonnet", "low"}},
		{"claude effort ceiling medium caps deep", agentdef.HarnessClaudeCode, claudeModels, "sonnet", "medium", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "sonnet", "medium"}},
		{"claude effort ceiling low caps standard and deep", agentdef.HarnessClaudeCode, claudeModels, "sonnet", "low", agentdef.HelperAgent, "deep", SubagentModelResult{"fast", "sonnet", "low"}},
		{"claude effort-less model stays effort-less", agentdef.HarnessClaudeCode, claudeModels, "haiku", "", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "haiku", ""}},

		// Codex effort-only scaling and lowest-effort clamping.
		{"codex parent scales effort without switching model", agentdef.HarnessCodex, codexModels, "gpt-6-codex", "xhigh", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gpt-6-codex", "low"}},
		{"codex mini clamps fast low to lowest supported medium", agentdef.HarnessCodex, codexModels, "gpt-6-codex-mini", "high", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gpt-6-codex-mini", "medium"}},

		// Antigravity dynamic de-orchestration works for existing and new codenames alike without guessing tiers.
		{"agy neon scales effort without switching models", agentdef.HarnessAntigravity, agyModels, "gemini-4-neon", "xhigh", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gemini-4-neon", "low"}},
		{"agy orchestrator carbon de-orchestrates to carbon", agentdef.HarnessAntigravity, agyModels, "gemini-pro-orchestrator", "", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gemini-4-carbon", "medium"}},
		{"agy orchestrator neon de-orchestrates to neon", agentdef.HarnessAntigravity, agyModels, "gemini-pro-orchestrator-neon", "", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "gemini-4-neon", "high"}},
		{"agy future orchestrator xenon de-orchestrates dynamically", agentdef.HarnessAntigravity, agyModels, "gemini-pro-orchestrator-xenon", "", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "gemini-5-xenon", "low"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSubagentFromModels(tc.harness, tc.parentModel, tc.parentEff, tc.agentType, tc.reqTier, "", tc.models, SubagentTierModels{})
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestResolveSubagentCustomLaddersAndFallbacks(t *testing.T) {
	agyModels := []Model{
		{ID: "gemini-4-carbon", Label: "Gemini 4 Carbon", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-4-neon", Label: "Gemini 4 Neon", Efforts: []string{"low", "medium", "high", "xhigh"}},
		{ID: "gemini-4-hydrogen", Label: "Gemini 4 Hydrogen", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-5-krypton", Label: "Gemini 5 Krypton", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-pro-orchestrator", Label: "Orchestrator (Carbon)"},
		{ID: "gemini-pro-orchestrator-neon", Label: "Orchestrator (Neon)"},
		{ID: "claude-opus-5-5", Label: "Claude Opus 5.5", Efforts: []string{"low", "medium", "high"}},
	}
	geminiLadder := SubagentTierModels{
		Deep:     "gemini-4-carbon",
		Standard: "gemini-4-neon",
		Fast:     "gemini-4-hydrogen",
	}

	cases := []struct {
		name        string
		models      []Model
		rule        SubagentTierModels
		parentModel string
		parentEff   string
		agentType   string
		reqTier     string
		want        SubagentModelResult
	}{
		// Explicit Carbon -> Neon -> Hydrogen ladder for Carbon and Orchestrator (Carbon).
		{"carbon explorer -> hydrogen", agyModels, geminiLadder, "gemini-4-carbon", "high", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "gemini-4-hydrogen", "low"}},
		{"carbon helper default -> neon", agyModels, geminiLadder, "gemini-4-carbon", "high", agentdef.HelperAgent, "", SubagentModelResult{"standard", "gemini-4-neon", "medium"}},
		{"carbon helper deep -> carbon", agyModels, geminiLadder, "gemini-4-carbon", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "gemini-4-carbon", "high"}},
		{"orchestrator carbon -> ladder", agyModels, geminiLadder, "gemini-pro-orchestrator", "", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gemini-4-neon", "medium"}},
		{"carbon effort suffix still matches ladder", agyModels, geminiLadder, "gemini-4-carbon-high", "", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gemini-4-hydrogen", "low"}},

		// Neon parent is standard on the ladder and cannot escalate up to Carbon.
		{"neon fast -> hydrogen", agyModels, geminiLadder, "gemini-4-neon", "xhigh", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gemini-4-hydrogen", "low"}},
		{"neon standard -> neon", agyModels, geminiLadder, "gemini-4-neon", "xhigh", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gemini-4-neon", "medium"}},
		{"neon deep capped at standard", agyModels, geminiLadder, "gemini-4-neon", "xhigh", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "gemini-4-neon", "medium"}},
		{"orchestrator neon deep capped at standard", agyModels, geminiLadder, "gemini-pro-orchestrator-neon", "", agentdef.HelperAgent, "deep", SubagentModelResult{"standard", "gemini-4-neon", "medium"}},

		// Hydrogen parent is fast on the ladder and caps everything at fast.
		{"hydrogen deep capped at fast", agyModels, geminiLadder, "gemini-4-hydrogen", "high", agentdef.HelperAgent, "deep", SubagentModelResult{"fast", "gemini-4-hydrogen", "low"}},

		// Unlisted parent (different vendor or brand-new unlisted model) falls back safely to effort-only on parent.
		{"unlisted claude-opus ignores gemini ladder", agyModels, geminiLadder, "claude-opus-5-5", "high", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "claude-opus-5-5", "low"}},
		{"unlisted future gemini-5-krypton stays effort-only", agyModels, geminiLadder, "gemini-5-krypton", "high", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "gemini-5-krypton", "medium"}},

		// Retired model configured on a tier falls back to parent model with scaled effort.
		{"stale fast model falls back safely to parent", agyModels, SubagentTierModels{Deep: "gemini-4-carbon", Standard: "gemini-4-neon", Fast: "gemini-3.8-flash"}, "gemini-4-carbon", "high", agentdef.HelperAgent, "fast", SubagentModelResult{"fast", "gemini-4-carbon", "low"}},

		// Fast-only partial rule lets any parent use the configured fast model and scales effort otherwise.
		{"fast-only rule applies across parents", agyModels, SubagentTierModels{Fast: "gemini-4-hydrogen"}, "claude-opus-5-5", "high", agentdef.ExplorerAgent, "", SubagentModelResult{"fast", "gemini-4-hydrogen", "low"}},
		{"fast-only rule keeps standard on parent", agyModels, SubagentTierModels{Fast: "gemini-4-hydrogen"}, "claude-opus-5-5", "high", agentdef.HelperAgent, "standard", SubagentModelResult{"standard", "claude-opus-5-5", "medium"}},

		// Effort ceiling on low-effort parent still clamps child effort.
		{"low effort parent caps child effort", agyModels, geminiLadder, "gemini-4-carbon", "low", agentdef.HelperAgent, "deep", SubagentModelResult{"deep", "gemini-4-carbon", "low"}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ResolveSubagentFromModels(agentdef.HarnessAntigravity, tc.parentModel, tc.parentEff, tc.agentType, tc.reqTier, "", tc.models, tc.rule)
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func TestResolveSubagentOverridesAndColdFallback(t *testing.T) {
	agyModels := []Model{
		{ID: "gemini-4-carbon", Label: "Gemini 4 Carbon", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-4-neon", Label: "Gemini 4 Neon", Efforts: []string{"low", "medium", "high"}},
		{ID: "gemini-4-hydrogen", Label: "Gemini 4 Hydrogen", Efforts: []string{"low", "medium", "high"}},
	}
	ladder := SubagentTierModels{Deep: "gemini-4-carbon", Standard: "gemini-4-neon", Fast: "gemini-4-hydrogen"}

	// ExplorerModelOverride applies when tier is omitted or fast; explicit standard overrides it.
	if got := ResolveSubagentFromModels(agentdef.HarnessAntigravity, "gemini-4-carbon", "high", agentdef.ExplorerAgent, "", "custom-fast", agyModels, ladder); got != (SubagentModelResult{"fast", "custom-fast", ""}) {
		t.Fatalf("explorer override omitted tier = %+v", got)
	}
	if got := ResolveSubagentFromModels(agentdef.HarnessAntigravity, "gemini-4-carbon", "high", agentdef.ExplorerAgent, "fast", "custom-fast", agyModels, ladder); got != (SubagentModelResult{"fast", "custom-fast", ""}) {
		t.Fatalf("explorer override fast tier = %+v", got)
	}
	if got := ResolveSubagentFromModels(agentdef.HarnessAntigravity, "gemini-4-carbon", "high", agentdef.ExplorerAgent, "standard", "custom-fast", agyModels, ladder); got != (SubagentModelResult{"standard", "gemini-4-neon", "medium"}) {
		t.Fatalf("explorer explicit standard tier = %+v", got)
	}

	// Cold catalog fallback: effort-only without rules; configured rules still apply directly when catalog is cold.
	if got := ResolveSubagentFromModels(agentdef.HarnessAntigravity, "gemini-4-neon", "high", agentdef.ExplorerAgent, "", "", nil, SubagentTierModels{}); got != (SubagentModelResult{"fast", "gemini-4-neon", "low"}) {
		t.Fatalf("cold default = %+v", got)
	}
	if got := ResolveSubagentFromModels(agentdef.HarnessAntigravity, "gemini-4-carbon", "high", agentdef.ExplorerAgent, "", "", nil, ladder); got != (SubagentModelResult{"fast", "gemini-4-hydrogen", "low"}) {
		t.Fatalf("cold with ladder = %+v", got)
	}
	if got := ResolveSubagentFromModels(agentdef.HarnessCodex, "gpt-6-codex", "", agentdef.ExplorerAgent, "", "", nil, SubagentTierModels{}); got != (SubagentModelResult{"fast", "gpt-6-codex", ""}) {
		t.Fatalf("cold without parent effort leaves effort empty: %+v", got)
	}
}

func TestNormalizeAndDecodeSubagentTierRules(t *testing.T) {
	norm, err := NormalizeSubagentTierRules(SubagentTierRules{
		"antigravity": {
			Deep:     " gemini-4-carbon ",
			Standard: "gemini-4-neon",
			Fast:     "gemini-4-hydrogen",
		},
		"codex": {},
	})
	if err != nil {
		t.Fatalf("NormalizeSubagentTierRules: %v", err)
	}
	if len(norm) != 1 || norm[agentdef.HarnessAntigravity] != (SubagentTierModels{Deep: "gemini-4-carbon", Standard: "gemini-4-neon", Fast: "gemini-4-hydrogen"}) {
		t.Fatalf("normalized = %#v", norm)
	}

	if _, err := NormalizeSubagentTierRules(SubagentTierRules{"unknown": {Fast: "m"}}); err == nil {
		t.Fatal("expected error for unknown harness")
	}
	if _, err := NormalizeSubagentTierRules(SubagentTierRules{agentdef.HarnessClaudeCode: {Fast: "bad\nmodel"}}); err == nil {
		t.Fatal("expected error for control character")
	}

	decoded := DecodeSubagentTierRules([]byte(`{"antigravity":{"deep":"gemini-4-carbon","standard":"gemini-4-neon","fast":"gemini-4-hydrogen"},"ignored":{"fast":"x"},"codex":{}}`))
	if len(decoded) != 1 || decoded.ForHarness(agentdef.HarnessAntigravity).Deep != "gemini-4-carbon" {
		t.Fatalf("decoded = %#v", decoded)
	}
	if empty := DecodeSubagentTierRules(nil); len(empty) != 0 {
		t.Fatalf("nil decode = %#v", empty)
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

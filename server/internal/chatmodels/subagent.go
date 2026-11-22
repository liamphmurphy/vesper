package chatmodels

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	tierSubFast = iota
	tierSubStandard
	tierSubDeep
)

var (
	subagentOrchestratorRe     = regexp.MustCompile(`\borchestrator\b`)
	orchestratorLabelVariantRe = regexp.MustCompile(`(?i)\borchestrator\s*\(([^)]+)\)`)
)

// SubagentTierModels maps each logical subagent tier (fast, standard, deep) to
// an optional concrete model ID on a single harness. Empty fields scale
// reasoning effort on the parent model instead of switching models.
type SubagentTierModels struct {
	Fast     string `json:"fast,omitempty"`
	Standard string `json:"standard,omitempty"`
	Deep     string `json:"deep,omitempty"`
}

// Normalized returns a copy with leading/trailing whitespace trimmed.
func (m SubagentTierModels) Normalized() SubagentTierModels {
	return SubagentTierModels{
		Fast:     strings.TrimSpace(m.Fast),
		Standard: strings.TrimSpace(m.Standard),
		Deep:     strings.TrimSpace(m.Deep),
	}
}

// IsZero reports whether all three tier slots are empty.
func (m SubagentTierModels) IsZero() bool {
	n := m.Normalized()
	return n.Fast == "" && n.Standard == "" && n.Deep == ""
}

// ModelForTier returns the configured model ID for tierSubFast/Standard/Deep.
func (m SubagentTierModels) ModelForTier(tier int) string {
	switch tier {
	case tierSubFast:
		return m.Fast
	case tierSubDeep:
		return m.Deep
	default:
		return m.Standard
	}
}

// SubagentTierRules configures optional per-harness subagent model ladders for
// a workspace (keyed by agentdef.Harness* constants).
type SubagentTierRules map[string]SubagentTierModels

// ForHarness returns the configured ladder for harness, or the zero struct.
func (r SubagentTierRules) ForHarness(harness string) SubagentTierModels {
	if r == nil {
		return SubagentTierModels{}
	}
	return r[harness].Normalized()
}

// DecodeSubagentTierRules parses stored JSONB rules, returning an empty map if
// raw is empty, null, or malformed, and dropping all-empty harness entries.
func DecodeSubagentTierRules(raw []byte) SubagentTierRules {
	out := SubagentTierRules{}
	if len(raw) == 0 {
		return out
	}
	var parsed map[string]SubagentTierModels
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return out
	}
	for harness, entry := range parsed {
		h := strings.TrimSpace(strings.ToLower(harness))
		if !validSubagentHarness(h) {
			continue
		}
		n := entry.Normalized()
		if !n.IsZero() {
			out[h] = n
		}
	}
	return out
}

// NormalizeSubagentTierRules validates harness keys and model IDs, returning a
// cleaned map with all-empty harness entries removed.
func NormalizeSubagentTierRules(in SubagentTierRules) (SubagentTierRules, error) {
	out := SubagentTierRules{}
	for rawHarness, entry := range in {
		h := strings.TrimSpace(strings.ToLower(rawHarness))
		if !validSubagentHarness(h) {
			return nil, fmt.Errorf("unknown harness %q", rawHarness)
		}
		n := entry.Normalized()
		for _, pair := range []struct {
			tier, val string
		}{
			{"fast", n.Fast},
			{"standard", n.Standard},
			{"deep", n.Deep},
		} {
			if pair.val == "" {
				continue
			}
			if len(pair.val) > 128 {
				return nil, fmt.Errorf("%s.%s model id is too long (max 128 characters)", h, pair.tier)
			}
			for _, r := range pair.val {
				if r < 0x20 || r == 0x7f {
					return nil, fmt.Errorf("%s.%s model id contains invalid control characters", h, pair.tier)
				}
			}
		}
		if !n.IsZero() {
			out[h] = n
		}
	}
	return out, nil
}

func validSubagentHarness(h string) bool {
	return h == agentdef.HarnessClaudeCode || h == agentdef.HarnessCodex || h == agentdef.HarnessAntigravity
}

// SubagentModelResult is the concrete harness target resolved for an in-turn
// subagent job after applying effort scaling or workspace tier rules, strictly
// capped at the parent's tier and effort.
type SubagentModelResult struct {
	Tier   string
	Model  string
	Effort string
}

// ModelsForHarness returns the live models offered for one harness in ws,
// reading the in-process cache first and falling back to a single non-blocking
// discovery lookup. Never errors: returns nil when the catalog is unavailable
// so subagent calls still run safely.
func (c Catalog) ModelsForHarness(ctx context.Context, q *store.Queries, ws uuid.UUID, harness string) []Model {
	if harness == "" {
		return nil
	}
	offered.Lock()
	cached := offered.byHarness[offeredKey(ws, harness)]
	offered.Unlock()
	if len(cached) > 0 {
		return cloneModels(cached)
	}
	if q == nil && (c.RequireKey || (c.Discover == nil && c.PlanModels == nil)) {
		return nil
	}
	h, err := c.harness(ctx, q, ws, harness, false)
	if err != nil || !h.Available || len(h.Models) == 0 {
		return nil
	}
	rememberOffered(ws, []Harness{h})
	return cloneModels(h.Models)
}

func cloneModels(in []Model) []Model {
	out := slices.Clone(in)
	for i := range out {
		if out[i].Efforts != nil {
			out[i].Efforts = slices.Clone(out[i].Efforts)
		}
	}
	return out
}

// ResolveSubagent resolves the effective tier, model ID, and effort for an
// in-turn subagent on the parent run's harness. By default it scales reasoning
// effort on the parent's own model (de-orchestrated on Antigravity) without
// guessing model codenames; when rules configure a custom model ladder for
// that harness, it maps tiers across those configured models instead.
func (c Catalog) ResolveSubagent(ctx context.Context, q *store.Queries, ws uuid.UUID, parent agentdef.Resolved, agentType, requestedTier string, rules SubagentTierRules) SubagentModelResult {
	models := c.ModelsForHarness(ctx, q, ws, parent.Harness)
	return ResolveSubagentFromModels(
		parent.Harness,
		parent.Model,
		parent.HarnessOptions["effort"],
		agentType,
		requestedTier,
		parent.HarnessOptions[agentdef.OptionExplorerModel],
		models,
		rules.ForHarness(parent.Harness),
	)
}

// ResolveSubagentFromModels maps a parent's model/effort and requested subagent
// tier using either effort-only scaling (when rule.IsZero()) or the explicit
// per-tier model ladder in rule, validating model availability against models.
func ResolveSubagentFromModels(_ string, parentModel, parentEffort, agentType, requestedTier, explorerModelOverride string, models []Model, rule SubagentTierModels) SubagentModelResult {
	reqTier := strings.TrimSpace(strings.ToLower(requestedTier))
	effectiveReq := reqTier
	if effectiveReq == "" {
		if agentType == agentdef.ExplorerAgent {
			effectiveReq = agentdef.SubagentTierFast
		} else {
			effectiveReq = agentdef.SubagentTierStandard
		}
	}
	wantTier := parseSubagentTier(effectiveReq)

	if agentType == agentdef.ExplorerAgent && explorerModelOverride != "" && (reqTier == "" || reqTier == agentdef.SubagentTierFast) {
		return SubagentModelResult{
			Tier:  agentdef.SubagentTierFast,
			Model: explorerModelOverride,
		}
	}

	rule = rule.Normalized()

	trimmedParent := strings.TrimSpace(parentModel)
	parentBase, suffixEffort, _ := agentdef.CutEffortSuffix(trimmedParent)
	parentEffort = strings.TrimSpace(strings.ToLower(parentEffort))
	if parentEffort == "" {
		parentEffort = suffixEffort
	}

	parentEntry := findCatalogModel(models, trimmedParent, parentBase)
	parentForClass := Model{ID: parentBase}
	if parentEntry != nil {
		parentForClass = *parentEntry
	}

	effectiveParentModel := trimmedParent
	if parentEntry != nil {
		effectiveParentModel = parentEntry.ID
	}
	effectiveParentEntry := parentEntry
	if isOrchestratorModel(parentForClass) {
		if deorch := deorchestrateParent(models, parentForClass); deorch != nil {
			effectiveParentEntry = deorch
			effectiveParentModel = deorch.ID
		}
	}
	effectiveParentBase, _, _ := agentdef.CutEffortSuffix(effectiveParentModel)

	parentEffortCap := effortCapTier(parentEffort)
	effTier := min(wantTier, parentEffortCap)
	chosenModel := effectiveParentModel
	chosenEntry := effectiveParentEntry

	resolveConfigured := func(targetID string) (string, *Model) {
		if targetID == "" {
			return effectiveParentModel, effectiveParentEntry
		}
		targetBase, _, _ := agentdef.CutEffortSuffix(targetID)
		if len(models) > 0 {
			if entry := findCatalogModel(models, targetID, targetBase); entry != nil {
				return entry.ID, entry
			}
			// Configured model is no longer in the live catalog: fall back safely to parent.
			return effectiveParentModel, effectiveParentEntry
		}
		return targetID, nil
	}

	if !rule.IsZero() {
		matchedTier, onLadder := matchRuleTier(rule, effectiveParentModel, effectiveParentBase, trimmedParent, parentBase)
		switch {
		case onLadder:
			effTier = min(wantTier, matchedTier)
			chosenModel, chosenEntry = resolveConfigured(rule.ModelForTier(effTier))
		case rule.Fast != "" && rule.Standard == "" && rule.Deep == "":
			if effTier == tierSubFast {
				chosenModel, chosenEntry = resolveConfigured(rule.Fast)
			}
		default:
			// Unlisted parent on a multi-tier ladder: stay safe with effort-only on parent.
		}
	}

	targetEffort := targetSubagentEffort(effTier)
	if parentEffort != "" {
		if pr, ok := effortRank(parentEffort); ok {
			if tr, tok := effortRank(targetEffort); !tok || tr > pr {
				targetEffort = parentEffort
			}
		}
	}

	var chosenEffort string
	if chosenEntry != nil {
		chosenEffort = clampModelEffort(chosenEntry.Efforts, targetEffort)
	} else if chosenModel != "" && parentEffort != "" {
		chosenEffort = targetEffort
	}

	return SubagentModelResult{
		Tier:   subagentTierName(effTier),
		Model:  chosenModel,
		Effort: chosenEffort,
	}
}

func matchRuleTier(rule SubagentTierModels, refs ...string) (int, bool) {
	checks := []struct {
		tier  int
		model string
	}{
		{tierSubDeep, rule.Deep},
		{tierSubStandard, rule.Standard},
		{tierSubFast, rule.Fast},
	}
	for _, ch := range checks {
		if ch.model == "" {
			continue
		}
		ruleBase, _, _ := agentdef.CutEffortSuffix(ch.model)
		for _, ref := range refs {
			if ref == "" {
				continue
			}
			if strings.EqualFold(ref, ch.model) || (ruleBase != "" && strings.EqualFold(ref, ruleBase)) {
				return ch.tier, true
			}
		}
	}
	return 0, false
}

func findCatalogModel(models []Model, fullID, baseID string) *Model {
	if fullID != "" {
		for i := range models {
			if strings.EqualFold(models[i].ID, fullID) {
				m := models[i]
				return &m
			}
		}
	}
	if baseID != "" && !strings.EqualFold(baseID, fullID) {
		for i := range models {
			if strings.EqualFold(models[i].ID, baseID) {
				m := models[i]
				return &m
			}
		}
	}
	return nil
}

func subagentNormalizedName(m Model) string {
	base, _, _ := agentdef.CutEffortSuffix(strings.TrimSpace(m.ID))
	return strings.ToLower(strings.TrimSpace(base + " " + m.Label))
}

func isOrchestratorModel(m Model) bool {
	return subagentOrchestratorRe.MatchString(subagentNormalizedName(m))
}

func orchestratorVariant(m Model) string {
	if match := orchestratorLabelVariantRe.FindStringSubmatch(m.Label); len(match) == 2 {
		if v := strings.ToLower(strings.TrimSpace(match[1])); v != "" {
			return v
		}
	}
	base, _, _ := agentdef.CutEffortSuffix(strings.TrimSpace(m.ID))
	lower := strings.ToLower(base)
	if _, after, ok := strings.Cut(lower, "-orchestrator-"); ok {
		return strings.TrimSpace(after)
	}
	return ""
}

func deorchestrateParent(models []Model, parent Model) *Model {
	variant := orchestratorVariant(parent)
	if variant == "" || len(models) == 0 {
		return nil
	}
	re, err := regexp.Compile(`(?:^|[^a-z0-9])` + regexp.QuoteMeta(variant) + `(?:$|[^a-z0-9])`)
	if err != nil {
		return nil
	}
	for i := range models {
		m := models[i]
		if isOrchestratorModel(m) {
			continue
		}
		if re.MatchString(subagentNormalizedName(m)) {
			found := m
			return &found
		}
	}
	return nil
}

func parseSubagentTier(tier string) int {
	switch tier {
	case agentdef.SubagentTierFast:
		return tierSubFast
	case agentdef.SubagentTierDeep:
		return tierSubDeep
	default:
		return tierSubStandard
	}
}

func subagentTierName(tier int) string {
	switch tier {
	case tierSubFast:
		return agentdef.SubagentTierFast
	case tierSubDeep:
		return agentdef.SubagentTierDeep
	default:
		return agentdef.SubagentTierStandard
	}
}

func effortCapTier(effort string) int {
	switch effort {
	case "low":
		return tierSubFast
	case "medium":
		return tierSubStandard
	default:
		return tierSubDeep
	}
}

func targetSubagentEffort(effTier int) string {
	switch effTier {
	case tierSubFast:
		return "low"
	case tierSubDeep:
		return "high"
	default:
		return "medium"
	}
}

func effortRank(e string) (int, bool) {
	i := slices.Index(agentdef.Efforts, e)
	return i, i >= 0
}

func clampModelEffort(efforts []string, target string) string {
	if len(efforts) == 0 {
		return ""
	}
	targetIdx, ok := effortRank(target)
	if !ok {
		return ""
	}
	best := ""
	bestIdx := -1
	lowest := ""
	lowestIdx := len(agentdef.Efforts) + 1
	for _, e := range efforts {
		idx, valid := effortRank(e)
		if !valid {
			continue
		}
		if idx < lowestIdx {
			lowestIdx = idx
			lowest = e
		}
		if idx <= targetIdx && idx > bestIdx {
			bestIdx = idx
			best = e
		}
	}
	if best != "" {
		return best
	}
	return lowest
}

package chatmodels

import (
	"context"
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
	subagentFastRe         = regexp.MustCompile(`\b(haiku|mini|nano|flash|lite|spark)\b`)
	subagentOrchestratorRe = regexp.MustCompile(`\borchestrator\b`)
	subagentOrchStdRe      = regexp.MustCompile(`\b(carbon|argon)\b`)
	subagentOrchNeonRe     = regexp.MustCompile(`\bneon\b`)
	subagentDeepRe         = regexp.MustCompile(`\b(fable|max|pro|ultra|neon|hydrogen)\b`)
	subagentOpusRe         = regexp.MustCompile(`\bopus\b`)
	subagentFableRe        = regexp.MustCompile(`(?i)\bfable\b`)
	subagentSonnetRe       = regexp.MustCompile(`\bsonnet\b`)
)

// SubagentModelResult is the concrete harness target resolved for an in-turn
// subagent job after applying tier defaults and the parent's tier/effort caps.
type SubagentModelResult struct {
	Tier   string
	Model  string
	Effort string
}

// ModelsForHarness returns the live models offered for one harness in ws,
// reading the in-process cache first and falling back to a single non-blocking
// discovery lookup. Never errors: returns nil when the catalog is unavailable
// so subagent calls still run with static defaults.
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
// in-turn subagent on the parent run's harness using the workspace's live model
// catalog when available.
func (c Catalog) ResolveSubagent(ctx context.Context, q *store.Queries, ws uuid.UUID, parent agentdef.Resolved, agentType, requestedTier string) SubagentModelResult {
	models := c.ModelsForHarness(ctx, q, ws, parent.Harness)
	return ResolveSubagentFromModels(
		parent.Harness,
		parent.Model,
		parent.HarnessOptions["effort"],
		agentType,
		requestedTier,
		parent.HarnessOptions[agentdef.OptionExplorerModel],
		models,
	)
}

// ResolveSubagentFromModels maps a parent's harness/model/effort and requested
// subagent tier against a harness model catalog, strictly clamping the child's
// tier and effort at or below the parent's.
func ResolveSubagentFromModels(harness, parentModel, parentEffort, agentType, requestedTier, explorerModelOverride string, models []Model) SubagentModelResult {
	reqTier := strings.TrimSpace(strings.ToLower(requestedTier))
	effectiveReq := reqTier
	if effectiveReq == "" {
		if agentType == agentdef.ExplorerAgent {
			effectiveReq = agentdef.SubagentTierFast
		} else {
			effectiveReq = agentdef.SubagentTierStandard
		}
	}

	if agentType == agentdef.ExplorerAgent && explorerModelOverride != "" && (reqTier == "" || reqTier == agentdef.SubagentTierFast) {
		return SubagentModelResult{
			Tier:  agentdef.SubagentTierFast,
			Model: explorerModelOverride,
		}
	}

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

	hasFable := hasFableModel(models)
	parentTier := classifySubagentModel(parentForClass, hasFable)
	wantTier := parseSubagentTier(effectiveReq)
	effTier := min(wantTier, parentTier)

	candidates := nonOrchestratorModels(models)
	hasDeepModel := false
	for _, m := range candidates {
		if classifySubagentModel(m, hasFable) == tierSubDeep {
			hasDeepModel = true
			break
		}
	}

	parentIsOrch := isOrchestratorModel(parentForClass)
	orchVariant := orchestratorVariant(parentForClass)
	parentFamily := subagentModelFamily(harness, parentForClass)

	var chosenModel string
	var chosenEntry *Model

	switch {
	case effTier == parentTier && !parentIsOrch && len(models) > 0:
		if parentEntry != nil {
			chosenModel = parentEntry.ID
			chosenEntry = parentEntry
		} else {
			chosenModel = trimmedParent
		}
	case len(candidates) > 0:
		for t := effTier; t >= 0; t-- {
			var tierCandidates []Model
			for _, m := range candidates {
				if classifySubagentModel(m, hasFable) == t {
					tierCandidates = append(tierCandidates, m)
				}
			}
			if len(tierCandidates) == 0 {
				continue
			}
			tierCandidates = narrowSubagentCandidates(tierCandidates, func(m Model) bool {
				return parentIsOrch && effTier == parentTier && orchVariant != "" && matchesVariant(m, orchVariant)
			})
			tierCandidates = narrowSubagentCandidates(tierCandidates, func(m Model) bool {
				return parentFamily != "" && subagentModelFamily(harness, m) == parentFamily
			})
			tierCandidates = narrowSubagentCandidates(tierCandidates, func(m Model) bool {
				return harness == agentdef.HarnessClaudeCode && effTier == tierSubStandard && parentTier == tierSubDeep &&
					subagentSonnetRe.MatchString(subagentNormalizedName(m))
			})
			picked := tierCandidates[0]
			for _, m := range tierCandidates {
				if m.Default {
					picked = m
					break
				}
			}
			chosenModel = picked.ID
			chosenEntry = &picked
			break
		}
		if chosenModel == "" {
			if parentEntry != nil && !parentIsOrch {
				chosenModel = parentEntry.ID
				chosenEntry = parentEntry
			} else {
				chosenModel = trimmedParent
			}
		}
	default:
		if effTier == tierSubFast && parentTier != tierSubFast {
			chosenModel = coldFastModel(harness)
		} else {
			chosenModel = trimmedParent
			if chosenModel == "" {
				chosenModel = coldFastModel(harness)
			}
		}
	}

	targetEffort := targetSubagentEffort(effTier, wantTier, parentTier, hasDeepModel)
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
	} else if chosenModel != "" && chosenModel == trimmedParent && parentEffort != "" {
		chosenEffort = targetEffort
	}

	return SubagentModelResult{
		Tier:   subagentTierName(effTier),
		Model:  chosenModel,
		Effort: chosenEffort,
	}
}

func narrowSubagentCandidates(candidates []Model, keep func(Model) bool) []Model {
	var out []Model
	for _, m := range candidates {
		if keep(m) {
			out = append(out, m)
		}
	}
	if len(out) > 0 {
		return out
	}
	return candidates
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

func hasFableModel(models []Model) bool {
	for _, m := range models {
		if subagentFableRe.MatchString(m.ID + " " + m.Label) {
			return true
		}
	}
	return false
}

func nonOrchestratorModels(models []Model) []Model {
	if len(models) == 0 {
		return nil
	}
	out := make([]Model, 0, len(models))
	for _, m := range models {
		if !isOrchestratorModel(m) {
			out = append(out, m)
		}
	}
	if len(out) == 0 {
		return models
	}
	return out
}

func subagentNormalizedName(m Model) string {
	base, _, _ := agentdef.CutEffortSuffix(strings.TrimSpace(m.ID))
	return strings.ToLower(strings.TrimSpace(base + " " + m.Label))
}

func isOrchestratorModel(m Model) bool {
	return subagentOrchestratorRe.MatchString(subagentNormalizedName(m))
}

func orchestratorVariant(m Model) string {
	name := subagentNormalizedName(m)
	switch {
	case subagentOrchNeonRe.MatchString(name):
		return "neon"
	case strings.Contains(name, "carbon"):
		return "carbon"
	case strings.Contains(name, "argon"):
		return "argon"
	default:
		return ""
	}
}

func matchesVariant(m Model, variant string) bool {
	name := subagentNormalizedName(m)
	return strings.Contains(name, variant)
}

func classifySubagentModel(m Model, hasFable bool) int {
	name := subagentNormalizedName(m)
	switch {
	case subagentFastRe.MatchString(name):
		return tierSubFast
	case subagentOrchestratorRe.MatchString(name):
		if subagentOrchStdRe.MatchString(name) {
			return tierSubStandard
		}
		return tierSubDeep
	case subagentDeepRe.MatchString(name):
		return tierSubDeep
	case !hasFable && subagentOpusRe.MatchString(name):
		return tierSubDeep
	default:
		return tierSubStandard
	}
}

func subagentModelFamily(harness string, m Model) string {
	switch harness {
	case agentdef.HarnessClaudeCode:
		return "claude"
	case agentdef.HarnessCodex:
		return "openai"
	}
	name := subagentNormalizedName(m)
	switch {
	case strings.Contains(name, "claude") || strings.Contains(name, "opus") || strings.Contains(name, "sonnet") || strings.Contains(name, "haiku") || strings.Contains(name, "fable"):
		return "claude"
	case strings.Contains(name, "gemini"):
		return "gemini"
	case strings.Contains(name, "gpt") || strings.Contains(name, "codex"):
		return "openai"
	default:
		return ""
	}
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

func coldFastModel(harness string) string {
	switch harness {
	case agentdef.HarnessCodex:
		return "gpt-5-mini"
	case agentdef.HarnessAntigravity:
		return "gemini-3.8-flash"
	default:
		return agentdef.DefaultExplorerModel
	}
}

func targetSubagentEffort(effTier, wantTier, parentTier int, hasDeepModel bool) string {
	switch effTier {
	case tierSubFast:
		return "low"
	case tierSubDeep:
		return "high"
	default:
		if wantTier == tierSubDeep && effTier == parentTier && !hasDeepModel {
			return "high"
		}
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

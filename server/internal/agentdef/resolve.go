package agentdef

import (
	"fmt"
	"slices"
	"strings"
	"time"
)

// Source says where a resolved value came from.
type Source string

const (
	FromAgent   Source = "agent"
	FromProject Source = "project"
	// FromPersona marks scopes a persona's structured capabilities grant a chat.
	FromPersona Source = "persona"
	// FromDelegation marks the repo:write denial of a read-only delegated copy.
	FromDelegation Source = "delegation"
)

// ResolvedScope is one scope after merging, with where its mode came from.
type ResolvedScope struct {
	Scope  string `json:"scope"`
	Mode   Mode   `json:"mode"`
	Source Source `json:"source"`
}

// Resolved is the fully merged definition a run snapshots (§6.4).
// Repository freezes project configuration at approval, including an empty repository URL.
// EpicBranch is set for a ticket in an epic: the epic's shared branch, whose
// one pull request into DefaultBranch carries all of the epic's work.
type Repository struct {
	URL           *string `json:"url"`
	DefaultBranch string  `json:"default_branch"`
	EpicBranch    string  `json:"epic_branch,omitempty"`
	EpicName      string  `json:"epic_name,omitempty"`
	// EpicReview marks the epic's final review ticket; EpicTickets is the
	// epic's regular tickets as of dispatch.
	EpicReview  bool         `json:"epic_review,omitempty"`
	EpicTickets []EpicTicket `json:"epic_tickets,omitempty"`
}

// EpicTicket is one regular ticket of the epic under final review.
type EpicTicket struct {
	Key     string `json:"key"`
	Title   string `json:"title"`
	Status  string `json:"status"`
	Branch  string `json:"branch,omitempty"`
	PRURL   string `json:"pr_url,omitempty"`
	PRState string `json:"pr_state,omitempty"`
}

// EpicBranch names an epic's shared branch. It uses the epic's id, not its
// name, so renaming the epic doesn't strand work on an old branch.
func EpicBranch(projectKey, epicID string) string {
	if len(epicID) > 8 {
		epicID = epicID[:8]
	}
	return "epic/" + strings.ToLower(projectKey) + "-" + epicID
}

type Resolved struct {
	ReviewRequired bool       `json:"review_required,omitempty"`
	Fallbacks      []Fallback `json:"fallbacks,omitempty"`
	// Chain is the run's full preference order, primary first. Only the runner
	// sets it (runs created before it existed derive it from Fallbacks).
	Chain          []Fallback                   `json:"chain,omitempty"`
	Repository     *Repository                  `json:"repository,omitempty"`
	Harness        string                       `json:"harness"`
	Model          string                       `json:"model"`
	Instructions   string                       `json:"instructions"`
	Scopes         []ResolvedScope              `json:"scopes"`
	Budget         Budget                       `json:"budget"`
	MaxConcurrency int                          `json:"max_concurrency"`
	MCPServers     []MCPServer                  `json:"mcp_servers"`
	HarnessOptions map[string]string            `json:"harness_options"` // for the resolved harness only
	Setup          []string                     `json:"setup"`
	Services       []Service                    `json:"services,omitempty"`
	Memory         Memory                       `json:"memory"`
	Skills         []Skill                      `json:"skills"`
	Provenance     map[string]Source            `json:"provenance"` // field → source, for fields a project changed
	allOptions     map[string]map[string]string // kept for re-resolution
}

// matches reports whether a wildcard scope ("prod:*") covers scope.
func matches(pattern, scope string) bool {
	if pattern == scope {
		return true
	}
	if p, ok := strings.CutSuffix(pattern, ":*"); ok {
		return strings.HasPrefix(scope, p+":")
	}
	return false
}

// ModeFor applies a scope map to one concrete scope: the strictest of the
// exact entry and every matching wildcard. Unknown scopes are denied.
func ModeFor(scopes map[string]Mode, scope string) (Mode, bool) {
	var (
		mode  Mode
		found bool
	)
	for pattern, m := range scopes {
		if matches(pattern, scope) {
			if !found {
				mode, found = m, true
			} else {
				mode = Stricter(mode, m)
			}
		}
	}
	if !found {
		return Denied, false
	}
	return mode, true
}

func minDuration(a, b string) string {
	if a == "" {
		return b
	}
	if b == "" {
		return a
	}
	da, _ := time.ParseDuration(a)
	db, _ := time.ParseDuration(b)
	if db < da {
		return b
	}
	return a
}

func minPositive(a, b int) int {
	if a == 0 {
		return b
	}
	if b == 0 || a < b {
		return a
	}
	return b
}

// Resolve merges a project override over an agent spec (docs/dev/plan.md §6.1):
//   - scalars replace (harness, model);
//   - instructions_append and mcp_servers_add append;
//   - scopes merge key by key and can only tighten; wildcard denials apply
//     to every matching scope;
//   - budget takes the lower of each limit;
//   - skills_remove drops agent skills by name (unknown names are a no-op),
//     then skills_add appends in override order. An added name still among the
//     remaining agent skills is skipped, so a project can't redefine an agent
//     skill; remove + add of the same name replaces it, placed at the end.
//     The result is capped at MaxSkills: agent skills are kept first and
//     trailing added skills are dropped (Resolve can't reject).
//
// Both inputs must be normalized. o may be nil.
func Resolve(s Spec, o *Override) Resolved {
	r := Resolved{
		Harness: s.Harness, Model: s.Model, Instructions: s.Instructions, ReviewRequired: s.ReviewRequired,
		Fallbacks: append([]Fallback{}, s.Fallbacks...),
		Budget:    s.Budget, MaxConcurrency: s.MaxConcurrency, Memory: s.MemoryOrDefault(),
		MCPServers: append([]MCPServer{}, s.MCPServers...), Skills: append([]Skill{}, s.Skills...),
		Setup: []string{}, Provenance: map[string]Source{}, allOptions: s.HarnessOptions,
	}
	if o == nil {
		o = &Override{}
	}
	if o.Harness != "" && o.Harness != s.Harness {
		r.Harness, r.Provenance["harness"] = o.Harness, FromProject
	}
	if o.Model != "" && o.Model != s.Model {
		r.Model, r.Provenance["model"] = o.Model, FromProject
	}
	if add := strings.TrimSpace(o.InstructionsAppend); add != "" {
		r.Instructions = strings.TrimRight(r.Instructions, "\n") + "\n\n" + add + "\n"
		r.Provenance["instructions"] = FromProject
	}
	if len(o.MCPServersAdd) > 0 {
		have := map[string]bool{}
		for _, m := range r.MCPServers {
			have[m.Name] = true
		}
		for _, m := range o.MCPServersAdd {
			if !have[m.Name] { // a project can add servers, not redefine the agent's
				r.MCPServers = append(r.MCPServers, m)
			}
		}
		r.Provenance["mcp_servers"] = FromProject
	}
	if len(o.SkillsRemove) > 0 || len(o.SkillsAdd) > 0 {
		r.Skills = resolveSkills(s.Skills, o)
		if !slices.Equal(r.Skills, s.Skills) {
			r.Provenance["skills"] = FromProject
		}
	}
	if b := (Budget{MaxRuntime: minDuration(s.Budget.MaxRuntime, o.Budget.MaxRuntime), MaxTurns: minPositive(s.Budget.MaxTurns, o.Budget.MaxTurns)}); b != s.Budget {
		r.Budget, r.Provenance["budget"] = b, FromProject
	}
	if len(o.Setup) > 0 {
		r.Setup = append(r.Setup, o.Setup...)
		r.Provenance["setup"] = FromProject
	}
	if len(o.Services) > 0 {
		r.Services = append([]Service(nil), o.Services...)
		r.Provenance["services"] = FromProject
	}

	// Scopes: every key named by either side, plus wildcards kept as-is so
	// a project's "prod:*: denied" also covers scopes added later.
	keys := map[string]bool{}
	for k := range s.Scopes {
		keys[k] = true
	}
	for k := range o.Scopes {
		keys[k] = true
	}
	merged := map[string]Mode{}
	for k := range keys {
		// A scope the agent doesn't grant is denied, and a project can't
		// grant it: overrides only tighten. Naming it just records the denial.
		base, inBase := ModeFor(s.Scopes, k)
		mode, source := base, FromAgent
		if pm, ok := ModeFor(o.Scopes, k); ok {
			if t := Stricter(base, pm); t != base || !inBase {
				mode, source = t, FromProject
			}
		}
		merged[k] = mode
		r.Scopes = append(r.Scopes, ResolvedScope{Scope: k, Mode: mode, Source: source})
	}
	sortScopes(r.Scopes)
	for _, sc := range r.Scopes {
		if sc.Source == FromProject {
			r.Provenance["scopes"] = FromProject
			break
		}
	}

	r.Fallbacks = slices.DeleteFunc(r.Fallbacks, func(f Fallback) bool { return f.Harness == r.Harness && f.Model == r.Model })
	r.HarnessOptions = map[string]string{}
	for k, v := range s.HarnessOptions[r.Harness] {
		r.HarnessOptions[k] = v
	}
	return r
}

func resolveSkills(agent []Skill, o *Override) []Skill {
	drop := map[string]bool{}
	for _, n := range o.SkillsRemove {
		drop[n] = true
	}
	out := make([]Skill, 0, len(agent)+len(o.SkillsAdd))
	have := map[string]bool{}
	for _, k := range agent {
		if !drop[k.Name] {
			out = append(out, k)
			have[k.Name] = true
		}
	}
	for _, k := range o.SkillsAdd {
		if !have[k.Name] {
			out = append(out, k)
			have[k.Name] = true
		}
	}
	if len(out) > MaxSkills {
		out = out[:MaxSkills]
	}
	return out
}

func sortScopes(s []ResolvedScope) {
	for i := 1; i < len(s); i++ {
		for j := i; j > 0 && s[j].Scope < s[j-1].Scope; j-- {
			s[j], s[j-1] = s[j-1], s[j]
		}
	}
}

// Mode returns the resolved mode for a concrete scope (wildcards applied).
func (r Resolved) Mode(scope string) Mode {
	m := map[string]Mode{}
	for _, s := range r.Scopes {
		m[s.Scope] = s.Mode
	}
	mode, _ := ModeFor(m, scope)
	return mode
}

// Changes summarizes an override for the overrides list ("harness → codex").
func (o Override) Changes() []string {
	var out []string
	if o.Harness != "" {
		out = append(out, "harness → "+o.Harness)
	}
	if o.Model != "" {
		out = append(out, "model → "+o.Model)
	}
	if a := strings.TrimSpace(o.InstructionsAppend); a != "" {
		first, _, _ := strings.Cut(a, "\n")
		out = append(out, "+ instructions: “"+first+"”")
	}
	for _, s := range sortedScopes(o.Scopes) {
		out = append(out, s+" → "+string(o.Scopes[s]))
	}
	for _, m := range o.MCPServersAdd {
		out = append(out, "+ MCP server "+m.Name)
	}
	for _, n := range o.SkillsRemove {
		out = append(out, "− skill "+n)
	}
	for _, k := range o.SkillsAdd {
		out = append(out, "+ skill "+k.Name)
	}
	if o.Budget.MaxRuntime != "" {
		out = append(out, "max runtime ≤ "+o.Budget.MaxRuntime)
	}
	if o.Budget.MaxTurns > 0 {
		out = append(out, "max turns ≤ "+itoa(o.Budget.MaxTurns))
	}
	for _, c := range o.Setup {
		out = append(out, "setup: "+c)
	}
	for _, s := range o.Services {
		out = append(out, "+ service "+s.Name+" ("+s.Image+")")
	}
	return out
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

// Validate checks that a run could execute a resolved definition's primary and
// fallback targets. A frozen spec can name a harness this build no longer has.
func (r Resolved) Validate() error {
	if !slices.Contains(Harnesses, r.Harness) {
		return fmt.Errorf("unsupported harness %q", r.Harness)
	}
	for _, f := range r.Fallbacks {
		if !slices.Contains(Harnesses, f.Harness) {
			return fmt.Errorf("fallback: unsupported harness %q", f.Harness)
		}
	}
	return nil
}

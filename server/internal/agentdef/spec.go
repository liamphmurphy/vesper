// Package agentdef defines what an agent is, independent of any harness
// (docs/dev/plan.md §6.1): the versioned definition, per-project overrides, the merge
// that resolves them, and how strongly each scope can be enforced (§6.3).
package agentdef

import (
	"fmt"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// Mode is a scope's permission. Modes are ordered: a project may only move a
// scope rightwards (tighten), never leftwards.
type Mode string

const (
	Allowed          Mode = "allowed"
	RequiresApproval Mode = "requires_approval"
	Denied           Mode = "denied"
)

func (m Mode) rank() int {
	switch m {
	case Allowed:
		return 0
	case RequiresApproval:
		return 1
	case Denied:
		return 2
	}
	return -1
}

// Stricter returns the tighter of two modes.
func Stricter(a, b Mode) Mode {
	if b.rank() > a.rank() {
		return b
	}
	return a
}

const (
	HarnessClaudeCode  = "claude-code"
	HarnessCodex       = "codex"
	HarnessAntigravity = "antigravity"
)

var Harnesses = []string{HarnessClaudeCode, HarnessCodex, HarnessAntigravity}

// CanMakeImages reports whether a harness has a built-in image generator a
// one-shot image step can use (ImageHarnesses, in preference order).
func CanMakeImages(harness string) bool { return slices.Contains(ImageHarnesses, harness) }

// ImageHarnesses are the harnesses that can generate images, in the order
// "Auto" prefers them.
var ImageHarnesses = []string{HarnessCodex, HarnessAntigravity}

// Budget is an optional runaway guard (no spend caps in v1). Zero = unset.
type Budget struct {
	MaxRuntime string `json:"max_runtime,omitempty"` // Go duration, e.g. "2h"
	MaxTurns   int    `json:"max_turns,omitempty"`
}

type MCPServer struct {
	Name        string `json:"name"`
	URL         string `json:"url"`
	Description string `json:"description,omitempty"`
	// Connector marks a person's connector: the harness reaches it through
	// Vesper at <MCP URL>/connectors/<Name> with the run's own token.
	Connector bool `json:"connector,omitempty"`
}

// Fallback is the next harness/model to try when provider usage is exhausted.
// Options belong only to this target; primary harness options are never reused.
type Fallback struct {
	Harness        string            `json:"harness"`
	Model          string            `json:"model"`
	HarnessOptions map[string]string `json:"harness_options,omitempty"`
}

// Spec is one immutable definition version, stored as jsonb.
type Spec struct {
	ReviewRequired bool                         `json:"review_required,omitempty"`
	Fallbacks      []Fallback                   `json:"fallbacks,omitempty"`
	Harness        string                       `json:"harness"`
	Model          string                       `json:"model"`
	Instructions   string                       `json:"instructions"`
	Scopes         map[string]Mode              `json:"scopes"`
	Budget         Budget                       `json:"budget"`
	MaxConcurrency int                          `json:"max_concurrency"`
	MCPServers     []MCPServer                  `json:"mcp_servers"`
	HarnessOptions map[string]map[string]string `json:"harness_options"`
	Memory         *Memory                      `json:"memory"` // nil (saved before memory existed) = DefaultMemory
	Skills         []Skill                      `json:"skills"` // nil (saved before skills existed) = none
}

// Skill is a reusable playbook the agent loads on demand: a short
// description it is matched against, and a markdown body it follows. On
// Claude Code it becomes a native skill (.claude/skills/<name>/SKILL.md);
// on harnesses without skills it is indexed in AGENTS.md and read as a file.
type Skill struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Body        string `json:"body"`
}

const (
	MaxSkills           = 30
	MaxSkillBodyBytes   = 64 * 1024
	MaxSkillDescription = 1024
)

// Memory says what wiki context a run gets (docs/dev/plan.md §12.3). Inject levels
// default to selective previews. Legacy full-page modes are cumulative:
// index (the agent's Memory page) → linked (plus pages
// linked to or from the ticket and its artifacts) → search (plus the top
// search hits for the ticket title).
type Memory struct {
	Enabled   bool   `json:"enabled"`
	Inject    string `json:"inject"`
	MaxTokens int    `json:"max_tokens"`
}

const (
	InjectSelective = "selective"
	InjectIndex     = "index"
	InjectLinked    = "linked"
	InjectSearch    = "search"
)

// DefaultMemory applies when a definition doesn't say.
var DefaultMemory = Memory{Enabled: true, Inject: InjectSelective, MaxTokens: 1500}

// Override is a project's partial definition, merged over the agent's.
type Override struct {
	Harness            string          `json:"harness,omitempty"`
	Model              string          `json:"model,omitempty"`
	InstructionsAppend string          `json:"instructions_append,omitempty"`
	Scopes             map[string]Mode `json:"scopes,omitempty"`
	Budget             Budget          `json:"budget"`
	MCPServersAdd      []MCPServer     `json:"mcp_servers_add,omitempty"`
	Setup              []string        `json:"setup,omitempty"`
	SkillsAdd          []Skill         `json:"skills_add,omitempty"`
	SkillsRemove       []string        `json:"skills_remove,omitempty"`
	// Services are what the project's tests need running (see Service).
	Services []Service `json:"services,omitempty"`
}

// Empty reports whether the override changes nothing.
func (o Override) Empty() bool {
	return o.Harness == "" && o.Model == "" && strings.TrimSpace(o.InstructionsAppend) == "" && len(o.Scopes) == 0 &&
		o.Budget == (Budget{}) && len(o.MCPServersAdd) == 0 && len(o.Setup) == 0 &&
		len(o.SkillsAdd) == 0 && len(o.SkillsRemove) == 0 && len(o.Services) == 0
}

// The lazyagents MCP server is always injected by the runner; definitions
// can't remove or shadow it.
const ReservedMCPName = "lazyagents"

// SecretsMCPName is the server a chat reaches its person's API secrets
// through. It's served like a connector (at <MCP URL>/connectors/<name>, with
// the run's token), and connector slugs can't contain "_", so no connector
// can take it.
const (
	SecretsMCPName     = "vesper_secrets"
	CustomAppMCPPrefix = "app_"
)

var (
	scopeRe = regexp.MustCompile(`^[a-z][a-z0-9-]*:([a-z0-9][a-z0-9-]*|\*)$`)
	nameRe  = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,63}$`)
	skillRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,63}$`)
)

// ValidationError names the offending field (mapped to 422 by the API).
type ValidationError struct{ Field, Msg string }

func (e *ValidationError) Error() string { return e.Field + ": " + e.Msg }

func invalid(field, format string, a ...any) error {
	return &ValidationError{Field: field, Msg: fmt.Sprintf(format, a...)}
}

// OptionWebSearch ("true") enables a harness's built-in web search and page
// fetch tools for a read-only run. Only the Personal Assistant's chat spec sets
// it (definitions can't), and the tool policy honors it only on chat runs;
// Claude Code and Codex support it. See
// ADR "Assistant web access".
const OptionWebSearch = "web_search"

// OptionImageGeneration ("true") turns on a harness's built-in image generation
// for a chat (Codex's image tool, Antigravity's generator). Only the Personal
// Assistant's chat spec sets it, for a persona with the images capability;
// definitions can't, and Codex runs without it have the feature switched off.
// Claude Code never receives it.
const OptionImageGeneration = "image_generation"

// OptionNoTools ("true") makes a turn answer from its prompt alone: no MCP
// servers and no tools. Vesper's own background prompts use it, since they
// carry a person's private context and have no run to scope tools to.
const OptionNoTools = "no_tools"

// OptionAside ("true") marks a chat segment that answers an aside: a question
// about another chat's running reply. Only the Personal Assistant's chat spec
// sets it, and the MCP surface it gets is read-only.
const OptionAside = "aside"

// OptionExplorer gives a Claude Code or Antigravity lead ticket run one
// read-only sub agent, "explorer", that searches and reads code on a cheap
// model and returns conclusions, keeping that output out of the lead's
// context. It is on unless set to "false". OptionExplorerModel picks its model
// on Claude Code (default DefaultExplorerModel); agy runs it on its flash
// tier. Codex has none (docs/contracts/ADR-explorer.md). See ExplorerOn for
// when it applies.
const (
	OptionExplorer       = "explorer"
	OptionExplorerModel  = "explorer_model"
	DefaultExplorerModel = "haiku-5.5"
	// ExplorerAgent is the explorer's sub agent type.
	ExplorerAgent = "explorer"
	// ExplorerDescription and ExplorerPrompt are the same on every harness.
	ExplorerDescription = "Read-only code search. Use it for any question that needs a broad grep or reading more than about three files, when you need the conclusion and not the file contents."
	ExplorerPrompt      = "Answer the question from the code. Reply in at most 300 words with file:line references. Never paste whole files or long excerpts. Say what you could not find."
)

// EagerVesperTools are the lazyagents tools almost every chat turn or ticket run
// calls. Harnesses that defer MCP tools until the model looks them up load these
// up front instead, saving a discovery round-trip each: Claude Code reads the
// MCP server's per-tool _meta "anthropic/alwaysLoad", agy reads tools.<name>.eager
// in mcp_config.json. Codex loads every tool up front already. Each one costs its
// schema in every prompt, so keep the list to tools a turn really starts with.
var EagerVesperTools = []string{
	// Chats.
	"set_chat_title", "list_projects", "list_tickets", "get_ticket", "update_ticket", "request_push",
	// Ticket runs.
	"claim_ticket", "post_plan", "update_step", "check_criterion", "complete_run",
}

// BatchExplorationGuide is the one line every coding prompt (chat and ticket
// run, on every harness) carries about exploring a codebase. Each model turn
// costs seconds of latency, so independent lookups belong in one turn.
const BatchExplorationGuide = "Explore in batches: make independent file reads and searches together in one turn, don't repeat a lookup you've already answered, and start editing once you know where the change goes and the local conventions."

// ExplorerOn reports whether a run gets the explorer sub agent: the option
// isn't "false", the harness is Claude Code or Antigravity, the run is a lead
// (an undelegated ticket run), and the spec is neither readonly nor no_tools.
// Only main agents run leads, so sub agents and chats never get it.
func ExplorerOn(spec Resolved, lead bool) bool {
	o := spec.HarnessOptions
	return lead && (spec.Harness == HarnessClaudeCode || spec.Harness == HarnessAntigravity) && o[OptionExplorer] != "false" &&
		o["readonly"] != "true" && o[OptionNoTools] != "true"
}

// Efforts are the allowed values of the "effort" harness option.
var Efforts = []string{"low", "medium", "high", "xhigh", "max"}

// CutEffortSuffix splits a trailing "-<effort>" suffix (such as
// "gemini-4-carbon-medium") into its base model slug and effort level.
func CutEffortSuffix(model string) (base, effort string, ok bool) {
	for _, e := range Efforts {
		if b, found := strings.CutSuffix(model, "-"+e); found && b != "" {
			return b, e, true
		}
	}
	return model, "", false
}

func validOptions(field string, opts map[string]string) error {
	if _, ok := opts[OptionWebSearch]; ok {
		return invalid(field, "%s is set by Vesper for the Personal Assistant only", OptionWebSearch)
	}
	if _, ok := opts[OptionImageGeneration]; ok {
		return invalid(field, "%s is set by Vesper for the Personal Assistant only", OptionImageGeneration)
	}
	if _, ok := opts[OptionAside]; ok {
		return invalid(field, "%s is set by Vesper for the Personal Assistant only", OptionAside)
	}
	if e, ok := opts["effort"]; ok && !slices.Contains(Efforts, e) {
		return invalid(field, "effort must be one of %s", strings.Join(Efforts, ", "))
	}
	return nil
}

func validMode(field string, m Mode) error {
	if m.rank() < 0 {
		return invalid(field, "mode must be allowed, requires_approval or denied")
	}
	return nil
}

func validScopes(field string, scopes map[string]Mode) error {
	for s, m := range scopes {
		if !scopeRe.MatchString(s) {
			return invalid(field, "%q is not a scope like repo:write or prod:*", s)
		}
		if err := validMode(field+"."+s, m); err != nil {
			return err
		}
	}
	return nil
}

func validBudget(field string, b Budget) error {
	if b.MaxRuntime != "" {
		d, err := time.ParseDuration(b.MaxRuntime)
		if err != nil || d <= 0 {
			return invalid(field+".max_runtime", "must be a duration like 2h or 45m")
		}
	}
	if b.MaxTurns < 0 {
		return invalid(field+".max_turns", "can't be negative")
	}
	return nil
}

func validMCP(field string, servers []MCPServer) error {
	seen := map[string]bool{}
	for _, s := range servers {
		if !nameRe.MatchString(s.Name) {
			return invalid(field, "server name %q must be lowercase letters, digits, - or _", s.Name)
		}
		if s.Name == ReservedMCPName || s.Name == SecretsMCPName {
			return invalid(field, "%q is reserved for a built-in server", s.Name)
		}
		if seen[s.Name] {
			return invalid(field, "duplicate server %q", s.Name)
		}
		seen[s.Name] = true
		if !strings.HasPrefix(s.URL, "http://") && !strings.HasPrefix(s.URL, "https://") {
			return invalid(field, "server %q needs an http(s) URL", s.Name)
		}
	}
	return nil
}

func validSkills(field string, skills []Skill) error {
	if len(skills) > MaxSkills {
		return invalid(field, "at most %d skills per agent", MaxSkills)
	}
	seen := map[string]bool{}
	for i := range skills {
		k := &skills[i]
		k.Name = strings.TrimSpace(k.Name)
		// Descriptions end up in YAML frontmatter and an index: one line.
		k.Description = strings.Join(strings.Fields(k.Description), " ")
		k.Body = strings.TrimSpace(k.Body)
		if !skillRe.MatchString(k.Name) {
			return invalid(field, "skill name %q must be lowercase letters, digits or -, up to 64 characters", k.Name)
		}
		if seen[k.Name] {
			return invalid(field, "duplicate skill %q", k.Name)
		}
		seen[k.Name] = true
		if k.Description == "" || len(k.Description) > MaxSkillDescription {
			return invalid(field, "skill %q needs a description of up to %d characters saying when to use it", k.Name, MaxSkillDescription)
		}
		if k.Body == "" {
			return invalid(field, "skill %q has no instructions", k.Name)
		}
		if len(k.Body) > MaxSkillBodyBytes {
			return invalid(field, "skill %q is over %d KB", k.Name, MaxSkillBodyBytes/1024)
		}
	}
	return nil
}

// Normalize fills defaults and validates. Saved specs are always normalized.
func (s *Spec) Normalize() error {
	if s.Harness == "" {
		s.Harness = HarnessClaudeCode
	}
	if !slices.Contains(Harnesses, s.Harness) {
		return invalid("harness", "must be one of %s", strings.Join(Harnesses, ", "))
	}
	if len(s.Fallbacks) > 8 {
		return invalid("fallbacks", "at most 8 targets")
	}
	seen := map[string]bool{s.Harness + "\x00" + strings.TrimSpace(s.Model): true}
	for i := range s.Fallbacks {
		f := &s.Fallbacks[i]
		f.Model = strings.TrimSpace(f.Model)
		if !slices.Contains(Harnesses, f.Harness) || f.Model == "" {
			return invalid("fallbacks", "each target needs a supported harness and a model")
		}
		if err := validOptions("fallbacks", f.HarnessOptions); err != nil {
			return err
		}
		key := f.Harness + "\x00" + f.Model
		if seen[key] {
			return invalid("fallbacks", "duplicate harness/model target")
		}
		seen[key] = true
	}
	s.Model = strings.TrimSpace(s.Model)
	if s.Model == "" {
		return invalid("model", "is required")
	}
	if s.MaxConcurrency == 0 {
		s.MaxConcurrency = 1
	}
	if s.MaxConcurrency < 1 || s.MaxConcurrency > 16 {
		return invalid("max_concurrency", "must be between 1 and 16")
	}
	if s.Scopes == nil {
		s.Scopes = map[string]Mode{}
	}
	if s.MCPServers == nil {
		s.MCPServers = []MCPServer{}
	}
	if s.HarnessOptions == nil {
		s.HarnessOptions = map[string]map[string]string{}
	}
	for h := range s.HarnessOptions {
		if !slices.Contains(Harnesses, h) {
			return invalid("harness_options", "unknown harness %q", h)
		}
		if err := validOptions("harness_options", s.HarnessOptions[h]); err != nil {
			return err
		}
	}
	if err := validScopes("scopes", s.Scopes); err != nil {
		return err
	}
	if err := validBudget("budget", s.Budget); err != nil {
		return err
	}
	if s.Memory == nil {
		m := DefaultMemory
		s.Memory = &m
	}
	switch s.Memory.Inject {
	case "":
		s.Memory.Inject = InjectSelective
	case InjectSelective, InjectIndex, InjectLinked, InjectSearch:
	default:
		return invalid("memory.inject", "must be selective, index, linked or search")
	}
	if s.Memory.MaxTokens == 0 {
		s.Memory.MaxTokens = DefaultMemory.MaxTokens
	}
	if s.Memory.MaxTokens < 500 || s.Memory.MaxTokens > 50000 {
		return invalid("memory.max_tokens", "must be between 500 and 50000")
	}
	if s.Skills == nil {
		s.Skills = []Skill{}
	}
	if err := validSkills("skills", s.Skills); err != nil {
		return err
	}
	return validMCP("mcp_servers", s.MCPServers)
}

func (o *Override) Normalize() error {
	if o.Harness != "" && !slices.Contains(Harnesses, o.Harness) {
		return invalid("harness", "must be one of %s", strings.Join(Harnesses, ", "))
	}
	o.Model = strings.TrimSpace(o.Model)
	if err := validScopes("scopes", o.Scopes); err != nil {
		return err
	}
	if err := validBudget("budget", o.Budget); err != nil {
		return err
	}
	if err := validMCP("mcp_servers_add", o.MCPServersAdd); err != nil {
		return err
	}
	if err := validSkills("skills_add", o.SkillsAdd); err != nil {
		return err
	}
	seenRemove := map[string]bool{}
	for i, n := range o.SkillsRemove {
		n = strings.TrimSpace(n)
		o.SkillsRemove[i] = n
		if !skillRe.MatchString(n) {
			return invalid("skills_remove", "skill name %q must be lowercase letters, digits or -, up to 64 characters", n)
		}
		if seenRemove[n] {
			return invalid("skills_remove", "duplicate skill %q", n)
		}
		seenRemove[n] = true
	}
	if err := validServices("services", o.Services); err != nil {
		return err
	}
	cleaned := o.Setup[:0]
	for _, c := range o.Setup {
		if c = strings.TrimSpace(c); c != "" {
			cleaned = append(cleaned, c)
		}
	}
	o.Setup = cleaned
	return nil
}

// sortedScopes returns scope names in a stable display order.
func sortedScopes(m map[string]Mode) []string {
	out := make([]string, 0, len(m))
	for s := range m {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

// MemoryOrDefault is the spec's memory settings, defaulted.
func (s Spec) MemoryOrDefault() Memory {
	if s.Memory == nil {
		return DefaultMemory
	}
	return *s.Memory
}

// Effort returns the primary harness's configured reasoning effort, or "".
func (s Spec) Effort() string {
	return s.HarnessOptions[s.Harness]["effort"]
}

// SetModel updates the primary harness, model, and effort, removing any matching
// fallback target so Normalize won't reject duplicate harness/model targets.
func (s *Spec) SetModel(harness, model, effort string) {
	if harness != "" && strings.TrimSpace(model) != "" {
		s.Harness = harness
		s.Model = strings.TrimSpace(model)
	}
	if len(s.Fallbacks) > 0 {
		kept := s.Fallbacks[:0]
		for _, f := range s.Fallbacks {
			if f.Harness == s.Harness && strings.TrimSpace(f.Model) == s.Model {
				continue
			}
			kept = append(kept, f)
		}
		s.Fallbacks = kept
	}
	if effort == "" {
		if opts := s.HarnessOptions[s.Harness]; len(opts) > 0 {
			delete(opts, "effort")
			if len(opts) == 0 {
				delete(s.HarnessOptions, s.Harness)
			}
		}
		return
	}
	if s.HarnessOptions == nil {
		s.HarnessOptions = map[string]map[string]string{}
	}
	if s.HarnessOptions[s.Harness] == nil {
		s.HarnessOptions[s.Harness] = map[string]string{}
	}
	s.HarnessOptions[s.Harness]["effort"] = effort
}

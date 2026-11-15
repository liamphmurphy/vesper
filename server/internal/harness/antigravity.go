package harness

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

//go:embed agy_policy.py
var agyPolicyHook []byte

//go:embed agy_launch.py
var agyLauncher []byte

const (
	agyPolicyPath = ".lazyagents/agy-policy.py"
	agyConfigPath = ".lazyagents/agy-config.json"
	agyLaunchPath = ".lazyagents/agy-launch.py"
)

// Antigravity runs `agy -p … --output-format stream-json`. Its contract
// (docs/contracts/antigravity.md) was recorded from agy 1.5.8 against a
// scripted Gemini endpoint; TestAgyProbe re-checks it against a real binary.
//
// Headless it authenticates with the saved native Antigravity login inside $HOME,
// reads MCP servers from ~/.gemini/config/mcp_config.json, and receives turn
// overrides via ~/.gemini/antigravity-cli/settings.json.
// asks the PreToolUse hook about every tool call. Two layers keep a turn
// inside its scopes, so a hook that fails to load still fails closed:
//   - settings.permissions.deny holds what the spec rules out whatever the hook
//     says (deny wins over every mode), and an unlisted action is "ask", which
//     headless agy soft-denies;
//   - the hook (agy_policy.py → runs.CheckTool) answers auto_approve only for
//     what Vesper's policy allows.
type Antigravity struct{}

func (Antigravity) Name() string { return agentdef.HarnessAntigravity }

// agyConfig is .lazyagents/agy-config.json, which agy_launch.py installs.
type agyConfig struct {
	// Install is set in a turn container, whose home is the turn's own.
	Install     bool           `json:"install"`
	TokenEnv    string         `json:"token_env"`
	HookCommand string         `json:"hook_command"`
	Settings    map[string]any `json:"settings"`
	MCPServers  map[string]any `json:"mcp_servers"`
}

func (Antigravity) Invocation(ws Workspace, t Turn) (Invocation, error) {
	spec := t.Spec
	env, err := hookEnvironmentAt(ws, agyPolicyPath)
	if err != nil {
		return Invocation{}, err
	}
	env[ws.TokenEnv] = ws.Token
	noTools := spec.HarnessOptions[agentdef.OptionNoTools] == "true"

	servers := map[string]any{}
	var allow []string
	addServer := func(name, url string, bearer bool, timeout int) {
		s := map[string]any{"serverUrl": url}
		if bearer {
			s["headers"] = map[string]string{"Authorization": "Bearer {{token}}"}
		}
		if timeout > 0 {
			s["timeoutSeconds"] = timeout
		}
		servers[name] = s
		// Vesper enforces each of its tools' scopes (and a connector tool's
		// approval) itself; without a rule agy would ask, and headless asks are denied.
		allow = append(allow, "mcp("+name+"/*)")
	}
	if !noTools {
		addServer(lazyagentsServer, ws.MCPURL, true, 0)
	}
	for _, m := range spec.MCPServers {
		if m.Connector {
			addServer(m.Name, ws.MCPURL+"/connectors/"+m.Name, true, 2400)
			continue
		}
		addServer(m.Name, m.URL, false, 0)
	}

	cfg := agyConfig{
		Install: ws.ContainerSandbox, TokenEnv: ws.TokenEnv, HookCommand: env["LAZYAGENTS_POLICY_HOOK_COMMAND"], MCPServers: servers,
		Settings: map[string]any{
			"toolPermission":        "request-review",
			"agentMode":             "",    // Default mode; agy 1.5.7+ otherwise defaults to "auto" (which forces terminal sandbox)
			"enableTerminalSandbox": false, // the container is the boundary, as for Codex
			"trustedWorkspaces":     []string{ws.Dir},
			"permissions":           map[string]any{"allow": nonNil(allow), "ask": []string{}, "deny": agyDenyRules(spec)},
		},
	}
	body, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return Invocation{}, err
	}

	prompt := t.Prompt
	if !noTools {
		// agy has no documented AGENTS.md convention; say where the instructions are.
		prompt = "Your instructions are in AGENTS.md in the workspace root: read it first and follow it.\n\n" + prompt
		if note := agyImageNote(t.Images); note != "" {
			prompt += "\n\n" + note
		}
	}
	argv := []string{"python3", agyLaunchPath, "agy", "-p", prompt, "--output-format", "stream-json"}
	model := spec.Model
	effort := spec.HarnessOptions["effort"]
	if effort != "" {
		// Legacy chats or definitions may carry an effort suffix like
		// "gemini-4-carbon-medium", which conflicts with `--effort` in agy.
		if base, _, ok := agentdef.CutEffortSuffix(model); ok {
			model = base
		}
	}
	if model != "" {
		argv = append(argv, "--model", model)
	}
	if effort != "" {
		argv = append(argv, "--effort", effort)
	}
	if t.SessionID != "" {
		argv = append(argv, "--conversation", t.SessionID)
	}

	files := SkillFilesFor(spec.Skills, agentdef.HarnessAntigravity) // agy 1.5.8 lists .agents/skills/*/SKILL.md to the model
	files[agyPolicyPath] = agyPolicyHook
	files[agyLaunchPath] = agyLauncher
	files[agyConfigPath] = body
	return Invocation{Argv: argv, Env: env, Files: files}, nil
}

func nonNil(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// agyDenyRules are the permission rules a spec rules out regardless of the hook.
// Deny > ask > allow, and deny applies in every mode (docs/permissions).
func agyDenyRules(spec agentdef.Resolved) []string {
	o := spec.HarnessOptions
	if o[agentdef.OptionNoTools] == "true" {
		return []string{"command(*)", "read_file(*)", "write_file(*)", "read_url(*)", "execute_url(*)", "mcp(*)"}
	}
	var deny []string
	if o["readonly"] == "true" || (!allowed(spec, "tests:run") && !allowed(spec, "repo:write")) {
		deny = append(deny, "command(*)")
	}
	// An image step's generator saves outside the workspace; the hook holds it
	// to the image tool, so a blanket write rule would only break it.
	if !allowed(spec, "repo:write") && o[agentdef.OptionImageGeneration] != "true" {
		deny = append(deny, "write_file(*)")
	}
	if o[agentdef.OptionWebSearch] != "true" && !allowed(spec, "web:read") {
		deny = append(deny, "read_url(*)", "execute_url(*)")
	}
	return nonNil(deny)
}

// agyImageNote points agy at reference images, which its stream input can't
// carry (text blocks only): it opens them with its file viewer.
func agyImageNote(images []string) string {
	if len(images) == 0 {
		return ""
	}
	return "Reference images (open each with your file viewer): " + strings.Join(images, ", ")
}

// hookEnvironmentAt is hookEnvironment for a hook script other than the shared one.
func hookEnvironmentAt(ws Workspace, rel string) (map[string]string, error) {
	env, err := hookEnvironment(ws)
	if err != nil {
		return nil, err
	}
	hookPath, err := filepath.Abs(filepath.Join(ws.Dir, rel))
	if err != nil {
		return nil, fmt.Errorf("harness: resolve policy hook path: %w", err)
	}
	env["LAZYAGENTS_POLICY_HOOK_PATH"] = hookPath
	env["LAZYAGENTS_POLICY_HOOK_COMMAND"] = "python3 '" + strings.ReplaceAll(hookPath, "'", "'\"'\"'") + "'"
	return env, nil
}

func (Antigravity) NewParser(model string) Parser { return &agyParser{model: model} }

// ---------------------------------------------------------------- stream

type agyUsage struct {
	InputTokens     int64 `json:"input_tokens"`  // without the cache reads
	OutputTokens    int64 `json:"output_tokens"` // with the thinking tokens
	CacheReadTokens int64 `json:"cache_read_tokens"`
}

type agyToolInfo struct {
	Name       string          `json:"name"`
	Parameters json.RawMessage `json:"parameters"`
	Output     json.RawMessage `json:"output"`
	Error      *struct {
		Type    string `json:"type"`
		Message string `json:"message"`
	} `json:"error"`
}

type agyStep struct {
	ConversationID string       `json:"conversation_id"`
	StepIndex      int          `json:"step_index"`
	State          string       `json:"state"` // ACTIVE, then DONE or ERROR
	StepType       string       `json:"step_type"`
	ToolName       string       `json:"tool_name"`
	TextDelta      string       `json:"text_delta"`
	ToolInfo       *agyToolInfo `json:"tool_info"`
	// Usage is set on each finished agent_response step: one model request.
	Usage        *agyUsage `json:"usage"`
	SubagentInfo *struct {
		Subagents []struct {
			TypeName      string `json:"type_name"`
			Role          string `json:"role"`
			InitialPrompt string `json:"initial_prompt"`
		} `json:"subagents"`
	} `json:"subagent_info"`
}

// agyEnvelope is the final result, also the shape of `--output-format json`.
type agyEnvelope struct {
	ConversationID string `json:"conversation_id"`
	Status         string `json:"status"`
	Response       string `json:"response"`
	Error          string `json:"error"`
}

type agyLine struct {
	Event string `json:"event"`
	Init  *struct {
		Model          string `json:"model"`
		PermissionMode string `json:"permission_mode"`
	} `json:"init"`
	StepUpdate *agyStep     `json:"step_update"`
	Result     *agyEnvelope `json:"result"`
	agyEnvelope
}

type agyParser struct {
	model   string
	res     Result
	text    map[int]*strings.Builder // agent_response text by step, until the step is done
	order   []int
	called  map[int]bool
	sawText bool
	done    bool
	// stepUsage sums this process's requests. result.usage can't be used when
	// it exists: it is cumulative over a resumed conversation.
	stepUsage *agyUsage
	context   int64 // prompt size of the latest request
}

var agyImagePath = regexp.MustCompile(`(/[^\s"'<>` + "`" + `\\]+\.(?:png|jpe?g|webp|gif))`)

func (p *agyParser) Line(b []byte) []Event {
	line := strings.TrimSpace(string(b))
	// agy prints a failed turn to stderr as "AGY_ERROR: {...}" too, after the
	// result line; this reads it should the line reach the parser.
	if rest, ok := strings.CutPrefix(line, "AGY_ERROR:"); ok {
		msg := strings.TrimSpace(rest)
		var e struct {
			ShortError string `json:"short_error"`
		}
		if json.Unmarshal([]byte(msg), &e) == nil && e.ShortError != "" {
			msg = e.ShortError
		}
		return p.fail(msg)
	}
	var l agyLine
	if err := json.Unmarshal(b, &l); err != nil || l.Event == "" {
		return nil
	}
	switch l.Event {
	case "init":
		if l.ConversationID != "" {
			p.res.SessionID = l.ConversationID
		}
		model := p.model
		if l.Init != nil && l.Init.Model != "" {
			model = l.Init.Model
		}
		return []Event{{"lifecycle", map[string]any{"state": "harness_started", "harness": agentdef.HarnessAntigravity, "model": model, "session_id": p.res.SessionID}}}
	case "step_update":
		if l.StepUpdate == nil {
			return nil
		}
		return p.step(*l.StepUpdate)
	case "result":
		env := l.agyEnvelope
		if l.Result != nil {
			env = *l.Result
		}
		return p.finish(env)
	}
	return nil
}

func (p *agyParser) step(s agyStep) []Event {
	var out []Event
	if s.ConversationID != "" && p.res.SessionID == "" {
		p.res.SessionID = s.ConversationID
	}
	// A step that ended carries its final tool info; DONE and ERROR both end one.
	ended := s.State != "" && s.State != "ACTIVE"
	switch s.StepType {
	case "agent_response":
		if u := s.Usage; u != nil && ended {
			p.addStepUsage(*u)
		}
		if p.text == nil {
			p.text = map[int]*strings.Builder{}
		}
		if p.text[s.StepIndex] == nil {
			p.text[s.StepIndex] = &strings.Builder{}
			p.order = append(p.order, s.StepIndex)
		}
		p.text[s.StepIndex].WriteString(s.TextDelta)
		if ended {
			out = append(out, p.flush(s.StepIndex)...)
		}
	case "tool", "subagent":
		name := s.ToolName
		if s.ToolInfo != nil && s.ToolInfo.Name != "" {
			name = s.ToolInfo.Name
		}
		if s.StepType == "subagent" && s.ToolInfo == nil {
			// A subagent step reports what it was asked in subagent_info, and
			// ends without output or error text: the model is told why.
			info := &agyToolInfo{Name: name}
			if si := s.SubagentInfo; si != nil && len(si.Subagents) > 0 {
				a := si.Subagents[0]
				info.Parameters, _ = json.Marshal(map[string]string{"TypeName": a.TypeName, "Role": a.Role, "Prompt": a.InitialPrompt})
			}
			if s.State == "ERROR" {
				info.Error = &struct {
					Type    string `json:"type"`
					Message string `json:"message"`
				}{Type: "SUBAGENT_ERROR", Message: "the subagent did not run"}
			}
			s.ToolInfo = info
		}
		if name == "" {
			return out
		}
		if p.called == nil {
			p.called = map[int]bool{}
		}
		id := "agy_step_" + strconv.Itoa(s.StepIndex)
		var input map[string]any
		if s.ToolInfo != nil && len(s.ToolInfo.Parameters) > 0 {
			_ = json.Unmarshal(s.ToolInfo.Parameters, &input)
		}
		tool, canon := antigravityTool(name, input)
		tool = strings.TrimPrefix(strings.TrimPrefix(tool, "mcp__"+lazyagentsServer+"_"), "_") // Vesper's own tools read as in Codex's events
		if !p.called[s.StepIndex] && (s.ToolInfo != nil || ended) {
			p.called[s.StepIndex] = true
			p.res.Usage.ToolCalls++
			out = append(out, Event{"tool_call", map[string]any{"id": id, "tool": tool, "input": canon}})
		}
		if ended && s.ToolInfo != nil {
			output := rawText(s.ToolInfo.Output)
			isErr := s.ToolInfo.Error != nil
			if isErr {
				output = s.ToolInfo.Error.Message
			}
			p.noteImages(output)
			out = append(out, Event{"tool_result", map[string]any{"id": id, "tool": tool, "is_error": isErr, "output": clip(output, 4000)}})
		}
	}
	return out
}

// rawText is a tool's output as text: a JSON string unquoted, anything else as written.
func rawText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	if string(raw) == "null" {
		return ""
	}
	return string(raw)
}

func (p *agyParser) flush(index int) []Event {
	b := p.text[index]
	if b == nil {
		return nil
	}
	delete(p.text, index)
	text := b.String()
	if strings.TrimSpace(text) == "" {
		return nil
	}
	p.sawText = true
	p.res.Final = text
	return []Event{{"message", map[string]any{"role": "assistant", "text": text}}}
}

// noteImages remembers image files a tool says it saved, for the runner to
// collect (Result.Images). The runner only reads them from under agy's own home.
func (p *agyParser) noteImages(s string) {
	for _, m := range agyImagePath.FindAllString(s, 8) {
		if len(p.res.Images) < 8 && !contains(p.res.Images, m) {
			p.res.Images = append(p.res.Images, m)
		}
	}
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// addStepUsage counts one model request. agy's input_tokens leave out the
// cache reads and its output_tokens already include thinking (recorded against
// a stub with known Gemini usageMetadata), so Vesper's input is their sum.
func (p *agyParser) addStepUsage(u agyUsage) {
	if p.stepUsage == nil {
		p.stepUsage = &agyUsage{}
	}
	p.stepUsage.InputTokens += u.InputTokens
	p.stepUsage.OutputTokens += u.OutputTokens
	p.stepUsage.CacheReadTokens += u.CacheReadTokens
	p.context = u.InputTokens + u.CacheReadTokens
}

func (p *agyParser) fail(msg string) []Event {
	if msg == "" {
		msg = "agy failed"
	}
	p.res.IsError, p.res.Error = true, msg
	p.res.UsageLimited = p.res.UsageLimited || UsageLimit(msg)
	return []Event{{"error", map[string]any{"message": msg}}}
}

func (p *agyParser) finish(env agyEnvelope) []Event {
	if p.done {
		return nil
	}
	p.done = true
	var out []Event
	// A step that never reported DONE still carries text.
	pending := append([]int(nil), p.order...)
	sort.Ints(pending)
	for _, i := range pending {
		out = append(out, p.flush(i)...)
	}
	if env.ConversationID != "" {
		p.res.SessionID = env.ConversationID
	}
	if !p.sawText && strings.TrimSpace(env.Response) != "" {
		p.sawText, p.res.Final = true, env.Response
		out = append(out, Event{"message", map[string]any{"role": "assistant", "text": env.Response}})
	}
	// Only the steps count: result.usage also holds a resumed conversation's
	// earlier turns, and no step usage means no request finished.
	if u := p.stepUsage; u != nil {
		p.res.Usage.SessionID = p.res.SessionID
		p.res.Usage.InputTokens = u.InputTokens + u.CacheReadTokens
		p.res.Usage.OutputTokens = u.OutputTokens
		p.res.Usage.CachedTokens = u.CacheReadTokens
		p.res.Usage.CacheReportedInputTokens = p.res.Usage.InputTokens
		p.res.Usage.ContextTokens = p.context
		// agy reports tokens but no cost, and Vesper keeps no Gemini price list.
		p.res.Usage.CostSource = "unknown"
		out = append(out, Event{"usage", map[string]any{"input_tokens": p.res.Usage.InputTokens, "output_tokens": p.res.Usage.OutputTokens,
			"cached_tokens": p.res.Usage.CachedTokens, "cache_reported_input_tokens": p.res.Usage.CacheReportedInputTokens, "cost_source": "unknown", "cost_known": false}})
	}
	if env.Status != "" && env.Status != "SUCCESS" {
		msg := env.Error
		if msg == "" {
			msg = "agy ended with status " + env.Status
		}
		out = append(out, p.fail(msg)...)
	}
	return out
}

func (p *agyParser) Result() Result { return p.res }

// ---------------------------------------------------------------- tool names

// antigravityTool renames one of agy's tool calls to the names Claude Code's
// events and Vesper's policy use, so the activity scenes and CheckTool need no
// second vocabulary. Unknown tools keep their name (CheckTool then requires
// tests:run for them: unrecognized means restricted). agy_policy.py's
// canonical() must agree; TestAgyPolicyHookAgreesWithTheParser runs both.
func antigravityTool(name string, args map[string]any) (string, map[string]any) {
	str := func(keys ...string) string {
		for _, k := range keys {
			if v, ok := args[k].(string); ok && v != "" {
				return v
			}
		}
		return ""
	}
	pathKeys := []string{"AbsolutePath", "TargetFile", "file_path", "path", "Path", "DirectoryPath", "SearchPath"}
	// The names agy 1.5.8 declares to the model come first; the others are its
	// internal names (init's tool list), kept in case a step reports one.
	switch name {
	case "run_command":
		return "Bash", map[string]any{"command": str("CommandLine", "command", "cmd")}
	case "read_file", "view_file", "view_file_outline":
		return "Read", map[string]any{"file_path": str(pathKeys...)}
	case "write_file", "write_to_file", "create_file":
		return "Write", map[string]any{"file_path": str(pathKeys...)}
	case "call_mcp_tool":
		// Every MCP tool goes through this one: name it as Claude Code would, so
		// the policy governs it as an MCP tool rather than an unknown one.
		server, tool := str("ServerName"), str("ToolName")
		if server == "" || tool == "" {
			return name, args
		}
		input, _ := args["Arguments"].(map[string]any)
		return "mcp__" + server + "__" + tool, input
	case "invoke_subagent", "define_subagent", "manage_subagents", "swarm", "send_message":
		// Other agents, which Vesper's policy refuses as it does Claude Code's
		// (only its explorer, which agy doesn't have), except image-generator in image steps.
		out := map[string]any{"description": str("Role", "Name", "TypeName", "action")}
		if name == "invoke_subagent" {
			if st := str("TypeName"); st != "" {
				out["subagent_type"] = st
			}
		}
		return "Agent", out
	case "replace_file_content", "multi_replace_file_content", "edit_file":
		return "Edit", map[string]any{"file_path": str(pathKeys...)}
	case "list_dir":
		return "LS", map[string]any{"path": str(pathKeys...)}
	case "grep_search":
		return "Grep", map[string]any{"pattern": str("Query", "query", "pattern"), "path": str(pathKeys...)}
	case "find_by_name":
		return "Glob", map[string]any{"pattern": str("Pattern", "pattern"), "path": str(pathKeys...)}
	case "search_web":
		return "WebSearch", map[string]any{"query": str("query", "Query")}
	case "read_url_content":
		return "WebFetch", map[string]any{"url": str("Url", "url", "URL")}
	}
	if m := agyMCPName.FindStringSubmatch(name); m != nil {
		return "mcp__" + m[1], args
	}
	return name, args
}

var agyMCPName = regexp.MustCompile(`^mcp[_./:-]+(.+)$`)

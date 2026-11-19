package harness

import (
	"encoding/base64"
	"encoding/json"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// ClaudeCode runs `claude -p --output-format stream-json` (checked against
// Claude Code 2.1.316). Instructions come from AGENTS.md, MCP from a
// generated --mcp-config, tool rules from scopes.
// ClaudeCode runs the claude CLI. Baseline is the previous turn's usage in
// the same session: a resumed session reports total_cost_usd for the whole
// session, so the turn's cost is the difference.
type ClaudeCode struct {
	Baseline Usage
}

func (ClaudeCode) Name() string { return agentdef.HarnessClaudeCode }

const (
	claudeMCPFile    = ".lazyagents/mcp.json"
	claudeAgentsFile = ".lazyagents/claude-agents.json"
)

// claudePrivacyEnv keeps the CLI from sending anything beyond the model
// requests themselves (names checked against Claude Code 2.1.316). Vesper owns
// memory, so the CLI's own auto-memory is off too: it would be a second,
// unsynced store inside the workspace. These are set one by one rather than
// via CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, which would also stop the
// autoupdater of a local runner's shared install.
var claudePrivacyEnv = map[string]string{
	"DISABLE_TELEMETRY":                   "1", // Statsig usage metrics
	"DISABLE_ERROR_REPORTING":             "1", // Sentry error reports
	"DISABLE_BUG_COMMAND":                 "1", // /bug transcript uploads
	"CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY": "1",
	"CLAUDE_CODE_DISABLE_AUTO_MEMORY":     "1",
}

type mcpEntry struct {
	Type    string            `json:"type"`
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers,omitempty"`
}

func (ClaudeCode) Invocation(ws Workspace, t Turn) (Invocation, error) {
	spec := t.Spec
	env, err := hookEnvironment(ws)
	if err != nil {
		return Invocation{}, err
	}
	env[ws.TokenEnv] = ws.Token
	for k, v := range claudePrivacyEnv {
		env[k] = v
	}
	servers := map[string]mcpEntry{
		// The run token is written into the (git-excluded) config; it's
		// revoked when the run ends.
		lazyagentsServer: {Type: "http", URL: ws.MCPURL, Headers: map[string]string{"Authorization": "Bearer " + ws.Token}},
	}
	for _, m := range spec.MCPServers {
		if m.Connector {
			servers[m.Name] = mcpEntry{Type: "http", URL: ws.MCPURL + "/connectors/" + m.Name, Headers: map[string]string{"Authorization": "Bearer " + ws.Token}}
			continue
		}
		servers[m.Name] = mcpEntry{Type: "http", URL: m.URL}
	}
	noTools := spec.HarnessOptions[agentdef.OptionNoTools] == "true"
	if noTools {
		servers = map[string]mcpEntry{}
	}
	cfg, err := json.MarshalIndent(map[string]any{"mcpServers": servers}, "", "  ")
	if err != nil {
		return Invocation{}, err
	}

	// "readonly" (planning runs) is enforced by the tool allow/deny lists
	// below. It must not use Claude's own "plan" permission mode: that mode
	// withholds approval for MCP tools, so propose_tickets is denied headless.
	readonly := spec.HarnessOptions["readonly"] == "true"
	mode := spec.HarnessOptions["permission_mode"]
	if mode == "" || mode == "plan" {
		mode = "acceptEdits"
		if readonly {
			mode = "default"
		}
	}
	allow := []string{"mcp__" + lazyagentsServer, "Read", "Edit", "Write", "Glob", "Grep", "TodoWrite", "TaskCreate", "TaskUpdate", "Skill", "ToolSearch"}
	for _, m := range spec.MCPServers {
		allow = append(allow, "mcp__"+m.Name)
	}
	// Shell access backs tests and git; it's granted when either scope is.
	if spec.Mode("tests:run") != agentdef.Denied || spec.Mode("repo:write") != agentdef.Denied || spec.Mode("repo:read") != agentdef.Denied {
		allow = append(allow, "Bash")
	}
	// Web tools need web:read; requires_approval goes through the policy hook.
	if spec.Mode("web:read") != agentdef.Denied {
		allow = append(allow, "WebFetch", "WebSearch")
	}
	var deny []string
	if readonly {
		allow = []string{"mcp__" + lazyagentsServer, "Read", "Glob", "Grep", "ToolSearch"}
		for _, m := range spec.MCPServers {
			if m.Connector {
				allow = append(allow, "mcp__"+m.Name)
			}
		}
		// The web tools are handled below: a denied tool beats an allowed one.
		deny = append(deny, "Edit", "Write", "NotebookEdit", "Bash", "Agent")
	}
	// The assistant's web_search option grants web tools even to read-only
	// chat; otherwise read-only runs never get the web.
	if spec.HarnessOptions[agentdef.OptionWebSearch] == "true" {
		allow = append(allow, "WebSearch", "WebFetch")
	} else if readonly || spec.Mode("web:read") == agentdef.Denied {
		deny = append(deny, "WebSearch", "WebFetch")
	}
	if denied(spec, "repo:write") {
		deny = append(deny, "Bash(git push:*)", "Bash(gh pr create:*)")
	}
	explorer := agentdef.ExplorerOn(spec, t.Lead)
	var agents []byte
	if explorer {
		// The policy hook still allows only the explorer (runs.CheckTool).
		allow = append(allow, "Agent")
		model := spec.HarnessOptions[agentdef.OptionExplorerModel]
		if model == "" {
			model = agentdef.DefaultExplorerModel
		}
		if agents, err = json.MarshalIndent(map[string]any{agentdef.ExplorerAgent: map[string]any{
			"description": "Read-only code search. Use it for any question that needs a broad grep or reading more than about three files, when you need the conclusion and not the file contents.",
			"prompt":      "Answer the question from the code. Reply in at most 300 words with file:line references. Never paste whole files or long excerpts. Say what you could not find.",
			"tools":       []string{"Read", "Grep", "Glob"},
			"model":       AnthropicModel(model),
		}}, "", "  "); err != nil {
			return Invocation{}, err
		}
	}

	argv := []string{"claude", "-p", t.Prompt,
		"--output-format", "stream-json", "--verbose",
		"--model", AnthropicModel(spec.Model),
		"--mcp-config", claudeMCPFile, "--strict-mcp-config",
		"--permission-mode", mode,
		// Nobody answers prompts headless: anything not allowed is denied
		// and the agent is told to use request_approval.
		"--permission-prompts", "none",
		"--settings", ".lazyagents/claude-settings.json",
		// Skip the host's user settings: on the fake runner HOME is the
		// host's, and a user-level "agent", plugins or permissions would
		// replace this run's tools and prompt. Login isn't a setting source.
		"--setting-sources", "project,local",
		"--allowedTools", strings.Join(allow, ","),
	}
	if len(deny) > 0 {
		argv = append(argv, "--disallowedTools", strings.Join(deny, ","))
	}
	if explorer {
		argv = append(argv, "--agents", claudeAgentsFile)
	}
	if noTools {
		argv = append(argv, "--tools", "")
	} else {
		// Lets the chat see rich blocks being written; messages still arrive whole.
		argv = append(argv, "--include-partial-messages")
	}
	if t.SessionID != "" {
		argv = append(argv, "--resume", t.SessionID)
	}
	// The flag, not settings: it takes every level (settings files refuse max)
	// and applies per invocation, so a chat can change it between turns.
	if effort := spec.HarnessOptions["effort"]; effort != "" {
		argv = append(argv, "--effort", effort)
	}
	files := SkillFiles(spec.Skills)
	if len(t.InlineImages) > 0 {
		input, err := claudeImageMessage(t.Prompt, t.InlineImages)
		if err != nil {
			return Invocation{}, err
		}
		files[claudeInputFile] = input
		// Images need the stream-json message form, read from stdin (checked
		// against claude 2.1.311), so the prompt moves out of the arguments.
		argv = append([]string{"sh", "-c", `exec "$@" < ` + claudeInputFile, "lazyagents-claude-input", argv[0], argv[1]}, argv[3:]...)
		argv = append(argv, "--input-format", "stream-json")
	}
	files[claudeMCPFile] = cfg
	if explorer {
		files[claudeAgentsFile] = agents
	}
	files[toolHookPath] = toolHook
	settingsDoc := map[string]any{"hooks": map[string]any{"PreToolUse": []any{map[string]any{"matcher": "*", "hooks": []any{map[string]any{"type": "command", "command": env["LAZYAGENTS_POLICY_HOOK_COMMAND"], "timeout": 20}}}}}}
	settings, _ := json.Marshal(settingsDoc)
	files[".lazyagents/claude-settings.json"] = settings
	return Invocation{
		Argv:  argv,
		Env:   env,
		Files: files,
	}, nil
}

func (c ClaudeCode) NewParser(string) Parser {
	return &claudeParser{tools: map[string]string{}, baseline: c.Baseline}
}

type claudeParser struct {
	res      Result
	tools    map[string]string // tool_use id → name
	baseline Usage
	reply    replyScanner
	activity activityTracker
}

type claudeLine struct {
	Type      string          `json:"type"`
	Error     string          `json:"error"`
	Subtype   string          `json:"subtype"`
	SessionID string          `json:"session_id"`
	Model     string          `json:"model"`
	Message   json.RawMessage `json:"message"`
	// stream_event: a piece of the message being written; nil parent is the main agent
	Event  json.RawMessage `json:"event"`
	Parent *string         `json:"parent_tool_use_id"`
	// result
	IsError    bool                            `json:"is_error"`
	Result     string                          `json:"result"`
	TotalCost  *float64                        `json:"total_cost_usd"`
	NumTurns   int                             `json:"num_turns"`
	DurationMS int64                           `json:"duration_ms"`
	Terminal   string                          `json:"terminal_reason"`
	Usage      *claudeUsage                    `json:"usage"`
	Denials    []json.RawMessage               `json:"permission_denials"`
	MCPServers []struct{ Name, Status string } `json:"mcp_servers"`
	// rate_limit_event
	RateLimitInfo json.RawMessage `json:"rate_limit_info"`
}

type claudeUsage struct {
	InputTokens         int64  `json:"input_tokens"`
	OutputTokens        int64  `json:"output_tokens"`
	CacheReadTokens     *int64 `json:"cache_read_input_tokens"`
	CacheCreationTokens int64  `json:"cache_creation_input_tokens"`
}

type claudeBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	Content   json.RawMessage `json:"content"`
	IsError   bool            `json:"is_error"`
}

func (p *claudeParser) streamEvent(l claudeLine) []Event {
	var ev struct {
		Type         string `json:"type"`
		ContentBlock struct {
			Type string `json:"type"`
		} `json:"content_block"`
		Delta struct {
			Type     string `json:"type"`
			Text     string `json:"text"`
			Thinking string `json:"thinking"`
		} `json:"delta"`
	}
	if l.Parent != nil || json.Unmarshal(l.Event, &ev) != nil {
		return nil
	}
	switch ev.Type {
	case "content_block_start":
		switch ev.ContentBlock.Type {
		case "thinking":
			return p.activity.thinkingStart()
		case "tool_use":
			p.activity.toolInputStartNow()
		default:
			p.reply = replyScanner{}
			p.activity.resetText()
		}
	case "content_block_delta":
		switch ev.Delta.Type {
		case "thinking_delta":
			return p.activity.thinkingDelta(ev.Delta.Thinking)
		case "text_delta":
			var out []Event
			if blocks := p.reply.feed(ev.Delta.Text); len(blocks) > 0 {
				p.activity.touch()
				out = append(out, blocks...)
			}
			if !p.reply.inFence {
				out = append(out, p.activity.textDelta(ev.Delta.Text)...)
			} else if len(out) == 0 {
				out = append(out, p.activity.heartbeatIfDue("writing_reply")...)
			}
			return out
		case "input_json_delta":
			return p.activity.toolInputDelta()
		}
	}
	return nil
}

func (p *claudeParser) Line(b []byte) []Event {
	var l claudeLine
	if err := json.Unmarshal(b, &l); err != nil || l.Type == "" {
		return nil // stderr noise or a partial line; the raw log keeps it
	}
	if l.SessionID != "" {
		p.res.SessionID = l.SessionID
	}
	if UsageLimit(l.Error) || (l.Type == "result" && l.IsError && UsageLimit(l.Result+" "+l.Terminal)) {
		p.res.UsageLimited = true
	}
	switch l.Type {
	case "rate_limit_event":
		if len(l.RateLimitInfo) > 0 && string(l.RateLimitInfo) != "null" {
			p.res.RateLimits = append(p.res.RateLimits, l.RateLimitInfo)
		}
		return nil
	case "stream_event":
		return p.streamEvent(l)
	case "system":
		if l.Subtype != "init" {
			return nil
		}
		pl := map[string]any{"state": "harness_started", "harness": agentdef.HarnessClaudeCode, "model": l.Model, "session_id": l.SessionID}
		for _, m := range l.MCPServers {
			if m.Status != "connected" {
				return []Event{{"lifecycle", pl}, {"error", map[string]any{"message": "MCP server " + m.Name + " is " + m.Status}}}
			}
		}
		return []Event{{"lifecycle", pl}}
	case "assistant", "user":
		// Blocks are decoded straight from the message: one pass over what
		// can be a large tool result instead of two.
		var msg struct {
			Content []claudeBlock `json:"content"`
			Usage   *claudeUsage  `json:"usage"`
		}
		sub := l.Parent != nil // a sub agent's message, on the main stream
		err := json.Unmarshal(l.Message, &msg)
		var reqContext int64 // this request's prompt size, stamped on its tool calls
		if l.Type == "assistant" && !sub && err == nil && msg.Usage != nil {
			// This request's prompt size; only the main agent's counts.
			var cached int64
			if msg.Usage.CacheReadTokens != nil {
				cached = *msg.Usage.CacheReadTokens
			}
			if n := msg.Usage.InputTokens + cached + msg.Usage.CacheCreationTokens; n > 0 {
				p.res.Usage.ContextTokens = n
				reqContext = n
			}
		}
		if err != nil {
			var raw struct {
				Content json.RawMessage `json:"content"`
			}
			if json.Unmarshal(l.Message, &raw) != nil {
				return nil
			}
			var s string // user messages can be a plain string
			if json.Unmarshal(raw.Content, &s) == nil && s != "" && l.Type == "assistant" && !sub {
				p.res.Final = s
				return []Event{{"message", map[string]any{"role": "assistant", "text": s}}}
			}
			return nil
		}
		var out []Event
		for _, bl := range msg.Content {
			switch bl.Type {
			case "text":
				// A sub agent's text is its report to the main agent, which
				// arrives as the Agent tool's result: never the reply.
				if l.Type == "assistant" && !sub && strings.TrimSpace(bl.Text) != "" {
					p.activity.reset()
					p.res.Final = bl.Text
					out = append(out, Event{"message", map[string]any{"role": "assistant", "text": bl.Text}})
				}
			case "thinking":
				// Kept for the Activity tab; never the reply. Redacted or
				// summarised-away thinking arrives empty and is skipped.
				if ev, ok := thinkingEvent(bl.Thinking); ok && l.Type == "assistant" && !sub {
					out = append(out, ev)
				}
			case "tool_use":
				p.tools[bl.ID] = bl.Name
				var input any
				_ = json.Unmarshal(bl.Input, &input)
				pl := map[string]any{"id": bl.ID, "tool": bl.Name, "input": input}
				if sub {
					p.res.Usage.SubagentToolCalls++
					pl["subagent"] = true
				} else {
					p.activity.reset()
					p.res.Usage.ToolCalls++
					if reqContext > 0 { // per-call context growth, for run analysis
						pl["context_tokens"] = reqContext
					}
				}
				out = append(out, Event{"tool_call", pl})
			case "tool_result":
				text := blockText(bl.Content)
				pl := map[string]any{"id": bl.ToolUseID, "tool": p.tools[bl.ToolUseID], "is_error": bl.IsError, "output": clip(text, 4000)}
				if sub { // a sub agent's results never enter the main context
					pl["subagent"] = true
				} else {
					p.activity.reset()
					p.res.Usage.AddToolOutput(p.tools[bl.ToolUseID], int64(len(text)))
				}
				out = append(out, Event{"tool_result", pl})
			}
		}
		return out
	case "result":
		p.res.IsError = l.IsError
		if l.Result != "" && !l.IsError {
			p.res.Final = l.Result
		}
		if l.IsError {
			p.res.Error = l.Result
			if p.res.Error == "" {
				p.res.Error = l.Terminal
			}
		}
		if l.Usage != nil {
			cached := int64(0)
			if l.Usage.CacheReadTokens != nil {
				cached = *l.Usage.CacheReadTokens
			}
			p.res.Usage.InputTokens = l.Usage.InputTokens + l.Usage.CacheCreationTokens + cached
			p.res.Usage.CachedTokens = cached
			if l.Usage.CacheReadTokens != nil && cached >= 0 && cached <= p.res.Usage.InputTokens {
				p.res.Usage.CacheReportedInputTokens = p.res.Usage.InputTokens
			}
			p.res.Usage.OutputTokens = l.Usage.OutputTokens
		}
		p.res.Usage.CostSource = "unknown"
		var cost any
		if l.TotalCost != nil {
			// Token counts are per process, but total_cost_usd covers the
			// whole session, earlier resumed turns included.
			base := p.baseline.SessionCostUSD
			if p.baseline.SessionID != p.res.SessionID || *l.TotalCost < base {
				base = 0
			}
			p.res.Usage.CostUSD, p.res.Usage.CostSource = *l.TotalCost-base, "harness"
			p.res.Usage.SessionID, p.res.Usage.SessionCostUSD = p.res.SessionID, *l.TotalCost
			cost = p.res.Usage.CostUSD
		}
		out := []Event{{"usage", map[string]any{
			"input_tokens": p.res.Usage.InputTokens, "output_tokens": p.res.Usage.OutputTokens, "cached_tokens": p.res.Usage.CachedTokens, "cache_reported_input_tokens": p.res.Usage.CacheReportedInputTokens,
			"cost_usd": cost, "cost_source": p.res.Usage.CostSource, "cost_known": l.TotalCost != nil, "num_turns": l.NumTurns, "duration_ms": l.DurationMS,
		}}}
		for _, d := range l.Denials {
			var den struct {
				ToolName  string          `json:"tool_name"`
				ToolUseID string          `json:"tool_use_id"`
				Input     json.RawMessage `json:"tool_input"`
			}
			if json.Unmarshal(d, &den) == nil {
				var input any
				_ = json.Unmarshal(den.Input, &input)
				out = append(out, Event{"tool_call", map[string]any{"id": den.ToolUseID, "tool": den.ToolName, "input": input, "denied_by_harness": true}})
			}
		}
		if l.IsError {
			out = append(out, Event{"error", map[string]any{"message": p.res.Error}})
		}
		return out
	}
	return nil
}

// blockText flattens a tool_result's content (a string or text blocks).
func blockText(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		var parts []string
		for _, b := range blocks {
			if b.Type == "text" {
				parts = append(parts, b.Text)
			}
		}
		return strings.Join(parts, "\n")
	}
	return string(raw)
}

func (p *claudeParser) Result() Result { return p.res }

const claudeInputFile = ".lazyagents/claude-input.jsonl"

// claudeImageMessage is the one user message of a turn with image inputs.
func claudeImageMessage(prompt string, images []InlineImage) ([]byte, error) {
	content := []map[string]any{{"type": "text", "text": prompt}}
	for _, im := range images {
		content = append(content, map[string]any{"type": "image", "source": map[string]any{"type": "base64", "media_type": im.MediaType, "data": base64.StdEncoding.EncodeToString(im.Data)}})
	}
	raw, err := json.Marshal(map[string]any{"type": "user", "message": map[string]any{"role": "user", "content": content}})
	if err != nil {
		return nil, err
	}
	return append(raw, '\n'), nil
}

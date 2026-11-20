package harness

import (
	"encoding/json"
	"path"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// Codex runs `codex exec --json` (checked against codex-cli 0.167.0; features.image_generation needs 0.167 or newer).
// Codex reads AGENTS.md itself; MCP servers and policy go in -c overrides.
// It authenticates headless with CODEX_API_KEY.
type Codex struct {
	Prices   map[string]Price
	Baseline Usage
}

func (Codex) Name() string { return agentdef.HarnessCodex }

func tomlString(s string) string { return strconv.Quote(s) }

// CodexProjectDocMaxBytes is the AGENTS.md budget Vesper gives Codex.
const CodexProjectDocMaxBytes = 128 * 1024

func codexHookRelPath(tag string) string {
	if tag == "" {
		return toolHookPath
	}
	return path.Join(".lazyagents", tag+"-tool-policy.py")
}

type codexConfigBuild struct {
	env     map[string]string
	files   map[string][]byte
	cfg     []string
	sandbox string
	noTools bool
}

func codexHookEnv(ws Workspace, rel string, noTools bool) (map[string]string, error) {
	if noTools && ws.MCPURL == "" {
		hookPath, err := filepath.Abs(filepath.Join(ws.Dir, rel))
		if err != nil {
			return nil, err
		}
		command := "python3 '" + strings.ReplaceAll(hookPath, "'", "'\"'\"'") + "'"
		return map[string]string{
			"LAZYAGENTS_POLICY_HOOK_PATH":    hookPath,
			"LAZYAGENTS_POLICY_HOOK_COMMAND": command,
		}, nil
	}
	return hookEnvironmentAt(ws, rel)
}

func buildCodexConfig(ws Workspace, t Turn, includeCacheInPerm bool) (codexConfigBuild, error) {
	spec := t.Spec
	noTools := spec.HarnessOptions[agentdef.OptionNoTools] == "true"
	noMCP := noTools || spec.HarnessOptions[agentdef.OptionNoMCP] == "true"
	hookRel := codexHookRelPath(t.ConfigTag)
	env, err := codexHookEnv(ws, hookRel, noTools)
	if err != nil {
		return codexConfigBuild{}, err
	}
	if ws.TokenEnv != "" {
		env[ws.TokenEnv] = ws.Token
	}
	command := env["LAZYAGENTS_POLICY_HOOK_COMMAND"]
	sandbox := spec.HarnessOptions["sandbox"]
	if sandbox == "" {
		sandbox = "workspace-write"
	}
	cfg := []string{
		"features.hooks=true",
		"features.multi_agent=false", // delegation stays in the run-scoped service
		`hooks.PreToolUse=[{matcher="*",hooks=[{type="command",command=` + tomlString(command) + `,timeout=20}]}]`,
		"approval_policy=" + tomlString("never"), // nobody answers prompts headless
		// Codex 0.169 truncates AGENTS.md past 32 KiB, global and thread
		// instructions included. A chat's generated section can be most of
		// that by itself (memory index, persona), so the repository's own
		// AGENTS.md at the end was cut off. Room for both (LAZYAGENTS-253).
		"project_doc_max_bytes=" + strconv.Itoa(CodexProjectDocMaxBytes),
	}
	if !noMCP {
		cfg = append(cfg,
			"mcp_servers."+lazyagentsServer+".url="+tomlString(ws.MCPURL),
			"mcp_servers."+lazyagentsServer+".bearer_token_env_var="+tomlString(ws.TokenEnv),
			// These are the service's own authenticated workflow tools. MCP's
			// approval policy is separate from shell approval_policy: without
			// this, unannotated tools prompt and are rejected headless. Scope
			// checks and human approvals still happen inside Vesper.
			"mcp_servers."+lazyagentsServer+".default_tools_approval_mode="+tomlString("approve"),
			"mcp_servers."+lazyagentsServer+".required=true",
		)
		for _, m := range spec.MCPServers {
			if m.Connector {
				// Vesper enforces each tool's permission; a call can wait on a person.
				cfg = append(cfg, "mcp_servers."+m.Name+".url="+tomlString(ws.MCPURL+"/connectors/"+m.Name), "mcp_servers."+m.Name+".bearer_token_env_var="+tomlString(ws.TokenEnv),
					"mcp_servers."+m.Name+".default_tools_approval_mode="+tomlString("approve"), "mcp_servers."+m.Name+".tool_timeout_sec=2400")
				continue
			}
			cfg = append(cfg, "mcp_servers."+m.Name+".url="+tomlString(m.URL), "mcp_servers."+m.Name+".default_tools_approval_mode="+tomlString("approve"))
		}
	}
	// Legacy workspace-write protects .git even when the workspace is writable.
	// Headless turns cannot request an exception, so explicitly grant Git writes
	// to repository writers while retaining the other workspace protections.
	if ws.ContainerSandbox {
		// The policy hook still holds read-only turns to read-only tools.
		cfg = append(cfg, "sandbox_mode="+tomlString("danger-full-access"))
	} else if sandbox == "workspace-write" && allowed(spec, "repo:write") {
		fsRules := `":workspace_roots"={".git"="write"}`
		if includeCacheInPerm && ws.DependencyCacheDir != "" {
			fsRules += `,` + tomlString(ws.DependencyCacheDir) + `="write"`
		}
		cfg = append(cfg,
			`default_permissions="lazyagents-repo-write"`,
			// One TOML table preserves quoted path keys; dotted -c keys split
			// the dot in ".git" and produce an invalid filesystem rule.
			`permissions.lazyagents-repo-write={extends=":workspace",filesystem={`+fsRules+`},network={enabled=true}}`,
		)
	} else if sandbox == "read-only" && spec.HarnessOptions[agentdef.OptionImageGeneration] == "true" {
		// An image-generating chat copies pictures into the workspace outbox
		// and nowhere else, so that is the only place it may write. Syntax
		// checked under --strict-config against codex-cli 0.167.0 (":read-only"
		// is a built-in base; a bad base or access value fails config load).
		cfg = append(cfg,
			`default_permissions="lazyagents-image-outbox"`,
			`permissions.lazyagents-image-outbox={extends=":read-only",filesystem={":workspace_roots"={".lazyagents/outbox"="write"}}}`,
		)
	} else {
		cfg = append(cfg, "sandbox_mode="+tomlString(sandbox))
	}
	// Codex can't route web search through Vesper approval, so it's live only
	// when web:read is plainly allowed.
	web := "disabled"
	if spec.HarnessOptions[agentdef.OptionWebSearch] == "true" {
		// The assistant's own search option (checked against codex-cli 0.167.0,
		// which accepts disabled, cached, indexed or live under --strict-config).
		// cached searches OpenAI's index without live fetches of arbitrary
		// URLs, which could carry data out (ADR "Assistant web access").
		web = "cached"
	} else if allowed(spec, "web:read") && spec.HarnessOptions["readonly"] != "true" {
		web = "live"
	}
	cfg = append(cfg, "web_search="+tomlString(web))
	// Image generation is a default-on feature in codex-cli 0.167.0, so it is
	// switched off unless the chat's persona has the images capability.
	cfg = append(cfg, "features.image_generation="+strconv.FormatBool(spec.HarnessOptions[agentdef.OptionImageGeneration] == "true"))
	if effort := spec.HarnessOptions["effort"]; effort != "" {
		cfg = append(cfg, "model_reasoning_effort="+tomlString(effort))
	}
	files := SkillFilesFor(spec.Skills, agentdef.HarnessCodex)
	files[hookRel] = toolHook
	if noTools {
		files[hookRel] = noToolsHook
	}
	return codexConfigBuild{
		env:     env,
		files:   files,
		cfg:     cfg,
		sandbox: sandbox,
		noTools: noTools,
	}, nil
}

func (Codex) Invocation(ws Workspace, t Turn) (Invocation, error) {
	b, err := buildCodexConfig(ws, t, false)
	if err != nil {
		return Invocation{}, err
	}
	spec := t.Spec
	opts := []string{"--json", "--skip-git-repo-check", "--dangerously-bypass-hook-trust", "--strict-config"}
	if len(t.Images) > 0 {
		// --image takes several comma-separated files (exec and exec resume,
		// codex-cli 0.167.0) and keeps consuming values, so it goes first: the
		// flags after it end the list before the positional prompt.
		opts = append([]string{"--image", strings.Join(t.Images, ",")}, opts...)
	}
	if spec.Model != "" {
		opts = append(opts, "-m", spec.Model)
	}
	for _, c := range b.cfg {
		opts = append(opts, "-c", c)
	}
	argv := []string{"codex", "exec"}
	// --add-dir belongs to exec, not its resume subcommand. Keep it before
	// resume so later turns retain cache access without a CLI parse failure.
	if ws.DependencyCacheDir != "" && (allowed(spec, "tests:run") || allowed(spec, "repo:write")) {
		argv = append(argv, "--add-dir", ws.DependencyCacheDir)
	}
	if t.SessionID != "" {
		argv = append(argv, "resume")
		argv = append(argv, opts...)
		argv = append(argv, t.SessionID, t.Prompt)
	} else {
		argv = append(argv, opts...)
		argv = append(argv, t.Prompt)
	}
	b.files[".lazyagents/codex-launch.py"] = codexLauncher
	argv = append([]string{"python3", ".lazyagents/codex-launch.py"}, argv...)
	return Invocation{Argv: argv, Env: b.env, Files: b.files}, nil
}

func (c Codex) NewParser(model string) Parser {
	return &codexParser{model: model, prices: c.Prices, baseline: c.Baseline}
}

type codexParser struct {
	hookTrustNotice bool
	baseline        Usage
	model           string
	prices          map[string]Price
	res             Result
	reply           replyScanner
	replyItemID     string
	replyOffset     int
	activity        activityTracker
}

type codexItem struct {
	ID               string          `json:"id"`
	Type             string          `json:"type"`
	Text             string          `json:"text"`
	Message          string          `json:"message"`
	Command          string          `json:"command"`
	AggregatedOutput string          `json:"aggregated_output"`
	ExitCode         *int            `json:"exit_code"`
	Status           string          `json:"status"`
	Server           string          `json:"server"`
	Tool             string          `json:"tool"`
	Arguments        json.RawMessage `json:"arguments"`
	Result           json.RawMessage `json:"result"`
	Error            json.RawMessage `json:"error"`
	Changes          []struct {
		Path string `json:"path"`
		Kind string `json:"kind"`
	} `json:"changes"`
	Query string `json:"query"`
}

type codexLine struct {
	Type     string     `json:"type"`
	ThreadID string     `json:"thread_id"`
	Message  string     `json:"message"`
	Item     *codexItem `json:"item"`
	Usage    *struct {
		InputTokens       int64  `json:"input_tokens"`
		CachedInputTokens *int64 `json:"cached_input_tokens"`
		OutputTokens      int64  `json:"output_tokens"`
	} `json:"usage"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

func (p *codexParser) Line(b []byte) []Event {
	var l codexLine
	if err := json.Unmarshal(b, &l); err != nil || l.Type == "" {
		return nil
	}
	switch l.Type {
	case "thread.started":
		p.res.SessionID = l.ThreadID
		return []Event{{"lifecycle", map[string]any{"state": "harness_started", "harness": agentdef.HarnessCodex, "model": p.model, "session_id": l.ThreadID}}}
	case "turn.completed":
		if l.Usage != nil {
			cached := int64(0)
			if l.Usage.CachedInputTokens != nil {
				cached = *l.Usage.CachedInputTokens
			}
			baseline := p.baseline
			if baseline.SessionID != "" && baseline.SessionID != p.res.SessionID {
				baseline = Usage{}
			}
			if l.Usage.InputTokens < baseline.SessionInputTokens || l.Usage.OutputTokens < baseline.SessionOutputTokens || (l.Usage.CachedInputTokens != nil && cached < baseline.SessionCachedTokens) {
				baseline = Usage{}
			}
			p.res.Usage.InputTokens = l.Usage.InputTokens - baseline.SessionInputTokens
			p.res.Usage.OutputTokens = l.Usage.OutputTokens - baseline.SessionOutputTokens
			p.res.Usage.CachedTokens = 0
			if l.Usage.CachedInputTokens != nil {
				p.res.Usage.CachedTokens = max(0, cached-baseline.SessionCachedTokens)
			}
			p.res.Usage.SessionID = p.res.SessionID
			p.res.Usage.SessionInputTokens = l.Usage.InputTokens
			p.res.Usage.SessionOutputTokens = l.Usage.OutputTokens
			p.res.Usage.SessionCachedTokens = cached
			p.res.Usage.SessionCacheKnown = l.Usage.CachedInputTokens != nil && cached >= 0 && cached <= l.Usage.InputTokens
			if l.Usage.CachedInputTokens != nil && cached >= 0 && cached <= l.Usage.InputTokens && (baseline.SessionInputTokens == 0 || baseline.SessionCacheKnown) && p.res.Usage.CachedTokens <= p.res.Usage.InputTokens {
				p.res.Usage.CacheReportedInputTokens = p.res.Usage.InputTokens
			}
		}
		p.res.Usage.CostSource = "unknown"
		cost, known := computeCost(p.model, p.res.Usage, p.prices)
		if known && (p.res.Usage.CacheReportedInputTokens < p.res.Usage.InputTokens || p.res.Usage.CachedTokens > p.res.Usage.InputTokens) {
			price, ok := p.prices[p.model]
			if !ok {
				price = Prices[p.model]
			}
			if price.Input != price.CachedInput || p.res.Usage.CachedTokens > p.res.Usage.InputTokens {
				known = false
			}
		}
		if known {
			p.res.Usage.CostUSD, p.res.Usage.CostSource = cost, "computed"
		}
		payload := map[string]any{"input_tokens": p.res.Usage.InputTokens, "output_tokens": p.res.Usage.OutputTokens, "cached_tokens": p.res.Usage.CachedTokens, "cache_reported_input_tokens": p.res.Usage.CacheReportedInputTokens, "cost_source": p.res.Usage.CostSource, "cost_known": known}
		if known {
			payload["cost_usd"] = p.res.Usage.CostUSD
		}
		return []Event{{"usage", payload}}
	case "turn.failed":
		msg := "turn failed"
		if l.Error != nil {
			msg = l.Error.Message
		}
		p.res.IsError, p.res.Error = true, msg
		p.res.UsageLimited = p.res.UsageLimited || UsageLimit(msg)
		return []Event{{"error", map[string]any{"message": msg}}}
	case "error":
		if l.Message == "`--dangerously-bypass-hook-trust` is enabled. Enabled hooks may run without review for this invocation." {
			if p.hookTrustNotice {
				return nil
			}
			p.hookTrustNotice = true
			return []Event{{"lifecycle", map[string]any{"state": "harness_notice", "code": "hook_trust_automation", "message": l.Message}}}
		}
		// Transient ("Reconnecting… 2/5") errors are noise until the last.
		if strings.HasPrefix(l.Message, "Reconnecting") {
			return nil
		}
		p.res.Error = l.Message
		p.res.UsageLimited = p.res.UsageLimited || UsageLimit(l.Message)
		return []Event{{"error", map[string]any{"message": l.Message}}}
	case "item.started", "item.updated", "item.completed":
		if l.Item == nil {
			return nil
		}
		return p.item(l.Type == "item.completed", *l.Item)
	}
	return nil
}

func (p *codexParser) item(done bool, it codexItem) []Event {
	switch it.Type {
	case "agent_message":
		if !done {
			if it.ID != "" && it.ID != p.replyItemID {
				p.reply = replyScanner{}
				p.replyItemID = it.ID
				p.replyOffset = 0
				p.activity.resetText()
			}
			var out []Event
			if len(it.Text) > p.replyOffset {
				delta := it.Text[p.replyOffset:]
				p.replyOffset = len(it.Text)
				if blocks := p.reply.feed(delta); len(blocks) > 0 {
					p.activity.touch()
					out = append(out, blocks...)
				}
			}
			if !p.reply.inFence {
				out = append(out, p.activity.textSnapshot(it.Text)...)
			} else if len(out) == 0 {
				out = append(out, p.activity.heartbeatIfDue("writing_reply")...)
			}
			return out
		}
		p.reply = replyScanner{}
		p.replyItemID = ""
		p.replyOffset = 0
		p.activity.reset()
		if strings.TrimSpace(it.Text) == "" {
			return nil
		}
		p.res.Final = it.Text
		return []Event{{"message", map[string]any{"role": "assistant", "text": it.Text}}}
	case "command_execution":
		p.activity.reset()
		if !done {
			p.res.Usage.ToolCalls++
			return []Event{{"tool_call", map[string]any{"id": it.ID, "tool": "shell", "input": map[string]any{"command": it.Command}}}}
		}
		exit := 0
		if it.ExitCode != nil {
			exit = *it.ExitCode
		}
		return []Event{{"tool_result", map[string]any{"id": it.ID, "tool": "shell", "is_error": exit != 0 || it.Status == "failed",
			"exit_code": exit, "output": clip(it.AggregatedOutput, 4000)}}}
	case "mcp_tool_call":
		p.activity.reset()
		tool := it.Tool
		if it.Server != "" && it.Server != lazyagentsServer {
			tool = it.Server + "." + it.Tool
		}
		if !done {
			p.res.Usage.ToolCalls++
			var args any
			_ = json.Unmarshal(it.Arguments, &args)
			return []Event{{"tool_call", map[string]any{"id": it.ID, "tool": tool, "input": args}}}
		}
		out := string(it.Result)
		hasError := len(it.Error) > 0 && string(it.Error) != "null"
		var resultFlags struct {
			IsError      bool `json:"isError"`
			IsErrorSnake bool `json:"is_error"`
		}
		_ = json.Unmarshal(it.Result, &resultFlags)
		if hasError {
			out = string(it.Error)
		}
		return []Event{{"tool_result", map[string]any{"id": it.ID, "tool": tool, "is_error": it.Status == "failed" || hasError || resultFlags.IsError || resultFlags.IsErrorSnake, "output": clip(out, 4000)}}}
	case "file_change":
		if !done {
			return nil
		}
		p.activity.reset()
		files := make([]string, len(it.Changes))
		for i, c := range it.Changes {
			files[i] = c.Kind + " " + c.Path
		}
		p.res.Usage.ToolCalls++
		return []Event{{"tool_call", map[string]any{"id": it.ID, "tool": "apply_patch", "input": map[string]any{"files": files}, "status": it.Status}}}
	case "web_search":
		if done {
			p.activity.reset()
			p.res.Usage.ToolCalls++
			return []Event{{"tool_call", map[string]any{"id": it.ID, "tool": "web_search", "input": map[string]any{"query": it.Query}}}}
		}
	case "reasoning":
		if !done {
			return p.activity.thinkingText(it.Text)
		}
		p.activity.reset()
		if ev, ok := thinkingEvent(it.Text); ok {
			return []Event{ev}
		}
	case "error":
		if done {
			return []Event{{"error", map[string]any{"message": it.Message}}}
		}
	}
	return nil // todo lists: raw log only
}

func (p *codexParser) Result() Result { return p.res }

// ---------------------------------------------------------------- prices

// Price is USD per million tokens.
type Price struct {
	Input       float64 `json:"input_per_million"`
	CachedInput float64 `json:"cached_input_per_million"`
	Output      float64 `json:"output_per_million"`
}

// Prices is the model_prices table for harnesses that don't report cost
// (Codex). Unknown models leave cost unset rather than guessing; add rows
// as models change.
var Prices = map[string]Price{
	"gpt-5":         {Input: 1.25, CachedInput: 0.125, Output: 10},
	"gpt-5-codex":   {Input: 1.25, CachedInput: 0.125, Output: 10},
	"gpt-5-mini":    {Input: 0.25, CachedInput: 0.025, Output: 2},
	"gpt-5.1-codex": {Input: 1.25, CachedInput: 0.125, Output: 10},
}

// ComputeCost prices usage for a model; known is false for unknown models.
func ComputeCost(model string, u Usage) (cost float64, known bool) {
	return computeCost(model, u, nil)
}

func computeCost(model string, u Usage, overrides map[string]Price) (cost float64, known bool) {
	pr, ok := overrides[model]
	if !ok {
		pr, ok = Prices[model]
	}
	if !ok {
		return 0, false
	}
	uncached := u.InputTokens - u.CachedTokens
	if uncached < 0 {
		uncached = 0
	}
	return (float64(uncached)*pr.Input + float64(u.CachedTokens)*pr.CachedInput + float64(u.OutputTokens)*pr.Output) / 1e6, true
}

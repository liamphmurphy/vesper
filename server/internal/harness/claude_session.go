package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

var _ SessionHarness = ClaudeCode{}

// SessionInvocation returns the command, env, and config files for driving
// Claude Code over its bidirectional stream-json stdio protocol.
func (ClaudeCode) SessionInvocation(ws Workspace, t Turn) (Invocation, error) {
	c, err := buildClaudeConfig(ws, t, false)
	if err != nil {
		return Invocation{}, err
	}
	spec := t.Spec
	argv := []string{"claude", "-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json", "--verbose",
		"--permission-prompt-tool", "stdio",
		"--model", AnthropicModel(spec.Model),
		"--mcp-config", c.mcpFile, "--strict-mcp-config",
		"--permission-mode", c.mode,
		"--settings", c.settingsFile,
		// Skip the host's user settings: on the fake runner HOME is the
		// host's, and a user-level "agent", plugins or permissions would
		// replace this run's tools and prompt. Login isn't a setting source.
		"--setting-sources", "project,local",
	}
	if len(c.allow) > 0 {
		argv = append(argv, "--allowedTools", strings.Join(c.allow, ","))
	}
	if len(c.deny) > 0 {
		argv = append(argv, "--disallowedTools", strings.Join(c.deny, ","))
	}
	if c.subagents {
		argv = append(argv, "--agents", c.agentsFile)
	}
	if c.noTools {
		argv = append(argv, "--tools", "")
	} else {
		// Lets the chat see rich blocks being written; messages still arrive whole.
		argv = append(argv, "--include-partial-messages")
	}
	if t.SessionID != "" {
		argv = append(argv, "--resume", t.SessionID)
	}
	if t.SystemAppend != "" {
		argv = append(argv, "--append-system-prompt", t.SystemAppend)
	}
	// The flag, not settings: it takes every level (settings files refuse max)
	// and applies per invocation, so a chat can change it between turns.
	if effort := spec.HarnessOptions["effort"]; effort != "" {
		argv = append(argv, "--effort", effort)
	}
	return Invocation{
		Argv:  argv,
		Env:   c.env,
		Files: c.files,
	}, nil
}

// RunSession drives a Claude Code stream-json stdio turn: initializes
// PreToolUse hooks, sends the prompt, enforces CheckTool on hook_callback and
// can_use_tool requests, forwards parsed events, and closes stdin on result.
func (c ClaudeCode) RunSession(ctx context.Context, stdin io.WriteCloser, stdout io.Reader, _ Workspace, t Turn, cb SessionCallbacks) (Result, error) {
	noTools := t.Spec.HarnessOptions[agentdef.OptionNoTools] == "true"
	w := newLineWriter(stdin)
	var wg sync.WaitGroup
	defer func() {
		_ = w.Close()
		wg.Wait()
	}()
	if cb.OnControl != nil {
		cb.OnControl(&claudeControl{w: w})
	}

	initReq := map[string]any{
		"type":       "control_request",
		"request_id": "init-1",
		"request": map[string]any{
			"subtype": "initialize",
			"hooks": map[string]any{
				"PreToolUse": []any{
					map[string]any{
						"matcher":         "*",
						"hookCallbackIds": []string{"vesper_policy"},
					},
				},
			},
		},
	}
	if err := w.writeJSON(initReq); err != nil {
		return Result{}, fmt.Errorf("claude write initialize: %w", err)
	}

	p := c.NewParser("")
	var lastSessionID string
	var lastCtx int64
	sentPrompt := false

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 256<<10), sessionMaxScanBytes)
	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		if cb.OnRaw != nil {
			cb.OnRaw(line)
		}
		var env struct {
			Type      string          `json:"type"`
			RequestID string          `json:"request_id"`
			Request   json.RawMessage `json:"request"`
			Response  struct {
				Subtype   string `json:"subtype"`
				RequestID string `json:"request_id"`
				Error     string `json:"error"`
			} `json:"response"`
		}
		if json.Unmarshal(line, &env) == nil {
			switch env.Type {
			case "control_response":
				if env.Response.RequestID == "init-1" {
					if env.Response.Subtype == "error" {
						return p.Result(), fmt.Errorf("claude initialize: %s", env.Response.Error)
					}
					if !sentPrompt {
						sentPrompt = true
						if err := w.writeJSON(claudeUserMessage(t.Prompt, t.InlineImages)); err != nil {
							return p.Result(), fmt.Errorf("claude write user message: %w", err)
						}
					}
				}
				continue
			case "control_request":
				reqID := env.RequestID
				rawReq := env.Request
				wg.Add(1)
				go func() {
					defer wg.Done()
					handleClaudeControlRequest(ctx, w, cb.CheckTool, noTools, reqID, rawReq)
				}()
				continue
			}
		}

		for _, ev := range p.Line(line) {
			if cb.OnEvent != nil {
				cb.OnEvent(ev)
			}
		}
		if sid := p.Result().SessionID; sid != "" && sid != lastSessionID {
			lastSessionID = sid
			if cb.OnSession != nil {
				cb.OnSession(sid)
			}
		}
		if ct := p.Result().Usage.ContextTokens; ct > 0 && ct != lastCtx {
			lastCtx = ct
			if cb.OnContextTokens != nil {
				cb.OnContextTokens(ct)
			}
		}
		if env.Type == "result" {
			_ = w.Close()
		}
	}
	if err := sc.Err(); err != nil {
		return p.Result(), err
	}
	return p.Result(), nil
}

type claudeControl struct {
	w   *lineWriter
	seq atomic.Int64
}

func (c *claudeControl) Interrupt() error {
	id := fmt.Sprintf("interrupt-%d", c.seq.Add(1))
	return c.w.writeJSON(map[string]any{
		"type":       "control_request",
		"request_id": id,
		"request": map[string]any{
			"subtype": "interrupt",
		},
	})
}

func handleClaudeControlRequest(ctx context.Context, w *lineWriter, fn PolicyFunc, noTools bool, reqID string, rawReq json.RawMessage) {
	var req struct {
		Subtype  string          `json:"subtype"`
		ToolName string          `json:"tool_name"`
		Input    json.RawMessage `json:"input"`
	}
	if err := json.Unmarshal(rawReq, &req); err != nil {
		_ = w.writeJSON(claudeControlError(reqID, "invalid control request payload"))
		return
	}
	switch req.Subtype {
	case "hook_callback":
		var in struct {
			ToolName  string         `json:"tool_name"`
			ToolInput map[string]any `json:"tool_input"`
		}
		if err := json.Unmarshal(req.Input, &in); err != nil {
			_ = w.writeJSON(claudeControlError(reqID, "invalid hook_callback input"))
			return
		}
		allow, reason := checkPolicy(ctx, fn, noTools, in.ToolName, in.ToolInput)
		hookOut := map[string]any{
			"hookEventName":      "PreToolUse",
			"permissionDecision": "deny",
		}
		if allow {
			hookOut["permissionDecision"] = "allow"
		} else {
			hookOut["permissionDecisionReason"] = reason
		}
		_ = w.writeJSON(claudeControlSuccess(reqID, map[string]any{
			"hookSpecificOutput": hookOut,
		}))
	case "can_use_tool":
		var in map[string]any
		if len(req.Input) > 0 && string(req.Input) != "null" {
			if err := json.Unmarshal(req.Input, &in); err != nil {
				_ = w.writeJSON(claudeControlError(reqID, "invalid can_use_tool input"))
				return
			}
		}
		if in == nil {
			in = map[string]any{}
		}
		allow, reason := checkPolicy(ctx, fn, noTools, req.ToolName, in)
		var body map[string]any
		if allow {
			body = map[string]any{
				"behavior":     "allow",
				"updatedInput": in,
			}
		} else {
			body = map[string]any{
				"behavior": "deny",
				"message":  reason,
			}
		}
		_ = w.writeJSON(claudeControlSuccess(reqID, body))
	default:
		_ = w.writeJSON(claudeControlError(reqID, "unsupported control request: "+req.Subtype))
	}
}

func claudeControlSuccess(reqID string, body map[string]any) map[string]any {
	return map[string]any{
		"type": "control_response",
		"response": map[string]any{
			"subtype":    "success",
			"request_id": reqID,
			"response":   body,
		},
	}
}

func claudeControlError(reqID, msg string) map[string]any {
	return map[string]any{
		"type": "control_response",
		"response": map[string]any{
			"subtype":    "error",
			"request_id": reqID,
			"error":      msg,
		},
	}
}

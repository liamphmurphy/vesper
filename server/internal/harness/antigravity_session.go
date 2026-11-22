package harness

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"sync"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

var _ SessionHarness = Antigravity{}

// agyUsesStreamJSON reports whether an Antigravity turn must run over
// `agy -p --output-format stream-json` instead of `agy acp --stdio`.
// Antigravity generates images through its asynchronous `image-generator`
// subagent (`invoke_subagent`), whose completion wakes the parent up in a
// follow-up turn carrying the saved image path. `agy acp --stdio` resolves
// `session/prompt` with `stopReason: "end_turn"` as soon as the initial turn
// ends and does not deliver background subagent wakeups, whereas `agy -p`
// waits for subagents to finish before exiting.
func agyUsesStreamJSON(spec agentdef.Resolved) bool {
	return spec.HarnessOptions[agentdef.OptionImageGeneration] == "true"
}

// SessionInvocation returns the command, env, and config files for driving
// Antigravity over `agy acp --stdio` (or `agy -p --output-format stream-json`
// for image-generation turns; see agyUsesStreamJSON).
func (Antigravity) SessionInvocation(ws Workspace, t Turn) (Invocation, error) {
	if agyUsesStreamJSON(t.Spec) {
		return (Antigravity{}).Invocation(ws, t)
	}
	b, err := buildAgyConfig(ws, t)
	if err != nil {
		return Invocation{}, err
	}
	b.env["LAZYAGENTS_AGY_ACP"] = "1"
	argv := []string{"python3", agyLaunchPath}
	if t.ConfigTag != "" {
		argv = append(argv, "--config", b.configRel)
	}
	argv = append(argv, "agy", "acp", "--stdio", "--disable-telemetry")
	return Invocation{Argv: argv, Env: b.env, Files: b.files}, nil
}

// RunSession drives an Antigravity ACP stdio turn: handshakes (`initialize`,
// `session/new` or `session/load` with API-key `authenticate` fallback only when
// `-32000` + `GEMINI_API_KEY` is present), applies `model`/`thought_level`, sends
// `session/prompt`, answers `session/request_permission` fail-closed via
// CheckTool, streams `session/update`, detects executor errors / 429s, and
// cancels via `session/cancel`. Image-generation turns use `agy -p` stream-json
// instead (see agyUsesStreamJSON).
func (Antigravity) RunSession(ctx context.Context, stdin io.WriteCloser, stdout io.Reader, ws Workspace, t Turn, cb SessionCallbacks) (Result, error) {
	if agyUsesStreamJSON(t.Spec) {
		return runAgyStreamSession(stdin, stdout, t.Spec.Model, cb)
	}
	noTools := t.Spec.HarnessOptions[agentdef.OptionNoTools] == "true"
	w := newLineWriter(stdin)
	ctrl := &agyControl{w: w}
	var wg sync.WaitGroup
	defer func() {
		_ = w.Close()
		wg.Wait()
	}()
	if cb.OnControl != nil {
		cb.OnControl(ctrl)
	}

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 256<<10), sessionMaxScanBytes)

	var nextID int64 = 1
	allocID := func() int64 {
		id := nextID
		nextID++
		return id
	}

	// call sends a JSON-RPC request during setup/teardown and waits for its
	// matching response while ignoring replayed session/update notifications.
	call := func(method string, params any) (agyRPCResponse, error) {
		id := allocID()
		if err := w.writeJSON(map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"method":  method,
			"params":  params,
		}); err != nil {
			return agyRPCResponse{}, fmt.Errorf("agy write %s: %w", method, err)
		}
		for sc.Scan() {
			line := append([]byte(nil), sc.Bytes()...)
			if cb.OnRaw != nil {
				cb.OnRaw(line)
			}
			// Handle early launcher setup failure output.
			var launchErr struct {
				Event  string `json:"event"`
				Result struct {
					Status string `json:"status"`
					Error  string `json:"error"`
				} `json:"result"`
			}
			if json.Unmarshal(line, &launchErr) == nil && launchErr.Event == "result" && launchErr.Result.Status == "ERROR" {
				return agyRPCResponse{}, fmt.Errorf("%s", launchErr.Result.Error)
			}
			var msg agyRPCMessage
			if json.Unmarshal(line, &msg) != nil {
				continue
			}
			if msg.Method != "" || len(msg.ID) == 0 || string(msg.ID) == "null" {
				continue
			}
			var respID int64
			if json.Unmarshal(msg.ID, &respID) == nil && respID == id {
				return agyRPCResponse{Result: msg.Result, Error: msg.Error}, nil
			}
		}
		if err := sc.Err(); err != nil {
			return agyRPCResponse{}, err
		}
		return agyRPCResponse{}, fmt.Errorf("agy exited before responding to %s", method)
	}

	initResp, err := call("initialize", map[string]any{
		"protocolVersion":    1,
		"clientCapabilities": map[string]any{},
	})
	if err != nil {
		return Result{}, err
	}
	if initResp.Error != nil {
		return Result{}, fmt.Errorf("agy initialize: %s", initResp.Error.Message)
	}

	openSession := func() (agyRPCResponse, error) {
		if t.SessionID != "" {
			return call("session/load", map[string]any{
				"sessionId":  t.SessionID,
				"cwd":        ws.Dir,
				"mcpServers": []any{},
			})
		}
		return call("session/new", map[string]any{
			"cwd":        ws.Dir,
			"mcpServers": []any{},
		})
	}
	sessResp, err := openSession()
	if err != nil {
		return Result{}, err
	}
	if sessResp.Error != nil && sessResp.Error.Code == -32000 && os.Getenv("GEMINI_API_KEY") != "" {
		authResp, authErr := call("authenticate", map[string]any{"methodId": "gemini-api-key"})
		if authErr != nil {
			return Result{}, authErr
		}
		if authResp.Error != nil {
			return Result{}, fmt.Errorf("agy authenticate: %s", authResp.Error.Message)
		}
		sessResp, err = openSession()
		if err != nil {
			return Result{}, err
		}
	}
	if sessResp.Error != nil {
		msg := sessResp.Error.Message
		return Result{IsError: true, Error: msg, UsageLimited: UsageLimit(msg)}, nil
	}
	var sessData struct {
		SessionID string `json:"sessionId"`
	}
	_ = json.Unmarshal(sessResp.Result, &sessData)
	sid := sessData.SessionID
	if sid == "" {
		sid = t.SessionID
	}
	if sid == "" {
		return Result{}, fmt.Errorf("agy session response missing sessionId")
	}
	ctrl.setSession(sid)

	st := &agySessionState{
		model:     t.Spec.Model,
		sessionID: sid,
		called:    map[string]bool{},
		finished:  map[string]bool{},
		toolNames: map[string]string{},
		emit: func(ev Event) {
			if cb.OnEvent != nil {
				cb.OnEvent(ev)
			}
		},
		onContextTokens: cb.OnContextTokens,
	}
	st.res.SessionID = sid
	st.emit(Event{"lifecycle", map[string]any{
		"state":      "harness_started",
		"harness":    agentdef.HarnessAntigravity,
		"model":      t.Spec.Model,
		"session_id": sid,
	}})
	if cb.OnSession != nil {
		cb.OnSession(sid)
	}

	model := t.Spec.Model
	effort := t.Spec.HarnessOptions["effort"]
	if effort != "" {
		if base, _, ok := agentdef.CutEffortSuffix(model); ok {
			model = base
		}
	}
	if model != "" {
		resp, err := call("session/set_config_option", map[string]any{
			"sessionId": sid,
			"configId":  "model",
			"value":     model,
		})
		if err != nil {
			return st.res, err
		}
		if resp.Error != nil && resp.Error.Code != -32602 {
			st.fail(resp.Error.Message)
			return st.res, nil
		}
	}
	if effort != "" {
		resp, err := call("session/set_config_option", map[string]any{
			"sessionId": sid,
			"configId":  "thought_level",
			"value":     effort,
		})
		if err != nil {
			return st.res, err
		}
		if resp.Error != nil && resp.Error.Code != -32602 {
			st.fail(resp.Error.Message)
			return st.res, nil
		}
	}

	promptText := t.Prompt
	if t.SystemAppend != "" {
		if promptText != "" {
			promptText = t.SystemAppend + "\n\n" + promptText
		} else {
			promptText = t.SystemAppend
		}
	}
	if !noTools {
		if note := agyImageNote(t.Images); note != "" {
			promptText += "\n\n" + note
		}
	}
	blocks := []map[string]any{{"type": "text", "text": promptText}}
	for _, im := range t.InlineImages {
		blocks = append(blocks, map[string]any{
			"type":     "image",
			"mimeType": im.MediaType,
			"data":     base64.StdEncoding.EncodeToString(im.Data),
		})
	}

	promptID := allocID()
	if err := w.writeJSON(map[string]any{
		"jsonrpc": "2.0",
		"id":      promptID,
		"method":  "session/prompt",
		"params": map[string]any{
			"sessionId": sid,
			"prompt":    blocks,
		},
	}); err != nil {
		return st.res, fmt.Errorf("agy write session/prompt: %w", err)
	}

	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		if cb.OnRaw != nil {
			cb.OnRaw(line)
		}
		var msg agyRPCMessage
		if json.Unmarshal(line, &msg) != nil {
			continue
		}

		// Server-initiated request (e.g. session/request_permission).
		if msg.Method != "" && len(msg.ID) > 0 && string(msg.ID) != "null" {
			idRaw := append(json.RawMessage(nil), msg.ID...)
			method := msg.Method
			paramsRaw := append(json.RawMessage(nil), msg.Params...)
			wg.Add(1)
			go func() {
				defer wg.Done()
				handleAgyServerRequest(ctx, w, cb.CheckTool, noTools, idRaw, method, paramsRaw)
			}()
			continue
		}

		// Response to session/prompt -> turn finished.
		if msg.Method == "" && len(msg.ID) > 0 && string(msg.ID) != "null" {
			var respID int64
			if json.Unmarshal(msg.ID, &respID) == nil && respID == promptID {
				st.finishPrompt(msg.Result, msg.Error)
				_ = w.Close()
				return st.res, nil
			}
			continue
		}

		if msg.Method == "session/update" {
			st.handleUpdate(msg.Params)
		}
	}
	if err := sc.Err(); err != nil {
		return st.res, err
	}
	return st.res, nil
}

type agyControl struct {
	w   *lineWriter
	mu  sync.Mutex
	sid string
}

func (c *agyControl) setSession(sid string) {
	c.mu.Lock()
	c.sid = sid
	c.mu.Unlock()
}

func (c *agyControl) Interrupt() error {
	c.mu.Lock()
	sid := c.sid
	c.mu.Unlock()
	if sid == "" {
		return nil
	}
	return c.w.writeJSON(map[string]any{
		"jsonrpc": "2.0",
		"method":  "session/cancel",
		"params":  map[string]any{"sessionId": sid},
	})
}

func (c *agyControl) Steer(string) error {
	return ErrSteerUnsupported
}

type agyRPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data"`
}

type agyRPCResponse struct {
	Result json.RawMessage
	Error  *agyRPCError
}

type agyRPCMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *agyRPCError    `json:"error"`
}

func handleAgyServerRequest(ctx context.Context, w *lineWriter, fn PolicyFunc, noTools bool, id json.RawMessage, method string, paramsRaw json.RawMessage) {
	if method != "session/request_permission" {
		_ = w.writeJSON(map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"error": map[string]any{
				"code":    -32601,
				"message": "unsupported ACP request: " + method,
			},
		})
		return
	}
	var p struct {
		ToolCall struct {
			Name     string         `json:"name"`
			Title    string         `json:"title"`
			Args     map[string]any `json:"args"`
			RawInput map[string]any `json:"rawInput"`
		} `json:"toolCall"`
		Options []struct {
			OptionID string `json:"optionId"`
			Kind     string `json:"kind"`
		} `json:"options"`
	}
	if err := json.Unmarshal(paramsRaw, &p); err != nil {
		_ = w.writeJSON(map[string]any{"jsonrpc": "2.0", "id": id, "result": map[string]any{"outcome": map[string]any{"outcome": "cancelled"}}})
		return
	}
	name := p.ToolCall.Name
	if name == "" {
		name = p.ToolCall.Title
	}
	args := p.ToolCall.Args
	if args == nil {
		args = p.ToolCall.RawInput
	}
	tool, canon := antigravityTool(name, args)
	allow, _ := checkPolicy(ctx, fn, noTools, tool, canon)

	pick := func(kinds ...string) string {
		for _, k := range kinds {
			for _, o := range p.Options {
				if o.Kind == k && o.OptionID != "" {
					return o.OptionID
				}
			}
		}
		return ""
	}
	var optID string
	if allow {
		optID = pick("allow_once", "allow_always")
	} else {
		optID = pick("reject_once", "reject_always")
	}
	if optID == "" {
		_ = w.writeJSON(map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"result":  map[string]any{"outcome": map[string]any{"outcome": "cancelled"}},
		})
		return
	}
	_ = w.writeJSON(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"result":  map[string]any{"outcome": map[string]any{"outcome": "selected", "optionId": optID}},
	})
}

type agySessionState struct {
	model           string
	sessionID       string
	res             Result
	called          map[string]bool
	finished        map[string]bool
	toolNames       map[string]string
	thinkBuf        strings.Builder
	textBuf         strings.Builder
	sawText         bool
	reply           replyScanner
	activity        activityTracker
	emit            func(Event)
	onContextTokens func(int64)
}

func (s *agySessionState) flushThinking() {
	if s.thinkBuf.Len() == 0 {
		return
	}
	txt := s.thinkBuf.String()
	s.thinkBuf.Reset()
	s.activity.reset()
	if ev, ok := thinkingEvent(txt); ok {
		s.emit(ev)
	}
}

func (s *agySessionState) flushText() {
	if s.textBuf.Len() == 0 {
		return
	}
	txt := s.textBuf.String()
	s.textBuf.Reset()
	s.reply = replyScanner{}
	s.activity.reset()
	if strings.TrimSpace(txt) == "" {
		return
	}
	s.sawText = true
	s.res.Final = txt
	s.noteImages(txt)
	s.emit(Event{"message", map[string]any{"role": "assistant", "text": txt}})
}

func (s *agySessionState) fail(msg string) {
	if msg == "" {
		msg = "agy failed"
	}
	s.res.IsError = true
	s.res.Error = msg
	s.res.UsageLimited = s.res.UsageLimited || UsageLimit(msg)
	s.emit(Event{"error", map[string]any{"message": msg}})
}

func (s *agySessionState) noteImages(str string) {
	for _, m := range agyImagePath.FindAllString(str, 8) {
		if len(s.res.Images) < 8 && !contains(s.res.Images, m) {
			s.res.Images = append(s.res.Images, m)
		}
	}
}

func (s *agySessionState) handleUpdate(paramsRaw json.RawMessage) {
	var p struct {
		Update struct {
			SessionUpdate string `json:"sessionUpdate"`
			Content       *struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			ToolCallID string          `json:"toolCallId"`
			Name       string          `json:"name"`
			Title      string          `json:"title"`
			Args       map[string]any  `json:"args"`
			RawInput   map[string]any  `json:"rawInput"`
			Status     string          `json:"status"`
			RawOutput  json.RawMessage `json:"rawOutput"`
			Blocks     json.RawMessage `json:"content_blocks"`
			Used       int64           `json:"used"`
		} `json:"update"`
	}
	if json.Unmarshal(paramsRaw, &p) != nil {
		return
	}
	u := p.Update
	switch u.SessionUpdate {
	case "agent_thought_chunk":
		s.flushText()
		if u.Content != nil && u.Content.Text != "" {
			s.thinkBuf.WriteString(u.Content.Text)
			for _, ev := range s.activity.thinkingDelta(u.Content.Text) {
				s.emit(ev)
			}
		} else {
			for _, ev := range s.activity.thinkingStart() {
				s.emit(ev)
			}
		}
	case "agent_message_chunk":
		s.flushThinking()
		if u.Content == nil || u.Content.Text == "" {
			return
		}
		txt := u.Content.Text
		if strings.Contains(txt, "agent executor error:") {
			trimmed := strings.TrimSpace(txt)
			s.res.IsError = true
			s.res.Error = trimmed
			s.res.UsageLimited = s.res.UsageLimited || UsageLimit(trimmed)
			return
		}
		s.textBuf.WriteString(txt)
		if blocks := s.reply.feed(txt); len(blocks) > 0 {
			s.activity.touch()
			for _, ev := range blocks {
				s.emit(ev)
			}
		}
		if !s.reply.inFence {
			for _, ev := range s.activity.textDelta(txt) {
				s.emit(ev)
			}
		} else {
			for _, ev := range s.activity.heartbeatIfDue("writing_reply") {
				s.emit(ev)
			}
		}
	case "tool_call", "tool_call_update":
		s.flushThinking()
		s.flushText()
		id := u.ToolCallID
		if id == "" {
			return
		}
		args := u.Args
		if args == nil {
			args = u.RawInput
		}
		name := u.Name
		if name == "" {
			name = u.Title
		}
		tool := s.toolNames[id]
		var canon map[string]any
		if name != "" {
			tool, canon = antigravityTool(name, args)
			tool = strings.TrimPrefix(strings.TrimPrefix(tool, "mcp__"+lazyagentsServer+"_"), "_")
			s.toolNames[id] = tool
		} else if tool == "" {
			return
		}
		if !s.called[id] {
			s.called[id] = true
			s.activity.reset()
			s.res.Usage.ToolCalls++
			s.emit(Event{"tool_call", map[string]any{"id": id, "tool": tool, "input": canon}})
		}
		if (u.Status == "completed" || u.Status == "failed" || u.Status == "cancelled") && !s.finished[id] {
			s.finished[id] = true
			s.activity.reset()
			output, rawErr := extractAgyToolOutput(u.RawOutput, paramsRaw)
			isErr := u.Status == "failed" || u.Status == "cancelled" || rawErr
			s.noteImages(output)
			s.res.Usage.AddToolOutput(tool, int64(len(output)))
			s.emit(Event{"tool_result", map[string]any{"id": id, "tool": tool, "is_error": isErr, "output": clip(output, 4000)}})
		}
	case "usage_update":
		if u.Used > 0 {
			s.res.Usage.ContextTokens = u.Used
			if s.onContextTokens != nil {
				s.onContextTokens(u.Used)
			}
		}
	}
}

func extractAgyToolOutput(rawOutput json.RawMessage, updateParams json.RawMessage) (string, bool) {
	if len(rawOutput) > 0 && string(rawOutput) != "null" {
		var s string
		if json.Unmarshal(rawOutput, &s) == nil {
			return s, false
		}
		var obj struct {
			Output   string `json:"output"`
			Error    string `json:"error"`
			ExitCode *int   `json:"exit_code"`
		}
		if json.Unmarshal(rawOutput, &obj) == nil {
			isErr := obj.Error != "" || (obj.ExitCode != nil && *obj.ExitCode != 0)
			if obj.Error != "" {
				return obj.Error, true
			}
			if obj.Output != "" {
				return obj.Output, isErr
			}
		}
	}
	// Fallback: ACP tool_call_update carries content blocks as an array.
	var fallback struct {
		Update struct {
			Content []struct {
				Type    string `json:"type"`
				Content struct {
					Type string `json:"type"`
					Text string `json:"text"`
				} `json:"content"`
			} `json:"content"`
		} `json:"update"`
	}
	if json.Unmarshal(updateParams, &fallback) == nil {
		var parts []string
		for _, c := range fallback.Update.Content {
			if c.Content.Text != "" {
				parts = append(parts, c.Content.Text)
			}
		}
		if len(parts) > 0 {
			return strings.Join(parts, "\n"), false
		}
	}
	return rawText(rawOutput), false
}

func (s *agySessionState) finishPrompt(resultRaw json.RawMessage, rpcErr *agyRPCError) {
	s.flushThinking()
	s.flushText()
	if rpcErr != nil {
		msg := rpcErr.Message
		if len(rpcErr.Data) > 0 && string(rpcErr.Data) != "null" {
			msg = msg + ": " + string(rpcErr.Data)
		}
		s.fail(msg)
		return
	}
	var res struct {
		StopReason string `json:"stopReason"`
		Usage      *struct {
			InputTokens      int64 `json:"inputTokens"`
			OutputTokens     int64 `json:"outputTokens"`
			CachedReadTokens int64 `json:"cachedReadTokens"`
			TotalTokens      int64 `json:"totalTokens"`
		} `json:"usage"`
	}
	if json.Unmarshal(resultRaw, &res) == nil && res.Usage != nil {
		u := res.Usage
		s.res.Usage.SessionID = s.res.SessionID
		s.res.Usage.InputTokens = u.InputTokens + u.CachedReadTokens
		s.res.Usage.OutputTokens = u.OutputTokens
		s.res.Usage.CachedTokens = u.CachedReadTokens
		s.res.Usage.CacheReportedInputTokens = s.res.Usage.InputTokens
		s.res.Usage.CostSource = "unknown"
		s.emit(Event{"usage", map[string]any{
			"input_tokens":                s.res.Usage.InputTokens,
			"output_tokens":               s.res.Usage.OutputTokens,
			"cached_tokens":               s.res.Usage.CachedTokens,
			"cache_reported_input_tokens": s.res.Usage.CacheReportedInputTokens,
			"cost_source":                 "unknown",
			"cost_known":                  false,
		}})
	}
	if s.res.IsError {
		s.emit(Event{"error", map[string]any{"message": s.res.Error}})
	}
}

func runAgyStreamSession(stdin io.WriteCloser, stdout io.Reader, model string, cb SessionCallbacks) (Result, error) {
	if stdin != nil {
		_ = stdin.Close()
	}
	p := (Antigravity{}).NewParser(model)
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 256<<10), sessionMaxScanBytes)

	var seenSession string
	var lastContext int64
	dispatch := func(evs []Event) {
		res := p.Result()
		if res.SessionID != "" && res.SessionID != seenSession {
			seenSession = res.SessionID
			if cb.OnSession != nil {
				cb.OnSession(seenSession)
			}
		}
		for _, ev := range evs {
			if cb.OnEvent != nil {
				cb.OnEvent(ev)
			}
		}
		if res.Usage.ContextTokens > 0 && res.Usage.ContextTokens != lastContext {
			lastContext = res.Usage.ContextTokens
			if cb.OnContextTokens != nil {
				cb.OnContextTokens(lastContext)
			}
		}
	}

	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		if cb.OnRaw != nil {
			cb.OnRaw(line)
		}
		dispatch(p.Line(line))
	}
	if err := sc.Err(); err != nil {
		return p.Result(), err
	}
	return p.Result(), nil
}

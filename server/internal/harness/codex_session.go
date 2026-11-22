package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

var _ SessionHarness = Codex{}

// SessionInvocation returns the command, env, and config files for driving
// Codex over `codex app-server --listen stdio://`.
func (Codex) SessionInvocation(ws Workspace, t Turn) (Invocation, error) {
	b, err := buildCodexConfig(ws, t, true)
	if err != nil {
		return Invocation{}, err
	}
	argv := []string{"codex", "app-server", "--listen", "stdio://", "--strict-config"}
	for _, c := range b.cfg {
		argv = append(argv, "-c", c)
	}
	return Invocation{Argv: argv, Env: b.env, Files: b.files}, nil
}

// validateCodexHooks checks hooks/list output from codex app-server: Vesper's
// exact sessionFlags PreToolUse command hook must be enabled once, and any
// other enabled hook must already be trusted or managed.
func validateCodexHooks(raw json.RawMessage, expectedCommand string) error {
	var res struct {
		Data []struct {
			Errors []any `json:"errors"`
			Hooks  []struct {
				Enabled     bool   `json:"enabled"`
				Source      string `json:"source"`
				HandlerType string `json:"handlerType"`
				Command     string `json:"command"`
				EventName   string `json:"eventName"`
				Matcher     string `json:"matcher"`
				Async       bool   `json:"async"`
				TrustStatus string `json:"trustStatus"`
			} `json:"hooks"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return fmt.Errorf("codex hooks/list decode: %w", err)
	}
	found := 0
	for _, group := range res.Data {
		if len(group.Errors) > 0 {
			return fmt.Errorf("codex hook configuration has errors")
		}
		for _, h := range group.Hooks {
			if !h.Enabled {
				continue
			}
			if h.Source == "sessionFlags" && h.HandlerType == "command" && h.Command == expectedCommand && h.EventName == "preToolUse" && h.Matcher == "*" && !h.Async {
				found++
			} else if h.TrustStatus != "trusted" && h.TrustStatus != "managed" {
				return fmt.Errorf("unreviewed Codex hook found; review it in Codex before running Vesper")
			}
		}
	}
	if found != 1 {
		return fmt.Errorf("vesper policy hook was not loaded exactly once (found %d); refusing to run without tool gating", found)
	}
	return nil
}

// RunSession drives a Codex app-server stdio turn: handshakes and validates
// hooks/list before granting bypass_hook_trust on thread/start or thread/resume,
// starts the turn, enforces CheckTool on any approval requests, streams events,
// captures ContextTokens, and interrupts via turn/interrupt.
func (c Codex) RunSession(ctx context.Context, stdin io.WriteCloser, stdout io.Reader, ws Workspace, t Turn, cb SessionCallbacks) (Result, error) {
	noTools := t.Spec.HarnessOptions[agentdef.OptionNoTools] == "true"
	hookEnv, err := codexHookEnv(ws, codexHookRelPath(t.ConfigTag), noTools)
	if err != nil {
		return Result{}, err
	}
	expectedCmd := hookEnv["LAZYAGENTS_POLICY_HOOK_COMMAND"]

	w := newLineWriter(stdin)
	ctrl := &codexControl{w: w}
	ctrl.nextID.Store(10)
	var wg sync.WaitGroup
	defer func() {
		ctrl.closeAll()
		_ = w.Close()
		wg.Wait()
	}()
	if cb.OnControl != nil {
		cb.OnControl(ctrl)
	}

	const (
		reqInit   int64 = 1
		reqHooks  int64 = 2
		reqThread int64 = 3
		reqTurn   int64 = 4
	)

	if err := w.writeJSON(map[string]any{
		"jsonrpc": "2.0",
		"id":      reqInit,
		"method":  "initialize",
		"params": map[string]any{
			"clientInfo":   map[string]any{"name": "vesper", "version": "1"},
			"capabilities": map[string]any{"experimentalApi": true},
		},
	}); err != nil {
		return Result{}, fmt.Errorf("codex write initialize: %w", err)
	}

	st := &codexSessionState{
		model:    t.Spec.Model,
		prices:   c.Prices,
		baseline: c.Baseline,
		emit: func(ev Event) {
			if cb.OnEvent != nil {
				cb.OnEvent(ev)
			}
		},
		onContextTokens: cb.OnContextTokens,
		onTextDelta:     cb.OnTextDelta,
	}

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 256<<10), sessionMaxScanBytes)
	for sc.Scan() {
		line := append([]byte(nil), sc.Bytes()...)
		if cb.OnRaw != nil {
			cb.OnRaw(line)
		}
		var msg codexRPCMessage
		if json.Unmarshal(line, &msg) != nil {
			continue
		}

		// Server-initiated RPC request (approvals / dynamic tools / user input).
		if msg.Method != "" && len(msg.ID) > 0 && string(msg.ID) != "null" {
			idRaw := append(json.RawMessage(nil), msg.ID...)
			method := msg.Method
			paramsRaw := append(json.RawMessage(nil), msg.Params...)
			wg.Add(1)
			go func() {
				defer wg.Done()
				handleCodexServerRequest(ctx, w, cb.CheckTool, noTools, idRaw, method, paramsRaw)
			}()
			continue
		}

		// Response to one of our handshake requests.
		if msg.Method == "" && len(msg.ID) > 0 && string(msg.ID) != "null" {
			var idNum int64
			if json.Unmarshal(msg.ID, &idNum) != nil {
				continue
			}
			switch idNum {
			case reqInit:
				if msg.Error != nil {
					return st.res, fmt.Errorf("codex initialize: %s", msg.Error.Message)
				}
				if err := w.writeJSON(map[string]any{"jsonrpc": "2.0", "method": "initialized"}); err != nil {
					return st.res, fmt.Errorf("codex write initialized: %w", err)
				}
				if err := w.writeJSON(map[string]any{
					"jsonrpc": "2.0",
					"id":      reqHooks,
					"method":  "hooks/list",
					"params":  map[string]any{"cwd": ws.Dir},
				}); err != nil {
					return st.res, fmt.Errorf("codex write hooks/list: %w", err)
				}
			case reqHooks:
				if msg.Error != nil {
					return st.res, fmt.Errorf("codex hooks/list: %s", msg.Error.Message)
				}
				if err := validateCodexHooks(msg.Result, expectedCmd); err != nil {
					return st.res, err
				}
				method := "thread/start"
				params := map[string]any{
					"cwd":            ws.Dir,
					"approvalPolicy": "never",
					"config":         map[string]any{"bypass_hook_trust": true},
				}
				if t.Spec.Model != "" {
					params["model"] = t.Spec.Model
				}
				if t.SystemAppend != "" {
					params["developerInstructions"] = t.SystemAppend
				}
				if t.SessionID != "" {
					method = "thread/resume"
					params["threadId"] = t.SessionID
				}
				if err := w.writeJSON(map[string]any{
					"jsonrpc": "2.0",
					"id":      reqThread,
					"method":  method,
					"params":  params,
				}); err != nil {
					return st.res, fmt.Errorf("codex write %s: %w", method, err)
				}
			case reqThread:
				if msg.Error != nil {
					st.fail(msg.Error.Message)
					return st.res, nil
				}
				var tr struct {
					Thread struct {
						ID string `json:"id"`
					} `json:"thread"`
				}
				if err := json.Unmarshal(msg.Result, &tr); err != nil || tr.Thread.ID == "" {
					st.fail("codex thread response missing thread id")
					return st.res, nil
				}
				threadID := tr.Thread.ID
				ctrl.setThread(threadID)
				st.markStarted(threadID)
				if cb.OnSession != nil {
					cb.OnSession(threadID)
				}
				turnParams := codexTurnStartParams(ws, t, threadID)
				if err := w.writeJSON(map[string]any{
					"jsonrpc": "2.0",
					"id":      reqTurn,
					"method":  "turn/start",
					"params":  turnParams,
				}); err != nil {
					return st.res, fmt.Errorf("codex write turn/start: %w", err)
				}
			case reqTurn:
				if msg.Error != nil {
					st.fail(msg.Error.Message)
					return st.res, nil
				}
				var tr struct {
					Turn struct {
						ID string `json:"id"`
					} `json:"turn"`
				}
				if json.Unmarshal(msg.Result, &tr) == nil && tr.Turn.ID != "" {
					ctrl.setTurn(tr.Turn.ID)
				}
			default:
				ctrl.resolve(idNum, msg.Error)
			}
			continue
		}

		// Server notification.
		if msg.Method != "" {
			if done := st.handleNotification(msg.Method, msg.Params); done {
				_ = w.Close()
				return st.res, nil
			}
		}
	}
	if err := sc.Err(); err != nil {
		return st.res, err
	}
	return st.res, nil
}

func codexTurnStartParams(ws Workspace, t Turn, threadID string) map[string]any {
	inputs := []map[string]any{{"type": "text", "text": t.Prompt}}
	for _, im := range t.Images {
		p := im
		if !filepath.IsAbs(p) && ws.Dir != "" {
			p = filepath.Join(ws.Dir, p)
		}
		inputs = append(inputs, map[string]any{"type": "localImage", "path": p})
	}
	params := map[string]any{
		"threadId": threadID,
		"cwd":      ws.Dir,
		"input":    inputs,
	}
	if effort := t.Spec.HarnessOptions["effort"]; effort != "" {
		params["effort"] = effort
	}
	sandbox := t.Spec.HarnessOptions["sandbox"]
	if !ws.ContainerSandbox && ws.DependencyCacheDir != "" && allowed(t.Spec, "tests:run") && !allowed(t.Spec, "repo:write") && (sandbox == "" || sandbox == "workspace-write") {
		params["sandboxPolicy"] = map[string]any{
			"type":          "workspaceWrite",
			"writableRoots": []string{ws.DependencyCacheDir},
		}
	}
	return params
}

type codexRPCError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type codexControl struct {
	w       *lineWriter
	nextID  atomic.Int64
	mu      sync.Mutex
	thread  string
	turn    string
	closed  bool
	pending map[int64]chan *codexRPCError
}

func (c *codexControl) setThread(id string) {
	c.mu.Lock()
	c.thread = id
	c.mu.Unlock()
}

func (c *codexControl) setTurn(id string) {
	c.mu.Lock()
	c.turn = id
	c.mu.Unlock()
}

func (c *codexControl) closeAll() {
	c.mu.Lock()
	if !c.closed {
		c.closed = true
		for id, ch := range c.pending {
			close(ch)
			delete(c.pending, id)
		}
	}
	c.mu.Unlock()
}

func (c *codexControl) resolve(id int64, rpcErr *codexRPCError) {
	c.mu.Lock()
	ch, ok := c.pending[id]
	if ok {
		delete(c.pending, id)
	}
	c.mu.Unlock()
	if ok {
		ch <- rpcErr
	}
}

func (c *codexControl) Interrupt() error {
	c.mu.Lock()
	threadID, turnID := c.thread, c.turn
	c.mu.Unlock()
	if threadID == "" || turnID == "" {
		return nil
	}
	return c.w.writeJSON(map[string]any{
		"jsonrpc": "2.0",
		"id":      c.nextID.Add(1),
		"method":  "turn/interrupt",
		"params": map[string]any{
			"threadId": threadID,
			"turnId":   turnID,
		},
	})
}

func (c *codexControl) Steer(message string) error {
	if strings.TrimSpace(message) == "" {
		return fmt.Errorf("codex steer: empty message")
	}
	id := c.nextID.Add(1)
	ch := make(chan *codexRPCError, 1)
	c.mu.Lock()
	if c.closed || c.thread == "" || c.turn == "" {
		c.mu.Unlock()
		return ErrSteerUnsupported
	}
	threadID, turnID := c.thread, c.turn
	if c.pending == nil {
		c.pending = map[int64]chan *codexRPCError{}
	}
	c.pending[id] = ch
	c.mu.Unlock()

	if err := c.w.writeJSON(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  "turn/steer",
		"params": map[string]any{
			"threadId":       threadID,
			"expectedTurnId": turnID,
			"input":          []map[string]any{{"type": "text", "text": message}},
		},
	}); err != nil {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return err
	}

	timer := time.NewTimer(2 * time.Second)
	defer timer.Stop()
	select {
	case rpcErr, ok := <-ch:
		if !ok {
			return ErrSteerUnsupported
		}
		if rpcErr != nil {
			return fmt.Errorf("%w: %s", ErrSteerUnsupported, rpcErr.Message)
		}
		return nil
	case <-timer.C:
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
		return fmt.Errorf("%w: timed out waiting for turn/steer ack", ErrSteerUnsupported)
	}
}

type codexRPCMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *codexRPCError  `json:"error"`
}

func handleCodexServerRequest(ctx context.Context, w *lineWriter, fn PolicyFunc, noTools bool, id json.RawMessage, method string, paramsRaw json.RawMessage) {
	reply := func(result any) {
		_ = w.writeJSON(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
	}
	switch method {
	case "item/commandExecution/requestApproval":
		var p struct {
			Command string `json:"command"`
			Cwd     string `json:"cwd"`
		}
		_ = json.Unmarshal(paramsRaw, &p)
		allow, _ := checkPolicy(ctx, fn, noTools, "Bash", map[string]any{"command": p.Command, "cwd": p.Cwd})
		if allow {
			reply(map[string]any{"decision": "accept"})
		} else {
			reply(map[string]any{"decision": "decline"})
		}
	case "execCommandApproval":
		var p struct {
			Command []string `json:"command"`
			Cwd     string   `json:"cwd"`
		}
		_ = json.Unmarshal(paramsRaw, &p)
		allow, _ := checkPolicy(ctx, fn, noTools, "Bash", map[string]any{"command": strings.Join(p.Command, " "), "cwd": p.Cwd})
		if allow {
			reply(map[string]any{"decision": "approved"})
		} else {
			reply(map[string]any{"decision": "denied"})
		}
	case "item/fileChange/requestApproval":
		var p struct {
			GrantRoot string `json:"grantRoot"`
			Reason    string `json:"reason"`
		}
		_ = json.Unmarshal(paramsRaw, &p)
		allow, _ := checkPolicy(ctx, fn, noTools, "Edit", map[string]any{"file_path": p.GrantRoot, "reason": p.Reason})
		if allow {
			reply(map[string]any{"decision": "accept"})
		} else {
			reply(map[string]any{"decision": "decline"})
		}
	case "applyPatchApproval":
		var p struct {
			GrantRoot   string         `json:"grantRoot"`
			FileChanges map[string]any `json:"fileChanges"`
		}
		_ = json.Unmarshal(paramsRaw, &p)
		allow, _ := checkPolicy(ctx, fn, noTools, "Edit", map[string]any{"file_path": p.GrantRoot, "fileChanges": p.FileChanges})
		if allow {
			reply(map[string]any{"decision": "approved"})
		} else {
			reply(map[string]any{"decision": "denied"})
		}
	default:
		_ = w.writeJSON(map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"error": map[string]any{
				"code":    -32601,
				"message": "unsupported server request: " + method,
			},
		})
	}
}

type codexSessionState struct {
	model           string
	prices          map[string]Price
	baseline        Usage
	res             Result
	startedEmitted  bool
	hasTokenUsage   bool
	reply           replyScanner
	replyItemID     string
	activity        activityTracker
	emit            func(Event)
	onContextTokens func(int64)
	onTextDelta     func(string)
}

func (s *codexSessionState) markStarted(threadID string) {
	s.res.SessionID = threadID
	if s.startedEmitted {
		return
	}
	s.startedEmitted = true
	s.emit(Event{"lifecycle", map[string]any{"state": "harness_started", "harness": agentdef.HarnessCodex, "model": s.model, "session_id": threadID}})
}

func (s *codexSessionState) fail(msg string) {
	if msg == "" {
		msg = "turn failed"
	}
	s.res.IsError = true
	s.res.Error = msg
	s.res.UsageLimited = s.res.UsageLimited || UsageLimit(msg)
	s.emit(Event{"error", map[string]any{"message": msg}})
}

func (s *codexSessionState) handleNotification(method string, paramsRaw json.RawMessage) bool {
	switch method {
	case "thread/started":
		var p struct {
			Thread struct {
				ID string `json:"id"`
			} `json:"thread"`
		}
		if json.Unmarshal(paramsRaw, &p) == nil && p.Thread.ID != "" {
			s.markStarted(p.Thread.ID)
		}
	case "item/agentMessage/delta":
		var p struct {
			ItemID string `json:"itemId"`
			Delta  string `json:"delta"`
		}
		if json.Unmarshal(paramsRaw, &p) == nil && p.Delta != "" {
			if s.onTextDelta != nil {
				s.onTextDelta(p.Delta)
			}
			if p.ItemID != "" && p.ItemID != s.replyItemID {
				s.reply = replyScanner{}
				s.replyItemID = p.ItemID
				s.activity.resetText()
			}
			if blocks := s.reply.feed(p.Delta); len(blocks) > 0 {
				s.activity.touch()
				for _, ev := range blocks {
					s.emit(ev)
				}
			}
			if !s.reply.inFence {
				for _, ev := range s.activity.textDelta(p.Delta) {
					s.emit(ev)
				}
			} else {
				for _, ev := range s.activity.heartbeatIfDue("writing_reply") {
					s.emit(ev)
				}
			}
		}
	case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
		var p struct {
			Delta string `json:"delta"`
		}
		if json.Unmarshal(paramsRaw, &p) == nil && p.Delta != "" {
			for _, ev := range s.activity.thinkingDelta(p.Delta) {
				s.emit(ev)
			}
		}
	case "item/started", "item/completed":
		var p struct {
			Item codexV2Item `json:"item"`
		}
		if json.Unmarshal(paramsRaw, &p) == nil && p.Item.Type != "" {
			s.handleItem(method == "item/completed", p.Item)
		}
	case "thread/tokenUsage/updated":
		var p struct {
			TokenUsage struct {
				Total codexV2Usage `json:"total"`
				Last  codexV2Usage `json:"last"`
			} `json:"tokenUsage"`
		}
		if json.Unmarshal(paramsRaw, &p) == nil {
			s.hasTokenUsage = true
			if p.TokenUsage.Last.InputTokens > 0 {
				s.res.Usage.ContextTokens = p.TokenUsage.Last.InputTokens
				if s.onContextTokens != nil {
					s.onContextTokens(s.res.Usage.ContextTokens)
				}
			}
			tot := p.TokenUsage.Total
			baseline := s.baseline
			if baseline.SessionID != "" && baseline.SessionID != s.res.SessionID {
				baseline = Usage{}
			}
			if tot.InputTokens < baseline.SessionInputTokens || tot.OutputTokens < baseline.SessionOutputTokens || tot.CachedInputTokens < baseline.SessionCachedTokens {
				baseline = Usage{}
			}
			s.res.Usage.InputTokens = tot.InputTokens - baseline.SessionInputTokens
			s.res.Usage.OutputTokens = tot.OutputTokens - baseline.SessionOutputTokens
			s.res.Usage.CachedTokens = max(0, tot.CachedInputTokens-baseline.SessionCachedTokens)
			s.res.Usage.SessionID = s.res.SessionID
			s.res.Usage.SessionInputTokens = tot.InputTokens
			s.res.Usage.SessionOutputTokens = tot.OutputTokens
			s.res.Usage.SessionCachedTokens = tot.CachedInputTokens
			s.res.Usage.SessionCacheKnown = tot.CachedInputTokens >= 0 && tot.CachedInputTokens <= tot.InputTokens
			if tot.CachedInputTokens >= 0 && tot.CachedInputTokens <= tot.InputTokens && (baseline.SessionInputTokens == 0 || baseline.SessionCacheKnown) && s.res.Usage.CachedTokens <= s.res.Usage.InputTokens {
				s.res.Usage.CacheReportedInputTokens = s.res.Usage.InputTokens
			}
		}
	case "error":
		var p struct {
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
			Message string `json:"message"`
		}
		if json.Unmarshal(paramsRaw, &p) == nil {
			msg := p.Message
			if msg == "" && p.Error != nil {
				msg = p.Error.Message
			}
			if msg != "" && !strings.HasPrefix(msg, "Reconnecting") {
				s.res.Error = msg
				s.res.UsageLimited = s.res.UsageLimited || UsageLimit(msg)
				s.emit(Event{"error", map[string]any{"message": msg}})
			}
		}
	case "turn/completed":
		var p struct {
			Turn struct {
				Status string `json:"status"`
				Error  *struct {
					Message        string          `json:"message"`
					CodexErrorInfo json.RawMessage `json:"codexErrorInfo"`
				} `json:"error"`
			} `json:"turn"`
		}
		_ = json.Unmarshal(paramsRaw, &p)
		s.res.Usage.CostSource = "unknown"
		cost, known := computeCost(s.model, s.res.Usage, s.prices)
		if known && (s.res.Usage.CacheReportedInputTokens < s.res.Usage.InputTokens || s.res.Usage.CachedTokens > s.res.Usage.InputTokens) {
			price, ok := s.prices[s.model]
			if !ok {
				price = Prices[s.model]
			}
			if price.Input != price.CachedInput || s.res.Usage.CachedTokens > s.res.Usage.InputTokens {
				known = false
			}
		}
		if known {
			s.res.Usage.CostUSD, s.res.Usage.CostSource = cost, "computed"
		}
		if s.hasTokenUsage {
			payload := map[string]any{
				"input_tokens":                s.res.Usage.InputTokens,
				"output_tokens":               s.res.Usage.OutputTokens,
				"cached_tokens":               s.res.Usage.CachedTokens,
				"cache_reported_input_tokens": s.res.Usage.CacheReportedInputTokens,
				"cost_source":                 s.res.Usage.CostSource,
				"cost_known":                  known,
			}
			if known {
				payload["cost_usd"] = s.res.Usage.CostUSD
			}
			s.emit(Event{"usage", payload})
		}
		if p.Turn.Status == "failed" || p.Turn.Error != nil {
			msg := "turn failed"
			extra := ""
			if p.Turn.Error != nil {
				if p.Turn.Error.Message != "" {
					msg = p.Turn.Error.Message
				}
				extra = string(p.Turn.Error.CodexErrorInfo)
			}
			s.res.IsError = true
			s.res.Error = msg
			s.res.UsageLimited = s.res.UsageLimited || UsageLimit(msg+" "+extra)
			s.emit(Event{"error", map[string]any{"message": msg}})
		}
		return true
	}
	return false
}

type codexV2Usage struct {
	InputTokens       int64 `json:"inputTokens"`
	CachedInputTokens int64 `json:"cachedInputTokens"`
	OutputTokens      int64 `json:"outputTokens"`
}

type codexV2Item struct {
	ID               string          `json:"id"`
	Type             string          `json:"type"`
	Text             string          `json:"text"`
	Summary          []string        `json:"summary"`
	Content          []string        `json:"content"`
	Command          string          `json:"command"`
	AggregatedOutput string          `json:"aggregatedOutput"`
	ExitCode         *int            `json:"exitCode"`
	Status           string          `json:"status"`
	Server           string          `json:"server"`
	Tool             string          `json:"tool"`
	Arguments        json.RawMessage `json:"arguments"`
	Result           json.RawMessage `json:"result"`
	Error            json.RawMessage `json:"error"`
	Changes          []struct {
		Path string `json:"path"`
		Kind struct {
			Type string `json:"type"`
		} `json:"kind"`
	} `json:"changes"`
	Query string `json:"query"`
}

func (s *codexSessionState) handleItem(done bool, it codexV2Item) {
	switch it.Type {
	case "agentMessage":
		if !done {
			return
		}
		s.reply = replyScanner{}
		s.replyItemID = ""
		s.activity.reset()
		if strings.TrimSpace(it.Text) == "" {
			return
		}
		s.res.Final = it.Text
		s.emit(Event{"message", map[string]any{"role": "assistant", "text": it.Text}})
	case "commandExecution":
		s.activity.reset()
		if !done {
			s.res.Usage.ToolCalls++
			s.emit(Event{"tool_call", map[string]any{"id": it.ID, "tool": "shell", "input": map[string]any{"command": it.Command}}})
			return
		}
		exit := 0
		if it.ExitCode != nil {
			exit = *it.ExitCode
		}
		s.emit(Event{"tool_result", map[string]any{
			"id":        it.ID,
			"tool":      "shell",
			"is_error":  exit != 0 || it.Status == "failed" || it.Status == "declined",
			"exit_code": exit,
			"output":    clip(it.AggregatedOutput, 4000),
		}})
	case "mcpToolCall":
		s.activity.reset()
		tool := it.Tool
		if it.Server != "" && it.Server != lazyagentsServer {
			tool = it.Server + "." + it.Tool
		}
		if !done {
			s.res.Usage.ToolCalls++
			var args any
			_ = json.Unmarshal(it.Arguments, &args)
			s.emit(Event{"tool_call", map[string]any{"id": it.ID, "tool": tool, "input": args}})
			return
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
		s.emit(Event{"tool_result", map[string]any{
			"id":       it.ID,
			"tool":     tool,
			"is_error": it.Status == "failed" || hasError || resultFlags.IsError || resultFlags.IsErrorSnake,
			"output":   clip(out, 4000),
		}})
	case "fileChange":
		if !done {
			return
		}
		s.activity.reset()
		files := make([]string, len(it.Changes))
		for i, c := range it.Changes {
			files[i] = strings.TrimSpace(c.Kind.Type + " " + c.Path)
		}
		s.res.Usage.ToolCalls++
		s.emit(Event{"tool_call", map[string]any{"id": it.ID, "tool": "apply_patch", "input": map[string]any{"files": files}, "status": it.Status}})
	case "webSearch":
		if !done {
			return
		}
		s.activity.reset()
		s.res.Usage.ToolCalls++
		s.emit(Event{"tool_call", map[string]any{"id": it.ID, "tool": "web_search", "input": map[string]any{"query": it.Query}}})
	case "reasoning":
		if !done {
			return
		}
		s.activity.reset()
		parts := it.Content
		if len(parts) == 0 {
			parts = it.Summary
		}
		if text := strings.Join(parts, "\n"); text != "" {
			if ev, ok := thinkingEvent(text); ok {
				s.emit(ev)
			}
		}
	}
}

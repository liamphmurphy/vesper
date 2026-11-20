package main

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	protoLegacy        = ""
	protoClaudeSession = "claude-session"
	protoCodexServer   = "codex-app-server"
	protoAgyACP        = "agy-acp"
)

var (
	sessionProto string
	outMu        sync.Mutex
	inMu         sync.Mutex
	pendingRPC   = map[string]chan json.RawMessage{}
	interrupted  = make(chan struct{})
	interruptOne sync.Once
	stdinClosed  = make(chan struct{})
	acpPromptID  json.RawMessage
	codexTurnID  = "turn_1"
)

func signalInterrupt() {
	interruptOne.Do(func() { close(interrupted) })
}

func watchSignals() {
	ch := make(chan os.Signal, 2)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-ch
		signalInterrupt()
	}()
}

func contextTokenCount() int64 {
	n := int64(2000)
	if v := os.Getenv("FAKE_HARNESS_CONTEXT_TOKENS"); v != "" {
		_, _ = fmt.Sscan(v, &n)
	}
	return n
}

func writeOutJSON(v any) {
	b, _ := json.Marshal(v)
	outMu.Lock()
	fmt.Println(string(b))
	outMu.Unlock()
}

func registerPending(id string) chan json.RawMessage {
	ch := make(chan json.RawMessage, 1)
	inMu.Lock()
	pendingRPC[id] = ch
	inMu.Unlock()
	return ch
}

func resolvePending(id string, msg json.RawMessage) bool {
	inMu.Lock()
	ch, ok := pendingRPC[id]
	if ok {
		delete(pendingRPC, id)
	}
	inMu.Unlock()
	if ok {
		ch <- msg
		return true
	}
	return false
}

func normalizeID(raw json.RawMessage) string {
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return s
	}
	return strings.TrimSpace(string(raw))
}

func parseCodexConfigArgs(args []string) (mcpURL, tokenEnv, mcpApproval string) {
	for i := 0; i < len(args); i++ {
		if args[i] != "-c" || i+1 >= len(args) {
			continue
		}
		kv := args[i+1]
		i++
		k, v, _ := strings.Cut(kv, "=")
		v = strings.Trim(v, `"`)
		switch k {
		case "mcp_servers.lazyagents.url":
			mcpURL = v
		case "mcp_servers.lazyagents.bearer_token_env_var":
			tokenEnv = v
		case "mcp_servers.lazyagents.default_tools_approval_mode":
			mcpApproval = v
		}
	}
	return
}

// claudeSessionHandshake handles Claude Code stream-json stdin/stdout:
// initializes PreToolUse callbacks, waits for the user turn, and routes later
// control_responses and interrupt requests on stdin while the turn runs.
func claudeSessionHandshake() (prompt string, inline []string) {
	sessionProto = protoClaudeSession
	watchSignals()
	type stdinLine struct {
		Type      string          `json:"type"`
		RequestID string          `json:"request_id"`
		Request   json.RawMessage `json:"request"`
		Response  struct {
			Subtype   string          `json:"subtype"`
			RequestID string          `json:"request_id"`
			Response  json.RawMessage `json:"response"`
		} `json:"response"`
		Message struct {
			Content json.RawMessage `json:"content"`
		} `json:"message"`
	}
	userReady := make(chan struct{})
	var userOnce sync.Once
	go func() {
		defer close(stdinClosed)
		sc := bufio.NewScanner(os.Stdin)
		sc.Buffer(make([]byte, 256<<10), 16<<20)
		for sc.Scan() {
			raw := append([]byte(nil), sc.Bytes()...)
			var m stdinLine
			if json.Unmarshal(raw, &m) != nil {
				continue
			}
			switch m.Type {
			case "control_request":
				var req struct {
					Subtype string `json:"subtype"`
				}
				_ = json.Unmarshal(m.Request, &req)
				writeOutJSON(map[string]any{
					"type": "control_response",
					"response": map[string]any{
						"subtype":    "success",
						"request_id": m.RequestID,
						"response":   map[string]any{},
					},
				})
				if req.Subtype == "interrupt" {
					signalInterrupt()
				}
			case "control_response":
				resolvePending(m.Response.RequestID, raw)
			case "user":
				var txt string
				if json.Unmarshal(m.Message.Content, &txt) == nil {
					prompt = txt
				} else {
					var blocks []struct {
						Text   string `json:"text"`
						Source struct {
							Data string `json:"data"`
						} `json:"source"`
					}
					if json.Unmarshal(m.Message.Content, &blocks) == nil {
						for _, bl := range blocks {
							if bl.Source.Data == "" {
								prompt = bl.Text
								continue
							}
							b, _ := base64.StdEncoding.DecodeString(bl.Source.Data)
							inline = append(inline, string(b))
						}
					}
				}
				userOnce.Do(func() { close(userReady) })
			}
		}
		userOnce.Do(func() { close(userReady) })
	}()
	select {
	case <-userReady:
	case <-interrupted:
	}
	return prompt, inline
}

// runCodexAppServer handles `codex app-server`: serves discovery requests
// (model/list, account/rateLimits/read) as well as full turn sessions.
func runCodexAppServer(args []string) (turnPrompt, turnResume, turnModel, mcpURL, tokenEnv, mcpApproval string, images []string, hasTurn bool) {
	codex = true
	sessionProto = protoCodexServer
	watchSignals()
	mcpURL, tokenEnv, mcpApproval = parseCodexConfigArgs(args)

	type rpcMsg struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
		Result json.RawMessage `json:"result"`
	}
	reqs := make(chan rpcMsg, 16)
	go func() {
		defer close(stdinClosed)
		sc := bufio.NewScanner(os.Stdin)
		sc.Buffer(make([]byte, 256<<10), 16<<20)
		for sc.Scan() {
			raw := append([]byte(nil), sc.Bytes()...)
			var msg rpcMsg
			if json.Unmarshal(raw, &msg) != nil {
				continue
			}
			if msg.Method == "" && len(msg.ID) > 0 && string(msg.ID) != "null" {
				resolvePending(normalizeID(msg.ID), raw)
				continue
			}
			if msg.Method == "turn/interrupt" {
				if len(msg.ID) > 0 && string(msg.ID) != "null" {
					writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{}})
				}
				signalInterrupt()
				continue
			}
			reqs <- msg
		}
		close(reqs)
	}()

	for msg := range reqs {
		switch msg.Method {
		case "initialize":
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"userAgent": "fake-codex/1"}})
		case "initialized":
		case "model/list":
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"data": []any{map[string]any{"model": "gpt-5-codex", "displayName": "GPT-5 Codex (fake)", "isDefault": true}}}})
		case "account/rateLimits/read":
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"rateLimits": map[string]any{"limitId": "codex", "planType": "plus",
				"primary":   map[string]any{"usedPercent": 46, "windowDurationMins": 300, "resetsAt": time.Now().Add(3 * time.Hour).Unix()},
				"secondary": map[string]any{"usedPercent": 72, "windowDurationMins": 10080, "resetsAt": time.Now().Add(120 * time.Hour).Unix()}}}})
		case "hooks/list":
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"data": []any{map[string]any{"errors": []any{}, "hooks": []any{map[string]any{
				"enabled": true, "source": "sessionFlags", "handlerType": "command", "command": os.Getenv("LAZYAGENTS_POLICY_HOOK_COMMAND"),
				"eventName": "preToolUse", "matcher": "*", "trustStatus": "untrusted",
			}}}}}})
		case "thread/start":
			var p struct {
				Model string `json:"model"`
			}
			_ = json.Unmarshal(msg.Params, &p)
			if p.Model != "" {
				turnModel = p.Model
			}
			session = newUUID()
			turnResume = ""
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"thread": map[string]any{"id": session}}})
		case "thread/resume":
			var p struct {
				ThreadID string `json:"threadId"`
				Model    string `json:"model"`
			}
			_ = json.Unmarshal(msg.Params, &p)
			if p.Model != "" {
				turnModel = p.Model
			}
			if os.Getenv("FAKE_HARNESS_RESUME") == "gone" {
				writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "error": map[string]any{
					"code":    -32600,
					"message": "No conversation found with session ID: " + p.ThreadID,
				}})
				waitEOFOrTimeout(5 * time.Second)
				return "", p.ThreadID, turnModel, mcpURL, tokenEnv, mcpApproval, nil, false
			}
			turnResume = p.ThreadID
			session = p.ThreadID
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"thread": map[string]any{"id": session}}})
		case "turn/start":
			var p struct {
				Model string `json:"model"`
				Input []struct {
					Type string `json:"type"`
					Text string `json:"text"`
					Path string `json:"path"`
				} `json:"input"`
			}
			_ = json.Unmarshal(msg.Params, &p)
			if p.Model != "" {
				turnModel = p.Model
			}
			for _, in := range p.Input {
				switch in.Type {
				case "text":
					turnPrompt = in.Text
				case "localImage":
					images = append(images, in.Path)
				}
			}
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"turn": map[string]any{"id": codexTurnID}}})
			return turnPrompt, turnResume, turnModel, mcpURL, tokenEnv, mcpApproval, images, true
		default:
			if len(msg.ID) > 0 && string(msg.ID) != "null" {
				writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{}})
			}
		}
	}
	return "", "", "", mcpURL, tokenEnv, mcpApproval, nil, false
}

// runAgyACPSession handles `agy acp --stdio` handshakes and starts a turn on session/prompt.
func runAgyACPSession() (turnPrompt, turnResume, turnModel string, inline []string, hasTurn bool) {
	sessionProto = protoAgyACP
	watchSignals()
	type rpcMsg struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params json.RawMessage `json:"params"`
	}
	reqs := make(chan rpcMsg, 16)
	go func() {
		defer close(stdinClosed)
		sc := bufio.NewScanner(os.Stdin)
		sc.Buffer(make([]byte, 256<<10), 16<<20)
		for sc.Scan() {
			raw := append([]byte(nil), sc.Bytes()...)
			var msg rpcMsg
			if json.Unmarshal(raw, &msg) != nil {
				continue
			}
			if msg.Method == "" && len(msg.ID) > 0 && string(msg.ID) != "null" {
				resolvePending(normalizeID(msg.ID), raw)
				continue
			}
			if msg.Method == "session/cancel" {
				signalInterrupt()
				continue
			}
			reqs <- msg
		}
		close(reqs)
	}()

	for msg := range reqs {
		switch msg.Method {
		case "initialize":
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"protocolVersion": 1}})
		case "authenticate":
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{}})
		case "session/new":
			session = newUUID()
			turnResume = ""
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"sessionId": session}})
		case "session/load":
			var p struct {
				SessionID string `json:"sessionId"`
			}
			_ = json.Unmarshal(msg.Params, &p)
			if os.Getenv("FAKE_HARNESS_RESUME") == "gone" {
				writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "error": map[string]any{
					"code":    -32000,
					"message": "No conversation found with session ID: " + p.SessionID,
				}})
				waitEOFOrTimeout(5 * time.Second)
				return "", p.SessionID, turnModel, nil, false
			}
			turnResume = p.SessionID
			session = p.SessionID
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{"sessionId": session}})
		case "session/set_config_option":
			var p struct {
				ConfigID string `json:"configId"`
				Value    string `json:"value"`
			}
			_ = json.Unmarshal(msg.Params, &p)
			if p.ConfigID == "model" && p.Value != "" {
				turnModel = p.Value
			}
			writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{}})
		case "session/prompt":
			acpPromptID = append(json.RawMessage(nil), msg.ID...)
			var p struct {
				Prompt []struct {
					Type string `json:"type"`
					Text string `json:"text"`
					Data string `json:"data"`
				} `json:"prompt"`
			}
			_ = json.Unmarshal(msg.Params, &p)
			for _, bl := range p.Prompt {
				switch bl.Type {
				case "text":
					turnPrompt = bl.Text
				case "image":
					b, _ := base64.StdEncoding.DecodeString(bl.Data)
					inline = append(inline, string(b))
				}
			}
			return turnPrompt, turnResume, turnModel, inline, true
		default:
			if len(msg.ID) > 0 && string(msg.ID) != "null" {
				writeOutJSON(map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": map[string]any{}})
			}
		}
	}
	return "", "", "", nil, false
}

func waitEOFOrTimeout(d time.Duration) {
	if sessionProto == protoLegacy {
		return
	}
	select {
	case <-stdinClosed:
	case <-time.After(d):
	}
}

func emitCodexAppServerTokenUsage(count int) {
	ctxTok := contextTokenCount()
	writeOutJSON(map[string]any{
		"jsonrpc": "2.0",
		"method":  "thread/tokenUsage/updated",
		"params": map[string]any{
			"threadId": session,
			"turnId":   codexTurnID,
			"tokenUsage": map[string]any{
				"last": map[string]any{
					"inputTokens":           ctxTok,
					"cachedInputTokens":     ctxTok * 9 / 10,
					"outputTokens":          1,
					"reasoningOutputTokens": 0,
					"totalTokens":           ctxTok + 1,
				},
				"total": map[string]any{
					"inputTokens":           1000 * int64(count),
					"cachedInputTokens":     500 * int64(count),
					"outputTokens":          200 * int64(count),
					"reasoningOutputTokens": 0,
					"totalTokens":           1200 * int64(count),
				},
			},
		},
	})
}

func emitCodexAppServer(v map[string]any) {
	switch v["type"] {
	case "turn.started", "thread.started":
		return
	case "item.started", "item.completed":
		it, _ := v["item"].(map[string]any)
		method := "item/completed"
		if v["type"] == "item.started" {
			method = "item/started"
		}
		typ, _ := it["type"].(string)
		switch typ {
		case "agent_message":
			writeOutJSON(map[string]any{
				"jsonrpc": "2.0",
				"method":  method,
				"params":  map[string]any{"item": map[string]any{"id": it["id"], "type": "agentMessage", "text": it["text"]}},
			})
		case "mcp_tool_call":
			status := "inProgress"
			if v["type"] == "item.completed" {
				status, _ = it["status"].(string)
			}
			itemOut := map[string]any{
				"id":        it["id"],
				"type":      "mcpToolCall",
				"server":    it["server"],
				"tool":      it["tool"],
				"arguments": it["arguments"],
				"status":    status,
			}
			if res, ok := it["result"]; ok {
				itemOut["result"] = res
			}
			writeOutJSON(map[string]any{
				"jsonrpc": "2.0",
				"method":  method,
				"params":  map[string]any{"item": itemOut},
			})
			if v["type"] == "item.completed" {
				emitCodexAppServerTokenUsage(max(1, codexSessionCountPeek()))
			}
		}
	case "turn.completed":
		count := codexSessionCountPeek()
		emitCodexAppServerTokenUsage(max(1, count))
		writeOutJSON(map[string]any{
			"jsonrpc": "2.0",
			"method":  "turn/completed",
			"params": map[string]any{
				"threadId": session,
				"turn":     map[string]any{"id": codexTurnID, "status": "completed"},
			},
		})
	case "turn.failed":
		errObj, _ := v["error"].(map[string]any)
		writeOutJSON(map[string]any{
			"jsonrpc": "2.0",
			"method":  "turn/completed",
			"params": map[string]any{
				"threadId": session,
				"turn":     map[string]any{"id": codexTurnID, "status": "failed", "error": errObj},
			},
		})
	}
}

func codexSessionCountPeek() int {
	counts := map[string]int{}
	raw, _ := os.ReadFile(".lazyagents/fake-codex-usage.json")
	_ = json.Unmarshal(raw, &counts)
	return counts[session]
}

func emitAgyACP(v map[string]any) {
	switch v["type"] {
	case "system":
		// session/new response already announced the session id.
		return
	case "assistant":
		msg, _ := v["message"].(map[string]any)
		blocks, _ := msg["content"].([]any)
		for _, bl := range blocks {
			b, _ := bl.(map[string]any)
			switch b["type"] {
			case "text":
				writeOutJSON(map[string]any{
					"jsonrpc": "2.0",
					"method":  "session/update",
					"params": map[string]any{
						"sessionId": session,
						"update": map[string]any{
							"sessionUpdate": "agent_message_chunk",
							"content":       map[string]any{"type": "text", "text": b["text"]},
						},
					},
				})
			case "tool_use":
				agyStep++
				id, _ := b["id"].(string)
				agyTools[id] = agyStep
				name, _ := b["name"].(string)
				name, params := agyCall(name, b["input"])
				writeOutJSON(map[string]any{
					"jsonrpc": "2.0",
					"method":  "session/update",
					"params": map[string]any{
						"sessionId": session,
						"update": map[string]any{
							"sessionUpdate": "tool_call",
							"toolCallId":    id,
							"name":          name,
							"args":          params,
							"status":        "in_progress",
						},
					},
				})
			}
		}
	case "user":
		msg, _ := v["message"].(map[string]any)
		blocks, _ := msg["content"].([]any)
		for _, bl := range blocks {
			b, _ := bl.(map[string]any)
			id, _ := b["tool_use_id"].(string)
			status := "completed"
			rawOut := map[string]any{"output": b["content"]}
			if isErr, _ := b["is_error"].(bool); isErr {
				status = "failed"
				rawOut = map[string]any{"error": b["content"]}
			}
			writeOutJSON(map[string]any{
				"jsonrpc": "2.0",
				"method":  "session/update",
				"params": map[string]any{
					"sessionId": session,
					"update": map[string]any{
						"sessionUpdate": "tool_call_update",
						"toolCallId":    id,
						"status":        status,
						"rawOutput":     rawOut,
					},
				},
			})
			writeOutJSON(map[string]any{
				"jsonrpc": "2.0",
				"method":  "session/update",
				"params": map[string]any{
					"sessionId": session,
					"update": map[string]any{
						"sessionUpdate": "usage_update",
						"used":          contextTokenCount(),
						"size":          1048576,
					},
				},
			})
		}
	case "result":
		writeOutJSON(map[string]any{
			"jsonrpc": "2.0",
			"method":  "session/update",
			"params": map[string]any{
				"sessionId": session,
				"update": map[string]any{
					"sessionUpdate": "usage_update",
					"used":          contextTokenCount(),
					"size":          1048576,
				},
			},
		})
		if isErr, _ := v["is_error"].(bool); isErr {
			msg, _ := v["result"].(string)
			writeOutJSON(map[string]any{
				"jsonrpc": "2.0",
				"method":  "session/update",
				"params": map[string]any{
					"sessionId": session,
					"update": map[string]any{
						"sessionUpdate": "agent_message_chunk",
						"content":       map[string]any{"type": "text", "text": "\n⚠ agent executor error: " + msg},
					},
				},
			})
		}
		if len(acpPromptID) > 0 {
			writeOutJSON(map[string]any{
				"jsonrpc": "2.0",
				"id":      acpPromptID,
				"result": map[string]any{
					"stopReason": "end_turn",
					"usage": map[string]any{
						"inputTokens":      500,
						"cachedReadTokens": 500,
						"outputTokens":     200,
						"totalTokens":      1200,
					},
				},
			})
		}
	}
}

func emitAgyACPImageStep(dir, name string) {
	agyStep++
	id := fmt.Sprintf("img_%d", agyStep)
	writeOutJSON(map[string]any{
		"jsonrpc": "2.0",
		"method":  "session/update",
		"params": map[string]any{
			"sessionId": session,
			"update": map[string]any{
				"sessionUpdate": "tool_call",
				"toolCallId":    id,
				"name":          "generate_image",
				"args":          map[string]any{"prompt": "x"},
				"status":        "in_progress",
			},
		},
	})
	writeOutJSON(map[string]any{
		"jsonrpc": "2.0",
		"method":  "session/update",
		"params": map[string]any{
			"sessionId": session,
			"update": map[string]any{
				"sessionUpdate": "tool_call_update",
				"toolCallId":    id,
				"name":          "generate_image",
				"status":        "completed",
				"rawOutput":     map[string]any{"output": "Saved " + filepath.Join(dir, name)},
			},
		},
	})
}

func checkSessionPolicy(tool string, input map[string]any) (allow bool, ok bool) {
	id := "policy_1"
	ch := registerPending(id)
	switch sessionProto {
	case protoClaudeSession:
		writeOutJSON(map[string]any{
			"type":       "control_request",
			"request_id": id,
			"request": map[string]any{
				"subtype":     "hook_callback",
				"callback_id": "vesper_policy",
				"input": map[string]any{
					"tool_name":  tool,
					"tool_input": input,
				},
			},
		})
		raw, recv := <-ch
		if !recv {
			return false, false
		}
		var resp struct {
			Response struct {
				Subtype  string `json:"subtype"`
				Response struct {
					HookSpecificOutput struct {
						PermissionDecision string `json:"permissionDecision"`
					} `json:"hookSpecificOutput"`
				} `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal(raw, &resp) != nil || resp.Response.Subtype != "success" {
			return false, false
		}
		return resp.Response.Response.HookSpecificOutput.PermissionDecision == "allow", true

	case protoCodexServer:
		writeOutJSON(map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"method":  "item/commandExecution/requestApproval",
			"params":  input,
		})
		raw, recv := <-ch
		if !recv {
			return false, false
		}
		var resp struct {
			Result struct {
				Decision string `json:"decision"`
			} `json:"result"`
		}
		if json.Unmarshal(raw, &resp) != nil {
			return false, false
		}
		return resp.Result.Decision == "accept", true

	case protoAgyACP:
		writeOutJSON(map[string]any{
			"jsonrpc": "2.0",
			"id":      id,
			"method":  "session/request_permission",
			"params": map[string]any{
				"sessionId": session,
				"toolCall": map[string]any{
					"name": "run_command",
					"args": map[string]any{"CommandLine": input["command"]},
				},
				"options": []map[string]any{
					{"optionId": "allow", "kind": "allow_once", "name": "Allow"},
					{"optionId": "deny", "kind": "reject_once", "name": "Deny"},
				},
			},
		})
		raw, recv := <-ch
		if !recv {
			return false, false
		}
		var resp struct {
			Result struct {
				Outcome struct {
					Outcome  string `json:"outcome"`
					OptionID string `json:"optionId"`
				} `json:"outcome"`
			} `json:"result"`
		}
		if json.Unmarshal(raw, &resp) != nil {
			return false, false
		}
		return resp.Result.Outcome.Outcome == "selected" && resp.Result.Outcome.OptionID == "allow", true
	}
	return false, false
}

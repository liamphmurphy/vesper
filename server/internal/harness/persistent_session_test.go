package harness

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

func TestPersistentSessionsRunMultipleTurns(t *testing.T) {
	t.Run("claude", func(t *testing.T) {
		c2sR, c2sW := io.Pipe()
		s2cR, s2cW := io.Pipe()
		defer c2sR.Close()
		defer s2cW.Close()

		go func() {
			defer s2cW.Close()
			sc := bufio.NewScanner(c2sR)
			enc := json.NewEncoder(s2cW)
			turns := 0
			for sc.Scan() {
				var m map[string]any
				if json.Unmarshal(sc.Bytes(), &m) != nil {
					continue
				}
				switch m["type"] {
				case "control_request":
					_ = enc.Encode(map[string]any{
						"type": "control_response",
						"response": map[string]any{
							"subtype":    "success",
							"request_id": m["request_id"],
						},
					})
				case "user":
					turns++
					reply := "turn one"
					if turns == 2 {
						reply = "turn two"
					}
					_ = enc.Encode(map[string]any{"type": "stream_event", "event": map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": reply}}})
					_ = enc.Encode(map[string]any{"type": "assistant", "session_id": "s-claude", "message": map[string]any{"content": []any{map[string]any{"type": "text", "text": reply}}}})
					_ = enc.Encode(map[string]any{"type": "result", "session_id": "s-claude", "result": reply})
				}
			}
		}()

		h := ClaudeCode{}
		sess, err := h.OpenSession(context.Background(), c2sW, s2cR, Workspace{}, Turn{}, SessionCallbacks{})
		if err != nil {
			t.Fatal(err)
		}
		defer sess.Close()

		var d1, d2 strings.Builder
		r1, err := sess.RunTurn(context.Background(), Turn{Prompt: "first"}, SessionCallbacks{OnTextDelta: func(s string) { d1.WriteString(s) }})
		if err != nil || r1.Final != "turn one" || d1.String() != "turn one" || !sess.Alive() {
			t.Fatalf("turn 1: res=%+v delta=%q alive=%v err=%v", r1, d1.String(), sess.Alive(), err)
		}
		r2, err := sess.RunTurn(context.Background(), Turn{Prompt: "second"}, SessionCallbacks{OnTextDelta: func(s string) { d2.WriteString(s) }})
		if err != nil || r2.Final != "turn two" || d2.String() != "turn two" || !sess.Alive() {
			t.Fatalf("turn 2: res=%+v delta=%q alive=%v err=%v", r2, d2.String(), sess.Alive(), err)
		}
	})

	t.Run("antigravity", func(t *testing.T) {
		c2sR, c2sW := io.Pipe()
		s2cR, s2cW := io.Pipe()
		defer c2sR.Close()
		defer s2cW.Close()

		go func() {
			defer s2cW.Close()
			sc := bufio.NewScanner(c2sR)
			enc := json.NewEncoder(s2cW)
			turns := 0
			for sc.Scan() {
				var req struct {
					ID     int64  `json:"id"`
					Method string `json:"method"`
				}
				if json.Unmarshal(sc.Bytes(), &req) != nil {
					continue
				}
				switch req.Method {
				case "initialize", "session/set_config_option":
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{}})
				case "session/new":
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{"sessionId": "s-agy"}})
				case "session/prompt":
					turns++
					reply := "agy one"
					if turns == 2 {
						reply = "agy two"
					}
					_ = enc.Encode(map[string]any{
						"jsonrpc": "2.0",
						"method":  "session/update",
						"params": map[string]any{
							"update": map[string]any{
								"sessionUpdate": "agent_message_chunk",
								"content":       map[string]any{"type": "text", "text": reply},
							},
						},
					})
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{"stopReason": "end_turn"}})
				}
			}
		}()

		h := Antigravity{}
		spec := agentdef.Resolved{Model: "gemini-4-neon", HarnessOptions: map[string]string{"effort": "low"}}
		sess, err := h.OpenSession(context.Background(), c2sW, s2cR, Workspace{Dir: "/workspace"}, Turn{Spec: spec}, SessionCallbacks{})
		if err != nil {
			t.Fatal(err)
		}
		defer sess.Close()

		r1, err := sess.RunTurn(context.Background(), Turn{Spec: spec, Prompt: "hi"}, SessionCallbacks{})
		if err != nil || r1.Final != "agy one" || !sess.Alive() {
			t.Fatalf("agy turn 1: res=%+v alive=%v err=%v", r1, sess.Alive(), err)
		}
		r2, err := sess.RunTurn(context.Background(), Turn{Spec: spec, Prompt: "again"}, SessionCallbacks{})
		if err != nil || r2.Final != "agy two" || !sess.Alive() {
			t.Fatalf("agy turn 2: res=%+v alive=%v err=%v", r2, sess.Alive(), err)
		}
	})

	t.Run("codex", func(t *testing.T) {
		c2sR, c2sW := io.Pipe()
		s2cR, s2cW := io.Pipe()
		defer c2sR.Close()
		defer s2cW.Close()

		ws := Workspace{Dir: "/workspace", MCPURL: "http://api/mcp"}
		hookEnv, err := codexHookEnv(ws, codexHookRelPath(""), false)
		if err != nil {
			t.Fatal(err)
		}
		expectedCmd := hookEnv["LAZYAGENTS_POLICY_HOOK_COMMAND"]

		go func() {
			defer s2cW.Close()
			sc := bufio.NewScanner(c2sR)
			enc := json.NewEncoder(s2cW)
			turns := 0
			for sc.Scan() {
				var req struct {
					ID     int64  `json:"id"`
					Method string `json:"method"`
				}
				if json.Unmarshal(sc.Bytes(), &req) != nil {
					continue
				}
				switch req.Method {
				case "initialize":
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{}})
				case "hooks/list":
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{
						"data": []any{map[string]any{
							"hooks": []any{map[string]any{
								"enabled":     true,
								"source":      "sessionFlags",
								"handlerType": "command",
								"command":     expectedCmd,
								"eventName":   "preToolUse",
								"matcher":     "*",
								"trustStatus": "trusted",
							}},
						}},
					}})
				case "thread/start":
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{"thread": map[string]any{"id": "t-codex"}}})
				case "turn/start":
					turns++
					reply := "codex one"
					if turns == 2 {
						reply = "codex two"
					}
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "id": req.ID, "result": map[string]any{"turn": map[string]any{"id": "turn-" + reply}}})
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "item/agentMessage/delta", "params": map[string]any{"itemId": "m1", "delta": reply}})
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "item/completed", "params": map[string]any{"item": map[string]any{"id": "m1", "type": "agentMessage", "text": reply}}})
					_ = enc.Encode(map[string]any{"jsonrpc": "2.0", "method": "turn/completed", "params": map[string]any{"turn": map[string]any{"status": "completed"}}})
				}
			}
		}()

		h := Codex{}
		spec := agentdef.Resolved{Model: "gpt-6-codex", HarnessOptions: map[string]string{"effort": "low"}}
		sess, err := h.OpenSession(context.Background(), c2sW, s2cR, ws, Turn{Spec: spec}, SessionCallbacks{})
		if err != nil {
			t.Fatal(err)
		}
		defer sess.Close()

		r1, err := sess.RunTurn(context.Background(), Turn{Spec: spec, Prompt: "hi"}, SessionCallbacks{})
		if err != nil || r1.Final != "codex one" || !sess.Alive() {
			t.Fatalf("codex turn 1: res=%+v alive=%v err=%v", r1, sess.Alive(), err)
		}
		r2, err := sess.RunTurn(context.Background(), Turn{Spec: spec, Prompt: "again"}, SessionCallbacks{})
		if err != nil || r2.Final != "codex two" || !sess.Alive() {
			t.Fatalf("codex turn 2: res=%+v alive=%v err=%v", r2, sess.Alive(), err)
		}
	})
}

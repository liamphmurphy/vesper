package runner_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestWarmChatSessionReusesProcessAcrossTurns(t *testing.T) {
	e := setup(t)
	e.runner.Cfg.WarmSessionTTL = time.Minute
	t.Cleanup(func() { e.runner.CloseWarmSessions() })

	// Minimal multi-turn Claude stream-json stand-in that stays alive across turns
	// and appends one line to countFile each time the process boots.
	tmp := t.TempDir()
	countFile := filepath.Join(tmp, "boots.log")
	scriptPath := filepath.Join(tmp, "warm-claude")
	script := `#!/usr/bin/env python3
import json, os, sys

with open(` + `"` + countFile + `"` + `, "a") as f:
    f.write("boot\n")

turn = 0
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    msg = json.loads(raw)
    t = msg.get("type")
    if t == "control_request":
        print(json.dumps({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": msg.get("request_id", "")},
        }), flush=True)
    elif t == "user":
        turn += 1
        reply = f"Warm reply number {turn}."
        print(json.dumps({
            "type": "stream_event",
            "event": {"type": "content_block_delta", "delta": {"type": "text_delta", "text": reply}},
        }), flush=True)
        print(json.dumps({
            "type": "assistant",
            "session_id": "warm-sess-1",
            "message": {"content": [{"type": "text", "text": reply}]},
        }), flush=True)
        print(json.dumps({
            "type": "result",
            "session_id": "warm-sess-1",
            "result": reply,
        }), flush=True)
`
	if err := os.WriteFile(scriptPath, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	fakeBackend, ok := e.runner.Backend.(*runner.Fake)
	if !ok {
		t.Fatalf("expected Fake backend, got %T", e.runner.Backend)
	}
	fakeBackend.Bins["claude"] = scriptPath

	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{
		Project: "PAY",
		Title:   "Warm voice test",
		Message: &runs.ChatMessageInput{Body: "first spoken question", Voice: true},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.until("first warm turn", func() bool { return e.chat(chat.ID).State == "idle" })

	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{
		Body:  "second spoken question",
		Voice: true,
	}); err != nil {
		t.Fatal(err)
	}
	e.until("second warm turn", func() bool {
		if e.chat(chat.ID).State != "idle" {
			return false
		}
		msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
		if err != nil {
			return false
		}
		var assistants int
		for _, m := range msgs {
			if m.Role == "assistant" {
				assistants++
			}
		}
		return assistants >= 2
	})

	boots, err := os.ReadFile(countFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(boots) != "boot\n" {
		t.Fatalf("expected exactly 1 process boot across 2 warm turns, got %q", string(boots))
	}

	// Verify turn_timing lifecycle events recorded warm_session=false then warm_session=true.
	run := e.chatRun(chat.ID)
	evs, err := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
	if err != nil {
		t.Fatal(err)
	}
	var warmFlags []bool
	for _, ev := range evs {
		if ev.Type != "lifecycle" {
			continue
		}
		var pl struct {
			State       string `json:"state"`
			WarmSession bool   `json:"warm_session"`
		}
		if json.Unmarshal(ev.Payload, &pl) == nil && pl.State == "turn_timing" {
			warmFlags = append(warmFlags, pl.WarmSession)
		}
	}
	if len(warmFlags) != 2 || warmFlags[0] || !warmFlags[1] {
		t.Fatalf("turn_timing warm_session flags = %v, want [false true]", warmFlags)
	}
}

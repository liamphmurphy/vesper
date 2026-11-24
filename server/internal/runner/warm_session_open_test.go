package runner_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// warmClaude installs a Python stand-in for Claude Code's stream-json mode
// whose behaviour before it answers `initialize` is beforeInit (Python, may be
// empty). Afterwards it answers every turn with "Warm reply.".
func warmClaude(t *testing.T, e env, beforeInit string) {
	t.Helper()
	e.runner.Cfg.WarmSessionTTL = time.Minute
	t.Cleanup(func() { e.runner.CloseWarmSessions() })
	script := `#!/usr/bin/env python3
import json, sys, time

for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    msg = json.loads(raw)
    t = msg.get("type")
    if t == "control_request":
` + indent(beforeInit, "        ") + `
        print(json.dumps({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": msg.get("request_id", "")},
        }), flush=True)
    elif t == "user":
        print(json.dumps({"type": "assistant", "session_id": "warm-1",
            "message": {"content": [{"type": "text", "text": "Warm reply."}]}}), flush=True)
        print(json.dumps({"type": "result", "session_id": "warm-1", "result": "Warm reply."}), flush=True)
`
	path := filepath.Join(t.TempDir(), "warm-claude")
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	fake, ok := e.runner.Backend.(*runner.Fake)
	if !ok {
		t.Fatalf("expected Fake backend, got %T", e.runner.Backend)
	}
	fake.Bins["claude"] = path
}

func indent(code, prefix string) string {
	if strings.TrimSpace(code) == "" {
		return prefix + "pass"
	}
	lines := strings.Split(strings.TrimSpace(code), "\n")
	for i, l := range lines {
		lines[i] = prefix + l
	}
	return strings.Join(lines, "\n")
}

// untilNoWait is e.until without Runner.Wait, for a turn that may hang: it
// fails after d instead of blocking the test on the stuck turn.
func untilNoWait(e env, what string, d time.Duration, cond func() bool) {
	e.t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		e.runner.Tick(e.ctx)
		if cond() {
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	e.t.Fatalf("timed out after %s waiting for %s", d, what)
}

func lastSystemMessage(e env, chatID uuid.UUID) string {
	e.t.Helper()
	msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chatID, Limit: 20})
	if err != nil {
		e.t.Fatal(err)
	}
	var body string
	for _, m := range msgs {
		if m.Role == "system" {
			body = m.BodyMd
		}
	}
	return body
}

// A harness that writes to stderr before answering `initialize` must not
// deadlock the turn: nothing read stderr until the session was open, so the
// harness blocked writing it and never sent the answer the runner waited on.
// 1 MiB is past any OS pipe buffer; in a microVM a single byte was enough.
func TestWarmSessionOpenDrainsStderr(t *testing.T) {
	e := setup(t)
	warmClaude(t, e, `
sys.stderr.write("warning: noisy startup\n" * 50000)
sys.stderr.flush()`)

	chat := e.startChat("hello")
	untilNoWait(e, "the warm turn to reply", 20*time.Second, func() bool { return e.chat(chat.ID).State == "idle" })
	e.runner.Wait()
	msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
	if err != nil {
		t.Fatal(err)
	}
	var replied bool
	for _, m := range msgs {
		replied = replied || (m.Role == "assistant" && strings.Contains(m.BodyMd, "Warm reply."))
	}
	if !replied {
		t.Fatalf("no assistant reply; messages: %+v", msgs)
	}
}

// Stopping a chat whose harness never finishes starting must stop it, not
// wait out the turn's whole runtime budget.
func TestWarmSessionOpenStopsOnCancel(t *testing.T) {
	e := setup(t)
	warmClaude(t, e, `time.sleep(3600)`)

	chat := e.startChat("hello")
	untilNoWait(e, "the turn to start", 15*time.Second, func() bool {
		run := e.chatRun(chat.ID)
		turns, err := e.q.ListTurns(e.ctx, run.ID)
		return err == nil && len(turns) > 0 && turns[0].ProcessStartedAt != nil
	})
	if _, err := e.runs.CancelChat(e.ctx, e.ws, e.me.ID, chat.ID); err != nil {
		t.Fatal(err)
	}
	untilNoWait(e, "the stopped chat to be idle", 10*time.Second, func() bool { return e.chat(chat.ID).State == "idle" })
	done := make(chan struct{})
	go func() { e.runner.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		t.Fatal("the stopped turn is still running")
	}
}

// A harness that exits before answering `initialize` fails the turn with what
// it printed, rather than a bare exit code.
func TestWarmSessionOpenFailureReportsStderr(t *testing.T) {
	e := setup(t)
	warmClaude(t, e, `
sys.stderr.write("Error: unable to get local issuer certificate\n")
sys.stderr.flush()
sys.exit(1)`)

	chat := e.startChat("hello")
	untilNoWait(e, "the turn to fail", 20*time.Second, func() bool { return e.chat(chat.ID).State == "failed" })
	e.runner.Wait()
	if got := lastSystemMessage(e, chat.ID); !strings.Contains(got, "unable to get local issuer certificate") {
		t.Fatalf("failure message = %q, want the harness's stderr", got)
	}
}

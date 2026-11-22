package runner_test

import (
	"context"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/runs"
)

func TestRunnerWakesOnNotify(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	e.runner.Cfg.Poll = 10 * time.Second

	runCtx, stopRunner := context.WithCancel(e.ctx)
	done := make(chan error, 1)
	go func() {
		done <- e.runner.Run(runCtx)
	}()
	t.Cleanup(func() {
		stopRunner()
		<-done
	})

	// Give LISTEN a moment to attach before queueing a turn.
	time.Sleep(150 * time.Millisecond)

	start := time.Now()
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{
		Project: "PAY",
		Title:   "Voice wake test",
		Message: &runs.ChatMessageInput{Body: "quick ping", Voice: true},
	})
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(4 * time.Second)
	for time.Now().Before(deadline) {
		if e.chat(chat.ID).State == "idle" {
			if elapsed := time.Since(start); elapsed >= 4*time.Second {
				t.Fatalf("runner took %v (expected wake well before 10s poll)", elapsed)
			}
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("chat turn did not finish within 4s (Poll=%v, state=%s)", e.runner.Cfg.Poll, e.chat(chat.ID).State)
}

package runner_test

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// holdChat starts a chat whose reply works until the returned release is
// called, and waits until it has started.
func (e env) holdChat() (store.ChatSession, func()) {
	e.t.Helper()
	hold := filepath.Join(e.t.TempDir(), "release")
	e.t.Setenv("FAKE_HARNESS_MODE", "chat")
	e.t.Setenv("FAKE_HARNESS_HOLD", hold)
	chat := e.startChat("held")
	e.tickUntil("the held reply to start", func() bool { _, err := os.Stat(hold + ".started"); return err == nil })
	var once sync.Once
	release := func() {
		once.Do(func() {
			if err := os.WriteFile(hold, nil, 0o644); err != nil {
				e.t.Error(err)
			}
		})
	}
	// Released before setup's cleanup waits for the runner, so a test that
	// ends mid-reply doesn't leave the reply holding forever.
	e.t.Cleanup(release)
	return chat, release
}

func (e env) messages(chatID uuid.UUID) []store.ChatMessage {
	e.t.Helper()
	msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chatID, Limit: 50})
	if err != nil {
		e.t.Fatal(err)
	}
	return msgs
}

func roles(msgs []store.ChatMessage) string {
	out := make([]string, len(msgs))
	for i, m := range msgs {
		out[i] = m.Role
	}
	return strings.Join(out, ",")
}

// Follow-ups queued while a reply runs don't interrupt it; once it has
// replied, each goes out in turn, in the order queued.
func TestChatFollowupsSendAfterReply(t *testing.T) {
	e := setup(t)
	chat, release := e.holdChat()
	for _, body := range []string{"first follow-up", "second follow-up"} {
		if _, err := e.runs.QueueChatFollowup(e.ctx, e.ws, e.me.ID, chat.ID, body); err != nil {
			t.Fatal(err)
		}
	}
	if c := e.chat(chat.ID); c.State != "running" || c.InterruptMessageID != nil {
		t.Fatalf("queueing interrupted the reply: %+v", c)
	}
	release()
	e.until("both follow-ups answered", func() bool {
		left, _ := e.q.ListChatFollowups(e.ctx, chat.ID)
		return e.chat(chat.ID).State == "idle" && len(left) == 0 && len(e.messages(chat.ID)) >= 6
	})
	msgs := e.messages(chat.ID)
	if got := roles(msgs); got != "user,assistant,user,assistant,user,assistant" {
		t.Fatalf("history %s", got)
	}
	if msgs[2].BodyMd != "first follow-up" || msgs[4].BodyMd != "second follow-up" {
		t.Fatalf("follow-ups sent as %q, %q", msgs[2].BodyMd, msgs[4].BodyMd)
	}
	if !strings.Contains(msgs[1].BodyMd, "held") || !strings.Contains(msgs[3].BodyMd, "first follow-up") || !strings.Contains(msgs[5].BodyMd, "second follow-up") {
		t.Fatalf("replies out of order:\n%s\n%s\n%s", msgs[1].BodyMd, msgs[3].BodyMd, msgs[5].BodyMd)
	}
}

// Stopping the reply holds the queue: nothing is sent until the person says so.
func TestChatStopHoldsFollowups(t *testing.T) {
	e := setup(t)
	chat, release := e.holdChat()
	defer release()
	if _, err := e.runs.QueueChatFollowup(e.ctx, e.ws, e.me.ID, chat.ID, "after that"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.CancelChat(e.ctx, e.ws, e.me.ID, chat.ID); err != nil {
		t.Fatal(err)
	}
	e.until("the stop", func() bool { return e.chat(chat.ID).State == "idle" })
	if got := roles(e.messages(chat.ID)); got != "user" {
		t.Fatalf("history after stop %s", got)
	}
	if left, _ := e.q.ListChatFollowups(e.ctx, chat.ID); len(left) != 1 {
		t.Fatalf("queue after stop %+v", left)
	}
}

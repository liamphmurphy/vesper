package runner_test

import (
	"context"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// An aside is answered while the reply it asks about keeps running, from a
// session that saw what the reply had written; it then ends its segment.
func TestChatAsideAnswersDuringReply(t *testing.T) {
	e := setup(t)
	chat, release := e.holdChat()
	defer release()
	e.tickUntil("the reply's opening text", func() bool {
		var n int
		_ = e.pool.QueryRow(e.ctx, `SELECT count(*) FROM run_events WHERE run_id=$1 AND type='message'`, e.chatRun(chat.ID).ID).Scan(&n)
		return n > 0
	})
	aside, err := e.runs.StartChatAside(e.ctx, e.ws, e.me.ID, chat.ID, "how far along are you?", nil)
	if err != nil {
		t.Fatal(err)
	}
	e.tickUntil("the aside's answer", func() bool { return e.chat(aside.ID).State == "idle" })
	msgs := e.messages(aside.ID)
	if got := roles(msgs); got != "user,assistant" {
		t.Fatalf("aside history %s", got)
	}
	for _, want := range []string{"this is an aside", "Working on it.", "how far along are you?"} {
		if !strings.Contains(msgs[1].BodyMd, want) {
			t.Fatalf("aside turn didn't see %q:\n%s", want, msgs[1].BodyMd)
		}
	}
	if run, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: *msgs[1].RunID, WorkspaceID: e.ws}); err != nil || run.State != "completed" {
		t.Fatalf("aside run %s, %v", run.State, err)
	}
	if c := e.chat(chat.ID); c.State != "running" {
		t.Fatalf("the aside stopped the reply: %s", c.State)
	}
	if got := roles(e.messages(chat.ID)); got != "user" {
		t.Fatalf("the aside reached the conversation: %s", got)
	}
}

// A thread on a finished message answers while nothing runs, waits for the
// person's next reply instead of ending, and answers that too.
func TestChatThreadKeepsAnswering(t *testing.T) {
	e := setup(t)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Message: &runs.ChatMessageInput{Body: "compare kokoro and piper"}})
	if err != nil {
		t.Fatal(err)
	}
	e.tickUntil("the chat's reply", func() bool { return e.chat(chat.ID).State == "idle" })
	reply := e.messages(chat.ID)[1]

	thread, err := e.runs.StartChatAside(e.ctx, e.ws, e.me.ID, chat.ID, "why these two?", &reply.ID)
	if err != nil {
		t.Fatal(err)
	}
	e.tickUntil("the thread's answer", func() bool { return e.chat(thread.ID).State == "idle" })
	if run, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: *e.chat(thread.ID).CurrentRunID, WorkspaceID: e.ws}); err != nil || run.State == "completed" {
		t.Fatalf("thread run %s, %v: it should wait for the next reply", run.State, err)
	}
	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, thread.ID, runs.ChatMessageInput{Body: "and for long texts?"}); err != nil {
		t.Fatal(err)
	}
	e.tickUntil("the thread's second answer", func() bool {
		return strings.HasPrefix(roles(e.messages(thread.ID)), "user,assistant,user,assistant") && e.chat(thread.ID).State == "idle"
	})
	if got := roles(e.messages(chat.ID)); got != "user,assistant" {
		t.Fatalf("the thread reached the conversation: %s", got)
	}
}

// A cross-harness second opinion runs on the second harness/model without
// ending or switching the parent chat's active session, and stays waiting so
// follow-up questions keep the second harness warm too.
func TestRunnerSecondOpinionKeepsParentSessionUntouched(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	e.runs.ModelDiscovery = func(_ context.Context, h, _ string) ([]chatmodels.Model, error) {
		switch h {
		case agentdef.HarnessClaudeCode:
			return []chatmodels.Model{{ID: "claude-sonnet-4-6", Label: "Sonnet 4.6", Default: true}}, nil
		case agentdef.HarnessCodex:
			return []chatmodels.Model{{ID: "gpt-5.4", Label: "GPT-5.4", Default: true}}, nil
		default:
			return []chatmodels.Model{{ID: "default", Label: "Default", Default: true}}, nil
		}
	}

	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{
		Message: &runs.ChatMessageInput{Body: "review the lock acquisition order"},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.tickUntil("the parent chat's reply", func() bool { return e.chat(chat.ID).State == "idle" })
	parentBefore := e.chat(chat.ID)
	if parentBefore.CurrentRunID == nil {
		t.Fatal("parent chat missing current run")
	}

	aside, err := e.runs.StartChatAsideWith(e.ctx, e.ws, e.me.ID, chat.ID, runs.AsideInput{
		SecondOpinion: true,
		Harness:       agentdef.HarnessCodex,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !aside.SecondOpinion || aside.Harness != agentdef.HarnessCodex || aside.Model != "gpt-5.4" {
		t.Fatalf("unexpected second opinion chat: %+v", aside)
	}
	e.tickUntil("the second opinion's answer", func() bool { return e.chat(aside.ID).State == "idle" })
	msgs := e.messages(aside.ID)
	if got := roles(msgs); got != "user,assistant" {
		t.Fatalf("second opinion history %s", got)
	}
	if !strings.Contains(msgs[1].BodyMd, "second-opinion aside") || !strings.Contains(msgs[1].BodyMd, "model=gpt-5.4") {
		t.Fatalf("second opinion turn lacked context/model:\n%s", msgs[1].BodyMd)
	}

	// Follow-up in the second opinion card keeps using the second harness.
	asideRun, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: *e.chat(aside.ID).CurrentRunID, WorkspaceID: e.ws})
	if err != nil || asideRun.State != "waiting" {
		t.Fatalf("second opinion run = %s, %v; want waiting for follow-up", asideRun.State, err)
	}
	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, aside.ID, runs.ChatMessageInput{Body: "any deadlock path?"}); err != nil {
		t.Fatal(err)
	}
	e.tickUntil("the second opinion's follow-up", func() bool {
		return strings.HasPrefix(roles(e.messages(aside.ID)), "user,assistant,user,assistant") && e.chat(aside.ID).State == "idle"
	})
	followMsgs := e.messages(aside.ID)
	if !strings.Contains(followMsgs[3].BodyMd, "resumed=true") {
		t.Fatalf("second opinion follow-up did not resume warm harness session:\n%s", followMsgs[3].BodyMd)
	}

	// Parent chat harness, model, and waiting run stayed completely untouched.
	parentAfter := e.chat(chat.ID)
	if parentAfter.Harness != parentBefore.Harness || parentAfter.Model != parentBefore.Model ||
		parentAfter.CurrentRunID == nil || *parentAfter.CurrentRunID != *parentBefore.CurrentRunID {
		t.Fatalf("parent chat changed: before=%+v after=%+v", parentBefore, parentAfter)
	}
	parentRun, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: *parentBefore.CurrentRunID, WorkspaceID: e.ws})
	if err != nil || parentRun.State != "waiting" {
		t.Fatalf("parent run disturbed: %s, %v", parentRun.State, err)
	}
}

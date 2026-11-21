package runner_test

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func requireToolApprovalOnRun(t *testing.T, e env, runID uuid.UUID) {
	t.Helper()
	run, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: runID, WorkspaceID: e.ws})
	if err != nil {
		t.Fatal(err)
	}
	spec, err := runs.Spec(run)
	if err != nil {
		t.Fatal(err)
	}
	delete(spec.HarnessOptions, agentdef.OptionNoTools)
	delete(spec.HarnessOptions, "readonly")
	kept := spec.Scopes[:0]
	for _, sc := range spec.Scopes {
		if _, covers := agentdef.ModeFor(map[string]agentdef.Mode{sc.Scope: agentdef.Denied}, "tests:run"); !covers {
			kept = append(kept, sc)
		}
	}
	spec.Scopes = append(kept, agentdef.ResolvedScope{Scope: "tests:run", Mode: agentdef.RequiresApproval})
	raw, _ := json.Marshal(spec)
	if _, err := e.pool.Exec(e.ctx, `UPDATE runs SET resolved_spec=$2 WHERE id=$1`, runID, raw); err != nil {
		t.Fatal(err)
	}
}

func TestLiveToolApprovalInTurn(t *testing.T) {
	runChatCase := func(t *testing.T, approve bool, wantReply string) {
		t.Helper()
		t.Setenv("FAKE_HARNESS_MODE", "tool-approval-live")
		e := setup(t)
		e.runner.Cfg.ToolApprovalWait = 5 * time.Second
		e.runner.Cfg.ToolApprovalPoll = 20 * time.Millisecond

		chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "run command"}); err != nil {
			t.Fatal(err)
		}
		run := e.chatRun(chat.ID)
		requireToolApprovalOnRun(t, e, run.ID)

		var ap store.ApprovalRequest
		e.tickUntil("pending chat tool approval", func() bool {
			aps, err := e.q.ListPendingApprovalsForChat(e.ctx, chat.ID)
			if err != nil {
				t.Fatal(err)
			}
			if len(aps) == 0 {
				return false
			}
			ap = aps[0]
			return true
		})
		if ap.TicketID != nil || ap.ChatID == nil || *ap.ChatID != chat.ID {
			t.Fatalf("unexpected chat approval scope: %+v", ap)
		}
		note := ""
		if !approve {
			note = "not now"
		}
		if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, ap.ID, approve, note); err != nil {
			t.Fatal(err)
		}

		e.tickUntil("chat turn to finish after decision", func() bool {
			return e.chat(chat.ID).State == "idle"
		})
		msgs := e.messages(chat.ID)
		if len(msgs) != 2 || !strings.Contains(msgs[1].BodyMd, wantReply) {
			t.Fatalf("chat messages after live approval: %+v", msgs)
		}
		turns, err := e.q.ListTurns(e.ctx, run.ID)
		if err != nil || len(turns) != 1 {
			t.Fatalf("expected single live turn without pause/resume, turns=%d err=%v", len(turns), err)
		}
	}

	t.Run("chat_approve", func(t *testing.T) {
		runChatCase(t, true, "tool_allowed")
	})

	t.Run("chat_deny", func(t *testing.T) {
		runChatCase(t, false, "tool_denied")
	})

	t.Run("ticket_approve", func(t *testing.T) {
		t.Setenv("FAKE_HARNESS_MODE", "tool-approval-live")
		e := setup(t)
		e.runner.Cfg.ToolApprovalWait = 5 * time.Second
		e.runner.Cfg.ToolApprovalPoll = 20 * time.Millisecond

		e.dispatch("PAY-214")
		run := e.run("PAY-214")
		requireToolApprovalOnRun(t, e, run.ID)

		var ap store.ApprovalRequest
		e.tickUntil("pending live ticket approval", func() bool {
			aps, err := e.q.ListApprovalsForRun(e.ctx, run.ID)
			if err != nil {
				t.Fatal(err)
			}
			for _, a := range aps {
				if a.State == "pending" {
					ap = a
					return true
				}
			}
			return false
		})
		if cur := e.run("PAY-214"); cur.State != "running" {
			t.Fatalf("expected ticket run to still be running while waiting live, got %s", cur.State)
		}
		if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, ap.ID, true, ""); err != nil {
			t.Fatal(err)
		}
		e.tickUntil("ticket run completion after live approval", func() bool {
			return e.run("PAY-214").State == "completed"
		})
		turns, err := e.q.ListTurns(e.ctx, run.ID)
		if err != nil || len(turns) != 1 {
			t.Fatalf("expected single live turn on ticket, turns=%d err=%v", len(turns), err)
		}
	})
}

func TestLiveChatSteering(t *testing.T) {
	waitForOpeningText := func(t *testing.T, e env, runID uuid.UUID) {
		t.Helper()
		e.tickUntil("live turn opening text", func() bool {
			var n int
			_ = e.pool.QueryRow(e.ctx, `SELECT count(*) FROM run_events WHERE run_id=$1 AND type IN ('message','activity')`, runID).Scan(&n)
			return n > 0
		})
	}

	t.Run("claude_live", func(t *testing.T) {
		t.Setenv("FAKE_HARNESS_MODE", "steer-live")
		e := setup(t)
		chat := e.startChat("start live")
		runID := e.chatRun(chat.ID).ID
		waitForOpeningText(t, e, runID)

		steer, msg, err := e.runs.SteerChat(e.ctx, e.ws, e.me.ID, chat.ID, "switch to sqlite tests")
		if err != nil {
			t.Fatal(err)
		}
		if steer.State != "pending" || msg.Role != "user" {
			t.Fatalf("unexpected steer/msg: steer=%+v msg=%+v", steer, msg)
		}

		e.tickUntil("claude chat idle after live steer", func() bool {
			return e.chat(chat.ID).State == "idle"
		})
		msgs := e.messages(chat.ID)
		if got := roles(msgs); got != "user,user,assistant" {
			t.Fatalf("roles = %s, want user,user,assistant (%+v)", got, msgs)
		}
		if !strings.Contains(msgs[2].BodyMd, "steered:switch to sqlite tests") {
			t.Fatalf("unexpected steered reply: %q", msgs[2].BodyMd)
		}
		turns, _ := e.q.ListTurns(e.ctx, runID)
		if len(turns) != 1 {
			t.Fatalf("expected live steer in single turn, got %d turns", len(turns))
		}
	})

	t.Run("codex_live", func(t *testing.T) {
		t.Setenv("FAKE_HARNESS_MODE", "steer-live")
		e := setup(t)
		chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY"})
		if err != nil {
			t.Fatal(err)
		}
		e.selectChat(chat.ID, agentdef.HarnessCodex, "gpt-5.5")
		if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "codex turn"}); err != nil {
			t.Fatal(err)
		}
		runID := e.chatRun(chat.ID).ID
		waitForOpeningText(t, e, runID)

		if _, _, err := e.runs.SteerChat(e.ctx, e.ws, e.me.ID, chat.ID, "check codex rpc"); err != nil {
			t.Fatal(err)
		}
		e.tickUntil("codex chat idle after live steer", func() bool {
			return e.chat(chat.ID).State == "idle"
		})
		msgs := e.messages(chat.ID)
		last := msgs[len(msgs)-1]
		if !strings.Contains(last.BodyMd, "steered:check codex rpc") {
			t.Fatalf("unexpected codex steered reply: %q", last.BodyMd)
		}
	})

	t.Run("codex_unsupported_fallback", func(t *testing.T) {
		t.Setenv("FAKE_HARNESS_MODE", "steer-live")
		t.Setenv("FAKE_HARNESS_REJECT_STEER", "1")
		t.Setenv("FAKE_HARNESS_STEER_ON_RESUME", "1")
		e := setup(t)
		chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY"})
		if err != nil {
			t.Fatal(err)
		}
		e.selectChat(chat.ID, agentdef.HarnessCodex, "gpt-5.5")
		if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "codex fallback"}); err != nil {
			t.Fatal(err)
		}
		runID := e.chatRun(chat.ID).ID
		waitForOpeningText(t, e, runID)

		// Disable steer-on-resume before the resumed fallback turn starts so it answers right away.
		t.Setenv("FAKE_HARNESS_STEER_ON_RESUME", "")
		if _, _, err := e.runs.SteerChat(e.ctx, e.ws, e.me.ID, chat.ID, "fallback instruction"); err != nil {
			t.Fatal(err)
		}
		e.tickUntil("codex fallback completion", func() bool {
			return e.chat(chat.ID).State == "idle" && len(e.messages(chat.ID)) >= 3
		})
		msgs := e.messages(chat.ID)
		userCount := 0
		for _, m := range msgs {
			if m.Role == "user" && m.BodyMd == "fallback instruction" {
				userCount++
			}
		}
		if userCount != 1 {
			t.Fatalf("expected exactly 1 steer user message, got %d in %+v", userCount, msgs)
		}
		last := msgs[len(msgs)-1]
		if !strings.Contains(last.BodyMd, "fallback instruction") {
			t.Fatalf("resumed reply missing steer prompt: %q", last.BodyMd)
		}
	})

	t.Run("antigravity_fallback", func(t *testing.T) {
		t.Setenv("FAKE_HARNESS_MODE", "steer-live")
		e := setup(t)
		chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY"})
		if err != nil {
			t.Fatal(err)
		}
		e.selectChat(chat.ID, agentdef.HarnessAntigravity, "gemini-3.8-flash")
		if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "agy turn"}); err != nil {
			t.Fatal(err)
		}
		e.tickUntil("antigravity session ready", func() bool {
			r := e.chatRun(chat.ID)
			return r.HarnessSessionID != nil && *r.HarnessSessionID != ""
		})

		if _, _, err := e.runs.SteerChat(e.ctx, e.ws, e.me.ID, chat.ID, "agy fallback steer"); err != nil {
			t.Fatal(err)
		}
		e.tickUntil("antigravity fallback completion", func() bool {
			return e.chat(chat.ID).State == "idle" && len(e.messages(chat.ID)) >= 3
		})
		msgs := e.messages(chat.ID)
		userCount := 0
		for _, m := range msgs {
			if m.Role == "user" && m.BodyMd == "agy fallback steer" {
				userCount++
			}
		}
		if userCount != 1 {
			t.Fatalf("expected single steer user message on agy fallback, got %d in %+v", userCount, msgs)
		}
		last := msgs[len(msgs)-1]
		if !strings.Contains(last.BodyMd, "agy fallback steer") {
			t.Fatalf("resumed agy reply missing steer prompt: %q", last.BodyMd)
		}
	})
}

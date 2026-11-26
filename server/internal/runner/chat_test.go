package runner_test

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (e env) chat(id uuid.UUID) store.ChatSession {
	e.t.Helper()
	chat, err := e.q.GetChatSession(e.ctx, store.GetChatSessionParams{ID: id, WorkspaceID: e.ws})
	if err != nil {
		e.t.Fatal(err)
	}
	return chat
}
func (e env) chatRun(id uuid.UUID) store.Run {
	e.t.Helper()
	chat := e.chat(id)
	if chat.CurrentRunID == nil {
		e.t.Fatal("chat has no run")
	}
	run, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: *chat.CurrentRunID, WorkspaceID: e.ws})
	if err != nil {
		e.t.Fatal(err)
	}
	return run
}
func (e env) startChat(body string) store.ChatSession {
	e.t.Helper()
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Title: "Test chat", Message: &runs.ChatMessageInput{Body: body}})
	if err != nil {
		e.t.Fatal(err)
	}
	return chat
}
func requireConflict(t *testing.T, err error) {
	t.Helper()
	var conflict *apperr.ConflictError
	if !errors.As(err, &conflict) {
		t.Fatalf("want HTTP-409-compatible conflict, got %v", err)
	}
}

func TestChatTurnsResumeWithoutTools(t *testing.T) {
	for _, name := range []string{agentdef.HarnessClaudeCode, agentdef.HarnessCodex} {
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			reader := e.persona("Read only", false, false)
			t.Setenv("FAKE_HARNESS_MODE", "chat")
			if err := (&agents.Service{Pool: e.pool}).SetOverride(e.ctx, e.ws, e.me.ID, e.assistant().Handle, "PAY", agentdef.Override{Harness: name, Setup: []string{"exit 79"}, Budget: agentdef.Budget{MaxTurns: 1, MaxRuntime: "3s"}}); err != nil {
				t.Fatal(err)
			}
			if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url='https://invalid.example/must-not-clone.git' WHERE key='PAY'"); err != nil {
				t.Fatal(err)
			}
			chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Title: "Test chat", PersonaID: &reader.ID, Message: &runs.ChatMessageInput{Body: "First question"}})
			if err != nil {
				t.Fatal(err)
			}
			e.until("first chat reply", func() bool { return e.chat(chat.ID).State == "idle" })
			first := e.chatRun(chat.ID)
			if first.State != "waiting" || deref(first.WaitReason) != "human_reply" || first.HarnessSessionID == nil || first.Purpose != "chat" || first.TicketID != nil {
				t.Fatalf("first run %+v", first)
			}
			spec, err := runs.Spec(first)
			if err != nil {
				t.Fatal(err)
			}
			if len(spec.Setup)+len(spec.MCPServers)+len(spec.Fallbacks) != 0 || spec.HarnessOptions["readonly"] != "true" {
				t.Fatalf("unsafe frozen spec %+v", spec)
			}
			root := e.runner.Backend.WorkspaceDir(first.ID.String())
			if _, err := os.Stat(filepath.Join(root, ".git")); !os.IsNotExist(err) {
				t.Fatal("chat scratch workspace contains git repository")
			}
			md, err := os.ReadFile(filepath.Join(root, "AGENTS.md"))
			if err != nil || !strings.Contains(string(md), "# Vesper chat\n") || strings.Contains(string(md), "claim_ticket") || strings.Contains(string(md), "## Projects") {
				t.Fatalf("chat instructions %s: %v", md, err)
			}
			// Exhaust the cumulative runtime and turn count: a chat still gets a full next turn.
			if _, err := e.pool.Exec(e.ctx, "UPDATE run_turns SET process_started_at=process_started_at-interval '10 seconds' WHERE run_id=$1", first.ID); err != nil {
				t.Fatal(err)
			}
			if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "Second question"}); err != nil {
				t.Fatal(err)
			}
			e.until("second chat reply", func() bool { return e.chat(chat.ID).State == "idle" })
			inputTokens := int64(1000)
			if name == agentdef.HarnessClaudeCode {
				inputTokens = 1500
			}
			second := e.chatRun(chat.ID)
			if second.ID != first.ID || deref(second.HarnessSessionID) != deref(first.HarnessSessionID) || second.State != "waiting" || deref(second.WaitReason) != "human_reply" || second.ToolCalls != 0 || second.InputTokens != 2*inputTokens || second.OutputTokens != 400 {
				t.Fatalf("second run %+v", second)
			}
			msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
			if err != nil {
				t.Fatal(err)
			}
			if len(msgs) != 4 {
				t.Fatalf("messages %+v", msgs)
			}
			turns, err := e.q.ListTurns(e.ctx, first.ID)
			if err != nil || len(turns) != 2 {
				t.Fatalf("turns=%+v err=%v", turns, err)
			}
			for i, idx := range []int{1, 3} {
				msg := msgs[idx]
				if msg.Role != "assistant" || deref(msg.Harness) != name || deref(msg.Model) != first.Model || msg.RunTurnID == nil || *msg.RunTurnID != turns[i].ID || msg.RunID == nil || *msg.RunID != first.ID || msg.Seq != int64(idx+1) {
					t.Fatalf("message metadata %+v", msg)
				}
				var usage harness.Usage
				if err := json.Unmarshal(msg.Usage, &usage); err != nil || usage.InputTokens != inputTokens || usage.OutputTokens != 200 {
					t.Fatalf("message usage %s: %v", msg.Usage, err)
				}
				if turns[i].Trigger != "comment" || turns[i].Status != "done" {
					t.Fatalf("turn %+v", turns[i])
				}
			}
			if !strings.Contains(msgs[1].BodyMd, "resumed=false") || !strings.Contains(msgs[3].BodyMd, "resumed=true") || !strings.Contains(msgs[3].BodyMd, "Second question") {
				t.Fatalf("resume transcript %+v", msgs)
			}
			if strings.Contains(e.eventTypes(first.ID), "tool_call") {
				t.Fatal("chat should succeed without any tool call")
			}
			if name == agentdef.HarnessClaudeCode && second.CostUsdMicros != 25000 {
				t.Fatalf("cost %d", second.CostUsdMicros)
			}
		})
	}
}

func TestChatConcurrentPostsAndQueuedCancel(t *testing.T) {
	e := setup(t)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY"})
	if err != nil {
		t.Fatal(err)
	}
	const n = 8
	start := make(chan struct{})
	results := make(chan error, n)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			_, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "Concurrent question"})
			results <- err
		}()
	}
	close(start)
	wg.Wait()
	close(results)
	for err := range results {
		if err != nil {
			t.Fatal(err)
		}
	}
	// Posts serialize on the chat: each one before the reply starts replaces
	// the queued turn, carrying its input along, so one turn answers them all.
	run := e.chatRun(chat.ID)
	turns, err := e.q.ListTurns(e.ctx, run.ID)
	if err != nil || len(turns) != n {
		t.Fatalf("turns %+v %v", turns, err)
	}
	for i, turn := range turns {
		if want := map[bool]string{true: "pending", false: "done"}[i == n-1]; turn.Status != want {
			t.Fatalf("turn %d is %s", i, turn.Status)
		}
	}
	if got := strings.Count(turns[n-1].InputMessage, "Concurrent question"); got != n {
		t.Fatalf("last turn carries %d of %d messages:\n%s", got, n, turns[n-1].InputMessage)
	}
	msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
	if err != nil || len(msgs) != n {
		t.Fatalf("messages %+v %v", msgs, err)
	}
	if _, err := e.runs.CancelChat(e.ctx, e.ws, e.me.ID, chat.ID); err != nil {
		t.Fatal(err)
	}
	if e.chat(chat.ID).State != "idle" || e.chatRun(chat.ID).State != "waiting" {
		t.Fatal("queued cancel did not idle chat")
	}
	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "After cancel"}); err != nil {
		t.Fatal(err)
	}
	if e.chatRun(chat.ID).State != "queued" {
		t.Fatal("cancel before setup must requeue workspace creation")
	}
	// A second cancel while scratch setup drains must not reopen posting early.
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET state='starting' WHERE id=$1", run.ID); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		if _, err := e.runs.CancelChat(e.ctx, e.ws, e.me.ID, chat.ID); err != nil {
			t.Fatal(err)
		}
	}
	if e.chat(chat.ID).State != "running" || e.chatRun(chat.ID).State != "paused" {
		t.Fatal("repeated cancel reopened a starting chat")
	}
	if err := e.runner.Recover(e.ctx); err != nil {
		t.Fatal(err)
	}
	if e.chat(chat.ID).State != "idle" {
		t.Fatal("recovery did not finish setup cancellation")
	}
	_, err = e.runs.PostChatMessage(e.ctx, e.ws, uuid.New(), chat.ID, runs.ChatMessageInput{Body: "Wrong user"})
	if !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("owner isolation %v", err)
	}
}

func TestChatCancelRunningAndRepost(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	chat := e.startChat("slow")
	// Tick asynchronously: never block waiting for the intentionally slow process.
	deadline := time.Now().Add(15 * time.Second)
	for e.chatRun(chat.ID).HarnessSessionID == nil {
		if time.Now().After(deadline) {
			t.Fatal("fake harness did not start")
		}
		e.runner.Tick(e.ctx)
		time.Sleep(20 * time.Millisecond)
	}
	first := e.chatRun(chat.ID)
	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, first.ID, "cancel"); err != nil {
		t.Fatal(err)
	}
	e.runner.Wait()
	if e.chat(chat.ID).State != "idle" || e.chatRun(chat.ID).State != "waiting" {
		t.Fatal("cancel did not leave chat usable")
	}
	if _, err := os.Stat(e.runner.Backend.WorkspaceDir(first.ID.String())); err != nil {
		t.Fatal("cancel removed scratch workspace", err)
	}
	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "After cancellation"}); err != nil {
		t.Fatal(err)
	}
	e.until("reply after cancellation", func() bool { return e.chat(chat.ID).State == "idle" })
	last := e.chatRun(chat.ID)
	if last.ID != first.ID || deref(last.HarnessSessionID) != deref(first.HarnessSessionID) {
		t.Fatal("lost chat segment/session")
	}
	msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
	if err != nil || len(msgs) != 3 || msgs[2].Role != "assistant" || !strings.Contains(msgs[2].BodyMd, "After cancellation") {
		t.Fatalf("cancel history %+v %v", msgs, err)
	}
}

func TestChatDoesNotOccupyTicketDispatchSlot(t *testing.T) {
	e := setup(t)
	chat := e.startChat("Question")
	chatRun := e.chatRun(chat.ID)
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET state='running' WHERE id=$1", chatRun.ID); err != nil {
		t.Fatal(err)
	}
	e.dispatch("PAY-214")
	ticket := e.run("PAY-214")
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET resolved_spec=jsonb_set(resolved_spec,'{max_concurrency}','1') WHERE id=$1", ticket.ID); err != nil {
		t.Fatal(err)
	}
	claimed, err := e.q.ClaimQueuedRun(e.ctx, store.ClaimQueuedRunParams{})
	if err != nil || claimed.ID != ticket.ID {
		t.Fatalf("chat blocked ticket dispatch: %+v %v", claimed, err)
	}
	// Conversely, an occupied ticket slot cannot block another chat turn.
	other := e.startChat("Another question")
	claimed, err = e.q.ClaimQueuedRun(e.ctx, store.ClaimQueuedRunParams{})
	if err != nil || claimed.ID != *other.CurrentRunID {
		t.Fatalf("ticket blocked chat dispatch: %+v %v", claimed, err)
	}
}

func TestChatFailureAndRuntimeLeaveChatUsable(t *testing.T) {
	for _, tc := range []struct{ name, body, runtime string }{{"quota", "quota", ""}, {"runtime", "slow", "150ms"}} {
		t.Run(tc.name, func(t *testing.T) {
			e := setup(t)
			t.Setenv("FAKE_HARNESS_MODE", "chat")
			if tc.runtime != "" {
				if err := (&agents.Service{Pool: e.pool}).SetOverride(e.ctx, e.ws, e.me.ID, e.assistant().Handle, "PAY", agentdef.Override{Budget: agentdef.Budget{MaxRuntime: tc.runtime}}); err != nil {
					t.Fatal(err)
				}
			}
			chat := e.startChat(tc.body)
			e.until("chat failure", func() bool { return e.chat(chat.ID).State == "failed" })
			first := e.chatRun(chat.ID)
			if first.State != "waiting" || deref(first.WaitReason) != "human_reply" {
				t.Fatalf("failed turn stranded run: %s %s", first.State, deref(first.WaitReason))
			}
			if strings.Contains(e.eventTypes(first.ID), "harness_fallback") {
				t.Fatal("chat switched harness implicitly")
			}
			if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "Try again"}); err != nil {
				t.Fatal(err)
			}
			e.until("chat retry reply", func() bool { return e.chat(chat.ID).State == "idle" })
			msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
			if err != nil || len(msgs) != 4 || msgs[1].Role != "system" || msgs[3].Role != "assistant" {
				t.Fatalf("retry history %+v: %v", msgs, err)
			}
			last := e.chatRun(chat.ID)
			if last.ID != first.ID || last.Harness != first.Harness || last.Model != first.Model {
				t.Fatal("retry switched segment or selection")
			}
		})
	}
}

func TestChatValidationAndArchivedConflict(t *testing.T) {
	e := setup(t)
	for _, body := range []string{" ", strings.Repeat("é", 100001)} {
		_, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Message: &runs.ChatMessageInput{Body: body}})
		var validation *apperr.ValidationError
		if !errors.As(err, &validation) || validation.Field != "body" {
			t.Fatalf("invalid body error: %v", err)
		}
	}
	p, err := e.q.GetProjectByKey(e.ctx, store.GetProjectByKeyParams{WorkspaceID: e.ws, Key: "PAY"})
	if err != nil {
		t.Fatal(err)
	}
	chats, err := e.q.ListChatSessions(e.ctx, store.ListChatSessionsParams{WorkspaceID: e.ws, ProjectID: &p.ID, CreatedBy: e.me.ID, Limit: 20})
	if err != nil || len(chats) != 0 {
		t.Fatalf("invalid first message left chat records: %+v %v", chats, err)
	}
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.ArchiveChatSession(e.ctx, store.ArchiveChatSessionParams{ID: chat.ID, WorkspaceID: e.ws, Revision: chat.Revision}); err != nil {
		t.Fatal(err)
	}
	_, err = e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "Archived chat"})
	requireConflict(t, err)
}

func TestChatRunnerRecovery(t *testing.T) {
	for _, cancelTurn := range []bool{false, true} {
		name := "interrupted"
		if cancelTurn {
			name = "cancelled"
		}
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			t.Setenv("FAKE_HARNESS_MODE", "chat")
			chat := e.startChat("slow")
			turnCtx, stop := context.WithCancel(e.ctx)
			defer stop()
			deadline := time.Now().Add(15 * time.Second)
			for e.chatRun(chat.ID).HarnessSessionID == nil {
				if time.Now().After(deadline) {
					t.Fatal("fake harness did not start")
				}
				e.runner.Tick(turnCtx)
				time.Sleep(20 * time.Millisecond)
			}
			first := e.chatRun(chat.ID)
			if cancelTurn {
				if _, err := e.runs.CancelChat(e.ctx, e.ws, e.me.ID, chat.ID); err != nil {
					t.Fatal(err)
				}
			}
			stop()
			e.runner.Wait()
			if err := e.runner.Recover(e.ctx); err != nil {
				t.Fatal(err)
			}
			if cancelTurn {
				if e.chat(chat.ID).State != "idle" || e.chatRun(chat.ID).State != "waiting" {
					t.Fatal("cancelled chat stranded after recovery")
				}
				if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "Recovered after cancel"}); err != nil {
					t.Fatal(err)
				}
			}
			e.until("recovered chat reply", func() bool { return e.chat(chat.ID).State == "idle" })
			last := e.chatRun(chat.ID)
			if last.ID != first.ID || deref(last.HarnessSessionID) != deref(first.HarnessSessionID) || last.State != "waiting" {
				t.Fatal("recovery lost segment/session")
			}
			msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
			if err != nil {
				t.Fatal(err)
			}
			want := 2
			if cancelTurn {
				want = 3
			}
			if len(msgs) != want || msgs[len(msgs)-1].Role != "assistant" || !strings.Contains(msgs[len(msgs)-1].BodyMd, "resumed=true") {
				t.Fatalf("recovery history %+v", msgs)
			}
			if last.InputTokens != 1500 {
				t.Fatalf("interrupted turn usage counted twice: %d", last.InputTokens)
			}
		})
	}
}

// A turn's citations are what that turn read; a turn without reads cites nothing.
func TestChatTurnCitations(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat-read")
	var art uuid.UUID
	var anchor, label string
	err := e.pool.QueryRow(e.ctx, `SELECT a.id, s.anchor, v.label FROM artifacts a JOIN artifact_versions v ON v.id = a.current_version_id
		JOIN artifact_sections s ON s.version_id = v.id
		WHERE a.type = 'prd' AND a.project_id = (SELECT id FROM projects WHERE key = 'PAY') ORDER BY a.id, s.position LIMIT 1`).Scan(&art, &anchor, &label)
	if err != nil {
		t.Fatal(err)
	}
	// A read from before the turn (e.g. an earlier segment) must not be cited.
	if _, err := e.pool.Exec(e.ctx, `INSERT INTO artifact_reads (version_id, agent_id, run_id, read_at)
		SELECT current_version_id, $2, NULL, now() - interval '1 hour' FROM artifacts WHERE id = $1`, art, e.atlas.ID); err != nil {
		t.Fatal(err)
	}
	chat := e.startChat("read " + art.String() + " " + anchor)
	e.until("first reply", func() bool { return e.chat(chat.ID).State == "idle" })
	// Same artifact twice in one turn is cited once; the next turn reads nothing.
	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "no reads here"}); err != nil {
		t.Fatal(err)
	}
	e.until("second reply", func() bool {
		m, _ := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
		return len(m) == 4 && e.chat(chat.ID).State == "idle"
	})
	msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
	if err != nil || len(msgs) != 4 {
		t.Fatalf("messages %+v %v", msgs, err)
	}
	var cites []struct {
		Target     struct{ Kind, Anchor, Title string }
		ArtifactID uuid.UUID `json:"artifact_id"`
		VersionID  uuid.UUID `json:"version_id"`
		Version    string
		Section    *string
	}
	if err := json.Unmarshal(msgs[1].Citations, &cites); err != nil || len(cites) != 1 {
		t.Fatalf("first turn citations %s: %v", msgs[1].Citations, err)
	}
	c := cites[0]
	if c.ArtifactID != art || c.Version != label || c.VersionID == uuid.Nil || c.Section == nil || *c.Section != anchor || c.Target.Kind != "section" || c.Target.Anchor != anchor {
		t.Fatalf("citation %s", msgs[1].Citations)
	}
	if string(msgs[3].Citations) != "[]" || string(msgs[0].Citations) != "[]" {
		t.Fatalf("citations bled: user=%s second=%s", msgs[0].Citations, msgs[3].Citations)
	}
}

// assistant is the Personal Assistant every chat runs as, created on demand so
// a test can set its project override before the first chat.
func (e *env) assistant() store.Agent {
	e.t.Helper()
	a, err := agents.EnsureAssistant(e.ctx, e.q, e.ws)
	if err != nil {
		e.t.Fatal(err)
	}
	return a
}

// A turn's opening line (text before its first tool call) is kept as its own
// reply ahead of the answer; the answer keeps the turn's citations.
func TestChatOpeningLinePersists(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat-read")
	t.Setenv("FAKE_HARNESS_OPENING", "Let me read that for you.")
	var art uuid.UUID
	if err := e.pool.QueryRow(e.ctx, `SELECT id FROM artifacts WHERE type = 'prd' AND project_id = (SELECT id FROM projects WHERE key = 'PAY') LIMIT 1`).Scan(&art); err != nil {
		t.Fatal(err)
	}
	chat := e.startChat("read " + art.String())
	e.until("reply", func() bool { return e.chat(chat.ID).State == "idle" })
	// A turn without a tool call has no opening line.
	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "hello"}); err != nil {
		t.Fatal(err)
	}
	e.until("second reply", func() bool {
		m, _ := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
		return len(m) == 5 && e.chat(chat.ID).State == "idle"
	})
	msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 20})
	if err != nil || len(msgs) != 5 {
		t.Fatalf("messages %+v %v", msgs, err)
	}
	opening, answer := msgs[1], msgs[2]
	if opening.Role != "assistant" || opening.BodyMd != "Let me read that for you." || string(opening.Citations) != "[]" || opening.RunTurnID == nil || answer.RunTurnID == nil || *opening.RunTurnID != *answer.RunTurnID {
		t.Fatalf("opening %+v", opening)
	}
	if answer.Role != "assistant" || !strings.HasPrefix(answer.BodyMd, "Chat reply: read") || !strings.Contains(string(answer.Citations), art.String()) {
		t.Fatalf("answer %+v", answer)
	}
	if msgs[3].Role != "user" || msgs[4].Role != "assistant" || !strings.HasPrefix(msgs[4].BodyMd, "Chat reply: hello") {
		t.Fatalf("second turn %+v", msgs[3:])
	}
}

func (e env) setOverride(o agentdef.Override) error {
	return (&agents.Service{Pool: e.pool}).SetOverride(e.ctx, e.ws, e.me.ID, e.assistant().Handle, "PAY", o)
}

func (e env) workspace(run store.Run) string {
	return filepath.Join(e.dir, "work", "runs", run.ID.String(), "workspace")
}

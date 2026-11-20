package runs

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// An aside is a hidden, read-only chat answered by a fresh session that sees
// the parent's running reply; it never touches the parent's conversation.
func TestChatAside(t *testing.T) {
	f := newChatFixture(t)
	parent, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{Message: &ChatMessageInput{Body: "fix the flaky retry test"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "   ", nil); err == nil {
		t.Fatal("an empty aside was accepted")
	}

	// What the running reply has done so far.
	run := *f.chat(t, parent.ID).CurrentRunID
	for _, e := range []struct {
		typ     string
		payload map[string]any
	}{
		{"message", map[string]any{"role": "assistant", "text": "Reproducing it first."}},
		{"tool_call", map[string]any{"id": "t1", "tool": "Bash", "input": map[string]any{"command": "go test ./runner -count=50"}}},
		{"tool_result", map[string]any{"id": "t1", "tool": "Bash", "output": "--- FAIL: TestRetry (2.00s)\nFAIL 3 of 50"}},
	} {
		raw, _ := json.Marshal(e.payload)
		if err := f.q.AddRunEvent(f.ctx, store.AddRunEventParams{RunID: run, Type: e.typ, Payload: raw}); err != nil {
			t.Fatal(err)
		}
	}

	// The code it has changed so far, as the runner's live review records it.
	branch, baseSHA, headSHA := "fix/flaky-retry", "1111111222222", "abc1234567890"
	files, _ := json.Marshal([]map[string]any{{
		"path": "runner/retry.go", "status": "modified", "additions": 1, "deletions": 1,
		"patch": "@@ -40 +40 @@\n-time.Sleep(time.Second)\n+time.Sleep(backoff(attempt))",
	}})
	if err := f.q.UpsertChatCodeReview(f.ctx, store.UpsertChatCodeReviewParams{
		ChatID: parent.ID, RepoUrl: "https://github.com/acme/app", Branch: &branch, BaseSha: &baseSHA, HeadSha: &headSHA,
		Commits: []byte("[]"), Files: files, Dirty: true, Live: true, Tree: []byte("[]"),
	}); err != nil {
		t.Fatal(err)
	}

	aside, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "how many runs failed so far?", nil)
	if err != nil {
		t.Fatal(err)
	}
	if !aside.Hidden || aside.ParentChatID == nil || *aside.ParentChatID != parent.ID || aside.RepoUrl != nil || aside.State != "running" {
		t.Fatalf("aside chat %+v", aside)
	}
	if aside.Harness != parent.Harness || aside.Model != parent.Model {
		t.Fatalf("aside runs %s/%s, parent %s/%s", aside.Harness, aside.Model, parent.Harness, parent.Model)
	}
	if got := f.userMessages(t, aside.ID); len(got) != 1 || got[0] != "how many runs failed so far?" {
		t.Fatalf("aside stored %q, want only the question", got)
	}
	if got := f.userMessages(t, parent.ID); len(got) != 1 {
		t.Fatalf("the aside reached the parent's conversation: %q", got)
	}
	if c := f.chat(t, parent.ID); c.State != "running" || *c.CurrentRunID != run {
		t.Fatalf("the aside disturbed the running reply: %+v", c)
	}

	// Its turn sees the conversation, the live reply and the question, and isn't asked to retitle.
	turns, err := f.q.ListTurns(f.ctx, *aside.CurrentRunID)
	if err != nil || len(turns) != 1 {
		t.Fatalf("aside turns %d, %v", len(turns), err)
	}
	prompt := turns[0].InputMessage
	for _, want := range []string{"fix the flaky retry test", "Reproducing it first.", "Called Bash", "go test ./runner -count=50", "FAIL 3 of 50",
		"Branch diff snapshot", "branch fix/flaky-retry", "modified runner/retry.go (+1/-1)", "+time.Sleep(backoff(attempt))",
		"this is an aside", "how many runs failed so far?"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("aside prompt lacks %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "different harness or model") {
		t.Error("an aside was told other models answered the conversation")
	}
	if strings.Contains(prompt, "set_chat_title") {
		t.Error("an aside was asked to title itself")
	}

	// Read-only, whatever the persona answering the parent may do.
	asideRun, err := f.q.GetRun(f.ctx, store.GetRunParams{ID: *aside.CurrentRunID, WorkspaceID: f.ws})
	if err != nil {
		t.Fatal(err)
	}
	spec, err := Spec(asideRun)
	if err != nil {
		t.Fatal(err)
	}
	if spec.HarnessOptions[agentdef.OptionAside] != "true" || spec.HarnessOptions["sandbox"] != "read-only" || spec.Mode("repo:write") == agentdef.Allowed || len(spec.MCPServers) != 0 {
		t.Fatalf("aside spec isn't read-only: %+v %+v", spec.HarnessOptions, spec.Scopes)
	}

	// Hidden from the chat list; listed under its parent.
	list, err := f.q.ListChatsForUser(f.ctx, store.ListChatsForUserParams{WorkspaceID: f.ws, CreatedBy: f.user, PersonaFilter: "all", SpaceFilter: "all", RowLimit: 50})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range list {
		if c.ID == aside.ID {
			t.Fatal("the aside is in the chat list")
		}
	}
	if got, _ := f.rs.ListChatAsides(f.ctx, f.ws, f.user, parent.ID); len(got) != 1 || got[0].ID != aside.ID {
		t.Fatalf("parent's asides %+v", got)
	}
	if _, err := f.rs.QueueChatFollowup(f.ctx, f.ws, f.user, aside.ID, "and?"); !isConflict(err) {
		t.Fatalf("queueing on an aside: %v", err)
	}

	// At most MaxLiveAsides answer at once.
	for i := 1; i < MaxLiveAsides; i++ {
		if _, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "still there?", nil); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "one too many", nil); !isConflict(err) {
		t.Fatalf("aside past the limit: %v", err)
	}

	// Once it has answered, its segment ends.
	f.endTurn(t, aside.ID, "idle")
	if err := EndAside(f.ctx, f.q, aside.ID); err != nil {
		t.Fatal(err)
	}
	if r, _ := f.q.GetRun(f.ctx, store.GetRunParams{ID: asideRun.ID, WorkspaceID: f.ws}); r.State != "completed" {
		t.Fatalf("answered aside's run is %s", r.State)
	}

	// Nothing running: there's nothing to ask about.
	f.endTurn(t, parent.ID, "idle")
	if _, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "and now?", nil); !isConflict(err) {
		t.Fatalf("aside on an idle chat: %v", err)
	}

	// Deleting the chat deletes its asides.
	if err := f.rs.DeleteChat(f.ctx, f.ws, f.user, parent.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := f.q.GetChatSession(f.ctx, store.GetChatSessionParams{ID: aside.ID, WorkspaceID: f.ws}); err == nil {
		t.Fatal("the aside outlived its chat")
	}
}

// A thread is an aside anchored to one message: it can start while nothing
// runs, its first turn sees that message, and the person can keep replying.
func TestChatThread(t *testing.T) {
	f := newChatFixture(t)
	parent, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{Message: &ChatMessageInput{Body: "compare kokoro and piper for local tts"}})
	if err != nil {
		t.Fatal(err)
	}
	f.endTurn(t, parent.ID, "idle")
	msgs, err := f.q.ListChatMessages(f.ctx, store.ListChatMessagesParams{SessionID: parent.ID, Limit: 10})
	if err != nil || len(msgs) == 0 {
		t.Fatalf("parent messages %d, %v", len(msgs), err)
	}
	anchor := msgs[0].ID

	// Without an anchor an idle chat has nothing to ask about; with one it does.
	if _, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "why these two?", nil); !isConflict(err) {
		t.Fatalf("unanchored aside on an idle chat: %v", err)
	}
	thread, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "why these two?", &anchor)
	if err != nil {
		t.Fatal(err)
	}
	if thread.AnchorMessageID == nil || *thread.AnchorMessageID != anchor || thread.ParentChatID == nil || !thread.Hidden {
		t.Fatalf("thread chat %+v", thread)
	}
	if !strings.HasPrefix(thread.Title, "Thread: ") {
		t.Errorf("thread titled %q", thread.Title)
	}
	turns, err := f.q.ListTurns(f.ctx, *thread.CurrentRunID)
	if err != nil || len(turns) != 1 {
		t.Fatalf("thread turns %d, %v", len(turns), err)
	}
	prompt := turns[0].InputMessage
	for _, want := range []string{"The message this thread is about", "compare kokoro and piper", "this is a thread", "why these two?"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("thread prompt lacks %q:\n%s", want, prompt)
		}
	}
	if strings.Contains(prompt, "still running") {
		t.Error("a thread on an idle chat was told about a running reply")
	}
	if got := f.userMessages(t, parent.ID); len(got) != 1 {
		t.Fatalf("the thread reached the parent's conversation: %q", got)
	}

	// The person keeps replying in it once it has answered: its run waits, as a chat's does.
	f.endTurn(t, thread.ID, "idle")
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, thread.ID, ChatMessageInput{Body: "and for long texts?"}); err != nil {
		t.Fatalf("replying in a thread: %v", err)
	}
	if got := f.userMessages(t, thread.ID); len(got) != 2 || got[1] != "and for long texts?" {
		t.Fatalf("thread messages %q", got)
	}

	// The anchor must be a person's or persona's message of this very chat.
	other, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{Message: &ChatMessageInput{Body: "unrelated"}})
	if err != nil {
		t.Fatal(err)
	}
	foreign, err := f.q.ListChatMessages(f.ctx, store.ListChatMessagesParams{SessionID: other.ID, Limit: 1})
	if err != nil {
		t.Fatal(err)
	}
	var invalid *apperr.ValidationError
	if _, err := f.rs.StartChatAside(f.ctx, f.ws, f.user, parent.ID, "?", &foreign[0].ID); !errors.As(err, &invalid) {
		t.Fatalf("thread on another chat's message: %v", err)
	}
}

func TestChatSecondOpinion(t *testing.T) {
	f := newChatFixture(t)
	f.rs.ModelDiscovery = func(_ context.Context, h, _ string) ([]chatmodels.Model, error) {
		switch h {
		case agentdef.HarnessClaudeCode:
			return []chatmodels.Model{{ID: "claude-sonnet-4-6", Label: "Sonnet 4.6", Default: true}}, nil
		case agentdef.HarnessCodex:
			return []chatmodels.Model{{ID: "gpt-5.4", Label: "GPT-5.4", Default: true}}, nil
		default:
			return []chatmodels.Model{{ID: "default", Label: "Default", Default: true}}, nil
		}
	}

	// Empty idle chat with no messages or code reviews cannot start a second opinion.
	empty, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.rs.StartChatAsideWith(f.ctx, f.ws, f.user, empty.ID, AsideInput{
		SecondOpinion: true,
		Harness:       agentdef.HarnessCodex,
	}); !isConflict(err) {
		t.Fatalf("empty idle chat second opinion: got %v, want conflict", err)
	}

	parent, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{
		Message: &ChatMessageInput{Body: "implement optimistic locking"},
	})
	if err != nil {
		t.Fatal(err)
	}
	f.endTurn(t, parent.ID, "idle")
	reply, err := f.q.AppendChatMessage(f.ctx, store.AppendChatMessageParams{
		SessionID:   parent.ID,
		Role:        "assistant",
		BodyMd:      "Added revision check in store/lock.go.",
		ContextRefs: []byte("[]"),
		Citations:   []byte("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}
	beforeParent := f.chat(t, parent.ID)
	repoURL := "https://github.com/acme/app"
	branch := "feat/optimistic"
	baseSHA := "1111111222222"
	headSHA := "abc1234567890"
	commitsJSON, _ := json.Marshal([]map[string]string{{"sha": headSHA, "subject": "Add optimistic revision check"}})
	filesJSON, _ := json.Marshal([]map[string]any{{
		"path":      "store/lock.go",
		"status":    "modified",
		"additions": 2,
		"deletions": 0,
		"patch":     "@@ -10,0 +11,2 @@\n+if rev != cur {\n+  return ErrConflict\n+}",
	}})
	if err := f.q.UpsertChatCodeReview(f.ctx, store.UpsertChatCodeReviewParams{
		ChatID:  parent.ID,
		RepoUrl: repoURL,
		Branch:  &branch,
		BaseSha: &baseSHA,
		HeadSha: &headSHA,
		Commits: commitsJSON,
		Files:   filesJSON,
		Dirty:   true,
		Tree:    []byte("[]"),
	}); err != nil {
		t.Fatal(err)
	}

	// Unknown repository filter fails validation (422).
	var invalid *apperr.ValidationError
	if _, err := f.rs.StartChatAsideWith(f.ctx, f.ws, f.user, parent.ID, AsideInput{
		SecondOpinion: true,
		Harness:       agentdef.HarnessCodex,
		Repository:    "https://github.com/acme/other",
	}); !errors.As(err, &invalid) {
		t.Fatalf("unknown repository filter: got %v, want validation error", err)
	}

	// Empty body defaults prompt; nil anchor auto-anchors to newest assistant reply;
	// parent chat's harness/model/run stays untouched.
	aside, err := f.rs.StartChatAsideWith(f.ctx, f.ws, f.user, parent.ID, AsideInput{
		SecondOpinion: true,
		Harness:       agentdef.HarnessCodex,
		Repository:    repoURL,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !aside.SecondOpinion || !aside.Hidden || aside.ParentChatID == nil || *aside.ParentChatID != parent.ID {
		t.Fatalf("unexpected second opinion chat: %+v", aside)
	}
	if aside.AnchorMessageID == nil || *aside.AnchorMessageID != reply.ID {
		t.Fatalf("expected auto-anchor to %s, got %v", reply.ID, aside.AnchorMessageID)
	}
	if aside.Harness != agentdef.HarnessCodex || aside.Model != "gpt-5.4" {
		t.Fatalf("second opinion selection = %s/%s, want codex/gpt-5.4", aside.Harness, aside.Model)
	}
	afterParent := f.chat(t, parent.ID)
	if afterParent.Harness != beforeParent.Harness || afterParent.Model != beforeParent.Model ||
		afterParent.CurrentRunID == nil || beforeParent.CurrentRunID == nil || *afterParent.CurrentRunID != *beforeParent.CurrentRunID {
		t.Fatalf("parent chat was mutated: before=%+v after=%+v", beforeParent, afterParent)
	}
	if got := f.userMessages(t, parent.ID); len(got) != 1 {
		t.Fatalf("second opinion polluted parent user messages: %q", got)
	}

	turns, err := f.q.ListTurns(f.ctx, *aside.CurrentRunID)
	if err != nil || len(turns) != 1 {
		t.Fatalf("aside turns %d, %v", len(turns), err)
	}
	prompt := turns[0].InputMessage
	for _, want := range []string{
		"implement optimistic locking",
		"Added revision check in store/lock.go.",
		"feat/optimistic",
		"abc1234",
		"store/lock.go",
		"+if rev != cur",
		"second-opinion aside",
		"Give an independent second opinion on this reply",
	} {
		if !strings.Contains(prompt, want) {
			t.Errorf("second opinion prompt lacks %q:\n%s", want, prompt)
		}
	}

	asideRun, err := f.q.GetRun(f.ctx, store.GetRunParams{ID: *aside.CurrentRunID, WorkspaceID: f.ws})
	if err != nil {
		t.Fatal(err)
	}
	spec, err := Spec(asideRun)
	if err != nil {
		t.Fatal(err)
	}
	if spec.HarnessOptions[agentdef.OptionAside] != "true" || spec.HarnessOptions["sandbox"] != "read-only" || spec.Mode("repo:write") == agentdef.Allowed {
		t.Fatalf("second opinion spec not read-only: %+v %+v", spec.HarnessOptions, spec.Scopes)
	}
}

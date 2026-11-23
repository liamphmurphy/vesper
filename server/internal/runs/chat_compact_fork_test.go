package runs

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestCompactChatManualAndAutoRollover(t *testing.T) {
	f := newChatFixture(t)

	chat, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{
		Title: "Compactable chat",
	})
	if err != nil {
		t.Fatal(err)
	}
	// Empty chat cannot be compacted yet.
	if _, err := f.rs.CompactChat(f.ctx, f.ws, f.user, chat.ID, ""); err == nil {
		t.Fatal("expected error compacting empty chat")
	}

	// Start turn 1 and confirm running chat rejects /compact with 409.
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, chat.ID, ChatMessageInput{Body: "Investigate auth bug"}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.rs.CompactChat(f.ctx, f.ws, f.user, chat.ID, "keep auth"); !isConflict(err) {
		t.Fatalf("expected conflict while running, got %v", err)
	}

	// Simulate runner completing turn 1 and saving session + context size + git review.
	c1 := f.chat(t, chat.ID)
	runID := *c1.CurrentRunID
	sessID := "harness-sess-1"
	if err := f.q.SetRunSession(f.ctx, store.SetRunSessionParams{ID: runID, HarnessSessionID: &sessID}); err != nil {
		t.Fatal(err)
	}
	if err := f.q.SetRunContextTokens(f.ctx, store.SetRunContextTokensParams{ID: runID, ContextTokens: 95000}); err != nil {
		t.Fatal(err)
	}
	if err := f.q.FinishUnfinishedChatTurns(f.ctx, runID); err != nil {
		t.Fatal(err)
	}
	f.endTurn(t, chat.ID, "idle")

	branch := "feat/auth-fix"
	sha := "abc1234567890abcdef"
	filesJSON, _ := json.Marshal([]map[string]any{{"path": "server/auth.go", "status": "modified"}})
	commitsJSON, _ := json.Marshal([]map[string]any{{"sha": sha, "subject": "tighten token check"}})
	if err := f.q.UpsertChatCodeReview(f.ctx, store.UpsertChatCodeReviewParams{
		ChatID: chat.ID, RepoUrl: "https://github.com/acme/repo", Branch: &branch, HeadSha: &sha,
		Files: filesJSON, Commits: commitsJSON, Dirty: true, Live: false, Tree: []byte("[]"),
	}); err != nil {
		t.Fatal(err)
	}

	// Manual /compact resets CLI session & context_tokens while keeping CurrentRunID intact.
	compacted, err := f.rs.CompactChat(f.ctx, f.ws, f.user, chat.ID, "preserve auth invariants")
	if err != nil {
		t.Fatal(err)
	}
	if !compacted.CompactPending || compacted.CompactFocus != "preserve auth invariants" {
		t.Fatalf("unexpected compact state: pending=%v focus=%q", compacted.CompactPending, compacted.CompactFocus)
	}
	if compacted.CurrentRunID == nil || *compacted.CurrentRunID != runID {
		t.Fatalf("expected CurrentRunID %s to be preserved, got %v", runID, compacted.CurrentRunID)
	}
	runAfterCompact, err := f.q.GetRun(f.ctx, store.GetRunParams{ID: runID, WorkspaceID: f.ws})
	if err != nil {
		t.Fatal(err)
	}
	if runAfterCompact.HarnessSessionID != nil {
		t.Fatalf("expected HarnessSessionID cleared, got %q", *runAfterCompact.HarnessSessionID)
	}
	if runAfterCompact.ContextTokens != 0 {
		t.Fatalf("expected ContextTokens reset to 0, got %d", runAfterCompact.ContextTokens)
	}

	// Next user message builds compacted handoff prompt with focus + git brief and clears flag.
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, chat.ID, ChatMessageInput{Body: "Now add tests"}); err != nil {
		t.Fatal(err)
	}
	c2 := f.chat(t, chat.ID)
	if c2.CurrentRunID == nil || *c2.CurrentRunID != runID {
		t.Fatalf("expected same run ID %s, got %v", runID, c2.CurrentRunID)
	}
	if c2.CompactPending || c2.CompactFocus != "" {
		t.Fatalf("expected compact flags cleared after next turn, got pending=%v focus=%q", c2.CompactPending, c2.CompactFocus)
	}
	turns, err := f.q.ListTurns(f.ctx, runID)
	if err != nil {
		t.Fatal(err)
	}
	lastPrompt := turns[len(turns)-1].InputMessage
	for _, want := range []string{compactLead, "preserve auth invariants", "## Workspace git state", "feat/auth-fix", "server/auth.go", "Now add tests"} {
		if !strings.Contains(lastPrompt, want) {
			t.Fatalf("expected turn prompt to contain %q, got:\n%s", want, lastPrompt)
		}
	}

	// Auto-rollover test: finish turn, set session + context tokens >= threshold.
	if err := f.q.FinishUnfinishedChatTurns(f.ctx, runID); err != nil {
		t.Fatal(err)
	}
	f.endTurn(t, chat.ID, "idle")
	sess2 := "harness-sess-2"
	if err := f.q.SetRunSession(f.ctx, store.SetRunSessionParams{ID: runID, HarnessSessionID: &sess2}); err != nil {
		t.Fatal(err)
	}
	if err := f.q.SetRunContextTokens(f.ctx, store.SetRunContextTokensParams{ID: runID, ContextTokens: 15000}); err != nil {
		t.Fatal(err)
	}
	f.rs.RolloverContextTokens = 10000

	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, chat.ID, ChatMessageInput{Body: "Continue past rollover"}); err != nil {
		t.Fatal(err)
	}
	runAfterAuto, err := f.q.GetRun(f.ctx, store.GetRunParams{ID: runID, WorkspaceID: f.ws})
	if err != nil {
		t.Fatal(err)
	}
	if runAfterAuto.HarnessSessionID != nil || runAfterAuto.ContextTokens != 0 {
		t.Fatalf("expected auto-rollover to reset session & context tokens, got sess=%v tokens=%d", runAfterAuto.HarnessSessionID, runAfterAuto.ContextTokens)
	}
	turns, _ = f.q.ListTurns(f.ctx, runID)
	if !strings.Contains(turns[len(turns)-1].InputMessage, compactLead) {
		t.Fatalf("expected auto-rollover turn to include compactLead, got:\n%s", turns[len(turns)-1].InputMessage)
	}

	// Setting per-chat auto_rollover_tokens = 0 disables auto-rollover even when server default is set.
	if err := f.q.FinishUnfinishedChatTurns(f.ctx, runID); err != nil {
		t.Fatal(err)
	}
	f.endTurn(t, chat.ID, "idle")
	cBeforePatch := f.chat(t, chat.ID)
	zero := int64(0)
	if _, err := f.rs.UpdateChat(f.ctx, f.ws, f.user, chat.ID, ChatPatchInput{
		Revision:           cBeforePatch.Revision,
		AutoRolloverSet:    true,
		AutoRolloverTokens: &zero,
	}); err != nil {
		t.Fatal(err)
	}
	sess3 := "harness-sess-3"
	if err := f.q.SetRunSession(f.ctx, store.SetRunSessionParams{ID: runID, HarnessSessionID: &sess3}); err != nil {
		t.Fatal(err)
	}
	if err := f.q.SetRunContextTokens(f.ctx, store.SetRunContextTokensParams{ID: runID, ContextTokens: 99000}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, chat.ID, ChatMessageInput{Body: "Keep same session"}); err != nil {
		t.Fatal(err)
	}
	runNoRoll, _ := f.q.GetRun(f.ctx, store.GetRunParams{ID: runID, WorkspaceID: f.ws})
	if runNoRoll.HarnessSessionID == nil || *runNoRoll.HarnessSessionID != sess3 {
		t.Fatalf("expected auto_rollover_tokens=0 to disable rollover, got sess=%v", runNoRoll.HarnessSessionID)
	}
}

func TestForkChatPrefixAndBranchRepo(t *testing.T) {
	f := newChatFixture(t)
	canCode := true
	coder, err := (&personas.Service{Pool: f.rs.Pool}).Create(f.ctx, personas.Owner{WorkspaceID: f.ws, UserID: f.user}, personas.NewInput{
		Name: "Fork Coder", Code: &canCode,
	})
	if err != nil {
		t.Fatal(err)
	}
	repoURL := "https://github.com/acme/forkable"
	src, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{
		Title:     "Original feature",
		PersonaID: &coder.ID,
		RepoURL:   repoURL,
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, src.ID, ChatMessageInput{Body: "Step 1 prompt"}); err != nil {
		t.Fatal(err)
	}
	c1 := f.chat(t, src.ID)
	f.q.FinishUnfinishedChatTurns(f.ctx, *c1.CurrentRunID)
	f.endTurn(t, src.ID, "idle")

	a1, err := f.q.AppendChatMessage(f.ctx, store.AppendChatMessageParams{
		SessionID: src.ID, Role: "assistant", BodyMd: "Step 1 answer", RunID: c1.CurrentRunID,
		ContextRefs: []byte("[]"), Citations: []byte("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}
	b1, sha1 := "feat/orig-work", "1111222233334444"
	if err := f.q.SetChatMessageGitRef(f.ctx, store.SetChatMessageGitRefParams{ID: a1.ID, GitBranch: &b1, GitCommitSha: &sha1}); err != nil {
		t.Fatal(err)
	}

	// Later message after the fork point must NOT be copied.
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, src.ID, ChatMessageInput{Body: "Wrong turn to fork away from"}); err != nil {
		t.Fatal(err)
	}

	// Reject invalid work branch name.
	if _, err := f.rs.ForkChat(f.ctx, f.ws, f.user, src.ID, ForkChatInput{
		MessageID: a1.ID, BranchRepo: true, BranchName: "bad branch name!",
	}); err == nil {
		t.Fatal("expected invalid branch_name error")
	}

	forked, err := f.rs.ForkChat(f.ctx, f.ws, f.user, src.ID, ForkChatInput{
		MessageID:  a1.ID,
		BranchRepo: true,
		BranchName: "feat/alt-path",
	})
	if err != nil {
		t.Fatal(err)
	}
	if forked.ForkedFromChatID == nil || *forked.ForkedFromChatID != src.ID {
		t.Fatalf("expected forked_from_chat_id=%s, got %v", src.ID, forked.ForkedFromChatID)
	}
	if forked.ForkedFromMessageID == nil || *forked.ForkedFromMessageID != a1.ID {
		t.Fatalf("expected forked_from_message_id=%s, got %v", a1.ID, forked.ForkedFromMessageID)
	}
	copied, err := f.q.ListChatMessages(f.ctx, store.ListChatMessagesParams{SessionID: forked.ID, Limit: 50})
	if err != nil {
		t.Fatal(err)
	}
	if len(copied) != 2 || copied[0].BodyMd != "Step 1 prompt" || copied[1].BodyMd != "Step 1 answer" {
		t.Fatalf("unexpected forked messages: %+v", copied)
	}
	if copied[1].RunID != nil {
		t.Fatalf("expected copied message run_id to be nil, got %v", copied[1].RunID)
	}
	if copied[1].GitCommitSha == nil || *copied[1].GitCommitSha != sha1 {
		t.Fatalf("expected git_commit_sha copied, got %v", copied[1].GitCommitSha)
	}
	repos, err := f.q.ChatRepositories(f.ctx, forked.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(repos) != 1 || deref(repos[0].CheckpointBranch) != sha1 || deref(repos[0].ForkBranch) != "feat/alt-path" {
		t.Fatalf("unexpected forked repo attachment: %+v", repos)
	}

	// First turn on the forked chat should deliver forkLead + copied history.
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, forked.ID, ChatMessageInput{Body: "Try alternative design"}); err != nil {
		t.Fatal(err)
	}
	fAfter := f.chat(t, forked.ID)
	turns, err := f.q.ListTurns(f.ctx, *fAfter.CurrentRunID)
	if err != nil {
		t.Fatal(err)
	}
	prompt := turns[0].InputMessage
	for _, want := range []string{forkLead, "Step 1 prompt", "Step 1 answer", "Try alternative design"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("expected fork turn prompt to include %q, got:\n%s", want, prompt)
		}
	}
}

func TestCompactPreservesPinnedMessagesAndDefaultAutoRollover(t *testing.T) {
	f := newChatFixture(t)
	chat, err := f.rs.StartChat(f.ctx, f.ws, f.user, ChatInput{Title: "Pinned compact"})
	if err != nil {
		t.Fatal(err)
	}
	// EffectiveChatAutoRollover falls back to DefaultChatAutoRolloverTokens (160k).
	if got := EffectiveChatAutoRollover(chat, 0); got != DefaultChatAutoRolloverTokens {
		t.Fatalf("expected default auto-rollover %d, got %d", DefaultChatAutoRolloverTokens, got)
	}

	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, chat.ID, ChatMessageInput{Body: "Constraint: never drop audit logs"}); err != nil {
		t.Fatal(err)
	}
	c1 := f.chat(t, chat.ID)
	runID := *c1.CurrentRunID
	if err := f.q.FinishUnfinishedChatTurns(f.ctx, runID); err != nil {
		t.Fatal(err)
	}
	f.endTurn(t, chat.ID, "idle")

	msgs, err := f.q.ListChatMessages(f.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 10})
	if err != nil || len(msgs) == 0 {
		t.Fatalf("list messages: %v (%d)", err, len(msgs))
	}
	if _, err := f.q.SetChatMessageBookmark(f.ctx, store.SetChatMessageBookmarkParams{
		ID: msgs[0].ID, SessionID: chat.ID, Bookmarked: true,
	}); err != nil {
		t.Fatal(err)
	}

	// Default 160k auto-rollover fires when ContextTokens reaches DefaultChatAutoRolloverTokens.
	sess := "harness-default-auto"
	if err := f.q.SetRunSession(f.ctx, store.SetRunSessionParams{ID: runID, HarnessSessionID: &sess}); err != nil {
		t.Fatal(err)
	}
	if err := f.q.SetRunContextTokens(f.ctx, store.SetRunContextTokensParams{ID: runID, ContextTokens: DefaultChatAutoRolloverTokens}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.rs.PostChatMessage(f.ctx, f.ws, f.user, chat.ID, ChatMessageInput{Body: "Next step after auto-compact"}); err != nil {
		t.Fatal(err)
	}
	turns, err := f.q.ListTurns(f.ctx, runID)
	if err != nil {
		t.Fatal(err)
	}
	prompt := turns[len(turns)-1].InputMessage
	for _, want := range []string{compactLead, "## Pinned messages (preserved verbatim across compaction)", "Constraint: never drop audit logs"} {
		if !strings.Contains(prompt, want) {
			t.Fatalf("expected compacted prompt to include %q, got:\n%s", want, prompt)
		}
	}
}

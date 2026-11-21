package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestPRFeedbackInboxAPIAndResumeActions(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()

	// Find a distinct second user to verify push-request inbox isolation.
	users, err := e.q.ListUsers(ctx, e.me.WorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	var other store.User
	for _, u := range users {
		if u.ID != e.me.ID {
			other = u
			break
		}
	}
	if other.ID == [16]byte{} {
		t.Fatal("expected seeded second user")
	}

	// ---- Part A: Chat push-request PR feedback ----
	code := true
	coder, err := (&personas.Service{Pool: e.pool}).Create(ctx, personas.Owner{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID}, personas.NewInput{
		Name: "PR Coder", Code: &code,
	})
	if err != nil {
		t.Fatal(err)
	}
	chatIDStr := e.newChat(map[string]any{"persona_id": coder.ID.String()})["id"].(string)
	chatMap := e.want("GET", "/chats/"+chatIDStr, nil, http.StatusOK)
	_ = chatMap

	repoURL := "https://github.com/acme/alpha.git"
	agents, err := e.q.ListAgents(ctx, e.me.WorkspaceID)
	if err != nil || len(agents) == 0 {
		t.Fatalf("list agents: %v", err)
	}
	chatSession, err := e.q.ListChatsForUser(ctx, store.ListChatsForUserParams{
		WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID, PersonaFilter: "all", RowLimit: 20,
	})
	if err != nil {
		t.Fatal(err)
	}
	var chatRow store.ChatSession
	for _, c := range chatSession {
		if c.ID.String() == chatIDStr {
			chatRow = c
			break
		}
	}
	if chatRow.ID == [16]byte{} {
		t.Fatal("chat not found")
	}
	if _, err := e.q.AttachChatRepository(ctx, store.AttachChatRepositoryParams{
		ChatID: chatRow.ID, RepoUrl: repoURL, Directory: ".lazyagents/repos/acme/alpha",
	}); err != nil {
		t.Fatal(err)
	}

	prReq, err := e.q.CreatePushRequest(ctx, store.CreatePushRequestParams{
		WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID, ChatID: chatRow.ID,
		AgentID: agents[0].ID, RepoUrl: repoURL, Branch: "feat/alpha", Title: "Alpha PR",
	})
	if err != nil {
		t.Fatal(err)
	}
	chatPRURL := "https://github.com/acme/alpha/pull/88"
	chatPRNum, openState := int32(88), "open"
	if _, err := e.q.FinishPushRequest(ctx, store.FinishPushRequestParams{
		ID: prReq.ID, State: "pushed", PrUrl: &chatPRURL, PrNumber: &chatPRNum, PrState: &openState,
	}); err != nil {
		t.Fatal(err)
	}

	now := time.Now().UTC().Truncate(time.Second)
	checksJSON, _ := json.Marshal([]map[string]any{{
		"name": "ci-test", "conclusion": "failure", "details_url": "https://github.com/acme/alpha/runs/1", "summary": "TestAlpha failed",
	}})
	threadsJSON, _ := json.Marshal([]map[string]any{{
		"id": "th-1", "path": "api.go", "line": 19, "url": "https://github.com/acme/alpha/pull/88#discussion_r1",
		"diff_hunk": "@@ -17,3 +17,3 @@\n+call()", "updated_at": now,
		"comments": []map[string]any{{"author": "bob", "body": "Use context here", "created_at": now}},
	}})
	if _, err := e.q.UpsertPRFeedback(ctx, store.UpsertPRFeedbackParams{
		WorkspaceID: e.me.WorkspaceID, PrUrl: chatPRURL, HeadSha: "sha-88",
		CiState: "failing", FailedChecksCount: 1, FailedChecks: checksJSON,
		UnresolvedThreads: 1, ReviewThreads: threadsJSON,
		CiFailedAt: &now, ReviewUpdatedAt: &now,
	}); err != nil {
		t.Fatal(err)
	}

	pushList := e.want("GET", "/chats/"+chatIDStr+"/push-requests", nil, http.StatusOK)
	reqs := pushList["requests"].([]any)
	if len(reqs) != 1 {
		t.Fatalf("push requests len = %d", len(reqs))
	}
	fbObj := reqs[0].(map[string]any)["feedback"].(map[string]any)
	if fbObj["ci_state"] != "failing" || fbObj["failed_checks_count"] != float64(1) || fbObj["unresolved_threads"] != float64(1) {
		t.Fatalf("unexpected push request feedback: %+v", fbObj)
	}

	srv := &Server{AnonymousAPI: true, Pool: e.pool, Q: e.q, Tracker: e.runs.Tracker, Runs: e.runs}
	meCtx := auth.WithUser(ctx, e.me)
	otherCtx := auth.WithUser(ctx, other)

	myInbox, err := srv.ListInbox(meCtx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	ciPushID := "pr_ci_failed:push:" + prReq.ID.String()
	revPushID := "pr_review_comments:push:" + prReq.ID.String()
	foundPushCI, foundPushRev := false, false
	for _, it := range myInbox.(api.ListInbox200JSONResponse).Items {
		if it.Id == ciPushID && it.NeedsYou && it.Href == "/chat/"+chatIDStr {
			foundPushCI = true
		}
		if it.Id == revPushID && it.NeedsYou && it.Href == "/chat/"+chatIDStr {
			foundPushRev = true
		}
	}
	if !foundPushCI || !foundPushRev {
		t.Fatalf("expected push PR feedback items in inbox: ci=%v rev=%v", foundPushCI, foundPushRev)
	}
	otherInbox, err := srv.ListInbox(otherCtx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	for _, it := range otherInbox.(api.ListInbox200JSONResponse).Items {
		if it.Id == ciPushID || it.Id == revPushID {
			t.Fatalf("private chat push request leaked to other user inbox: %s", it.Id)
		}
	}

	msg := e.want("POST", "/push-requests/"+prReq.ID.String()+"/address-pr-feedback", map[string]any{"mode": "review"}, http.StatusCreated)
	bodyStr := msg["body_md"].(string)
	for _, wantSub := range []string{"feat/alpha", "api.go:19", "@bob", "Use context here", "request_push"} {
		if !strings.Contains(bodyStr, wantSub) {
			t.Fatalf("chat prompt missing %q:\n%s", wantSub, bodyStr)
		}
	}
	// Chat is now running; second request conflicts.
	e.want("POST", "/push-requests/"+prReq.ID.String()+"/address-pr-feedback", map[string]any{"mode": "ci"}, http.StatusConflict)

	// Review item was marked read; CI item stays unread.
	myInbox2, _ := srv.ListInbox(meCtx, api.ListInboxRequestObject{})
	for _, it := range myInbox2.(api.ListInbox200JSONResponse).Items {
		if it.Id == revPushID && !it.Read {
			t.Fatalf("expected %s marked read", revPushID)
		}
		if it.Id == ciPushID && it.Read {
			t.Fatalf("expected %s still unread", ciPushID)
		}
	}

	// ---- Part B: Ticket PR feedback & resume ----
	tk, err := tracker.Get(ctx, e.q, e.me.WorkspaceID, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	tkPRURL := "https://github.com/acme/alpha/pull/99"
	tkPRNum := int32(99)
	if err := e.q.SetTicketPR(ctx, store.SetTicketPRParams{ID: tk.ID, PrNumber: &tkPRNum, PrUrl: &tkPRURL, PrState: &openState}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, "UPDATE tickets SET branch='atlas/pay-214' WHERE id=$1", tk.ID); err != nil {
		t.Fatal(err)
	}
	tkChecksJSON, _ := json.Marshal([]map[string]any{{
		"name": "unit-tests", "conclusion": "failure", "summary": "FAIL pkg",
	}})
	tkThreadsJSON, _ := json.Marshal([]map[string]any{{
		"id": "th-t1", "path": "handler.go", "line": 10, "updated_at": now,
		"comments": []map[string]any{{"author": "carol", "body": "Check bounds", "created_at": now}},
	}})
	if _, err := e.q.UpsertPRFeedback(ctx, store.UpsertPRFeedbackParams{
		WorkspaceID: e.me.WorkspaceID, PrUrl: tkPRURL, HeadSha: "sha-99",
		CiState: "failing", FailedChecksCount: 1, FailedChecks: tkChecksJSON,
		UnresolvedThreads: 1, ReviewThreads: tkThreadsJSON,
		CiFailedAt: &now, ReviewUpdatedAt: &now,
	}); err != nil {
		t.Fatal(err)
	}

	tkResp := e.want("GET", "/tickets/PAY-214", nil, http.StatusOK)
	tkFB := tkResp["pr"].(map[string]any)["feedback"].(map[string]any)
	if tkFB["ci_state"] != "failing" || len(tkFB["review_threads"].([]any)) != 1 {
		t.Fatalf("unexpected ticket PR feedback: %+v", tkFB)
	}

	ciTicketID := "pr_ci_failed:ticket:" + tk.ID.String()
	revTicketID := "pr_review_comments:ticket:" + tk.ID.String()
	runResp := e.want("POST", "/tickets/PAY-214/address-pr-feedback", map[string]any{"mode": "ci"}, http.StatusCreated)
	if runResp["state"] != "queued" {
		t.Fatalf("expected queued run, got %v", runResp["state"])
	}
	// Active queued run rejects another dispatch.
	e.want("POST", "/tickets/PAY-214/address-pr-feedback", map[string]any{"mode": "review"}, http.StatusConflict)

	// Transition run to waiting/human_reply and verify review action resumes it directly.
	if _, err := e.pool.Exec(ctx, "UPDATE runs SET state='waiting', wait_reason='human_reply' WHERE id=$1", runResp["id"]); err != nil {
		t.Fatal(err)
	}
	resumed := e.want("POST", "/tickets/PAY-214/address-pr-feedback", map[string]any{"mode": "review"}, http.StatusCreated)
	if resumed["id"] != runResp["id"] || resumed["state"] != "running" {
		t.Fatalf("expected resumed run %v in running state, got %+v", runResp["id"], resumed)
	}
	var latestTurnMsg string
	if err := e.pool.QueryRow(ctx, "SELECT input_message FROM run_turns WHERE run_id=$1 ORDER BY seq DESC LIMIT 1", resumed["id"]).Scan(&latestTurnMsg); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(latestTurnMsg, "handler.go:10") || !strings.Contains(latestTurnMsg, "Check bounds") {
		t.Fatalf("resumed turn missing review context: %s", latestTurnMsg)
	}

	// Merged ticket PR drops both feedback items from inbox.
	if _, err := e.pool.Exec(ctx, "UPDATE tickets SET pr_state='merged' WHERE id=$1", tk.ID); err != nil {
		t.Fatal(err)
	}
	myInbox3, _ := srv.ListInbox(meCtx, api.ListInboxRequestObject{})
	for _, it := range myInbox3.(api.ListInbox200JSONResponse).Items {
		if it.Id == ciTicketID || it.Id == revTicketID {
			t.Fatalf("merged ticket PR item should disappear from inbox: %s", it.Id)
		}
	}
}

package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestLiveChatSteerAndToolApprovalAPI(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()

	// Find a distinct second user in the workspace to verify chat approval/steer ownership.
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
		t.Fatal("expected seeded second user for isolation check")
	}

	srv := &Server{
		Pool:    e.pool,
		Q:       e.q,
		Tracker: e.runs.Tracker,
		Runs:    e.runs,
	}
	meCtx := auth.WithUser(ctx, e.me)
	otherCtx := auth.WithUser(ctx, other)

	chat := e.newChat(nil)
	chatIDStr := chat["id"].(string)

	// Idle chat rejects steering with 409 Conflict.
	e.want("POST", "/chats/"+chatIDStr+"/steer", map[string]any{"body": "too early"}, http.StatusConflict)

	// Start a turn so chat is running.
	e.want("POST", "/chats/"+chatIDStr+"/messages", map[string]any{"body": "do work"}, http.StatusAccepted)
	loaded := e.want("GET", "/chats/"+chatIDStr, nil, http.StatusOK)
	runIDStr := loaded["current_run_id"].(string)
	chatSession, err := e.q.ListChatsForUser(ctx, store.ListChatsForUserParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID, PersonaFilter: "all", RowLimit: 10})
	if err != nil || len(chatSession) == 0 {
		t.Fatalf("load chat: %+v, %v", chatSession, err)
	}
	cs := chatSession[0]
	run, err := e.q.GetRun(ctx, store.GetRunParams{ID: *cs.CurrentRunID, WorkspaceID: e.me.WorkspaceID})
	if err != nil {
		t.Fatal(err)
	}
	if run.ID.String() != runIDStr {
		t.Fatalf("run id mismatch: %s vs %s", run.ID, runIDStr)
	}

	// Blank steer fails 422.
	e.invalid("POST", "/chats/"+chatIDStr+"/steer", map[string]any{"body": "   "}, "body", "1–20000")

	// Valid steer succeeds 201 and appends user message once.
	st := e.want("POST", "/chats/"+chatIDStr+"/steer", map[string]any{"body": "focus on migrations"}, http.StatusCreated)
	if st["state"] != "pending" || st["body"] != "focus on migrations" {
		t.Fatalf("unexpected steer response: %+v", st)
	}
	// Another user cannot steer this chat.
	if _, err := srv.SteerChat(otherCtx, api.SteerChatRequestObject{
		Id:   cs.ID,
		Body: &api.SteerChatJSONRequestBody{Body: "hijack"},
	}); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("other user steer = %v, want ErrNotFound", err)
	}

	// Configure chat run as actively running with tests:run requires_approval and invoke CheckTool live.
	chatAgent, err := e.q.GetAgent(ctx, store.GetAgentParams{ID: run.AgentID, WorkspaceID: e.me.WorkspaceID})
	if err != nil {
		t.Fatal(err)
	}
	spec, _ := runs.Spec(run)
	delete(spec.HarnessOptions, agentdef.OptionNoTools)
	delete(spec.HarnessOptions, "readonly")
	kept := spec.Scopes[:0]
	for _, sc := range spec.Scopes {
		if _, covers := agentdef.ModeFor(map[string]agentdef.Mode{sc.Scope: agentdef.Denied}, "tests:run"); !covers {
			kept = append(kept, sc)
		}
	}
	spec.Scopes = append(kept, agentdef.ResolvedScope{Scope: "tests:run", Mode: agentdef.RequiresApproval})
	rawSpec, _ := json.Marshal(spec)
	if _, err := e.pool.Exec(ctx, `UPDATE runs SET state='running', resolved_spec=$2 WHERE id=$1`, run.ID, rawSpec); err != nil {
		t.Fatal(err)
	}

	checkCtx, cancelCheck := context.WithTimeout(ctx, 5*time.Second)
	defer cancelCheck()
	type checkRes struct {
		d   runs.ToolDecision
		err error
	}
	checkCh := make(chan checkRes, 1)
	caller := agents.Caller{Agent: chatAgent, Kind: "run", RunID: &run.ID}
	go func() {
		d, err := e.runs.CheckTool(checkCtx, caller, runs.ToolCheck{
			Tool:  "Bash",
			Input: map[string]any{"command": "go test ./..."},
			Wait:  5 * time.Second,
		})
		checkCh <- checkRes{d, err}
	}()

	var apsDB []store.ApprovalRequest
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		apsDB, err = e.q.ListPendingApprovalsForChat(ctx, cs.ID)
		if err != nil {
			t.Fatal(err)
		}
		if len(apsDB) > 0 {
			break
		}
		time.Sleep(15 * time.Millisecond)
	}
	if len(apsDB) != 1 {
		t.Fatalf("expected 1 pending chat approval, got %d", len(apsDB))
	}

	// Owner sees it on GET /chats/{id}/tool-approvals with chat_id set and ticket_key "".
	listOut := e.want("GET", "/chats/"+chatIDStr+"/tool-approvals", nil, http.StatusOK)
	aps := listOut["approvals"].([]any)
	if len(aps) != 1 {
		t.Fatalf("expected 1 chat tool approval, got %+v", aps)
	}
	apMap := aps[0].(map[string]any)
	if apMap["chat_id"] != chatIDStr || apMap["ticket_key"] != "" {
		t.Fatalf("unexpected approval shape: %+v", apMap)
	}
	apIDStr := apMap["id"].(string)

	// Run response also exposes it cleanly.
	runOut := e.want("GET", "/runs/"+runIDStr, nil, http.StatusOK)
	if len(runOut["approvals"].([]any)) != 1 {
		t.Fatalf("expected approval on run payload, got %+v", runOut["approvals"])
	}

	// Owner sees the chat approval in ListInbox; another user must NOT see private chat approvals in ListInbox.
	myInbox, err := srv.ListInbox(meCtx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	wantInboxID := "approval:" + apIDStr
	foundMine := false
	for _, item := range myInbox.(api.ListInbox200JSONResponse).Items {
		if item.Id == wantInboxID {
			foundMine = true
			if item.Href != "/chat/"+chatIDStr || item.TicketKey != "" {
				t.Fatalf("unexpected chat approval inbox item: %+v", item)
			}
		}
	}
	if !foundMine {
		t.Fatalf("owner inbox missing chat approval %s", wantInboxID)
	}
	otherInbox, err := srv.ListInbox(otherCtx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range otherInbox.(api.ListInbox200JSONResponse).Items {
		if item.Id == wantInboxID {
			t.Fatalf("private chat approval leaked into another user's inbox: %+v", item)
		}
	}

	// Other user cannot list chat tool approvals or decide the approval.
	if _, err := srv.ListChatToolApprovals(otherCtx, api.ListChatToolApprovalsRequestObject{Id: cs.ID}); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("other user ListChatToolApprovals = %v, want ErrNotFound", err)
	}
	if _, err := srv.DecideApproval(otherCtx, api.DecideApprovalRequestObject{
		Id:       apsDB[0].ID,
		Decision: "approve",
		Body:     &api.DecideApprovalJSONRequestBody{},
	}); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("other user DecideApproval = %v, want ErrNotFound", err)
	}

	// Owner decides approval over HTTP, live CheckTool unblocks with allow, and pending list clears.
	e.want("POST", "/approvals/"+apIDStr+"/approve", map[string]any{}, http.StatusOK)
	res := <-checkCh
	if res.err != nil || res.d.Decision != "allow" {
		t.Fatalf("live CheckTool after HTTP approve = %+v, %v", res.d, res.err)
	}
	afterOut := e.want("GET", "/chats/"+chatIDStr+"/tool-approvals", nil, http.StatusOK)
	if len(afterOut["approvals"].([]any)) != 0 {
		t.Fatalf("expected empty pending approvals after decision, got %+v", afterOut)
	}
}

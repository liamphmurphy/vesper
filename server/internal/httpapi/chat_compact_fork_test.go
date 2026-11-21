package httpapi

import (
	"context"
	"net/http"
	"testing"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestCompactAndForkChatHTTP(t *testing.T) {
	e := newChatEnvWith(t, func(rs *runs.Service) {
		rs.RolloverContextTokens = 100000
	})
	ctx := context.Background()

	created := e.want("POST", "/chats", map[string]any{"title": "HTTP compact & fork"}, http.StatusCreated)
	chatID := created["id"].(string)

	// First user turn puts chat in running state.
	posted := e.want("POST", "/chats/"+chatID+"/messages", map[string]any{"body": "First question"}, http.StatusAccepted)
	runID := posted["chat"].(map[string]any)["current_run_id"].(string)
	firstMsgID := posted["message"].(map[string]any)["id"].(string)

	// /compact returns 409 while running.
	e.want("POST", "/chats/"+chatID+"/compact", map[string]any{"focus": "auth"}, http.StatusConflict)

	// Finish turn in store so /compact and PATCH are allowed.
	cRow, err := e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: uuid.MustParse(chatID), WorkspaceID: e.me.WorkspaceID})
	if err != nil {
		t.Fatal(err)
	}
	if err := e.q.FinishUnfinishedChatTurns(ctx, *cRow.CurrentRunID); err != nil {
		t.Fatal(err)
	}
	if err := e.q.SetRunContextTokens(ctx, store.SetRunContextTokensParams{ID: *cRow.CurrentRunID, ContextTokens: 42000}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.SetRunState(ctx, store.SetRunStateParams{ID: *cRow.CurrentRunID, State: "waiting"}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.SetChatRunState(ctx, store.SetChatRunStateParams{ID: cRow.ID, CurrentRunID: cRow.CurrentRunID, State: "idle"}); err != nil {
		t.Fatal(err)
	}

	fetched := e.want("GET", "/chats/"+chatID, nil, http.StatusOK)
	if int64(fetched["context_tokens"].(float64)) != 42000 {
		t.Fatalf("expected context_tokens=42000, got %v (run %s)", fetched["context_tokens"], runID)
	}

	// PATCH auto_rollover_tokens: custom value, 0, and null (inherit default).
	rev := int(fetched["revision"].(float64))
	p1 := e.want("PATCH", "/chats/"+chatID, map[string]any{"revision": rev, "auto_rollover_tokens": 150000}, http.StatusOK)
	if int64(p1["auto_rollover_tokens"].(float64)) != 150000 {
		t.Fatalf("expected auto_rollover_tokens=150000, got %v", p1["auto_rollover_tokens"])
	}
	rev = int(p1["revision"].(float64))
	e.want("PATCH", "/chats/"+chatID, map[string]any{"revision": rev, "auto_rollover_tokens": -1}, http.StatusUnprocessableEntity)

	p2 := e.want("PATCH", "/chats/"+chatID, map[string]any{"revision": rev, "auto_rollover_tokens": 0}, http.StatusOK)
	if int64(p2["auto_rollover_tokens"].(float64)) != 0 {
		t.Fatalf("expected auto_rollover_tokens=0, got %v", p2["auto_rollover_tokens"])
	}
	rev = int(p2["revision"].(float64))
	p3 := e.want("PATCH", "/chats/"+chatID, map[string]any{"revision": rev, "auto_rollover_tokens": nil}, http.StatusOK)
	if _, has := p3["auto_rollover_tokens"]; has && p3["auto_rollover_tokens"] != nil {
		t.Fatalf("expected auto_rollover_tokens cleared, got %v", p3["auto_rollover_tokens"])
	}

	// POST /compact returns 200 with compact_pending=true and focus.
	comp := e.want("POST", "/chats/"+chatID+"/compact", map[string]any{"focus": "keep API compat"}, http.StatusOK)
	if comp["compact_pending"] != true || comp["compact_focus"] != "keep API compat" {
		t.Fatalf("unexpected compact response: %+v", comp)
	}

	// POST /fork creates a new chat seeded with the prefix message.
	e.want("POST", "/chats/"+chatID+"/fork", map[string]any{"message_id": firstMsgID, "branch_repo": true, "branch_name": "invalid branch"}, http.StatusUnprocessableEntity)
	forked := e.want("POST", "/chats/"+chatID+"/fork", map[string]any{"message_id": firstMsgID, "title": "My fork"}, http.StatusCreated)
	if forked["forked_from_chat_id"] != chatID || forked["forked_from_message_id"] != firstMsgID {
		t.Fatalf("unexpected fork origin metadata: %+v", forked)
	}
	forkID := forked["id"].(string)
	msgsBody := e.want("GET", "/chats/"+forkID+"/messages", nil, http.StatusOK)
	msgs := msgsBody["messages"].([]any)
	if len(msgs) != 1 || msgs[0].(map[string]any)["body_md"] != "First question" {
		t.Fatalf("expected 1 copied prefix message, got %+v", msgs)
	}
}

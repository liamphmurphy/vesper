package httpapi

import (
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestChatMessageChecklistPersistenceAndPromptNotice(t *testing.T) {
	e, _ := newAvatarEnv(t)
	chat := e.newChat(nil)
	chatID := uuid.MustParse(chat["id"].(string))
	ctx := t.Context()

	userMsg, err := e.q.AppendChatMessage(ctx, store.AppendChatMessageParams{
		SessionID: chatID, Role: "user", BodyMd: "Give me a checklist", ContextRefs: []byte("[]"), Citations: []byte("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}
	assistMsg, err := e.q.AppendChatMessage(ctx, store.AppendChatMessageParams{
		SessionID:   chatID,
		Role:        "assistant",
		BodyMd:      "Checklist:\n- [ ] Write migration\n- [ ] Add tests\n",
		ContextRefs: []byte("[]"),
		Citations:   []byte("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}

	// Reject updating a user message.
	e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+userMsg.ID.String()+"/checklist", map[string]any{"index": 0, "checked": true}, 422)

	// Toggle item 0 on, then item 1 on, then item 0 off.
	res := e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+assistMsg.ID.String()+"/checklist", map[string]any{"index": 0, "checked": true}, 200)
	state := res["checklist_state"].(map[string]any)
	if state["0"] != true {
		t.Fatalf("expected item 0 checked, got %v", state)
	}
	e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+assistMsg.ID.String()+"/checklist", map[string]any{"index": 1, "checked": true}, 200)
	res = e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+assistMsg.ID.String()+"/checklist", map[string]any{"index": 0, "checked": false}, 200)
	state = res["checklist_state"].(map[string]any)
	if state["0"] != false || state["1"] != true {
		t.Fatalf("expected 0=false, 1=true, got %v", state)
	}

	// ListChatMessages returns persisted checklist_state on the assistant message only.
	list := e.want("GET", "/chats/"+chatID.String()+"/messages", nil, 200)["messages"].([]any)
	if len(list) != 2 {
		t.Fatalf("expected 2 messages, got %d", len(list))
	}
	if _, has := list[0].(map[string]any)["checklist_state"]; has {
		t.Fatalf("user message should not have checklist_state: %v", list[0])
	}
	gotState := list[1].(map[string]any)["checklist_state"].(map[string]any)
	if gotState["0"] != false || gotState["1"] != true {
		t.Fatalf("unexpected persisted checklist_state: %v", gotState)
	}

	// ChecklistPromptNotice exposes current ticked state for continuing the chat.
	notice, err := runs.ChecklistPromptNotice(ctx, e.q, chatID)
	if err != nil {
		t.Fatal(err)
	}
	if notice == "" || !strings.Contains(notice, "- [ ] Write migration") || !strings.Contains(notice, "- [x] Add tests") {
		t.Fatalf("unexpected prompt notice: %q", notice)
	}
}

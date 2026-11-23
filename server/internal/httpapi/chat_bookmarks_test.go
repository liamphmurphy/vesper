package httpapi

import (
	"net/http"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestChatMessageBookmarkToggleAndPersistence(t *testing.T) {
	e, _ := newAvatarEnv(t)
	chat := e.newChat(nil)
	chatID := uuid.MustParse(chat["id"].(string))
	ctx := t.Context()

	userMsg, err := e.q.AppendChatMessage(ctx, store.AppendChatMessageParams{
		SessionID: chatID, Role: "user", BodyMd: "Key requirement", ContextRefs: []byte("[]"), Citations: []byte("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}
	assistMsg, err := e.q.AppendChatMessage(ctx, store.AppendChatMessageParams{
		SessionID: chatID, Role: "assistant", BodyMd: "Important decision", ContextRefs: []byte("[]"), Citations: []byte("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}
	sysMsg, err := e.q.AppendChatMessage(ctx, store.AppendChatMessageParams{
		SessionID: chatID, Role: "system", BodyMd: "Turn stopped", ContextRefs: []byte("[]"), Citations: []byte("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}

	// Reject system messages and unknown message IDs.
	e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+sysMsg.ID.String()+"/bookmark", map[string]any{"bookmarked": true}, http.StatusUnprocessableEntity)
	e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+uuid.NewString()+"/bookmark", map[string]any{"bookmarked": true}, http.StatusNotFound)

	// Bookmark both user and assistant messages.
	res := e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+assistMsg.ID.String()+"/bookmark", map[string]any{"bookmarked": true}, http.StatusOK)
	if res["bookmarked"] != true || res["bookmarked_at"] == nil {
		t.Fatalf("expected bookmarked=true with timestamp, got %v", res)
	}
	e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+userMsg.ID.String()+"/bookmark", map[string]any{"bookmarked": true}, http.StatusOK)

	// ListChatMessages exposes persisted bookmarked flag.
	list := e.want("GET", "/chats/"+chatID.String()+"/messages", nil, http.StatusOK)["messages"].([]any)
	if list[0].(map[string]any)["bookmarked"] != true || list[1].(map[string]any)["bookmarked"] != true {
		t.Fatalf("expected both messages bookmarked: %v", list)
	}

	// Unbookmark assistant message and verify cleared state.
	cleared := e.want("PATCH", "/chats/"+chatID.String()+"/messages/"+assistMsg.ID.String()+"/bookmark", map[string]any{"bookmarked": false}, http.StatusOK)
	if cleared["bookmarked"] != false || cleared["bookmarked_at"] != nil {
		t.Fatalf("expected cleared bookmark, got %v", cleared)
	}
	list = e.want("GET", "/chats/"+chatID.String()+"/messages", nil, http.StatusOK)["messages"].([]any)
	if _, has := list[1].(map[string]any)["bookmarked"]; has {
		t.Fatalf("unbookmarked message should omit bookmarked: %v", list[1])
	}
}

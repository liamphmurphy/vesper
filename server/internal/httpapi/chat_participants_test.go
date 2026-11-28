package httpapi

import (
	"net/http"
	"testing"

	"github.com/google/uuid"
)

func TestChatParticipantManagement(t *testing.T) {
	e := newChatEnv(t)

	host := e.want("POST", "/personas", map[string]any{"name": "Judy"}, http.StatusCreated)
	hostID := host["id"].(string)
	guest := e.want("POST", "/personas", map[string]any{"name": "Elminster"}, http.StatusCreated)
	guestID := guest["id"].(string)
	third := e.want("POST", "/personas", map[string]any{"name": "Iris"}, http.StatusCreated)
	thirdID := third["id"].(string)

	chat := e.newChat(map[string]any{
		"persona_id": hostID,
		"message":    map[string]any{"body": "hello"},
	})
	chatID := chat["id"].(string)

	// Add a guest participant.
	added := e.want("POST", "/chats/"+chatID+"/participants", map[string]any{"persona_id": guestID}, http.StatusOK)
	parts := added["participants"].([]any)
	if len(parts) != 2 {
		t.Fatalf("expected 2 participants, got %v", parts)
	}

	// Setting default speaker to a non-participant joins them and switches speaker.
	switched := e.want("PUT", "/chats/"+chatID+"/speaker", map[string]any{"persona_id": thirdID}, http.StatusOK)
	if sp := switched["speaker"].(map[string]any); sp["id"] != thirdID {
		t.Fatalf("expected speaker %s, got %v", thirdID, sp)
	}
	if len(switched["participants"].([]any)) != 3 {
		t.Fatalf("expected 3 participants after switching speaker, got %v", switched["participants"])
	}

	// Cannot remove host persona.
	e.want("DELETE", "/chats/"+chatID+"/participants/"+hostID, nil, http.StatusConflict)

	// Removing active speaker guest falls speaker back to host.
	removed := e.want("DELETE", "/chats/"+chatID+"/participants/"+thirdID, nil, http.StatusOK)
	if sp := removed["speaker"].(map[string]any); sp["id"] != hostID {
		t.Fatalf("expected speaker fallback to host %s, got %v", hostID, sp)
	}
	if len(removed["participants"].([]any)) != 2 {
		t.Fatalf("expected 2 participants after removing %s, got %v", thirdID, removed["participants"])
	}

	// Unknown persona returns 404.
	e.want("POST", "/chats/"+chatID+"/participants", map[string]any{"persona_id": uuid.NewString()}, http.StatusNotFound)
}

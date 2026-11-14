package httpapi

import (
	"testing"
)

// A dock keeps every chat started or picked for a place: a page's chats
// (including the one it opens on), and an app's own list. Others' chats and
// bad scopes are refused.
func TestDockChats(t *testing.T) {
	e := newChatEnv(t)
	page := e.want("POST", "/knowledge/pages", map[string]any{"title": "Harbour", "body_md": "By the sea."}, 200)
	scope := "page:" + page["id"].(string)
	first := e.newChat(nil)
	second := e.newChat(nil)
	// Attaching a chat to the page lists it; the page opens on the latest.
	e.want("PUT", "/knowledge/pages/"+page["id"].(string)+"/chat", map[string]any{"chat_id": first["id"]}, 200)
	e.want("PUT", "/knowledge/pages/"+page["id"].(string)+"/chat", map[string]any{"chat_id": second["id"]}, 200)
	if got := e.want("GET", "/knowledge/pages/"+page["id"].(string), nil, 200)["chat_id"]; got != second["id"] {
		t.Fatalf("page opens on %v", got)
	}
	list := e.want("GET", "/dock-chats?scope="+scope, nil, 200)["chats"].([]any)
	if len(list) != 2 {
		t.Fatalf("page dock chats %v", list)
	}

	e.want("POST", "/dock-chats", map[string]any{"scope": "app:knowledge", "chat_id": first["id"]}, 204)
	e.want("POST", "/dock-chats", map[string]any{"scope": "app:knowledge", "chat_id": first["id"]}, 204)
	if list := e.want("GET", "/dock-chats?scope=app:knowledge", nil, 200)["chats"].([]any); len(list) != 1 || list[0].(map[string]any)["id"] != first["id"] {
		t.Fatalf("app dock chats %v", list)
	}
	e.want("GET", "/dock-chats?scope=app:knowledge", nil, 200)
	e.want("GET", "/dock-chats?scope=page:../../x", nil, 422)
	e.want("POST", "/dock-chats", map[string]any{"scope": "app:knowledge", "chat_id": "01a1d6a1-5881-7270-9ed6-5b9d9c0b320e"}, 404)
	if list := e.want("GET", "/dock-chats?scope=app:library", nil, 200)["chats"].([]any); len(list) != 0 {
		t.Fatalf("scopes leak into each other %v", list)
	}
}

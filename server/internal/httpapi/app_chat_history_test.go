package httpapi

import (
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestAppChatsStayInTheirApps(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	persona := e.want("POST", "/personas", map[string]any{"name": "Historian"}, http.StatusCreated)["id"].(string)
	plain := e.newChat(map[string]any{"title": "apphistory normal", "persona_id": persona})["id"].(string)
	e.addReply(t, plain, "apphistory normal reply")
	knowledge := e.newChat(map[string]any{"title": "apphistory knowledge", "hidden": true, "persona_id": persona})["id"].(string)
	e.addReply(t, knowledge, "apphistory Knowledge reply")
	e.want("GET", "/chats/"+knowledge+"/messages", nil, http.StatusOK)
	for _, app := range []string{"docs", "slides", "designs"} {
		space, err := e.q.CreateAppSpace(ctx, store.CreateAppSpaceParams{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID, Name: app, Color: "blue", AppName: app})
		if err != nil {
			t.Fatal(err)
		}
		chat := e.newChat(map[string]any{"title": "apphistory " + app, "space_id": space.ID, "persona_id": persona})["id"].(string)
		e.addReply(t, chat, "apphistory app reply")
		// App screens can resume and list their conversations, including old ones.
		e.want("GET", "/chats/"+chat, nil, http.StatusOK)
		e.want("GET", "/chats/"+chat+"/messages", nil, http.StatusOK)
		inApp := ids(e.want("GET", "/chats?persona_id=all&space="+space.ID.String(), nil, http.StatusOK)["chats"], "id")
		if !slices.Contains(inApp, chat) {
			t.Fatalf("%s chat missing inside app: %v", app, inApp)
		}
	}
	for _, archived := range []bool{false, true} {
		for _, scope := range []string{"", "&space=all"} {
			path := "/chats?persona_id=all" + scope
			if archived {
				path += "&archived=true"
			}
			listed := ids(e.want("GET", path, nil, http.StatusOK)["chats"], "id")
			if len(listed) != 1 || listed[0] != plain {
				t.Fatalf("%s = %v, want only normal chat", path, listed)
			}
		}
		if !archived {
			counts, err := e.q.PersonaChatCounts(ctx, []uuid.UUID{uuid.MustParse(persona)})
			if err != nil || len(counts) != 1 || counts[0].N != 1 {
				t.Fatalf("personal chat counts = %v, %v", counts, err)
			}
			chat, err := e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: uuid.MustParse(plain), WorkspaceID: e.me.WorkspaceID})
			if err != nil {
				t.Fatal(err)
			}
			legacy, err := e.q.ListChatSessions(ctx, store.ListChatSessionsParams{WorkspaceID: e.me.WorkspaceID, ProjectID: chat.ProjectID, CreatedBy: e.me.ID, Limit: 50})
			if err != nil || len(legacy) != 1 || legacy[0].ID != chat.ID {
				t.Fatalf("project chat list = %v, %v", legacy, err)
			}
			search := e.want("GET", "/chat-search?q=apphistory", nil, http.StatusOK)["hits"].([]any)
			if len(search) != 1 || search[0].(map[string]any)["chat_id"] != plain {
				t.Fatalf("conversation search = %v", search)
			}
			for _, hit := range e.want("GET", "/search?q=apphistory", nil, http.StatusOK)["hits"].([]any) {
				row := hit.(map[string]any)["target"].(map[string]any)
				if row["kind"] == "chat" && !strings.HasPrefix(row["href"].(string), "/chat/"+plain) {
					t.Fatalf("app chat in global search: %v", row)
				}
			}
			dock, err := e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
			if err != nil || len(dock) != 1 || dock[0].ID != uuid.MustParse(plain) {
				t.Fatalf("dock = %v, %v", dock, err)
			}
			if _, err := e.pool.Exec(ctx, `UPDATE chat_sessions SET archived=true WHERE created_by=$1`, e.me.ID); err != nil {
				t.Fatal(err)
			}
		}
	}
}

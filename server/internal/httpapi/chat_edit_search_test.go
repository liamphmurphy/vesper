package httpapi

import (
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (e *chatEnv) addReply(t *testing.T, chat, body string) {
	t.Helper()
	if _, err := e.q.AppendChatMessage(t.Context(), store.AppendChatMessageParams{SessionID: uuid.MustParse(chat), Role: "assistant", BodyMd: body, ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
		t.Fatal(err)
	}
}

func TestEditLastMessageRedoesTheTurn(t *testing.T) {
	e := newChatEnv(t)
	id := e.newChat(map[string]any{"message": map[string]any{"body": "first"}})["id"].(string)
	// Not while it's running.
	e.want("POST", "/chats/"+id+"/edit-last", map[string]any{"body": "x"}, http.StatusConflict)
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	e.addReply(t, id, "An answer to first")
	e.addReply(t, id, "More of it")

	res := e.want("POST", "/chats/"+id+"/edit-last", map[string]any{"body": "edited"}, http.StatusAccepted)
	if res["chat"].(map[string]any)["state"] != "running" || res["message"].(map[string]any)["body_md"] != "edited" {
		t.Fatalf("%v", res)
	}
	msgs := e.want("GET", "/chats/"+id+"/messages", nil, 200)["messages"].([]any)
	if len(msgs) != 1 || msgs[0].(map[string]any)["body_md"] != "edited" {
		t.Fatalf("history %v", msgs)
	}
	var prompt string
	if err := e.pool.QueryRow(t.Context(), `SELECT t.input_message FROM run_turns t JOIN chat_messages m ON m.run_turn_id = t.id WHERE m.session_id = $1`, id).Scan(&prompt); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(prompt, "edited their last message") || !strings.Contains(prompt, "> first") || !strings.HasSuffix(prompt, "edited") {
		t.Fatalf("prompt %q", prompt)
	}

	e.invalid("POST", "/chats/"+id+"/edit-last", map[string]any{"body": " "}, "body", "1–100000")
	e.want("POST", "/chats/"+uuid.NewString()+"/edit-last", map[string]any{"body": "x"}, http.StatusNotFound)
}

func TestEditLastMessageRegeneratesWithEffortOverride(t *testing.T) {
	e := newChatEnv(t)
	id := e.newChat(map[string]any{"message": map[string]any{"body": "explain quicksort"}})["id"].(string)
	e.want("POST", "/chats/"+id+"/cancel", nil, 200)
	e.addReply(t, id, "First answer")

	res := e.want("POST", "/chats/"+id+"/edit-last", map[string]any{
		"body":   "explain quicksort",
		"effort": "high",
	}, http.StatusAccepted)
	chat := res["chat"].(map[string]any)
	if chat["state"] != "running" || chat["effort"] != "high" {
		t.Fatalf("expected running chat with high effort, got %v", chat)
	}
	var prompt string
	if err := e.pool.QueryRow(t.Context(), `SELECT t.input_message FROM run_turns t JOIN chat_messages m ON m.run_turn_id = t.id WHERE m.session_id = $1`, id).Scan(&prompt); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(prompt, "try your last reply again") {
		t.Fatalf("expected retry note for identical body, got %q", prompt)
	}
}

func TestChatSearchFindsOwnMessagesWithAMarkedSnippet(t *testing.T) {
	e := newChatEnv(t)
	chat := e.newChat(nil)["id"].(string)
	e.addReply(t, chat, "We compared Kokoro and Cartesia for the voice feature.")
	e.addReply(t, chat, "Something unrelated.")

	hits := e.want("GET", "/chat-search?q=kokoro", nil, 200)["hits"].([]any)
	if len(hits) != 1 {
		t.Fatalf("hits %v", hits)
	}
	h := hits[0].(map[string]any)
	if h["chat_id"] != chat || h["role"] != "assistant" || h["project_key"] == "" || !strings.Contains(h["snippet"].(string), "Kokoro") {
		t.Fatalf("hit %v", h)
	}
	if n := len(e.want("GET", "/chat-search?q=k", nil, 200)["hits"].([]any)); n != 0 {
		t.Fatalf("one letter matched %d", n)
	}
	// Another person's chat is invisible.
	var other uuid.UUID
	if err := e.pool.QueryRow(t.Context(), `INSERT INTO users (workspace_id, email, name, initials, password_hash) SELECT workspace_id, 'o@example.com', 'O', 'O', 'x' FROM users WHERE id = $1 RETURNING id`, e.me.ID).Scan(&other); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(t.Context(), `UPDATE chat_sessions SET created_by = $1 WHERE id = $2`, other, chat); err != nil {
		t.Fatal(err)
	}
	if n := len(e.want("GET", "/chat-search?q=kokoro", nil, 200)["hits"].([]any)); n != 0 {
		t.Fatalf("saw another person's chat: %d", n)
	}
}

func TestStaleLinkPreviewsAreSwept(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	for _, u := range []string{"https://old.example", "https://new.example"} {
		if _, err := e.q.UpsertLinkPreview(ctx, store.UpsertLinkPreviewParams{WorkspaceID: e.me.WorkspaceID, Url: u, Kind: "site", Title: "T", BlobKey: "k" + u}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.pool.Exec(ctx, `UPDATE link_previews SET fetched_at = now() - interval '100 days' WHERE url = 'https://old.example'`); err != nil {
		t.Fatal(err)
	}
	keys, err := e.q.DeleteStaleLinkPreviews(ctx, store.DeleteStaleLinkPreviewsParams{Before: time.Now().Add(-90 * 24 * time.Hour), RowLimit: 10})
	if err != nil || len(keys) != 1 || keys[0] != "khttps://old.example" {
		t.Fatalf("%v %v", keys, err)
	}
}

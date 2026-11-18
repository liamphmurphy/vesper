package httpapi

import (
	"net/http"
	"net/url"
	"slices"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// A document started in the Docs app is a text canvas in its own chat, kept
// out of the chat list and the Spaces menu, and found again by its id.
func TestCreateDoc(t *testing.T) {
	e := newChatEnv(t)

	doc := e.want("POST", "/docs", map[string]any{"title": "  Trip   plan "}, http.StatusCreated)
	id, chat := doc["id"].(string), doc["chat_id"].(string)
	if doc["title"] != "Trip plan" || doc["kind"] != "text" || doc["chat_title"] != "Trip plan" {
		t.Fatalf("created %v", doc)
	}
	cv := e.want("GET", "/chats/"+chat+"/canvases/"+id, nil, http.StatusOK)
	if cv["body"] != "# Trip plan\n" || cv["seq"].(float64) != 1 {
		t.Fatalf("first version %v", cv)
	}
	if got := e.want("GET", "/canvases/"+id, nil, http.StatusOK); got["chat_id"] != chat || got["title"] != "Trip plan" {
		t.Fatalf("by id %v", got)
	}
	e.want("GET", "/canvases/"+uuid.NewString(), nil, http.StatusNotFound)

	untitled := e.want("POST", "/docs", map[string]any{}, http.StatusCreated)
	if untitled["title"] != "Untitled document" {
		t.Fatalf("untitled %v", untitled)
	}
	e.invalid("POST", "/docs", map[string]any{"title": strings.Repeat("x", 201)}, "title", "200")

	// Both documents' chats share one Docs space, which stays out of the menu.
	if a, b := e.want("GET", "/chats/"+chat, nil, http.StatusOK)["space"], e.want("GET", "/chats/"+untitled["chat_id"].(string), nil, http.StatusOK)["space"]; a == nil || a.(map[string]any)["id"] != b.(map[string]any)["id"] {
		t.Fatalf("spaces %v %v", a, b)
	}
	// Only the seeded projects' spaces (they track work) are listed.
	if spaces := e.want("GET", "/chat-spaces", nil, http.StatusOK)["spaces"].([]any); len(slices.DeleteFunc(spaces, func(v any) bool { return v.(map[string]any)["work"] != nil })) != 0 {
		t.Fatalf("Spaces list %v", spaces)
	}
	for _, c := range e.want("GET", "/chats", nil, http.StatusOK)["chats"].([]any) {
		if c.(map[string]any)["id"] == chat {
			t.Fatal("a document's chat is in the chat list")
		}
	}
	listed := 0
	for _, c := range e.want("GET", "/canvases", nil, http.StatusOK)["canvases"].([]any) {
		if m := c.(map[string]any); m["id"] == id || m["id"] == untitled["id"] {
			listed++
		}
	}
	if listed != 2 {
		t.Fatalf("listed %d of 2 documents", listed)
	}
}

// The review mark only moves forward, and only to a version the document has,
// so a stale tab can't reopen a review the person already finished.
func TestMarkDocReviewed(t *testing.T) {
	e := newChatEnv(t)
	doc := e.want("POST", "/docs", map[string]any{"title": "Plan"}, http.StatusCreated)
	id, chat := doc["id"].(string), doc["chat_id"].(string)
	if got := e.want("GET", "/canvases/"+id, nil, http.StatusOK)["reviewed_seq"]; got != float64(0) {
		t.Fatalf("new document reviewed_seq %v", got)
	}
	e.want("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 1, "body": "# Plan\n\nMore.\n"}, http.StatusCreated)

	if got := e.want("POST", "/docs/"+id+"/reviewed", map[string]any{"seq": 2}, http.StatusOK)["reviewed_seq"]; got != float64(2) {
		t.Fatalf("reviewed_seq %v, want 2", got)
	}
	if got := e.want("POST", "/docs/"+id+"/reviewed", map[string]any{"seq": 1}, http.StatusOK)["reviewed_seq"]; got != float64(2) {
		t.Fatalf("moved back to %v", got)
	}
	if got := e.want("GET", "/canvases/"+id, nil, http.StatusOK)["reviewed_seq"]; got != float64(2) {
		t.Fatalf("GET reviewed_seq %v", got)
	}
	e.invalid("POST", "/docs/"+id+"/reviewed", map[string]any{"seq": 3}, "seq", "no version 3")
	e.want("POST", "/docs/"+uuid.NewString()+"/reviewed", map[string]any{"seq": 1}, http.StatusNotFound)
}

// Saving to the Library copies the text as it is now; saving the same text
// again returns that copy, and an edit makes a new one.
func TestSaveDocToLibrary(t *testing.T) {
	e, fake := newAvatarEnv(t)
	doc := e.want("POST", "/docs", map[string]any{"title": "Trip / plan"}, http.StatusCreated)
	id, chat := doc["id"].(string), doc["chat_id"].(string)

	first := e.want("POST", "/docs/"+id+"/library", nil, http.StatusCreated)
	if first["kind"] != "export" || first["title"] != "Trip / plan" || first["filename"] != "Trip plan.md" || first["chat_id"] != chat {
		t.Fatalf("saved %v", first)
	}
	if again := e.want("POST", "/docs/"+id+"/library", nil, http.StatusCreated); again["id"] != first["id"] {
		t.Fatalf("saving unchanged text made %v, want %v", again["id"], first["id"])
	}
	e.want("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 1, "body": "# Trip / plan\n\nDay one.\n"}, http.StatusCreated)
	if edited := e.want("POST", "/docs/"+id+"/library", nil, http.StatusCreated); edited["id"] == first["id"] {
		t.Fatal("an edited document reused the old copy")
	}
	var bodies []string
	for _, k := range fake.keys(avatarBucket + "/library-exports/") {
		bodies = append(bodies, string(fake.body(k)))
	}
	if len(bodies) != 2 || !slices.Contains(bodies, "# Trip / plan\n") || !slices.Contains(bodies, "# Trip / plan\n\nDay one.\n") {
		t.Fatalf("stored %q", bodies)
	}

	e.want("POST", "/docs/"+uuid.NewString()+"/library", nil, http.StatusNotFound)
}

// Promoting publishes the document as it is now, with a line saying where it
// came from; it never overwrites a page without being told to.
func TestPromoteDocToWiki(t *testing.T) {
	e := newChatEnv(t)
	word := strings.ToLower(strings.ReplaceAll(uuid.NewString(), "-", ""))[:8]
	doc := e.want("POST", "/docs", map[string]any{"title": "Rollback " + word + " / notes"}, http.StatusCreated)
	id, chat := doc["id"].(string), doc["chat_id"].(string)
	e.want("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 1, "body": "# Rollback\n\nStep one.\n"}, http.StatusCreated)

	got := e.want("POST", "/docs/"+id+"/wiki", map[string]any{}, http.StatusCreated)
	path := "Rollback " + word + " notes"
	if got["path"] != path || got["created"] != true {
		t.Fatalf("promoted %v, want a new page %q", got, path)
	}
	page := e.want("GET", "/wiki/page?path="+url.QueryEscape(path), nil, http.StatusOK)
	if body := page["body_md"].(string); !strings.HasPrefix(body, "# Rollback\n\nStep one.\n") || !strings.Contains(body, "_Promoted from the Doc “Rollback "+word+" / notes” on ") {
		t.Fatalf("page body %q", body)
	}

	// The page is a copy: a taken path is refused, and replacing is explicit.
	e.want("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 2, "body": "# Rollback\n\nStep two.\n"}, http.StatusCreated)
	if out := e.want("POST", "/docs/"+id+"/wiki", map[string]any{}, http.StatusConflict); !strings.Contains(out["message"].(string), "already exists") {
		t.Fatalf("conflict message %v", out)
	}
	if again := e.want("POST", "/docs/"+id+"/wiki", map[string]any{"replace": true}, http.StatusCreated); again["created"] != false || again["path"] != path {
		t.Fatalf("replaced %v", again)
	}
	if body := e.want("GET", "/wiki/page?path="+url.QueryEscape(path), nil, http.StatusOK)["body_md"].(string); !strings.Contains(body, "Step two.") {
		t.Fatalf("replaced body %q", body)
	}

	// A chosen path, an invalid one, and a document that isn't yours or isn't there.
	if out := e.want("POST", "/docs/"+id+"/wiki", map[string]any{"path": "Runbooks/Rollback " + word}, http.StatusCreated); out["path"] != "Runbooks/Rollback "+word {
		t.Fatalf("chosen path %v", out)
	}
	e.invalid("POST", "/docs/"+id+"/wiki", map[string]any{"path": "Bad [link]"}, "path", "[[links]]")
	e.want("POST", "/docs/"+uuid.NewString()+"/wiki", map[string]any{}, http.StatusNotFound)
}

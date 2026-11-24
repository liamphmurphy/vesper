package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/linkpreview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// fakePages stands in for spacePages: a page's text by URL.
type fakePages map[string][2]string

func (f fakePages) PageText(_ context.Context, url string) (string, string, error) {
	p, ok := f[url]
	if !ok {
		return "", "", errors.New("status 404")
	}
	if p[1] == "" {
		return p[0], "", linkpreview.ErrNoText
	}
	return p[0], p[1], nil
}

func (e *chatEnv) uploadSource(space, filename string, data []byte) (int, map[string]any) {
	e.t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	pw, err := mw.CreateFormFile("file", filename)
	if err != nil {
		e.t.Fatal(err)
	}
	pw.Write(data)
	mw.Close()
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/v1/chat-spaces/"+space+"/sources/upload", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(res.Body)
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

// A space's defaults fill in new chats, its chats stay out of the plain chat
// list, and settings edits, validation and deletion behave.
func TestChatSpacesAndTheirChats(t *testing.T) {
	e := newChatEnv(t)
	nora := e.want("POST", "/personas", map[string]any{"name": "Nora"}, http.StatusCreated)["id"].(string)

	e.invalid("POST", "/chat-spaces", map[string]any{"name": "   "}, "name", "1–80")
	e.invalid("POST", "/chat-spaces", map[string]any{"name": "X", "color": "plaid"}, "color", "must be one of")
	e.invalid("POST", "/chat-spaces", map[string]any{"name": "X", "persona_id": uuid.NewString()}, "persona_id", "unknown persona")
	e.invalid("POST", "/chat-spaces", map[string]any{"name": "X", "project": "NOPE"}, "project", "unknown project")

	sp := e.want("POST", "/chat-spaces", map[string]any{"name": "  Health ", "description": "Workouts, nutrition\nand recovery", "color": "green",
		"instructions": "Act as my coach.", "persona_id": nora, "project": "PAY"}, http.StatusCreated)
	id := sp["id"].(string)
	if sp["name"] != "Health" || sp["description"] != "Workouts, nutrition and recovery" || sp["space_memory"] != true || sp["project"] != "PAY" ||
		sp["persona_id"] != nora || len(sp["connector_ids"].([]any)) != 0 || sp["chat_count"].(float64) != 0 {
		t.Fatalf("created %v", sp)
	}

	// A chat started in the space gets its persona and project.
	chat := e.want("POST", "/chats", map[string]any{"space_id": id}, http.StatusCreated)
	if chat["project"] != "PAY" || chat["persona"].(map[string]any)["id"] != nora {
		t.Fatalf("defaults not applied: %v", chat)
	}
	ref := chat["space"].(map[string]any)
	if ref["id"] != id || ref["name"] != "Health" || ref["has_instructions"] != true || ref["space_memory"] != true || ref["color"] != "green" {
		t.Fatalf("space ref %v", ref)
	}
	// Given ones win over the space's.
	own := e.want("POST", "/chats", map[string]any{"space_id": id, "project": "PAY", "persona_id": nil}, http.StatusCreated)
	if own["space"] == nil {
		t.Fatal("not in the space")
	}
	outside := e.want("POST", "/chats", map[string]any{}, http.StatusCreated)
	e.invalid("POST", "/chats", map[string]any{"space_id": uuid.NewString()}, "space_id", "unknown space")

	// A reply gives the space's list a preview.
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO chat_messages (session_id, seq, role, body_md) VALUES ($1, 1, 'assistant', $2)`,
		chat["id"], "## Plan\n```\ncode\n```\nAim for **1.6–1.8 g/kg** while keeping it plant-based."); err != nil {
		t.Fatal(err)
	}
	inSpace := e.want("GET", "/chats?persona_id=all&space="+id, nil, http.StatusOK)["chats"].([]any)
	if got := ids(inSpace, "id"); len(got) != 2 || !slices.Contains(got, chat["id"].(string)) {
		t.Fatalf("space list %v", got)
	}
	for _, c := range inSpace {
		m := c.(map[string]any)
		if m["id"] == chat["id"] && m["preview"] != "Plan Aim for 1.6–1.8 g/kg while keeping it plant-based." {
			t.Fatalf("preview %q", m["preview"])
		}
	}
	plain := ids(e.want("GET", "/chats?persona_id=all", nil, http.StatusOK)["chats"], "id")
	if slices.Contains(plain, chat["id"].(string)) || !slices.Contains(plain, outside["id"].(string)) {
		t.Fatalf("plain list %v", plain)
	}
	every := ids(e.want("GET", "/chats?persona_id=all&space=all", nil, http.StatusOK)["chats"], "id")
	if !slices.Contains(every, chat["id"].(string)) || !slices.Contains(every, outside["id"].(string)) {
		t.Fatalf("all list %v", every)
	}
	e.invalid("GET", "/chats?space="+uuid.NewString(), nil, "space", "unknown space")

	// Settings are edited from the cards: one field at a time.
	upd := e.want("PATCH", "/chat-spaces/"+id, map[string]any{"instructions": "  Be brief.  ", "persona_id": "", "project": "", "space_memory": false}, http.StatusOK)
	if upd["instructions"] != "Be brief." || upd["persona_id"] != nil || upd["project"] != nil || upd["space_memory"] != false || upd["name"] != "Health" {
		t.Fatalf("updated %v", upd)
	}
	if upd["chat_count"].(float64) != 2 {
		t.Fatalf("chat count %v", upd["chat_count"])
	}
	e.invalid("PATCH", "/chat-spaces/"+id, map[string]any{"persona_id": "nope"}, "persona_id", "persona id")
	e.want("PATCH", "/chat-spaces/"+uuid.NewString(), map[string]any{"name": "X"}, http.StatusNotFound)
	// The seeded projects' spaces (they track work) are listed too; Health is the one without.
	if list := e.want("GET", "/chat-spaces", nil, http.StatusOK)["spaces"].([]any); len(slices.DeleteFunc(list, func(v any) bool { return v.(map[string]any)["work"] != nil })) != 1 {
		t.Fatalf("list %v", list)
	}

	// Deleting the space keeps its chats, now outside any space.
	e.want("DELETE", "/chat-spaces/"+id, nil, http.StatusNoContent)
	e.want("GET", "/chat-spaces/"+id, nil, http.StatusNotFound)
	back := e.want("GET", "/chats/"+chat["id"].(string), nil, http.StatusOK)
	if back["space"] != nil {
		t.Fatalf("chat still in a deleted space: %v", back["space"])
	}
}

// Sources: pasted text, a page, a canvas, Library items and uploads become
// snapshots; long ones are searched; files keep their bytes in the bucket.
func TestChatSpaceSources(t *testing.T) {
	e, fake := newAvatarEnv(t)
	old := spacePages
	spacePages = fakePages{
		"https://examine.com/creatine": {"Creatine", strings.Repeat("Creatine works. ", 6000)},
		"https://example.com/empty":    {"Empty", ""},
		"https://example.com/saved":    {"Saved page", "The saved page's text."},
	}
	t.Cleanup(func() { spacePages = old })
	id := e.want("POST", "/chat-spaces", map[string]any{"name": "Health"}, http.StatusCreated)["id"].(string)
	base := "/chat-spaces/" + id + "/sources"

	text := e.want("POST", base, map[string]any{"kind": "text", "text": "# Meal ideas\nTofu bowls, lentil soup."}, http.StatusCreated)
	if text["title"] != "Meal ideas" || text["tokens"].(float64) < 5 || text["delivery"] != "inline" {
		t.Fatalf("text %v", text)
	}
	e.invalid("POST", base, map[string]any{"kind": "text", "text": "   "}, "text", "empty")
	site := e.want("POST", base, map[string]any{"kind": "website", "url": "https://examine.com/creatine"}, http.StatusCreated)
	if site["title"] != "Creatine" || site["url"] != "https://examine.com/creatine" || site["delivery"] != "searched" {
		t.Fatalf("site %v", site)
	}
	e.invalid("POST", base, map[string]any{"kind": "website", "url": "http://10.0.0.1/"}, "url", "")
	e.invalid("POST", base, map[string]any{"kind": "website", "url": "https://example.com/empty"}, "url", "no text")
	e.invalid("POST", base, map[string]any{"kind": "website", "url": "https://example.com/missing"}, "url", "couldn’t read")

	// A canvas from one of the person's chats.
	chat := e.newChat(nil)
	ctx := context.Background()
	cv, err := e.q.CreateChatCanvas(ctx, store.CreateChatCanvasParams{SessionID: uuid.MustParse(chat["id"].(string)), Kind: "text", Title: "Training plan"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.CreateChatCanvasVersion(ctx, store.CreateChatCanvasVersionParams{CanvasID: cv.ID, Seq: 1, Body: "Mon: lift", AuthorType: "user", AuthorID: e.me.ID}); err != nil {
		t.Fatal(err)
	}
	if got := e.want("GET", "/canvases", nil, http.StatusOK)["canvases"].([]any); len(got) != 1 || got[0].(map[string]any)["chat_title"] == nil {
		t.Fatalf("canvases %v", got)
	}
	canvas := e.want("POST", base, map[string]any{"kind": "canvas", "canvas_id": cv.ID}, http.StatusCreated)
	if canvas["title"] != "Training plan" || canvas["kind"] != "canvas" {
		t.Fatalf("canvas %v", canvas)
	}
	e.invalid("POST", base, map[string]any{"kind": "canvas", "canvas_id": uuid.NewString()}, "canvas_id", "unknown canvas")

	// A saved link is read from its page.
	link, err := e.q.CreateLibraryLink(ctx, store.CreateLibraryLinkParams{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID, Title: "Saved", Url: "https://example.com/saved", ContentType: "text/uri-list", BlobKey: "link-key"})
	if err != nil {
		t.Fatal(err)
	}
	saved := e.want("POST", base, map[string]any{"kind": "link", "item_id": link.ID}, http.StatusCreated)
	if saved["title"] != "Saved page" || saved["url"] != "https://example.com/saved" {
		t.Fatalf("saved link %v", saved)
	}

	// Uploads: text is kept as text, an image's bytes go to the bucket.
	code, md := e.uploadSource(id, "Plan.md", []byte("# Plan\nLift three days."))
	if code != http.StatusCreated || md["kind"] != "file" || md["filename"] != "Plan.md" || md["tokens"].(float64) == 0 {
		t.Fatalf("md upload %d %v", code, md)
	}
	var img bytes.Buffer
	if err := png.Encode(&img, avatarImage(4, 4)); err != nil {
		t.Fatal(err)
	}
	code, pic := e.uploadSource(id, "scan.png", img.Bytes())
	if code != http.StatusCreated || pic["tokens"].(float64) != 0 || pic["delivery"] != "inline" {
		t.Fatalf("png upload %d %v", code, pic)
	}
	if keys := fake.keys(avatarBucket + "/chat-spaces/"); len(keys) != 1 {
		t.Fatalf("stored %v", keys)
	}
	if code, out := e.uploadSource(id, "run.exe", []byte("MZ")); code != http.StatusUnprocessableEntity {
		t.Fatalf("exe upload %d %v", code, out)
	}

	list := e.want("GET", base, nil, http.StatusOK)
	if n := len(list["sources"].([]any)); n != 6 || list["inline_budget"].(float64) != 40000 {
		t.Fatalf("list %v", list)
	}
	if sp := e.want("GET", "/chat-spaces/"+id, nil, http.StatusOK); sp["source_count"].(float64) != 6 || sp["inline_tokens"].(float64) != list["inline_tokens"].(float64) {
		t.Fatalf("space %v", sp)
	}

	// Removing a file source removes its bytes; another person's space is a 404.
	e.want("DELETE", base+"/"+pic["id"].(string), nil, http.StatusNoContent)
	if keys := fake.keys(avatarBucket + "/chat-spaces/"); len(keys) != 0 {
		t.Fatalf("left %v", keys)
	}
	e.want("DELETE", base+"/"+pic["id"].(string), nil, http.StatusNotFound)
	e.want("GET", "/chat-spaces/"+uuid.NewString()+"/sources", nil, http.StatusNotFound)
}

// The memory manager names a space's entries and can keep to one space.
func TestMemoriesBySpace(t *testing.T) {
	e := newChatEnv(t)
	id := e.want("POST", "/chat-spaces", map[string]any{"name": "Novel"}, http.StatusCreated)["id"].(string)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO memories (workspace_id, user_id, space_id, title) VALUES ($1, $2, $3, 'Second act twist'), ($1, $2, NULL, 'Prefers metric')`,
		e.me.WorkspaceID, e.me.ID, id); err != nil {
		t.Fatal(err)
	}
	got := e.want("GET", "/memories?space_id="+id, nil, http.StatusOK)
	ms := got["memories"].([]any)
	if len(ms) != 1 || ms[0].(map[string]any)["space_name"] != "Novel" || ms[0].(map[string]any)["space_id"] != id {
		t.Fatalf("space memories %v", got)
	}
	if sp := e.want("GET", "/chat-spaces/"+id, nil, http.StatusOK); sp["memory_count"].(float64) != 1 {
		t.Fatalf("memory count %v", sp["memory_count"])
	}
	e.invalid("GET", "/memories?space_id="+uuid.NewString(), nil, "space_id", "unknown space")
}

// Listing a space's chats (or all spaces) without persona_id returns chats from
// every persona even after switching the default persona; explicit persona_id
// still filters, and plain GET /chats keeps defaulting to the default persona.
func TestListSpaceChatsIgnoresDefaultPersona(t *testing.T) {
	e := newChatEnv(t)
	alice := e.want("POST", "/personas", map[string]any{"name": "Alice", "is_default": true}, http.StatusCreated)["id"].(string)
	bob := e.want("POST", "/personas", map[string]any{"name": "Bob"}, http.StatusCreated)["id"].(string)
	carol := e.want("POST", "/personas", map[string]any{"name": "Carol"}, http.StatusCreated)["id"].(string)
	spaceID := e.want("POST", "/chat-spaces", map[string]any{"name": "Vesper"}, http.StatusCreated)["id"].(string)

	inSpaceAlice := e.want("POST", "/chats", map[string]any{"space_id": spaceID, "persona_id": alice}, http.StatusCreated)["id"].(string)
	inSpaceCarol := e.want("POST", "/chats", map[string]any{"space_id": spaceID, "persona_id": carol}, http.StatusCreated)["id"].(string)
	plainAlice := e.want("POST", "/chats", map[string]any{"persona_id": alice}, http.StatusCreated)["id"].(string)
	plainBob := e.want("POST", "/chats", map[string]any{"persona_id": bob}, http.StatusCreated)["id"].(string)

	// Switch the default persona to Bob, who has zero chats in the space.
	e.want("POST", "/personas/"+bob+"/default", nil, http.StatusOK)

	// Omitting persona_id for a specific space still returns all of its chats.
	inSpace := ids(e.want("GET", "/chats?space="+spaceID, nil, http.StatusOK)["chats"], "id")
	if len(inSpace) != 2 || !slices.Contains(inSpace, inSpaceAlice) || !slices.Contains(inSpace, inSpaceCarol) {
		t.Fatalf("GET /chats?space=%s = %v, want [%s %s]", spaceID, inSpace, inSpaceAlice, inSpaceCarol)
	}

	// Omitting persona_id for space=all returns chats across every persona.
	allSpaces := ids(e.want("GET", "/chats?space=all", nil, http.StatusOK)["chats"], "id")
	for _, want := range []string{inSpaceAlice, inSpaceCarol, plainAlice, plainBob} {
		if !slices.Contains(allSpaces, want) {
			t.Fatalf("GET /chats?space=all missing %s in %v", want, allSpaces)
		}
	}

	// Explicit persona_id inside a space still filters to that persona.
	onlyAlice := ids(e.want("GET", "/chats?space="+spaceID+"&persona_id="+alice, nil, http.StatusOK)["chats"], "id")
	if len(onlyAlice) != 1 || onlyAlice[0] != inSpaceAlice {
		t.Fatalf("GET /chats?space=%s&persona_id=%s = %v, want [%s]", spaceID, alice, onlyAlice, inSpaceAlice)
	}
	onlyBob := ids(e.want("GET", "/chats?space="+spaceID+"&persona_id="+bob, nil, http.StatusOK)["chats"], "id")
	if len(onlyBob) != 0 {
		t.Fatalf("GET /chats?space=%s&persona_id=%s = %v, want empty", spaceID, bob, onlyBob)
	}

	// Plain GET /chats (outside spaces) still defaults to the current default persona.
	plain := ids(e.want("GET", "/chats", nil, http.StatusOK)["chats"], "id")
	if len(plain) != 1 || plain[0] != plainBob {
		t.Fatalf("GET /chats = %v, want only default persona's chat [%s]", plain, plainBob)
	}
}

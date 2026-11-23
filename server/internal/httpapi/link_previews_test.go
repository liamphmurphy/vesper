package httpapi

import (
	"context"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/linkpreview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type fakePreviews struct {
	calls atomic.Int32
	empty atomic.Bool
}

func (f *fakePreviews) Fetch(_ context.Context, url string) linkpreview.Preview {
	f.calls.Add(1)
	if f.empty.Load() {
		return linkpreview.Preview{Kind: linkpreview.KindSite}
	}
	if strings.Contains(url, "youtu") {
		return linkpreview.Preview{Kind: linkpreview.KindVideo, Title: "A talk", Site: "Lab", VideoID: "dQw4w9WgXcQ"}
	}
	if strings.HasSuffix(url, ".png") || strings.HasSuffix(url, ".jpg") {
		return linkpreview.Preview{Kind: linkpreview.KindImage, Site: "cdn.example", Image: []byte("\x89PNG\r\n\x1a\nbytes"), ImageType: "image/png"}
	}
	return linkpreview.Preview{Kind: linkpreview.KindSite, Title: "Routes", Description: "Quiet", Image: []byte("\x89PNG\r\n\x1a\nbytes"), ImageType: "image/png"}
}

func usePreviews(t *testing.T) *fakePreviews {
	t.Helper()
	old := linkPreviews
	f := &fakePreviews{}
	linkPreviews = f
	t.Cleanup(func() { linkPreviews = old })
	return f
}

func (e *chatEnv) previewMessage(t *testing.T, role, body string) string {
	t.Helper()
	chat := uuid.MustParse(e.newChat(nil)["id"].(string))
	m, err := e.q.AppendChatMessage(t.Context(), store.AppendChatMessageParams{SessionID: chat, Role: role, BodyMd: body, ContextRefs: []byte("[]"), Citations: []byte("[]")})
	if err != nil {
		t.Fatal(err)
	}
	return m.ID.String()
}

const recommendReply = "Try:\n\n```recommend\nhttps://a.example/x\nWorth it.\n```\n\n```recommend\nhttps://youtu.be/dQw4w9WgXcQ\n```\n"

func TestLinkPreviewsFetchOnceAndServeTheImage(t *testing.T) {
	e, _ := newAvatarEnv(t)
	f := usePreviews(t)
	id := e.previewMessage(t, "assistant", recommendReply)

	got := e.want("GET", "/chat-messages/"+id+"/link-previews", nil, 200)["previews"].([]any)
	if len(got) != 2 {
		t.Fatalf("previews %v", got)
	}
	site, video := got[0].(map[string]any), got[1].(map[string]any)
	if site["url"] != "https://a.example/x" || site["kind"] != "site" || site["title"] != "Routes" || site["image_url"] == nil {
		t.Fatalf("site %v", site)
	}
	if video["kind"] != "video" || video["video_id"] != "dQw4w9WgXcQ" || video["image_url"] != nil {
		t.Fatalf("video %v", video)
	}

	e.want("GET", "/chat-messages/"+id+"/link-previews", nil, 200)
	if n := f.calls.Load(); n != 2 {
		t.Fatalf("fetched %d times", n)
	}

	res, err := http.Get(e.srv.URL + site["image_url"].(string))
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 || !strings.HasPrefix(string(body), "\x89PNG") || res.Header.Get("Content-Type") != "image/png" || res.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("image %d %v", res.StatusCode, res.Header)
	}
}

func TestLinkPreviewFailureIsCachedThenRetried(t *testing.T) {
	e, _ := newAvatarEnv(t)
	f := usePreviews(t)
	f.empty.Store(true)
	id := e.previewMessage(t, "assistant", "```recommend\nhttps://a.example/x\n```")
	path := "/chat-messages/" + id + "/link-previews"

	got := e.want("GET", path, nil, 200)["previews"].([]any)
	if got[0].(map[string]any)["title"] != "" {
		t.Fatalf("%v", got)
	}
	e.want("GET", path, nil, 200)
	if n := f.calls.Load(); n != 1 {
		t.Fatalf("fetched %d times", n)
	}
	f.empty.Store(false)
	if _, err := e.pool.Exec(t.Context(), `UPDATE link_previews SET fetched_at = now() - interval '2 days'`); err != nil {
		t.Fatal(err)
	}
	got = e.want("GET", path, nil, 200)["previews"].([]any)
	if got[0].(map[string]any)["title"] != "Routes" {
		t.Fatalf("%v", got)
	}
}

func TestLinkPreviewsOnlyReadAssistantFencesInYourChats(t *testing.T) {
	e, _ := newAvatarEnv(t)
	f := usePreviews(t)
	mine := e.previewMessage(t, "user", recommendReply)
	if got := e.want("GET", "/chat-messages/"+mine+"/link-previews", nil, 200)["previews"].([]any); len(got) != 0 {
		t.Fatalf("%v", got)
	}
	e.want("GET", "/chat-messages/"+uuid.NewString()+"/link-previews", nil, http.StatusNotFound)
	e.want("GET", "/link-previews/"+uuid.NewString()+"/image", nil, http.StatusNotFound)
	if n := f.calls.Load(); n != 0 {
		t.Fatalf("fetched %d times", n)
	}
}

// A saved link keeps its own image, is listed under its kind, and shows as
// saved on the card until it's removed.
func TestLibraryLinksSaveListAndRemove(t *testing.T) {
	e, s3 := newAvatarEnv(t)
	usePreviews(t)
	id := e.previewMessage(t, "assistant", recommendReply)
	save := map[string]any{"message_id": id, "url": "https://a.example/x"}
	first := e.want("POST", "/library/links", save, http.StatusCreated)
	again := e.want("POST", "/library/links", save, http.StatusCreated)
	if first["id"] != again["id"] || first["kind"] != "link" || first["title"] != "Routes" || first["note"] != "Worth it." {
		t.Fatalf("saved %v then %v", first, again)
	}

	item := e.want("GET", "/library?kind=link", nil, 200)["items"].([]any)[0].(map[string]any)
	if item["url"] != "https://a.example/x" || item["chat_id"] == nil {
		t.Fatalf("item %v", item)
	}
	if n := len(e.want("GET", "/library?kind=image", nil, 200)["items"].([]any)); n != 0 {
		t.Fatalf("%d images", n)
	}
	res, err := http.Get(e.srv.URL + "/api/v1/library/" + item["id"].(string) + "/content")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("content %d %v", res.StatusCode, res.Header)
	}

	isSaved := func() bool {
		return e.want("GET", "/chat-messages/"+id+"/link-previews", nil, 200)["previews"].([]any)[0].(map[string]any)["saved"].(bool)
	}
	if !isSaved() {
		t.Fatal("not marked saved")
	}
	e.want("DELETE", "/library/"+item["id"].(string), nil, http.StatusNoContent)
	if isSaved() {
		t.Fatal("still marked saved")
	}
	// The card's cached image survives the Library copy going away.
	if len(s3.keys(avatarBucket+"/"+linkPreviewKey(e.me.WorkspaceID, "https://a.example/x"))) != 1 {
		t.Fatal("removing the link deleted the preview image")
	}
}

func TestLibraryLinkWithoutImageSavesAndRemoves(t *testing.T) {
	e, _ := newAvatarEnv(t)
	f := usePreviews(t)
	f.empty.Store(true)
	id := e.previewMessage(t, "assistant", "```recommend\nhttps://www.a.example/notes/\nGood.\n```")
	got := e.want("POST", "/library/links", map[string]any{"message_id": id, "url": "https://www.a.example/notes/"}, http.StatusCreated)
	if got["title"] != "a.example/notes" || got["size_bytes"] != float64(0) {
		t.Fatalf("%v", got)
	}
	e.want("GET", "/library/"+got["id"].(string)+"/content", nil, http.StatusNotFound)
	e.want("DELETE", "/library/"+got["id"].(string), nil, http.StatusNoContent)
}

func TestLibraryLinkMustBeRecommendedByTheReply(t *testing.T) {
	e, _ := newAvatarEnv(t)
	f := usePreviews(t)
	id := e.previewMessage(t, "assistant", recommendReply)
	e.invalid("POST", "/library/links", map[string]any{"message_id": id, "url": "https://elsewhere.example"}, "url", "doesn't recommend")
	mine := e.previewMessage(t, "user", recommendReply)
	e.invalid("POST", "/library/links", map[string]any{"message_id": mine, "url": "https://a.example/x"}, "message_id", "assistant")
	e.want("POST", "/library/links", map[string]any{"message_id": uuid.NewString(), "url": "https://a.example/x"}, http.StatusNotFound)
	if n := f.calls.Load(); n != 0 {
		t.Fatalf("fetched %d times", n)
	}
}

func TestLibraryLinkQueueAndSummary(t *testing.T) {
	e, _ := newAvatarEnv(t)
	usePreviews(t)
	chat := uuid.MustParse(e.newChat(nil)["id"].(string))
	add := func(role, body string) string {
		m, err := e.q.AppendChatMessage(t.Context(), store.AppendChatMessageParams{SessionID: chat, Role: role, BodyMd: body, ContextRefs: []byte("[]"), Citations: []byte("[]")})
		if err != nil {
			t.Fatal(err)
		}
		return m.ID.String()
	}
	add("assistant", "```recommend\nhttps://a.example/x\nWorth it.\n```")
	plain := add("assistant", "Unrelated.")
	add("user", "Summarize this page: [Routes](https://a.example/x)")
	reply := add("assistant", "It says three things.")

	e.invalid("POST", "/library/links/summary", map[string]any{"message_id": plain, "url": "https://a.example/x"}, "message_id", "isn't a summary")
	e.invalid("POST", "/library/links/summary", map[string]any{"message_id": reply, "url": "https://elsewhere.example"}, "message_id", "isn't a summary")

	// Saves the link too, when it isn't in the Library yet.
	got := e.want("POST", "/library/links/summary", map[string]any{"message_id": reply, "url": "https://a.example/x"}, http.StatusCreated)
	if got["summary"] != "It says three things." || got["link_status"] != "to_read" || got["note"] != "Worth it." {
		t.Fatalf("%v", got)
	}
	id := got["id"].(string)
	e.want("PUT", "/library/"+id+"/link-status", map[string]any{"status": "done"}, http.StatusNoContent)
	item := e.want("GET", "/library?kind=link", nil, 200)["items"].([]any)[0].(map[string]any)
	if item["link_status"] != "done" || item["summary"] != "It says three things." {
		t.Fatalf("%v", item)
	}
	e.want("PUT", "/library/"+uuid.NewString()+"/link-status", map[string]any{"status": "done"}, http.StatusNotFound)
	if code, _ := e.do("PUT", "/library/"+id+"/link-status", map[string]any{"status": "nope"}); code == http.StatusNoContent {
		t.Fatal("accepted a bad status")
	}
}

func TestLinkPreviewsServeGalleryProductAndCitedSources(t *testing.T) {
	e, _ := newAvatarEnv(t)
	f := usePreviews(t)
	body := strings.Join([]string{
		"```gallery",
		`{"title":"Stills","items":[{"image":"https://cdn.example/hero.png","url":"https://article.example/post","caption":"Hero shot"}]}`,
		"```",
		"```product",
		`{"title":"Picks","items":[{"name":"Lamp","url":"https://shop.example/lamp","image":"https://cdn.example/lamp.jpg","price":"$79"}]}`,
		"```",
		"",
		"Sources:",
		"1. [Review](https://review.example/lamp)",
	}, "\n")
	id := e.previewMessage(t, "assistant", body)
	got := e.want("GET", "/chat-messages/"+id+"/link-previews", nil, 200)["previews"].([]any)
	if len(got) != 5 {
		t.Fatalf("expected 5 previews, got %d: %v", len(got), got)
	}
	first := got[0].(map[string]any)
	if first["kind"] != "image" || first["image_url"] == nil {
		t.Fatalf("expected proxied image preview, got %v", first)
	}
	// Cached image is not refetched on subsequent calls.
	e.want("GET", "/chat-messages/"+id+"/link-previews", nil, 200)
	if n := f.calls.Load(); n != 5 {
		t.Fatalf("expected 5 fetches total, got %d", n)
	}
	// Product page can be saved to Library directly.
	saved := e.want("POST", "/library/links", map[string]any{"message_id": id, "url": "https://shop.example/lamp"}, http.StatusCreated)
	if saved["url"] != "https://shop.example/lamp" || saved["note"] != "Lamp" {
		t.Fatalf("unexpected saved product link: %v", saved)
	}
}

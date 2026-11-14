package httpapi

import (
	"encoding/base64"
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// A persona in the person's chat can do what the Knowledge app does, under
// the page's persona controls: deletes and filing apply only on direct pages,
// restores and edits follow the controls, and review decisions and controls
// only go the cautious way.
func TestPersonaKnowledgeTools(t *testing.T) {
	objects := &memObjects{}
	e := newChatEnvServer(t, nil, func(s *Server) { s.Wiki.Objects = objects })
	chat := e.newChat(nil)
	chatID := uuid.MustParse(chat["id"].(string))
	token := e.canvasToken(chatID)
	page := func(title, path, body string) map[string]any {
		return e.want("POST", "/knowledge/pages", map[string]any{"title": title, "path": path, "body_md": body}, 200)
	}
	get := func(p map[string]any) map[string]any {
		return e.want("GET", "/knowledge/pages/"+p["id"].(string), nil, 200)
	}
	controls := func(p map[string]any, direct, paused bool) {
		e.want("PUT", "/knowledge/pages/"+p["id"].(string)+"/controls", map[string]any{"direct": direct, "paused": paused}, 200)
	}
	call := func(tool string, args map[string]any) (int, map[string]any) { return e.tool(token, tool, args) }
	mustCall := func(tool string, args map[string]any) map[string]any {
		t.Helper()
		code, out := call(tool, args)
		if code != 200 {
			t.Fatalf("%s %d %v", tool, code, out)
		}
		return out
	}

	// Delete follows page controls.
	{
		keep := page("Keep", "Drafts/Keep", "Reviewed first.")
		gone := page("Gone", "Drafts/Gone", "Old.")
		controls(keep, false, false)
		if code, out := call("delete_page", map[string]any{"ref": keep["id"]}); code != 409 || !strings.Contains(fmt.Sprint(out["message"]), "can't be deleted") {
			t.Fatalf("deleted a review-first page: %d %v", code, out)
		}
		// One review-first page keeps the whole folder.
		if code, _ := call("delete_folder", map[string]any{"folder": "Drafts"}); code != 409 {
			t.Fatalf("deleted a folder holding a review-first page: %d", code)
		}
		get(gone)
		mustCall("delete_page", map[string]any{"ref": "Drafts/Gone"})
		e.want("GET", "/knowledge/pages/"+gone["id"].(string), nil, 404)
		controls(keep, true, false)
		if out := mustCall("delete_folder", map[string]any{"folder": "Drafts"}); out["deleted"] != float64(1) {
			t.Fatalf("delete_folder %v", out)
		}
		if code, _ := call("delete_folder", map[string]any{"folder": "agents"}); code != 422 {
			t.Fatalf("persona reached agent knowledge: %d", code)
		}
	}

	// Versions and restore.
	{
		p := page("Harbour", "Places/Harbour", "First draft.")
		first := p["version_id"].(string)
		e.want("PUT", "/knowledge/pages/"+p["id"].(string), map[string]any{"body_md": "Second draft."}, 200)
		versions := mustCall("list_page_versions", map[string]any{"ref": p["id"]})
		if list := versions["versions"].([]any); len(list) != 2 || list[1].(map[string]any)["version_id"] != first {
			t.Fatalf("versions %v", versions)
		}
		cur := get(p)["version_id"]
		if code, _ := call("restore_page_version", map[string]any{"ref": p["id"], "version_id": first, "base_version": first}); code != 409 {
			t.Fatalf("restore against a stale base: %d", code)
		}
		if out := mustCall("restore_page_version", map[string]any{"ref": p["id"], "version_id": first, "base_version": cur}); out["state"] != "published" {
			t.Fatalf("restore on a direct page %v", out)
		}
		if body := get(p)["body_md"]; body != "First draft." {
			t.Fatalf("restored body %q", body)
		}
	}

	// File captures.
	{
		capture := e.want("POST", "/knowledge/capture", map[string]any{"title": "Ferry", "body_md": "Arrives at dawn."}, 200)
		target := page("Travel", "Notes/Travel", "# Travel")
		if code, _ := call("file_capture", map[string]any{"ref": capture["id"]}); code != 422 {
			t.Fatal("filed with neither folder nor merge")
		}
		mustCall("file_capture", map[string]any{"ref": capture["id"], "merge": target["id"]})
		if body := get(target)["body_md"].(string); !strings.Contains(body, "Arrives at dawn.") {
			t.Fatalf("merged body %q", body)
		}
		e.want("GET", "/knowledge/pages/"+capture["id"].(string), nil, 404)
		other := e.want("POST", "/knowledge/capture", map[string]any{"title": "Tide", "body_md": "High at noon."}, 200)
		if out := mustCall("file_capture", map[string]any{"ref": other["id"], "folder": "Notes"}); !strings.HasPrefix(out["path"].(string), "Notes/") {
			t.Fatalf("filed path %v", out)
		}
	}

	// Attach a file.
	{
		svg := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>`
		out := mustCall("attach_file", map[string]any{"data": base64.StdEncoding.EncodeToString([]byte(svg)), "filename": "map.svg"})
		embed := out["embed"].(string)
		if !strings.HasPrefix(embed, "![[attachment:") || out["content_type"] != "image/svg+xml" {
			t.Fatalf("attach %v", out)
		}
		objects.mu.Lock()
		stored := 0
		for key, b := range objects.data {
			if strings.Contains(key, "knowledge-assets/") && string(b) == svg {
				stored++
			}
		}
		objects.mu.Unlock()
		if stored != 1 {
			t.Fatalf("asset not stored once: %d", stored)
		}
		if code, _ := call("attach_file", map[string]any{"data": "!!!", "filename": "x.png"}); code != 422 {
			t.Fatal("accepted invalid base64")
		}
	}

	// Reviews and controls only go the cautious way.
	{
		p := page("Ledger", "Notes/Ledger", "Line one.")
		controls(p, false, false)
		patch := mustCall("patch_page", map[string]any{"ref": p["id"], "base_version": p["version_id"], "changes": []any{map[string]any{"before": "Line one.", "after": "Line 1.", "why": "Digits"}}})
		if patch["state"] != "suggested" {
			t.Fatalf("patch on review-first page %v", patch)
		}
		reviews := mustCall("list_page_reviews", map[string]any{"ref": p["id"]})["reviews"].([]any)
		if len(reviews) != 1 || reviews[0].(map[string]any)["yours"] != true {
			t.Fatalf("reviews %v", reviews)
		}
		mustCall("withdraw_suggestion", map[string]any{"ref": p["id"], "version_id": reviews[0].(map[string]any)["version_id"]})
		if left := get(p)["reviews"].([]any); len(left) != 0 || get(p)["body_md"] != "Line one." {
			t.Fatalf("withdrawn suggestion still waits %v", left)
		}
		if code, _ := call("set_page_controls", map[string]any{"ref": p["id"]}); code != 422 {
			t.Fatal("set_page_controls loosened or did nothing")
		}
		if out := mustCall("set_page_controls", map[string]any{"ref": p["id"], "pause": true}); out["paused"] != true || out["direct"] != false {
			t.Fatalf("pause %v", out)
		}
		if code, _ := call("patch_page", map[string]any{"ref": p["id"], "base_version": get(p)["version_id"], "changes": []any{map[string]any{"before": "Line one.", "after": "x", "why": "y"}}}); code != 409 {
			t.Fatalf("patched a paused page: %d", code)
		}
	}

	// Chat, canvas and graph.
	{
		a := page("Anchor", "Graph/Anchor", "See [[Graph/Buoy]] and [[Nowhere]].")
		page("Buoy", "Graph/Buoy", "Floats.")
		mustCall("attach_chat_to_page", map[string]any{"ref": a["id"]})
		if got := get(a)["chat_id"]; got != chatID.String() {
			t.Fatalf("page chat %v", got)
		}
		graph := mustCall("knowledge_graph", map[string]any{"folder": "Graph"})
		if len(graph["pages"].([]any)) != 2 || len(graph["links"].([]any)) != 2 {
			t.Fatalf("graph %v", graph)
		}
		canvas := mustCall("canvas_create", map[string]any{"kind": "text", "title": "Draft plan", "body": "Steps."})
		promoted := mustCall("promote_canvas", map[string]any{"canvas_id": canvas["canvas_id"], "folder": "Plans"})
		if !strings.HasPrefix(promoted["path"].(string), "Plans/") {
			t.Fatalf("promoted %v", promoted)
		}
	}

	// Imports.
	{
		if out := mustCall("list_imports", map[string]any{}); len(out["imports"].([]any)) != 0 {
			t.Fatalf("imports %v", out)
		}
		if code, _ := call("confirm_import", map[string]any{"import_id": uuid.NewString(), "policy": "skip"}); code != 404 {
			t.Fatalf("confirmed a missing import: %d", code)
		}
		if code, _ := call("confirm_import", map[string]any{"import_id": uuid.NewString(), "policy": "everything"}); code != 422 {
			t.Fatalf("accepted an unknown policy: %d", code)
		}
	}
	// A deck's page has no text of its own: read_page and patch_page say where the deck is.
	{
		deck := e.want("POST", "/slides", map[string]any{"title": "Board deck"}, http.StatusCreated)
		ref := e.want("GET", "/wiki/canvas-pages/"+deck["id"].(string), nil, 200)
		code, out := call("read_page", map[string]any{"ref": ref["id"]})
		if code != 422 || !strings.Contains(fmt.Sprint(out["message"]), "slide deck") || !strings.Contains(fmt.Sprint(out["message"]), deck["id"].(string)) {
			t.Fatalf("read_page on a deck's page: %d %v", code, out)
		}
		p := get(ref)
		if code, out := call("patch_page", map[string]any{"ref": ref["id"], "base_version": p["version_id"], "changes": []any{map[string]any{"before": "x", "after": "y", "why": "z"}}}); code != 422 || !strings.Contains(fmt.Sprint(out["message"]), "canvas_read") {
			t.Fatalf("patch_page on a deck's page: %d %v", code, out)
		}
	}
}

package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/designs"
)

// A non-coding persona can render PDFs by default (no opt-in), preview before
// saving, save to Library with detail and GET /library/{itemId}, and place them
// into Knowledge directly (attach_to_knowledge) or later (attach_file library_item_id)
// or via ![[library:<id>]].
func TestRenderPDFToolAndKnowledgePlacement(t *testing.T) {
	fakePDF := []byte("%PDF-1.4\n1 0 obj\n<< /Type /Page >>\nendobj\n2 0 obj\n<< /Type /Page >>\nendobj\n%%EOF\n")
	fakePNG := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}

	var workerStatus = http.StatusOK
	var workerMsg string
	var lastReq map[string]any
	workerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/internal/designs/pdf" || r.Method != http.MethodPost {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		if r.Header.Get("Authorization") != "Bearer pdf-tok" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		_ = json.NewDecoder(r.Body).Decode(&lastReq)
		if workerStatus != http.StatusOK {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(workerStatus)
			_ = json.NewEncoder(w).Encode(map[string]string{"message": workerMsg})
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"pdf_base64": base64.StdEncoding.EncodeToString(fakePDF),
			"pages":      2,
			"page_size":  "Letter",
			"previews": []map[string]any{
				{"page": 1, "width": 850, "height": 1100, "png_base64": base64.StdEncoding.EncodeToString(fakePNG)},
			},
		})
	}))
	defer workerSrv.Close()

	blobs := newFakeBlobs(t).Store
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = blobs
		s.ArtifactBucket = avatarBucket
		s.DesignWorker = &designs.Worker{URL: workerSrv.URL + "/internal/designs", Token: "pdf-tok", Backoff: 1}
		s.Wiki.Objects = blobs
		s.Wiki.Artifacts.Bucket = avatarBucket
	})

	// Create a non-coding persona explicitly (code=false) to prove render_pdf works by default.
	persona := e.want("POST", "/personas", map[string]any{
		"name": "Writer", "tone": "friendly", "color": "#4f6d7a", "capabilities": map[string]any{"code": false},
	}, http.StatusCreated)
	chatObj := e.newChat(map[string]any{"persona_id": persona["id"]})
	chat := uuid.MustParse(chatObj["id"].(string))
	token := e.canvasToken(chat)

	// 1. preview_only renders and returns metadata without saving anything to Library.
	code, prev := e.tool(token, "render_pdf", map[string]any{
		"title":        "Draft Brief",
		"html":         "<h1>Draft</h1>",
		"preview_only": true,
	})
	if code != 200 || prev["preview_only"] != true || prev["pages"] != float64(2) || prev["detail"] != "2 pages · Letter" {
		t.Fatalf("preview_only = %d %v", code, prev)
	}
	if items := e.want("GET", "/library?kind=file", nil, 200)["items"].([]any); len(items) != 0 {
		t.Fatalf("preview_only left library items: %v", items)
	}

	// 2. Full render with attach_to_knowledge saves to Library AND creates a Knowledge asset.
	code, out := e.tool(token, "render_pdf", map[string]any{
		"title":               "Q4 Plan",
		"filename":            "q4-plan.pdf",
		"html":                "<h1>Q4 Plan</h1><p>Details.</p>",
		"css":                 "h1 { color: #1f2937; }",
		"page_size":           "letter",
		"margins":             map[string]any{"top": "0.5in"},
		"attach_to_knowledge": true,
	})
	if code != 200 {
		t.Fatalf("render_pdf = %d %v", code, out)
	}
	libID, _ := out["library_item_id"].(string)
	embed, _ := out["knowledge_embed"].(string)
	if libID == "" || out["detail"] != "2 pages · Letter" || !strings.HasPrefix(embed, "![[attachment:") || !strings.HasSuffix(embed, "/q4-plan.pdf]]") {
		t.Fatalf("render_pdf output = %v", out)
	}
	if lastReq["css"] != "h1 { color: #1f2937; }" {
		t.Fatalf("worker did not receive css: %v", lastReq)
	}

	// GET /library/{itemId} returns the saved PDF with detail and enforces ownership.
	got := e.want("GET", "/library/"+libID, nil, 200)
	if got["id"] != libID || got["title"] != "Q4 Plan" || got["content_type"] != "application/pdf" || got["detail"] != "2 pages · Letter" {
		t.Fatalf("GET /library/{itemId} = %v", got)
	}
	e.want("GET", "/library/"+uuid.NewString(), nil, http.StatusNotFound)

	// Placing the returned knowledge_embed into a Knowledge page resolves cleanly as a PDF file embed.
	code, pageRes := e.tool(token, "create_page", map[string]any{
		"title": "Q4 Overview",
		"body":  "Here is the PDF:\n\n" + embed + "\n\nAnd via library ref:\n\n![[library:" + libID + "]]\n",
	})
	if code != 200 {
		t.Fatalf("create_page = %d %v", code, pageRes)
	}
	pageID := pageRes["id"].(string)
	page := e.want("GET", "/knowledge/pages/"+pageID, nil, 200)
	embeds, _ := page["embeds"].([]any)
	if len(embeds) != 2 {
		t.Fatalf("expected 2 resolved embeds, got %v", embeds)
	}
	for i, raw := range embeds {
		em := raw.(map[string]any)
		if em["available"] != true || em["kind"] != "file" || em["content_type"] != "application/pdf" {
			t.Fatalf("embed[%d] = %v", i, em)
		}
	}

	// 3. Two-step Knowledge placement: render without attach_to_knowledge, then call attach_file with library_item_id.
	code, second := e.tool(token, "render_pdf", map[string]any{
		"title": "Handout",
		"html":  "<p>One pager</p>",
	})
	if code != 200 || second["knowledge_embed"] != nil {
		t.Fatalf("second render = %d %v", code, second)
	}
	secondID := second["library_item_id"].(string)
	code, attached := e.tool(token, "attach_file", map[string]any{"library_item_id": secondID})
	if code != 200 || attached["content_type"] != "application/pdf" || !strings.HasPrefix(attached["embed"].(string), "![[attachment:") {
		t.Fatalf("attach_file(library_item_id) = %d %v", code, attached)
	}

	// 4. Validation & worker error propagation.
	if code, _ = e.tool(token, "render_pdf", map[string]any{"html": ""}); code != http.StatusUnprocessableEntity {
		t.Fatalf("empty html = %d", code)
	}
	if code, _ = e.tool(token, "render_pdf", map[string]any{"html": "<p>x</p>", "preview_only": true, "attach_to_knowledge": true}); code != http.StatusUnprocessableEntity {
		t.Fatalf("preview_only + attach_to_knowledge = %d", code)
	}
	workerStatus, workerMsg = http.StatusBadRequest, "margins: invalid length"
	if code, errOut := e.tool(token, "render_pdf", map[string]any{"html": "<p>x</p>"}); code != http.StatusUnprocessableEntity || !strings.Contains(errOut["message"].(string), "margins") {
		t.Fatalf("worker 400 = %d %v", code, errOut)
	}
	workerStatus, workerMsg = http.StatusServiceUnavailable, "no Chrome found"
	if code, errOut := e.tool(token, "render_pdf", map[string]any{"html": "<p>x</p>"}); code != http.StatusConflict || !strings.Contains(errOut["message"].(string), "no Chrome found") {
		t.Fatalf("worker 503 = %d %v", code, errOut)
	}
}

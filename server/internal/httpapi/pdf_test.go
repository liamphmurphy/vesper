package httpapi

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/store"
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

func TestRenderPDFEmbedsKnowledgeAndLibraryImages(t *testing.T) {
	fakePDF := []byte("%PDF-1.4\n1 0 obj\n<< /Type /Page >>\nendobj\n%%EOF\n")
	fakePNG := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R'}
	fakeJPEG := []byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xd9}
	fakeWebP, err := base64.StdEncoding.DecodeString("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")
	if err != nil {
		t.Fatal(err)
	}

	var workerCalls int
	var lastReq map[string]any
	workerSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		workerCalls++
		lastReq = nil
		_ = json.NewDecoder(r.Body).Decode(&lastReq)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"pdf_base64": base64.StdEncoding.EncodeToString(fakePDF),
			"pages":      1,
			"page_size":  "Letter",
			"previews": []map[string]any{
				{"page": 1, "width": 850, "height": 1100, "png_base64": base64.StdEncoding.EncodeToString(fakePNG)},
			},
		})
	}))
	defer workerSrv.Close()

	blobs := newFakeBlobs(t).Store
	var srv *Server
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = blobs
		s.ArtifactBucket = avatarBucket
		s.DesignWorker = &designs.Worker{URL: workerSrv.URL + "/internal/designs", Token: "pdf-tok", Backoff: 1}
		s.Wiki.Objects = blobs
		s.Wiki.Artifacts.Bucket = avatarBucket
		srv = s
	})

	ctx := t.Context()
	persona := e.want("POST", "/personas", map[string]any{
		"name": "Chronicler", "tone": "friendly", "color": "#4f6d7a", "capabilities": map[string]any{"code": false},
	}, http.StatusCreated)
	chatObj := e.newChat(map[string]any{"persona_id": persona["id"]})
	chat := uuid.MustParse(chatObj["id"].(string))
	token := e.canvasToken(chat)

	// Upload JPEG, PNG, WebP and a non-image PDF as Knowledge attachments owned by e.me.
	jpegAsset, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, e.me.ID, "cyric.jpg", fakeJPEG)
	if err != nil {
		t.Fatal(err)
	}
	pngAsset, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, e.me.ID, "Midnight Mystra.png", fakePNG)
	if err != nil {
		t.Fatal(err)
	}
	webpAsset, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, e.me.ID, "Mortal_Kelemvor.webp", fakeWebP)
	if err != nil {
		t.Fatal(err)
	}
	pdfAsset, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, e.me.ID, "handout.pdf", fakePDF)
	if err != nil {
		t.Fatal(err)
	}

	// Create a second user with a private attachment (inaccessible) and a shared-page attachment (accessible).
	other, err := e.q.CreateUser(ctx, store.CreateUserParams{WorkspaceID: e.me.WorkspaceID, Name: "Other", Email: "other-pdf@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	privateAsset, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, other.ID, "secret.png", fakePNG)
	if err != nil {
		t.Fatal(err)
	}
	sharedAsset, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, other.ID, "shared-crest.webp", fakeWebP)
	if err != nil {
		t.Fatal(err)
	}
	sharedPage := e.want("POST", "/knowledge/pages", map[string]any{"title": "Shared Lore", "audience": "shared"}, http.StatusOK)
	if _, err := e.pool.Exec(ctx, `INSERT INTO page_asset_refs(version_id,asset_id) VALUES ($1,$2)`, sharedPage["version_id"], sharedAsset.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE artifacts SET owner_user_id=$2 WHERE id=$1`, sharedPage["id"], other.ID); err != nil {
		t.Fatal(err)
	}

	// Create a Library image item and a private Doc Library item owned by e.me.
	libBlobKey := "library/test-portrait.png"
	if err := blobs.Put(ctx, avatarBucket, libBlobKey, bytes.NewReader(fakePNG), int64(len(fakePNG)), "image/png"); err != nil {
		t.Fatal(err)
	}
	libImg, err := e.q.CreateLibraryItem(ctx, store.CreateLibraryItemParams{
		WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID, Kind: "image", Title: "Adon Portrait",
		Filename: "adon.png", ContentType: "image/png", SizeBytes: int64(len(fakePNG)), BlobKey: libBlobKey,
	})
	if err != nil {
		t.Fatal(err)
	}
	libDoc, err := e.q.CreateLibraryItem(ctx, store.CreateLibraryItemParams{
		WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID, Kind: "document", Title: "Private Doc",
		Filename: "doc.png", ContentType: "image/png", SizeBytes: int64(len(fakePNG)), BlobKey: libBlobKey,
	})
	if err != nil {
		t.Fatal(err)
	}

	// 1. Successful render inlining bare attachment:<id>, attachment:<id>/<filename>, JPEG/PNG/WebP, shared attachment, library:<id>, CSS url(), and header_html.
	html := `<h1>Time of Troubles</h1>` +
		`<img src="attachment:` + jpegAsset.ID.String() + `" alt="Cyric">` +
		`<img src="attachment:` + pngAsset.ID.String() + `/Midnight Mystra.png" alt="Mystra">` +
		`<img src="attachment:` + webpAsset.ID.String() + `/Mortal_Kelemvor.webp" alt="Kelemvor">` +
		`<img src="attachment:` + sharedAsset.ID.String() + `/shared-crest.webp" alt="Crest">` +
		`<img src="library:` + libImg.ID.String() + `" alt="Adon">`
	css := `.banner { background-image: url("attachment:` + webpAsset.ID.String() + `/Mortal_Kelemvor.webp"); }`
	header := `<div><img src="attachment:` + pngAsset.ID.String() + `"></div>`

	code, out := e.tool(token, "render_pdf", map[string]any{
		"title":        "Character Dossiers",
		"html":         html,
		"css":          css,
		"header_html":  header,
		"preview_only": true,
	})
	if code != http.StatusOK || out["pages"] != float64(1) {
		t.Fatalf("render_pdf with attachments = %d %v", code, out)
	}
	if workerCalls != 1 {
		t.Fatalf("workerCalls = %d, want 1", workerCalls)
	}

	jpegURI := "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(fakeJPEG)
	pngURI := "data:image/png;base64," + base64.StdEncoding.EncodeToString(fakePNG)
	webpURI := "data:image/webp;base64," + base64.StdEncoding.EncodeToString(fakeWebP)

	sentHTML, _ := lastReq["html"].(string)
	sentCSS, _ := lastReq["css"].(string)
	sentHeader, _ := lastReq["header_html"].(string)
	for _, want := range []string{jpegURI, pngURI, webpURI} {
		if !strings.Contains(sentHTML, want) {
			t.Errorf("worker html missing inlined URI %q", want)
		}
	}
	if strings.Contains(sentHTML, "attachment:") || strings.Contains(sentHTML, "library:") {
		t.Errorf("worker html still contains unresolved refs: %s", sentHTML)
	}
	if !strings.Contains(sentCSS, "url("+webpURI+")") {
		t.Errorf("worker css = %q, want inlined WebP URI", sentCSS)
	}
	if !strings.Contains(sentHeader, pngURI) {
		t.Errorf("worker header_html = %q, want inlined PNG URI", sentHeader)
	}

	// 2. Error cases: unknown, unauthorized, non-image, and private Doc refs fail with 422 naming the reference and never call the worker.
	missingID := uuid.New()
	errCases := []struct {
		name    string
		html    string
		wantRef string
	}{
		{"unknown attachment", `<img src="attachment:` + missingID.String() + `/missing.jpg">`, "attachment:" + missingID.String() + "/missing.jpg"},
		{"private attachment of another user", `<img src="attachment:` + privateAsset.ID.String() + `">`, "attachment:" + privateAsset.ID.String()},
		{"non-image attachment", `<img src="attachment:` + pdfAsset.ID.String() + `/handout.pdf">`, "attachment:" + pdfAsset.ID.String() + "/handout.pdf"},
		{"unknown library item", `<img src="library:` + missingID.String() + `">`, "library:" + missingID.String()},
		{"private doc library item", `<img src="library:` + libDoc.ID.String() + `">`, "library:" + libDoc.ID.String()},
	}
	for _, tc := range errCases {
		t.Run(tc.name, func(t *testing.T) {
			before := workerCalls
			code, errOut := e.tool(token, "render_pdf", map[string]any{
				"html":         tc.html,
				"preview_only": true,
			})
			if code != http.StatusUnprocessableEntity {
				t.Fatalf("got HTTP %d %v, want 422", code, errOut)
			}
			msg, _ := errOut["message"].(string)
			if !strings.Contains(msg, tc.wantRef) {
				t.Fatalf("error message %q does not name reference %q", msg, tc.wantRef)
			}
			if workerCalls != before {
				t.Fatalf("worker was called despite failed asset resolution")
			}
		})
	}
}

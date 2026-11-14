package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/links"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// LAZYAGENTS-178: links, block references, embeds and attachments, exercised
// through the REST API a client renders from and the tools a run reads with.

// newKnowledgeAssetsEnv is the Designs env (fake S3 and design worker) with
// Knowledge attachments stored in the same fake bucket the API serves from.
func newKnowledgeAssetsEnv(t *testing.T) (*designsEnv, *Server) {
	t.Helper()
	f := &flakyS3{fakeS3: &fakeS3{objs: map[string]fakeObject{}}}
	ts := httptest.NewServer(f)
	t.Cleanup(ts.Close)
	blobs := blob.New(config.S3{Endpoint: ts.URL, Region: "us-east-1", AccessKey: "test", SecretKey: "test-secret", UsePathStyle: true})
	ws := httptest.NewServer(&stubWorker{})
	t.Cleanup(ws.Close)
	var srv *Server
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = blobs
		s.ArtifactBucket = avatarBucket
		s.DesignWorker = &designs.Worker{URL: ws.URL, Token: "test-token", Backoff: 1}
		s.Wiki.Objects = blobs
		s.Wiki.Artifacts.Bucket = avatarBucket
		srv = s
	})
	return &designsEnv{&slidesEnv{chatEnv: e, s3: f, blobs: blobs}}, srv
}

// ticketRunToken is an MCP token for a ticket run: no person behind it.
func (e *chatEnv) ticketRunToken() string {
	e.t.Helper()
	ctx, ws := e.t.Context(), e.me.WorkspaceID
	atlas, err := e.q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	if err != nil {
		e.t.Fatal(err)
	}
	tk, err := e.q.GetTicketByKey(ctx, store.GetTicketByKeyParams{WorkspaceID: ws, Key: e.payKey})
	if err != nil {
		e.t.Fatal(err)
	}
	run, err := e.q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, TicketID: &tk.ID, AgentID: atlas.ID, Mode: "managed", State: "running", Purpose: "ticket", Harness: "claude", Model: "test", ResolvedSpec: json.RawMessage(`{}`)})
	if err != nil {
		e.t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, e.q, atlas.ID, "run", "embeds", &run.ID, nil, nil)
	if err != nil {
		e.t.Fatal(err)
	}
	return token
}

func pageEmbeds(page map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	for _, x := range page["embeds"].([]any) {
		m := x.(map[string]any)
		out[m["ref"].(string)] = m
	}
	return out
}

func (e *chatEnv) linksFrom(id string) map[string]store.KnowledgeLink {
	e.t.Helper()
	ls, err := e.q.LinksFromSource(e.t.Context(), store.LinksFromSourceParams{SourceKind: links.SourceArtifact, SourceID: uuid.MustParse(id)})
	if err != nil {
		e.t.Fatal(err)
	}
	out := map[string]store.KnowledgeLink{}
	for _, l := range ls {
		out[l.RawText] = l
	}
	return out
}

// Criteria 1–3: |label, #Heading and #^block links are indexed and resolved;
// page, heading and block embeds come back with their content from the page
// API; a run reading the page never receives a private embed's content.
func TestKnowledgeLinksBlocksAndEmbedsOverTheAPI(t *testing.T) {
	e := newChatEnv(t)
	runbook := e.want("POST", "/knowledge/pages", map[string]any{"title": "Runbook", "audience": "shared", "body_md": strings.Join([]string{
		"# Runbook", "", "Intro.", "", "## Roll back", "", "Stop the writers.", "", "Restart the ledger and wait. ^restart", "", "- check the queues ^queues", "", "## Verify", "", "All green.",
	}, "\n")}, 200)
	e.want("POST", "/knowledge/pages", map[string]any{"title": "Secret plan", "audience": "private", "body_md": "Private payload 9f3a ^p1"}, 200)
	hub := e.want("POST", "/knowledge/pages", map[string]any{"title": "Hub", "audience": "shared", "body_md": strings.Join([]string{
		"See [[Runbook|the runbook]], [[Runbook#Roll back]] and [[Runbook#^restart]].", "",
		"![[Runbook#Roll back]]", "", "![[Runbook#^restart]]", "", "![[Runbook#^queues]]", "", "![[Secret plan]]", "", "![[Secret plan#^p1]]", "", "![[Later page#^x]]",
	}, "\n")}, 200)
	hubID, runbookID := hub["id"].(string), runbook["id"].(string)

	got := e.linksFrom(hubID)
	for raw, anchor := range map[string]string{
		"[[Runbook|the runbook]]": "",
		"[[Runbook#Roll back]]":   "roll-back",
		"[[Runbook#^restart]]":    "^restart",
		"![[Runbook#^queues]]":    "^queues",
	} {
		l, ok := got[raw]
		if !ok || l.TargetID == nil || l.TargetID.String() != runbookID || l.TargetAnchor != anchor {
			t.Errorf("%s indexed as %+v, want Runbook with anchor %q", raw, l, anchor)
		}
	}
	if l := got["![[Later page#^x]]"]; l.TargetKind != links.KindUnresolved {
		t.Errorf("link to a missing page: %+v", l)
	}
	// A ghost link resolves once its page exists.
	e.want("POST", "/knowledge/pages", map[string]any{"title": "Later page", "audience": "shared", "body_md": "Later text ^x"}, 200)
	if l := e.linksFrom(hubID)["![[Later page#^x]]"]; l.TargetKind == links.KindUnresolved || l.TargetID == nil {
		t.Errorf("ghost block link after the page was created: %+v", l)
	}

	em := pageEmbeds(e.want("GET", "/knowledge/pages/"+hubID, nil, 200))
	for ref, want := range map[string]string{
		"![[Runbook#Roll back]]": "Stop the writers.",
		"![[Runbook#^restart]]":  "Restart the ledger and wait.",
		"![[Runbook#^queues]]":   "check the queues",
		"![[Secret plan]]":       "Private payload 9f3a",
		"![[Secret plan#^p1]]":   "Private payload 9f3a",
		"![[Later page#^x]]":     "Later text",
	} {
		m := em[ref]
		if m["available"] != true || !strings.Contains(m["markdown"].(string), want) {
			t.Errorf("embed %s for the owner: %v", ref, m)
		}
	}
	if md := em["![[Runbook#Roll back]]"]["markdown"].(string); strings.Contains(md, "All green") {
		t.Errorf("heading embed runs into the next section: %q", md)
	}
	if md := em["![[Runbook#^restart]]"]["markdown"].(string); strings.Contains(md, "Stop the writers") || strings.Contains(md, "check the queues") {
		t.Errorf("block embed holds more than its block: %q", md)
	}

	// A run reads the shared hub and follows its embeds: nothing private.
	token := e.ticketRunToken()
	for _, ref := range []string{"Hub", "Secret plan", "[[Secret plan#^p1]]"} {
		code, out := e.tool(token, "read_page", map[string]any{"ref": ref})
		raw, _ := json.Marshal(out)
		if strings.Contains(string(raw), "Private payload") {
			t.Fatalf("run read_page(%q) received private content: %d %s", ref, code, raw)
		}
		if ref != "Hub" && code == http.StatusOK {
			t.Fatalf("run opened private %q: %s", ref, raw)
		}
	}
	if code, out := e.tool(token, "read_page", map[string]any{"ref": "[[Runbook#^restart]]"}); code != http.StatusOK || !strings.Contains(out["markdown"].(string), "Restart the ledger") || strings.Contains(out["markdown"].(string), "All green") {
		t.Errorf("run read_page of a block: %d %v", code, out)
	}
}

func (e *designsEnv) uploadAsset(name string, data []byte) (int, map[string]any) {
	e.t.Helper()
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/v1/knowledge/assets", bytes.NewReader(data))
	req.Header.Set("X-Filename", name)
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

func (e *designsEnv) assetObjects() []string {
	e.s3.mu.Lock()
	defer e.s3.mu.Unlock()
	var keys []string
	for k := range e.s3.objs {
		if strings.Contains(k, "knowledge-assets/") {
			keys = append(keys, k)
		}
	}
	return keys
}

// Criterion 4: attachments are stored by content hash, an identical upload
// reuses the stored file, a file embed resolves through the page API, and
// the sweep deletes an attachment no page uses (and keeps one a page uses).
func TestKnowledgeAttachmentsReuseEmbedAndSweep(t *testing.T) {
	e, s := newKnowledgeAssetsEnv(t)
	ctx := t.Context()
	png := avatarPNG(t)
	code, first := e.uploadAsset("diagram.png", png)
	if code != http.StatusCreated {
		t.Fatalf("upload: %d %v", code, first)
	}
	code, again := e.uploadAsset("diagram.png", png)
	if code != http.StatusCreated || again["id"] != first["id"] {
		t.Fatalf("identical upload made a new attachment: %v then %v", first, again)
	}
	if keys := e.assetObjects(); len(keys) != 1 {
		t.Fatalf("stored objects after two identical uploads: %v", keys)
	}
	code, orphan := e.uploadAsset("unused.pdf", []byte("%PDF-1.4\nnot embedded anywhere\n"))
	if code != http.StatusCreated || orphan["id"] == first["id"] {
		t.Fatalf("second file: %d %v", code, orphan)
	}

	ref := "![[" + first["ref"].(string) + "]]"
	page := e.want("POST", "/knowledge/pages", map[string]any{"title": "Diagrams", "audience": "shared", "body_md": "The flow:\n\n" + ref}, 200)
	emb := pageEmbeds(page)[ref]
	if emb["available"] != true || emb["kind"] != "file" || emb["content_type"] != "image/png" || emb["url"] != first["url"] {
		t.Fatalf("file embed: %v", emb)
	}
	res, err := http.Get(e.srv.URL + first["url"].(string))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || !bytes.Equal(body, png) || res.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatalf("attachment content: %d %v", res.StatusCode, res.Header)
	}

	// Both uploads are past the grace period; only the embedded one survives.
	if _, err := e.pool.Exec(ctx, `UPDATE knowledge_assets SET created_at = now() - interval '2 days'`); err != nil {
		t.Fatal(err)
	}
	if err := s.Wiki.SweepKnowledgeAssets(ctx); err != nil {
		t.Fatal(err)
	}
	var left []uuid.UUID
	rows, err := e.pool.Query(ctx, `SELECT id FROM knowledge_assets`)
	if err != nil {
		t.Fatal(err)
	}
	for rows.Next() {
		var id uuid.UUID
		rows.Scan(&id)
		left = append(left, id)
	}
	rows.Close()
	if len(left) != 1 || left[0].String() != first["id"] {
		t.Fatalf("assets after the sweep: %v, want only %v", left, first["id"])
	}
	if keys := e.assetObjects(); len(keys) != 1 {
		t.Fatalf("objects after the sweep: %v", keys)
	}
	if code, _ := e.do("GET", "/knowledge/assets/"+orphan["id"].(string), nil); code != http.StatusNotFound {
		t.Fatalf("swept attachment still served: %d", code)
	}
}

// Criterion 5 through the page API: a Designs frame and a Library image embed
// in a page for their owner; a run reading the page gets neither.
func TestKnowledgeEmbedsDesignFrameAndLibraryItemOverTheAPI(t *testing.T) {
	e, _ := newKnowledgeAssetsEnv(t)
	designID, _, _ := e.acceptance()
	_, body := e.current(designID)
	frameID := ""
	for _, p := range body["pages"].([]any) {
		for _, c := range p.(map[string]any)["children"].([]any) {
			if n := c.(map[string]any); n["type"] == "frame" && frameID == "" {
				frameID = n["id"].(string)
			}
		}
	}
	if frameID == "" {
		t.Fatal("the acceptance design has no top-level frame")
	}
	code, item := e.uploadLibrary("photo.png", avatarPNG(t))
	if code != http.StatusCreated && code != http.StatusOK {
		t.Fatalf("library upload: %d %v", code, item)
	}
	frame := "![[design:" + designID + "#" + frameID + "]]"
	image := "![[library:" + item["id"].(string) + "]]"
	page := e.want("POST", "/knowledge/pages", map[string]any{"title": "Moodboard", "audience": "shared", "body_md": frame + "\n\n" + image}, 200)
	em := pageEmbeds(page)
	if d := em[frame]; d["available"] != true || d["kind"] != "design" {
		t.Errorf("design frame embed: %v", d)
	}
	if l := em[image]; l["available"] != true || l["kind"] != "image" || !strings.Contains(l["url"].(string), item["id"].(string)) {
		t.Errorf("library embed: %v", l)
	}
	code, out := e.tool(e.ticketRunToken(), "read_page", map[string]any{"ref": "Moodboard"})
	raw, _ := json.Marshal(out)
	if code != http.StatusOK || strings.Contains(string(raw), "/library/"+item["id"].(string)+"/content") || strings.Contains(string(raw), `"kind":"design"`) {
		t.Errorf("run read of the moodboard: %d %s", code, raw)
	}
}

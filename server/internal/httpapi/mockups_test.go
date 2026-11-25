package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"image"
	"image/png"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

const httpSVG = `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200"><rect width="320" height="200"/><text x="10" y="20">Login</text></svg>`

func TestMockupHTTP(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	tr := &tracker.Service{Pool: pool}
	srv := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}, Artifacts: arts}
	h := srv.Handler()
	do := func(method, path string, body any) *httptest.ResponseRecorder {
		var rd bytes.Buffer
		if body != nil {
			_ = json.NewEncoder(&rd).Encode(body)
		}
		req := httptest.NewRequest(method, "/api/v1"+path, &rd)
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	want := func(w *httptest.ResponseRecorder, code int) {
		t.Helper()
		if w.Code != code {
			t.Fatalf("status %d, want %d: %s", w.Code, code, w.Body.String())
		}
	}

	// Create a mockup from SVG source over multipart.
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range map[string]string{"project_key": "PAY", "type": "mockup", "title": "Login", "body_md": httpSVG} {
		_ = mw.WriteField(k, v)
	}
	_ = mw.Close()
	req := httptest.NewRequest("POST", "/api/v1/artifacts", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	want(rec, 201)
	var art api.Artifact
	_ = json.Unmarshal(rec.Body.Bytes(), &art)
	if art.Type != api.ArtifactTypeMockup || art.CurrentVersion.Content.Kind != api.ArtifactContentKindSvg || art.CurrentVersion.Review == nil || art.CurrentVersion.Review.State != api.MockupReviewStatePending {
		t.Fatalf("created = %+v", art.CurrentVersion)
	}
	if v, _ := art.BodyMd.Get(); v != httpSVG {
		t.Fatalf("body_md = %q", v)
	}

	// Content is served as sandboxed SVG, never inline-safe.
	base := "/artifacts/" + art.Id.String() + "/versions/" + art.CurrentVersion.Id.String()
	rec = do("GET", base+"/content", nil)
	want(rec, 200)
	if ct := rec.Header().Get("Content-Type"); ct != "image/svg+xml; charset=utf-8" {
		t.Errorf("content type = %q", ct)
	}
	if rec.Header().Get("Content-Security-Policy") != "sandbox" || !strings.HasPrefix(rec.Header().Get("Content-Disposition"), "attachment") || !strings.Contains(rec.Header().Get("Content-Disposition"), "login-v1.svg") {
		t.Errorf("headers = %v", rec.Header())
	}

	// Listing counts mockups and exposes the review state.
	rec = do("GET", "/artifacts?type=mockup", nil)
	want(rec, 200)
	var list api.ArtifactList
	_ = json.Unmarshal(rec.Body.Bytes(), &list)
	if list.Counts.Mockup != 1 || len(list.Artifacts) != 1 || list.Artifacts[0].ReviewState == nil || *list.Artifacts[0].ReviewState != api.MockupReviewStatePending {
		t.Fatalf("list = %+v", list)
	}

	// Flag a ticket and attach the mockup: the gate shows it.
	rec = do("PATCH", "/tickets/PAY-214", map[string]any{"requires_mockup": true})
	want(rec, 200)
	rec = do("POST", "/tickets/PAY-214/artifacts", map[string]any{"artifact_id": art.Id, "relation": "context"})
	want(rec, 200)
	var tk api.Ticket
	_ = json.Unmarshal(rec.Body.Bytes(), &tk)
	if !tk.RequiresMockup || !tk.MockupGate.Required || tk.MockupGate.Approved || len(tk.MockupGate.Mockups) != 1 || tk.MockupGate.Mockups[0].ReviewState != api.MockupReviewStatePending {
		t.Fatalf("gate = %+v", tk.MockupGate)
	}
	var card *api.DocCard
	for i := range tk.Artifacts {
		if tk.Artifacts[i].Id == art.Id {
			card = &tk.Artifacts[i]
		}
	}
	if card == nil || card.ReviewState == nil || *card.ReviewState != api.MockupReviewStatePending {
		t.Fatalf("doc card = %+v", card)
	}

	// The inbox asks for a review.
	inbox := func() *api.InboxItem {
		rec := do("GET", "/inbox", nil)
		want(rec, 200)
		var res struct{ Items []api.InboxItem }
		_ = json.Unmarshal(rec.Body.Bytes(), &res)
		for i, it := range res.Items {
			if it.Id == "mockup:"+art.CurrentVersion.Id.String() {
				return &res.Items[i]
			}
		}
		return nil
	}
	if it := inbox(); it == nil || it.Resolved || it.Kind != api.InboxItemKindMockup || it.TicketKey != "PAY-214" || it.Href != "/artifacts/"+art.Id.String()+"/review" {
		t.Fatalf("inbox item = %+v", it)
	}

	// Review: validation, then approval.
	review := base + "/review"
	want(do("POST", review, map[string]any{"decision": "changes_requested"}), 422)
	want(do("POST", review, map[string]any{"decision": "maybe"}), 422)
	want(do("POST", "/artifacts/"+art.Id.String()+"/versions/"+tk.Id.String()+"/review", map[string]any{"decision": "approved"}), 409)
	// Pins alone don't satisfy the note a change request needs; bad pins are refused.
	pins := []map[string]any{{"x": 0.25, "y": 0.5, "text": " Bigger button "}, {"x": 1, "y": 0, "text": "Logo here"}}
	want(do("POST", review, map[string]any{"decision": "changes_requested", "pins": pins}), 422)
	want(do("POST", review, map[string]any{"decision": "changes_requested", "note": "x", "pins": []map[string]any{{"x": 1.5, "y": 0, "text": "off"}}}), 422)
	want(do("POST", review, map[string]any{"decision": "changes_requested", "note": "x", "pins": []map[string]any{{"x": 0, "y": 0, "text": " "}}}), 422)
	rec = do("POST", review, map[string]any{"decision": "changes_requested", "note": "Add a forgot-password link", "pins": pins})
	want(rec, 200)
	_ = json.Unmarshal(rec.Body.Bytes(), &art)
	wantNote := "Add a forgot-password link\n\nPinned comments (% across, % down the drawing):\n1. (25%, 50%) Bigger button\n2. (100%, 0%) Logo here"
	if r := art.CurrentVersion.Review; r == nil || r.State != api.MockupReviewStateChangesRequested || r.Note != wantNote || r.ReviewedBy == nil ||
		len(r.Pins) != 2 || r.Pins[0] != (api.MockupPin{X: 0.25, Y: 0.5, Text: "Bigger button"}) || r.Pins[1].Text != "Logo here" {
		t.Fatalf("review = %+v", r)
	}
	rec = do("GET", "/tickets/PAY-214", nil)
	_ = json.Unmarshal(rec.Body.Bytes(), &tk)
	if g := tk.MockupGate; g.Approved || len(g.Mockups) != 1 || g.Mockups[0].ReviewState != api.MockupReviewStateChangesRequested || g.Mockups[0].ReviewNote != wantNote {
		t.Fatalf("gate after changes requested = %+v", g)
	}
	rec = do("POST", review, map[string]any{"decision": "approved", "note": "Looks good"})
	want(rec, 200)
	_ = json.Unmarshal(rec.Body.Bytes(), &art)
	if r := art.CurrentVersion.Review; r.State != api.MockupReviewStateApproved || r.Note != "Looks good" || r.Pins == nil || len(r.Pins) != 0 {
		t.Fatalf("review = %+v", r)
	}
	rec = do("GET", "/tickets/PAY-214", nil)
	_ = json.Unmarshal(rec.Body.Bytes(), &tk)
	if !tk.MockupGate.Approved {
		t.Fatalf("gate = %+v", tk.MockupGate)
	}
	if it := inbox(); it == nil || !it.Resolved {
		t.Fatalf("resolved inbox item = %+v", it)
	}
	want(do("POST", "/artifacts/00000000-0000-0000-0000-000000000000/versions/"+art.CurrentVersion.Id.String()+"/review", map[string]any{"decision": "approved"}), 404)

	// Epics can require mockups for all their tickets.
	if tk.Epic == nil {
		t.Fatal("PAY-214 should be in an epic")
	}
	rec = do("PATCH", "/epics/"+tk.Epic.Id.String(), map[string]any{"requires_mockup": true})
	want(rec, 200)
	var epic api.Epic
	_ = json.Unmarshal(rec.Body.Bytes(), &epic)
	if !epic.RequiresMockup {
		t.Fatalf("epic = %+v", epic)
	}
	rec = do("PATCH", "/tickets/PAY-214", map[string]any{"requires_mockup": false})
	want(rec, 200)
	_ = json.Unmarshal(rec.Body.Bytes(), &tk)
	if tk.RequiresMockup || !tk.MockupGate.Required || !tk.MockupGate.FromEpic {
		t.Fatalf("epic gate = %+v", tk.MockupGate)
	}
	want(do("PATCH", "/epics/00000000-0000-0000-0000-000000000000", map[string]any{"requires_mockup": true}), 404)

	// The change is on the timeline.
	rec = do("GET", "/tickets/PAY-214/activity", nil)
	want(rec, 200)
	if !strings.Contains(rec.Body.String(), `"mockup_requirement_changed"`) || !strings.Contains(rec.Body.String(), `"mockup_approved"`) {
		t.Errorf("activity missing mockup events: %s", rec.Body.String())
	}
	_ = http.StatusOK
}

func TestMockupAgentTools(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()
	a, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	token, _, err := agents.IssueToken(ctx, q, a.ID, "unmanaged", "test", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	call := func(name string, args any) (int, map[string]any) {
		t.Helper()
		raw, _ := json.Marshal(args)
		req := httptest.NewRequest("POST", "/api/v1/agent/tools/"+name, bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}
	yes := true
	if _, err := tr.Update(ctx, ws, tracker.UserActor(me.ID), "PAY-214", tracker.Patch{RequiresMockup: &yes}); err != nil {
		t.Fatal(err)
	}
	if code, out := call("claim_ticket", map[string]any{"ticket": "PAY-214"}); code != 200 || out["requires_mockup"] != true {
		t.Fatalf("claim = %d %v", code, out)
	}
	code, out := call("get_ticket", map[string]any{"ticket": "PAY-214"})
	gate, _ := out["mockup"].(map[string]any)
	if code != 200 || gate["required"] != true || gate["approved"] != false || !strings.Contains(gate["instruction"].(string), "create_mockup") {
		t.Fatalf("get_ticket = %d %v", code, out)
	}
	if code, out := call("complete_run", map[string]any{"ticket": "PAY-214", "outcome": "done"}); code == 200 {
		t.Fatalf("complete_run before approval: %v", out)
	}
	if code, out := call("create_mockup", map[string]any{"ticket": "PAY-214", "title": "Evil", "svg": `<svg onload="x()"/>`}); code == 200 {
		t.Fatalf("unsafe svg accepted: %v", out)
	}
	code, out = call("create_mockup", map[string]any{"ticket": "PAY-214", "title": "Payout screen", "svg": httpSVG})
	if code != 200 || out["state"] != "waiting_for_review" || out["review_state"] != "pending" || out["version"] != "v1" {
		t.Fatalf("create_mockup = %d %v", code, out)
	}
	artifactID := out["artifact_id"].(string)
	tk, _ := tracker.Get(ctx, q, ws, "PAY-214")
	run, _ := q.ActiveRunForTicket(ctx, &tk.ID)
	if run.State != "waiting" || run.WaitReason == nil || *run.WaitReason != "mockup_review" {
		t.Fatalf("run = %s/%v", run.State, run.WaitReason)
	}
	// The mockup is attached as generated output and in the ticket's gate.
	g, _ := artifacts.MockupGate(ctx, q, tk)
	if len(g.Mockups) != 1 || g.Mockups[0].ID.String() != artifactID {
		t.Fatalf("gate = %+v", g)
	}
	m := g.Mockups[0]
	if _, err := rs.ReviewMockup(ctx, ws, me.ID, m.ID, m.VersionID, "approved", "", nil, nil); err != nil {
		t.Fatal(err)
	}
	if code, out := call("read_artifact", map[string]any{"ticket": "PAY-214", "artifact": artifactID}); code != 200 || out["svg"] != httpSVG || out["review_state"] != "approved" || out["markdown"] != nil {
		t.Fatalf("read_artifact = %d %v", code, out)
	}
	code, out = call("get_ticket", map[string]any{"ticket": "PAY-214"})
	if gate, _ = out["mockup"].(map[string]any); code != 200 || gate["approved"] != true || gate["instruction"] != nil {
		t.Fatalf("get_ticket after approval = %d %v", code, out)
	}
}

func TestCreateArtifactWithTicketKey(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	tr := &tracker.Service{Pool: pool}
	h := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}, Artifacts: arts}).Handler()
	create := func(project, ticket string) *httptest.ResponseRecorder {
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		for k, v := range map[string]string{"project_key": project, "type": "mockup", "title": "Attached", "body_md": httpSVG, "ticket_key": ticket} {
			_ = mw.WriteField(k, v)
		}
		_ = mw.Close()
		req := httptest.NewRequest("POST", "/api/v1/artifacts", &buf)
		req.Header.Set("Content-Type", mw.FormDataContentType())
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	count := func() (n int) {
		_ = pool.QueryRow(ctx, "SELECT count(*) FROM artifacts").Scan(&n)
		return
	}
	before := count()
	rec := create("PAY", "PAY-214")
	if rec.Code != 201 {
		t.Fatalf("status %d: %s", rec.Code, rec.Body.String())
	}
	var art api.Artifact
	_ = json.Unmarshal(rec.Body.Bytes(), &art)
	var n int
	if err := pool.QueryRow(ctx, "SELECT count(*) FROM ticket_artifacts ta JOIN tickets t ON t.id = ta.ticket_id WHERE t.key = 'PAY-214' AND ta.artifact_id = $1 AND ta.relation = 'context'", art.Id).Scan(&n); err != nil || n != 1 {
		t.Fatalf("not attached: %d %v", n, err)
	}
	if count() != before+1 {
		t.Fatal("expected exactly one new artifact")
	}
	// Unknown ticket, or one in another project: 422 and nothing created.
	before = count()
	if rec := create("PAY", "PAY-99999"); rec.Code != 422 {
		t.Fatalf("unknown ticket status %d: %s", rec.Code, rec.Body.String())
	}
	var other string
	if err := pool.QueryRow(ctx, "SELECT key FROM projects WHERE key <> 'PAY' LIMIT 1").Scan(&other); err != nil {
		t.Fatal(err)
	}
	if rec := create(other, "PAY-214"); rec.Code != 422 {
		t.Fatalf("cross-project status %d: %s", rec.Code, rec.Body.String())
	}
	if count() != before {
		t.Fatal("failed create left an artifact behind")
	}
}

// A review can carry the PNG the reviewer saw; it's served back, named on the
// version, and refused when it's of other source.
func TestMockupReviewSnapshotHTTP(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	blobs := blob.New(config.Blob{Dir: t.TempDir(), Buckets: []string{"artifacts"}})
	if err := blobs.EnsureBuckets(ctx); err != nil {
		t.Fatal(err)
	}
	arts := &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: "artifacts"}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	tr := &tracker.Service{Pool: pool}
	srv := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts},
		Artifacts: arts, Blobs: blobs, ArtifactBucket: "artifacts"}
	h := srv.Handler()
	do := func(method, path string, body any) *httptest.ResponseRecorder {
		var rd bytes.Buffer
		if body != nil {
			_ = json.NewEncoder(&rd).Encode(body)
		}
		req := httptest.NewRequest(method, "/api/v1"+path, &rd)
		req.Header.Set("Content-Type", "application/json")
		w := httptest.NewRecorder()
		h.ServeHTTP(w, req)
		return w
	}
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for k, v := range map[string]string{"project_key": "PAY", "type": "mockup", "title": "Login", "body_md": httpSVG} {
		_ = mw.WriteField(k, v)
	}
	_ = mw.Close()
	req := httptest.NewRequest("POST", "/api/v1/artifacts", &buf)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 201 {
		t.Fatalf("create: %d %s", rec.Code, rec.Body.String())
	}
	var art api.Artifact
	_ = json.Unmarshal(rec.Body.Bytes(), &art)
	base := "/artifacts/" + art.Id.String() + "/versions/" + art.CurrentVersion.Id.String()

	if rec := do("GET", base+"/review-snapshot", nil); rec.Code != 404 {
		t.Fatalf("snapshot before any review: %d", rec.Code)
	}
	img := image.NewRGBA(image.Rect(0, 0, 640, 400))
	var pngBuf bytes.Buffer
	_ = png.Encode(&pngBuf, img)
	snap := map[string]any{"png_base64": base64.StdEncoding.EncodeToString(pngBuf.Bytes()), "renderer": "vesper-native/1",
		"source_sha256": artifacts.SourceSHA256(httpSVG + "x")}
	if rec := do("POST", base+"/review", map[string]any{"decision": "approved", "snapshot": snap}); rec.Code != 422 {
		t.Fatalf("snapshot of other source: %d %s", rec.Code, rec.Body.String())
	}
	snap["source_sha256"] = artifacts.SourceSHA256(httpSVG)
	rec = do("POST", base+"/review", map[string]any{"decision": "approved", "snapshot": snap})
	if rec.Code != 200 {
		t.Fatalf("review: %d %s", rec.Code, rec.Body.String())
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &art)
	if r := art.CurrentVersion.Review; r == nil || r.Snapshot == nil || r.Snapshot.Renderer != "vesper-native/1" || r.Snapshot.SourceSha256 != artifacts.SourceSHA256(httpSVG) {
		t.Fatalf("review = %+v", r)
	}
	rec = do("GET", base+"/review-snapshot", nil)
	if rec.Code != 200 || rec.Header().Get("Content-Type") != "image/png" || !bytes.Equal(rec.Body.Bytes(), pngBuf.Bytes()) {
		t.Fatalf("served snapshot: %d %q %d bytes", rec.Code, rec.Header().Get("Content-Type"), rec.Body.Len())
	}
}

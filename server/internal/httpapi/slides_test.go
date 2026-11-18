package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/deck"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/slides"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type slidesEnv struct {
	*chatEnv
	s3    *fakeBlobs
	blobs *blob.Store
}

func newSlidesEnv(t *testing.T) *slidesEnv {
	t.Helper()
	f := newFakeBlobs(t)
	blobs := f.Store
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = blobs
		s.ArtifactBucket = avatarBucket
	})
	return &slidesEnv{chatEnv: e, s3: f, blobs: blobs}
}

// deck creates a deck and returns its id and chat id.
func (e *slidesEnv) deck(title string) (id, chat string) {
	e.t.Helper()
	d := e.want("POST", "/slides", map[string]any{"title": title}, http.StatusCreated)
	return d["id"].(string), d["chat_id"].(string)
}

func (e *slidesEnv) upload(deckID string, data []byte) (int, map[string]any) {
	e.t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	pw, _ := mw.CreateFormFile("file", "image.bin")
	pw.Write(data)
	mw.Close()
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/v1/slides/"+deckID+"/assets", &body)
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

func (e *slidesEnv) uploaded(deckID string, data []byte) string {
	e.t.Helper()
	code, out := e.upload(deckID, data)
	if code != http.StatusCreated {
		e.t.Fatalf("upload = %d %v", code, out)
	}
	return out["id"].(string)
}

// image fetches a deck image, returning the status and bytes.
func (e *slidesEnv) image(deckID, assetID string) (int, []byte) {
	e.t.Helper()
	res, err := http.Get(e.srv.URL + "/api/v1/slides/" + deckID + "/assets/" + assetID)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res.StatusCode, b
}

// sweep runs the runner's blob sweep, as if every queued key were due.
func (e *slidesEnv) sweep() (int, error) {
	return slides.SweepBlobs(e.t.Context(), e.pool, e.blobs, avatarBucket, time.Now().Add(time.Minute), 100)
}

func (e *slidesEnv) slideKeys() []string { return e.s3.keys(avatarBucket + "/slides/") }

func (e *slidesEnv) queued() []string {
	e.t.Helper()
	rows, err := e.pool.Query(e.t.Context(), `SELECT blob_key FROM deck_blob_sweep ORDER BY blob_key`)
	if err != nil {
		e.t.Fatal(err)
	}
	keys, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		e.t.Fatal(err)
	}
	return keys
}

func (e *slidesEnv) otherUser() store.User {
	e.t.Helper()
	u, err := e.q.CreateUser(e.t.Context(), store.CreateUserParams{WorkspaceID: e.me.WorkspaceID, Name: "Other", Email: "other@example.com", Initials: "OT"})
	if err != nil {
		e.t.Fatal(err)
	}
	return u
}

// pngSized is a valid PNG of the given size; seed changes one pixel, so
// different seeds are different blobs.
func pngSized(t *testing.T, w, h int, seed byte) []byte {
	t.Helper()
	img := avatarImage(w, h).(*image.RGBA)
	img.Set(0, 0, color.RGBA{seed, seed, seed, 255})
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// deckBody is a deck's current body, decoded.
func (e *slidesEnv) deckBody(chat, id string) (map[string]any, int) {
	e.t.Helper()
	cv := e.want("GET", "/chats/"+chat+"/canvases/"+id, nil, http.StatusOK)
	var m map[string]any
	if err := json.Unmarshal([]byte(cv["body"].(string)), &m); err != nil {
		e.t.Fatal(err)
	}
	return m, int(cv["seq"].(float64))
}

func encode(t *testing.T, m map[string]any) string {
	t.Helper()
	b, err := json.Marshal(m)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// blankSlides is n blank slides with notes of noteRunes two-byte runes each.
func blankSlides(n, noteRunes int) []any {
	out := make([]any, n)
	for i := range out {
		s := map[string]any{"id": fmt.Sprintf("s_blank%d", i), "layout": "blank", "elements": []any{}}
		if noteRunes > 0 {
			s["notes"] = strings.Repeat("é", noteRunes)
		}
		out[i] = s
	}
	return out
}

// A deck is created, listed, read, renamed, saved against its current
// version, duplicated with its images and deleted, all through the API.
func TestDeckLifecycle(t *testing.T) {
	e := newSlidesEnv(t)
	id, chat := e.deck("  Quarterly   review ")

	mine := e.want("GET", "/canvases/"+id, nil, http.StatusOK)
	if mine["kind"] != "deck" || mine["title"] != "Quarterly review" || mine["chat_id"] != chat {
		t.Fatalf("read %v", mine)
	}
	body, seq := e.deckBody(chat, id)
	if seq != 1 || len(body["slides"].([]any)) != 1 || body["schema"] != float64(deck.Schema) {
		t.Fatalf("first version %d %v", seq, body)
	}
	untitled := e.want("POST", "/slides", map[string]any{}, http.StatusCreated)
	if untitled["title"] != slides.UntitledTitle {
		t.Fatalf("untitled %v", untitled)
	}

	decks := e.want("GET", "/slides", nil, http.StatusOK)["decks"].([]any)
	if len(decks) != 2 {
		t.Fatalf("listed %v", decks)
	}
	var listed map[string]any
	for _, d := range decks {
		if d.(map[string]any)["id"] == id {
			listed = d.(map[string]any)
		}
	}
	if listed == nil || listed["slide_count"] != float64(1) || listed["cover"] == "" {
		t.Fatalf("list entry %v", listed)
	}

	if got := e.want("PATCH", "/slides/"+id, map[string]any{"title": " Q3  review "}, http.StatusOK); got["title"] != "Q3 review" {
		t.Fatalf("rename %v", got)
	}
	e.want("PATCH", "/slides/"+id, map[string]any{"title": strings.Repeat("x", 201)}, http.StatusUnprocessableEntity)

	// Saving checks the base version: a stale tab gets 409, never a silent overwrite.
	asset := e.uploaded(id, pngSized(t, 40, 30, 1))
	body["assets"] = map[string]any{asset: map[string]any{"mime": "image/png", "w": 40, "h": 30, "alt": "chart"}}
	slide := body["slides"].([]any)[0].(map[string]any)
	slide["elements"] = append(slide["elements"].([]any), map[string]any{"id": "e_img", "type": "image", "asset": asset,
		"frame": map[string]any{"x": 100, "y": 100, "w": 400, "h": 300}})
	saved := e.want("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 1, "body": encode(t, body)}, http.StatusCreated)
	if saved["seq"] != float64(2) {
		t.Fatalf("saved %v", saved)
	}
	e.want("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 1, "body": encode(t, body)}, http.StatusConflict)

	// A copy has the same slides and its own references to the same images.
	cp := e.want("POST", "/slides/"+id+"/duplicate", nil, http.StatusCreated)
	cpID, cpChat := cp["id"].(string), cp["chat_id"].(string)
	if cp["title"] != "Copy of Q3 review" || cpChat == chat {
		t.Fatalf("copy %v", cp)
	}
	cpBody, _ := e.deckBody(cpChat, cpID)
	if encode(t, cpBody) != encode(t, func() map[string]any { b, _ := e.deckBody(chat, id); return b }()) {
		t.Fatal("the copy's slides differ")
	}
	if code, b := e.image(cpID, asset); code != http.StatusOK || !bytes.Equal(b, pngSized(t, 40, 30, 1)) {
		t.Fatalf("copy's image = %d", code)
	}
	if n := len(e.slideKeys()); n != 1 {
		t.Fatalf("%d blobs for one image", n)
	}

	e.want("DELETE", "/slides/"+id, nil, http.StatusNoContent)
	e.want("GET", "/canvases/"+id, nil, http.StatusNotFound)
	e.want("DELETE", "/slides/"+id, nil, http.StatusNotFound)
	if code, _ := e.image(cpID, asset); code != http.StatusOK {
		t.Fatalf("the copy lost its image: %d", code)
	}
	for _, d := range e.want("GET", "/slides", nil, http.StatusOK)["decks"].([]any) {
		if d.(map[string]any)["id"] == id {
			t.Fatal("a deleted deck is listed")
		}
	}
}

// The chooser lists every starter with a one-slide cover, and a deck made
// from one is the starter in the chosen theme under the starter's name.
func TestDeckFromStarter(t *testing.T) {
	e := newSlidesEnv(t)
	starters := e.want("GET", "/slide-starters", nil, http.StatusOK)["starters"].([]any)
	if len(starters) != len(deck.Starters) {
		t.Fatalf("listed %v", starters)
	}
	for i, s := range starters {
		m := s.(map[string]any)
		cover, err := deck.Parse(m["cover"].(string))
		if m["key"] != deck.Starters[i].Key || m["slide_count"].(float64) < 5 || err != nil || len(cover.Slides) != 1 {
			t.Fatalf("starter %d: %v (%v)", i, m, err)
		}
	}

	d := e.want("POST", "/slides", map[string]any{"starter": "research-findings", "theme": "ocean"}, http.StatusCreated)
	if d["title"] != "Research findings" {
		t.Fatalf("created %v", d)
	}
	body, seq := e.deckBody(d["chat_id"].(string), d["id"].(string))
	fixture, _ := deck.StarterDeck("research-findings")
	if seq != 1 || len(body["slides"].([]any)) != len(fixture.Slides) || body["theme"].(map[string]any)["name"] != "Ocean" {
		t.Fatalf("deck %d %v", seq, body)
	}
	if body["slides"].([]any)[0].(map[string]any)["id"] == fixture.Slides[0].ID {
		t.Fatal("the starter's ids were kept")
	}

	titled := e.want("POST", "/slides", map[string]any{"starter": "pitch", "title": "Acme seed"}, http.StatusCreated)
	if titled["title"] != "Acme seed" {
		t.Fatalf("titled %v", titled)
	}
	e.want("POST", "/slides", map[string]any{"starter": "nope"}, http.StatusUnprocessableEntity)
	e.want("POST", "/slides", map[string]any{"starter": "dnd-recap"}, http.StatusUnprocessableEntity)
}

// Someone else's deck, and a canvas that isn't a deck, are 404 on every
// Slides route; the list shows only the person's own decks.
func TestDeckOwnerIsolation(t *testing.T) {
	e := newSlidesEnv(t)
	ctx := t.Context()
	other := e.otherUser()
	svc := &slides.Service{Pool: e.pool, Runs: e.runs}
	theirs, _, err := svc.Create(ctx, e.me.WorkspaceID, other.ID, "Theirs", "")
	if err != nil {
		t.Fatal(err)
	}
	img := pngSized(t, 8, 8, 9)
	key := fmt.Sprintf("slides/%s/%s/x", e.me.WorkspaceID, other.ID)
	if _, err := svc.AddAsset(ctx, store.CreateDeckAssetParams{CanvasID: theirs.ID, ID: "a_theirs", WorkspaceID: e.me.WorkspaceID, UserID: other.ID,
		BlobKey: key, Mime: "image/png", Width: 8, Height: 8, SizeBytes: int64(len(img))}); err != nil {
		t.Fatal(err)
	}
	doc := e.want("POST", "/docs", map[string]any{"title": "A document"}, http.StatusCreated)["id"].(string)

	for _, target := range []string{theirs.ID.String(), doc, uuid.NewString()} {
		e.want("PATCH", "/slides/"+target, map[string]any{"title": "Mine now"}, http.StatusNotFound)
		e.want("POST", "/slides/"+target+"/duplicate", nil, http.StatusNotFound)
		if code, _ := e.upload(target, img); code != http.StatusNotFound {
			t.Fatalf("upload to %s = %d", target, code)
		}
		if code, _ := e.image(target, "a_theirs"); code != http.StatusNotFound {
			t.Fatalf("image of %s = %d", target, code)
		}
		e.want("DELETE", "/slides/"+target, nil, http.StatusNotFound)
	}
	e.want("GET", "/canvases/"+theirs.ID.String(), nil, http.StatusNotFound)
	if decks := e.want("GET", "/slides", nil, http.StatusOK)["decks"].([]any); len(decks) != 0 {
		t.Fatalf("someone else's deck is listed: %v", decks)
	}
	if got, err := e.q.GetMyCanvas(ctx, store.GetMyCanvasParams{ID: theirs.ID, WorkspaceID: e.me.WorkspaceID, UserID: other.ID}); err != nil || got.Title != "Theirs" {
		t.Fatalf("their deck changed: %v %v", got, err)
	}
}

// Invalid decks are refused whole on every path that writes a version,
// including the persona's canvas_patch, and the 512 KB cap holds on each.
func TestDeckSchemaLimitsAndMalformedPatches(t *testing.T) {
	e := newSlidesEnv(t)
	id, chat := e.deck("Limits")
	body, _ := e.deckBody(chat, id)
	save := func(m map[string]any) {
		t.Helper()
		e.invalid("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 1, "body": encode(t, m)}, "body", "")
	}
	with := func(k string, v any) map[string]any {
		m := map[string]any{}
		for kk, vv := range body {
			m[kk] = vv
		}
		m[k] = v
		return m
	}
	save(with("schema", 2))
	save(with("bogus", true))
	save(with("size", map[string]any{"w": 1280, "h": 720}))
	save(with("slides", blankSlides(deck.MaxSlides+1, 0)))
	// Under the slide limit but over 512 KB of canonical JSON.
	big := with("slides", blankSlides(30, 10000))
	if n := len(encode(t, big)); n <= deck.MaxBody {
		t.Fatalf("fixture is only %d bytes", n)
	}
	save(big)
	e.invalid("POST", "/chats/"+chat+"/canvases/"+id+"/versions", map[string]any{"base_seq": 1, "body": "{not json"}, "body", "")

	// The persona's edits go through canvas_patch: malformed ops are refused,
	// and so is a patch that would take the deck past 512 KB.
	token := e.canvasToken(uuid.MustParse(chat))
	patch := func(ops ...map[string]any) map[string]any {
		return map[string]any{"canvas_id": id, "base_version": 1, "ops": ops}
	}
	e.toolInvalid(token, "canvas_patch", patch(map[string]any{"op": "explode"}), "body")
	e.toolInvalid(token, "canvas_patch", patch(map[string]any{"op": "remove_slide", "id": "s_missing"}), "body")
	e.toolInvalid(token, "canvas_patch", patch(map[string]any{"op": "insert_slide", "value": map[string]any{"layout": "blank", "bogus": 1}}), "body")
	e.toolInvalid(token, "canvas_patch", patch(map[string]any{"op": "set_theme", "value": map[string]any{"preset": "neon"}}), "body")
	e.toolInvalid(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 1, "ops": []any{}}, "ops")
	var ops []map[string]any
	for range 30 {
		ops = append(ops, map[string]any{"op": "insert_slide", "value": map[string]any{"layout": "blank", "notes": strings.Repeat("é", 10000)}})
	}
	code, out := e.tool(token, "canvas_patch", patch(ops...))
	if msg, _ := out["message"].(string); code != http.StatusUnprocessableEntity || !strings.Contains(msg, "512 KB") {
		t.Fatalf("oversized persona patch = %d %v", code, out)
	}
	if code, out := e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 7, "ops": []any{map[string]any{"op": "set_theme", "value": map[string]any{"preset": "dark"}}}}); code != http.StatusConflict {
		t.Fatalf("stale persona patch = %d %v", code, out)
	}
	// Agents can't start decks; they're made in the Slides app.
	e.toolInvalid(token, "canvas_create", map[string]any{"kind": "deck", "title": "Mine", "body": encode(t, body)}, "kind")

	// Nothing above wrote a version.
	if _, seq := e.deckBody(chat, id); seq != 1 {
		t.Fatalf("a refused edit wrote version %d", seq)
	}
	// A valid persona patch still works.
	if code, out := e.tool(token, "canvas_patch", patch(map[string]any{"op": "set_theme", "value": map[string]any{"preset": "dark"}})); code != http.StatusOK || out["version"] != float64(2) {
		t.Fatalf("persona patch = %d %v", code, out)
	}
}

// Image type comes from the bytes, and size and dimensions are capped.
func TestDeckImageChecks(t *testing.T) {
	e := newSlidesEnv(t)
	id, _ := e.deck("Images")

	gif := []byte("GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;")
	truncated := pngSized(t, 10, 10, 1)[:20]
	tooBig := append(append([]byte{}, pngSized(t, 10, 10, 1)...), make([]byte, slides.MaxAssetBytes)...)
	for name, data := range map[string][]byte{
		"empty":      nil,
		"text":       []byte("<svg xmlns='http://www.w3.org/2000/svg'/>"),
		"gif":        gif,
		"truncated":  truncated,
		"too wide":   pngSized(t, slides.MaxAssetEdge+1, 1, 1),
		"too tall":   pngSized(t, 1, slides.MaxAssetEdge+1, 1),
		"over 10 MB": tooBig,
	} {
		if code, out := e.upload(id, data); code != http.StatusUnprocessableEntity || out["field"] != "file" {
			t.Errorf("%s: %d %v", name, code, out)
		}
	}
	if keys := e.slideKeys(); len(keys) != 0 {
		t.Fatalf("refused uploads stored %v", keys)
	}

	// A JPEG is sniffed as one whatever it's called, with its real size.
	code, out := e.upload(id, avatarJPEG(t))
	if code != http.StatusCreated || out["mime"] != "image/jpeg" || out["w"] != float64(12) || out["h"] != float64(12) {
		t.Fatalf("jpeg = %d %v", code, out)
	}
	if code, out := e.upload(id, pngSized(t, slides.MaxAssetEdge, 1, 1)); code != http.StatusCreated || out["mime"] != "image/png" || out["w"] != float64(slides.MaxAssetEdge) {
		t.Fatalf("edge-sized png = %d %v", code, out)
	}
	if code, b := e.image(id, out["id"].(string)); code != http.StatusOK || !bytes.Equal(b, avatarJPEG(t)) {
		t.Fatalf("read back = %d", code)
	}
	if code, _ := e.image(id, "a_missing"); code != http.StatusNotFound {
		t.Fatalf("missing asset = %d", code)
	}
}

// The quota counts each stored image once per person: copies and repeat
// uploads of the same bytes are free, and a full Library refuses new ones.
func TestDeckImageQuotaCountsEachBlobOnce(t *testing.T) {
	e := newSlidesEnv(t)
	ctx := t.Context()
	id, _ := e.deck("Quota")
	img := pngSized(t, 20, 20, 3)
	e.uploaded(id, img)
	e.uploaded(id, img)
	e.want("POST", "/slides/"+id+"/duplicate", nil, http.StatusCreated)
	used := func() int64 {
		t.Helper()
		n, err := e.q.DeckAssetBytes(ctx, store.DeckAssetBytesParams{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID})
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	if got := used(); got != int64(len(img)) {
		t.Fatalf("used %d, want %d", got, len(img))
	}

	// Fill the Library to the byte.
	if _, err := e.pool.Exec(ctx, `INSERT INTO deck_assets (canvas_id, id, workspace_id, user_id, blob_key, mime, width, height, size_bytes)
		VALUES ($1, 'a_filler', $2, $3, 'slides/filler', 'image/png', 1, 1, $4)`, id, e.me.WorkspaceID, e.me.ID, runs.MaxGeneratedImageStorageBytes-int64(len(img))); err != nil {
		t.Fatal(err)
	}
	if code, out := e.upload(id, pngSized(t, 20, 20, 4)); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "full") {
		t.Fatalf("over quota = %d %v", code, out)
	}
	other, _ := e.deck("Other")
	e.uploaded(other, img) // already stored: costs nothing
	if got := used(); got != runs.MaxGeneratedImageStorageBytes {
		t.Fatalf("used %d", got)
	}
}

// The sweep deletes a released image only when no deck uses it any more:
// copies and later uploads of the same image keep it, the delay protects
// recent releases, and another person's images are never touched.
func TestDeckImageSweep(t *testing.T) {
	e := newSlidesEnv(t)
	ctx := t.Context()
	img := pngSized(t, 16, 16, 5)
	a, _ := e.deck("A")
	asset := e.uploaded(a, img)
	b := e.want("POST", "/slides/"+a+"/duplicate", nil, http.StatusCreated)["id"].(string)
	key := e.slideKeys()
	if len(key) != 1 {
		t.Fatalf("keys %v", key)
	}

	// Someone else's identical image is a separate blob under their prefix.
	other := e.otherUser()
	svc := &slides.Service{Pool: e.pool, Runs: e.runs}
	theirs, _, err := svc.Create(ctx, e.me.WorkspaceID, other.ID, "Theirs", "")
	if err != nil {
		t.Fatal(err)
	}
	theirKey := fmt.Sprintf("slides/%s/%s/%x", e.me.WorkspaceID, other.ID, "same")
	if _, err := svc.AddAsset(ctx, store.CreateDeckAssetParams{CanvasID: theirs.ID, ID: "a_theirs", WorkspaceID: e.me.WorkspaceID, UserID: other.ID,
		BlobKey: theirKey, Mime: "image/png", Width: 16, Height: 16, SizeBytes: int64(len(img))}); err != nil {
		t.Fatal(err)
	}
	e.s3.put(avatarBucket+"/"+theirKey, img, "image/png")

	// Deleting A queues the blob, but B still uses it.
	e.want("DELETE", "/slides/"+a, nil, http.StatusNoContent)
	if q := e.queued(); len(q) != 1 {
		t.Fatalf("queued %v", q)
	}
	if n, err := e.sweep(); err != nil || n != 0 {
		t.Fatalf("sweep = %d %v", n, err)
	}
	if code, _ := e.image(b, asset); code != http.StatusOK || len(e.queued()) != 0 {
		t.Fatalf("copy's image = %d, queued %v", code, e.queued())
	}

	// Deleting B's chat (not the deck route) releases it too; a recent release
	// waits out the delay.
	bChat := e.want("GET", "/canvases/"+b, nil, http.StatusOK)["chat_id"].(string)
	e.want("DELETE", "/chats/"+bChat, nil, http.StatusNoContent)
	if n, err := slides.SweepBlobs(ctx, e.pool, e.blobs, avatarBucket, time.Now().Add(-slides.BlobSweepDelay), 100); err != nil || n != 0 {
		t.Fatalf("early sweep = %d %v", n, err)
	}
	// Uploading the same image again before the sweep takes the blob back.
	c, _ := e.deck("C")
	cAsset := e.uploaded(c, img)
	if n, err := e.sweep(); err != nil || n != 0 {
		t.Fatalf("sweep with a live re-upload = %d %v", n, err)
	}
	if code, got := e.image(c, cAsset); code != http.StatusOK || !bytes.Equal(got, img) {
		t.Fatalf("re-uploaded image = %d", code)
	}

	// Once nothing uses it, the blob goes, and only it.
	e.want("DELETE", "/slides/"+c, nil, http.StatusNoContent)
	if n, err := e.sweep(); err != nil || n != 1 {
		t.Fatalf("sweep = %d %v", n, err)
	}
	if keys := e.slideKeys(); len(keys) != 1 || keys[0] != avatarBucket+"/"+theirKey {
		t.Fatalf("left %v", keys)
	}
	if q := e.queued(); len(q) != 0 {
		t.Fatalf("still queued %v", q)
	}
	if n, err := e.sweep(); err != nil || n != 0 {
		t.Fatalf("second sweep = %d %v", n, err)
	}
}

// A failed blob write leaves no row and queues its key; a failed delete
// stays queued and a later sweep finishes it.
func TestDeckImagePartialFailures(t *testing.T) {
	e := newSlidesEnv(t)
	ctx := t.Context()
	id, _ := e.deck("Failures")
	img := pngSized(t, 10, 10, 6)

	e.s3.failPut.Store(true)
	if code, _ := e.upload(id, img); code < 500 {
		t.Fatalf("upload with a failing store = %d", code)
	}
	e.s3.failPut.Store(false)
	if rows, _ := e.q.ListDeckAssets(ctx, uuid.MustParse(id)); len(rows) != 0 {
		t.Fatalf("a failed upload kept rows %v", rows)
	}
	if q := e.queued(); len(q) != 1 {
		t.Fatalf("queued %v", q)
	}
	if n, err := e.sweep(); err != nil || n != 1 {
		t.Fatalf("sweep after failed upload = %d %v", n, err)
	}

	e.uploaded(id, img)
	e.want("DELETE", "/slides/"+id, nil, http.StatusNoContent)
	e.s3.failDelete.Store(true)
	if n, err := e.sweep(); err == nil || n != 0 {
		t.Fatalf("sweep with a failing store = %d %v", n, err)
	}
	if q := e.queued(); len(q) != 1 || len(e.slideKeys()) != 1 {
		t.Fatalf("after a failed delete: queued %v, stored %v", q, e.slideKeys())
	}
	e.s3.failDelete.Store(false)
	if n, err := e.sweep(); err != nil || n != 1 || len(e.slideKeys()) != 0 || len(e.queued()) != 0 {
		t.Fatalf("retry = %d %v, stored %v", n, err, e.slideKeys())
	}
}

// An upload waits while the sweep holds the blob's lock (mid-delete), so it
// either lands its row first (and the sweep keeps the blob) or writes the
// blob after the sweep has deleted it.
func TestDeckImageUploadWaitsForSweepLock(t *testing.T) {
	e := newSlidesEnv(t)
	ctx := t.Context()
	id, _ := e.deck("Race")
	img := pngSized(t, 10, 10, 7)
	key := fmt.Sprintf("slides/%s/%s/%x", e.me.WorkspaceID, e.me.ID, sha256.Sum256(img))

	tx, err := e.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// Registered after the database's cleanup, so it runs first: a failure
	// below must not leave the transaction holding the pool open.
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	if err := store.New(tx).LockDeckBlob(ctx, key); err != nil {
		t.Fatal(err)
	}
	done := make(chan int, 1)
	go func() {
		code, _ := e.upload(id, img)
		done <- code
	}()
	select {
	case code := <-done:
		t.Fatalf("upload finished (%d) while the sweep held the lock", code)
	case <-time.After(300 * time.Millisecond):
	}
	// The sweep deletes the blob and lets go; the upload then rewrites it.
	_ = e.blobs.Delete(ctx, avatarBucket, key)
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case code := <-done:
		if code != http.StatusCreated {
			t.Fatalf("upload = %d", code)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("upload never finished")
	}
	if keys := e.slideKeys(); len(keys) != 1 {
		t.Fatalf("stored %v", keys)
	}
	if n, err := e.sweep(); err != nil || n != 0 {
		t.Fatalf("sweep = %d %v", n, err)
	}
}

// Migrations 00098 and 00097 roll back cleanly from a database with decks in
// use, losing only Slides data (by design), and apply again afterwards.
func TestSlidesMigrationsRollBackAndReapply(t *testing.T) {
	e := newSlidesEnv(t)
	ctx := t.Context()
	id, chat := e.deck("Doomed")
	e.uploaded(id, pngSized(t, 10, 10, 8))
	e.want("POST", "/slides/"+id+"/duplicate", nil, http.StatusCreated)
	e.canvasToken(uuid.MustParse(chat)) // a persona turn: the deck's chat has a run
	doc := e.want("POST", "/docs", map[string]any{"title": "Kept"}, http.StatusCreated)["id"].(string)
	count := func(sql string, args ...any) int {
		t.Helper()
		var n int
		if err := e.pool.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
		return n
	}
	chatsBefore := count(`SELECT count(*) FROM chat_sessions`)
	deckChats := count(`SELECT count(*) FROM chat_sessions c JOIN chat_spaces s ON s.id = c.space_id WHERE s.app = 'slides'`)
	if deckChats != 2 {
		t.Fatalf("%d deck chats", deckChats)
	}

	sqldb := stdlib.OpenDBFromPool(e.pool)
	defer sqldb.Close()
	if err := goose.DownToContext(ctx, sqldb, ".", 96); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"deck_assets", "deck_blob_sweep"} {
		if n := count(`SELECT count(*) FROM pg_tables WHERE tablename = $1`, table); n != 0 {
			t.Fatalf("%s survived the rollback", table)
		}
	}
	if n := count(`SELECT count(*) FROM chat_canvases WHERE kind = 'deck'`); n != 0 {
		t.Fatalf("%d decks survived", n)
	}
	if n := count(`SELECT count(*) FROM chat_spaces WHERE app = 'slides'`); n != 0 {
		t.Fatalf("%d Slides spaces survived", n)
	}
	if got := count(`SELECT count(*) FROM chat_sessions`); got != chatsBefore-deckChats {
		t.Fatalf("%d chats after rollback, want %d", got, chatsBefore-deckChats)
	}
	if n := count(`SELECT count(*) FROM chat_canvases WHERE id = $1`, doc); n != 1 {
		t.Fatal("the rollback deleted a document")
	}
	if _, err := e.pool.Exec(ctx, `UPDATE chat_canvases SET kind = 'deck' WHERE id = $1`, doc); err == nil {
		t.Fatal("kind 'deck' is still allowed after the rollback")
	}

	if err := goose.UpContext(ctx, sqldb, "."); err != nil {
		t.Fatal(err)
	}
	id, _ = e.deck("Again")
	e.uploaded(id, pngSized(t, 10, 10, 8))
	e.want("DELETE", "/slides/"+id, nil, http.StatusNoContent)
	if q := e.queued(); len(q) != 1 {
		t.Fatalf("queued after reapplying: %v", q)
	}
}

// The sweep against a local-directory store: a released image shared with a
// copy survives, and is deleted from storage once nothing uses it.
func TestDeckImageSweepRealStore(t *testing.T) {
	const bucket = "test-artifacts"
	blobs := blob.New(config.Blob{Dir: t.TempDir(), Buckets: []string{bucket}})
	ctx := t.Context()
	if err := blobs.EnsureBuckets(ctx); err != nil {
		t.Fatal(err)
	}
	e := &slidesEnv{chatEnv: newChatEnvServer(t, nil, func(s *Server) { s.Blobs, s.ArtifactBucket = blobs, bucket }), blobs: blobs}
	img := pngSized(t, 12, 12, byte(time.Now().UnixNano()))
	id, _ := e.deck("Real")
	asset := e.uploaded(id, img)
	cp := e.want("POST", "/slides/"+id+"/duplicate", nil, http.StatusCreated)["id"].(string)
	key := fmt.Sprintf("slides/%s/%s/%x", e.me.WorkspaceID, e.me.ID, sha256.Sum256(img))
	sweep := func() int {
		t.Helper()
		n, err := slides.SweepBlobs(ctx, e.pool, blobs, bucket, time.Now().Add(time.Minute), 100)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}

	e.want("DELETE", "/slides/"+id, nil, http.StatusNoContent)
	if n := sweep(); n != 0 {
		t.Fatalf("swept %d while the copy uses the image", n)
	}
	if code, b := e.image(cp, asset); code != http.StatusOK || !bytes.Equal(b, img) {
		t.Fatalf("copy's image = %d", code)
	}
	e.want("DELETE", "/slides/"+cp, nil, http.StatusNoContent)
	if n := sweep(); n != 1 {
		t.Fatalf("swept %d, want 1", n)
	}
	if _, err := blobs.Get(ctx, bucket, key); !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("blob after sweep: %v", err)
	}
}

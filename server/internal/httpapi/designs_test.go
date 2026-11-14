package httpapi

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/canvas"
	"github.com/liamphmurphy/vesper/server/internal/design"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const designFixtures = "../../../web/lib/designs/fixtures"

type designsEnv struct{ *slidesEnv }

func newDesignsEnv(t *testing.T) *designsEnv { return &designsEnv{newSlidesEnv(t)} }

func (e *designsEnv) svc() *designs.Service { return &designs.Service{Pool: e.pool, Runs: e.runs} }

// design creates a design and returns its id and chat id.
func (e *designsEnv) design(body map[string]any) (id, chat string) {
	e.t.Helper()
	d := e.want("POST", "/designs", body, http.StatusCreated)
	if d["kind"] != "design" {
		e.t.Fatalf("kind %v", d["kind"])
	}
	return d["id"].(string), d["chat_id"].(string)
}

// current is a design's current version and body.
func (e *designsEnv) current(id string) (int, map[string]any) {
	e.t.Helper()
	seq := int(e.want("GET", "/designs/"+id, nil, http.StatusOK)["seq"].(float64))
	v := e.want("GET", fmt.Sprintf("/designs/%s/versions/%d", id, seq), nil, http.StatusOK)
	var body map[string]any
	if err := json.Unmarshal([]byte(v["body"].(string)), &body); err != nil {
		e.t.Fatal(err)
	}
	return seq, body
}

func (e *designsEnv) minimal() map[string]any {
	e.t.Helper()
	raw, err := os.ReadFile(designFixtures + "/valid-minimal.json")
	if err != nil {
		e.t.Fatal(err)
	}
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	return m
}

func (e *designsEnv) save(id string, base int, body map[string]any) (int, map[string]any) {
	e.t.Helper()
	return e.do("POST", "/designs/"+id+"/versions", map[string]any{"base_seq": base, "body": encode(e.t, body)})
}

func (e *designsEnv) uploadTo(path string, data []byte) (int, map[string]any) {
	e.t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	pw, _ := mw.CreateFormFile("file", "image.bin")
	pw.Write(data)
	mw.Close()
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/v1"+path, &body)
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

func (e *designsEnv) agentOf(chat string) uuid.UUID {
	e.t.Helper()
	var agent uuid.UUID
	if err := e.pool.QueryRow(e.t.Context(), `SELECT agent_id FROM chat_sessions WHERE id = $1`, chat).Scan(&agent); err != nil {
		e.t.Fatal(err)
	}
	return agent
}

func (e *designsEnv) count(sql string, args ...any) int {
	e.t.Helper()
	var n int
	if err := e.pool.QueryRow(e.t.Context(), sql, args...).Scan(&n); err != nil {
		e.t.Fatalf("%s: %v", sql, err)
	}
	return n
}

// A design is created (blank and from a starter), listed, read, renamed,
// saved against its current version (409 when stale), duplicated with fresh
// ids and its images, and deleted with its images queued for the sweep.
func TestDesignLifecycle(t *testing.T) {
	e := newDesignsEnv(t)
	blank, _ := e.design(map[string]any{})
	id, _ := e.design(map[string]any{"title": "  Checkout  flow ", "starter": "mobile-flow"})

	list := e.want("GET", "/designs", nil, http.StatusOK)["designs"].([]any)
	if len(list) != 2 {
		t.Fatalf("list: %v", list)
	}
	first := list[0].(map[string]any)
	if first["id"] != id || first["title"] != "Checkout flow" || first["pages"] != 1.0 || first["frames"] != 3.0 || first["pending_proposals"] != 0.0 ||
		first["seq"] != 1.0 || first["persona_edited"] != false {
		t.Fatalf("summary: %v", first)
	}
	if got := e.want("GET", "/designs/"+blank, nil, http.StatusOK); got["title"] != designs.UntitledTitle || got["settings"].(map[string]any)["direct_edit"] != false {
		t.Fatalf("blank: %v", got)
	}
	e.invalid("POST", "/designs", map[string]any{"starter": "poster"}, "starter", "use one of")

	e.want("PATCH", "/designs/"+id, map[string]any{"title": "Checkout"}, http.StatusOK)

	// Save: the person's edit, against the current version.
	seq, _ := e.current(id)
	body := e.minimal()
	body["pages"].([]any)[0].(map[string]any)["children"].([]any)[0].(map[string]any)["linked_tickets"] = []any{e.payKey, "NOPE-1"}
	if code, out := e.save(id, seq, body); code != http.StatusCreated || out["seq"] != float64(seq+1) || out["author_type"] != "user" {
		t.Fatalf("save = %d %v", code, out)
	}
	if code, _ := e.save(id, seq, body); code != http.StatusConflict {
		t.Fatalf("stale save = %d, want 409", code)
	}
	if n := e.count(`SELECT count(*) FROM design_frame_links WHERE canvas_id = $1 AND node_id = 'n_home'`, id); n != 1 {
		t.Fatalf("%d frame links, want the PAY ticket's only", n)
	}
	bad := e.minimal()
	bad["pages"].([]any)[0].(map[string]any)["children"].([]any)[0].(map[string]any)["shadow"] = 4
	if code, out := e.save(id, seq+1, bad); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "unknown field shadow") {
		t.Fatalf("invalid save = %d %v", code, out)
	}
	e.want("GET", fmt.Sprintf("/designs/%s/versions/%d", id, seq+5), nil, http.StatusNotFound)

	// An image, then a copy with fresh ids that shares it.
	code, a := e.uploadTo("/designs/"+id+"/assets", pngSized(t, 10, 10, 1))
	if code != http.StatusCreated {
		t.Fatalf("upload = %d %v", code, a)
	}
	if keys := e.s3.keys(avatarBucket + "/designs/"); len(keys) != 1 {
		t.Fatalf("blobs: %v", keys)
	}
	cp := e.want("POST", "/designs/"+id+"/duplicate", nil, http.StatusCreated)["id"].(string)
	_, copied := e.current(cp)
	if strings.Contains(encode(t, copied), `"n_home"`) {
		t.Fatal("the copy kept the original's ids")
	}
	if res, err := http.Get(e.srv.URL + "/api/v1/designs/" + cp + "/assets/" + a["id"].(string)); err != nil || res.StatusCode != http.StatusOK {
		t.Fatalf("copy's image: %v %v", res.StatusCode, err)
	}

	e.want("DELETE", "/designs/"+id, nil, http.StatusNoContent)
	e.want("GET", "/designs/"+id, nil, http.StatusNotFound)
	if n, err := e.sweep(); err != nil || n != 0 {
		t.Fatalf("swept %d (%v) while the copy uses the image", n, err)
	}
	e.want("DELETE", "/designs/"+cp, nil, http.StatusNoContent)
	if n, err := e.sweep(); err != nil || n != 1 {
		t.Fatalf("swept %d (%v), want the released image", n, err)
	}
}

// Deleting a chat-created design must not delete the conversation or siblings,
// even in an app space. A general chat survives deletion of its last canvas too.
func TestDesignDeletePreservesSharedChat(t *testing.T) {
	for _, appSpace := range []bool{false, true} {
		t.Run(fmt.Sprintf("appSpace=%v", appSpace), func(t *testing.T) {
			e := newDesignsEnv(t)
			ctx := t.Context()
			var chat store.ChatSession
			var first store.ChatCanvas
			var err error
			if appSpace {
				first, chat, err = e.svc().Create(ctx, e.me.WorkspaceID, e.me.ID, "First", "", "")
			} else {
				chat, err = e.runs.StartChat(ctx, e.me.WorkspaceID, e.me.ID, runs.ChatInput{Title: "Longstanding conversation"})
				if err == nil {
					first, _, err = e.svc().CreateInChat(ctx, e.me.WorkspaceID, chat, "First", "", "", canvas.Actor{Type: "user", ID: e.me.ID}, nil, nil)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, err := e.pool.Exec(ctx, `INSERT INTO chat_messages (session_id, seq, role, body_md) VALUES ($1, 1, 'user', 'Keep this conversation')`, chat.ID); err != nil {
				t.Fatal(err)
			}
			second, _, err := e.svc().CreateInChat(ctx, e.me.WorkspaceID, chat, "Second", "", "", canvas.Actor{Type: "user", ID: e.me.ID}, nil, nil)
			if err != nil {
				t.Fatal(err)
			}
			e.want("DELETE", "/designs/"+first.ID.String(), nil, http.StatusNoContent)
			e.want("GET", "/designs/"+first.ID.String(), nil, http.StatusNotFound)
			e.want("GET", "/designs/"+second.ID.String(), nil, http.StatusOK)
			if n := e.count(`SELECT count(*) FROM chat_canvas_versions WHERE canvas_id = $1`, first.ID); n != 0 {
				t.Fatalf("deleted design kept %d versions", n)
			}
			if n := e.count(`SELECT count(*) FROM chat_sessions WHERE id = $1`, chat.ID); n != 1 {
				t.Fatal("shared conversation deleted")
			}
			if n := e.count(`SELECT count(*) FROM chat_messages WHERE session_id = $1 AND body_md = 'Keep this conversation'`, chat.ID); n != 1 {
				t.Fatal("conversation message deleted")
			}
			if !appSpace {
				e.want("DELETE", "/designs/"+second.ID.String(), nil, http.StatusNoContent)
				if n := e.count(`SELECT count(*) FROM chat_sessions WHERE id = $1`, chat.ID); n != 1 {
					t.Fatal("general chat deleted with its last design")
				}
			}
		})
	}
}

func TestDesignDeleteDedicatedChat(t *testing.T) {
	e := newDesignsEnv(t)
	id, chat := e.design(map[string]any{})
	e.want("DELETE", "/designs/"+id, nil, http.StatusNoContent)
	if n := e.count(`SELECT count(*) FROM chat_sessions WHERE id = $1`, chat); n != 0 {
		t.Fatal("dedicated design chat survived")
	}
}

// Designs get a 2 MB body cap; documents keep 512 KB.
func TestDesignBodyCap(t *testing.T) {
	e := newDesignsEnv(t)
	id, chat := e.design(map[string]any{})
	big := e.minimal()
	next := big["pages"].([]any)[0].(map[string]any)["children"].([]any)[1].(map[string]any)
	sticky := func(i, chars int) map[string]any {
		return map[string]any{"id": fmt.Sprintf("n_s%d", i), "type": "sticky", "x": 0, "y": 0, "w": 10, "h": 10, "text": strings.Repeat("x", chars)}
	}
	var kids []any
	for i := range 400 { // ~800 KB: over a document's cap, under a design's
		kids = append(kids, sticky(i, 2000))
	}
	next["children"] = kids
	if code, out := e.save(id, 1, big); code != http.StatusCreated {
		t.Fatalf("800 KB save = %d %v", code, out)
	}
	for i := 400; i < 1100; i++ { // ~2.2 MB
		kids = append(kids, sticky(i, 2000))
	}
	next["children"] = kids
	if code, out := e.save(id, 2, big); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "2048 KB") {
		t.Fatalf("2.2 MB save = %d %v", code, out)
	}

	// A patch whose result goes over the cap is refused too.
	svc := canvas.Service{Pool: e.pool}
	var ops []canvas.Op
	for i := range 100 {
		ops = append(ops, canvas.Op{Op: "add_node", Value: map[string]any{"parent": "n_next", "node": sticky(2000+i, 2000)}})
	}
	_, err := svc.Patch(t.Context(), uuid.MustParse(chat), uuid.MustParse(id), 2, ops, "", canvas.Actor{Type: "user", ID: e.me.ID})
	if err == nil {
		// 100 more stickies is ~200 KB; reach the cap with a few rounds.
		for seq := int32(3); err == nil && seq < 20; seq++ {
			for i := range ops {
				ops[i].Value["node"].(map[string]any)["id"] = fmt.Sprintf("n_r%d_%d", seq, i)
			}
			_, err = svc.Patch(t.Context(), uuid.MustParse(chat), uuid.MustParse(id), seq, ops, "", canvas.Actor{Type: "user", ID: e.me.ID})
		}
	}
	if err == nil || !strings.Contains(err.Error(), "2048 KB") {
		t.Fatalf("patch over the cap: %v", err)
	}
}

// canvas.Patch applies design ops against the current version only.
func TestDesignPatchStaleBase(t *testing.T) {
	e := newDesignsEnv(t)
	id, chat := e.design(map[string]any{})
	e.save(id, 1, e.minimal())
	svc := canvas.Service{Pool: e.pool}
	ops := []canvas.Op{{Op: "set_node", ID: "n_box", Value: map[string]any{"fields": map[string]any{"name": "Box"}}}}
	if _, err := svc.Patch(t.Context(), uuid.MustParse(chat), uuid.MustParse(id), 1, ops, "", canvas.Actor{Type: "user", ID: e.me.ID}); !isConflict(err) {
		t.Fatalf("stale patch: %v", err)
	}
	v, err := svc.Patch(t.Context(), uuid.MustParse(chat), uuid.MustParse(id), 2, ops, "", canvas.Actor{Type: "user", ID: e.me.ID})
	if err != nil || v.Seq != 3 || !strings.Contains(v.Body, `"name":"Box"`) {
		t.Fatalf("patch: %v %v", v.Seq, err)
	}
}

func isConflict(err error) bool {
	var c *apperr.ConflictError
	return errors.As(err, &c)
}

// Another person's design is 404 on every endpoint, as is a canvas that
// isn't a design.
func TestDesignOwnerIsolation(t *testing.T) {
	e := newDesignsEnv(t)
	ctx := t.Context()
	other := e.otherUser()
	theirs, chat, err := e.svc().Create(ctx, e.me.WorkspaceID, other.ID, "Theirs", "diagram", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc().AddAsset(ctx, store.CreateDesignAssetParams{CanvasID: theirs.ID, ID: "a_theirs", WorkspaceID: e.me.WorkspaceID, UserID: other.ID,
		BlobKey: "designs/x", Mime: "image/png", Width: 1, Height: 1, SizeBytes: 1}); err != nil {
		t.Fatal(err)
	}
	p, err := e.svc().Propose(ctx, designs.Patch{CanvasID: theirs.ID, ChatID: chat.ID, AgentID: chat.AgentID, Base: 1, Summary: "x",
		Ops: []design.Op{{"op": "add_page", "page": map[string]any{"name": "More"}, "why": "room"}}})
	if err != nil {
		t.Fatal(err)
	}
	doc := e.want("POST", "/docs", map[string]any{"title": "A doc"}, http.StatusCreated)["id"].(string)
	for _, target := range []string{theirs.ID.String(), doc} {
		for _, r := range []struct {
			method, path string
			body         any
		}{
			{"GET", "", nil},
			{"PATCH", "", map[string]any{"title": "Mine"}},
			{"DELETE", "", nil},
			{"POST", "/duplicate", nil},
			{"GET", "/versions/1", nil},
			{"POST", "/versions", map[string]any{"base_seq": 1, "body": "{}"}},
			{"PATCH", "/settings", map[string]any{"direct_edit": true}},
			{"GET", "/proposals", nil},
			{"POST", "/proposals/" + p.Proposal.ID.String() + "/resolve", map[string]any{"decisions": []any{map[string]any{"i": 0, "state": "accepted"}}}},
			{"GET", "/assets/a_theirs", nil},
		} {
			if code, out := e.do(r.method, "/designs/"+target+r.path, r.body); code != http.StatusNotFound {
				t.Errorf("%s %s on %s = %d %v, want 404", r.method, r.path, target, code, out)
			}
		}
		if code, _ := e.uploadTo("/designs/"+target+"/assets", pngSized(t, 4, 4, 1)); code != http.StatusNotFound {
			t.Errorf("upload to %s = %d", target, code)
		}
	}
	if list := e.want("GET", "/designs", nil, http.StatusOK)["designs"].([]any); len(list) != 0 {
		t.Fatalf("listed someone else's design: %v", list)
	}
	if got, err := e.q.GetMyCanvas(ctx, store.GetMyCanvasParams{ID: theirs.ID, WorkspaceID: e.me.WorkspaceID, UserID: other.ID}); err != nil || got.Title != "Theirs" {
		t.Fatalf("their design changed: %v %v", got, err)
	}
}

// A persona's patch is held as a pending proposal (the design untouched);
// the person accepts some ops and rejects others with a reason, and the
// accepted ones are applied on the current version as one new version.
func TestDesignProposalReview(t *testing.T) {
	e := newDesignsEnv(t)
	ctx := t.Context()
	id, chat := e.design(map[string]any{})
	e.save(id, 1, e.minimal())
	agent := e.agentOf(chat)
	patch := func(base int32, ops ...design.Op) (designs.Proposed, error) {
		return e.svc().Propose(ctx, designs.Patch{CanvasID: uuid.MustParse(id), ChatID: uuid.MustParse(chat), AgentID: agent, Base: base, Summary: "Tidy the flow", Ops: ops})
	}

	if _, err := patch(2, design.Op{"op": "set_node", "id": "n_box", "fields": map[string]any{"name": "x"}}); err == nil || !strings.Contains(err.Error(), "why") {
		t.Fatalf("an op without why: %v", err)
	}
	if _, err := patch(1, design.Op{"op": "set_node", "id": "n_box", "fields": map[string]any{"name": "x"}, "why": "w"}); !isConflict(err) {
		t.Fatalf("stale base: %v", err)
	}
	if _, err := patch(2, design.Op{"op": "remove_node", "id": "n_nope", "why": "w"}); err == nil || !strings.Contains(err.Error(), "op 0") {
		t.Fatalf("an op that doesn't apply: %v", err)
	}

	got, err := patch(2,
		design.Op{"op": "set_node", "id": "n_box", "fields": map[string]any{"fill": "$surface"}, "why": "use the token"},
		design.Op{"op": "add_node", "parent": "n_next", "node": map[string]any{"type": "text", "x": 0, "y": 0, "w": 100, "h": 20,
			"paragraphs": []any{map[string]any{"runs": []any{map[string]any{"text": "Promo code", "size": 14}}}}}, "why": "promo field"},
		design.Op{"op": "set_node", "id": "n_title", "fields": map[string]any{"name": "Heading"}, "why": "clearer layer name"},
	)
	if err != nil || got.Version != nil || got.Proposal.Status != "pending" {
		t.Fatalf("propose: %+v %v", got, err)
	}
	if seq, body := e.current(id); seq != 2 || strings.Contains(encode(t, body), "Promo") {
		t.Fatal("a suggestion changed the design")
	}
	ps := e.want("GET", "/designs/"+id+"/proposals?status=pending", nil, http.StatusOK)["proposals"].([]any)
	if len(ps) != 1 {
		t.Fatalf("proposals: %v", ps)
	}
	listed := ps[0].(map[string]any)
	added := listed["ops"].([]any)[1].(map[string]any)["node"].(map[string]any)["id"].(string)
	if !strings.HasPrefix(added, "n_") {
		t.Fatalf("the server didn't mint the new node's id: %v", listed["ops"])
	}
	if e.want("GET", "/designs/"+id, nil, http.StatusOK)["pending_proposals"] != 1.0 {
		t.Fatal("pending count")
	}
	pid := got.Proposal.ID.String()
	resolve := func(ds ...map[string]any) (int, map[string]any) {
		list := make([]any, len(ds))
		for i, d := range ds {
			list[i] = d
		}
		return e.do("POST", "/designs/"+id+"/proposals/"+pid+"/resolve", map[string]any{"decisions": list})
	}
	if code, out := resolve(map[string]any{"i": 0, "state": "accepted"}); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "decide op 1") {
		t.Fatalf("missing decisions: %d %v", code, out)
	}

	// Meanwhile the person removes the node op 2 renames: that op goes stale.
	_, body := e.current(id)
	frame := body["pages"].([]any)[0].(map[string]any)["children"].([]any)[0].(map[string]any)
	frame["children"] = frame["children"].([]any)[1:]
	if code, out := e.save(id, 2, body); code != http.StatusCreated {
		t.Fatalf("save: %d %v", code, out)
	}

	code, out := resolve(
		map[string]any{"i": 0, "state": "accepted"},
		map[string]any{"i": 1, "state": "rejected", "reason": "promo codes belong on Cart"},
		map[string]any{"i": 2, "state": "accepted"},
	)
	if code != http.StatusOK {
		t.Fatalf("resolve = %d %v", code, out)
	}
	v := out["version"].(map[string]any)
	if v["seq"] != 4.0 || v["author_type"] != "user" || v["note"] != "Accepted 1 of 3 suggested changes" {
		t.Fatalf("version: %v", v)
	}
	if !strings.Contains(v["body"].(string), `"fill":"$surface"`) || strings.Contains(v["body"].(string), "Promo") || !strings.Contains(v["body"].(string), "n_pic") {
		t.Fatal("the version doesn't hold exactly the accepted op on top of the person's edit")
	}
	p := out["proposal"].(map[string]any)
	ds := p["decisions"].([]any)
	if p["status"] != "resolved" || p["result_seq"] != 4.0 || ds[0].(map[string]any)["state"] != "accepted" ||
		ds[1].(map[string]any)["reason"] != "promo codes belong on Cart" || ds[2].(map[string]any)["state"] != "stale" {
		t.Fatalf("proposal: %v", p)
	}
	if code, _ := resolve(map[string]any{"i": 0, "state": "accepted"}, map[string]any{"i": 1, "state": "accepted"}, map[string]any{"i": 2, "state": "accepted"}); code != http.StatusConflict {
		t.Fatalf("resolving twice = %d", code)
	}
	if mine := e.want("GET", "/canvases/"+id, nil, http.StatusOK); mine["reviewed_seq"] != 4.0 {
		t.Fatalf("reviewed_seq %v", mine["reviewed_seq"])
	}

	// An op needing one the person rejected can't be accepted.
	got, err = patch(4,
		design.Op{"op": "add_node", "parent": "p_flows", "node": map[string]any{"id": "n_new", "type": "frame", "x": 900, "y": 0, "w": 10, "h": 10, "children": []any{}}, "why": "a new screen"},
		design.Op{"op": "add_link", "from": "n_box", "to": "n_new", "why": "go there"},
	)
	if err != nil {
		t.Fatal(err)
	}
	pid = got.Proposal.ID.String()
	if code, out := resolve(map[string]any{"i": 0, "state": "rejected"}, map[string]any{"i": 1, "state": "accepted"}); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "op 1 needs op 0") {
		t.Fatalf("dependent accept: %d %v", code, out)
	}
	if code, out := resolve(map[string]any{"i": 0, "state": "rejected", "reason": "no"}, map[string]any{"i": 1, "state": "rejected"}); code != http.StatusOK || out["version"] != nil {
		t.Fatalf("reject all = %d %v", code, out)
	}
}

// With direct edit on, a persona patch applies at once as a version by the
// persona and is recorded as applied; paused, it's refused.
func TestDesignDirectEditAndPause(t *testing.T) {
	e := newDesignsEnv(t)
	ctx := t.Context()
	id, chat := e.design(map[string]any{})
	e.save(id, 1, e.minimal())
	agent := e.agentOf(chat)
	patch := func(base int32) (designs.Proposed, error) {
		return e.svc().Propose(ctx, designs.Patch{CanvasID: uuid.MustParse(id), ChatID: uuid.MustParse(chat), AgentID: agent, Base: base, Summary: "Rename",
			Ops: []design.Op{{"op": "set_node", "id": "n_box", "fields": map[string]any{"name": fmt.Sprintf("Box %d", base)}, "why": "clearer"}}})
	}
	st := e.want("PATCH", "/designs/"+id+"/settings", map[string]any{"direct_edit": true}, http.StatusOK)
	if st["direct_edit"] != true || st["persona_paused"] != false {
		t.Fatalf("settings: %v", st)
	}
	got, err := patch(2)
	if err != nil || got.Version == nil || got.Version.Seq != 3 || got.Version.AuthorType != "agent" || got.Proposal.Status != "applied" || *got.Proposal.ResultSeq != 3 {
		t.Fatalf("direct edit: %+v %v", got, err)
	}
	if _, body := e.current(id); !strings.Contains(encode(t, body), `"Box 2"`) {
		t.Fatal("the patch didn't apply")
	}
	if list := e.want("GET", "/designs", nil, http.StatusOK)["designs"].([]any); list[0].(map[string]any)["persona_edited"] != true || list[0].(map[string]any)["seq"] != 3.0 {
		t.Fatalf("a persona's version: %v", list[0])
	}
	if _, err := patch(2); !isConflict(err) {
		t.Fatalf("stale direct edit: %v", err)
	}

	e.want("PATCH", "/designs/"+id+"/settings", map[string]any{"direct_edit": false}, http.StatusOK)
	if got, err := patch(3); err != nil || got.Version != nil || got.Proposal.Status != "pending" {
		t.Fatalf("direct edit off: %+v %v", got, err)
	}
	e.want("PATCH", "/designs/"+id+"/settings", map[string]any{"persona_paused": true}, http.StatusOK)
	if _, err := patch(3); !isConflict(err) || !strings.Contains(err.Error(), "paused") {
		t.Fatalf("paused: %v", err)
	}
	if n := e.count(`SELECT count(*) FROM design_proposals WHERE canvas_id = $1`, id); n != 2 {
		t.Fatalf("%d proposals", n)
	}
}

func TestDesignImageChecks(t *testing.T) {
	e := newDesignsEnv(t)
	id, _ := e.design(map[string]any{})
	if code, out := e.uploadTo("/designs/"+id+"/assets", pngSized(t, 4097, 2, 1)); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "4096") {
		t.Fatalf("oversized image = %d %v", code, out)
	}
	if code, _ := e.uploadTo("/designs/"+id+"/assets", []byte("not an image")); code != http.StatusUnprocessableEntity {
		t.Fatalf("not an image = %d", code)
	}
	code, a := e.uploadTo("/designs/"+id+"/assets", pngSized(t, 30, 20, 2))
	if code != http.StatusCreated || a["w"] != 30.0 || a["h"] != 20.0 || a["mime"] != "image/png" {
		t.Fatalf("upload = %d %v", code, a)
	}
	res, err := http.Get(e.srv.URL + "/api/v1/designs/" + id + "/assets/" + a["id"].(string))
	if err != nil || res.StatusCode != http.StatusOK || res.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("get image: %v %v", res.StatusCode, err)
	}
	res.Body.Close()
	e.want("GET", "/designs/"+id+"/assets/a_missing", nil, http.StatusNotFound)
}

// Migration 00113 rolls back from a database with designs in use: their
// chats, spaces and canvases go, their images are queued for the sweep, and
// it applies again.
func TestDesignsMigrationRollsBackAndReapplies(t *testing.T) {
	e := newDesignsEnv(t)
	ctx := t.Context()
	id, _ := e.design(map[string]any{"starter": "diagram"})
	e.uploadTo("/designs/"+id+"/assets", pngSized(t, 10, 10, 3))
	doc := e.want("POST", "/docs", map[string]any{"title": "Kept"}, http.StatusCreated)["id"].(string)
	chatsBefore := e.count(`SELECT count(*) FROM chat_sessions`)

	sqldb := stdlib.OpenDBFromPool(e.pool)
	defer sqldb.Close()
	if err := goose.DownToContext(ctx, sqldb, ".", 112); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"design_assets", "design_settings", "design_proposals", "design_frame_links"} {
		if n := e.count(`SELECT count(*) FROM pg_tables WHERE tablename = $1`, table); n != 0 {
			t.Fatalf("%s survived the rollback", table)
		}
	}
	if n := e.count(`SELECT count(*) FROM chat_canvases WHERE kind = 'design'`); n != 0 {
		t.Fatalf("%d designs survived", n)
	}
	if n := e.count(`SELECT count(*) FROM chat_spaces WHERE app = 'designs'`); n != 0 {
		t.Fatalf("%d Designs spaces survived", n)
	}
	if got := e.count(`SELECT count(*) FROM chat_sessions`); got != chatsBefore-1 {
		t.Fatalf("%d chats after rollback, want %d", got, chatsBefore-1)
	}
	if q := e.queued(); len(q) != 1 || !strings.HasPrefix(q[0], "designs/") {
		t.Fatalf("queued blobs: %v", q)
	}
	if n := e.count(`SELECT count(*) FROM chat_canvases WHERE id = $1`, doc); n != 1 {
		t.Fatal("the rollback deleted a document")
	}
	if _, err := e.pool.Exec(ctx, `UPDATE chat_canvases SET kind = 'design' WHERE id = $1`, doc); err == nil {
		t.Fatal("kind 'design' is still allowed after the rollback")
	}

	if err := goose.UpContext(ctx, sqldb, "."); err != nil {
		t.Fatal(err)
	}
	id, _ = e.design(map[string]any{})
	e.want("DELETE", "/designs/"+id, nil, http.StatusNoContent)
}

// design_flows answers the acceptance design's prototype as JSON and Mermaid,
// for the design's own chat only, and refuses canvases that aren't designs.
func TestDesignFlowsTool(t *testing.T) {
	e := newDesignsEnv(t)
	id, chat := e.design(map[string]any{})
	raw, err := os.ReadFile("../../../docs/design/fixtures/acceptance-design.json")
	if err != nil {
		t.Fatal(err)
	}
	var body map[string]any
	_ = json.Unmarshal(raw, &body)
	seq, _ := e.current(id)
	if code, out := e.save(id, seq, body); code != http.StatusCreated {
		t.Fatalf("save = %d %v", code, out)
	}
	token := e.canvasToken(uuid.MustParse(chat))
	code, out := e.tool(token, "design_flows", map[string]any{"canvas_id": id})
	if code != http.StatusOK || len(out["frames"].([]any)) != 4 || len(out["links"].([]any)) != 3 ||
		!strings.HasPrefix(out["mermaid"].(string), "flowchart LR\n") || !strings.Contains(out["mermaid"].(string), "n_pay -->|\"Button / Primary: click · smart-animate\"| n_done") {
		t.Fatalf("design_flows = %d %v", code, out)
	}
	if code, out = e.tool(token, "design_flows", map[string]any{"canvas_id": id, "page": "Nowhere"}); code != http.StatusUnprocessableEntity {
		t.Fatalf("unknown page = %d %v", code, out)
	}
	_, otherToken, textID := e.makeCanvas("Not a design.")
	if code, out = e.tool(otherToken, "design_flows", map[string]any{"canvas_id": textID}); code != http.StatusUnprocessableEntity {
		t.Fatalf("text canvas = %d %v", code, out)
	}
	if code, out = e.tool(otherToken, "design_flows", map[string]any{"canvas_id": id}); code != http.StatusNotFound {
		t.Fatalf("another chat's design = %d %v", code, out)
	}
}

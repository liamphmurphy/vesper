package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/canvas"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const acceptanceDesign = "../../../docs/design/fixtures/acceptance-design.json"

// stubWorker stands in for the Node design worker.
type stubWorker struct {
	mu       sync.Mutex
	down     bool
	renders  []map[string]any
	layouts  int
	inspects []map[string]any
	imports  []map[string]any
}

var stubPNG, _ = base64.StdEncoding.DecodeString("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")

func (w *stubWorker) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if r.Header.Get("Authorization") != "Bearer test-token" {
		rw.WriteHeader(http.StatusUnauthorized)
		return
	}
	if w.down {
		rw.WriteHeader(http.StatusInternalServerError)
		return
	}
	var in map[string]any
	_ = json.NewDecoder(r.Body).Decode(&in)
	switch r.URL.Path {
	case "/render":
		w.renders = append(w.renders, in)
		rw.Header().Set("Content-Type", "image/png")
		rw.Header().Set("X-Design-Width", "393")
		rw.Header().Set("X-Design-Height", "852")
		_, _ = rw.Write(stubPNG)
	case "/layout":
		w.layouts++
		// Settled boxes differ from the stored ones, so a test can tell which it got.
		_ = json.NewEncoder(rw).Encode(map[string]any{"pages": []any{map[string]any{"id": "p_flows", "boxes": map[string]any{
			"n_cart": map[string]any{"x": 1, "y": 2, "w": 393, "h": 852}, "n_cart_title": map[string]any{"x": 24, "y": 24, "w": 200, "h": 34}}}}})
	case "/import":
		w.imports = append(w.imports, in)
		if m, _ := in["mermaid"].(string); strings.HasSuffix(m, "-->") {
			rw.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(rw).Encode(map[string]any{"message": `mermaid: line 2: the edge has no target node: "A -->"`})
			return
		}
		shape := func(id string, x float64) map[string]any {
			return map[string]any{"id": id, "type": "shape", "shape": "roundRect", "x": x, "y": 56, "w": 96, "h": 46}
		}
		_ = json.NewEncoder(rw).Encode(map[string]any{"warnings": []string{"line 3: classDef is ignored (styling isn't imported)"}, "node": map[string]any{
			"id": "n_imported", "type": "section", "name": "Imported flowchart", "x": 2000, "y": 0, "w": 300, "h": 140,
			"children": []any{shape("n_imp_a", 32), shape("n_imp_b", 184), map[string]any{"id": "n_imp_c", "type": "connector", "from": map[string]any{"node": "n_imp_a"}, "to": map[string]any{"node": "n_imp_b"}, "points": []any{[]float64{128, 79}, []float64{184, 79}}}},
		}})
	case "/inspect":
		w.inspects = append(w.inspects, in)
		if in["node"] == "n_gone" {
			rw.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(rw).Encode(map[string]any{"message": "node: n_gone isn't drawn"})
			return
		}
		_ = json.NewEncoder(rw).Encode(map[string]any{"node": map[string]any{"id": in["node"]}, "target": in["target"], "code": "<div className=\"bg-panel\" />",
			"tokens": []any{map[string]any{"name": "bg-panel", "value": "#16151F"}}})
	default:
		rw.WriteHeader(http.StatusNotFound)
	}
}

func (w *stubWorker) set(down bool) { w.mu.Lock(); w.down = down; w.mu.Unlock() }

// newDesignToolsEnv is a designs environment whose API reaches a stub worker.
func newDesignToolsEnv(t *testing.T) (*designsEnv, *stubWorker) {
	t.Helper()
	f := newFakeBlobs(t)
	blobs := f.Store
	stub := &stubWorker{}
	ws := httptest.NewServer(stub)
	t.Cleanup(ws.Close)
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = blobs
		s.ArtifactBucket = avatarBucket
		s.DesignWorker = &designs.Worker{URL: ws.URL, Token: "test-token", Backoff: 1}
	})
	return &designsEnv{&slidesEnv{chatEnv: e, s3: f, blobs: blobs}}, stub
}

// acceptance makes a design holding the acceptance fixture; it returns its id,
// chat and the agent token for a turn in that chat.
func (e *designsEnv) acceptance() (id, chat, token string) {
	e.t.Helper()
	id, chat = e.design(map[string]any{})
	raw, err := os.ReadFile(acceptanceDesign)
	if err != nil {
		e.t.Fatal(err)
	}
	if code, out := e.do("POST", "/designs/"+id+"/versions", map[string]any{"base_seq": 1, "body": string(raw)}); code != http.StatusCreated {
		e.t.Fatalf("save the acceptance design: %d %v", code, out)
	}
	return id, chat, e.canvasToken(uuid.MustParse(chat))
}

func (e *designsEnv) call(token, name string, args any) map[string]any {
	e.t.Helper()
	code, out := e.tool(token, name, args)
	if code != http.StatusOK {
		e.t.Fatalf("%s = %d %v", name, code, out)
	}
	return out
}

func find(t *testing.T, nodes []any, id string) map[string]any {
	t.Helper()
	for _, n := range nodes {
		m := n.(map[string]any)
		if m["id"] == id {
			return m
		}
		if kids, ok := m["children"].([]any); ok {
			if got := findIn(kids, id); got != nil {
				return got
			}
		}
	}
	t.Fatalf("node %s not found", id)
	return nil
}

func findIn(nodes []any, id string) map[string]any {
	for _, n := range nodes {
		m := n.(map[string]any)
		if m["id"] == id {
			return m
		}
		if kids, ok := m["children"].([]any); ok {
			if got := findIn(kids, id); got != nil {
				return got
			}
		}
	}
	return nil
}

// design_list, design_outline and design_read on the acceptance design, with
// boxes from the worker (and stored ones when it is down), tokens as
// {token, value}, instance overrides and the links touching the nodes read.
func TestDesignOutlineAndReadTools(t *testing.T) {
	e, stub := newDesignToolsEnv(t)
	id, _, token := e.acceptance()

	list := e.call(token, "design_list", map[string]any{})["designs"].([]any)
	if len(list) != 1 {
		t.Fatalf("design_list: %v", list)
	}
	d := list[0].(map[string]any)
	if d["canvas_id"] != id || d["pages"] != 3.0 || d["frames"].(float64) < 3 || d["pending_proposals"] != 0.0 || d["updated_at"] == "" {
		t.Fatalf("design_list: %v", d)
	}

	out := e.call(token, "design_outline", map[string]any{"canvas_id": id, "page": "p_flows", "depth": 2})
	if !strings.Contains(out["boxes"].(string), "renderer") || strings.Contains(out["boxes"].(string), "stored") {
		t.Fatalf("boxes: %v", out["boxes"])
	}
	pages := out["pages"].([]any)
	if len(pages) != 1 {
		t.Fatalf("page filter: %v", pages)
	}
	cart := find(t, pages[0].(map[string]any)["children"].([]any), "n_cart")
	if box := cart["box"].(map[string]any); box["x"] != 1.0 || box["w"] != 393.0 {
		t.Fatalf("the worker's box wasn't used: %v", cart)
	}
	if cart["type"] != "frame" || cart["child_count"].(float64) < 1 || cart["children"] == nil {
		t.Fatalf("outline node: %v", cart)
	}
	for _, c := range cart["children"].([]any) {
		if _, deeper := c.(map[string]any)["children"]; deeper {
			t.Fatalf("depth 2 went deeper than two levels: %v", c)
		}
	}
	if stub.layouts != 1 {
		t.Fatalf("layout calls: %d", stub.layouts)
	}

	stub.set(true)
	out = e.call(token, "design_outline", map[string]any{"canvas_id": id, "page": "p_flows"})
	if !strings.Contains(out["boxes"].(string), "stored") {
		t.Fatalf("fallback not announced: %v", out["boxes"])
	}
	cart = find(t, out["pages"].([]any)[0].(map[string]any)["children"].([]any), "n_cart")
	if cart["box"] == nil {
		t.Fatalf("no stored box: %v", cart)
	}
	stub.set(false)

	read := e.call(token, "design_read", map[string]any{"canvas_id": id, "node_ids": []string{"n_cart"}})
	if read["version"] != 2.0 || read["mode"] == "" {
		t.Fatalf("read: %v", read)
	}
	frame := read["nodes"].([]any)[0].(map[string]any)
	fill, _ := frame["fill"].(map[string]any)
	if fill["token"] != "$bg-panel" || fill["value"] == nil {
		t.Fatalf("a $token should read as {token, value}: %v", frame["fill"])
	}
	btn := findIn(frame["children"].([]any), "n_cart_btn")
	if btn == nil || btn["overrides"] == nil {
		t.Fatalf("instance overrides: %v", btn)
	}
	links := read["links"].([]any)
	if len(links) == 0 || links[0].(map[string]any)["id"] != "k_cart_ship" {
		t.Fatalf("links touching the nodes: %v", links)
	}
	if code, out := e.tool(token, "design_read", map[string]any{"canvas_id": id, "node_ids": []string{"n_nope"}}); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "n_nope") {
		t.Fatalf("unknown node: %d %v", code, out)
	}
	if code, _ := e.tool(token, "design_read", map[string]any{"canvas_id": id}); code != http.StatusUnprocessableEntity {
		t.Fatalf("read with no target = %d", code)
	}
}

// The design tools refuse canvases that aren't designs, and designs outside
// the chat.
func TestDesignToolsRefuseOtherCanvases(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	_, _, token := e.acceptance()
	other, _ := e.design(map[string]any{})
	_, out := e.tool(token, "canvas_create", map[string]any{"kind": "text", "title": "Notes", "body": "hi"})
	text := out["canvas_id"].(string)
	for _, tool := range []string{"design_outline", "design_read", "design_render", "design_patch", "design_comments", "design_comment", "design_reply"} {
		args := map[string]any{"node_ids": []string{"n_cart"}, "base_version": 1, "summary": "s", "ops": []any{}, "node_id": "n_cart", "body": "b", "comment_id": uuid.NewString()}
		args["canvas_id"] = text
		if code, out := e.tool(token, tool, args); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "isn't a design") {
			t.Errorf("%s on a text canvas = %d %v", tool, code, out)
		}
		args["canvas_id"] = other
		if code, _ := e.tool(token, tool, args); code != http.StatusNotFound {
			t.Errorf("%s on another chat's design = %d", tool, code)
		}
	}
}

// design_patch and canvas_patch on a design hold a suggestion and leave the
// body alone; with direct edit on they write a version by the persona.
func TestDesignPatchTools(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	id, _, token := e.acceptance()
	op := func(name string) map[string]any {
		return map[string]any{"op": "set_node", "id": "n_cart_title", "fields": map[string]any{"name": name}, "why": "Clearer layer name"}
	}

	out := e.call(token, "design_patch", map[string]any{"canvas_id": id, "base_version": 2, "summary": "Rename", "ops": []any{op("Heading")}})
	if out["pending_review"] != true || out["ops"] != 1.0 || out["proposal_id"] == nil || out["applied"] != nil {
		t.Fatalf("design_patch: %v", out)
	}
	if seq, _ := e.current(id); seq != 2 {
		t.Fatalf("a suggestion wrote version %d", seq)
	}
	if n := e.call(token, "design_list", map[string]any{})["designs"].([]any)[0].(map[string]any)["pending_proposals"]; n != 1.0 {
		t.Fatalf("pending_proposals = %v", n)
	}

	// canvas_patch takes the same route: ops as canvas ops, why in value, the note as the summary.
	viaCanvas := map[string]any{"canvas_id": id, "base_version": 2, "note": "Rename again",
		"ops": []any{map[string]any{"op": "set_node", "id": "n_cart_title", "value": map[string]any{"fields": map[string]any{"name": "Screen title"}, "why": "Shorter name"}}}}
	out = e.call(token, "canvas_patch", viaCanvas)
	if out["pending_review"] != true || out["version"] != nil {
		t.Fatalf("canvas_patch on a design: %v", out)
	}
	if seq, _ := e.current(id); seq != 2 {
		t.Fatalf("canvas_patch wrote version %d", seq)
	}
	viaCanvas["ops"] = []any{map[string]any{"op": "set_node", "id": "n_cart_title", "value": map[string]any{"fields": map[string]any{"name": "Title"}}}}
	if code, out := e.tool(token, "canvas_patch", viaCanvas); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "why") {
		t.Fatalf("canvas_patch without why = %d %v", code, out)
	}
	viaCanvas["note"] = ""
	if code, _ := e.tool(token, "canvas_patch", viaCanvas); code != http.StatusUnprocessableEntity {
		t.Fatalf("canvas_patch without a note = %d", code)
	}
	if code, out := e.tool(token, "design_patch", map[string]any{"canvas_id": id, "base_version": 1, "summary": "Stale", "ops": []any{op("X")}}); code != http.StatusConflict {
		t.Fatalf("stale base = %d %v", code, out)
	}

	// Direct edit: applied at once, as a version by the persona.
	e.want("PATCH", "/designs/"+id+"/settings", map[string]any{"direct_edit": true}, http.StatusOK)
	out = e.call(token, "design_patch", map[string]any{"canvas_id": id, "base_version": 2, "summary": "Rename", "ops": []any{op("Heading")}})
	if out["applied"] != true || out["version"] != 3.0 || out["pending_review"] != nil {
		t.Fatalf("direct edit: %v", out)
	}
	v := e.want("GET", "/designs/"+id+"/versions/3", nil, http.StatusOK)
	if v["author_type"] != "agent" || !strings.Contains(v["body"].(string), `"name":"Heading"`) {
		t.Fatalf("version: %v", v)
	}

	// The result names the nodes it touched, with the id minted for a node the persona
	// left unnamed: the editor puts the persona's cursor on them, and the persona can edit them next.
	add := map[string]any{"op": "add_sticky", "page": "p_flows", "x": 0, "y": 0, "text": "Check copy", "why": "A note to self"}
	out = e.call(token, "design_patch", map[string]any{"canvas_id": id, "base_version": 3, "summary": "Note", "ops": []any{add, op("Title")}})
	nodes, _ := out["nodes"].([]any)
	if len(nodes) != 2 || nodes[1] != "n_cart_title" {
		t.Fatalf("nodes: %v", out)
	}
	minted, _ := nodes[0].(string)
	v = e.want("GET", "/designs/"+id+"/versions/4", nil, http.StatusOK)
	if !strings.HasPrefix(minted, "n_") || !strings.Contains(v["body"].(string), `"id":"`+minted+`"`) {
		t.Fatalf("minted %q isn't in the version", minted)
	}
}

// Node-anchored comments: a person's through the chat canvas comment REST,
// the persona's through the tools; an anchor outside the node's box or on a
// node that isn't there is refused, and a comment loses its target when the
// node goes.
func TestDesignComments(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	id, chat, token := e.acceptance()
	base := "/chats/" + chat + "/canvases/" + id + "/comments"

	if code, out := e.do("POST", base, map[string]any{"seq": 2, "body": "Too tight", "node": "n_nope"}); code != http.StatusUnprocessableEntity {
		t.Fatalf("comment on a missing node = %d %v", code, out)
	}
	if code, _ := e.do("POST", base, map[string]any{"seq": 2, "body": "Too tight", "node": "n_cart_title", "point": map[string]any{"x": 1.5, "y": 0}}); code != http.StatusUnprocessableEntity {
		t.Fatalf("a point outside the node = %d", code)
	}
	c := e.want("POST", base, map[string]any{"seq": 2, "body": "Too tight", "node": "n_cart_title", "point": map[string]any{"x": 0.25, "y": 0.5}}, http.StatusCreated)
	anchor := c["anchor"].(map[string]any)
	if anchor["node"] != "n_cart_title" || anchor["point"].(map[string]any)["x"] != 0.25 || anchor["label"] == "" {
		t.Fatalf("anchor: %v", anchor)
	}
	e.want("POST", base+"/send", map[string]any{"comment_ids": []string{c["id"].(string)}}, http.StatusNoContent)

	// What the next turn is told about it.
	title, ctxDoc, err := canvas.ContextDoc(e.t.Context(), e.q, uuid.MustParse(chat), uuid.MustParse(id))
	if err != nil || title == "" || !strings.Contains(ctxDoc, "On node n_cart_title") || !strings.Contains(ctxDoc, "Too tight") || !strings.Contains(ctxDoc, "design_reply") || strings.Contains(ctxDoc, `"pages"`) {
		t.Fatalf("context doc: %v\n%s", err, ctxDoc)
	}

	threads := e.call(token, "design_comments", map[string]any{"canvas_id": id, "open_only": true})["threads"].([]any)
	if len(threads) != 1 || threads[0].(map[string]any)["node"] != "n_cart_title" || threads[0].(map[string]any)["x"] != 0.25 {
		t.Fatalf("design_comments: %v", threads)
	}
	cid := threads[0].(map[string]any)["comment_id"].(string)
	e.call(token, "design_reply", map[string]any{"canvas_id": id, "comment_id": cid, "body": "Added padding", "addressed": true})
	if open := e.call(token, "design_comments", map[string]any{"canvas_id": id, "open_only": true})["threads"].([]any); len(open) != 0 {
		t.Fatalf("an addressed thread is still open: %v", open)
	}
	all := e.call(token, "design_comments", map[string]any{"canvas_id": id})["threads"].([]any)
	if r := all[0].(map[string]any)["replies"].([]any); len(all) != 1 || len(r) != 1 || all[0].(map[string]any)["status"] != "addressed" {
		t.Fatalf("threads: %v", all)
	}

	made := e.call(token, "design_comment", map[string]any{"canvas_id": id, "node_id": "n_cart", "body": "Is this frame too wide?", "x": 0.5, "y": 0.1})
	if made["comment_id"] == nil {
		t.Fatalf("design_comment: %v", made)
	}
	if code, _ := e.tool(token, "design_comment", map[string]any{"canvas_id": id, "node_id": "n_nope", "body": "?"}); code != http.StatusUnprocessableEntity {
		t.Fatalf("design_comment on a missing node = %d", code)
	}
	if code, _ := e.tool(token, "design_comment", map[string]any{"canvas_id": id, "node_id": "n_cart", "body": "?", "x": 0.5}); code != http.StatusUnprocessableEntity {
		t.Fatalf("design_comment with x only = %d", code)
	}

	// The node goes: its comment is kept with target_lost.
	seq, body := e.current(id)
	kids := body["pages"].([]any)[0].(map[string]any)["children"].([]any)[0].(map[string]any)
	var keep []any
	for _, k := range kids["children"].([]any) {
		if k.(map[string]any)["id"] != "n_cart_title" {
			keep = append(keep, k)
		}
	}
	kids["children"] = keep
	if code, out := e.save(id, seq, body); code != http.StatusCreated {
		t.Fatalf("save: %d %v", code, out)
	}
	for _, th := range e.call(token, "design_comments", map[string]any{"canvas_id": id})["threads"].([]any) {
		m := th.(map[string]any)
		if m["comment_id"] == cid && m["target_lost"] != true {
			t.Fatalf("target_lost not set: %v", m)
		}
	}
}

// A selection rides on a canvas ref to a design, and only there.
func TestDesignSelectionRefs(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	id, chat, token := e.acceptance()
	cv := uuid.MustParse(id)
	sel := &canvas.Selection{Page: "p_flows", Nodes: []string{"n_cart", "n_cart_title", "n_gone"}, Viewport: canvas.Viewport{X: 10, Y: 20, W: 800, H: 600, Zoom: 0.5}}
	ws := e.me.WorkspaceID

	docs, err := runs.ResolveChatRefs(e.t.Context(), e.q, ws, uuid.MustParse(chat), []runs.ChatContextRef{{Kind: "canvas", ID: &cv, Selection: sel}})
	if err != nil {
		t.Fatal(err)
	}
	body := docs[0].Body
	for _, want := range []string{id, "version: 2", "page: p_flows", "zoom=0.5", "- n_cart: frame", "- n_cart_title: text", "box x=", "- n_gone: no longer in this design", "When the person says this/these, they mean the selected nodes."} {
		if !strings.Contains(body, want) {
			t.Errorf("selection doc lacks %q:\n%s", want, body)
		}
	}
	if len(body) > 2000 || strings.Contains(body, `"fill"`) {
		t.Errorf("the selection doc should be short, not the design (%d bytes)", len(body))
	}

	bad := func(name string, ref runs.ChatContextRef) {
		t.Helper()
		if _, err := runs.ResolveChatRefs(e.t.Context(), e.q, ws, uuid.MustParse(chat), []runs.ChatContextRef{ref}); err == nil || !strings.Contains(err.Error(), "context_refs") {
			t.Errorf("%s: %v", name, err)
		}
	}
	bad("a missing page", runs.ChatContextRef{Kind: "canvas", ID: &cv, Selection: &canvas.Selection{Page: "p_nope", Viewport: canvas.Viewport{Zoom: 1}}})
	bad("a bad node id", runs.ChatContextRef{Kind: "canvas", ID: &cv, Selection: &canvas.Selection{Page: "p_flows", Nodes: []string{"x"}, Viewport: canvas.Viewport{Zoom: 1}}})
	many := make([]string, 101)
	for i := range many {
		many[i] = "n_cart"
	}
	bad("too many nodes", runs.ChatContextRef{Kind: "canvas", ID: &cv, Selection: &canvas.Selection{Page: "p_flows", Nodes: many, Viewport: canvas.Viewport{Zoom: 1}}})
	bad("zero zoom", runs.ChatContextRef{Kind: "canvas", ID: &cv, Selection: &canvas.Selection{Page: "p_flows"}})
	bad("on a ticket", runs.ChatContextRef{Kind: "ticket", Key: "PAY-214", Selection: sel})
	_, out := e.tool(token, "canvas_create", map[string]any{"kind": "text", "title": "Notes", "body": "hi"})
	text := uuid.MustParse(out["canvas_id"].(string))
	bad("on a text canvas", runs.ChatContextRef{Kind: "canvas", ID: &text, Selection: sel})

	// Through the REST contract, a chat message accepts it (and 422s the bad one).
	msg := func(ref any) (int, map[string]any) {
		return e.do("POST", "/chats/"+chat+"/messages", map[string]any{"body": "make this bigger", "context_refs": []any{ref}})
	}
	if code, out := msg(map[string]any{"kind": "canvas", "id": id, "selection": map[string]any{"page": "p_flows", "nodes": []string{"n_cart"}, "viewport": map[string]any{"x": 0, "y": 0, "w": 800, "h": 600, "zoom": 1}}}); code >= 300 {
		t.Fatalf("message with a selection = %d %v", code, out)
	}
	if code, _ := msg(map[string]any{"kind": "canvas", "id": text.String(), "selection": map[string]any{"page": "p_flows", "nodes": []string{}, "viewport": map[string]any{"x": 0, "y": 0, "w": 8, "h": 6, "zoom": 1}}}); code != http.StatusUnprocessableEntity {
		t.Fatalf("selection on a text canvas = %d", code)
	}
	var stored string
	if err := e.pool.QueryRow(e.t.Context(), `SELECT context_refs::text FROM chat_messages WHERE session_id = $1 AND role = 'user' ORDER BY seq DESC LIMIT 1`, chat).Scan(&stored); err != nil || !strings.Contains(stored, `"selection"`) {
		t.Fatalf("stored refs: %v %s", err, stored)
	}
}

// design_render and GET /designs/{id}/render go through the worker, posting
// the design's images as data URIs; a broken worker is a message, not a crash.
func TestDesignRender(t *testing.T) {
	e, stub := newDesignToolsEnv(t)
	id, _, token := e.acceptance()

	// The design's image: upload one, and list it under the fixture's asset id.
	code, a := e.uploadTo("/designs/"+id+"/assets", pngSized(t, 30, 20, 2))
	if code != http.StatusCreated {
		t.Fatalf("upload: %d %v", code, a)
	}
	if _, err := e.pool.Exec(e.t.Context(), `INSERT INTO design_assets (canvas_id, id, workspace_id, user_id, blob_key, mime, width, height, size_bytes)
		SELECT canvas_id, 'a_landscape', workspace_id, user_id, blob_key, mime, width, height, size_bytes FROM design_assets WHERE id = $1`, a["id"]); err != nil {
		t.Fatal(err)
	}

	out := e.call(token, "design_render", map[string]any{"canvas_id": id, "node_id": "n_cart", "scale": 2})
	if out["w"] != 393.0 || out["h"] != 852.0 || out["image_png_base64"] != base64.StdEncoding.EncodeToString(stubPNG) {
		t.Fatalf("design_render: %v", out)
	}
	req := stub.renders[len(stub.renders)-1]
	if req["node"] != "n_cart" || req["scale"] != 2.0 || !strings.Contains(req["body"].(string), "n_cart") {
		t.Fatalf("worker request: %v", req)
	}
	assets, _ := req["assets"].(map[string]any)
	if uri, _ := assets["a_landscape"].(string); !strings.HasPrefix(uri, "data:image/png;base64,") {
		t.Fatalf("assets weren't posted as data URIs: %v", assets)
	}
	if code, _ := e.tool(token, "design_render", map[string]any{"canvas_id": id, "node_id": "n_cart", "page": "p_flows"}); code != http.StatusUnprocessableEntity {
		t.Fatalf("node and page together = %d", code)
	}
	if code, _ := e.tool(token, "design_render", map[string]any{"canvas_id": id, "scale": 9}); code != http.StatusUnprocessableEntity {
		t.Fatalf("scale 9 = %d", code)
	}

	get := func(q string) (*http.Response, []byte) {
		res, err := http.Get(e.srv.URL + "/api/v1/designs/" + id + "/render" + q)
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		raw, _ := io.ReadAll(res.Body)
		return res, raw
	}
	res, raw := get("?page=p_flows&scale=1")
	if res.StatusCode != http.StatusOK || res.Header.Get("Content-Type") != "image/png" || res.Header.Get("X-Design-Width") != "393" || string(raw) != string(stubPNG) {
		t.Fatalf("render endpoint = %d %s %q", res.StatusCode, res.Header, raw)
	}
	if p := stub.renders[len(stub.renders)-1]["page"]; p != "p_flows" {
		t.Fatalf("page not forwarded: %v", p)
	}
	if res, _ := get("?node=n_nope"); res.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("unknown node = %d", res.StatusCode)
	}
	if res, _ := get("?scale=4"); res.StatusCode != http.StatusBadRequest && res.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("scale 4 = %d", res.StatusCode)
	}
	if res, _ := http.Get(e.srv.URL + "/api/v1/designs/" + uuid.NewString() + "/render"); res.StatusCode != http.StatusNotFound {
		t.Fatalf("someone else's design = %d", res.StatusCode)
	}

	stub.set(true)
	res, raw = get("")
	if res.StatusCode != http.StatusServiceUnavailable || !strings.Contains(string(raw), "renderer") {
		t.Fatalf("worker down = %d %s", res.StatusCode, raw)
	}
	down := e.call(token, "design_render", map[string]any{"canvas_id": id})
	if !strings.Contains(down["message"].(string), "render unavailable") || down["image_png_base64"] != nil {
		t.Fatalf("design_render with the worker down: %v", down)
	}
}

var _ = store.ChatCanvas{}

// design_create starts a design in the persona's own chat: the person's
// Designs app lists it and the persona's design tools reach it there.
func TestDesignCreateTool(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	_, chat, token := e.acceptance()
	out := e.call(token, "design_create", map[string]any{"title": "  Onboarding  flow ", "starter": "mobile-flow"})
	id, _ := out["canvas_id"].(string)
	if id == "" || out["title"] != "Onboarding flow" || out["version"] != float64(1) || out["url"] != "/apps/designs/"+id {
		t.Fatalf("design_create = %v", out)
	}
	d := e.want("GET", "/designs/"+id, nil, http.StatusOK)
	if d["chat_id"] != chat {
		t.Errorf("the design lives in chat %v, not the persona's chat %s", d["chat_id"], chat)
	}
	listed := false
	for _, x := range e.call(token, "design_list", map[string]any{})["designs"].([]any) {
		m := x.(map[string]any)
		if m["canvas_id"] == id {
			listed = true
			if m["frames"].(float64) < 1 {
				t.Errorf("a mobile-flow starter has frames: %v", m)
			}
		}
	}
	if !listed {
		t.Error("design_list doesn't show the new design")
	}
	e.call(token, "design_outline", map[string]any{"canvas_id": id})

	if code, _ := e.tool(token, "design_create", map[string]any{"title": "X", "starter": "poster"}); code != http.StatusUnprocessableEntity {
		t.Errorf("unknown starter = %d", code)
	}
	if code, out := e.tool(token, "design_create", map[string]any{"title": "X", "project": "NOPE"}); code != http.StatusUnprocessableEntity || !strings.Contains(out["message"].(string), "NOPE") {
		t.Errorf("unknown project = %d %v", code, out)
	}
}

// design_components, design_tokens, design_inspect and design_link_ticket on
// the acceptance design.
func TestDesignLibraryTools(t *testing.T) {
	e, stub := newDesignToolsEnv(t)
	id, _, token := e.acceptance()

	comps := e.call(token, "design_components", map[string]any{"canvas_id": id})["components"].([]any)
	if len(comps) != 1 {
		t.Fatalf("components: %v", comps)
	}
	if c := comps[0].(map[string]any); c["id"] != "n_btn" || c["name"] != "Button / Primary" || c["page"] != "p_components" || len(c["instances"].([]any)) != 3 {
		t.Fatalf("component: %v", c)
	}

	tk := e.call(token, "design_tokens", map[string]any{"canvas_id": id})
	if tk["tokens_css_changed"] != false || tk["tokens_ref"].(map[string]any)["set"] != "dusk-web" || tk["token_sets"].(map[string]any)["dusk-web"] == nil {
		t.Fatalf("design_tokens: %v", tk)
	}
	if used := fmt.Sprint(tk["used"]); !strings.Contains(used, "accent") {
		t.Fatalf("used: %v", used)
	}

	ins := e.call(token, "design_inspect", map[string]any{"canvas_id": id, "node_id": "n_pay", "target": "tailwind"})
	if ins["code"] == nil || ins["version"] != 2.0 || len(stub.inspects) != 1 || stub.inspects[0]["target"] != "tailwind" || stub.inspects[0]["node"] != "n_pay" || !strings.Contains(stub.inspects[0]["body"].(string), "n_pay") {
		t.Fatalf("design_inspect: %v / %v", ins, stub.inspects)
	}
	e.call(token, "design_inspect", map[string]any{"canvas_id": id, "node_id": "n_pay"})
	if stub.inspects[1]["target"] != "react" {
		t.Fatalf("default target: %v", stub.inspects[1]["target"])
	}
	if code, out := e.tool(token, "design_inspect", map[string]any{"canvas_id": id, "node_id": "n_pay", "target": "swift"}); code != http.StatusUnprocessableEntity {
		t.Fatalf("bad target = %d %v", code, out)
	}
	if code, out := e.tool(token, "design_inspect", map[string]any{"canvas_id": id, "node_id": "n_nope"}); code != http.StatusUnprocessableEntity {
		t.Fatalf("unknown node = %d %v", code, out)
	}
	stub.set(true)
	if out := e.call(token, "design_inspect", map[string]any{"canvas_id": id, "node_id": "n_pay"}); out["inspect"] != "unavailable" {
		t.Fatalf("worker down: %v", out)
	}
	stub.set(false)

	// Linking is a suggestion the person reviews; the body is unchanged until then.
	out := e.call(token, "design_link_ticket", map[string]any{"canvas_id": id, "node_id": "n_ship", "ticket": e.payKey})
	if out["pending_review"] != true || out["ops"] != 1.0 {
		t.Fatalf("design_link_ticket: %v", out)
	}
	if n := e.count(`SELECT count(*) FROM design_frame_links WHERE canvas_id = $1 AND node_id = 'n_ship'`, id); n != 0 {
		t.Fatalf("linked before review: %d", n)
	}
	var ops string
	if err := e.pool.QueryRow(e.t.Context(), `SELECT ops::text FROM design_proposals WHERE canvas_id = $1`, id).Scan(&ops); err != nil || !strings.Contains(ops, `"link_ticket"`) || !strings.Contains(ops, e.payKey) {
		t.Fatalf("proposal ops: %s %v", ops, err)
	}
	if code, out := e.tool(token, "design_link_ticket", map[string]any{"canvas_id": id, "node_id": "n_ship", "ticket": "NOPE-1"}); code != http.StatusUnprocessableEntity {
		t.Fatalf("unknown ticket = %d %v", code, out)
	}
}

// design_import: the worker's node arrives as one add_node suggestion (the
// design unchanged until review), or as a version with direct edit on; text
// the worker refuses comes back with its message and changes nothing.
func TestDesignImportTool(t *testing.T) {
	e, stub := newDesignToolsEnv(t)
	id, _, token := e.acceptance()
	chart := "flowchart LR\n  A --> B"

	out := e.call(token, "design_import", map[string]any{"canvas_id": id, "page": "p_flows", "mermaid": chart})
	if out["pending_review"] != true || out["ops"] != 1.0 || out["node_id"] != "n_imported" || out["proposal_id"] == nil {
		t.Fatalf("design_import: %v", out)
	}
	if w, _ := out["warnings"].([]any); len(w) != 1 {
		t.Fatalf("warnings: %v", out["warnings"])
	}
	if seq, _ := e.current(id); seq != 2 {
		t.Fatalf("a suggested import wrote version %d", seq)
	}
	if len(stub.imports) != 1 || stub.imports[0]["page"] != "p_flows" || stub.imports[0]["mermaid"] != chart || stub.imports[0]["body"] == nil {
		t.Fatalf("worker request: %v", stub.imports)
	}
	if n := e.call(token, "design_list", map[string]any{})["designs"].([]any)[0].(map[string]any)["pending_proposals"]; n != 1.0 {
		t.Fatalf("pending_proposals = %v", n)
	}

	// Refusals name the problem and change nothing.
	code, bad := e.tool(token, "design_import", map[string]any{"canvas_id": id, "page": "p_flows", "mermaid": "flowchart LR\n  A -->"})
	if code != http.StatusUnprocessableEntity || !strings.Contains(bad["message"].(string), "line 2: the edge has no target node") {
		t.Fatalf("bad mermaid = %d %v", code, bad)
	}
	for _, args := range []map[string]any{
		{"canvas_id": id, "page": "p_nope", "mermaid": chart},
		{"canvas_id": id, "page": "p_flows"},
		{"canvas_id": id, "page": "p_flows", "mermaid": chart, "svg": "<svg/>"},
		{"canvas_id": id, "page": "p_flows", "mermaid": chart, "x": 10},
	} {
		if code, out := e.tool(token, "design_import", args); code != http.StatusUnprocessableEntity {
			t.Fatalf("%v = %d %v", args, code, out)
		}
	}
	if code, out := e.tool(token, "design_import", map[string]any{"canvas_id": id, "page": "p_flows", "mermaid": chart, "base_version": 1}); code != http.StatusConflict {
		t.Fatalf("stale base = %d %v", code, out)
	}
	if seq, _ := e.current(id); seq != 2 {
		t.Fatalf("a refused import wrote version %d", seq)
	}
	if n := e.call(token, "design_list", map[string]any{})["designs"].([]any)[0].(map[string]any)["pending_proposals"]; n != 1.0 {
		t.Fatalf("a refused import left a proposal: %v", n)
	}

	// Direct edit on: applied at once as the persona's version.
	e.want("PATCH", "/designs/"+id+"/settings", map[string]any{"direct_edit": true}, http.StatusOK)
	out = e.call(token, "design_import", map[string]any{"canvas_id": id, "page": "p_flows", "svg": "<svg><rect width='1' height='1'/></svg>"})
	if out["applied"] != true || out["version"] != 3.0 {
		t.Fatalf("direct edit: %v", out)
	}
	v := e.want("GET", "/designs/"+id+"/versions/3", nil, http.StatusOK)
	if v["author_type"] != "agent" || !strings.Contains(v["body"].(string), `"id":"n_imported"`) || !strings.Contains(v["body"].(string), `"id":"n_imp_c"`) {
		t.Fatalf("version: %v", v)
	}

	// No worker: nothing imported, and the persona is told why.
	stub.set(true)
	if code, out := e.tool(token, "design_import", map[string]any{"canvas_id": id, "page": "p_flows", "mermaid": chart}); code != http.StatusConflict || !strings.Contains(out["message"].(string), "nothing was imported") {
		t.Fatalf("worker down = %d %v", code, out)
	}
}

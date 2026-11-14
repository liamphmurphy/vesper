package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// runningTurn marks the chat's latest turn running, as the runner does while
// the persona answers, and returns it.
func (e *designsEnv) runningTurn(chat string) uuid.UUID {
	e.t.Helper()
	c, err := e.q.GetChatSession(e.t.Context(), store.GetChatSessionParams{ID: uuid.MustParse(chat), WorkspaceID: e.me.WorkspaceID})
	if err != nil {
		e.t.Fatal(err)
	}
	var id uuid.UUID
	if err := e.pool.QueryRow(e.t.Context(), `UPDATE run_turns SET status = 'running'
		WHERE id = (SELECT id FROM run_turns WHERE run_id = $1 ORDER BY seq DESC LIMIT 1) RETURNING id`, c.CurrentRunID).Scan(&id); err != nil {
		e.t.Fatal(err)
	}
	return id
}

func (e *designsEnv) endTurn(turn uuid.UUID) {
	e.t.Helper()
	if err := e.q.FinishTurn(e.t.Context(), store.FinishTurnParams{ID: turn, Usage: []byte("{}")}); err != nil {
		e.t.Fatal(err)
	}
}

func (e *designsEnv) pendingProposals(id string) []any {
	e.t.Helper()
	return e.want("GET", "/designs/"+id+"/proposals?status=pending", nil, http.StatusOK)["proposals"].([]any)
}

// A persona's patches during a turn are its own until the turn ends: the
// person sees no suggestion while it works, then one suggestion holding only
// the net change, however many steps made it.
func TestDesignTurnPublishesOneNetSuggestion(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	id, chat, token := e.acceptance()
	turn := e.runningTurn(chat)
	v := e.call(token, "design_outline", map[string]any{"canvas_id": id})["version"]

	patch := func(summary string, ops ...map[string]any) map[string]any {
		return e.call(token, "design_patch", map[string]any{"canvas_id": id, "base_version": v, "summary": summary, "ops": ops})
	}
	shape := func(id string) map[string]any {
		return map[string]any{"id": id, "type": "shape", "shape": "rect", "x": 3000, "y": 0, "w": 40, "h": 40}
	}
	if out := patch("Try a badge", map[string]any{"op": "add_node", "parent": "p_flows", "node": shape("n_try"), "why": "A badge"}); out["drafted"] != true {
		t.Fatalf("first patch = %v, want drafted", out)
	}
	// The next patch builds on the draft: n_try exists only there.
	patch("Recolour it", map[string]any{"op": "set_node", "id": "n_try", "fields": map[string]any{"fill": "#FF0000"}, "why": "Red"})
	if got := e.call(token, "design_read", map[string]any{"canvas_id": id, "node_ids": []string{"n_try"}})["nodes"].([]any); len(got) != 1 {
		t.Fatalf("design_read of the draft = %v", got)
	}
	patch("Settle on a pill",
		map[string]any{"op": "remove_node", "id": "n_try", "why": "Not this"},
		map[string]any{"op": "add_node", "parent": "p_flows", "node": shape("n_pill"), "why": "A pill reads better"})

	if ps := e.pendingProposals(id); len(ps) != 0 {
		t.Fatalf("the person sees %d suggestions mid-turn", len(ps))
	}
	if n := e.want("GET", "/designs/"+id, nil, http.StatusOK)["pending_proposals"]; n != 0.0 {
		t.Fatalf("pending_proposals mid-turn = %v", n)
	}

	// The turn ends; reading the design hands its draft over.
	e.endTurn(turn)
	ps := e.pendingProposals(id)
	if len(ps) != 1 {
		t.Fatalf("got %d suggestions, want 1", len(ps))
	}
	p := ps[0].(map[string]any)
	ops := p["ops"].([]any)
	if len(ops) != 1 {
		t.Fatalf("net ops = %v, want only the pill", ops)
	}
	op := ops[0].(map[string]any)
	if op["op"] != "add_node" || op["node"].(map[string]any)["id"] != "n_pill" || op["why"] != "A pill reads better" {
		t.Fatalf("net op = %v", op)
	}
	if s := p["summary"].(string); !strings.Contains(s, "Try a badge") || !strings.Contains(s, "Settle on a pill") {
		t.Fatalf("summary = %q", s)
	}
	// The design itself waits for the person's review.
	if seq, _ := e.current(id); seq != int(v.(float64)) {
		t.Fatalf("design moved to %d before review", seq)
	}
}

// A design the persona starts is drafted from a blank version: the starter's
// placeholder frames are only scaffolding in the draft, and with nothing of the
// person's to change, the finished draft lands as the next version unreviewed.
func TestPersonaFirstDraftLandsWithoutStarterFrames(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	chat := e.newChat(nil)["id"].(string)
	token := e.canvasToken(uuid.MustParse(chat))
	turn := e.runningTurn(chat)

	created := e.call(token, "design_create", map[string]any{"title": "Sign-in flow", "starter": "mobile-flow"})
	id := created["canvas_id"].(string)
	outline := e.call(token, "design_outline", map[string]any{"canvas_id": id, "depth": 1})
	page := outline["pages"].([]any)[0].(map[string]any)
	var ops []map[string]any
	for _, n := range page["children"].([]any) {
		ops = append(ops, map[string]any{"op": "remove_node", "id": n.(map[string]any)["id"], "why": "Replace the placeholder"})
	}
	if len(ops) != 3 {
		t.Fatalf("the persona should see the starter's three frames, got %v", page["children"])
	}
	ops = append(ops, map[string]any{"op": "add_node", "parent": page["id"], "why": "The first screen",
		"node": map[string]any{"type": "frame", "name": "Sign in", "x": 0, "y": 0, "w": 393, "h": 852, "children": []any{}}})
	e.call(token, "design_patch", map[string]any{"canvas_id": id, "base_version": created["version"], "summary": "Sign-in screen", "ops": ops})

	if seq, body := e.current(id); seq != 1 || strings.Contains(mustJSON(t, body), "Start") {
		t.Fatalf("mid-turn the person should see the blank version 1, got v%d %v", seq, body)
	}
	e.endTurn(turn)
	if err := e.svc().PublishSettled(t.Context(), nil, &turn); err != nil {
		t.Fatal(err)
	}
	seq, body := e.current(id)
	text := mustJSON(t, body)
	if seq != 2 || !strings.Contains(text, `"Sign in"`) {
		t.Fatalf("the draft should land as version 2, got v%d %s", seq, text)
	}
	for _, name := range []string{`"Start"`, `"Details"`, `"Done"`} {
		if strings.Contains(text, name) {
			t.Fatalf("starter frame %s is in the design", name)
		}
	}
	if ps := e.pendingProposals(id); len(ps) != 0 {
		t.Fatalf("a persona's first draft needs no review, got %v", ps)
	}
}

func mustJSON(t *testing.T, v any) string {
	t.Helper()
	raw, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// A design the person made from a starter and hasn't touched since is still
// scaffolding: the persona's first draft replaces the placeholders without a
// review listing their removal.
func TestFirstDraftOnAnUntouchedStarterLandsDirectly(t *testing.T) {
	e, _ := newDesignToolsEnv(t)
	id, chat := e.design(map[string]any{"title": "Checkout", "starter": "mobile-flow"})
	token := e.canvasToken(uuid.MustParse(chat))
	turn := e.runningTurn(chat)
	outline := e.call(token, "design_outline", map[string]any{"canvas_id": id, "depth": 1})
	page := outline["pages"].([]any)[0].(map[string]any)
	var ops []map[string]any
	for _, n := range page["children"].([]any) {
		ops = append(ops, map[string]any{"op": "remove_node", "id": n.(map[string]any)["id"], "why": "Replace the placeholder"})
	}
	ops = append(ops, map[string]any{"op": "add_node", "parent": page["id"], "why": "The cart",
		"node": map[string]any{"type": "frame", "name": "Cart", "x": 0, "y": 0, "w": 393, "h": 852, "children": []any{}}})
	e.call(token, "design_patch", map[string]any{"canvas_id": id, "base_version": outline["version"], "summary": "Cart screen", "ops": ops})
	e.endTurn(turn)

	if ps := e.pendingProposals(id); len(ps) != 0 {
		t.Fatalf("an untouched design's first draft needs no review, got %v", ps)
	}
	seq, body := e.current(id)
	if text := mustJSON(t, body); seq != 2 || !strings.Contains(text, `"Cart"`) || strings.Contains(text, `"Details"`) {
		t.Fatalf("got v%d %s", seq, text)
	}

	// Once the person has a version of their own, the next turn's work waits for review.
	turn = e.runningTurn(chat)
	read := e.call(token, "design_outline", map[string]any{"canvas_id": id, "depth": 1})
	cart := read["pages"].([]any)[0].(map[string]any)["children"].([]any)[0].(map[string]any)["id"]
	body["pages"].([]any)[0].(map[string]any)["name"] = "Checkout"
	if code, out := e.do("POST", "/designs/"+id+"/versions", map[string]any{"base_seq": 2, "body": mustJSON(t, body)}); code != http.StatusCreated {
		t.Fatalf("save: %d %v", code, out)
	}
	e.call(token, "design_patch", map[string]any{"canvas_id": id, "base_version": 3, "summary": "Rename", "ops": []map[string]any{
		{"op": "set_node", "id": cart, "fields": map[string]any{"name": "Basket"}, "why": "Matches the copy"}}})
	e.endTurn(turn)
	if ps := e.pendingProposals(id); len(ps) != 1 {
		t.Fatalf("got %d suggestions, want 1", len(ps))
	}
}

package design

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
	"testing"
)

func minimal(t *testing.T) string {
	t.Helper()
	out, err := Normalize(read(t, sharedDir+"/valid-minimal.json"))
	if err != nil {
		t.Fatal(err)
	}
	return out
}

func ops(t *testing.T, s string) []Op {
	t.Helper()
	o, err := DecodeOps([]byte(s))
	if err != nil {
		t.Fatal(err)
	}
	return o
}

func node(t *testing.T, body, id string) map[string]any {
	t.Helper()
	d, _ := Parse(body)
	l, ok := find(d, id)
	if !ok {
		return nil
	}
	return l.n
}

func TestApplyOps(t *testing.T) {
	base := minimal(t)
	cases := []struct {
		name, ops string
		check     func(t *testing.T, out string)
	}{
		{"add_node with minted ids", `[{"op":"add_node","parent":"n_next","node":{"type":"frame","x":0,"y":0,"w":10,"h":10,"children":[{"type":"text","x":0,"y":0,"w":5,"h":5,"paragraphs":[{"runs":[{"text":"Hi","size":12}]}]}]}}]`,
			func(t *testing.T, out string) {
				if n := node(t, out, "n_next"); len(children(n)) != 1 || !strings.HasPrefix(children(children(n)[0])[0]["id"].(string), "n_") {
					t.Fatal(out)
				}
			}},
		{"set_node merges and removes", `[{"op":"set_node","id":"n_box","fields":{"fill":"#ff0000","radius":4,"name":null}}]`,
			func(t *testing.T, out string) {
				if n := node(t, out, "n_box"); n["fill"] != "#FF0000" || n["radius"] != 4.0 {
					t.Fatal(n)
				}
			}},
		{"move_node reparents", `[{"op":"move_node","id":"n_box","parent":"n_next","x":5}]`,
			func(t *testing.T, out string) {
				if n := node(t, out, "n_next"); len(children(n)) != 1 || children(n)[0]["x"] != 5.0 {
					t.Fatal(out)
				}
			}},
		{"remove_node prunes links and connectors", `[{"op":"remove_node","id":"n_next"}]`,
			func(t *testing.T, out string) {
				if strings.Contains(out, "k_go") || strings.Contains(out, "n_wire") {
					t.Fatal(out)
				}
			}},
		{"set_text keeps the first run's style", `[{"op":"set_text","id":"n_title","text":"One\nTwo"}]`,
			func(t *testing.T, out string) {
				if ps := node(t, out, "n_title")["paragraphs"].([]any); len(ps) != 2 {
					t.Fatal(ps)
				}
			}},
		{"connect and add_sticky", `[{"op":"connect","from":"n_box","to":"n_next","label":"go"},{"op":"add_sticky","page":"p_flows","x":0,"y":0,"text":"note"}]`,
			func(t *testing.T, out string) {
				if strings.Count(out, `"type":"connector"`) != 2 || !strings.Contains(out, `"type":"sticky"`) {
					t.Fatal(out)
				}
			}},
		{"pages", `[{"op":"add_page","page":{"id":"p_x","name":"Extra"}},{"op":"add_page","page":{"name":"Kept"},"after":"p_flows"},{"op":"set_page","id":"p_flows","name":"Main"},{"op":"remove_page","id":"p_x"}]`,
			func(t *testing.T, out string) {
				if strings.Contains(out, `"name":"Extra"`) || !strings.Contains(out, `"name":"Kept"`) || !strings.Contains(out, `"name":"Main"`) {
					t.Fatal(out)
				}
			}},
		{"links", `[{"op":"add_link","id":"k_back","from":"n_box","to":"n_home"},{"op":"set_link","id":"k_go","transition":"dissolve"},{"op":"remove_link","id":"k_back"}]`,
			func(t *testing.T, out string) {
				if strings.Contains(out, "k_back") || !strings.Contains(out, "dissolve") {
					t.Fatal(out)
				}
			}},
		{"components", `[{"op":"remove_link","id":"k_go"},{"op":"create_component","id":"n_next","name":"Card"},{"op":"instantiate","component":"n_button","parent":"p_flows","x":0,"y":0,"id":"n_two"},{"op":"set_overrides","id":"n_two","overrides":{"n_label":{"text":"Two"}}},{"op":"detach","id":"n_btn"}]`,
			func(t *testing.T, out string) {
				if node(t, out, "n_next")["type"] != "component" || node(t, out, "n_btn")["type"] != "frame" || !strings.Contains(out, `"text":"Go"`) {
					t.Fatal(out)
				}
			}},
		{"tickets", `[{"op":"link_ticket","node":"n_home","ticket":"LAZYAGENTS-150"}]`,
			func(t *testing.T, out string) {
				if FrameLinks(out)["n_home"][0] != "LAZYAGENTS-150" {
					t.Fatal(out)
				}
			}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			out, err := Apply(base, ops(t, c.ops))
			if err != nil {
				t.Fatal(err)
			}
			c.check(t, out)
		})
	}
}

func TestApplyRefuses(t *testing.T) {
	base := minimal(t)
	for _, c := range []struct{ ops, want string }{
		{`[{"op":"explode"}]`, "unknown op"},
		{`[{"op":"remove_node","id":"n_box","extra":1}]`, "doesn't take extra"},
		{`[{"op":"set_node","id":"n_box","fields":{"fill":"#FF0000"}},{"op":"remove_node","id":"n_gone"}]`, "op 1: n_gone doesn't exist"},
		{`[{"op":"remove_page","id":"p_parts"},{"op":"remove_page","id":"p_flows"}]`, "at least one page"},
		{`[{"op":"set_node","id":"n_box","fields":{"fill":"$nope"}}]`, "token $nope"},
		{`[{"op":"set_token","set":"web","name":"x","mode":"dark","value":"#000000"}]`, "snapshot"},
		{`[{"op":"move_node","id":"n_home","parent":"n_box"}]`, "can't hold children"},
	} {
		if _, err := Apply(base, ops(t, c.ops)); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.ops, err, c.want)
		}
	}
	if err := CheckOp(0, Op{"op": "remove_node", "id": "n_box"}, true); err == nil {
		t.Error("an op without why passed when why is required")
	}
}

func TestApplyEachSkipsStaleOps(t *testing.T) {
	base := minimal(t)
	o := ops(t, `[{"op":"set_node","id":"n_gone","fields":{"name":"x"}},{"op":"set_node","id":"n_box","fields":{"name":"Box"}}]`)
	out, ok, err := ApplyEach(base, o)
	if err != nil || ok[0] || !ok[1] || node(t, out, "n_box")["name"] != "Box" {
		t.Fatal(ok, err)
	}
}

func TestDeps(t *testing.T) {
	o := ops(t, `[{"op":"add_node","parent":"p_flows","node":{"id":"n_new","type":"frame","x":0,"y":0,"w":1,"h":1,"children":[]}},{"op":"set_node","id":"n_box","fields":{"x":1}},{"op":"add_link","from":"n_box","to":"n_new"}]`)
	MintIDs(o)
	deps := Deps(o)
	if len(deps[0]) != 0 || len(deps[1]) != 0 || len(deps[2]) != 1 || deps[2][0] != 0 {
		t.Fatal(deps)
	}
	if !strings.HasPrefix(o[2]["id"].(string), "k_") {
		t.Fatal(o[2])
	}
}

func TestTouchesNamesMintedNodesInOpOrder(t *testing.T) {
	o := ops(t, `[
		{"op":"add_page","page":{"name":"Two"}},
		{"op":"add_node","parent":"p_flows","node":{"type":"frame","x":0,"y":0,"w":1,"h":1,"children":[{"type":"rect","x":0,"y":0,"w":1,"h":1}]}},
		{"op":"set_node","id":"n_box","fields":{"x":1}},
		{"op":"add_sticky","page":"p_flows","x":0,"y":0,"text":"Hi"},
		{"op":"add_link","from":"n_box","to":"n_box"},
		{"op":"set_token","set":"s","name":"t","mode":"dark","value":"#000000"},
		{"op":"link_ticket","node":"n_box","ticket":"T-1"}
	]`)
	MintIDs(o)
	got := Touches(o)
	frame := o[1]["node"].(map[string]any)["id"].(string)
	sticky := o[3]["id"].(string)
	// The frame's root, not its minted child; n_box once although three ops name it.
	if want := []string{frame, "n_box", sticky}; !slices.Equal(got, want) {
		t.Fatalf("Touches = %v, want %v", got, want)
	}
}

func TestRemintAndStarters(t *testing.T) {
	fixture, err := Normalize(read(t, fixtureDir+"/acceptance-design.json"))
	if err != nil {
		t.Fatal(err)
	}
	out, err := Remint(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, `"n_pay"`) || len(out) < len(fixture)/2 {
		t.Fatal("ids weren't reminted")
	}
	for _, s := range Starters {
		body, err := Starter(s)
		if err != nil {
			t.Fatalf("%s: %v", s, err)
		}
		var d map[string]any
		_ = json.Unmarshal([]byte(body), &d)
		if p, _ := Summary(body); p != 1 {
			t.Fatalf("%s: %d pages", s, p)
		}
	}
	if _, err := Starter("nope"); err == nil {
		t.Fatal("unknown starter accepted")
	}
}

// Malformed nodes from an earlier op are refused before a later op walks them.
func TestApplyRefusesMalformedInsertsWithoutPanicking(t *testing.T) {
	base := minimal(t)
	for _, o := range []string{
		`[{"op":"add_node","parent":"p_flows","node":{"id":"n_x"}},{"op":"add_node","parent":"n_x","node":{"type":"text"}}]`,
		`[{"op":"add_node","parent":"p_flows","node":{"id":"n_g","type":"group","x":0,"y":0,"w":1,"h":1,"children":[1]}},{"op":"remove_node","id":"n_box"}]`,
		`[{"op":"add_node","parent":"p_flows","node":{"id":"n_s","type":"shape","shape":"rect","x":0,"y":0,"w":1,"h":1,"text":{"paragraphs":[1]}}},{"op":"set_text","id":"n_s","text":"hi"}]`,
		`[{"op":"add_page","page":{"id":5,"name":"x","children":[{"id":"n_q"}]}},{"op":"move_node","id":"n_box","after":"n_q"}]`,
		`[{"op":"add_node","parent":"p_flows","node":{"id":"n_p","type":"frame","x":0,"y":0,"w":1,"h":1,"children":[{"id":7}]}},{"op":"remove_node","id":"n_p"}]`,
	} {
		if _, err := Apply(base, ops(t, o)); err == nil || !strings.Contains(err.Error(), "op 0") {
			t.Errorf("%s: %v", o, err)
		}
	}
}

// Ops valid only together are all applied when nothing changed underneath.
func TestApplyEachKeepsOpsThatNeedALaterOne(t *testing.T) {
	o := ops(t, `[{"op":"set_node","id":"n_box","fields":{"sizing":{"w":"fill"}}},{"op":"move_node","id":"n_box","parent":"n_home"}]`)
	if _, err := Apply(minimal(t), o); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := ApplyEach(minimal(t), o); err != nil || !ok[0] || !ok[1] {
		t.Fatal(ok, err)
	}
}

func TestComponentsAndTokens(t *testing.T) {
	raw, err := os.ReadFile("../../../docs/design/fixtures/acceptance-design.json")
	if err != nil {
		t.Fatal(err)
	}
	d, err := Parse(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	cs := Components(d)
	if len(cs) != 1 || cs[0].ID != "n_btn" || cs[0].Name != "Button / Primary" || cs[0].Page != "p_components" || len(cs[0].Instances) != 3 {
		t.Fatalf("components = %+v", cs)
	}
	tk := TokensOf(d)
	if tk.TokensCSSChange || tk.Ref["set"] != "dusk-web" || tk.Sets["dusk-web"] == nil {
		t.Fatalf("tokens = %+v", tk.Ref)
	}
	if !slices.Contains(tk.Used, "accent") || !slices.Contains(tk.Used, "text-2") || slices.Contains(tk.Used, "84.00") {
		t.Fatalf("used = %v", tk.Used)
	}
	d["tokens_ref"].(map[string]any)["hash"] = "sha256:old"
	if !TokensOf(d).TokensCSSChange {
		t.Fatal("a stale hash should show tokens.css changed")
	}
}

// The embedded snapshot is the one tokens.css hashes to: run the web's
// npm run gen:design-tokens after editing tokens.css.
func TestTokensSnapshotMatchesTokensCSS(t *testing.T) {
	css, err := os.ReadFile("../../../design-worker/styles/tokens.css")
	if err != nil {
		t.Fatal(err)
	}
	if want := fmt.Sprintf("sha256:%x", sha256.Sum256(css)); TokensHash != want {
		t.Fatalf("TokensHash = %s, tokens.css is %s; run npm run gen:design-tokens in design-worker/", TokensHash, want)
	}
}

// Detaching keeps the instance's overrides in a frame of its own; later edits
// to the main don't reach it, while the remaining instances keep their overrides.
func TestDetachLeavesTheCopyAlone(t *testing.T) {
	raw, err := os.ReadFile("../../../docs/design/fixtures/acceptance-design.json")
	if err != nil {
		t.Fatal(err)
	}
	body, err := Normalize(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	out, err := Apply(body, []Op{
		{"op": "detach", "id": "n_ship_btn"},
		{"op": "set_node", "id": "n_btn", "fields": map[string]any{"fill": "$state-done"}},
		{"op": "set_text", "id": "n_btn_label", "text": "Go"},
	})
	if err != nil {
		t.Fatal(err)
	}
	d, _ := Parse(out)
	ship, _ := find(d, "n_ship_btn")
	if ship.n["type"] != "frame" || ship.n["fill"] != "$accent" {
		t.Fatalf("detached = %v", ship.n)
	}
	label := children(ship.n)[0]
	if label["id"] == "n_btn_label" || !strings.Contains(fmt.Sprint(label["paragraphs"]), "Continue") {
		t.Fatalf("detached label = %v", label)
	}
	pay, _ := find(d, "n_pay_btn")
	if ov := pay.n["overrides"].(map[string]any)["n_btn_label"].(map[string]any); ov["text"] != "Pay $84.00" {
		t.Fatalf("instance overrides = %v", ov)
	}
}

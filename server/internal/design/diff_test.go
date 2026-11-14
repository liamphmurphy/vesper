package design

import (
	"errors"
	"slices"
	"testing"
)

func opNames(ops []Op) []string {
	out := make([]string, len(ops))
	for i, op := range ops {
		out[i] = op["op"].(string)
	}
	return out
}

// diffOf applies steps to base as a persona's turn would, then checks that
// Diff's net ops reproduce the result exactly.
func diffOf(t *testing.T, base, steps string) []Op {
	t.Helper()
	after, err := Apply(base, ops(t, steps))
	if err != nil {
		t.Fatal(err)
	}
	net, err := Diff(base, after, func(id string) string { return "why " + id })
	if err != nil {
		t.Fatalf("diff: %v", err)
	}
	got, err := Apply(base, net)
	if err != nil {
		t.Fatalf("applying the net ops: %v\n%v", err, net)
	}
	if !sameDesign(got, after) {
		t.Fatalf("net ops don't reproduce the turn:\n got %s\nwant %s", got, after)
	}
	return net
}

func TestDiffIsTheNetChange(t *testing.T) {
	base := minimal(t)
	cases := []struct {
		name, steps string
		want        []string
	}{
		{"nothing", `[{"op":"set_node","id":"n_box","fields":{"fill":"#FF0000"}},{"op":"set_node","id":"n_box","fields":{"fill":null}}]`, nil},
		{"added then removed is nothing", `[{"op":"add_node","parent":"p_flows","node":{"id":"n_tmp","type":"shape","shape":"rect","x":0,"y":0,"w":4,"h":4}},{"op":"remove_node","id":"n_tmp"}]`, nil},
		{"added then edited is one add", `[{"op":"add_node","parent":"n_next","node":{"id":"n_new","type":"shape","shape":"rect","x":0,"y":0,"w":4,"h":4}},{"op":"set_node","id":"n_new","fields":{"fill":"#00FF00"}},{"op":"move_node","id":"n_new","x":8}]`, []string{"add_node"}},
		{"edited three times is one change", `[{"op":"set_node","id":"n_box","fields":{"fill":"#FF0000"}},{"op":"set_node","id":"n_box","fields":{"fill":"#00FF00"}},{"op":"set_node","id":"n_box","fields":{"radius":3}}]`, []string{"set_node"}},
		{"a position alone is a move", `[{"op":"move_node","id":"n_box","x":40,"y":12},{"op":"move_node","id":"n_box","x":44}]`, []string{"move_node"}},
		{"text edits fold into one", `[{"op":"set_text","id":"n_title","text":"One"},{"op":"set_text","id":"n_title","text":"Two"}]`, []string{"set_text"}},
		{"added first in a stack", `[{"op":"add_node","parent":"n_home","node":{"id":"n_top","type":"shape","shape":"rect","x":0,"y":0,"w":4,"h":4}},{"op":"move_node","id":"n_top","parent":"n_home","after":"n_btn"},{"op":"move_node","id":"n_title","parent":"n_home","after":"n_top"}]`, []string{"move_node", "add_node"}},
		{"moved into a new frame", `[{"op":"add_node","parent":"p_flows","node":{"id":"n_card","type":"frame","x":0,"y":400,"w":200,"h":200,"children":[]}},{"op":"move_node","id":"n_box","parent":"n_card"}]`, []string{"add_node", "move_node"}},
		{"page and link", `[{"op":"add_page","page":{"id":"p_more","name":"More"}},{"op":"set_page","id":"p_flows","name":"Flow"},{"op":"set_link","id":"k_go","transition":"instant"}]`, []string{"set_page", "add_page", "set_link"}},
		{"removed with what hangs off it", `[{"op":"remove_node","id":"n_next"}]`, []string{"remove_node"}},
		{"a component made and edited", `[{"op":"add_node","parent":"p_parts","node":{"id":"n_chip","type":"frame","x":300,"y":0,"w":80,"h":32,"children":[]}},{"op":"create_component","id":"n_chip","name":"Chip"}]`, []string{"add_node"}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			net := diffOf(t, base, c.steps)
			if got := opNames(net); !slices.Equal(got, c.want) {
				t.Fatalf("ops %v, want %v: %v", got, c.want, net)
			}
			for _, op := range net {
				if op["why"] == nil && op["op"] != "set_token" {
					t.Fatalf("op without a why: %v", op)
				}
			}
		})
	}
}

// A persona that starts from a starter and replaces its placeholder frames
// has nothing of the starter left in its net change.
func TestDiffDropsReplacedStarterFrames(t *testing.T) {
	blank, err := Starter("blank")
	if err != nil {
		t.Fatal(err)
	}
	starter, err := Starter("mobile-flow")
	if err != nil {
		t.Fatal(err)
	}
	seed, err := Diff(blank, starter, nil)
	if err != nil {
		t.Fatal(err)
	}
	drafted, err := Apply(blank, seed)
	if err != nil {
		t.Fatal(err)
	}
	d, _ := Parse(drafted)
	page := pages(d)[0]["id"].(string)
	var steps []Op
	for _, f := range children(pages(d)[0]) {
		steps = append(steps, Op{"op": "remove_node", "id": f["id"]})
	}
	steps = append(steps, Op{"op": "add_node", "parent": page, "node": map[string]any{"id": "n_signin", "type": "frame", "name": "Sign in", "x": 0.0, "y": 0.0, "w": 393.0, "h": 852.0, "children": []any{}}})
	final, err := Apply(drafted, steps)
	if err != nil {
		t.Fatal(err)
	}
	net, err := Diff(blank, final, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, op := range net {
		if n, ok := op["node"].(map[string]any); ok && slices.Contains([]any{"Start", "Details", "Done"}, n["name"]) {
			t.Fatalf("the starter's %v is in the net change: %v", n["name"], net)
		}
		if op["op"] == "remove_node" {
			t.Fatalf("nothing of blank was removed, got %v", net)
		}
	}
}

func TestDiffRefusesWhatOpsCantSay(t *testing.T) {
	base := minimal(t)
	d, _ := Parse(base)
	d["mode"] = "dark"
	if d["mode"] == Doc(must(Parse(base)))["mode"] {
		d["mode"] = "light"
	}
	changed, err := Finish(d)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Diff(base, changed, nil); !errors.Is(err, ErrNoNetDiff) {
		t.Fatalf("got %v, want ErrNoNetDiff", err)
	}
}

func must(d Doc, err error) Doc {
	if err != nil {
		panic(err)
	}
	return d
}

// Every starter can be drafted onto a blank design as ops: a persona's
// design_create puts the starter in its draft rather than in version 1.
func TestDiffFromBlankToEachStarter(t *testing.T) {
	blank, err := Starter("blank")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range Starters[1:] {
		starter, err := Starter(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := Diff(blank, starter, nil); err != nil {
			t.Fatalf("%s: %v", name, err)
		}
	}
}

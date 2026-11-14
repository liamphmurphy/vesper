package design

import (
	"errors"
	"reflect"
	"slices"
	"sort"
)

// ErrNoNetDiff means Diff can't express the change between two designs as
// ops that reproduce it exactly (a page reorder, a new token set), so the
// caller should keep the ops that made it instead.
var ErrNoNetDiff = errors.New("design: no net diff reproduces this change")

// Diff returns ops that turn before into after: the net change, with none of
// the steps that made it. A layer added and then removed again is absent; one
// added and then edited is a single add_node with its final fields; a layer
// edited three times is one set_node. why names each op's reason by the id it
// is about. Diff checks its result by applying it to before, and returns
// ErrNoNetDiff when that doesn't reproduce after.
func Diff(before, after string, why func(id string) string) ([]Op, error) {
	w, err := Parse(before)
	if err != nil {
		return nil, err
	}
	t, err := Parse(after)
	if err != nil {
		return nil, err
	}
	for _, k := range []string{"schema", "mode", "assets", "tokens_ref"} {
		if !reflect.DeepEqual(w[k], t[k]) {
			return nil, ErrNoNetDiff
		}
	}
	df := differ{w: w, t: t, why: why}
	// Layers go before links, so a link that goes with its layer isn't a change of its own.
	steps := []func() error{df.pages, df.retyped, df.placeAll, df.fields, df.removeGone, df.links, df.tokens}
	for _, step := range steps {
		if err := step(); err != nil {
			return nil, err
		}
	}
	if len(df.ops) == 0 {
		return nil, nil
	}
	got, err := Apply(before, df.ops)
	if err != nil || !sameDesign(got, after) {
		return nil, ErrNoNetDiff
	}
	return df.ops, nil
}

// differ builds the ops on a working copy w of before, applying each as it
// goes, so every later op is computed against what the earlier ones made.
type differ struct {
	w, t Doc
	why  func(id string) string
	ops  []Op
}

func (df *differ) emit(about string, op Op) error {
	if df.why != nil {
		if y := df.why(about); y != "" {
			op["why"] = y
		}
	}
	// Apply consumes a copy; the stored op keeps its own values.
	if err := applyOp(df.w, clone(op).(map[string]any)); err != nil {
		return ErrNoNetDiff
	}
	normalizeDoc(df.w)
	df.ops = append(df.ops, op)
	return nil
}

// where indexes a design's nodes: each node and the id of the page or
// container holding it.
type where struct {
	n      map[string]any
	holder string
}

func index(d Doc) map[string]where {
	out := map[string]where{}
	for _, p := range pages(d) {
		var visit func(h map[string]any)
		visit = func(h map[string]any) {
			for _, c := range children(h) {
				if id, ok := c["id"].(string); ok {
					out[id] = where{n: c, holder: h["id"].(string)}
				}
				visit(c)
			}
		}
		visit(p)
	}
	return out
}

// fresh copies a node of after without the layers that already exist in the
// working copy: those are moved into place rather than added twice.
func fresh(n map[string]any, have map[string]where) map[string]any {
	out := map[string]any{}
	for k, v := range n {
		if k != "children" {
			out[k] = clone(v)
		}
	}
	if _, ok := n["children"]; ok {
		kids := []any{}
		for _, c := range children(n) {
			if _, ok := have[c["id"].(string)]; !ok {
				kids = append(kids, fresh(c, have))
			}
		}
		out["children"] = kids
	}
	return out
}

// pages adds new pages (with their new layers) and renames changed ones.
// Pages that go are removed last, once their layers have moved out.
func (df *differ) pages() error {
	have := map[string]map[string]any{}
	for _, p := range pages(df.w) {
		have[p["id"].(string)] = p
	}
	prev := ""
	for _, tp := range pages(df.t) {
		id := tp["id"].(string)
		if wp, ok := have[id]; ok {
			op := Op{"op": "set_page", "id": id}
			for _, k := range []string{"name", "background"} {
				if !reflect.DeepEqual(wp[k], tp[k]) {
					op[k] = tp[k]
				}
			}
			if len(op) > 2 {
				if err := df.emit(id, op); err != nil {
					return err
				}
			}
		} else {
			op := Op{"op": "add_page", "page": fresh(tp, index(df.w))}
			if prev != "" {
				op["after"] = prev
			}
			if err := df.emit(id, op); err != nil {
				return err
			}
		}
		prev = id
	}
	return nil
}

// retyped removes layers whose type changed (a frame made a component, an
// instance detached): no op edits a type, so they come back as new layers.
func (df *differ) retyped() error {
	tx, wx := index(df.t), index(df.w)
	ids := make([]string, 0, len(wx))
	for id := range wx {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		if tn, ok := tx[id]; ok && wx[id].n["type"] != tn.n["type"] {
			if _, still := index(df.w)[id]; !still {
				continue
			}
			if err := df.emit(id, Op{"op": "remove_node", "id": id}); err != nil {
				return err
			}
		}
	}
	return nil
}

// placeAll puts every page's and container's children in after's order,
// parents first: new layers are added, layers from elsewhere moved in, and
// layers out of order moved, keeping the longest run already in order.
func (df *differ) placeAll() error {
	holders := []map[string]any{}
	for _, p := range pages(df.t) {
		holders = append(holders, p)
	}
	Walk(df.t, func(n, _, _ map[string]any, _ int) {
		if _, ok := n["children"]; ok {
			holders = append(holders, n)
		}
	})
	for _, h := range holders {
		if err := df.place(h); err != nil {
			return err
		}
	}
	return nil
}

func (df *differ) place(th map[string]any) error {
	hid := th["id"].(string)
	var target []string
	for _, c := range children(th) {
		target = append(target, c["id"].(string))
	}
	have, tx := index(df.w), index(df.t)
	var cur []string
	for _, c := range df.holderKids(hid) {
		cur = append(cur, c["id"].(string))
	}
	keep := lcs(cur, target)
	// Back to front, so each layer goes before one that is already in place.
	next := ""
	for i := len(target) - 1; i >= 0; i-- {
		id := target[i]
		at, exists := have[id]
		var op Op
		switch {
		case !exists:
			op = Op{"op": "add_node", "parent": hid, "node": fresh(tx[id].n, have)}
		case at.holder != hid || !keep[id]:
			op = Op{"op": "move_node", "id": id, "parent": hid}
		}
		if op != nil {
			if next != "" {
				op["before"] = next
			}
			if err := df.emit(id, op); err != nil {
				return err
			}
			have = index(df.w)
		}
		next = id
	}
	return nil
}

func (df *differ) holderKids(id string) []map[string]any {
	for _, p := range pages(df.w) {
		if p["id"] == id {
			return children(p)
		}
	}
	if at, ok := index(df.w)[id]; ok {
		return children(at.n)
	}
	return nil
}

// lcs marks the ids of the longest common subsequence of a and b.
func lcs(a, b []string) map[string]bool {
	m, n := len(a), len(b)
	dp := make([][]int, m+1)
	for i := range dp {
		dp[i] = make([]int, n+1)
	}
	for i := m - 1; i >= 0; i-- {
		for j := n - 1; j >= 0; j-- {
			if a[i] == b[j] {
				dp[i][j] = dp[i+1][j+1] + 1
			} else {
				dp[i][j] = max(dp[i+1][j], dp[i][j+1])
			}
		}
	}
	out := map[string]bool{}
	for i, j := 0, 0; i < m && j < n; {
		switch {
		case a[i] == b[j]:
			out[a[i]] = true
			i, j = i+1, j+1
		case dp[i+1][j] >= dp[i][j+1]:
			i++
		default:
			j++
		}
	}
	return out
}

// fields edits every layer both designs have to after's fields: its text with
// set_text, a change of position alone with move_node, the rest with set_node.
func (df *differ) fields() error {
	tx := index(df.t)
	wx := index(df.w)
	ids := make([]string, 0, len(wx))
	for id := range wx {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		tn, ok := tx[id]
		if !ok {
			continue
		}
		wn := wx[id].n
		var textOp Op
		skip := map[string]bool{"id": true, "type": true, "children": true}
		switch wn["type"] {
		case "text":
			skip["paragraphs"] = true
			if !reflect.DeepEqual(wn["paragraphs"], tn.n["paragraphs"]) {
				textOp = Op{"op": "set_text", "id": id, "paragraphs": clone(tn.n["paragraphs"])}
			}
		case "sticky":
			if s, ok := tn.n["text"].(string); ok && !reflect.DeepEqual(wn["text"], s) {
				skip["text"] = true
				textOp = Op{"op": "set_text", "id": id, "text": s}
			}
		case "shape":
			wt, _ := wn["text"].(map[string]any)
			tt, _ := tn.n["text"].(map[string]any)
			if wt != nil && tt != nil && !reflect.DeepEqual(wt, tt) && sameExcept(wt, tt, "paragraphs") {
				skip["text"] = true
				textOp = Op{"op": "set_text", "id": id, "paragraphs": clone(tt["paragraphs"])}
			}
		}
		fs := map[string]any{}
		for _, k := range unionKeys(wn, tn.n) {
			if skip[k] || reflect.DeepEqual(wn[k], tn.n[k]) {
				continue
			}
			fs[k] = clone(tn.n[k]) // nil removes it
		}
		if textOp != nil {
			if err := df.emit(id, textOp); err != nil {
				return err
			}
		}
		if len(fs) == 0 {
			continue
		}
		op := Op{"op": "set_node", "id": id, "fields": fs}
		if onlyKeys(fs, "x", "y") {
			op = Op{"op": "move_node", "id": id}
			for k, v := range fs {
				op[k] = v
			}
		}
		if err := df.emit(id, op); err != nil {
			return err
		}
	}
	return nil
}

func sameExcept(a, b map[string]any, k string) bool {
	for _, key := range unionKeys(a, b) {
		if key != k && !reflect.DeepEqual(a[key], b[key]) {
			return false
		}
	}
	return true
}

func onlyKeys(m map[string]any, keys ...string) bool {
	for k := range m {
		if !slices.Contains(keys, k) {
			return false
		}
	}
	return true
}

func unionKeys(a, b map[string]any) []string {
	seen := map[string]bool{}
	var out []string
	for _, m := range []map[string]any{a, b} {
		for k := range m {
			if !seen[k] {
				seen[k] = true
				out = append(out, k)
			}
		}
	}
	sort.Strings(out)
	return out
}

var linkFields = []string{"from", "to", "trigger", "transition", "delay_ms", "duration_ms"}

// links adds, changes and removes prototype links by id.
func (df *differ) links() error {
	have := map[string]map[string]any{}
	for _, l := range links(df.w) {
		have[l["id"].(string)] = l
	}
	want := map[string]bool{}
	for _, tl := range links(df.t) {
		id := tl["id"].(string)
		want[id] = true
		wl, ok := have[id]
		if !ok {
			op := Op{"op": "add_link", "id": id}
			for _, k := range linkFields {
				if v, ok := tl[k]; ok {
					op[k] = v
				}
			}
			if err := df.emit(fieldStr(tl, "from"), op); err != nil {
				return err
			}
			continue
		}
		op := Op{"op": "set_link", "id": id}
		for _, k := range linkFields {
			if !reflect.DeepEqual(wl[k], tl[k]) {
				op[k] = tl[k]
			}
		}
		if len(op) > 2 {
			if err := df.emit(fieldStr(tl, "from"), op); err != nil {
				return err
			}
		}
	}
	for _, wl := range links(df.w) {
		if id := wl["id"].(string); !want[id] {
			if err := df.emit(fieldStr(wl, "from"), Op{"op": "remove_link", "id": id}); err != nil {
				return err
			}
		}
	}
	return nil
}

func fieldStr(m map[string]any, k string) string { s, _ := m[k].(string); return s }

// tokens sets the tokens after has in sets both designs have. A new or
// removed set has no op, so it has no net diff.
func (df *differ) tokens() error {
	ws, _ := df.w["token_sets"].(map[string]any)
	ts, _ := df.t["token_sets"].(map[string]any)
	if len(ws) != len(ts) {
		return ErrNoNetDiff
	}
	for _, name := range sortedKeys(ts) {
		wset, _ := ws[name].(map[string]any)
		tset, _ := ts[name].(map[string]any)
		if wset == nil || !sameExcept(wset, tset, "modes") {
			return ErrNoNetDiff
		}
		wm, _ := wset["modes"].(map[string]any)
		tm, _ := tset["modes"].(map[string]any)
		for _, mode := range []string{"dark", "light"} {
			wt, _ := wm[mode].(map[string]any)
			tt, _ := tm[mode].(map[string]any)
			for _, tok := range unionKeys(wt, tt) {
				if reflect.DeepEqual(wt[tok], tt[tok]) {
					continue
				}
				var value any
				if v, ok := tt[tok].(map[string]any); ok {
					value = v["value"]
				}
				if err := df.emit("", Op{"op": "set_token", "set": name, "name": tok, "mode": mode, "value": value}); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

// removeGone removes the layers and pages after doesn't have, outermost first.
func (df *differ) removeGone() error {
	tx := index(df.t)
	var gone, wires []string
	Walk(df.w, func(n, _, _ map[string]any, _ int) {
		if _, ok := tx[n["id"].(string)]; !ok {
			if n["type"] == "connector" {
				wires = append(wires, n["id"].(string))
			} else {
				gone = append(gone, n["id"].(string))
			}
		}
	})
	// Connectors last: most go with the layer they join.
	gone = append(gone, wires...)
	for _, id := range gone {
		// Removing a layer takes its children and the connectors to it with it.
		if _, still := index(df.w)[id]; !still {
			continue
		}
		if err := df.emit(id, Op{"op": "remove_node", "id": id}); err != nil {
			return err
		}
	}
	keep := map[string]bool{}
	for _, p := range pages(df.t) {
		keep[p["id"].(string)] = true
	}
	for _, p := range pages(df.w) {
		if id := p["id"].(string); !keep[id] {
			if err := df.emit(id, Op{"op": "remove_page", "id": id}); err != nil {
				return err
			}
		}
	}
	return nil
}

// sameDesign compares two normalised bodies, ignoring the order of links,
// which nothing reads.
func sameDesign(a, b string) bool {
	da, err1 := Parse(a)
	db, err2 := Parse(b)
	if err1 != nil || err2 != nil {
		return false
	}
	for _, d := range []Doc{da, db} {
		ls, _ := d["links"].([]any)
		sort.SliceStable(ls, func(i, j int) bool {
			return fieldStr(ls[i].(map[string]any), "id") < fieldStr(ls[j].(map[string]any), "id")
		})
	}
	return reflect.DeepEqual(da, db)
}

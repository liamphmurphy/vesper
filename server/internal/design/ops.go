package design

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

// Op is one design_patch op (ADR §3.9): {op, …fields, why}. Generic, so each
// op's fields are checked here and anything unknown is refused.
type Op = map[string]any

// MaxWhy bounds an op's why.
const MaxWhy = 280

// NewID mints an opaque id: prefix, underscore, 10 base32 characters.
func NewID(prefix string) string {
	const alphabet = "abcdefghijklmnopqrstuvwxyz234567"
	b := make([]byte, 10)
	_, _ = rand.Read(b)
	for i := range b {
		b[i] = alphabet[int(b[i])%len(alphabet)]
	}
	return prefix + "_" + string(b)
}

// opFields lists each op's allowed fields (besides op and why) and the
// required ones (prefixed with !).
var opFields = map[string][]string{
	"add_page":         {"!page", "after"},
	"set_page":         {"!id", "name", "background"},
	"remove_page":      {"!id"},
	"add_node":         {"!parent", "after", "before", "!node"},
	"set_node":         {"!id", "!fields"},
	"move_node":        {"!id", "parent", "after", "before", "x", "y"},
	"remove_node":      {"!id"},
	"set_text":         {"!id", "paragraphs", "text"},
	"connect":          {"id", "!from", "!to", "label", "route", "stroke", "stroke_width", "dash", "start_arrow", "end_arrow", "from_anchor", "to_anchor"},
	"add_sticky":       {"id", "!page", "!x", "!y", "!text", "color", "author"},
	"add_link":         {"id", "!from", "!to", "trigger", "delay_ms", "transition", "duration_ms"},
	"set_link":         {"!id", "trigger", "delay_ms", "transition", "duration_ms", "from", "to"},
	"remove_link":      {"!id"},
	"create_component": {"!id", "name"},
	"instantiate":      {"id", "!component", "!parent", "!x", "!y", "after", "overrides"},
	"set_overrides":    {"!id", "!overrides"},
	"detach":           {"!id"},
	"set_token":        {"!set", "!name", "!mode", "!value"},
	"link_ticket":      {"!node", "!ticket"},
	"unlink_ticket":    {"!node", "!ticket"},
}

// OpNames are the ops, for tool descriptions.
func OpNames() []string {
	names := make([]string, 0, len(opFields))
	for k := range opFields {
		names = append(names, k)
	}
	slices.Sort(names)
	return names
}

func opErr(i int, format string, args ...any) error {
	return apperr.Invalid("ops", "op %d: %s", i, fmt.Sprintf(format, args...))
}

// CheckOp checks an op's name and fields, and its why when requireWhy.
func CheckOp(i int, op Op, requireWhy bool) error {
	name, _ := op["op"].(string)
	allowed, ok := opFields[name]
	if !ok {
		return opErr(i, "unknown op %q; use one of %s", name, strings.Join(OpNames(), ", "))
	}
	known := map[string]bool{"op": true, "why": true}
	for _, f := range allowed {
		req := strings.HasPrefix(f, "!")
		f = strings.TrimPrefix(f, "!")
		known[f] = true
		if _, ok := op[f]; req && !ok {
			return opErr(i, "%s needs %s", name, f)
		}
	}
	for k := range op {
		if !known[k] {
			return opErr(i, "%s doesn't take %s", name, k)
		}
	}
	if field(op, "after") != "" && field(op, "before") != "" {
		return opErr(i, "give after or before, not both")
	}
	why, hasWhy := op["why"].(string)
	if _, set := op["why"]; set && !hasWhy {
		return opErr(i, "why must be a string")
	}
	if requireWhy && strings.TrimSpace(why) == "" {
		return opErr(i, "say why: every op needs a short why for the person reviewing it")
	}
	if utf8.RuneCountInString(why) > MaxWhy {
		return opErr(i, "why is at most %d characters", MaxWhy)
	}
	return nil
}

// MintIDs gives every page, node and link an op creates an id where it has
// none, in place, so a stored proposal names what it adds.
func MintIDs(ops []Op) {
	var mintNode func(n map[string]any)
	mintNode = func(n map[string]any) {
		if _, ok := n["id"]; !ok {
			n["id"] = NewID("n")
		}
		for _, c := range children(n) {
			mintNode(c)
		}
	}
	for _, op := range ops {
		switch op["op"] {
		case "add_page":
			if p, ok := op["page"].(map[string]any); ok {
				if _, ok := p["id"]; !ok {
					p["id"] = NewID("p")
				}
				for _, c := range children(p) {
					mintNode(c)
				}
			}
		case "add_node":
			if n, ok := op["node"].(map[string]any); ok {
				mintNode(n)
			}
		case "connect", "add_sticky", "instantiate":
			if _, ok := op["id"]; !ok {
				op["id"] = NewID("n")
			}
		case "add_link":
			if _, ok := op["id"]; !ok {
				op["id"] = NewID("k")
			}
		}
	}
}

// Creates lists the ids an op adds.
func Creates(op Op) []string {
	var out []string
	var collect func(n map[string]any)
	collect = func(n map[string]any) {
		if id, ok := n["id"].(string); ok {
			out = append(out, id)
		}
		for _, c := range children(n) {
			collect(c)
		}
	}
	switch op["op"] {
	case "add_page", "add_node":
		key := "page"
		if op["op"] == "add_node" {
			key = "node"
		}
		if n, ok := op[key].(map[string]any); ok {
			collect(n)
		}
	case "connect", "add_sticky", "instantiate", "add_link":
		if id, ok := op["id"].(string); ok {
			out = append(out, id)
		}
	}
	return out
}

// Touches lists the node each op is about, in op order and without repeats:
// the root it adds, else the node it changes. Run it after MintIDs, so a node
// the persona left unnamed is listed by the id it was given. Pages, links and
// tokens aren't nodes, so ops only about them add nothing.
func Touches(ops []Op) []string {
	var out []string
	add := func(v any) bool {
		s, ok := v.(string)
		if !ok || !strings.HasPrefix(s, "n_") {
			return false
		}
		if !slices.Contains(out, s) {
			out = append(out, s)
		}
		return true
	}
	for _, op := range ops {
		if created := Creates(op); len(created) > 0 && add(created[0]) {
			continue
		}
		for _, k := range []string{"id", "node", "from"} {
			if add(op[k]) {
				break
			}
		}
	}
	return out
}

// refs lists the ids an op points at (other than those it creates).
func refs(op Op) []string {
	var out []string
	for _, k := range []string{"id", "parent", "after", "before", "page", "from", "to", "component", "node"} {
		if s, ok := op[k].(string); ok {
			out = append(out, s)
		}
	}
	created := Creates(op)
	return slices.DeleteFunc(out, func(s string) bool { return slices.Contains(created, s) })
}

// Deps says, for each op, which earlier ops create something it refers to:
// accepting op j needs every op in Deps[j].
func Deps(ops []Op) [][]int {
	by := map[string]int{}
	deps := make([][]int, len(ops))
	for j, op := range ops {
		for _, r := range refs(op) {
			if i, ok := by[r]; ok && !slices.Contains(deps[j], i) {
				deps[j] = append(deps[j], i)
			}
		}
		for _, id := range Creates(op) {
			by[id] = j
		}
	}
	return deps
}

// Apply runs ops in order on a body and returns the normalised result. Any
// op that fails refuses the whole patch, naming it.
func Apply(body string, ops []Op) (string, error) {
	d, err := Parse(body)
	if err != nil {
		return "", err
	}
	if ops, err = asJSON(ops); err != nil {
		return "", err
	}
	MintIDs(ops)
	for i, op := range ops {
		if err := CheckOp(i, op, false); err != nil {
			return "", err
		}
		if err := applyOp(d, op); err != nil {
			return "", opErr(i, "%s", err.Error())
		}
		// Later ops walk what this one added, so its structure must hold
		// now; the cross-reference rules wait for the end, since a later op
		// may complete what an earlier one starts.
		normalizeDoc(d)
		if err := cDesign(d, ""); err != nil {
			return "", opErr(i, "%s", strings.TrimPrefix(err.Error(), "body: "))
		}
	}
	out, err := Finish(d)
	if err != nil {
		return "", apperr.Invalid("ops", "the result isn't a valid design: %s", strings.TrimPrefix(err.Error(), "body: "))
	}
	return out, nil
}

// ApplyEach applies ops together when they still apply; otherwise one by one
// on a body, skipping any op that no longer applies (its target is gone, or
// the result wouldn't be valid). It returns
// the result and, per op, whether it was applied.
func ApplyEach(body string, ops []Op) (string, []bool, error) {
	d, err := Parse(body)
	if err != nil {
		return "", nil, err
	}
	if ops, err = asJSON(ops); err != nil {
		return "", nil, err
	}
	ok := make([]bool, len(ops))
	// All together first: an op may only be valid with a later one (a token
	// it uses, the auto layout its fill sizing needs).
	if out, err := Apply(body, ops); err == nil {
		for i := range ok {
			ok[i] = true
		}
		return out, ok, nil
	}
	for i, op := range ops {
		next := clone(d).(map[string]any)
		if CheckOp(i, op, false) != nil || applyOp(next, op) != nil {
			continue
		}
		normalizeDoc(next)
		if Validate(next) != nil {
			continue
		}
		d, ok[i] = next, true
	}
	out, err := Finish(d)
	return out, ok, err
}

// asJSON copies ops through JSON, so values built in Go (ints, typed maps)
// look exactly like ops decoded from a request.
func asJSON(ops []Op) ([]Op, error) {
	raw, err := json.Marshal(ops)
	if err != nil {
		return nil, apperr.Invalid("ops", "can't be encoded: %v", err)
	}
	return DecodeOps(raw)
}

func clone(v any) any {
	switch t := v.(type) {
	case map[string]any:
		m := make(map[string]any, len(t))
		for k, x := range t {
			m[k] = clone(x)
		}
		return m
	case []any:
		a := make([]any, len(t))
		for i, x := range t {
			a[i] = clone(x)
		}
		return a
	}
	return v
}

// loc is where a node sits: its holder (a page or container) and index.
type loc struct {
	n, holder, page map[string]any
	i               int
}

func find(d Doc, id string) (loc, bool) {
	var out loc
	found := false
	var visit func(holder, page map[string]any)
	visit = func(holder, page map[string]any) {
		for i, c := range children(holder) {
			if found {
				return
			}
			if c["id"] == id {
				out, found = loc{n: c, holder: holder, page: page, i: i}, true
				return
			}
			visit(c, page)
		}
	}
	for _, p := range pages(d) {
		if !found {
			visit(p, p)
		}
	}
	return out, found
}

func findPage(d Doc, id string) (int, map[string]any, bool) {
	for i, p := range pages(d) {
		if p["id"] == id {
			return i, p, true
		}
	}
	return 0, nil, false
}

// holderOf is a page or a container node by id.
func holderOf(d Doc, id string) (holder, page map[string]any, err error) {
	if _, p, ok := findPage(d, id); ok {
		return p, p, nil
	}
	l, ok := find(d, id)
	if !ok {
		return nil, nil, fmt.Errorf("%s doesn't exist", id)
	}
	if !Containers[l.n["type"].(string)] {
		return nil, nil, fmt.Errorf("%s is a %s, which can't hold children", id, l.n["type"])
	}
	return l.n, l.page, nil
}

func field(op Op, k string) string { s, _ := op[k].(string); return s }

// insert puts n into holder's children after the sibling id after, before
// the sibling id before, or on top when neither is given.
func insert(holder map[string]any, n any, after, before string) error {
	kids, _ := holder["children"].([]any)
	at := len(kids)
	index := func(id string) int {
		return slices.IndexFunc(kids, func(c any) bool { m, _ := c.(map[string]any); return m["id"] == id })
	}
	switch {
	case after != "":
		if at = index(after); at < 0 {
			return fmt.Errorf("after: %s isn't a child of %s", after, holder["id"])
		}
		at++
	case before != "":
		if at = index(before); at < 0 {
			return fmt.Errorf("before: %s isn't a child of %s", before, holder["id"])
		}
	}
	holder["children"] = slices.Insert(kids, at, n)
	return nil
}

func detachAt(l loc) {
	kids := l.holder["children"].([]any)
	l.holder["children"] = slices.Delete(kids, l.i, l.i+1)
}

func subtreeIDs(n map[string]any, into map[string]bool) {
	into[n["id"].(string)] = true
	for _, c := range children(n) {
		subtreeIDs(c, into)
	}
}

// prune drops connectors, links and instance overrides that point into gone.
func prune(d Doc, gone map[string]bool) {
	var visit func(holder map[string]any)
	visit = func(holder map[string]any) {
		kids, _ := holder["children"].([]any)
		kept := kids[:0]
		for _, c := range kids {
			m := c.(map[string]any)
			if m["type"] == "connector" {
				from, _ := m["from"].(map[string]any)
				to, _ := m["to"].(map[string]any)
				if gone[fmt.Sprint(from["node"])] || gone[fmt.Sprint(to["node"])] {
					continue
				}
			}
			if ov, ok := m["overrides"].(map[string]any); ok {
				for k := range ov {
					if gone[k] {
						delete(ov, k)
					}
				}
				if len(ov) == 0 {
					delete(m, "overrides")
				}
			}
			visit(m)
			kept = append(kept, m)
		}
		if holder["children"] != nil {
			holder["children"] = kept
		}
	}
	for _, p := range pages(d) {
		visit(p)
	}
	ls, _ := d["links"].([]any)
	d["links"] = slices.DeleteFunc(ls, func(l any) bool {
		m := l.(map[string]any)
		return gone[fmt.Sprint(m["from"])] || gone[fmt.Sprint(m["to"])]
	})
}

func asObject(v any, what string) (map[string]any, error) {
	m, ok := v.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("%s must be an object", what)
	}
	return m, nil
}

// lowestContainer is the deepest page or non-group container holding both nodes.
func lowestContainer(d Doc, a, b string) (map[string]any, error) {
	var chainOf func(id string) ([]map[string]any, map[string]any, error)
	chainOf = func(id string) ([]map[string]any, map[string]any, error) {
		for _, p := range pages(d) {
			var path []map[string]any
			var walk func(h map[string]any) bool
			walk = func(h map[string]any) bool {
				for _, c := range children(h) {
					if c["id"] == id {
						return true
					}
					path = append(path, c)
					if walk(c) {
						return true
					}
					path = path[:len(path)-1]
				}
				return false
			}
			if walk(p) {
				return path, p, nil
			}
		}
		return nil, nil, fmt.Errorf("%s doesn't exist", id)
	}
	pa, pageA, err := chainOf(a)
	if err != nil {
		return nil, err
	}
	pb, pageB, err := chainOf(b)
	if err != nil {
		return nil, err
	}
	if pageA["id"] != pageB["id"] {
		return nil, fmt.Errorf("%s and %s are on different pages", a, b)
	}
	holder := pageA
	for i := 0; i < len(pa) && i < len(pb) && pa[i]["id"] == pb[i]["id"]; i++ {
		if pa[i]["type"] != "group" {
			holder = pa[i]
		} else {
			break
		}
	}
	return holder, nil
}

func applyOp(d Doc, op Op) error {
	switch op["op"] {
	case "add_page":
		p, err := asObject(op["page"], "page")
		if err != nil {
			return err
		}
		if _, ok := p["children"]; !ok {
			p["children"] = []any{}
		}
		if _, ok := p["id"]; !ok {
			p["id"] = NewID("p")
		}
		list, _ := d["pages"].([]any)
		at := len(list)
		if after := field(op, "after"); after != "" {
			i, _, ok := findPage(d, after)
			if !ok {
				return fmt.Errorf("after: page %s doesn't exist", after)
			}
			at = i + 1
		}
		d["pages"] = slices.Insert(list, at, any(p))
	case "set_page":
		_, p, ok := findPage(d, field(op, "id"))
		if !ok {
			return fmt.Errorf("page %s doesn't exist", op["id"])
		}
		for _, k := range []string{"name", "background"} {
			if v, ok := op[k]; ok {
				if v == nil {
					delete(p, k)
				} else {
					p[k] = v
				}
			}
		}
	case "remove_page":
		i, p, ok := findPage(d, field(op, "id"))
		if !ok {
			return fmt.Errorf("page %s doesn't exist", op["id"])
		}
		if len(pages(d)) == 1 {
			return fmt.Errorf("a design keeps at least one page")
		}
		gone := map[string]bool{}
		for _, c := range children(p) {
			subtreeIDs(c, gone)
		}
		d["pages"] = slices.Delete(d["pages"].([]any), i, i+1)
		prune(d, gone)
	case "add_node":
		n, err := asObject(op["node"], "node")
		if err != nil {
			return err
		}
		holder, _, err := holderOf(d, field(op, "parent"))
		if err != nil {
			return err
		}
		return insert(holder, n, field(op, "after"), field(op, "before"))
	case "set_node":
		l, ok := find(d, field(op, "id"))
		if !ok {
			return fmt.Errorf("%s doesn't exist", op["id"])
		}
		fs, err := asObject(op["fields"], "fields")
		if err != nil {
			return err
		}
		for k, v := range fs {
			switch k {
			case "id", "type", "children", "paragraphs":
				return fmt.Errorf("set_node can't change %s", k)
			}
			if v == nil {
				delete(l.n, k)
			} else {
				l.n[k] = v
			}
		}
	case "move_node":
		id := field(op, "id")
		l, ok := find(d, id)
		if !ok {
			return fmt.Errorf("%s doesn't exist", id)
		}
		for _, k := range []string{"x", "y"} {
			if v, ok := op[k]; ok {
				l.n[k] = v
			}
		}
		parent, after, before := field(op, "parent"), field(op, "after"), field(op, "before")
		if parent == "" && after == "" && before == "" {
			return nil
		}
		if parent == "" {
			sibling, which := after, "after"
			if sibling == "" {
				sibling, which = before, "before"
			}
			sl, ok := find(d, sibling)
			if !ok {
				return fmt.Errorf("%s: %s doesn't exist", which, sibling)
			}
			parent = sl.holder["id"].(string)
		}
		inside := map[string]bool{}
		subtreeIDs(l.n, inside)
		if inside[parent] {
			return fmt.Errorf("can't move %s into itself", id)
		}
		holder, _, err := holderOf(d, parent)
		if err != nil {
			return err
		}
		if after == id || before == id {
			return nil
		}
		detachAt(l)
		return insert(holder, l.n, after, before)
	case "remove_node":
		l, ok := find(d, field(op, "id"))
		if !ok {
			return fmt.Errorf("%s doesn't exist", op["id"])
		}
		gone := map[string]bool{}
		subtreeIDs(l.n, gone)
		detachAt(l)
		prune(d, gone)
	case "set_text":
		return setText(d, op)
	case "connect":
		holder, err := lowestContainer(d, field(op, "from"), field(op, "to"))
		if err != nil {
			return err
		}
		n := map[string]any{"id": op["id"], "type": "connector"}
		from := map[string]any{"node": op["from"]}
		to := map[string]any{"node": op["to"]}
		if a, ok := op["from_anchor"]; ok {
			from["anchor"] = a
		}
		if a, ok := op["to_anchor"]; ok {
			to["anchor"] = a
		}
		n["from"], n["to"] = from, to
		if _, ok := op["route"]; !ok {
			n["route"] = "orthogonal"
		}
		for _, k := range []string{"label", "route", "stroke", "stroke_width", "dash", "start_arrow", "end_arrow"} {
			if v, ok := op[k]; ok {
				n[k] = v
			}
		}
		if _, ok := n["end_arrow"]; !ok {
			n["end_arrow"] = "arrow"
		}
		return insert(holder, n, "", "")
	case "add_sticky":
		_, p, ok := findPage(d, field(op, "page"))
		if !ok {
			return fmt.Errorf("page %s doesn't exist", op["page"])
		}
		n := map[string]any{"id": op["id"], "type": "sticky", "x": op["x"], "y": op["y"], "w": 200.0, "h": 200.0, "text": op["text"]}
		for _, k := range []string{"color", "author"} {
			if v, ok := op[k]; ok {
				n[k] = v
			}
		}
		return insert(p, n, "", "")
	case "add_link":
		l := map[string]any{"id": op["id"], "from": op["from"], "to": op["to"], "trigger": "click", "transition": "instant"}
		for _, k := range []string{"trigger", "delay_ms", "transition", "duration_ms"} {
			if v, ok := op[k]; ok {
				l[k] = v
			}
		}
		ls, _ := d["links"].([]any)
		d["links"] = append(ls, any(l))
	case "set_link", "remove_link":
		ls, _ := d["links"].([]any)
		i := slices.IndexFunc(ls, func(l any) bool { return l.(map[string]any)["id"] == op["id"] })
		if i < 0 {
			return fmt.Errorf("link %s doesn't exist", op["id"])
		}
		if op["op"] == "remove_link" {
			d["links"] = slices.Delete(ls, i, i+1)
			return nil
		}
		l := ls[i].(map[string]any)
		for _, k := range []string{"trigger", "delay_ms", "transition", "duration_ms", "from", "to"} {
			if v, ok := op[k]; ok {
				if v == nil {
					delete(l, k)
				} else {
					l[k] = v
				}
			}
		}
	case "create_component":
		l, ok := find(d, field(op, "id"))
		if !ok {
			return fmt.Errorf("%s doesn't exist", op["id"])
		}
		if l.n["type"] != "frame" {
			return fmt.Errorf("%s is a %s; only a frame can become a component", op["id"], l.n["type"])
		}
		l.n["type"] = "component"
		delete(l.n, "preset")
		if name, ok := op["name"]; ok {
			l.n["name"] = name
		}
	case "instantiate":
		main, ok := find(d, field(op, "component"))
		if !ok || main.n["type"] != "component" {
			return fmt.Errorf("%s isn't a component", op["component"])
		}
		holder, _, err := holderOf(d, field(op, "parent"))
		if err != nil {
			return err
		}
		n := map[string]any{"id": op["id"], "type": "instance", "component": op["component"], "x": op["x"], "y": op["y"], "w": main.n["w"], "h": main.n["h"]}
		if ov, ok := op["overrides"]; ok {
			n["overrides"] = ov
		}
		return insert(holder, n, field(op, "after"), "")
	case "set_overrides":
		l, ok := find(d, field(op, "id"))
		if !ok || l.n["type"] != "instance" {
			return fmt.Errorf("%s isn't an instance", op["id"])
		}
		if ov, ok := op["overrides"].(map[string]any); ok && len(ov) == 0 || op["overrides"] == nil {
			delete(l.n, "overrides")
		} else {
			l.n["overrides"] = op["overrides"]
		}
	case "detach":
		return detach(d, field(op, "id"))
	case "set_token":
		return setToken(d, op)
	case "link_ticket", "unlink_ticket":
		l, ok := find(d, field(op, "node"))
		if !ok {
			return fmt.Errorf("%s doesn't exist", op["node"])
		}
		if t := l.n["type"]; t != "frame" && t != "component" {
			return fmt.Errorf("%s is a %s; link a frame", op["node"], t)
		}
		list, _ := l.n["linked_tickets"].([]any)
		ticket := op["ticket"]
		i := slices.Index(list, ticket)
		if op["op"] == "link_ticket" && i < 0 {
			list = append(list, ticket)
		} else if op["op"] == "unlink_ticket" {
			if i < 0 {
				return fmt.Errorf("%s isn't linked to %v", op["node"], ticket)
			}
			list = slices.Delete(list, i, i+1)
		}
		if len(list) == 0 {
			delete(l.n, "linked_tickets")
		} else {
			l.n["linked_tickets"] = list
		}
	}
	return nil
}

// setText replaces a text node's, shape's or sticky's text. Plain text keeps
// the first run's style, one paragraph per line.
func setText(d Doc, op Op) error {
	l, ok := find(d, field(op, "id"))
	if !ok {
		return fmt.Errorf("%s doesn't exist", op["id"])
	}
	ps, hasPs := op["paragraphs"]
	text, hasText := op["text"].(string)
	if hasPs == hasText {
		return fmt.Errorf("set_text takes paragraphs or text")
	}
	if l.n["type"] == "sticky" {
		if !hasText {
			return fmt.Errorf("a sticky takes plain text")
		}
		l.n["text"] = text
		return nil
	}
	var target map[string]any
	switch l.n["type"] {
	case "text":
		target = l.n
	case "shape":
		tb, ok := l.n["text"].(map[string]any)
		if !ok {
			tb = map[string]any{}
			l.n["text"] = tb
		}
		target = tb
	default:
		return fmt.Errorf("%s is a %s, which has no text", op["id"], l.n["type"])
	}
	if hasText {
		style := map[string]any{"size": 16.0}
		if old, ok := target["paragraphs"].([]any); ok && len(old) > 0 {
			if runs, ok := old[0].(map[string]any)["runs"].([]any); ok && len(runs) > 0 {
				style = clone(runs[0]).(map[string]any)
			}
		}
		var out []any
		for _, line := range strings.Split(text, "\n") {
			r := clone(style).(map[string]any)
			r["text"] = line
			out = append(out, map[string]any{"runs": []any{r}})
		}
		ps = out
	}
	target["paragraphs"] = ps
	return nil
}

// detach replaces an instance with a frame holding a copy of its main's
// subtree with fresh ids, overrides applied.
func detach(d Doc, id string) error {
	l, ok := find(d, id)
	if !ok || l.n["type"] != "instance" {
		return fmt.Errorf("%s isn't an instance", id)
	}
	main, ok := find(d, field(l.n, "component"))
	if !ok {
		return fmt.Errorf("its component %s doesn't exist", l.n["component"])
	}
	ov, _ := l.n["overrides"].(map[string]any)
	copyMain := clone(main.n).(map[string]any)
	var remint func(n map[string]any)
	remint = func(n map[string]any) {
		if o, ok := ov[field(n, "id")].(map[string]any); ok {
			if t, ok := o["text"].(string); ok {
				if ps, ok := n["paragraphs"].([]any); ok && len(ps) > 0 {
					p0 := ps[0].(map[string]any)
					if runs, ok := p0["runs"].([]any); ok && len(runs) > 0 {
						r0 := runs[0].(map[string]any)
						r0["text"] = t
						p0["runs"] = runs[:1]
						n["paragraphs"] = ps[:1]
					}
				}
			}
			if f, ok := o["fill"]; ok {
				n["fill"] = f
			}
			if v, ok := o["visible"]; ok {
				n["visible"] = v
			}
		}
		n["id"] = NewID("n")
		for _, c := range children(n) {
			remint(c)
		}
	}
	remint(copyMain)
	copyMain["type"] = "frame"
	copyMain["id"] = id // links and connectors to the instance keep working
	for _, k := range []string{"x", "y", "w", "h", "name", "rotation", "opacity", "visible", "locked", "sizing", "absolute", "constraints"} {
		if v, ok := l.n[k]; ok {
			copyMain[k] = v
		} else {
			delete(copyMain, k)
		}
	}
	kids := l.holder["children"].([]any)
	kids[l.i] = copyMain
	return nil
}

func setToken(d Doc, op Op) error {
	sets, _ := d["token_sets"].(map[string]any)
	s, ok := sets[field(op, "set")].(map[string]any)
	if !ok {
		return fmt.Errorf("token set %s doesn't exist", op["set"])
	}
	if s["source"] != nil {
		return fmt.Errorf("token set %s is a snapshot of %v; sync it from the editor instead", op["set"], s["source"])
	}
	mode := field(op, "mode")
	if mode != "dark" && mode != "light" {
		return fmt.Errorf("mode must be dark or light")
	}
	modes := s["modes"].(map[string]any)
	toks, ok := modes[mode].(map[string]any)
	if !ok {
		toks = map[string]any{}
		modes[mode] = toks
	}
	name := field(op, "name")
	if op["value"] == nil {
		delete(toks, name)
		return nil
	}
	v, _ := op["value"].(string)
	kind := "color"
	if strings.HasSuffix(v, "px") {
		kind = "dimension"
	} else {
		v = strings.ToUpper(v)
	}
	toks[name] = map[string]any{"kind": kind, "value": v}
	return nil
}

// FrameLinks lists each frame's or component's linked tickets.
func FrameLinks(body string) map[string][]string {
	d, err := Parse(body)
	if err != nil {
		return nil
	}
	out := map[string][]string{}
	Walk(d, func(n, _, _ map[string]any, _ int) {
		if list, ok := n["linked_tickets"].([]any); ok {
			for _, t := range list {
				if s, ok := t.(string); ok {
					out[n["id"].(string)] = append(out[n["id"].(string)], s)
				}
			}
		}
	})
	return out
}

// Remint gives every page, node and link a fresh id and rewrites the
// references to them, for a copy of a design.
func Remint(body string) (string, error) {
	d, err := Parse(body)
	if err != nil {
		return "", err
	}
	ids := map[string]string{}
	for _, p := range pages(d) {
		ids[p["id"].(string)] = NewID("p")
		p["id"] = ids[p["id"].(string)]
	}
	Walk(d, func(n, _, _ map[string]any, _ int) {
		old := n["id"].(string)
		ids[old] = NewID("n")
		n["id"] = ids[old]
	})
	re := func(v any) any {
		if s, ok := v.(string); ok {
			if n, ok := ids[s]; ok {
				return n
			}
		}
		return v
	}
	Walk(d, func(n, _, _ map[string]any, _ int) {
		if n["type"] == "instance" {
			n["component"] = re(n["component"])
			if ov, ok := n["overrides"].(map[string]any); ok {
				out := map[string]any{}
				for k, v := range ov {
					out[re(k).(string)] = v
				}
				n["overrides"] = out
			}
		}
		if n["type"] == "connector" {
			for _, end := range []string{"from", "to"} {
				if e, ok := n[end].(map[string]any); ok {
					e["node"] = re(e["node"])
				}
			}
		}
	})
	for _, l := range links(d) {
		l["id"] = NewID("k")
		l["from"], l["to"] = re(l["from"]), re(l["to"])
	}
	return Finish(d)
}

// Summary counts a design's pages and top-level frames.
func Summary(body string) (pageCount, frameCount int) {
	d, err := Parse(body)
	if err != nil {
		return 0, 0
	}
	for _, p := range pages(d) {
		pageCount++
		for _, n := range children(p) {
			if n["type"] == "frame" {
				frameCount++
			}
		}
	}
	return pageCount, frameCount
}

// DecodeOps reads ops from JSON.
func DecodeOps(raw []byte) ([]Op, error) {
	var ops []Op
	if err := json.Unmarshal(raw, &ops); err != nil {
		return nil, apperr.Invalid("ops", "must be a list of op objects")
	}
	return ops, nil
}

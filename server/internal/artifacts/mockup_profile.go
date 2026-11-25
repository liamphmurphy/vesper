package artifacts

import (
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

// Mockup SVG profile v1 (docs/dev/mockup-svg-profile.md) is the subset of SVG
// the Mac app's native renderer draws completely, so a reviewed mockup means
// exactly one picture. The app's MockupSVGProfile enforces the same rules;
// testdata/mockup-svg keeps the two in step.

const (
	svgNS   = "http://www.w3.org/2000/svg"
	xlinkNS = "http://www.w3.org/1999/xlink"

	maxMockupElements = 5000
	maxMockupDepth    = 32
	// maxMockupProblems bounds one rejection: enough for an agent to fix a
	// document in one try without burying the first problem.
	maxMockupProblems = 5
)

var (
	drawnElements      = set("g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "tspan", "image", "use")
	referencedElements = set("defs", "symbol", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "pattern", "marker")
	ignoredElements    = set("title", "desc", "metadata")

	// Elements an agent is likely to reach for, with what to do instead.
	elementHints = map[string]string{
		"svg":           "an <svg> can only be the root; group with <g transform=…> or reuse with <symbol> and <use>",
		"style":         "use presentation attributes like fill=\"#fff\" instead of CSS",
		"filter":        "filters aren't drawn; fake shadows and glows with extra shapes, e.g. a semi-transparent rect offset behind",
		"foreignObject": "draw text with <text> and <tspan> instead of HTML",
		"textPath":      "position text with x, y and transform instead",
		"a":             "links aren't drawn; use a <g>",
		"switch":        "keep only the branch you want drawn",
	}

	ignoredAttrs = set("xmlns", "version", "baseProfile", "xml:space", "xml:lang", "lang", "role", "focusable", "pointer-events")

	// Attributes that size a viewport. The profile table lists root, use,
	// image, rect, pattern, mask and symbol; markers have a viewBox too.
	viewportElements = set("svg", "use", "image", "rect", "pattern", "mask", "symbol", "marker")

	attrHints = map[string]string{
		"class":      "use presentation attributes like fill=\"#fff\"",
		"style":      "write each property as its own attribute, like fill=\"#fff\"",
		"filter":     "filters aren't drawn; fake shadows and glows with extra shapes, e.g. a semi-transparent rect offset behind",
		"textLength": "position text with x, y, dx and dy",
		"rotate":     "rotate a whole <text> or <tspan> with transform=\"rotate(…)\"",
	}

	enumAttrs = map[string][]string{
		"fill-rule":           {"nonzero", "evenodd"},
		"clip-rule":           {"nonzero", "evenodd"},
		"stroke-linecap":      {"butt", "round", "square"},
		"stroke-linejoin":     {"miter", "round", "bevel"},
		"display":             {"inline", "block", "none"},
		"visibility":          {"visible", "hidden", "collapse"},
		"clipPathUnits":       {"userSpaceOnUse", "objectBoundingBox"},
		"maskUnits":           {"userSpaceOnUse", "objectBoundingBox"},
		"maskContentUnits":    {"userSpaceOnUse", "objectBoundingBox"},
		"gradientUnits":       {"userSpaceOnUse", "objectBoundingBox"},
		"patternUnits":        {"userSpaceOnUse", "objectBoundingBox"},
		"patternContentUnits": {"userSpaceOnUse", "objectBoundingBox"},
		"markerUnits":         {"strokeWidth", "userSpaceOnUse"},
		"spreadMethod":        {"pad", "reflect", "repeat"},
		"text-anchor":         {"start", "middle", "end"},
		"dominant-baseline":   {"auto", "alphabetic", "middle", "central", "hanging"},
		"font-style":          {"normal", "italic", "oblique"},
		"font-weight":         {"normal", "bold", "bolder", "lighter", "100", "200", "300", "400", "500", "600", "700", "800", "900"},
		"text-decoration":     {"none", "underline", "line-through"},
	}

	// Lengths: % only where the spec allows it.
	percentLengths = set("x", "y", "width", "height", "cx", "cy", "r", "rx", "ry", "x1", "y1", "x2", "y2", "fx", "fy", "fr")
	plainLengths   = set("dx", "dy", "stroke-width", "stroke-dashoffset", "font-size", "letter-spacing", "markerWidth", "markerHeight", "refX", "refY")
	numberAttrs    = set("opacity", "fill-opacity", "stroke-opacity", "stop-opacity", "stroke-miterlimit")
	singleValue    = set("x", "y", "dx", "dy")
	refAttrs       = map[string]string{"clip-path": "clipPath", "mask": "mask", "marker-start": "marker", "marker-mid": "marker", "marker-end": "marker"}
	transformAttrs = set("transform", "gradientTransform", "patternTransform")

	// profileAttrs is every attribute the profile draws.
	profileAttrs = set(
		"id", "viewBox", "preserveAspectRatio",
		"x", "y", "width", "height", "rx", "ry", "cx", "cy", "r", "fx", "fy", "fr", "x1", "y1", "x2", "y2", "points", "d", "transform", "dx", "dy",
		"fill", "fill-opacity", "fill-rule", "stroke", "stroke-width", "stroke-opacity", "stroke-dasharray", "stroke-dashoffset",
		"stroke-linecap", "stroke-linejoin", "stroke-miterlimit", "opacity", "color", "display", "visibility",
		"clip-path", "clip-rule", "mask", "clipPathUnits", "maskUnits", "maskContentUnits",
		"gradientUnits", "gradientTransform", "spreadMethod", "offset", "stop-color", "stop-opacity", "href", "xlink:href",
		"patternUnits", "patternContentUnits", "patternTransform",
		"marker-start", "marker-mid", "marker-end", "markerWidth", "markerHeight", "markerUnits", "refX", "refY", "orient",
		"font-family", "font-size", "font-weight", "font-style", "text-anchor", "dominant-baseline", "letter-spacing", "text-decoration",
	)

	// What a use may show, and what paint and gradient references may point at.
	useTargets      = set("g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "image", "use", "symbol")
	paintTargets    = set("linearGradient", "radialGradient", "pattern")
	gradientTargets = set("linearGradient", "radialGradient")

	numberRE     = regexp.MustCompile(`^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?`)
	urlRefRE     = regexp.MustCompile(`^url\(\s*(['"]?)#([^'"()\s]+)['"]?\s*\)\s*(.*)$`)
	dataImageRE  = regexp.MustCompile(`(?i)^data:image/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\s]*$`)
	alignRE      = regexp.MustCompile(`^x(Min|Mid|Max)Y(Min|Mid|Max)$`)
	hexColorRE   = regexp.MustCompile(`^#([0-9a-fA-F]{3}|[0-9a-fA-F]{4}|[0-9a-fA-F]{6}|[0-9a-fA-F]{8})$`)
	colorFuncRE  = regexp.MustCompile(`(?i)^(rgba?|hsla?)\((.*)\)$`)
	transformsRE = regexp.MustCompile(`^(matrix|translate|scale|rotate|skewX|skewY)$`)
)

func set(names ...string) map[string]bool {
	m := make(map[string]bool, len(names))
	for _, n := range names {
		m[n] = true
	}
	return m
}

// svgNode is an element of a mockup outside ignored content.
type svgNode struct {
	name     string // as written, with any prefix
	local    string
	attrs    []svgAttr
	parent   *svgNode
	children []*svgNode
}

type svgAttr struct {
	name  string // href, xlink:href (whatever its prefix), aria-label
	value string
	// foreign: in a namespace the profile doesn't know, like inkscape:label.
	foreign bool
}

func (n *svgNode) attr(name string) (string, bool) {
	for _, a := range n.attrs {
		if a.name == name {
			return a.value, true
		}
	}
	return "", false
}

// href is the node's href, preferring the SVG 2 attribute over xlink:href.
func (n *svgNode) href() (string, bool) {
	if v, ok := n.attr("href"); ok {
		return v, true
	}
	return n.attr("xlink:href")
}

type problems []string

func (p *problems) add(format string, args ...any) {
	if len(*p) < maxMockupProblems {
		*p = append(*p, fmt.Sprintf(format, args...))
	}
}

func (p problems) full() bool { return len(p) >= maxMockupProblems }

func (p problems) err() error {
	switch len(p) {
	case 0:
		return nil
	case 1:
		return apperr.Invalid("svg", "%s", p[0])
	}
	var b strings.Builder
	fmt.Fprintf(&b, "doesn't conform to mockup SVG profile v1:")
	for i, s := range p {
		fmt.Fprintf(&b, " (%d) %s", i+1, s)
		if i < len(p)-1 {
			b.WriteByte(';')
		}
	}
	return apperr.Invalid("svg", "%s", b.String())
}

// ValidateMockupProfile checks that body conforms to mockup SVG profile v1:
// the elements, attributes and values the native renderer draws, with every
// reference resolved. Run ValidSVG first for the security rules; this only
// narrows them. Up to maxMockupProblems problems are reported together.
func ValidateMockupProfile(body string) error {
	root, p := parseMockupTree(body)
	if root == nil || p.full() {
		return p.err()
	}
	ids := map[string]*svgNode{}
	walk(root, func(n *svgNode) {
		if id, ok := n.attr("id"); ok && id != "" {
			if _, dup := ids[id]; !dup {
				ids[id] = n
			}
		}
	})
	checkRoot(root, &p)
	walk(root, func(n *svgNode) {
		if !p.full() {
			checkAttrs(n, ids, &p)
		}
	})
	if !p.full() {
		checkUseCycles(root, ids, &p)
	}
	return p.err()
}

func walk(n *svgNode, fn func(*svgNode)) {
	fn(n)
	for _, c := range n.children {
		walk(c, fn)
	}
}

// parseMockupTree reads the element tree, checking the document structure
// and the element allowlist. Ignored elements are dropped with their content.
func parseMockupTree(body string) (*svgNode, problems) {
	var p problems
	dec := xml.NewDecoder(strings.NewReader(body))
	dec.Strict = true
	dec.Entity = nil
	type frame struct {
		name string
		ns   map[string]string
	}
	var stack []frame
	resolve := func(prefix string) string {
		if prefix == "xml" {
			return "http://www.w3.org/XML/1998/namespace"
		}
		for i := len(stack) - 1; i >= 0; i-- {
			if uri, ok := stack[i].ns[prefix]; ok {
				return uri
			}
		}
		return ""
	}
	var root, cur *svgNode
	skip := 0       // depth inside ignored or rejected content
	elements := 0   // counted outside ignored content
	closed := false // the root has ended
	for {
		tok, err := dec.RawToken()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			p.add("isn't well-formed XML: %v", err)
			return nil, p
		}
		switch t := tok.(type) {
		case xml.Directive:
			p.add("can't contain a DOCTYPE or entity declaration")
			return nil, p
		case xml.StartElement:
			f := frame{name: qname(t.Name), ns: map[string]string{}}
			for _, a := range t.Attr {
				switch {
				case a.Name.Space == "" && a.Name.Local == "xmlns":
					f.ns[""] = a.Value
				case a.Name.Space == "xmlns":
					f.ns[a.Name.Local] = a.Value
				}
			}
			stack = append(stack, f)
			if closed {
				p.add("has content after the root </svg>; a mockup is one <svg> element")
				return nil, p
			}
			if skip > 0 {
				skip++
				continue
			}
			ns := resolve(t.Name.Space)
			if root == nil {
				if t.Name.Local != "svg" || ns != svgNS {
					p.add(`the root element must be <svg xmlns="%s">`, svgNS)
					return nil, p
				}
			} else if ns != svgNS {
				p.add("<%s> isn't an SVG element; mockups draw only SVG", f.name)
				skip = 1
				continue
			} else if ignoredElements[t.Name.Local] {
				skip = 1
				continue
			} else if !drawnElements[t.Name.Local] && !referencedElements[t.Name.Local] {
				hint := elementHints[t.Name.Local]
				if hint == "" && (strings.HasPrefix(t.Name.Local, "fe") || strings.HasPrefix(t.Name.Local, "animate") || t.Name.Local == "set") {
					hint = "mockups are static pictures; remove it"
				}
				if hint == "" {
					hint = "profile v1 draws svg, g, rect, circle, ellipse, line, polyline, polygon, path, text, tspan, image and use, with defs, symbol, gradients, stop, clipPath, mask, pattern and marker"
				}
				p.add("<%s> isn't allowed in mockups; %s", f.name, hint)
				if p.full() {
					return root, p
				}
				skip = 1
				continue
			}
			elements++
			if elements > maxMockupElements {
				p.add("has more than %d elements; simplify the mockup or reuse parts with <use>", maxMockupElements)
				return root, p
			}
			n := &svgNode{name: f.name, local: t.Name.Local, parent: cur}
			for _, a := range t.Attr {
				at := svgAttr{name: qname(a.Name), value: a.Value}
				switch a.Name.Space {
				case "", "xmlns", "xml":
				default:
					if resolve(a.Name.Space) == xlinkNS {
						at.name = "xlink:" + a.Name.Local
					} else {
						at.foreign = true
					}
				}
				n.attrs = append(n.attrs, at)
			}
			if root == nil {
				root = n
			} else {
				cur.children = append(cur.children, n)
			}
			cur = n
			if depth(n) > maxMockupDepth {
				p.add("nests elements more than %d deep; flatten the groups", maxMockupDepth)
				return root, p
			}
		case xml.EndElement:
			if len(stack) == 0 || stack[len(stack)-1].name != qname(t.Name) {
				p.add("isn't well-formed XML: unexpected </%s>", qname(t.Name))
				return nil, p
			}
			stack = stack[:len(stack)-1]
			if skip > 0 {
				skip--
				continue
			}
			if cur == root {
				closed = true
			}
			cur = cur.parent
		}
	}
	if root == nil {
		p.add(`must contain an <svg xmlns="%s"> element`, svgNS)
		return nil, p
	}
	if !closed {
		p.add("isn't well-formed XML: <svg> isn't closed")
		return nil, p
	}
	return root, p
}

func qname(n xml.Name) string {
	if n.Space == "" {
		return n.Local
	}
	return n.Space + ":" + n.Local
}

func depth(n *svgNode) int {
	d := 0
	for ; n != nil; n = n.parent {
		d++
	}
	return d
}

// checkRoot requires a drawable size: a positive viewBox, or numeric width
// and height, which then define it.
func checkRoot(root *svgNode, p *problems) {
	if _, ok := root.attr("viewBox"); ok {
		return // a bad viewBox is reported with the root's other attributes
	}
	w, wok := root.attr("width")
	h, hok := root.attr("height")
	if wok && hok && isPlainLength(w) && isPlainLength(h) && positive(w) && positive(h) {
		return
	}
	p.add(`the root <svg> needs a viewBox with a positive size, like viewBox="0 0 1280 800" (or numeric width and height)`)
}

func isPlainLength(v string) bool {
	s := strings.TrimSpace(v)
	n := len(numberRE.FindString(s))
	return n > 0 && (s[n:] == "" || s[n:] == "px")
}

func positive(v string) bool {
	s := strings.TrimSpace(v)
	n := numberRE.FindString(s)
	var f float64
	_, err := fmt.Sscan(n, &f)
	return err == nil && f > 0
}

func checkAttrs(n *svgNode, ids map[string]*svgNode, p *problems) {
	seen := map[string]bool{}
	for _, a := range n.attrs {
		if p.full() {
			return
		}
		if seen[a.name] {
			p.add("<%s> has attribute %s twice; keep one", n.name, a.name)
			continue
		}
		seen[a.name] = true
		if ignoredAttrs[a.name] || strings.HasPrefix(a.name, "xmlns:") || strings.HasPrefix(a.name, "aria-") || strings.HasPrefix(a.name, "data-") {
			continue
		}
		if a.foreign || !profileAttrs[a.name] {
			if a.foreign && strings.HasPrefix(a.name, "xlink:") {
				p.add(`<%s> attribute %s uses an undeclared xlink prefix; write plain href`, n.name, a.name)
			} else if a.foreign {
				p.add("<%s> attribute %s isn't allowed in mockups; remove editor-specific attributes", n.name, a.name)
			} else if hint := attrHints[a.name]; hint != "" {
				p.add("<%s> attribute %s isn't allowed in mockups; %s", n.name, a.name, hint)
			} else {
				p.add("<%s> attribute %s isn't allowed in mockups; remove it (profile v1 draws presentation attributes like fill, stroke, opacity, transform and font-size)", n.name, a.name)
			}
			continue
		}
		if (a.name == "viewBox" || a.name == "preserveAspectRatio") && !viewportElements[n.local] {
			p.add("<%s> attribute %s isn't allowed in mockups; only svg, symbol, marker, pattern, use, image, rect and mask take it", n.name, a.name)
			continue
		}
		if hint := valueHint(n, a, ids); hint != "" {
			p.add("<%s> attribute %s=%q %s", n.name, a.name, clip(a.value), hint)
		}
	}
}

func clip(v string) string {
	if len(v) > 60 {
		return v[:57] + "…"
	}
	return v
}

// valueHint says what is wrong with an attribute's value and what to write
// instead, or "" when it conforms.
func valueHint(n *svgNode, a svgAttr, ids map[string]*svgNode) string {
	v := strings.TrimSpace(a.value)
	name := a.name
	if h := cssFuncHint(v); h != "" {
		return h
	}
	switch {
	case singleValue[name] && len(strings.FieldsFunc(v, isSep)) > 1:
		return "must be a single number; mockups don't support per-glyph lists, so split the text into <tspan>s with their own " + name
	case percentLengths[name]:
		return lengthHint(name, v, true)
	case plainLengths[name]:
		if name == "letter-spacing" && v == "normal" {
			return ""
		}
		return lengthHint(name, v, false)
	case numberAttrs[name]:
		if numberRE.FindString(v) == v && v != "" {
			return ""
		}
		return fmt.Sprintf(`must be a plain number, like %s="0.5"`, name)
	case name == "offset":
		if s := numberRE.FindString(v); s != "" && (v == s || v == s+"%") {
			return ""
		}
		return `must be a number or a percentage, like offset="0.5" or offset="50%"`
	case enumAttrs[name] != nil:
		for _, ok := range enumAttrs[name] {
			if v == ok {
				return ""
			}
		}
		return "must be one of " + strings.Join(enumAttrs[name], ", ")
	case name == "orient":
		if v == "auto" || v == "auto-start-reverse" || (v != "" && numberRE.FindString(v) == v) {
			return ""
		}
		return "must be a number of degrees, auto or auto-start-reverse"
	case name == "color" || name == "stop-color":
		if validColor(v) {
			return ""
		}
		return colorHint
	case name == "fill" || name == "stroke":
		return paintHint(v, ids)
	case refAttrs[name] != "":
		if v == "none" {
			return ""
		}
		m := urlRefRE.FindStringSubmatch(v)
		if m == nil || m[3] != "" {
			return fmt.Sprintf("must be none or url(#id) pointing at a <%s>", refAttrs[name])
		}
		return refKindHint(m[2], ids, set(refAttrs[name]), "a <"+refAttrs[name]+">")
	case transformAttrs[name]:
		if validTransform(v) {
			return ""
		}
		return "must be a list of matrix(), translate(), scale(), rotate() (1 or 3 numbers), skewX() or skewY() with plain numbers, like transform=\"translate(10 20) rotate(45)\""
	case name == "d":
		if validPath(v) {
			return ""
		}
		return "isn't valid path data; start with M and use only the commands M L H V C S Q T A Z (either case) with numbers"
	case name == "points":
		nums, ok := numberList(v)
		if ok && len(nums)%2 == 0 {
			return ""
		}
		return `must be pairs of numbers, like points="0,0 10,0 10,10"`
	case name == "viewBox":
		return viewBoxHint(v)
	case name == "preserveAspectRatio":
		f := strings.Fields(v)
		if len(f) == 1 && f[0] == "none" {
			return ""
		}
		if (len(f) == 1 || (len(f) == 2 && (f[1] == "meet" || f[1] == "slice"))) && alignRE.MatchString(f[0]) {
			return ""
		}
		return "must be none or xMinYMin…xMaxYMax with an optional meet or slice, like preserveAspectRatio=\"xMidYMid meet\""
	case name == "stroke-dasharray":
		if v == "none" {
			return ""
		}
		for _, part := range strings.FieldsFunc(v, isSep) {
			if !isPlainLength(part) {
				return `must be none or a list of numbers, like stroke-dasharray="4 2"`
			}
		}
		if v == "" {
			return `must be none or a list of numbers, like stroke-dasharray="4 2"`
		}
		return ""
	case name == "font-family":
		if v == "" {
			return `is empty; name a family, like font-family="system-ui, sans-serif"`
		}
		return ""
	case name == "id":
		if v == "" || strings.ContainsAny(v, " \t\n\r") {
			return "must be a non-empty name without spaces"
		}
		return ""
	case name == "href" || name == "xlink:href":
		return hrefHint(n, v, ids)
	}
	return ""
}

const colorHint = "isn't a colour mockups support; use #rgb, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl(), hsla(), a CSS colour name, transparent or currentColor"

func cssFuncHint(v string) string {
	l := strings.ToLower(v)
	switch {
	case strings.Contains(l, "var("):
		return "uses var(), which mockups don't support; write the value itself, like fill=\"#2563EB\""
	case strings.Contains(l, "calc("):
		return "uses calc(), which mockups don't support; write the computed number"
	}
	return ""
}

func isSep(r rune) bool { return r == ',' || r == ' ' || r == '\t' || r == '\n' || r == '\r' }

func lengthHint(name, v string, pct bool) string {
	n := len(numberRE.FindString(v))
	if n == 0 {
		return fmt.Sprintf(`isn't a number; use a plain number of user units, like %s="10"`, name)
	}
	switch rest := v[n:]; {
	case rest == "" || rest == "px":
		return ""
	case rest == "%" && pct:
		return ""
	case rest == "%":
		return fmt.Sprintf(`can't be a percentage; use a number of user units, like %s="2"`, name)
	}
	return fmt.Sprintf(`uses a unit mockups don't support; use a plain number of user units (or px), like %s="10"`, name)
}

func viewBoxHint(v string) string {
	nums, ok := numberList(v)
	if !ok || len(nums) != 4 {
		return `must be four numbers, like viewBox="0 0 1280 800"`
	}
	if nums[2] <= 0 || nums[3] <= 0 {
		return `needs a positive width and height, like viewBox="0 0 1280 800"`
	}
	return ""
}

func paintHint(v string, ids map[string]*svgNode) string {
	if v == "none" || validColor(v) {
		return ""
	}
	m := urlRefRE.FindStringSubmatch(v)
	if m == nil {
		if strings.HasPrefix(v, "url(") {
			return "must be url(#id) pointing at a gradient or pattern, with an optional fallback colour"
		}
		return colorHint
	}
	if fb := strings.TrimSpace(m[3]); fb != "" && fb != "none" && !validColor(fb) {
		return "has a fallback that isn't a colour; write url(#id) followed by a colour, like fill=\"url(#g) #6366F1\""
	}
	return refKindHint(m[2], ids, paintTargets, "a <linearGradient>, <radialGradient> or <pattern>")
}

func refKindHint(id string, ids map[string]*svgNode, kinds map[string]bool, want string) string {
	t, ok := ids[id]
	if !ok {
		return fmt.Sprintf("points at #%s, which doesn't exist; add an element with id=%q or remove the reference", id, id)
	}
	if !kinds[t.local] {
		return fmt.Sprintf("points at a <%s>; it must point at %s", t.name, want)
	}
	return ""
}

func hrefHint(n *svgNode, v string, ids map[string]*svgNode) string {
	switch {
	case n.local == "image":
		if dataImageRE.MatchString(v) {
			return ""
		}
		return "must be a data:image/png|jpeg|gif|webp;base64, URI; embed the image instead of linking it"
	case n.local == "use" || gradientTargets[n.local]:
		id, ok := strings.CutPrefix(v, "#")
		if !ok || id == "" {
			return "must be #id of an element in this document"
		}
		if n.local == "use" {
			return refKindHint(id, ids, useTargets, "a shape, <g>, <text>, <image>, <use> or <symbol>")
		}
		return refKindHint(id, ids, gradientTargets, "another gradient")
	}
	return "isn't allowed here; only <use>, gradients and <image> take href"
}

// checkUseCycles rejects a use that shows itself, through its target or any
// use inside the target, however indirectly.
func checkUseCycles(root *svgNode, ids map[string]*svgNode, p *problems) {
	targetOf := func(u *svgNode) *svgNode {
		v, _ := u.href()
		id, ok := strings.CutPrefix(strings.TrimSpace(v), "#")
		if !ok {
			return nil
		}
		return ids[id]
	}
	// next: the uses drawn when u is drawn, i.e. those in its target's subtree.
	next := func(u *svgNode) []*svgNode {
		t := targetOf(u)
		if t == nil {
			return nil
		}
		var out []*svgNode
		walk(t, func(n *svgNode) {
			if n.local == "use" {
				out = append(out, n)
			}
		})
		return out
	}
	const (
		unvisited = iota
		visiting
		done
	)
	state := map[*svgNode]int{}
	var cyclic func(u *svgNode) bool
	cyclic = func(u *svgNode) bool {
		switch state[u] {
		case visiting:
			return true
		case done:
			return false
		}
		state[u] = visiting
		for _, w := range next(u) {
			if cyclic(w) {
				return true
			}
		}
		state[u] = done
		return false
	}
	walk(root, func(n *svgNode) {
		if n.local == "use" && state[n] == unvisited && !p.full() && cyclic(n) {
			v, _ := n.href()
			p.add("<%s> href=%q makes a reference cycle: the element it shows contains this <use>, directly or through other uses; point it at an element outside", n.name, v)
		}
	})
}

// validColor accepts the profile's colours (not none, which only paint takes).
func validColor(v string) bool {
	if hexColorRE.MatchString(v) {
		return true
	}
	l := strings.ToLower(v)
	if l == "transparent" || l == "currentcolor" || cssNamedColors[l] {
		return true
	}
	m := colorFuncRE.FindStringSubmatch(v)
	if m == nil {
		return false
	}
	hsl := strings.HasPrefix(strings.ToLower(m[1]), "hsl")
	args := m[2]
	var parts []string
	alpha := ""
	if strings.Contains(args, ",") {
		if strings.Contains(args, "/") {
			return false
		}
		for _, s := range strings.Split(args, ",") {
			parts = append(parts, strings.TrimSpace(s))
		}
		if len(parts) == 4 {
			alpha, parts = parts[3], parts[:3]
		}
	} else {
		main, a, slash := strings.Cut(args, "/")
		parts = strings.Fields(main)
		if slash {
			if alpha = strings.TrimSpace(a); alpha == "" {
				return false
			}
		}
	}
	if len(parts) != 3 {
		return false
	}
	for i, s := range parts {
		if hsl && i == 0 {
			s = strings.TrimSuffix(s, "deg")
		}
		if !numberOrPercent(s) {
			return false
		}
	}
	return alpha == "" || numberOrPercent(alpha)
}

func numberOrPercent(s string) bool {
	n := numberRE.FindString(s)
	return n != "" && (s == n || s == n+"%")
}

// numScanner reads SVG number lists and path data, where separators are
// optional between numbers that can't run together ("10-20", ".5.5").
type numScanner struct {
	s string
	i int
}

func (sc *numScanner) skipWS() {
	for sc.i < len(sc.s) && strings.IndexByte(" \t\n\r\f", sc.s[sc.i]) >= 0 {
		sc.i++
	}
}

// skipSep skips whitespace and at most one comma.
func (sc *numScanner) skipSep() {
	sc.skipWS()
	if sc.i < len(sc.s) && sc.s[sc.i] == ',' {
		sc.i++
		sc.skipWS()
	}
}

func (sc *numScanner) done() bool { return sc.i >= len(sc.s) }

func (sc *numScanner) number() (float64, bool) {
	m := numberRE.FindString(sc.s[sc.i:])
	if m == "" {
		return 0, false
	}
	sc.i += len(m)
	var f float64
	_, err := fmt.Sscan(m, &f)
	return f, err == nil
}

func (sc *numScanner) startsNumber() bool {
	return sc.i < len(sc.s) && strings.IndexByte("+-.0123456789", sc.s[sc.i]) >= 0
}

func numberList(v string) ([]float64, bool) {
	sc := numScanner{s: v}
	var out []float64
	sc.skipWS()
	for !sc.done() {
		f, ok := sc.number()
		if !ok {
			return nil, false
		}
		out = append(out, f)
		sc.skipSep()
	}
	return out, len(out) > 0
}

var pathArgs = map[byte]int{'M': 2, 'L': 2, 'T': 2, 'H': 1, 'V': 1, 'S': 4, 'Q': 4, 'C': 6, 'A': 7, 'Z': 0}

func validPath(d string) bool {
	sc := numScanner{s: d}
	sc.skipWS()
	first := true
	for !sc.done() {
		c := sc.s[sc.i]
		n, ok := pathArgs[c&^0x20] // upper-case
		if !ok {
			return false
		}
		if first && c != 'M' && c != 'm' {
			return false
		}
		first = false
		sc.i++
		sc.skipWS()
		if n == 0 {
			continue
		}
		for sets := 0; ; sets++ {
			if !sc.startsNumber() {
				if sets == 0 {
					return false
				}
				break
			}
			for k := 0; k < n; k++ {
				if k > 0 {
					sc.skipSep()
				}
				if n == 7 && (k == 3 || k == 4) {
					if sc.done() || (sc.s[sc.i] != '0' && sc.s[sc.i] != '1') {
						return false
					}
					sc.i++
					continue
				}
				if _, ok := sc.number(); !ok {
					return false
				}
			}
			sc.skipSep()
		}
	}
	return true
}

var transformArgs = map[string][]int{
	"matrix": {6}, "translate": {1, 2}, "scale": {1, 2}, "rotate": {1, 3}, "skewX": {1}, "skewY": {1},
}

func validTransform(v string) bool {
	sc := numScanner{s: v}
	sc.skipWS()
	for !sc.done() {
		start := sc.i
		for sc.i < len(sc.s) && (sc.s[sc.i] >= 'a' && sc.s[sc.i] <= 'z' || sc.s[sc.i] >= 'A' && sc.s[sc.i] <= 'Z' || sc.s[sc.i] >= '0' && sc.s[sc.i] <= '9') {
			sc.i++
		}
		name := sc.s[start:sc.i]
		if !transformsRE.MatchString(name) {
			return false
		}
		sc.skipWS()
		if sc.done() || sc.s[sc.i] != '(' {
			return false
		}
		sc.i++
		sc.skipWS()
		n := 0
		for !sc.done() && sc.s[sc.i] != ')' {
			if n > 0 {
				sc.skipSep()
			}
			if _, ok := sc.number(); !ok {
				return false
			}
			n++
			sc.skipWS()
		}
		if sc.done() {
			return false
		}
		sc.i++ // )
		okCount := false
		for _, want := range transformArgs[name] {
			okCount = okCount || n == want
		}
		if !okCount {
			return false
		}
		sc.skipSep()
	}
	return true
}

// cssNamedColors are the 148 CSS named colours (CSS Color 4 §6.1).
var cssNamedColors = set(
	"aliceblue", "antiquewhite", "aqua", "aquamarine", "azure", "beige", "bisque", "black", "blanchedalmond", "blue",
	"blueviolet", "brown", "burlywood", "cadetblue", "chartreuse", "chocolate", "coral", "cornflowerblue", "cornsilk", "crimson",
	"cyan", "darkblue", "darkcyan", "darkgoldenrod", "darkgray", "darkgreen", "darkgrey", "darkkhaki", "darkmagenta", "darkolivegreen",
	"darkorange", "darkorchid", "darkred", "darksalmon", "darkseagreen", "darkslateblue", "darkslategray", "darkslategrey", "darkturquoise", "darkviolet",
	"deeppink", "deepskyblue", "dimgray", "dimgrey", "dodgerblue", "firebrick", "floralwhite", "forestgreen", "fuchsia", "gainsboro",
	"ghostwhite", "gold", "goldenrod", "gray", "green", "greenyellow", "grey", "honeydew", "hotpink", "indianred",
	"indigo", "ivory", "khaki", "lavender", "lavenderblush", "lawngreen", "lemonchiffon", "lightblue", "lightcoral", "lightcyan",
	"lightgoldenrodyellow", "lightgray", "lightgreen", "lightgrey", "lightpink", "lightsalmon", "lightseagreen", "lightskyblue", "lightslategray", "lightslategrey",
	"lightsteelblue", "lightyellow", "lime", "limegreen", "linen", "magenta", "maroon", "mediumaquamarine", "mediumblue", "mediumorchid",
	"mediumpurple", "mediumseagreen", "mediumslateblue", "mediumspringgreen", "mediumturquoise", "mediumvioletred", "midnightblue", "mintcream", "mistyrose", "moccasin",
	"navajowhite", "navy", "oldlace", "olive", "olivedrab", "orange", "orangered", "orchid", "palegoldenrod", "palegreen",
	"paleturquoise", "palevioletred", "papayawhip", "peachpuff", "peru", "pink", "plum", "powderblue", "purple", "rebeccapurple",
	"red", "rosybrown", "royalblue", "saddlebrown", "salmon", "sandybrown", "seagreen", "seashell", "sienna", "silver",
	"skyblue", "slateblue", "slategray", "slategrey", "snow", "springgreen", "steelblue", "tan", "teal", "thistle",
	"tomato", "turquoise", "violet", "wheat", "white", "whitesmoke", "yellow", "yellowgreen",
)

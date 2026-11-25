package artifacts

import (
	"encoding/xml"
	"io"
	"regexp"
	"sort"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

// mockupPresentationProps are the CSS properties normalization can turn into
// presentation attributes (docs/dev/mockup-svg-profile.md, "Attributes"). The
// order is the order new attributes are appended in.
var mockupPresentationProps = []string{
	"fill", "fill-opacity", "fill-rule",
	"stroke", "stroke-width", "stroke-opacity", "stroke-dasharray", "stroke-dashoffset",
	"stroke-linecap", "stroke-linejoin", "stroke-miterlimit",
	"opacity", "color", "display", "visibility",
	"clip-path", "clip-rule", "mask",
	"marker-start", "marker-mid", "marker-end",
	"stop-color", "stop-opacity",
	"font-family", "font-size", "font-weight", "font-style",
	"text-anchor", "dominant-baseline", "letter-spacing", "text-decoration",
}

var mockupPresentationPropSet = func() map[string]bool {
	m := make(map[string]bool, len(mockupPresentationProps))
	for _, p := range mockupPresentationProps {
		m[p] = true
	}
	return m
}()

// NormalizeMockupSVG rewrites simple CSS (<style> rules with type, class, id
// and * selectors, and style attributes) into presentation attributes, then
// removes every <style> element and class and style attribute. Only rewritten
// start tags and removed <style> elements differ from body; a body with no CSS
// comes back unchanged. A body encoding/xml can't parse is returned as is so
// the validators that run next report it. CSS with no single conversion
// (combinators, pseudo-classes, at-rules, unknown properties, var(), calc())
// is an apperr.Invalid naming the rule.
func NormalizeMockupSVG(body string) (string, error) {
	doc, ok := scanMockupCSSDoc(body)
	if !ok || (len(doc.styles) == 0 && !doc.hasClassOrStyle) {
		return body, nil
	}

	var rules []cssRule
	order := 0
	for _, s := range doc.styles {
		parsed, err := parseStylesheet(s.text, &order)
		if err != nil {
			return "", err
		}
		rules = append(rules, parsed...)
	}

	var edits []mockupSplice
	for _, s := range doc.styles {
		edits = append(edits, styleRemoval(body, s.start, s.end))
	}
	for i := range doc.elements {
		el := &doc.elements[i]
		values, err := cascadeElement(el, rules, &order)
		if err != nil {
			return "", err
		}
		raw := body[el.start:el.end]
		if tag, changed := rewriteStartTag(raw, el, values); changed {
			edits = append(edits, mockupSplice{start: el.start, end: el.end, text: tag})
		}
	}

	sort.Slice(edits, func(i, j int) bool { return edits[i].start < edits[j].start })
	var b strings.Builder
	b.Grow(len(body))
	pos := 0
	for _, e := range edits {
		b.WriteString(body[pos:e.start])
		b.WriteString(e.text)
		pos = e.end
	}
	b.WriteString(body[pos:])
	return b.String(), nil
}

type mockupSplice struct {
	start, end int
	text       string
}

type cssElement struct {
	start, end int // byte span of the start tag
	local      string
	id         string
	classes    []string
	style      string
	hasStyle   bool
	attrs      map[string]string // unprefixed attributes, decoded
}

type cssStyleBlock struct {
	start, end int // byte span from <style> through </style>
	text       string
}

type cssDoc struct {
	elements        []cssElement
	styles          []cssStyleBlock
	hasClassOrStyle bool
}

func scanMockupCSSDoc(body string) (cssDoc, bool) {
	var doc cssDoc
	d := xml.NewDecoder(strings.NewReader(body))
	styleDepth := 0  // >0 while inside a <style> element
	ignoreDepth := 0 // >0 inside title, desc or metadata, whose content the profile ignores
	var cur *cssStyleBlock
	var text strings.Builder
	for {
		before := int(d.InputOffset())
		tok, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return cssDoc{}, false
		}
		after := int(d.InputOffset())
		switch t := tok.(type) {
		case xml.StartElement:
			if styleDepth > 0 {
				styleDepth++
				continue
			}
			if ignoreDepth > 0 || ignoredElements[t.Name.Local] {
				ignoreDepth++
				continue
			}
			if t.Name.Local == "style" {
				styleDepth = 1
				cur = &cssStyleBlock{start: before}
				text.Reset()
				continue
			}
			el := cssElement{start: before, end: after, local: t.Name.Local, attrs: map[string]string{}}
			for _, a := range t.Attr {
				if a.Name.Space != "" {
					continue
				}
				el.attrs[a.Name.Local] = a.Value
				switch a.Name.Local {
				case "id":
					el.id = a.Value
				case "class":
					el.classes = strings.Fields(a.Value)
					doc.hasClassOrStyle = true
				case "style":
					el.style, el.hasStyle = a.Value, true
					doc.hasClassOrStyle = true
				}
			}
			doc.elements = append(doc.elements, el)
		case xml.EndElement:
			if ignoreDepth > 0 {
				ignoreDepth--
				continue
			}
			if styleDepth > 0 {
				styleDepth--
				if styleDepth == 0 {
					cur.end = after
					cur.text = text.String()
					doc.styles = append(doc.styles, *cur)
					cur = nil
				}
			}
		case xml.CharData:
			if styleDepth == 1 {
				text.Write(t)
			}
		}
	}
	return doc, true
}

// styleRemoval removes a <style> element, and its whole line when nothing
// else shares it, so no blank line is left behind.
func styleRemoval(body string, start, end int) mockupSplice {
	lineStart := strings.LastIndexByte(body[:start], '\n') + 1
	if strings.Trim(body[lineStart:start], " \t") != "" {
		return mockupSplice{start: start, end: end}
	}
	rest := body[end:]
	lineEnd := strings.IndexByte(rest, '\n')
	if lineEnd < 0 {
		lineEnd = len(rest)
	} else {
		lineEnd++
	}
	if strings.TrimRight(rest[:lineEnd], " \t\r\n") != "" {
		return mockupSplice{start: start, end: end}
	}
	return mockupSplice{start: lineStart, end: end + lineEnd}
}

// --- CSS parsing ---

type cssDecl struct {
	prop      string
	value     string
	important bool
	order     int
}

type cssCompound struct {
	typ     string // "" or "*" match any element
	ids     []string
	classes []string
}

func (c cssCompound) specificity() [3]int {
	types := 0
	if c.typ != "" && c.typ != "*" {
		types = 1
	}
	return [3]int{len(c.ids), len(c.classes), types}
}

func (c cssCompound) matches(el *cssElement) bool {
	if c.typ != "" && c.typ != "*" && c.typ != el.local {
		return false
	}
	for _, id := range c.ids {
		if el.id != id {
			return false
		}
	}
	for _, want := range c.classes {
		found := false
		for _, have := range el.classes {
			if have == want {
				found = true
				break
			}
		}
		if !found {
			return false
		}
	}
	return true
}

type cssRule struct {
	text      string
	selectors []cssCompound
	decls     []cssDecl
}

func cssInvalid(format string, args ...any) error {
	return apperr.Invalid("svg", format, args...)
}

func stripCSSComments(css string) (string, error) {
	var b strings.Builder
	for {
		i := strings.Index(css, "/*")
		if i < 0 {
			b.WriteString(css)
			return b.String(), nil
		}
		b.WriteString(css[:i])
		j := strings.Index(css[i+2:], "*/")
		if j < 0 {
			return "", cssInvalid("a <style> element has an unterminated /* comment")
		}
		b.WriteByte(' ')
		css = css[i+2+j+2:]
	}
}

func parseStylesheet(css string, order *int) ([]cssRule, error) {
	// Escapes are refused rather than decoded: ValidSVG's checks for
	// external URLs read the attributes this CSS becomes, not the CSS.
	if strings.ContainsRune(css, '\\') {
		return nil, cssInvalid("a <style> element uses a CSS escape (\\), which can't be converted; write the characters themselves")
	}
	css, err := stripCSSComments(css)
	if err != nil {
		return nil, err
	}
	var rules []cssRule
	for {
		css = strings.TrimLeft(css, " \t\r\n\f")
		// HTML comment markers are allowed around a stylesheet and mean nothing.
		css = strings.TrimPrefix(strings.TrimPrefix(css, "<!--"), "-->")
		css = strings.TrimLeft(css, " \t\r\n\f")
		if css == "" {
			return rules, nil
		}
		if css[0] == '@' {
			name := css
			if k := strings.IndexAny(css, " \t\r\n\f{;("); k > 0 {
				name = css[:k]
			}
			return nil, cssInvalid("the <style> at-rule %q can't be converted; mockups can't use at-rules, so put the properties on the elements instead", name)
		}
		open := strings.IndexByte(css, '{')
		if open < 0 {
			return nil, cssInvalid("the <style> text %q isn't a rule (selectors { declarations })", collapseSpace(css))
		}
		selText := collapseSpace(css[:open])
		if strings.ContainsAny(selText, "};") {
			return nil, cssInvalid("the <style> text %q isn't a rule (selectors { declarations })", selText)
		}
		close, err := findBlockEnd(css, open+1, selText)
		if err != nil {
			return nil, err
		}
		sels, err := parseSelectorList(selText)
		if err != nil {
			return nil, err
		}
		context := "the <style> rule " + quoteCSS(selText)
		decls, err := parseDeclarations(css[open+1:close], context, order)
		if err != nil {
			return nil, err
		}
		rules = append(rules, cssRule{text: selText, selectors: sels, decls: decls})
		css = css[close+1:]
	}
}

// findBlockEnd returns the index of the } closing the block opened before i,
// skipping quoted strings and refusing nested blocks.
func findBlockEnd(css string, i int, selText string) (int, error) {
	var quote byte
	for ; i < len(css); i++ {
		c := css[i]
		switch {
		case quote != 0:
			if c == '\\' {
				i++
			} else if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'':
			quote = c
		case c == '{':
			return 0, cssInvalid("the <style> rule %q nests rules, which can't be converted; write each rule at the top level with a simple selector", selText)
		case c == '}':
			return i, nil
		}
	}
	return 0, cssInvalid("the <style> rule %q is missing its closing }", selText)
}

func parseSelectorList(list string) ([]cssCompound, error) {
	var out []cssCompound
	for _, part := range splitOutside(list, ',') {
		sel := collapseSpace(part)
		if sel == "" {
			return nil, cssInvalid("the <style> rule %q has an empty selector", list)
		}
		c, err := parseCompound(sel)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, nil
}

func isCSSIdentByte(c byte) bool {
	return c == '-' || c == '_' || c >= 0x80 ||
		(c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

func parseCompound(sel string) (cssCompound, error) {
	const fix = "which can't be converted; put the properties on the elements instead"
	var c cssCompound
	i := 0
	ident := func() string {
		j := i
		for j < len(sel) && isCSSIdentByte(sel[j]) {
			j++
		}
		s := sel[i:j]
		i = j
		return s
	}
	if i < len(sel) && sel[i] == '*' {
		c.typ = "*"
		i++
	} else if i < len(sel) && isCSSIdentByte(sel[i]) {
		c.typ = ident()
	}
	for i < len(sel) {
		switch ch := sel[i]; ch {
		case '.', '#':
			i++
			name := ident()
			if name == "" {
				return c, cssInvalid("the <style> rule %q has a malformed selector", sel)
			}
			if ch == '.' {
				c.classes = append(c.classes, name)
			} else {
				c.ids = append(c.ids, name)
			}
		case ' ':
			rest := strings.TrimLeft(sel[i:], " ")
			if rest != "" && strings.ContainsRune(">+~", rune(rest[0])) {
				i += len(sel[i:]) - len(rest)
				continue
			}
			return c, cssInvalid("the <style> rule %q uses a descendant selector, %s", sel, fix)
		case '>':
			return c, cssInvalid("the <style> rule %q uses a child combinator (>), %s", sel, fix)
		case '+', '~':
			return c, cssInvalid("the <style> rule %q uses a sibling combinator (%c), %s", sel, ch, fix)
		case ':':
			j := i + 1
			kind := "pseudo-class"
			if j < len(sel) && sel[j] == ':' {
				j++
				kind = "pseudo-element"
			}
			for j < len(sel) && isCSSIdentByte(sel[j]) {
				j++
			}
			return c, cssInvalid("the <style> rule %q uses the %s %q, %s", sel, kind, sel[i:j], fix)
		case '[':
			return c, cssInvalid("the <style> rule %q uses an attribute selector, %s", sel, fix)
		case '&':
			return c, cssInvalid("the <style> rule %q uses nesting (&), %s", sel, fix)
		case '|':
			return c, cssInvalid("the <style> rule %q uses a namespace selector, %s", sel, fix)
		default:
			return c, cssInvalid("the <style> rule %q has a selector that can't be converted; use a type, .class, #id or * selector", sel)
		}
	}
	if c.typ == "" && len(c.ids) == 0 && len(c.classes) == 0 {
		return c, cssInvalid("the <style> rule %q has a malformed selector", sel)
	}
	return c, nil
}

var cssImportant = regexp.MustCompile(`(?i)!\s*important\s*$`)

// parseDeclarations parses "prop: value; …". context names where the
// declarations came from, for error messages. Each kept declaration takes the
// next source order from *order.
func parseDeclarations(block, context string, order *int) ([]cssDecl, error) {
	if strings.ContainsRune(block, '\\') {
		return nil, cssInvalid("%s uses a CSS escape (\\), which can't be converted; write the characters themselves", context)
	}
	var out []cssDecl
	for _, raw := range splitOutside(block, ';') {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		colon := strings.IndexByte(raw, ':')
		if colon < 0 {
			return nil, cssInvalid("%s has a declaration %q without a colon", context, raw)
		}
		prop := strings.ToLower(strings.TrimSpace(raw[:colon]))
		value := strings.TrimSpace(raw[colon+1:])
		important := false
		if loc := cssImportant.FindStringIndex(value); loc != nil {
			important = true
			value = strings.TrimSpace(value[:loc[0]])
		}
		if ignoredCSSProp(prop) {
			continue
		}
		if prop != "marker" && !mockupPresentationPropSet[prop] {
			return nil, cssInvalid("%s sets the property %q, which isn't a mockup SVG presentation attribute and can't be converted; use properties like fill, stroke, opacity or font-size", context, prop)
		}
		if value == "" {
			return nil, cssInvalid("%s gives the property %q no value", context, prop)
		}
		lower := strings.ToLower(value)
		for _, fn := range []string{"var(", "calc("} {
			if strings.Contains(lower, fn) {
				return nil, cssInvalid("%s sets %q to %q, which uses %s) and can't be converted; write the value itself", context, prop, value, fn)
			}
		}
		props := []string{prop}
		if prop == "marker" {
			props = []string{"marker-start", "marker-mid", "marker-end"}
		}
		*order++
		for _, p := range props {
			out = append(out, cssDecl{prop: p, value: value, important: important, order: *order})
		}
	}
	return out, nil
}

func ignoredCSSProp(prop string) bool {
	switch prop {
	case "cursor", "pointer-events", "user-select":
		return true
	}
	return strings.HasPrefix(prop, "transition") ||
		strings.HasPrefix(prop, "-webkit-") || strings.HasPrefix(prop, "-moz-")
}

// splitOutside splits s on sep, ignoring separators inside quotes or
// parentheses (url(data:…;base64,…), rgb(1, 2, 3)).
func splitOutside(s string, sep byte) []string {
	var parts []string
	depth, start := 0, 0
	var quote byte
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case quote != 0:
			if c == '\\' {
				i++
			} else if c == quote {
				quote = 0
			}
		case c == '"' || c == '\'':
			quote = c
		case c == '(':
			depth++
		case c == ')':
			if depth > 0 {
				depth--
			}
		case c == sep && depth == 0:
			parts = append(parts, s[start:i])
			start = i + 1
		}
	}
	return append(parts, s[start:])
}

func collapseSpace(s string) string { return strings.Join(strings.Fields(s), " ") }

func quoteCSS(s string) string { return `"` + strings.ReplaceAll(s, `"`, `\"`) + `"` }

// --- cascade ---

// cssWeight orders competing declarations. level: 0 stylesheet, 1 style
// attribute, 2 stylesheet !important, 3 style attribute !important. Within a
// level, specificity (ids, classes, types) then source order decide.
type cssWeight struct {
	level int
	spec  [3]int
	order int
}

func (a cssWeight) less(b cssWeight) bool {
	if a.level != b.level {
		return a.level < b.level
	}
	for i := range a.spec {
		if a.spec[i] != b.spec[i] {
			return a.spec[i] < b.spec[i]
		}
	}
	return a.order < b.order
}

// cascadeElement returns the winning value of every property some CSS sets on
// el. Presentation attributes rank below all CSS, so any CSS value wins.
func cascadeElement(el *cssElement, rules []cssRule, order *int) (map[string]string, error) {
	type candidate struct {
		w     cssWeight
		value string
	}
	best := map[string]candidate{}
	offer := func(d cssDecl, w cssWeight) {
		if cur, ok := best[d.prop]; !ok || cur.w.less(w) {
			best[d.prop] = candidate{w: w, value: d.value}
		}
	}
	for _, r := range rules {
		var spec [3]int
		matched := false
		for _, s := range r.selectors {
			if !s.matches(el) {
				continue
			}
			// A selector list's specificity for an element is its most
			// specific matching selector.
			if sp := s.specificity(); !matched || (cssWeight{spec: spec}).less(cssWeight{spec: sp}) {
				spec = sp
			}
			matched = true
		}
		if !matched {
			continue
		}
		for _, d := range r.decls {
			level := 0
			if d.important {
				level = 2
			}
			offer(d, cssWeight{level: level, spec: spec, order: d.order})
		}
	}
	if el.hasStyle {
		decls, err := parseDeclarations(el.style, "the style attribute on <"+el.local+">", order)
		if err != nil {
			return nil, err
		}
		for _, d := range decls {
			level := 1
			if d.important {
				level = 3
			}
			offer(d, cssWeight{level: level, order: d.order})
		}
	}
	values := make(map[string]string, len(best))
	for p, c := range best {
		values[p] = c.value
	}
	return values, nil
}

// --- start-tag rewriting ---

type rawAttr struct {
	name                 string
	segStart, segEnd     int // whitespace before the name through the closing quote
	valueStart, valueEnd int // inside the quotes
	quote                byte
}

// scanRawStartTag splits a well-formed start tag into the tag name's end,
// its attributes and the offset of the tail (whitespace, optional /, >).
func scanRawStartTag(tag string) (nameEnd int, attrs []rawAttr, tail int) {
	isSpace := func(c byte) bool { return c == ' ' || c == '\t' || c == '\n' || c == '\r' }
	i := 1
	for i < len(tag) && !isSpace(tag[i]) && tag[i] != '/' && tag[i] != '>' {
		i++
	}
	nameEnd = i
	for {
		seg := i
		for i < len(tag) && isSpace(tag[i]) {
			i++
		}
		if i >= len(tag) || tag[i] == '/' || tag[i] == '>' {
			return nameEnd, attrs, seg
		}
		n := i
		for i < len(tag) && !isSpace(tag[i]) && tag[i] != '=' {
			i++
		}
		a := rawAttr{name: tag[n:i], segStart: seg}
		for i < len(tag) && tag[i] != '"' && tag[i] != '\'' {
			i++
		}
		if i >= len(tag) {
			return nameEnd, attrs, seg
		}
		a.quote = tag[i]
		a.valueStart = i + 1
		end := strings.IndexByte(tag[a.valueStart:], a.quote)
		if end < 0 {
			return nameEnd, attrs, seg
		}
		a.valueEnd = a.valueStart + end
		a.segEnd = a.valueEnd + 1
		i = a.segEnd
		attrs = append(attrs, a)
	}
}

func escapeAttrValue(v string, quote byte) string {
	v = strings.ReplaceAll(v, "&", "&amp;")
	v = strings.ReplaceAll(v, "<", "&lt;")
	if quote == '\'' {
		return strings.ReplaceAll(v, "'", "&apos;")
	}
	return strings.ReplaceAll(v, `"`, "&quot;")
}

// rewriteStartTag drops class and style, sets the cascaded values and keeps
// everything else (name, attribute order, quoting, spacing) as written.
func rewriteStartTag(tag string, el *cssElement, values map[string]string) (string, bool) {
	nameEnd, attrs, tail := scanRawStartTag(tag)
	changed := false
	done := map[string]bool{}
	var b strings.Builder
	b.WriteString(tag[:nameEnd])
	for _, a := range attrs {
		if a.name == "class" || a.name == "style" {
			changed = true
			continue
		}
		v, ok := values[a.name]
		if !ok {
			b.WriteString(tag[a.segStart:a.segEnd])
			continue
		}
		done[a.name] = true
		if el.attrs[a.name] == v {
			b.WriteString(tag[a.segStart:a.segEnd])
			continue
		}
		changed = true
		b.WriteString(tag[a.segStart:a.valueStart])
		b.WriteString(escapeAttrValue(v, a.quote))
		b.WriteString(tag[a.valueEnd:a.segEnd])
	}
	for _, p := range mockupPresentationProps {
		v, ok := values[p]
		if !ok || done[p] {
			continue
		}
		changed = true
		b.WriteString(" " + p + `="` + escapeAttrValue(v, '"') + `"`)
	}
	b.WriteString(tag[tail:])
	return b.String(), changed
}

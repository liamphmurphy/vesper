package personas

import (
	"bytes"
	"encoding/xml"
	"errors"
	"io"
	"math"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

const (
	MaxCharacterSVGBytes = 32 << 10 // 32 KB
	MaxCharacterElements = 160
	MaxCharacterDepth    = 16
	svgNamespace         = "http://www.w3.org/2000/svg"
	xlinkNamespace       = "http://www.w3.org/1999/xlink"
)

// CharacterMotions are the whitelisted CSS animation names a persona character layer may reference.
var CharacterMotions = []string{
	"none",
	"breathe",
	"float",
	"blink",
	"glance",
	"tilt",
	"nod",
	"sway",
	"wag",
	"wag-fast",
	"tap",
	"type",
	"bounce",
	"wave",
	"scan",
	"orbit",
	"spark",
	"pulse",
	"shadow",
}

// CharacterShowStates are the whitelisted visibility tokens allowed in data-show.
var CharacterShowStates = []string{
	"idle",
	"working",
	"thinking",
	"reading",
	"coding",
	"creating",
	"needs-you",
}

// CharacterSpeeds are the whitelisted speed presets allowed in data-speed.
var CharacterSpeeds = []string{"slow", "normal", "fast"}

var characterMotionAttrs = map[string]bool{
	"data-motion":           true,
	"data-motion-idle":      true,
	"data-motion-working":   true,
	"data-motion-thinking":  true,
	"data-motion-reading":   true,
	"data-motion-coding":    true,
	"data-motion-creating":  true,
	"data-motion-needs-you": true,
}

var characterElements = map[string]bool{
	"svg":            true,
	"g":              true,
	"rect":           true,
	"circle":         true,
	"ellipse":        true,
	"line":           true,
	"polyline":       true,
	"polygon":        true,
	"path":           true,
	"text":           true,
	"tspan":          true,
	"title":          true,
	"desc":           true,
	"defs":           true,
	"linearGradient": true,
	"radialGradient": true,
	"stop":           true,
	"clipPath":       true,
	"mask":           true,
	"pattern":        true,
	"symbol":         true,
	"use":            true,
	"marker":         true,
}

var characterTextElements = map[string]bool{
	"text":  true,
	"tspan": true,
	"title": true,
	"desc":  true,
}

var characterAttrs = map[string]bool{
	"x": true, "y": true, "x1": true, "y1": true, "x2": true, "y2": true,
	"cx": true, "cy": true, "r": true, "rx": true, "ry": true, "fx": true, "fy": true,
	"width": true, "height": true, "d": true, "points": true, "transform": true,
	"viewBox": true, "preserveAspectRatio": true,
	"fill": true, "stroke": true, "opacity": true,
	"stroke-width": true, "stroke-dasharray": true, "stroke-dashoffset": true,
	"stroke-linecap": true, "stroke-linejoin": true, "stroke-miterlimit": true,
	"fill-opacity": true, "stroke-opacity": true, "fill-rule": true, "clip-rule": true,
	"font-family": true, "font-size": true, "font-weight": true, "font-style": true,
	"text-anchor": true, "dominant-baseline": true, "letter-spacing": true,
	"offset": true, "stop-color": true, "stop-opacity": true,
	"gradientUnits": true, "gradientTransform": true, "spreadMethod": true,
	"dx": true, "dy": true, "id": true,
	"clip-path": true, "mask": true,
	"marker-start": true, "marker-mid": true, "marker-end": true,
	"patternUnits": true, "patternTransform": true, "clipPathUnits": true, "maskUnits": true,
	"markerWidth": true, "markerHeight": true, "refX": true, "refY": true, "orient": true,
	"href": true, "rotate": true, "display": true, "visibility": true,
	"aria-hidden": true,
	"data-part":   true, "data-show": true, "data-pivot": true, "data-delay": true, "data-speed": true,
}

var (
	svgIDRe    = regexp.MustCompile(`^[A-Za-z_][\w.:-]*$`)
	svgURLRe   = regexp.MustCompile(`(?i)^url\(\s*#([A-Za-z_][\w.:-]*)\s*\)$`)
	partNameRe = regexp.MustCompile(`^[a-z0-9-]{1,32}$`)
	splitWSRe  = regexp.MustCompile(`[\s,]+`)
)

func charInvalid(format string, args ...any) error {
	return apperr.Invalid("character_svg", format, args...)
}

// CheckCharacterSVG validates a persona's animated SVG character against the
// 64x64 rig specification and element/attribute whitelist.
func CheckCharacterSVG(raw string) (string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return "", charInvalid("character SVG cannot be empty")
	}
	if len(trimmed) > MaxCharacterSVGBytes {
		return "", charInvalid("character SVG must be at most %d bytes", MaxCharacterSVGBytes)
	}

	d := xml.NewDecoder(strings.NewReader(trimmed))
	d.Strict = true
	d.Entity = map[string]string{}

	var stack []string
	elements := 0
	roots := 0

	for {
		tok, err := d.Token()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return "", charInvalid("not well-formed SVG: %v", err)
		}
		switch t := tok.(type) {
		case xml.Directive:
			return "", charInvalid("DOCTYPE and directives aren't allowed")
		case xml.ProcInst:
			if t.Target != "xml" {
				return "", charInvalid("processing instructions aren't allowed")
			}
		case xml.CharData:
			if len(bytes.TrimSpace(t)) == 0 {
				continue
			}
			if len(stack) == 0 || !characterTextElements[stack[len(stack)-1]] {
				return "", charInvalid("unexpected text outside <text>, <tspan>, <title>, or <desc>")
			}
		case xml.StartElement:
			elements++
			if elements > MaxCharacterElements {
				return "", charInvalid("character SVG has too many elements (max %d)", MaxCharacterElements)
			}
			if len(stack)+1 > MaxCharacterDepth {
				return "", charInvalid("character SVG nesting is too deep (max %d)", MaxCharacterDepth)
			}
			name := t.Name.Local
			if len(stack) == 0 {
				roots++
				if roots > 1 {
					return "", charInvalid("character SVG must have a single <svg> root")
				}
				if name != "svg" {
					return "", charInvalid("the root element must be <svg>")
				}
				if t.Name.Space != svgNamespace {
					return "", charInvalid(`the root <svg> needs xmlns="%s"`, svgNamespace)
				}
				if err := checkRootViewBox(t.Attr); err != nil {
					return "", err
				}
			} else {
				if name == "svg" {
					return "", charInvalid("nested <svg> elements aren't allowed")
				}
				if t.Name.Space != "" && t.Name.Space != svgNamespace {
					return "", charInvalid("foreign element <%s> isn't allowed", name)
				}
				if err := checkAllowedElement(name); err != nil {
					return "", err
				}
			}
			for _, a := range t.Attr {
				if err := checkCharacterAttr(name, a); err != nil {
					return "", err
				}
			}
			stack = append(stack, name)
		case xml.EndElement:
			if len(stack) > 0 {
				stack = stack[:len(stack)-1]
			}
		}
	}

	if roots == 0 {
		return "", charInvalid("missing root <svg> element")
	}
	return trimmed, nil
}

func checkAllowedElement(name string) error {
	if characterElements[name] {
		return nil
	}
	switch name {
	case "style":
		return charInvalid("<style> isn't allowed; use presentation attributes and data-motion-* animations instead")
	case "animate", "animateTransform", "animateMotion", "set":
		return charInvalid("<%s> isn't allowed; use data-motion-* and data-show attributes instead", name)
	default:
		return charInvalid("element <%s> isn't allowed in character SVGs", name)
	}
}

func checkRootViewBox(attrs []xml.Attr) error {
	for _, a := range attrs {
		if a.Name.Space == "" && a.Name.Local == "viewBox" {
			fields := splitWSRe.Split(strings.TrimSpace(a.Value), -1)
			if len(fields) != 4 {
				return charInvalid(`viewBox must be "0 0 64 64"`)
			}
			var vals [4]float64
			for i, f := range fields {
				v, err := strconv.ParseFloat(f, 64)
				if err != nil || math.IsNaN(v) || math.IsInf(v, 0) {
					return charInvalid(`viewBox must be "0 0 64 64"`)
				}
				vals[i] = v
			}
			if vals[0] != 0 || vals[1] != 0 || vals[2] != 64 || vals[3] != 64 {
				return charInvalid(`viewBox must be "0 0 64 64"`)
			}
			return nil
		}
	}
	return charInvalid(`root <svg> requires viewBox="0 0 64 64"`)
}

func checkCharacterAttr(elem string, a xml.Attr) error {
	// Go's encoding/xml surfaces xmlns declarations as Space=="xmlns" or Local=="xmlns".
	if a.Name.Space == "xmlns" || (a.Name.Space == "" && a.Name.Local == "xmlns") {
		if elem == "svg" && (a.Value == svgNamespace || a.Value == xlinkNamespace) {
			return nil
		}
		return charInvalid("namespace attribute isn't allowed on <%s>", elem)
	}
	name := a.Name.Local
	if a.Name.Space != "" {
		if a.Name.Space == xlinkNamespace && name == "href" {
			name = "href"
		} else {
			return charInvalid("attribute %q isn't allowed", name)
		}
	}
	if !characterAttrs[name] && !characterMotionAttrs[name] {
		return charInvalid("attribute %q isn't allowed", name)
	}
	return checkAttrValue(name, a.Value)
}

func hasUnsafeScriptRef(raw string) bool {
	var b strings.Builder
	for _, r := range raw {
		if r > 0x20 && r != 0x7f {
			b.WriteRune(r)
		}
	}
	clean := strings.ToLower(b.String())
	return strings.Contains(clean, "javascript:") || strings.Contains(clean, "expression(")
}

func checkAttrValue(name, val string) error {
	if hasUnsafeScriptRef(val) {
		return charInvalid("unsafe value in attribute %q", name)
	}
	if name == "id" {
		if !svgIDRe.MatchString(val) {
			return charInvalid("invalid id %q", val)
		}
		return nil
	}
	if name == "href" {
		if !strings.HasPrefix(val, "#") || !svgIDRe.MatchString(val[1:]) {
			return charInvalid("href must reference a local #id, got %q", val)
		}
		return nil
	}
	if strings.Contains(strings.ToLower(val), "url(") {
		if !svgURLRe.MatchString(strings.TrimSpace(val)) {
			return charInvalid("url(...) references must target a local #id in %q", name)
		}
	}
	if characterMotionAttrs[name] {
		if !slices.Contains(CharacterMotions, val) {
			return charInvalid("%s=%q isn't a supported motion", name, val)
		}
		return nil
	}
	switch name {
	case "data-part":
		if !partNameRe.MatchString(val) {
			return charInvalid("data-part %q must be 1–32 lowercase letters, digits, or hyphens", val)
		}
	case "data-show":
		toks := strings.Fields(val)
		if len(toks) == 0 {
			return charInvalid("data-show cannot be empty")
		}
		for _, tok := range toks {
			if !slices.Contains(CharacterShowStates, tok) {
				return charInvalid("data-show token %q isn't supported", tok)
			}
		}
	case "data-pivot":
		fields := strings.Fields(val)
		if len(fields) != 2 {
			return charInvalid(`data-pivot must be "x y" within 0..64`)
		}
		for _, f := range fields {
			v, err := strconv.ParseFloat(f, 64)
			if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < 0 || v > 64 {
				return charInvalid(`data-pivot coordinates must be numbers in [0, 64], got %q`, val)
			}
		}
	case "data-delay":
		s := strings.TrimSuffix(strings.TrimSpace(val), "s")
		v, err := strconv.ParseFloat(s, 64)
		if err != nil || math.IsNaN(v) || math.IsInf(v, 0) || v < -4 || v > 4 {
			return charInvalid("data-delay must be a number of seconds in [-4, 4], got %q", val)
		}
	case "data-speed":
		if !slices.Contains(CharacterSpeeds, val) {
			return charInvalid("data-speed must be slow, normal, or fast, got %q", val)
		}
	}
	return nil
}

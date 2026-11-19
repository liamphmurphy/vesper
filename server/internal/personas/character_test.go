package personas

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

const validCharacterSVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" fill="none">
  <title>Meow</title>
  <ellipse data-part="shadow" data-motion="shadow" cx="32" cy="58" rx="14" ry="3" fill="#000" opacity="0.2"/>
  <g data-part="body" data-motion-idle="breathe" data-motion-working="tap" data-motion-coding="type" data-pivot="32 34" data-speed="normal">
    <circle cx="32" cy="34" r="16" fill="currentColor"/>
    <g data-part="eyes" data-motion="blink" data-delay="-0.5">
      <circle cx="26" cy="32" r="2" fill="#18181b"/>
      <circle cx="38" cy="32" r="2" fill="#18181b"/>
    </g>
    <path data-show="coding creating" data-motion="spark" d="M48 16l2 4 4 2-4 2-2 4-2-4-4-2 4-2z" fill="#ffd6a0"/>
  </g>
</svg>`

func TestCheckCharacterSVGValid(t *testing.T) {
	got, err := CheckCharacterSVG("  " + validCharacterSVG + "\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.HasPrefix(got, "<svg") || !strings.HasSuffix(got, "</svg>") {
		t.Fatalf("expected trimmed svg, got %q", got)
	}

	// Internal gradient + use href references are permitted.
	withDefs := `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 64 64">
	  <defs>
	    <linearGradient id="coat" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#000"/></linearGradient>
	    <circle id="ear" cx="20" cy="18" r="5"/>
	  </defs>
	  <circle cx="32" cy="32" r="20" fill="url(#coat)"/>
	  <use xlink:href="#ear"/>
	</svg>`
	if _, err := CheckCharacterSVG(withDefs); err != nil {
		t.Fatalf("valid defs/use failed: %v", err)
	}
}

func TestCheckCharacterSVGRejectsUnsafeOrInvalid(t *testing.T) {
	many := strings.Repeat(`<rect x="1" y="1" width="1" height="1"/>`, MaxCharacterElements+1)
	deepOpen := strings.Repeat(`<g>`, MaxCharacterDepth)
	deepClose := strings.Repeat(`</g>`, MaxCharacterDepth)

	cases := []struct {
		name string
		svg  string
	}{
		{"empty", "   "},
		{"oversize", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">` + strings.Repeat(" ", MaxCharacterSVGBytes) + `</svg>`},
		{"not xml", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect>`},
		{"doctype", `<!DOCTYPE svg><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"/>`},
		{"missing xmlns", `<svg viewBox="0 0 64 64"><circle cx="32" cy="32" r="10"/></svg>`},
		{"wrong root", `<g xmlns="http://www.w3.org/2000/svg"/>`},
		{"wrong viewBox", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100"/>`},
		{"missing viewBox", `<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64"/>`},
		{"nested svg", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><svg viewBox="0 0 10 10"/></svg>`},
		{"script", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><script>alert(1)</script></svg>`},
		{"style", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><style>rect{fill:red}</style></svg>`},
		{"foreignObject", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><foreignObject><div/></foreignObject></svg>`},
		{"image", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><image href="https://example.com/a.png"/></svg>`},
		{"animate", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="5"><animate attributeName="r" values="5;8"/></circle></svg>`},
		{"onclick", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="5" onclick="alert(1)"/></svg>`},
		{"inline style", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><circle cx="32" cy="32" r="5" style="fill:red"/></svg>`},
		{"external href", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><use href="https://evil.example/a.svg#x"/></svg>`},
		{"external url fill", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><rect width="10" height="10" fill="url(https://evil.example/g)"/></svg>`},
		{"bad motion", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g data-motion="explode"/></svg>`},
		{"bad action motion", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g data-motion-coding="flip"/></svg>`},
		{"bad show", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g data-show="sleeping"/></svg>`},
		{"bad pivot range", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g data-pivot="32 90"/></svg>`},
		{"bad delay", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g data-delay="12"/></svg>`},
		{"bad speed", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g data-speed="turbo"/></svg>`},
		{"bad part", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64"><g data-part="Bad Name!"/></svg>`},
		{"too many elements", fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">%s</svg>`, many)},
		{"too deep", fmt.Sprintf(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">%s<rect width="1" height="1"/>%s</svg>`, deepOpen, deepClose)},
		{"stray text", `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">hello</svg>`},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := CheckCharacterSVG(tc.svg)
			var ve *apperr.ValidationError
			if !errors.As(err, &ve) || ve.Field != "character_svg" {
				t.Fatalf("expected validation error on character_svg, got %v", err)
			}
		})
	}
}

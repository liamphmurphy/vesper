package artifacts

import (
	"errors"
	"path/filepath"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

func corpus(t *testing.T, pattern string) []string {
	t.Helper()
	files, err := filepath.Glob(filepath.Join(mockupCorpus, pattern))
	if err != nil || len(files) == 0 {
		t.Fatalf("no fixtures for %s: %v", pattern, err)
	}
	return files
}

func TestMockupProfileAcceptsValidCorpus(t *testing.T) {
	for _, f := range corpus(t, "valid/*.svg") {
		t.Run(filepath.Base(f), func(t *testing.T) {
			body := readFixture(t, f)
			if err := ValidSVG(body); err != nil {
				t.Fatalf("ValidSVG: %v", err)
			}
			if err := ValidateMockupProfile(body); err != nil {
				t.Fatalf("ValidateMockupProfile: %v", err)
			}
		})
	}
}

func TestMockupProfileRejectsInvalidCorpus(t *testing.T) {
	// Each fixture breaks one rule; its message must be about that rule.
	mentions := map[string]string{
		"anchor-element":               "<a> isn't allowed",
		"animate-element":              "<animate> isn't allowed",
		"bad-color-name":               `fill="reddish" isn't a colour`,
		"bad-color":                    `fill="#12345" isn't a colour`,
		"bad-enum-baseline":            "dominant-baseline=\"mathematical\" must be one of",
		"bad-enum-linecap":             "stroke-linecap=\"pointy\" must be one of",
		"bad-path":                     "isn't valid path data",
		"bad-transform":                `transform="translate3d(1px, 2px, 0)" must be a list`,
		"calc-length":                  "uses calc()",
		"class-attribute":              `<rect> attribute class isn't allowed in mockups; use presentation attributes like fill="#fff"`,
		"coordinate-list":              `x="10 20 30" must be a single number`,
		"filter-attribute":             "<rect> attribute filter isn't allowed",
		"filter-element":               "<filter> isn't allowed",
		"glyph-rotate":                 "<text> attribute rotate isn't allowed",
		"missing-reference":            "points at #nope, which doesn't exist",
		"nested-svg":                   "<svg> isn't allowed in mockups; an <svg> can only be the root",
		"no-viewbox-or-size":           "the root <svg> needs a viewBox",
		"percent-size-without-viewbox": "the root <svg> needs a viewBox",
		"percent-stroke-width":         `stroke-width="10%" can't be a percentage`,
		"style-attribute":              "<rect> attribute style isn't allowed",
		"style-element":                "<style> isn't allowed",
		"switch-element":               "<switch> isn't allowed",
		"text-length":                  "<text> attribute textLength isn't allowed",
		"text-path":                    "<textPath> isn't allowed",
		"too-deep":                     "more than 32 deep",
		"too-many-elements":            "more than 5000 elements",
		"unit-em":                      `width="10em" uses a unit`,
		"unit-mm":                      `height="10mm" uses a unit`,
		"unknown-attribute":            "<rect> attribute shape-rendering isn't allowed",
		"use-indirect-cycle":           "reference cycle",
		"use-self-cycle":               "reference cycle",
		"var-color":                    "uses var()",
		"wrong-reference-kind":         "points at a <clipPath>",
		"zero-viewbox":                 "needs a positive width and height",
	}
	for _, f := range corpus(t, "invalid/*.svg") {
		name := strings.TrimSuffix(filepath.Base(f), ".svg")
		t.Run(name, func(t *testing.T) {
			want, ok := mentions[name]
			if !ok {
				t.Fatalf("add the expected message for %s to the table", name)
			}
			body := readFixture(t, f)
			err := ValidSVG(body)
			if err == nil {
				err = ValidateMockupProfile(body)
			}
			var ve *apperr.ValidationError
			if !errors.As(err, &ve) || ve.Field != "svg" {
				t.Fatalf("err = %v, want an apperr.Invalid on svg", err)
			}
			if !strings.Contains(ve.Msg, want) {
				t.Errorf("message %q doesn't mention %q", ve.Msg, want)
			}
		})
	}
}

func TestNormalizedFixturesConform(t *testing.T) {
	for _, f := range corpus(t, "normalize/*.out.svg") {
		t.Run(filepath.Base(f), func(t *testing.T) {
			body := readFixture(t, f)
			if err := ValidSVG(body); err != nil {
				t.Fatalf("ValidSVG: %v", err)
			}
			if err := ValidateMockupProfile(body); err != nil {
				t.Fatalf("ValidateMockupProfile: %v", err)
			}
		})
	}
}

func TestMockupProfileReportsSeveralProblems(t *testing.T) {
	body := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <rect class="a" width="1em" height="1"/>
  <circle r="1" fill="url(#none)"/>
</svg>`
	err := ValidateMockupProfile(body)
	if err == nil {
		t.Fatal("accepted")
	}
	for _, want := range []string{"(1) <rect> attribute class", "(2) <rect> attribute width=\"1em\"", "(3) <circle> attribute fill=\"url(#none)\" points at #none"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("%q doesn't mention %q", err, want)
		}
	}
}

func TestMockupProfileValues(t *testing.T) {
	doc := func(inner string) string {
		return `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 100"><defs><linearGradient id="g"/><clipPath id="c"/><marker id="m"/></defs>` + inner + `</svg>`
	}
	cases := []struct {
		inner string
		ok    bool
	}{
		{`<rect width="10" height="10" fill="hsl(210deg 50% 40%)"/>`, true},
		{`<rect width="10" height="10" fill="rgb(1,2,3,4,5)"/>`, false},
		{`<rect width="10" height="10" fill="url('#g') none"/>`, true},
		{`<rect width="10" height="10" fill="none" stroke="url(#c)"/>`, false},
		{`<rect width="10" height="10" clip-path="url(#c)"/>`, true},
		{`<rect width="10" height="10" clip-path="url(#g)"/>`, false},
		{`<path d="M0,0L10-10h5v.5.5z"/>`, true},
		{`<path d="L0 0"/>`, false},
		{`<path d="M0 0 A5 5 0 1 0 10 10"/>`, true},
		{`<path d="M0 0 A5 5 0 2 0 10 10"/>`, false},
		{`<polyline points="0 0 1"/>`, false},
		{`<rect width="10" height="10" transform="rotate(1 2)"/>`, false},
		{`<rect width="10" height="10" transform="rotate(45deg)"/>`, false},
		{`<line x2="10" marker-end="url(#m)" stroke-dasharray="4, 2 1px"/>`, true},
		{`<rect width="10" height="10" viewBox="0 0 1 1" preserveAspectRatio="none"/>`, true},
		{`<g viewBox="0 0 1 1"/>`, false},
		{`<image width="10" height="10" href="data:image/svg+xml;base64,AAAA"/>`, false},
		{`<use href="#g"/>`, false},
		{`<use xlink:href="#m2"/>`, false},
		{`<rect width="10" height="10" inkscape:label="x" xmlns:inkscape="urn:inkscape"/>`, false},
		{`<rect width="10" height="10" data-vid="r1" aria-label="x" role="img"/>`, true},
		{`<title><blink class="x">ignored</blink></title><desc style="x"/>`, true},
		{`<text x="1" y="1" font-weight="650">a</text>`, false},
		{`<text x="1" y="1" letter-spacing="normal" font-size="12px">a</text>`, true},
	}
	for _, c := range cases {
		err := ValidateMockupProfile(doc(c.inner))
		if (err == nil) != c.ok {
			t.Errorf("%s: ok=%v err=%v", c.inner, c.ok, err)
		}
	}
}

func TestCSSNamedColors(t *testing.T) {
	if len(cssNamedColors) != 148 {
		t.Fatalf("%d named colours, want 148", len(cssNamedColors))
	}
}

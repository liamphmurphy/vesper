package artifacts

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

const mockupCorpus = "../../../testdata/mockup-svg"

func TestNormalizeMockupSVGFixtures(t *testing.T) {
	ins, err := filepath.Glob(filepath.Join(mockupCorpus, "normalize", "*.in.svg"))
	if err != nil || len(ins) == 0 {
		t.Fatalf("no normalize fixtures: %v", err)
	}
	for _, in := range ins {
		name := strings.TrimSuffix(filepath.Base(in), ".in.svg")
		t.Run(name, func(t *testing.T) {
			input := readFixture(t, in)
			want := readFixture(t, strings.TrimSuffix(in, ".in.svg")+".out.svg")
			got, err := NormalizeMockupSVG(input)
			if err != nil {
				t.Fatalf("NormalizeMockupSVG: %v", err)
			}
			if got != want {
				t.Errorf("output mismatch\n--- got ---\n%s\n--- want ---\n%s", got, want)
			}
			for _, bad := range []string{"<style", " class=", " style="} {
				if strings.Contains(got, bad) {
					t.Errorf("output still contains %q", bad)
				}
			}
		})
	}
}

func TestNormalizeMockupSVGRejects(t *testing.T) {
	// Each fixture's error must name the offending rule or property.
	mentions := map[string]string{
		"attribute-selector":  `"rect[width]" uses an attribute selector`,
		"child-combinator":    `"g > rect" uses a child combinator`,
		"descendant-selector": `"g rect" uses a descendant selector`,
		"media-query":         `at-rule "@media"`,
		"pseudo-class":        `"rect:hover" uses the pseudo-class ":hover"`,
		"unknown-property":    `the property "filter"`,
		"var-value":           `"var(--accent)"`,
	}
	files, err := filepath.Glob(filepath.Join(mockupCorpus, "normalize-reject", "*.svg"))
	if err != nil || len(files) == 0 {
		t.Fatalf("no normalize-reject fixtures: %v", err)
	}
	for _, f := range files {
		name := strings.TrimSuffix(filepath.Base(f), ".svg")
		t.Run(name, func(t *testing.T) {
			want, ok := mentions[name]
			if !ok {
				t.Fatalf("add the expected message for %s to the table", name)
			}
			_, err := NormalizeMockupSVG(readFixture(t, f))
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

func TestNormalizeMockupSVGPassThrough(t *testing.T) {
	for name, body := range map[string]string{
		"no css":    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect  width='1'   height="1"/></svg>`,
		"malformed": `<svg xmlns="http://www.w3.org/2000/svg"><style>g rect{}</style><rect class="x">`,
	} {
		got, err := NormalizeMockupSVG(body)
		if err != nil || got != body {
			t.Errorf("%s: got %q, %v; want the body unchanged", name, got, err)
		}
	}
}

func TestParseSelectorList(t *testing.T) {
	got, err := parseSelectorList("rect.card#a, .a.b ,*, #x, text")
	if err != nil {
		t.Fatal(err)
	}
	want := []cssCompound{
		{typ: "rect", classes: []string{"card"}, ids: []string{"a"}},
		{classes: []string{"a", "b"}},
		{typ: "*"},
		{ids: []string{"x"}},
		{typ: "text"},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	specs := [][3]int{{1, 1, 1}, {0, 2, 0}, {0, 0, 0}, {1, 0, 0}, {0, 0, 1}}
	for i, c := range got {
		if c.specificity() != specs[i] {
			t.Errorf("specificity(%+v) = %v, want %v", c, c.specificity(), specs[i])
		}
	}

	for sel, want := range map[string]string{
		"g rect":       "descendant selector",
		"g>rect":       "child combinator",
		"a + b":        "sibling combinator (+)",
		"a ~ b":        "sibling combinator (~)",
		"rect::before": `pseudo-element "::before"`,
		"a:not(.b)":    `pseudo-class ":not"`,
		".a[x=y]":      "attribute selector",
		"&.a":          "nesting",
		"svg|rect":     "namespace selector",
		".":            "malformed selector",
		"rect,":        "empty selector",
	} {
		_, err := parseSelectorList(sel)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("parseSelectorList(%q) = %v, want an error mentioning %q", sel, err, want)
		}
	}
}

func TestParseStylesheetErrors(t *testing.T) {
	for css, want := range map[string]string{
		"@import url(a.css);":           `at-rule "@import"`,
		"@font-face { font-family: x }": `at-rule "@font-face"`,
		".a { .b { fill: red } }":       "nests rules",
		".a { fill: red":                "missing its closing }",
		".a { fill: calc(1 + 2) }":      "calc()",
		".a { --accent: red }":          `the property "--accent"`,
		".a { fill }":                   "without a colon",
		".a { fill: }":                  "no value",
		"/* open":                       "unterminated /* comment",
	} {
		order := 0
		_, err := parseStylesheet(css, &order)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("parseStylesheet(%q) = %v, want an error mentioning %q", css, err, want)
		}
	}
}

func TestCascadeOrder(t *testing.T) {
	svg := func(css, attrs string) string {
		return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><style>` + css +
			`</style><rect id="r" class="c" ` + attrs + `/></svg>`
	}
	cases := []struct {
		name, css, attrs, want string
	}{
		{"css beats presentation attribute", `rect{fill:red}`, `fill="blue"`, `fill="red"`},
		{"class beats type", `.c{fill:red} rect{fill:blue}`, ``, `fill="red"`},
		{"id beats class", `#r{fill:red} .c{fill:blue}`, ``, `fill="red"`},
		{"compound beats single", `.c{fill:blue} rect.c{fill:red}`, ``, `fill="red"`},
		{"later rule wins at equal specificity", `.c{fill:blue} .c{fill:red}`, ``, `fill="red"`},
		{"later declaration in a rule wins", `.c{fill:blue;fill:red}`, ``, `fill="red"`},
		{"most specific matching selector of a list", `#r, rect{fill:red} .c{fill:blue}`, ``, `fill="red"`},
		{"style beats id", `#r{fill:blue}`, `style="fill:red"`, `fill="red"`},
		{"sheet important beats style", `rect{fill:red!important}`, `style="fill:blue"`, `fill="red"`},
		{"important type beats id", `rect{fill:red !IMPORTANT} #r{fill:blue}`, ``, `fill="red"`},
		{"style important beats sheet important", `#r{fill:blue!important}`, `style="fill:red!important"`, `fill="red"`},
		{"later style declaration wins", ``, `style="fill:blue;fill:red"`, `fill="red"`},
		{"universal applies", `*{fill:red}`, ``, `fill="red"`},
		{"value escaped", `rect{font-family:"A&lt;B"&amp;x}`, ``, `font-family="&quot;A&lt;B&quot;&amp;x"`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := NormalizeMockupSVG(svg(tc.css, tc.attrs))
			if err != nil {
				t.Fatal(err)
			}
			rect := got[strings.Index(got, "<rect"):]
			rect = strings.TrimSpace(strings.TrimSuffix(rect[:strings.Index(rect, ">")], "/"))
			if want := `<rect id="r" ` + tc.want; rect != want {
				t.Errorf("got %s, want %s", rect, want)
			}
		})
	}
}

func readFixture(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

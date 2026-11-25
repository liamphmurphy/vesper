package design

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const (
	fixtureDir = "../../../docs/design/fixtures"
	sharedDir  = "../../../design-worker/lib/designs/fixtures"
)

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestNormalizeAcceptsTheAcceptanceDesign(t *testing.T) {
	for _, f := range []string{fixtureDir + "/acceptance-design.json", sharedDir + "/valid-minimal.json", "../../../docs/design/poc/evidence/mermaid/checkout.design.json"} {
		out, err := Normalize(read(t, f))
		if err != nil {
			t.Fatalf("%s: %v", f, err)
		}
		again, err := Normalize(out)
		if err != nil || again != out {
			t.Fatalf("%s: normalising twice changed it (%v)", f, err)
		}
	}
}

// The shared invalid bodies: web/lib/designs/schema.test.mjs runs the same table.
func TestNormalizeRefusesTheSharedInvalidBodies(t *testing.T) {
	var cases []struct{ File, Want string }
	if err := json.Unmarshal([]byte(read(t, sharedDir+"/invalid/cases.json")), &cases); err != nil {
		t.Fatal(err)
	}
	files, _ := filepath.Glob(sharedDir + "/invalid/*.json")
	if len(cases) < 12 || len(files) != len(cases)+1 {
		t.Fatalf("%d cases for %d files", len(cases), len(files))
	}
	for _, c := range cases {
		_, err := Normalize(read(t, sharedDir+"/invalid/"+c.File))
		if err == nil {
			t.Errorf("%s: accepted", c.File)
		} else if !strings.Contains(err.Error(), c.Want) {
			t.Errorf("%s: got %q, want it to mention %q", c.File, err, c.Want)
		}
	}
}

func TestNormalizeCanonicalises(t *testing.T) {
	d, _ := Parse(read(t, sharedDir+"/valid-minimal.json"))
	home := pages(d)[0]["children"].([]any)[0].(map[string]any)
	home["fill"] = "#a1b2c3"
	home["x"] = 1.23456
	home["rotation"] = 0.0
	home["visible"] = true
	title := children(home)[0]
	run := title["paragraphs"].([]any)[0].(map[string]any)["runs"].([]any)[0].(map[string]any)
	run["bold"] = true
	run["italic"] = false
	raw, _ := json.Marshal(d)
	out, err := Normalize(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{`"fill":"#A1B2C3"`, `"x":1.23`, `"weight":700`} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %s", want)
		}
	}
	for _, gone := range []string{`"rotation"`, `"visible"`, `"bold"`, `"italic"`, "\n"} {
		if strings.Contains(out, gone) {
			t.Errorf("still has %q", gone)
		}
	}
}

func TestNormalizeCaps(t *testing.T) {
	big := `{"x":"` + strings.Repeat("a", MaxBody) + `"}`
	if _, err := Normalize(big); err == nil || !strings.Contains(err.Error(), "at most 2048 KB") {
		t.Fatalf("body over the cap: %v", err)
	}
	d, _ := Parse(read(t, sharedDir+"/valid-minimal.json"))
	next := children(pages(d)[0])[1]
	kids := make([]any, 0, MaxNodes)
	for i := range MaxNodes {
		kids = append(kids, map[string]any{"id": "n_s" + itoa(i), "type": "shape", "shape": "rect", "x": 0.0, "y": 0.0, "w": 1.0, "h": 1.0})
	}
	next["children"] = kids
	if _, err := Finish(d); err == nil || !strings.Contains(err.Error(), "nodes; the cap is 10000") {
		t.Fatalf("too many nodes: %v", err)
	}
}

func itoa(i int) string { b, _ := json.Marshal(i); return string(b) }

var update = flag.Bool("update", false, "rewrite the golden normalised fixture")

// The TypeScript normaliser must produce these exact bytes (web/lib/designs-schema.test.mjs).
func TestGoldenNormalizedFixture(t *testing.T) {
	out, err := Normalize(read(t, fixtureDir+"/acceptance-design.json"))
	if err != nil {
		t.Fatal(err)
	}
	golden := sharedDir + "/acceptance.normalized.json"
	if *update {
		if err := os.WriteFile(golden, []byte(out), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if read(t, golden) != out {
		t.Fatal("the normalised fixture changed: run go test -run Golden -update and check the diff")
	}
}

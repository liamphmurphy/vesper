package speech

import (
	"strings"
	"testing"
)

func TestSpeakableKeepsOnlyProse(t *testing.T) {
	md := "## Plan\n\nI checked the **runner** and found _two_ bugs [1].\n\n" +
		"```go\nfunc main() {}\n```\n\n" +
		"| a | b |\n|---|---|\n| 1 | 2 |\n\n" +
		"- First, fix the [lock](https://example.com/lock).\n- Then run `go test`\n\n" +
		"> Quoted aside\n\nSee https://example.com/x for details ![diagram](x.png)\n\n" +
		"```mermaid\ngraph TD\n```\n"
	got, words := Speakable(md, 200)
	want := "Plan. I checked the runner and found two bugs. First, fix the lock. Then run go test. Quoted aside. See for details."
	if got != want {
		t.Fatalf("Speakable =\n%q\nwant\n%q", got, want)
	}
	if words != len(strings.Fields(want)) {
		t.Errorf("words = %d", words)
	}
}

func TestSpeakableCapsAtASentence(t *testing.T) {
	md := "One two three. Four five six seven. Eight nine ten."
	if got, n := Speakable(md, 8); got != "One two three. Four five six seven." || n != 7 {
		t.Errorf("cap 8 = %q (%d)", got, n)
	}
	if got, n := Speakable("alpha beta gamma delta epsilon", 3); got != "alpha beta gamma…" || n != 3 {
		t.Errorf("one long sentence = %q (%d)", got, n)
	}
	if got, n := Speakable("```\nonly code\n```", 50); got != "" || n != 0 {
		t.Errorf("code only = %q (%d)", got, n)
	}
}

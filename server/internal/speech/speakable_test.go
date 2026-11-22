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

func TestSplitLeadEndsOnTheFirstSentencesLongEnoughToLead(t *testing.T) {
	cases := []struct{ text, lead, rest string }{
		// A short opener takes the next sentence along, so the rest has time to be voiced.
		{"Sure. I checked the runner and it looks fine. Want the logs?", "Sure. I checked the runner and it looks fine.", "Want the logs?"},
		{"The runner restarted cleanly after the deploy finished. Nothing else changed.", "The runner restarted cleanly after the deploy finished.", "Nothing else changed."},
		{"Too short to split. Really.", "Too short to split. Really.", ""},
		// An unfinished tail (a capped reply) belongs to the rest.
		{"This first sentence is long enough to lead. and then some words…", "This first sentence is long enough to lead.", "and then some words…"},
		{"no punctuation at all here", "no punctuation at all here", ""},
		{"", "", ""},
	}
	for _, c := range cases {
		lead, rest := SplitLead(c.text)
		if lead != c.lead || rest != c.rest {
			t.Errorf("SplitLead(%q) = %q | %q, want %q | %q", c.text, lead, rest, c.lead, c.rest)
		}
	}
}

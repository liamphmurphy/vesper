package artifacts

import "testing"

func TestCountWords(t *testing.T) {
	cases := []struct {
		name string
		md   string
		want int
	}{
		{name: "empty", md: "", want: 0},
		{name: "whitespace only", md: "   \n\t\n  ", want: 0},
		{name: "plain prose", md: "Hello world from Vesper.", want: 4},
		{name: "contractions and hyphens", md: "It's a well-known fact—really.", want: 5},
		{name: "smart apostrophe", md: "Don’t panic, it’s fine.", want: 4},
		{name: "headings and emphasis", md: "# Chapter 1: The Signal\n\n**Bold** and *italic* ~~old~~ ==new==.", want: 9},
		{name: "frontmatter ignored", md: "---\ntitle: Prologue\ntags: [book, draft]\n---\nFirst sentence here.", want: 3},
		{name: "fenced code ignored", md: "Before.\n```go\nfunc main() {\n\tprintln(\"hi\")\n}\n```\nAfter.", want: 2},
		{name: "tilde code fence ignored", md: "One\n~~~\ncode words here\n~~~\nTwo", want: 2},
		{name: "inline code kept", md: "Call `CreateArtifactVersion` once.", want: 3},
		{name: "embeds and images ignored", md: "![[map.png]]\n![alt text here](https://example.com/img.png)\nCaption.", want: 1},
		{name: "wikilinks use display text", md: "See [[Lore/Umbra|the Umbra]] and [[Locations/Citadel#Gate]].", want: 6},
		{name: "markdown links keep label", md: "Read [the full spec](https://example.com/a/b/c) now.", want: 5},
		{name: "task list and ordered list", md: "- [x] Finish chapter 2\n- [ ] Edit prologue\n1. First item\n2. Second item", want: 9},
		{name: "tables skip separator", md: "| Name | Role |\n| --- | :---: |\n| Judy | Netrunner |", want: 4},
		{name: "html comments and block anchors ignored", md: "<!-- hidden note\nwith lines -->\nVisible text ^block-1", want: 2},
		{name: "cjk characters", md: "Hello 世界", want: 3},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := CountWords(tc.md); got != tc.want {
				t.Fatalf("CountWords(%q) = %d, want %d", tc.md, got, tc.want)
			}
		})
	}
}

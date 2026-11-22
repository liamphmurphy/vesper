// Package speech turns a persona's reply into what its voice reads aloud.
package speech

import (
	"regexp"
	"strings"
	"unicode"
)

// MaxWords is how much of a reply a voice reads by default: about 45 seconds,
// which keeps a spoken reply around a cent and never drones through an essay.
const MaxWords = 120

var (
	fence      = regexp.MustCompile("(?s)(^|\n)\\s*(```|~~~).*?(\n\\s*(```|~~~)[^\n]*|$)")
	image      = regexp.MustCompile(`!\[[^\]]*\]\([^)]*\)`)
	link       = regexp.MustCompile(`\[([^\]]+)\]\([^)]*\)`)
	bareURL    = regexp.MustCompile(`<?https?://\S+>?`)
	citation   = regexp.MustCompile(`\s*\[\d+\]`)
	html       = regexp.MustCompile(`<[^>]+>`)
	emphasis   = regexp.MustCompile(`(\*\*|__|~~|\*|_|` + "`" + `)`)
	listMarker = regexp.MustCompile(`^\s*([-*+]|\d+[.)])\s+`)
	heading    = regexp.MustCompile(`^\s*#{1,6}\s+`)
	quote      = regexp.MustCompile(`^\s*>+\s?`)
	spaces     = regexp.MustCompile(`\s+`)
	sentence   = regexp.MustCompile(`[^.!?…]+[.!?…]+["')\]]*`)
)

// Speakable is the prose of a markdown reply as one plain paragraph: code,
// tables, images and URLs are dropped (they read badly aloud), links and
// emphasis keep their words, and each heading, list item or paragraph ends as
// a sentence so the voice pauses where the eye would. It stops after the last
// whole sentence within maxWords, and returns the words it kept.
func Speakable(md string, maxWords int) (string, int) {
	md = fence.ReplaceAllString(md, "\n")
	var parts []string
	for _, line := range strings.Split(md, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "|") {
			continue // a table row
		}
		line = image.ReplaceAllString(line, "")
		line = link.ReplaceAllString(line, "$1")
		line = bareURL.ReplaceAllString(line, "")
		line = citation.ReplaceAllString(line, "")
		line = html.ReplaceAllString(line, "")
		line = heading.ReplaceAllString(line, "")
		line = quote.ReplaceAllString(line, "")
		line = listMarker.ReplaceAllString(line, "")
		line = emphasis.ReplaceAllString(line, "")
		line = strings.TrimSpace(spaces.ReplaceAllString(line, " "))
		if line == "" {
			continue
		}
		// A line ending mid-sentence (a heading, a bullet) still ends a thought.
		if r := []rune(line); !unicode.IsPunct(r[len(r)-1]) || strings.ContainsRune(",;:-", r[len(r)-1]) {
			line = strings.TrimRight(line, ",;:- ") + "."
		}
		line = strings.ReplaceAll(line, " .", ".")
		parts = append(parts, line)
	}
	return capWords(strings.Join(parts, " "), maxWords)
}

func capWords(text string, maxWords int) (string, int) {
	if maxWords <= 0 {
		maxWords = MaxWords
	}
	if n := len(strings.Fields(text)); n <= maxWords {
		return text, n
	}
	var kept []string
	n := 0
	for _, s := range sentence.FindAllString(text, -1) {
		s = strings.TrimSpace(s)
		w := len(strings.Fields(s))
		if n+w > maxWords {
			break
		}
		kept = append(kept, s)
		n += w
	}
	if n == 0 {
		words := strings.Fields(text)[:maxWords]
		return strings.TrimRight(strings.Join(words, " "), ".,;:") + "…", maxWords
	}
	return strings.Join(kept, " "), n
}

// LeadMinWords is how much a lead must say before the rest can follow:
// enough to cover the rest's synthesis, short enough to start quickly.
const LeadMinWords = 8

// SplitLead splits speakable text after its first whole sentences that reach
// LeadMinWords, so the lead can be voiced and played while the rest is still
// being voiced. rest is empty when the lead is everything.
func SplitLead(text string) (lead, rest string) {
	words := 0
	for _, m := range sentence.FindAllStringIndex(text, -1) {
		words += len(strings.Fields(text[m[0]:m[1]]))
		if words >= LeadMinWords {
			return strings.TrimSpace(text[:m[1]]), strings.TrimSpace(text[m[1]:])
		}
	}
	return strings.TrimSpace(text), ""
}

package artifacts

import (
	"regexp"
	"strings"
	"unicode"
)

var (
	htmlCommentRE     = regexp.MustCompile(`(?s)<!--.*?-->`)
	obsidianEmbedRE   = regexp.MustCompile(`!\[\[[^\]]*\]\]`)
	markdownImageRE   = regexp.MustCompile(`!\[[^\]]*\]\([^)]*\)`)
	wikilinkRE        = regexp.MustCompile(`\[\[([^\]]+)\]\]`)
	markdownLinkRE    = regexp.MustCompile(`\[([^\]]+)\]\([^)]*\)`)
	taskCheckboxRE    = regexp.MustCompile(`^\s*[-*+]\s+\[[ xX]\]\s+`)
	orderedListMarkRE = regexp.MustCompile(`^\s*\d+[.)]\s+`)
	blockAnchorRE     = regexp.MustCompile(`\s+\^[A-Za-z0-9_-]+\s*$`)
)

// CountWords returns the number of prose words in a Markdown document.
// It ignores YAML frontmatter, fenced code blocks, HTML comments, embeds/images,
// link URLs/targets (keeping display text), task checkboxes, ordered list numbers,
// table dividers, and block anchors.
func CountWords(md string) int {
	if strings.TrimSpace(md) == "" {
		return 0
	}
	s := stripFrontmatter(md)
	s = htmlCommentRE.ReplaceAllString(s, " ")

	total := 0
	var fenceChar byte
	fenceLen := 0

	for _, rawLine := range strings.Split(s, "\n") {
		line := strings.TrimRight(rawLine, "\r")
		trimmed := strings.TrimLeft(line, " \t")

		if fenceChar != 0 {
			if isClosingFence(trimmed, fenceChar, fenceLen) {
				fenceChar = 0
				fenceLen = 0
			}
			continue
		}
		if ch, n := openingFence(trimmed); n >= 3 {
			fenceChar = ch
			fenceLen = n
			continue
		}
		if trimmed == "" || isTableSeparator(trimmed) {
			continue
		}

		cleaned := cleanMarkdownLine(line)
		total += countLineWords(cleaned)
	}
	return total
}

func stripFrontmatter(md string) string {
	norm := strings.ReplaceAll(md, "\r\n", "\n")
	if !strings.HasPrefix(norm, "---\n") {
		return md
	}
	rest := norm[4:]
	for i := 0; i < len(rest); {
		nl := strings.IndexByte(rest[i:], '\n')
		var line string
		var next int
		if nl == -1 {
			line = rest[i:]
			next = len(rest)
		} else {
			line = rest[i : i+nl]
			next = i + nl + 1
		}
		t := strings.TrimSpace(line)
		if t == "---" || t == "..." {
			return rest[next:]
		}
		i = next
	}
	return md
}

func openingFence(trimmed string) (byte, int) {
	if len(trimmed) < 3 || (trimmed[0] != '`' && trimmed[0] != '~') {
		return 0, 0
	}
	ch := trimmed[0]
	n := 0
	for n < len(trimmed) && trimmed[n] == ch {
		n++
	}
	// Backtick info strings cannot contain backticks per CommonMark.
	if ch == '`' && strings.IndexByte(trimmed[n:], '`') != -1 {
		return 0, 0
	}
	return ch, n
}

func isClosingFence(trimmed string, ch byte, minLen int) bool {
	n := 0
	for n < len(trimmed) && trimmed[n] == ch {
		n++
	}
	if n < minLen {
		return false
	}
	return strings.TrimSpace(trimmed[n:]) == ""
}

func isTableSeparator(trimmed string) bool {
	hasDash := false
	for i := 0; i < len(trimmed); i++ {
		switch trimmed[i] {
		case '|', ':', ' ', '\t':
		case '-':
			hasDash = true
		default:
			return false
		}
	}
	return hasDash
}

func cleanMarkdownLine(line string) string {
	line = taskCheckboxRE.ReplaceAllString(line, " ")
	line = orderedListMarkRE.ReplaceAllString(line, " ")
	line = blockAnchorRE.ReplaceAllString(line, "")
	line = obsidianEmbedRE.ReplaceAllString(line, " ")
	line = markdownImageRE.ReplaceAllString(line, " ")
	line = wikilinkRE.ReplaceAllStringFunc(line, func(match string) string {
		inner := match[2 : len(match)-2]
		if pipe := strings.IndexByte(inner, '|'); pipe != -1 {
			return inner[pipe+1:]
		}
		if hash := strings.IndexByte(inner, '#'); hash != -1 {
			if hash == 0 {
				return strings.TrimPrefix(inner[1:], "^")
			}
			return inner[:hash]
		}
		return inner
	})
	line = markdownLinkRE.ReplaceAllString(line, "$1")
	return line
}

func isCJKIdeograph(r rune) bool {
	return unicode.Is(unicode.Han, r) || unicode.Is(unicode.Hiragana, r) || unicode.Is(unicode.Katakana, r)
}

func isWordRune(r rune) bool {
	return (unicode.IsLetter(r) || unicode.IsDigit(r)) && !isCJKIdeograph(r)
}

func countLineWords(s string) int {
	runes := []rune(s)
	words := 0
	inWord := false
	for i, r := range runes {
		if isCJKIdeograph(r) {
			if inWord {
				words++
				inWord = false
			}
			words++
			continue
		}
		if isWordRune(r) {
			inWord = true
			continue
		}
		if inWord && (r == '\'' || r == '’' || r == '-') && i+1 < len(runes) && isWordRune(runes[i+1]) {
			continue
		}
		if inWord {
			words++
			inWord = false
		}
	}
	if inWord {
		words++
	}
	return words
}

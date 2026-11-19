package harness

import (
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// AgentsSectionPath is where a turn's generated instructions are written; the
// turn wrapper puts them at the top of AGENTS.md, above the repository's own.
const AgentsSectionPath = ".lazyagents/agents-section.md"

// agy caps every rule file (AGENTS.md included) at 24,000 bytes and cuts the
// rest (agy 1.5.9 docs/rules.md; TestAgyProbe/instructions). A chat's section
// alone can be larger, and the repository's AGENTS.md comes after it, so agy
// lost the repository's file on every turn. Always-on rule files under
// .agents/rules are each capped separately, so for agy the section is split
// across them and AGENTS.md keeps only the repository's file.
const (
	agyRulesDir     = ".agents/rules"
	agyRuleSlots    = 6
	agyRuleMaxBytes = 22000 // under agy's 24,000-byte cap, with the frontmatter
	agyRuleHeader   = "---\ntrigger: always_on\n---\n\n"
)

// InstructionFiles places a turn's generated instructions for its harness.
// exclude lists workspace paths the turn wrapper keeps out of git.
func InstructionFiles(harnessName string, section []byte) (files map[string][]byte, exclude []string) {
	if harnessName != agentdef.HarnessAntigravity {
		return map[string][]byte{AgentsSectionPath: section}, nil
	}
	files = map[string][]byte{AgentsSectionPath: nil}
	chunks := splitRule(string(section), agyRuleMaxBytes)
	if len(chunks) > agyRuleSlots {
		// Past ~130 KB agy truncates the last file rather than losing it.
		chunks = append(chunks[:agyRuleSlots-1], strings.Join(chunks[agyRuleSlots-1:], ""))
	}
	// Every slot is written each turn, so a shorter section never leaves a
	// stale chunk from an earlier turn in the chat's workspace.
	for i := range agyRuleSlots {
		path := fmt.Sprintf("%s/vesper-%02d.md", agyRulesDir, i+1)
		body := ""
		if i < len(chunks) {
			body = chunks[i]
		}
		files[path] = []byte(agyRuleHeader + body)
		exclude = append(exclude, "/"+path)
	}
	return files, exclude
}

// splitRule cuts text into pieces of at most max bytes, at "## " headings
// where it can and at line ends where a section is longer than max.
func splitRule(text string, max int) []string {
	var out []string
	var cur strings.Builder
	flush := func() {
		if cur.Len() > 0 {
			out = append(out, cur.String())
			cur.Reset()
		}
	}
	for _, block := range splitBefore(text, "\n## ") {
		if cur.Len()+len(block) <= max {
			cur.WriteString(block)
			continue
		}
		flush()
		for len(block) > max {
			cut := strings.LastIndexByte(block[:max], '\n') + 1
			if cut == 0 { // one line longer than max: cut on a character boundary
				for cut = max; cut > 0 && !utf8.RuneStart(block[cut]); cut-- {
				}
				if cut == 0 {
					cut = max
				}
			}
			out = append(out, block[:cut])
			block = block[cut:]
		}
		cur.WriteString(block)
	}
	flush()
	return out
}

// splitBefore splits s before each occurrence of sep, keeping sep with the
// piece it starts.
func splitBefore(s, sep string) []string {
	var out []string
	for s != "" {
		i := strings.Index(s[1:], sep)
		if i < 0 {
			return append(out, s)
		}
		out = append(out, s[:i+1])
		s = s[i+1:]
	}
	return out
}

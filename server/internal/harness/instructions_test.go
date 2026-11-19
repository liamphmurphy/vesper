package harness

import (
	"fmt"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

func TestInstructionFiles(t *testing.T) {
	section := []byte("# Vesper chat\n\nhello\n")
	for _, h := range []string{agentdef.HarnessClaudeCode, agentdef.HarnessCodex} {
		files, exclude := InstructionFiles(h, section)
		if len(files) != 1 || string(files[AgentsSectionPath]) != string(section) || exclude != nil {
			t.Errorf("%s: %v %v", h, files, exclude)
		}
	}

	// A section bigger than agy's per-file cap, with a heading-free run longer
	// than a chunk and multi-byte text at the cut.
	var b strings.Builder
	b.WriteString("# Vesper chat\n")
	for i := range 40 {
		fmt.Fprintf(&b, "\n## Section %d\n\n%s\n", i, strings.Repeat("Plenty of guidance — détaillée. ", 40))
	}
	b.WriteString("\n## Wall\n\n" + strings.Repeat("é", 12000) + "\n")
	big := b.String()
	files, exclude := InstructionFiles(agentdef.HarnessAntigravity, []byte(big))
	if string(files[AgentsSectionPath]) != agyRulesPointer {
		t.Fatalf("agy's AGENTS.md keeps only a pointer and the repository's file: %q", files[AgentsSectionPath])
	}
	var joined strings.Builder
	for i := 1; i <= agyRuleSlots; i++ {
		path := fmt.Sprintf(".agents/rules/vesper-%02d.md", i)
		body, ok := files[path]
		if !ok || !strings.HasPrefix(string(body), agyRuleHeader) || len(body) > 24000 {
			t.Fatalf("%s: present=%v %d bytes", path, ok, len(body))
		}
		if !strings.Contains(strings.Join(exclude, " "), "/"+path) {
			t.Errorf("%s isn't excluded from git", path)
		}
		joined.WriteString(strings.TrimPrefix(string(body), agyRuleHeader))
	}
	if joined.String() != big {
		t.Fatal("the rule files don't add up to the section")
	}
	// Each chunk starts at a heading where the text allows it.
	if body := string(files[".agents/rules/vesper-02.md"]); !strings.HasPrefix(strings.TrimPrefix(body, agyRuleHeader), "\n## ") {
		t.Errorf("second chunk doesn't start at a heading: %.80q", body)
	}
	// Past six slots the rest goes to the last one, which agy truncates,
	// rather than being dropped.
	huge := strings.Repeat("\n## Part\n\n"+strings.Repeat("x", 20000), 8)
	files, _ = InstructionFiles(agentdef.HarnessAntigravity, []byte(huge))
	joined.Reset()
	for i := 1; i <= agyRuleSlots; i++ {
		joined.WriteString(strings.TrimPrefix(string(files[fmt.Sprintf(".agents/rules/vesper-%02d.md", i)]), agyRuleHeader))
	}
	if joined.String() != huge || len(files[".agents/rules/vesper-05.md"]) > 24000 {
		t.Fatal("overflow lost text or overfilled an earlier slot")
	}
	// A short section still writes every slot, so no stale chunk survives.
	files, _ = InstructionFiles(agentdef.HarnessAntigravity, section)
	if string(files[".agents/rules/vesper-01.md"]) != agyRuleHeader+string(section) || string(files[".agents/rules/vesper-06.md"]) != agyRuleHeader {
		t.Fatalf("short section: %q / %q", files[".agents/rules/vesper-01.md"], files[".agents/rules/vesper-06.md"])
	}
}

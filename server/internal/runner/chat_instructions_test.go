package runner_test

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/runs"
)

// A chat's feature playbooks reach every harness as skills, not inline, and
// its instructions are placed so no harness truncates them or the
// repository's AGENTS.md after them: Codex is given room for both, and agy
// (24,000 bytes per rule file) reads Vesper's section from always-on rule
// files instead of AGENTS.md (LAZYAGENTS-253).
func TestChatInstructionsFitEveryHarness(t *testing.T) {
	for _, c := range []struct{ harness, model, skills string }{
		{agentdef.HarnessClaudeCode, "opus-5.5", ".claude/skills"},
		{agentdef.HarnessCodex, "gpt-5.5", ".agents/skills"},
		{agentdef.HarnessAntigravity, "gemini-3.8-flash", ".agents/skills"},
	} {
		t.Run(c.harness, func(t *testing.T) {
			e := setup(t)
			t.Setenv("FAKE_HARNESS_MODE", "chat")
			if err := e.setOverride(agentdef.Override{Harness: c.harness, Model: c.model}); err != nil {
				t.Fatal(err)
			}
			p := e.persona("Coder", true, false)
			chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Title: "Instructions", PersonaID: &p.ID})
			if err != nil {
				t.Fatal(err)
			}
			e.selectChat(chat.ID, c.harness, c.model)
			e.say(chat.ID, "hi")
			if got := e.chatRun(chat.ID).Harness; got != c.harness {
				t.Fatalf("chat ran on %s", got)
			}
			ws := e.runner.Backend.WorkspaceDir(e.chatRun(chat.ID).ID.String())
			read := func(rel string) string {
				t.Helper()
				b, err := os.ReadFile(filepath.Join(ws, rel))
				if err != nil {
					t.Fatal(err)
				}
				return string(b)
			}

			// The section as the harness reads it.
			var section string
			if c.harness == agentdef.HarnessAntigravity {
				if md := read("AGENTS.md"); strings.Contains(md, "# Vesper chat") {
					t.Fatalf("agy reads Vesper's section from rules, not AGENTS.md:\n%s", md)
				}
				for i := 1; i <= 6; i++ {
					rule := read(fmt.Sprintf(".agents/rules/vesper-%02d.md", i))
					if len(rule) > 24000 || !strings.HasPrefix(rule, "---\ntrigger: always_on\n---\n") {
						t.Fatalf("rule %d is %d bytes or not always on:\n%.200s", i, len(rule), rule)
					}
					section += strings.TrimPrefix(rule, "---\ntrigger: always_on\n---\n\n")
				}
				if !strings.Contains(read(harness.SkillsExcludeFile), "/.agents/rules/vesper-01.md") {
					t.Error("Vesper's rule files must stay out of git")
				}
			} else {
				section = read("AGENTS.md")
			}
			if c.harness == agentdef.HarnessCodex && len(section) > harness.CodexProjectDocMaxBytes/2 {
				t.Errorf("a plain chat's section is %d bytes, over half of Codex's %d-byte budget", len(section), harness.CodexProjectDocMaxBytes)
			}
			if !strings.Contains(section, "# Vesper chat") || !strings.Contains(section, "## Working in code") {
				t.Fatalf("core instructions missing:\n%s", section)
			}
			for _, moved := range []string{"## Videos", "## Audio", "## Playground", "## Canvases", "## Custom Apps", "## PDFs", "## SVG images"} {
				if strings.Contains(section, moved) {
					t.Errorf("%q is a skill now, not inline", moved)
				}
			}
			if strings.Contains(section, ".lazyagents/skills/") {
				t.Error("every harness discovers its skills natively: no index pointing at .lazyagents/skills")
			}
			for _, skill := range []string{"vesper-pdfs", "vesper-canvases", "vesper-custom-apps", "vesper-videos", "vesper-audio", "vesper-playground"} {
				if body := read(filepath.Join(c.skills, skill, "SKILL.md")); !strings.Contains(body, "description: ") {
					t.Errorf("%s has no description:\n%s", skill, body)
				}
			}
		})
	}
}

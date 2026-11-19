package harness

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// Skills reach an agent as files in the workspace. Claude Code loads
// .claude/skills/<name>/SKILL.md natively (the description decides when);
// Codex loads .agents/skills/<name>/SKILL.md natively; other harnesses
// get the same file under .lazyagents/skills/ plus an index
// in AGENTS.md telling them when to read it.
const (
	claudeSkillsDir = ".claude/skills"
	plainSkillsDir  = ".lazyagents/skills"
	// SkillsExcludeFile lists workspace paths the turn wrapper adds to
	// .git/info/exclude so skills are never committed.
	SkillsExcludeFile = ".lazyagents/skills-exclude.txt"
)

// RenderSkill is a SKILL.md: YAML frontmatter, then the body.
func RenderSkill(s agentdef.Skill) []byte {
	name, _ := json.Marshal(s.Name) // JSON strings are valid YAML
	desc, _ := json.Marshal(s.Description)
	return []byte(fmt.Sprintf("---\nname: %s\ndescription: %s\n---\n\n%s\n", name, desc, s.Body))
}

// SkillFiles returns the workspace files for a resolved definition's skills,
// in Claude Code's skill directory and excluded from git.
func SkillFiles(skills []agentdef.Skill) map[string][]byte {
	files := map[string][]byte{}
	if len(skills) == 0 {
		return files
	}
	var exclude []string
	for _, s := range skills {
		files[claudeSkillsDir+"/"+s.Name+"/SKILL.md"] = RenderSkill(s)
		exclude = append(exclude, "/"+claudeSkillsDir+"/"+s.Name+"/")
	}
	sort.Strings(exclude)
	files[SkillsExcludeFile] = []byte(strings.Join(exclude, "\n") + "\n")
	return files
}

// nativeSkills reports whether a harness lists the skills SkillFilesFor
// installs by itself (Claude Code .claude/skills, Codex 0.169 and agy 1.5.8
// .agents/skills). An index in AGENTS.md would point the others at
// .lazyagents/skills, which SkillFilesFor writes for none of these.
func nativeSkills(name string) bool {
	return name == agentdef.HarnessClaudeCode || name == agentdef.HarnessCodex || name == agentdef.HarnessAntigravity
}

// skillsIndex is the AGENTS.md section for harnesses without native skills.
func skillsIndex(skills []agentdef.Skill) string {
	var b strings.Builder
	b.WriteString("## Skills\n\nThese are playbooks for specific situations. When a task matches a description, read the file and follow it before you start.\n\n")
	for _, s := range skills {
		fmt.Fprintf(&b, "- `%s/%s/SKILL.md`: %s\n", plainSkillsDir, s.Name, s.Description)
	}
	b.WriteString("\n")
	return b.String()
}

// SkillFilesFor installs native skills for the selected harness.
func SkillFilesFor(skills []agentdef.Skill, name string) map[string][]byte {
	files := SkillFiles(skills)
	if name != agentdef.HarnessCodex && name != agentdef.HarnessAntigravity { // both discover .agents/skills
		return files
	}
	out := map[string][]byte{}
	for p, body := range files {
		if p == SkillsExcludeFile {
			body = []byte(strings.ReplaceAll(string(body), "/.claude/skills/", "/.agents/skills/"))
		}
		out[strings.ReplaceAll(p, ".claude/skills", ".agents/skills")] = body
	}
	return out
}

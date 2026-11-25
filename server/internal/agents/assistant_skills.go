package agents

import (
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// Chat playbooks for features a turn rarely uses go to the harness as skills,
// not into AGENTS.md: every harness (Claude Code, Codex, agy) lists a skill's
// name and description and loads its body only when the task matches. Inline,
// they made a chat's AGENTS.md several times bigger than agy's 24,000-byte
// rule cap and Codex's default project_doc_max_bytes, so the repository's own
// AGENTS.md at the end was cut off (LAZYAGENTS-253). The descriptions are what
// a model sees when deciding, so each names the tools and the moment to read it.
var (
	SkillVideos = assistantSkill("vesper-videos",
		"Read before making a video for the person (start_video, update_video, finish_video, fail_video): how to render it in the workspace, the stills check, progress files and the video card.",
		assistantVideoSection)
	SkillAudio = assistantSkill("vesper-audio",
		"Read before making music or a sound for the person (start_audio, update_audio, finish_audio, fail_audio): how to render it with code, measure it and hand it to the audio card.",
		assistantAudioSection)
	SkillPlayground = assistantSkill("vesper-playground",
		"Read before letting the person try a web UI or API you built (start_playground, playground_status, stop_playground, set_playground_openapi) or mapping an app's API: processes, routes, the playground card and checking your work in it.",
		assistantPlaygroundSection)
	SkillCanvases = assistantSkill("vesper-canvases",
		"Read before creating or changing a canvas, design or mockup (canvas_create, canvas_patch, canvas_comment, design_create, design_patch, create_mockup): drafts the person revises with you, mockups for them to approve, wireframes, flows and diagrams, and answering their comments.",
		AssistantCanvasSection)
	SkillCustomApps = assistantSkill("vesper-custom-apps",
		"Read before building, changing or querying a Custom App, a persistent app at /apps/<slug> with its own SQLite database (list_custom_apps, get_custom_app, create_custom_app, update_custom_app, custom_app_sql, delete_custom_app).",
		AssistantCustomAppsSection)
	SkillPDFs = assistantSkill("vesper-pdfs",
		"Read before making a PDF with render_pdf: page setup, offline HTML and CSS, embedding Knowledge and Library images, visual QA of previews, the pdf card, and placing PDFs in Knowledge.",
		AssistantPDFSection)
	SkillWorkflowEditing = assistantSkill("vesper-workflow-editing",
		"Read before building or changing one of the person's workflows (list_workflows, read_workflow, propose_workflow_edit): node types, references between steps, checks, gates and image steps.",
		AssistantWorkflowBuildSection)
	SkillSVGImages = assistantSkill("vesper-svg-images",
		"Read before drawing any SVG in a reply (svg-image or svg-steps blocks, an SVG canvas): required structure, the theme palette, and layout rules for diagrams.",
		AssistantSVGSection)
	SkillPersonaCharacter = assistantSkill("vesper-persona-character",
		"Read before designing or iterating on an animated 64x64 SVG character for a persona (propose_persona_character, or character_svg on propose_persona): viewBox rules, currentColor, action-state animations (idle, thinking, reading, coding, creating, needs-you), and layer visibility.",
		AssistantPersonaCharacterSection)
)

// assistantSkill is a playbook as a skill. The body keeps its section heading.
func assistantSkill(name, description, section string) agentdef.Skill {
	return agentdef.Skill{Name: name, Description: description, Body: strings.TrimSpace(section)}
}

// AssistantSkills are the playbooks a chat gets as skills: coding is whether
// it may write and run code, workflows whether its persona may build
// workflows, svg whether it may draw SVG images.
func AssistantSkills(coding, workflows, svg bool) []agentdef.Skill {
	out := []agentdef.Skill{SkillCanvases, SkillCustomApps, SkillPDFs, SkillPersonaCharacter}
	if coding {
		out = append(out, SkillVideos, SkillAudio, SkillPlayground)
	}
	if workflows {
		out = append(out, SkillWorkflowEditing)
	}
	if svg {
		out = append(out, SkillSVGImages)
	}
	return out
}

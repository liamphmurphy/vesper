package agentapi

import (
	"slices"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A renamed tool must not silently drop out of a profile.
func TestProfileToolsExist(t *testing.T) {
	for name, list := range map[string][]string{"chat": chatTools, "planning": planningTools, "subagent": subagentTools, "lead hidden": leadHidden} {
		for _, n := range list {
			if _, ok := ByName[n]; !ok {
				t.Errorf("%s profile lists %q, which isn't in Tools", name, n)
			}
		}
	}
}

// Board writes are lead-only (ADR Kanban board, Decision 6): chat, planning
// and delegated runs are neither served nor allowed them.
func TestBoardToolsLeadOnly(t *testing.T) {
	for _, tool := range []string{"estimate_ticket", "check_epic_criterion", "recheck_review"} {
		if _, ok := ByName[tool]; !ok {
			t.Fatalf("%s isn't in Tools", tool)
		}
		for name, list := range map[string][]string{"chat": chatTools, "planning": planningTools, "subagent": subagentTools, "lead hidden": leadHidden} {
			if slices.Contains(list, tool) {
				t.Errorf("%s profile allows %s", name, tool)
			}
		}
		for _, p := range []string{profileChat, profilePlanning, profileSubagent} {
			if slices.ContainsFunc(profileTools(p), func(tl Tool) bool { return tl.Name == tool }) {
				t.Errorf("%s profile serves %s", p, tool)
			}
		}
		if !slices.ContainsFunc(profileTools(profileLead), func(tl Tool) bool { return tl.Name == tool }) {
			t.Errorf("lead profile doesn't serve %s", tool)
		}
	}
	// The sub agent profile names the role and points at the brief and AGENTS.md,
	// which carries the lifecycle rules.
	if s := profileInstructions[profileSubagent]; strings.Contains(s, "claim_ticket") || strings.Contains(s, "complete_run") || !strings.Contains(s, "AGENTS.md") {
		t.Errorf("sub agent profile text restates rules: %q", s)
	}
	// get_ticket (with the estimate and epic payload) stays on every profile.
	for name, list := range map[string][]string{"chat": chatTools, "planning": planningTools, "subagent": subagentTools} {
		if !slices.Contains(list, "get_ticket") {
			t.Errorf("%s profile lost get_ticket", name)
		}
	}
}

// asideRefused are the chat tools that change something. Every chat tool is
// either one of these or readable in an aside, so a new chat tool has to be
// classified before an aside can be given it.
var asideRefused = []string{"librarian_pass", "daily_note", "import_vault", "patch_page", "set_properties", "move_page", "move_folder", "delete_page", "delete_folder", "restore_page_version", "file_capture", "attach_file", "withdraw_suggestion", "set_page_controls", "attach_chat_to_page", "promote_canvas", "confirm_import", "cancel_import", "undo_import", "create_page", "capture_note", "create_ticket", "update_ticket", "comment_ticket", "update_ticket_blockers", "create_epic", "update_epic", "reply_to_run",
	"write_note", "save_memory", "update_memory", "forget_memory", "use_repository", "request_push", "set_chat_title", "generate_image", "start_video", "update_video", "finish_video", "fail_video", "start_audio", "update_audio", "finish_audio", "fail_audio", "save_file",
	"start_playground", "playground_status", "stop_playground", "set_playground_openapi", "propose_persona", "save_link",
	"submit_research_report", "canvas_create", "canvas_patch", "canvas_comment", "canvas_reply", "design_list", "design_outline", "design_read", "design_render", "design_patch", "design_import", "design_comments", "design_comment", "design_reply", "design_create", "design_components", "design_tokens", "design_inspect", "design_link_ticket", "propose_workflow_edit", "propose_connector", "propose_secret",
	"create_space", "create_scheduled_task", "update_scheduled_task", "delete_scheduled_task", "create_learning_module"}

func TestAsideToolsOnlyRead(t *testing.T) {
	for _, n := range asideTools {
		if !slices.Contains(chatTools, n) {
			t.Errorf("aside tool %q isn't a chat tool", n)
		}
		if slices.Contains(asideRefused, n) {
			t.Errorf("aside tool %q changes something", n)
		}
	}
	for _, n := range chatTools {
		if !slices.Contains(asideTools, n) && !slices.Contains(asideRefused, n) {
			t.Errorf("chat tool %q is neither readable in an aside nor refused there", n)
		}
	}
}

// A chat run whose spec marks an aside gets the aside's tools; any other chat
// run keeps the chat's, and an unreadable spec fails closed.
func TestAsideProfile(t *testing.T) {
	run := func(spec string) store.Run { return store.Run{Purpose: "chat", ResolvedSpec: []byte(spec)} }
	if got := profileFor(run(`{"harness_options":{"aside":"true"}}`)); got != profileAside {
		t.Fatalf("aside run profile %q", got)
	}
	if got := profileFor(run(`{"harness_options":{"sandbox":"read-only"}}`)); got != profileChat {
		t.Fatalf("chat run profile %q", got)
	}
	if got := profileFor(run(`not json`)); got != profileAside {
		t.Fatalf("unreadable spec profile %q", got)
	}
	for _, tl := range profileTools(profileAside) {
		if !slices.Contains(asideTools, tl.Name) {
			t.Errorf("aside profile serves %s", tl.Name)
		}
	}
}

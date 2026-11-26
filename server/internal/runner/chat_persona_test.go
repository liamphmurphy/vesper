package runner_test

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// The persona is read from the chat on every turn: an edit shows on the next
// turn of the same segment, a harness switch's fresh segment keeps it, and a
// deleted persona falls back to the built-in Assistant (no persona section).
func TestChatPersonaAppliesPerTurn(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	if err := e.setOverride(agentdef.Override{Harness: agentdef.HarnessClaudeCode, Model: "opus-5.5"}); err != nil {
		t.Fatal(err)
	}
	ps := &personas.Service{Pool: e.pool}
	o := personas.Owner{WorkspaceID: e.ws, UserID: e.me.ID}
	tone, ins := "formal", "Sign off as Coach."
	p, err := ps.Create(e.ctx, o, personas.NewInput{Name: "Writing coach", Tone: &tone, Instructions: &ins})
	if err != nil {
		t.Fatal(err)
	}
	// The persona's own memory loads in its own section, never in the person's index.
	mem := memory.New(store.New(e.pool))
	mo := memory.Owner{WorkspaceID: e.ws, UserID: e.me.ID}
	if _, err := mem.Save(e.ctx, mo.Persona(p.ID), memory.Input{Title: "Rowing history", Body: "Taught rowing for ten years."}, memory.Source{Label: "manual"}); err != nil {
		t.Fatal(err)
	}
	if _, err := mem.Save(e.ctx, mo.Persona(p.ID), memory.Input{Title: "First essay together", Summary: "We fixed the intro", Type: memory.TypeMoment}, memory.Source{Label: "manual"}); err != nil {
		t.Fatal(err)
	}
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Title: "Persona chat", PersonaID: &p.ID, Message: &runs.ChatMessageInput{Body: "Message one"}})
	if err != nil {
		t.Fatal(err)
	}
	e.until("first reply", func() bool { return e.chat(chat.ID).State == "idle" })
	agentsMD := func() string {
		t.Helper()
		md, err := os.ReadFile(filepath.Join(e.runner.Backend.WorkspaceDir(e.chatRun(chat.ID).ID.String()), "AGENTS.md"))
		if err != nil {
			t.Fatal(err)
		}
		return string(md)
	}
	md := agentsMD()
	for _, want := range []string{"# Vesper chat", "## Persona", "In this conversation you are Writing coach.", "Write in a formal, professional register", "Sign off as Coach."} {
		if !strings.Contains(md, want) {
			t.Errorf("first turn missing %q in %s", want, md)
		}
	}
	for _, bad := range []string{"## Projects", "create_ticket", "create_epic", "list_projects", "ticket or epic"} {
		if strings.Contains(md, bad) {
			t.Errorf("first turn still contains stale Work text %q in %s", bad, md)
		}
	}
	if strings.Index(md, "Answer directly") > strings.Index(md, "## Persona") {
		t.Errorf("persona precedes the chat rules:\n%s", md)
	}
	own := strings.Index(md, "## Your own memory (Writing coach)")
	if own < 0 || !strings.Contains(md[own:], "Taught rowing for ten years.") || !strings.Contains(md[own:], "First essay together: We fixed the intro") {
		t.Errorf("persona memory section missing:\n%s", md)
	}
	if idx := md[strings.Index(md, "### Memory index"):strings.Index(md, "## Instructions")]; strings.Contains(idx, "Rowing history") {
		t.Errorf("persona memory in the person's index:\n%s", idx)
	}

	// An edit applies to the next turn of the same, resumed segment.
	first := e.chatRun(chat.ID)
	name, edited := "Mentor", "Sign off as Mentor."
	if p, err = ps.Update(e.ctx, o, p.ID, personas.Patch{Revision: p.Revision, Name: &name, Instructions: &edited}); err != nil {
		t.Fatal(err)
	}
	if reply := e.say(chat.ID, "Message two"); !strings.Contains(reply.BodyMd, "resumed=true") || e.chatRun(chat.ID).ID != first.ID {
		t.Fatalf("second turn did not resume: %s", reply.BodyMd)
	}
	if md = agentsMD(); !strings.Contains(md, "In this conversation you are Mentor.") || !strings.Contains(md, "Sign off as Mentor.") || strings.Contains(md, "Coach") {
		t.Fatalf("edit not applied on the next turn:\n%s", md)
	}

	// A harness switch hands the transcript to a fresh segment with the same persona.
	e.selectChat(chat.ID, agentdef.HarnessCodex, "gpt-5.5")
	reply := e.say(chat.ID, "Message three")
	if second := e.chatRun(chat.ID); second.ID == first.ID || !strings.Contains(reply.BodyMd, "different harness or model") {
		t.Fatalf("no handoff: run %v reply %s", second.ID, reply.BodyMd)
	}
	if md = agentsMD(); !strings.Contains(md, "In this conversation you are Mentor.") || !strings.Contains(md, "Sign off as Mentor.") {
		t.Fatalf("handoff lost the persona:\n%s", md)
	}

	// Deleting the persona nulls the chat's persona: the built-in Assistant from the next turn.
	if _, err := ps.Delete(e.ctx, o, p.ID, nil); err != nil {
		t.Fatal(err)
	}
	e.say(chat.ID, "Message four")
	if md = agentsMD(); strings.Contains(md, "## Persona") || strings.Contains(md, "Mentor") {
		t.Fatalf("deleted persona still rendered:\n%s", md)
	}
}

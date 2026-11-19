package agents_test

import (
	"context"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// The Personal Assistant is created once per workspace, sidesteps a taken
// handle, and stays out of the roster and ticket work.
func TestEnsureAssistant(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &agents.Service{Pool: pool}
	// Someone already uses @assistant for a ticket agent.
	if _, err := svc.Create(ctx, ws, me.ID, "assistant", agents.Identity{Name: "Helper"}, nil); err != nil {
		t.Fatal(err)
	}

	a, err := agents.EnsureAssistant(ctx, q, ws)
	if err != nil || a.Kind != agents.KindAssistant || a.Handle != "personal-assistant" || a.CurrentDefinitionVersionID == nil {
		t.Fatalf("assistant = %+v, %v", a, err)
	}
	again, err := agents.EnsureAssistant(ctx, q, ws)
	if err != nil || again.ID != a.ID {
		t.Fatalf("second call = %+v, %v", again, err)
	}
	spec, _, err := agents.CurrentSpec(ctx, q, a)
	if err != nil || spec.Instructions != agents.AssistantInstructions || len(spec.Scopes) != 0 {
		t.Fatalf("assistant spec = %+v, %v", spec, err)
	}

	roster, err := q.ListAgents(ctx, ws)
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range roster {
		if r.ID == a.ID {
			t.Fatal("the assistant is in the roster")
		}
	}
	if _, err := (&tracker.Service{Pool: pool}).Create(ctx, ws, tracker.UserActor(me.ID), tracker.NewTicket{ProjectKey: "PAY", Title: "For the assistant", AssigneeAgentID: &a.ID}); err == nil || !strings.Contains(err.Error(), "Personal Assistant") {
		t.Fatal("assigned a ticket to the assistant")
	}
	if _, err := svc.SaveDefinition(ctx, ws, me.ID, a.Handle, agents.Identity{Name: "PA", Kind: agents.KindMain}, spec, "Make it main"); err == nil || !strings.Contains(err.Error(), "managed by Vesper") {
		t.Fatal("edited the assistant into a main agent")
	}
	if err := svc.Delete(ctx, ws, a.Handle); err == nil || !strings.Contains(err.Error(), "can't be deleted") {
		t.Fatal("deleted the assistant")
	}
}

// Every persona is told how to write interactive apps, whatever its capabilities.
func TestAssistantInstructionsInteractiveApps(t *testing.T) {
	for _, ins := range []string{agents.AssistantInstructions, agents.AssistantInstructionsFor(true, true, []string{"feat/x"}, true, false)} {
		if !strings.Contains(ins, "## Interactive apps") || !strings.Contains(ins, "fenced code block tagged app") || !strings.Contains(ins, "aren't just for coding") {
			t.Fatalf("instructions lack the interactive apps section:\n%s", ins)
		}
	}
}

// The canvas section says when a mockup is a single svg canvas and when it is
// a design, so personas don't have to guess between the two tools.
func TestAssistantCanvasSectionRoutesMockupsAndDesigns(t *testing.T) {
	for _, want := range []string{"Mockup or design?", "design_create", "canvas_create with kind svg", "start with a single svg canvas"} {
		if !strings.Contains(agents.AssistantCanvasSection, want) {
			t.Errorf("canvas section lacks %q", want)
		}
	}
}

// Memory guidance keeps technical decisions and PR/branch logs out of personal
// memory and points them at Knowledge instead, without contradicting Knowledge
// with a blanket ban on writing the wiki.
func TestAssistantInstructionsMemoryVsKnowledge(t *testing.T) {
	for _, ins := range []string{agents.AssistantInstructions, agents.AssistantInstructionsFor(true, true, []string{"feat/x"}, true, false)} {
		for _, want := range []string{"technical or architecture decisions", "durable project knowledge belongs in Knowledge", "PR/branch/implementation logs"} {
			if !strings.Contains(ins, want) {
				t.Errorf("instructions lack %q", want)
			}
		}
		if strings.Contains(ins, "write the shared wiki") {
			t.Errorf("instructions still forbid writing the shared wiki")
		}
	}
}

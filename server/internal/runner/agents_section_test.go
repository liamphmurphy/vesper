package runner

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// Planning runs render exactly as before and never load a persona: they get a nil Queries,
// so any persona (or memory) read panics.
func TestAgentsSectionPlanningLoadsNoPersona(t *testing.T) {
	spec := agentdef.Resolved{Harness: agentdef.HarnessClaudeCode, Model: "opus-5.5", Instructions: "Be careful."}
	paths := []string{".lazyagents/context/adr.md"}
	got, _, _, err := agentsSection(context.Background(), nil, runCtx{run: store.Run{Purpose: "planning"}, spec: spec}, append([]string{}, paths...))
	if want := "Be careful.\nRead these context files first:\n.lazyagents/context/adr.md"; err != nil || string(got) != want {
		t.Fatalf("err=%v\n%s", err, got)
	}
}

// A ticket run (and a run it delegates to) speaks in its persona's voice, after the work
// brief, and is told which memory it may search; it never loads the persona's memory or the
// chat persona block. A work record without a persona renders exactly as before.
func TestAgentsSectionTicketRunVoice(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	var ws, user, withPersona, bare uuid.UUID
	scan := func(dst *uuid.UUID, sql string, args ...any) {
		t.Helper()
		if err := pool.QueryRow(ctx, sql, args...).Scan(dst); err != nil {
			t.Fatal(err)
		}
	}
	scan(&ws, `INSERT INTO workspaces(name,slug) VALUES('W','w') RETURNING id`)
	scan(&user, `INSERT INTO users(workspace_id,name,email,initials,password_hash) VALUES($1,'Ann','ann@example.com','A','x') RETURNING id`, ws)
	scan(&withPersona, `INSERT INTO agents(workspace_id,name,handle) VALUES($1,'Tech Lead','tech-lead') RETURNING id`, ws)
	scan(&bare, `INSERT INTO agents(workspace_id,name,handle) VALUES($1,'Bare','bare') RETURNING id`, ws)
	if _, err := pool.Exec(ctx, `INSERT INTO personas(id,workspace_id,user_id,name,tone,custom_instructions) VALUES($1,$2,$3,'Tech Lead','concise','Say what you verified.')`, withPersona, ws, user); err != nil {
		t.Fatal(err)
	}
	if _, err := memory.New(q).Save(ctx, memory.Owner{WorkspaceID: ws, UserID: user}.Persona(withPersona), memory.Input{Title: "Secret moment"}, memory.Source{Label: "manual"}); err != nil {
		t.Fatal(err)
	}
	spec := agentdef.Resolved{Harness: agentdef.HarnessClaudeCode, Model: "opus-5.5", Instructions: "Be careful.",
		Scopes: []agentdef.ResolvedScope{{Scope: "repo:write", Mode: agentdef.Allowed}}}
	paths := []string{".lazyagents/context/adr.md"}
	parent := uuid.New()
	section := func(agent uuid.UUID, parentRun *uuid.UUID) string {
		t.Helper()
		got, _, _, err := agentsSection(ctx, q, runCtx{run: store.Run{Purpose: "ticket", WorkspaceID: ws, AgentID: agent, ParentRunID: parentRun}, ticket: store.Ticket{Key: "PAY-1"}, spec: spec}, append([]string{}, paths...))
		if err != nil {
			t.Fatal(err)
		}
		return string(got)
	}
	if got := section(bare, nil); got != string(harness.AgentsMD("", spec, paths, "PAY-1")) {
		t.Fatalf("a work record without a persona changed:\n%s", got)
	}
	if got := section(bare, &parent); got != string(harness.SubagentAgentsMD("", spec, paths, "PAY-1")) {
		t.Fatalf("a delegated run without a persona changed:\n%s", got)
	}
	for _, p := range []*uuid.UUID{nil, &parent} {
		got := section(withPersona, p)
		brief, voice := strings.Index(got, "## Instructions"), strings.Index(got, "## Voice")
		if brief < 0 || voice < brief || !strings.Contains(got, "You are Tech Lead") || !strings.Contains(got, "Keep replies short") ||
			!strings.Contains(got, "Say what you verified.") || !strings.Contains(got, "project and work notes") {
			t.Fatalf("persona run (delegated=%v) lacks its voice after the brief:\n%s", p != nil, got)
		}
		if strings.Contains(got, "Secret moment") || strings.Contains(got, "## Persona") || strings.Contains(got, "In this conversation you are") {
			t.Fatalf("persona run loaded chat persona content or memory:\n%s", got)
		}
	}
}

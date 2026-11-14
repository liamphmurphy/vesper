// Package agentapi is the Agent API (docs/dev/plan.md §5.2): one table of tools,
// served over MCP at /mcp and mirrored as REST at /api/v1/agent/tools/{name}.
// Every call authenticates with an agent bearer token (vsp_…).
package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/connectors"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

type Deps struct {
	Connectors *connectors.Service
	Secrets    *usersecrets.Service
	Q          *store.Queries
	Runs       *runs.Service
	Tracker    *tracker.Service
	Wiki       *wiki.Service
	Designs    *designs.Service
	// Files keeps a file in the person's Library (save_file); nil where there is no object store.
	Files FileKeeper
}

// Tool is one Agent API operation, independent of transport.
type Tool struct {
	Name        string
	Description string
	// register adds the tool to an MCP server and returns a REST invoker.
	call   func(ctx context.Context, d Deps, c agents.Caller, raw json.RawMessage) (any, error)
	addMCP func(srv mcpServer, d Deps)
}

// TicketArg is shared by tools that act on a run: optional when the caller
// has exactly one live run (or a run-scoped token).
type TicketArg struct {
	Ticket string `json:"ticket,omitempty" jsonschema:"Ticket key, e.g. PAY-214. Optional when you have one live run."`
}

type Empty struct{}

type WhoamiOut struct {
	ID           string         `json:"id"`
	Name         string         `json:"name"`
	Handle       string         `json:"handle"`
	Role         string         `json:"role"`
	Model        string         `json:"model"`
	Instructions string         `json:"instructions"`
	Scopes       map[string]any `json:"scopes"`
	Session      string         `json:"session"`
	LiveRuns     []string       `json:"live_runs"`
	Queue        []QueueItem    `json:"queue"`
	Project      string         `json:"project,omitempty"` // chats only
	ChatID       string         `json:"chat_id,omitempty"` // chats only
}

type QueueItem struct {
	Key      string `json:"key"`
	Title    string `json:"title"`
	Status   string `json:"status"`
	Priority string `json:"priority"`
}

func whoami(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	spec, _, err := agents.CurrentSpec(ctx, d.Q, c.Agent)
	if err != nil {
		return nil, err
	}
	out := WhoamiOut{ID: c.Agent.ID.String(), Name: c.Agent.Name, Handle: c.Agent.Handle, Role: c.Agent.Role, Model: spec.Model,
		Instructions: spec.Instructions, Scopes: map[string]any{}, Session: c.Kind, LiveRuns: []string{}, Queue: []QueueItem{}}
	for s, m := range spec.Scopes {
		out.Scopes[s] = m
	}
	if c.RunID != nil {
		if run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID}); err == nil {
			if resolved, err := runs.Spec(run); err == nil {
				out.Model = resolved.Model
				out.Instructions = resolved.Instructions
				out.Scopes = map[string]any{}
				for _, sc := range resolved.Scopes {
					out.Scopes[sc.Scope] = sc.Mode
				}
			}
		}
	}
	// A chat has no tickets or queue: it answers a person from project context.
	scope, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if scope != nil {
		out.Instructions = fmt.Sprintf(chatInstructions, scope.where(), scope.ChatID) + "\n\n" + out.Instructions
		out.Project, out.ChatID = scope.ProjectKey, scope.ChatID.String()
		return out, nil
	}
	live, err := d.Q.ActiveRunsForAgent(ctx, c.Agent.ID)
	if err != nil {
		return nil, err
	}
	for _, r := range live {
		out.LiveRuns = append(out.LiveRuns, r.TicketKey)
	}
	q, err := d.Q.AgentQueue(ctx, &c.Agent.ID)
	if err != nil {
		return nil, err
	}
	for _, t := range q {
		out.Queue = append(out.Queue, QueueItem{Key: t.Key, Title: t.Title, Status: t.Status, Priority: t.Priority})
	}
	return out, nil
}

// mockupInfo is the ticket's mockup gate as the agent sees it: what exists, what
// a person approved, and (while it blocks finishing) what to do about it.
func mockupInfo(ctx context.Context, d Deps, t store.Ticket) (map[string]any, error) {
	g, err := artifacts.MockupGate(ctx, d.Q, t)
	if err != nil {
		return nil, err
	}
	items := make([]map[string]any, len(g.Mockups))
	for i, m := range g.Mockups {
		items[i] = map[string]any{"id": m.ID, "title": m.Title, "version": m.VersionLabel, "review_state": m.ReviewState, "review_note": m.ReviewNote}
	}
	out := map[string]any{"required": g.Required, "approved": g.Approved, "mockups": items}
	if g.Required && !g.Approved {
		out["instruction"] = "This ticket needs a person-approved UI mockup before implementation. Read an existing one with read_artifact, or draft one with create_mockup; your run pauses until a person reviews it. You can't call set_pr, check_criterion or complete_run until one is approved."
	}
	return out, nil
}

type ClaimIn struct {
	Ticket string `json:"ticket" jsonschema:"Ticket key to start working on, e.g. PAY-214"`
}

func claim(ctx context.Context, d Deps, c agents.Caller, in ClaimIn) (any, error) {
	run, err := d.Runs.Claim(ctx, c, in.Ticket)
	if err != nil {
		return nil, err
	}
	spec, _ := runs.Spec(run)
	scopes := map[string]string{}
	for _, s := range spec.Scopes {
		scopes[s.Scope] = string(s.Mode)
	}
	// Wiki memory this run starts with (docs/dev/plan.md §12.3); delivered pages
	// count as one read each.
	memory := []wiki.ContextPage{}
	if t, err := d.Q.GetTicketByID(ctx, *run.TicketID); err == nil && run.Mode != "managed" {
		if memory, err = wiki.RunContext(ctx, d.Q, c.Agent, t, spec.Memory); err != nil {
			return nil, err
		}
		if err := wiki.RecordContextReads(ctx, d.Q, c.Agent.WorkspaceID, c.Agent.ID, &run.ID, memory); err != nil {
			return nil, err
		}
	}
	details, err := getTicket(ctx, d, c, GetTicketIn{Ticket: in.Ticket})
	if err != nil {
		return nil, err
	}
	out := map[string]any{
		"run_id": run.ID, "ticket": strings.ToUpper(in.Ticket), "state": run.State, "scopes": scopes, "agent": c.Agent.Handle,
		"instructions": spec.Instructions,
		"memory":       memory,
		"next": "Read memory first: it's what you and others learned before. The ticket is in ticket_details, so skip get_ticket; read the attached artifacts with read_artifact, then post_plan before editing. " +
			"Before implementing, look up conventions with find_pattern (e.g. find_pattern({q: \"error wrapping\"})) and follow what it returns. " +
			"Don't log what you did. Only write_note under " + wiki.MemoryRoot(c.Agent.Handle) + " for a durable lesson that would help a future run on this codebase, linked with [[…]] to the tickets and documents it's about. " +
			"A general lesson that applies beyond this codebase (an architecture pattern or coding style) goes through propose_pattern instead. Project-specific decisions belong in ADR/Architecture notes.",
	}
	out["ticket_details"] = details
	if run.Mode == "managed" {
		delete(out, "instructions")
		delete(out, "memory")
		out["next"] = "Your instructions and available context are already in AGENTS.md. The ticket is in ticket_details, so skip get_ticket; read only context relevant to this task, and post_plan before editing. Work directly by default; delegate only when justified. Reuse existing session context on resume."
	}
	// A retry would otherwise start cold and repeat the last attempt's dead end.
	prior, err := priorRuns(ctx, d, run)
	if err != nil {
		return nil, err
	}
	if len(prior) > 0 {
		out["prior_attempts"] = len(prior)
		out["next"] = fmt.Sprintf("This ticket was tried %d time(s) before: call get_prior_attempts before post_plan to see how it ended and where its work was saved. ", len(prior)) + out["next"].(string)
	}
	if t, err := d.Q.GetTicketByID(ctx, *run.TicketID); err == nil {
		out["requires_mockup"] = t.RequiresMockup
		if out["mockup"], err = mockupInfo(ctx, d, t); err != nil {
			return nil, err
		}
	}
	return out, nil
}

type GetTicketIn struct {
	Ticket string `json:"ticket" jsonschema:"Ticket key, e.g. PAY-214"`
}

func getTicket(ctx context.Context, d Deps, c agents.Caller, in GetTicketIn) (any, error) {
	ws := c.Agent.WorkspaceID
	t, err := tracker.Get(ctx, d.Q, ws, strings.ToUpper(strings.TrimSpace(in.Ticket)))
	if err != nil {
		return nil, apperr.Invalid("ticket", "no ticket %s", in.Ticket)
	}
	crit, err := d.Q.ListCriteria(ctx, t.ID)
	if err != nil {
		return nil, err
	}
	criteria := make([]map[string]any, len(crit))
	for i, cr := range crit {
		criteria[i] = map[string]any{"n": i + 1, "text": cr.Text, "done": cr.Done}
	}
	docs, err := d.Q.ListTicketArtifacts(ctx, store.ListTicketArtifactsParams{TicketID: t.ID, AssigneeAgentID: &c.Agent.ID, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	arts := make([]map[string]any, len(docs))
	for i, a := range docs {
		m := map[string]any{"id": a.ID, "type": a.Type, "title": a.Title, "relation": a.Relation, "read_by_you": a.ReadByAssignee}
		if id := artifacts.DisplayID(a.Type, a.Number); id != nil {
			m["display_id"] = *id
		}
		arts[i] = m
	}
	deps, err := d.Q.TicketDependencies(ctx, t.ID)
	if err != nil {
		return nil, err
	}
	comments, err := d.Q.ListTicketComments(ctx, t.ID)
	if err != nil {
		return nil, err
	}
	cs := make([]map[string]any, len(comments))
	for i := range comments {
		cm := comments[len(comments)-1-i] // oldest first
		cs[i] = map[string]any{"author": cm.Author, "author_type": cm.AuthorType, "body": cm.BodyMd, "at": cm.CreatedAt}
	}
	out := map[string]any{
		"key": t.Key, "title": t.Title, "description": t.DescriptionMd, "status": t.Status, "priority": t.Priority,
		"blocked_by": func() []map[string]any {
			out := []map[string]any{}
			for _, d := range deps {
				out = append(out, map[string]any{"key": d.Key, "title": d.Title, "status": d.Status})
			}
			return out
		}(), "criteria": criteria, "artifacts": arts, "comments": cs, "assigned_to_you": t.AssigneeAgentID != nil && *t.AssigneeAgentID == c.Agent.ID,
	}
	if t.Branch != nil {
		out["branch"] = *t.Branch
	}
	if t.PrUrl != nil {
		out["pr_url"] = *t.PrUrl
	}
	out["requires_mockup"] = t.RequiresMockup
	if out["mockup"], err = mockupInfo(ctx, d, t); err != nil {
		return nil, err
	}
	out["revision"] = t.Revision
	out["estimate_points"] = t.EstimatePoints
	out["estimate"] = ticketEstimate(t)
	if out["epic"], err = ticketEpic(ctx, d, t); err != nil {
		return nil, err
	}
	return out, nil
}

type ReadArtifactIn struct {
	TicketArg
	Artifact string `json:"artifact" jsonschema:"Artifact id from get_ticket, or an ADR id like ADR-012"`
	Section  string `json:"section,omitempty" jsonschema:"Optional section anchor from the outline, e.g. reconciliation-performance"`
}

// readRunID is the run a read is attributed to: the live run when there is
// one, else the token's own run (chat runs have no ticket for Active to find).
func readRunID(ctx context.Context, d Deps, c agents.Caller, ticket string) *uuid.UUID {
	if run, _, err := d.Runs.Active(ctx, d.Q, c, ticket); err == nil {
		return &run.ID
	}
	return c.RunID
}

func readArtifact(ctx context.Context, d Deps, c agents.Caller, in ReadArtifactIn) (any, error) {
	ws := c.Agent.WorkspaceID
	var a store.Artifact
	ref := strings.TrimSpace(in.Artifact)
	if id, err := uuid.Parse(ref); err == nil {
		a, err = d.Q.GetArtifact(ctx, store.GetArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return nil, apperr.Invalid("artifact", "no artifact %s", ref)
		}
	} else if n, ok := strings.CutPrefix(strings.ToUpper(ref), "ADR-"); ok {
		var num int32
		for _, ch := range n {
			if ch < '0' || ch > '9' {
				return nil, apperr.Invalid("artifact", "%s isn't an ADR id", ref)
			}
			num = num*10 + int32(ch-'0')
		}
		a, err = d.Q.GetADRByNumber(ctx, store.GetADRByNumberParams{WorkspaceID: ws, Number: &num, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return nil, apperr.Invalid("artifact", "no %s", ref)
		}
	} else {
		return nil, apperr.Invalid("artifact", "pass an artifact id or ADR-NNN")
	}
	if a.CurrentVersionID == nil {
		return nil, apperr.Invalid("artifact", "has no content")
	}
	v, err := d.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	if a.Type == "mockup" && v.BodyMd != nil {
		runID := readRunID(ctx, d, c, in.Ticket)
		if err := artifacts.RecordRead(ctx, d.Q, a, c.Agent.ID, runID, "", nil); err != nil {
			return nil, err
		}
		reviewState := ""
		if v.ReviewState != nil {
			reviewState = *v.ReviewState
		}
		return map[string]any{"title": a.Title, "type": a.Type, "version": v.Label, "svg": *v.BodyMd,
			"review_state": reviewState, "review_note": v.ReviewNote}, nil
	}
	if v.BodyMd == nil {
		return nil, apperr.Invalid("artifact", "%s is a %s file, not text; ask a person to describe it", a.Title, v.ContentType)
	}
	body := *v.BodyMd
	if in.Section != "" {
		sec, ok := artifacts.SectionText(body, in.Section)
		if !ok {
			return nil, apperr.Invalid("section", "no section %q; call read_artifact without section to see the outline", in.Section)
		}
		body = sec
	}
	// Reads are attributed to the run when there is one, for citation counts.
	runID := readRunID(ctx, d, c, in.Ticket)
	if err := artifacts.RecordRead(ctx, d.Q, a, c.Agent.ID, runID, in.Section, nil); err != nil {
		return nil, err
	}
	outline := []map[string]any{}
	for _, s := range artifacts.Outline(*v.BodyMd) {
		outline = append(outline, map[string]any{"level": s.Level, "heading": s.Heading, "anchor": s.Anchor})
	}
	return map[string]any{"title": a.Title, "type": a.Type, "version": v.Label, "markdown": body, "outline": outline}, nil
}

type PlanIn struct {
	TicketArg
	Steps []string `json:"steps" jsonschema:"The plan, one short sentence per step, in order"`
}

type StepIn struct {
	TicketArg
	Step  int    `json:"step" jsonschema:"Step number, from 1"`
	State string `json:"state" jsonschema:"pending, current, done, needs_human or failed"`
	Note  string `json:"note,omitempty" jsonschema:"When marking a step done: what the next step needs to know that the code doesn't show, e.g. decisions made, gotchas, where things live. Up to 1,500 characters."`
}

type LogEventIn struct {
	TicketArg
	Kind    string         `json:"kind" jsonschema:"test_run for test results (payload: passed, failed, duration_s, command); anything else is logged to the run only"`
	Payload map[string]any `json:"payload,omitempty"`
}

type UsageIn struct {
	TicketArg
	ToolCalls    int64   `json:"tool_calls,omitempty"`
	InputTokens  int64   `json:"input_tokens,omitempty"`
	OutputTokens int64   `json:"output_tokens,omitempty"`
	CostUSD      float64 `json:"cost_usd,omitempty"`
}

type BranchIn struct {
	TicketArg
	Branch string `json:"branch" jsonschema:"Branch name, e.g. atlas/pay-214-partition-ledger"`
}

type PRIn struct {
	TicketArg
	URL   string `json:"url" jsonschema:"GitHub pull request URL"`
	Draft bool   `json:"draft,omitempty"`
}

type CriterionIn struct {
	TicketArg
	N    int   `json:"n,omitempty" jsonschema:"Criterion number from get_ticket, from 1"`
	Ns   []int `json:"ns,omitempty" jsonschema:"Several criterion numbers to tick (or untick) in one call; use instead of n"`
	Done *bool `json:"done,omitempty" jsonschema:"Default true; false unticks"`
}

type ReportIn struct {
	TicketArg
	Title string `json:"title"`
	Body  string `json:"body" jsonschema:"Markdown. Use ## headings so people and agents can cite sections."`
}

type CommentIn struct {
	TicketArg
	Body string `json:"body" jsonschema:"Markdown"`
}

type NewTicketIn struct {
	TicketArg
	Project           string     `json:"project,omitempty" jsonschema:"Chats only: project key, e.g. PAY; default the chat's default project"`
	Agent             string     `json:"agent,omitempty" jsonschema:"Chats only: assign a main agent by handle, e.g. pike, so the ticket can be started"`
	EpicID            *uuid.UUID `json:"epic_id,omitempty"`
	Title             string     `json:"title"`
	Description       string     `json:"description,omitempty"`
	Priority          string     `json:"priority,omitempty" jsonschema:"none, low, medium, high or urgent"`
	RequiresMockup    bool       `json:"requires_mockup,omitempty" jsonschema:"The ticket needs a person-approved UI mockup before it can be finished"`
	Points            *int       `json:"points,omitempty" jsonschema:"Optional story points: 1, 2, 3, 5, 8 or 13"`
	EstimateRationale string     `json:"estimate_rationale,omitempty" jsonschema:"Why that estimate, in a sentence"`
	Criteria          []string   `json:"criteria,omitempty" jsonschema:"Acceptance criteria, one checkable sentence each. The run ticks them as it verifies them, and can't finish with any unticked"`
	BlockedBy         []string   `json:"blocked_by,omitempty" jsonschema:"Keys of tickets that must be Done before this one starts, e.g. [PAY-12]. A started run queues until they are"`
}

// estimate is the optional estimate on create_ticket, validated up front.
func (in NewTicketIn) estimate() (*int, *string, error) {
	if in.Points == nil {
		return nil, nil, nil
	}
	if !slices.Contains(tracker.EstimateScale, *in.Points) {
		return nil, nil, apperr.Invalid("points", "%d is off the scale: use one of 1, 2, 3, 5, 8, 13", *in.Points)
	}
	r := strings.TrimSpace(in.EstimateRationale)
	if len([]rune(r)) > 2000 {
		return nil, nil, apperr.Invalid("estimate_rationale", "must be at most 2000 characters")
	}
	if r == "" {
		return in.Points, nil, nil
	}
	return in.Points, &r, nil
}

type MockupIn struct {
	TicketArg
	Title    string `json:"title,omitempty" jsonschema:"Mockup title, e.g. Checkout screen. Required for a new mockup."`
	SVG      string `json:"svg" jsonschema:"The complete SVG document: self-contained, no scripts, no external images or links. Wireframe the screen at its real size."`
	MockupID string `json:"mockup_id,omitempty" jsonschema:"Revise this existing mockup (id from get_ticket) instead of creating a new one"`
	Note     string `json:"note,omitempty" jsonschema:"One line on what changed in this revision"`
}

type ApprovalIn struct {
	TicketArg
	Scope  string         `json:"scope" jsonschema:"The scope that needs approval, e.g. db:migrate"`
	Action string         `json:"action" jsonschema:"One sentence naming the exact action, e.g. Apply 0042_partition_ledger_entries to staging"`
	Detail map[string]any `json:"detail,omitempty" jsonschema:"For brokered scopes, exactly what to run: db:migrate takes {sql}"`
	Risk   string         `json:"risk,omitempty" jsonschema:"What could go wrong and how big it is"`
}

type WaitIn struct {
	ApprovalID string `json:"approval_id"`
	TimeoutS   int    `json:"timeout_s,omitempty" jsonschema:"Up to 50; call again if it returns pending"`
}

type GatedIn struct {
	TicketArg
	ApprovalID string `json:"approval_id" jsonschema:"An approved request from request_approval; runs exactly what was approved"`
}

type AwaitHumanIn struct {
	TicketArg
	Reason string `json:"reason" jsonschema:"What you need from a person"`
}

type SignalIn struct {
	TicketArg
	Since    string `json:"since,omitempty" jsonschema:"Cursor from the previous await_signal (RFC 3339); omit the first time"`
	TimeoutS int    `json:"timeout_s,omitempty" jsonschema:"Up to 50"`
}

type CompleteIn struct {
	TicketArg
	Outcome        string `json:"outcome" jsonschema:"One or two sentences on what you did; for a delegated run, the headline; put detail in report"`
	Report         string `json:"report,omitempty" jsonschema:"Delegated runs only: the full result for the main agent, in Markdown: findings with file:line, what you changed and why, open questions. Up to 8,000 characters. It is delivered to the main agent as is, so don't also post it as a ticket comment."`
	Status         string `json:"status,omitempty" jsonschema:"in_review (default) or done require every acceptance criterion checked after verification; todo explicitly hands unfinished work back. done is accepted only after a delegated reviewer or QA agent gave the all clear"`
	Verdict        string `json:"verdict,omitempty" jsonschema:"Reviewer/QA sub agents only: approved (all clear) or changes_requested"`
	ReproCommand   string `json:"repro_command,omitempty" jsonschema:"Reviewer/QA only: the command that runs the failing tests you committed for your blocking findings, e.g. go test ./internal/deck -run TestInsertSlideGroupIDs. It must fail now and pass once they are fixed."`
	ReproCoversAll bool   `json:"repro_covers_all,omitempty" jsonschema:"True only if every blocking finding has a failing test in repro_command."`
}

type RecheckReviewIn struct {
	TicketArg
	RunID string `json:"run_id" jsonschema:"run_id of the completed review whose failing tests (repro_command) were merged into your branch"`
}

type DelegateIn struct {
	TicketArg
	Agent              string   `json:"agent" jsonschema:"Handle of a sub agent from list_subagents, e.g. docs-writer"`
	Task               string   `json:"task" jsonschema:"What it should do, with the context it needs: it can't see your conversation. Name files, constraints and the done condition."`
	AcceptanceCriteria []string `json:"acceptance_criteria,omitempty" jsonschema:"Checkable conditions that make the task done. Shown to the sub agent; you verify them against the automated check results."`
	AllowedPaths       []string `json:"allowed_paths,omitempty" jsonschema:"Repo-relative files, directories (trailing slash) or globs the sub agent may change. Changes outside them fail the automated checks."`
	TestCommand        string   `json:"test_command,omitempty" jsonschema:"Command that must exit 0 in the sub agent's worktree, e.g. go test ./internal/runs/. The server runs it when the sub agent finishes and reports the result to you."`
	ContinueRunID      string   `json:"continue_run_id,omitempty" jsonschema:"run_id of a finished delegation to the same sub agent to carry on, e.g. to send it fixes. Keeps that agent's context: same worktree and branch, and its conversation is resumed. The server tells it which commits changed since its last run; don't paste SHAs."`
}

type SearchIn struct {
	Folder     string               `json:"folder,omitempty"`
	Tag        string               `json:"tag,omitempty"`
	Audience   string               `json:"audience,omitempty"`
	Properties artifacts.Properties `json:"properties,omitempty"`
	Q          string               `json:"q" jsonschema:"What to look for; web-search syntax (quotes, OR, -word)"`
	Kinds      []string             `json:"kinds,omitempty" jsonschema:"Limit to note, prd, spec, adr, report, design or ticket"`
	Project    string               `json:"project,omitempty" jsonschema:"Project key; notes without a project always match"`
	Limit      int                  `json:"limit,omitempty" jsonschema:"Up to 50, default 10"`
}

type PageIn struct {
	TicketArg
	Ref     string `json:"ref" jsonschema:"A page title or path, ADR-012, an artifact id, or [[Page#Section]]"`
	Section string `json:"section,omitempty" jsonschema:"Optional heading (or its anchor) to read just that section"`
}

type WriteNoteIn struct {
	TicketArg
	BaseVersion *uuid.UUID           `json:"base_version_id,omitempty"`
	Properties  artifacts.Properties `json:"properties,omitempty"`
	Path        string               `json:"path" jsonschema:"Page path, e.g. agents/atlas/Partition gotchas (a durable lesson in your memory) or Payments/Rollback runbook (shared)"`
	Body        string               `json:"body" jsonschema:"Markdown. Link what it's about with [[PAY-214]], [[ADR-012]], [[Page title]] or [[Page#Section]]."`
	Mode        string               `json:"mode,omitempty" jsonschema:"create, replace (default) or append"`
	Note        string               `json:"note,omitempty" jsonschema:"One line on what changed"`
}

type FindPatternIn struct {
	TicketArg
	Q     string `json:"q" jsonschema:"What the convention is about; typos and partial words are fine, e.g. error wrapping, pgx, ctx. Empty lists every pattern."`
	Topic string `json:"topic,omitempty" jsonschema:"Limit to one topic: Go, React, Postgres, Testing, API, Architecture or Process"`
	Limit int    `json:"limit,omitempty" jsonschema:"Up to 50, default 10"`
}

type ProposePatternIn struct {
	Title        string   `json:"title" jsonschema:"Short and imperative, e.g. Wrap errors with context. Becomes the page name."`
	Topic        string   `json:"topic" jsonschema:"Go, React, Postgres, Testing, API, Architecture or Process"`
	Tags         []string `json:"tags" jsonschema:"2 to 5 lowercase tags people would search for, e.g. errors, context"`
	Body         string   `json:"body" jsonschema:"Markdown with the sections ## When to use, ## Rule, ## Example, ## When not to use, ## Related. Don't add the Topic/Tags header: it is written for you."`
	SourceTicket string   `json:"source_ticket,omitempty" jsonschema:"Ticket key the lesson came from, e.g. PAY-214. Linked in Related."`
}

type PublishPatternIn struct {
	TicketArg
	ProposedTitle string `json:"proposed_title" jsonschema:"Title of a proposal from list_proposed_patterns"`
	Title         string `json:"title,omitempty" jsonschema:"Publish under a different title"`
	Topic         string `json:"topic,omitempty" jsonschema:"Publish under a different topic"`
	Body          string `json:"body,omitempty" jsonschema:"Replace the proposal's body with this edited Markdown"`
}

type RejectPatternIn struct {
	TicketArg
	ProposedTitle string `json:"proposed_title" jsonschema:"Title of a proposal from list_proposed_patterns"`
	Reason        string `json:"reason" jsonschema:"Why it isn't being published (duplicate, too specific, wrong); relayed to the proposer"`
}

type BacklinksIn struct {
	Ref string `json:"ref" jsonschema:"A page title or path, ADR-012, PAY-214, an epic name, @handle or an artifact id"`
}

// scopesFor is the caller's scope map: the live run's frozen definition if
// there is one, else the agent's current definition.
func scopesFor(ctx context.Context, d Deps, c agents.Caller, ticket string) (map[string]agentdef.Mode, *uuid.UUID, error) {
	out := map[string]agentdef.Mode{}
	if run, _, err := d.Runs.Active(ctx, d.Q, c, ticket); err == nil {
		spec, err := runs.Spec(run)
		if err != nil {
			return nil, nil, err
		}
		for _, s := range spec.Scopes {
			out[s.Scope] = s.Mode
		}
		return out, &run.ID, nil
	}
	spec, _, err := agents.CurrentSpec(ctx, d.Q, c.Agent)
	if err != nil {
		return nil, nil, err
	}
	return spec.Scopes, nil, nil
}

func searchKnowledge(ctx context.Context, d Deps, c agents.Caller, in SearchIn) (any, error) {
	if in.Folder != "" || in.Tag != "" || in.Audience != "" || len(in.Properties) > 0 {
		return filteredSearch(ctx, d, c, in)
	}
	if strings.TrimSpace(in.Q) == "" {
		return nil, apperr.Invalid("q", "is required")
	}
	project, err := projectFilter(ctx, d, c.Agent.WorkspaceID, in.Project)
	if err != nil {
		return nil, err
	}
	hits, err := wiki.Search(ctx, d.Q, c.Agent.WorkspaceID, in.Q, in.Kinds, project, in.Limit)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, len(hits))
	for i, h := range hits {
		out[i] = map[string]any{"ref": wiki.LinkText(h.Target), "kind": h.Kind, "type": h.ArtifactType, "title": h.Title, "snippet": h.Snippet}
	}
	return map[string]any{"results": out, "hint": "Open one with read_page(ref)."}, nil
}

func readPage(ctx context.Context, d Deps, c agents.Caller, in PageIn) (any, error) {
	ws := c.Agent.WorkspaceID
	ref, t, err := wiki.LookupRef(ctx, d.Q, ws, in.Ref)
	if err != nil {
		return nil, apperr.Invalid("ref", "nothing called %q; try search_knowledge", in.Ref)
	}
	if ref.Kind == "ticket" {
		return nil, apperr.Invalid("ref", "%s is a ticket: use get_ticket", t.DisplayID)
	}
	if ref.Kind != "artifact" {
		return map[string]any{"kind": ref.Kind, "title": t.Title, "message": "Not a page. get_backlinks shows what links to it."}, nil
	}
	a, err := d.Q.GetArtifact(ctx, store.GetArtifactParams{ID: ref.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	if a.CurrentVersionID == nil {
		return nil, apperr.Invalid("ref", "%q is only a suggestion so far", in.Ref)
	}
	v, err := d.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	if v.BodyMd == nil {
		return nil, apperr.Invalid("ref", "%s is a %s file, not text", a.Title, v.ContentType)
	}
	if a.Type == "mockup" {
		return nil, apperr.Invalid("ref", "%s is a UI mockup (SVG): use read_artifact", a.Title)
	}
	if err := canvasPageBody(ctx, d, a); err != nil {
		return nil, err
	}
	body := *v.BodyMd
	anchor := t.Anchor
	if in.Section != "" {
		anchor = artifacts.Slug(in.Section)
		if strings.HasPrefix(in.Section, "^") {
			anchor = in.Section
		}
	}
	if anchor != "" {
		sec, ok := artifacts.SectionText(body, anchor)
		if !ok {
			return nil, apperr.Invalid("section", "no section %q; read the page without section to see its outline", anchor)
		}
		body = sec
	}
	runID := readRunID(ctx, d, c, in.Ticket)
	if err := artifacts.RecordRead(ctx, d.Q, a, c.Agent.ID, runID, anchor, nil); err != nil {
		return nil, err
	}
	outline := []map[string]any{}
	for _, s := range artifacts.Outline(*v.BodyMd) {
		outline = append(outline, map[string]any{"level": s.Level, "heading": s.Heading, "anchor": s.Anchor})
	}
	ls, err := d.Q.LinksFromSource(ctx, store.LinksFromSourceParams{SourceKind: "artifact", SourceID: a.ID})
	if err != nil {
		return nil, err
	}
	linksOut := []string{}
	for _, l := range ls {
		if !slices.Contains(linksOut, l.RawText) {
			linksOut = append(linksOut, l.RawText)
		}
	}
	out := map[string]any{"id": a.ID, "version_id": v.ID, "properties": artifacts.DecodeProperties(v.Properties), "title": a.Title, "type": a.Type, "version": v.Label, "markdown": body, "outline": outline, "links": linksOut}
	if a.Path != nil {
		out["path"] = *a.Path
	}
	if t.DisplayID != "" {
		out["display_id"] = t.DisplayID
	}
	return out, nil
}

func writeNote(ctx context.Context, d Deps, c agents.Caller, in WriteNoteIn) (any, error) {
	scopes, _, err := scopesFor(ctx, d, c, in.Ticket)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Body) == "" {
		return nil, apperr.Invalid("body", "is empty; to clear a page's text, ask the person")
	}
	res, err := d.Wiki.AgentWrite(ctx, c.Agent, scopes, wiki.Save{Path: in.Path, Body: in.Body, Mode: in.Mode, Note: in.Note, BaseID: in.BaseVersion, Properties: in.Properties})
	if err != nil {
		return nil, err
	}
	out := map[string]any{"path": *res.Note.Path, "state": res.State, "created": res.Created}
	if res.State == "suggested" {
		out["message"] = "Saved as a suggestion: a person will accept or reject it. Your own memory (" + wiki.MemoryRoot(c.Agent.Handle) + ") is always writable."
	}
	return ok(out), nil
}

func findPattern(ctx context.Context, d Deps, c agents.Caller, in FindPatternIn) (any, error) {
	ws := c.Agent.WorkspaceID
	ps, err := wiki.FindPatterns(ctx, d.Q, ws, in.Q, in.Topic, in.Limit)
	if err != nil {
		return nil, err
	}
	// Patterns a search turned up count as read (citations); plain browsing doesn't.
	if strings.TrimSpace(in.Q) != "" && len(ps) > 0 {
		runID := readRunID(ctx, d, c, in.Ticket)
		for _, p := range ps {
			a, err := d.Q.GetArtifact(ctx, store.GetArtifactParams{ID: p.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
			if err != nil {
				return nil, err
			}
			if err := artifacts.RecordRead(ctx, d.Q, a, c.Agent.ID, runID, "", nil); err != nil {
				return nil, err
			}
		}
	}
	out := make([]map[string]any, len(ps))
	for i, p := range ps {
		out[i] = map[string]any{"ref": p.Path, "title": p.Title, "topic": p.Topic, "tags": p.Tags, "summary": p.Summary, "score": p.Score}
	}
	return map[string]any{"patterns": out, "hint": "Open one with read_page(ref) for the rule and example. Nothing fits? Follow the code around you; when you learn a reusable lesson, propose_pattern."}, nil
}

func proposePattern(ctx context.Context, d Deps, c agents.Caller, in ProposePatternIn) (any, error) {
	source := strings.ToUpper(strings.TrimSpace(in.SourceTicket))
	if source != "" {
		if _, err := tracker.Get(ctx, d.Q, c.Agent.WorkspaceID, source); err != nil {
			return nil, apperr.Invalid("source_ticket", "no ticket %s", in.SourceTicket)
		}
	}
	res, err := d.Wiki.ProposePattern(ctx, c.Agent, wiki.Proposal{Title: in.Title, Topic: in.Topic, Tags: in.Tags, Body: in.Body, SourceTicket: source})
	if err != nil {
		return nil, err
	}
	return ok(map[string]any{"path": *res.Note.Path, "created": res.Created,
		"message": "Proposed. An agent with wiki:write allowed reviews proposals and publishes them under Patterns/<Topic>/. Re-call propose_pattern with the same title to revise it."}), nil
}

// curator is the caller's scopes when they may publish and reject patterns.
func curator(ctx context.Context, d Deps, c agents.Caller, ticket string) (map[string]agentdef.Mode, error) {
	scopes, _, err := scopesFor(ctx, d, c, ticket)
	if err != nil {
		return nil, err
	}
	if !wiki.CanCurate(scopes) {
		return nil, apperr.Invalid("scope", "only agents whose wiki:write scope is allowed can review patterns; use propose_pattern to suggest one")
	}
	return scopes, nil
}

func publishPattern(ctx context.Context, d Deps, c agents.Caller, in PublishPatternIn) (any, error) {
	scopes, err := curator(ctx, d, c, in.Ticket)
	if err != nil {
		return nil, err
	}
	res, err := d.Wiki.PublishPattern(ctx, c.Agent, scopes, wiki.PublishInput{ProposedTitle: in.ProposedTitle, Title: in.Title, Topic: in.Topic, Body: in.Body})
	if err != nil {
		return nil, err
	}
	return ok(map[string]any{"path": *res.Note.Path, "message": "Published; the proposal was removed. find_pattern now returns it."}), nil
}

func rejectPattern(ctx context.Context, d Deps, c agents.Caller, in RejectPatternIn) (any, error) {
	scopes, err := curator(ctx, d, c, in.Ticket)
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.Reason) == "" {
		return nil, apperr.Invalid("reason", "is required")
	}
	who, err := d.Wiki.RejectPattern(ctx, c.Agent, scopes, in.ProposedTitle)
	if err != nil {
		return nil, err
	}
	return ok(map[string]any{"proposed_by": who, "reason": strings.TrimSpace(in.Reason),
		"message": "The proposal was removed. Relay the reason to " + who + " (comment on a ticket or mention them) if it matters."}), nil
}

func listProposedPatterns(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	if _, err := curator(ctx, d, c, ""); err != nil {
		return nil, err
	}
	ps, err := d.Wiki.ListProposed(ctx, c.Agent.WorkspaceID)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, len(ps))
	for i, p := range ps {
		out[i] = map[string]any{"title": p.Title, "ref": p.Path, "proposer": p.Proposer, "age": time.Since(p.UpdatedAt).Round(time.Minute).String()}
	}
	return map[string]any{"proposed": out, "hint": "Open one with read_page(ref), then publish_pattern or reject_pattern."}, nil
}

func getBacklinks(ctx context.Context, d Deps, c agents.Caller, in BacklinksIn) (any, error) {
	ws := c.Agent.WorkspaceID
	ref, t, err := wiki.LookupRef(ctx, d.Q, ws, in.Ref)
	if err != nil {
		return nil, apperr.Invalid("ref", "nothing called %q; try search_knowledge", in.Ref)
	}
	bl, err := wiki.Backlinks(ctx, d.Q, ws, ref)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(bl))
	for _, m := range bl {
		r := map[string]any{"ref": wiki.LinkText(m.Source), "kind": m.Source.Kind, "title": m.Source.Title, "snippets": m.Snippets}
		if len(m.Anchors) > 0 {
			r["cites_sections"] = m.Anchors
		}
		out = append(out, r)
	}
	return map[string]any{"target": t.Title, "linked_from": out}, nil
}

func timeoutOf(s int) time.Duration { return time.Duration(s) * time.Second }

func parseUUID(field, s string) (uuid.UUID, error) {
	id, err := uuid.Parse(strings.TrimSpace(s))
	if err != nil {
		return id, apperr.Invalid(field, "must be an id returned by an earlier call")
	}
	return id, nil
}

func ok(extra map[string]any) map[string]any {
	out := map[string]any{"ok": true}
	for k, v := range extra {
		out[k] = v
	}
	return out
}

// Tools is the whole Agent API.
type TicketProposalIn struct {
	Ref               string   `json:"ref,omitempty" jsonschema:"Unique stable proposal reference, such as schema or api"`
	DependsOn         []string `json:"depends_on,omitempty" jsonschema:"Other proposal refs that must finish first"`
	BlockedBy         []string `json:"blocked_by,omitempty" jsonschema:"Existing ticket keys that must be Done first"`
	Title             string   `json:"title"`
	Description       string   `json:"description"`
	Criteria          []string `json:"criteria"`
	AgentID           string   `json:"agent_id,omitempty" jsonschema:"Optional suggested agent UUID; omit for unassigned"`
	RequiresMockup    bool     `json:"requires_mockup,omitempty" jsonschema:"the ticket changes UI: a person must approve a mockup before implementation"`
	Points            *int     `json:"points,omitempty" jsonschema:"Story points: 1, 2, 3, 5, 8 or 13. Copied to the ticket when a person accepts the draft."`
	EstimateRationale string   `json:"estimate_rationale,omitempty" jsonschema:"Why that estimate, in a sentence"`
}

type ProposeTicketsIn struct {
	Tickets []TicketProposalIn `json:"tickets" jsonschema:"Draft tickets for a person to edit and accept"`
}

var Tools = []Tool{
	define("propose_tickets", "Submit draft tickets for human review and finish this planning run. Creates no tickets.", func(ctx context.Context, d Deps, c agents.Caller, in ProposeTicketsIn) (any, error) {
		items := make([]runs.Proposal, 0, len(in.Tickets))
		for _, item := range in.Tickets {
			p := runs.Proposal{Ref: item.Ref, DependsOn: item.DependsOn, BlockedBy: item.BlockedBy, Title: item.Title, Description: item.Description, Criteria: item.Criteria, RequiresMockup: item.RequiresMockup, EstimatePoints: item.Points}
			if item.Points != nil && !slices.Contains(tracker.EstimateScale, *item.Points) {
				return nil, apperr.Invalid("points", "%q: %d is off the scale: use one of 1, 2, 3, 5, 8, 13", item.Title, *item.Points)
			}
			if r := strings.TrimSpace(item.EstimateRationale); r != "" {
				p.EstimateRationale = &r
			}
			if item.AgentID != "" {
				id, err := parseUUID("agent_id", item.AgentID)
				if err != nil {
					return nil, err
				}
				p.AgentID = &id
			}
			items = append(items, p)
		}
		p, err := d.Runs.ProposeTickets(ctx, c, items)
		if err != nil {
			return nil, err
		}
		return map[string]any{"planning_id": p.ID, "state": p.State}, nil
	}),
	define("whoami", "Your identity, instructions, scopes, live runs and the tickets assigned to you.", whoami),
	define("next_ticket", "Assigned tickets ready to claim: blockers Done, project active and no live run. Most urgent first.",
		func(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
			q, err := d.Q.ListTickets(ctx, store.ListTicketsParams{WorkspaceID: c.Agent.WorkspaceID, AssigneeAgentID: &c.Agent.ID, Ready: true})
			if err != nil {
				return nil, err
			}
			items := make([]QueueItem, len(q))
			for i, t := range q {
				items[i] = QueueItem{Key: t.Key, Title: t.Title, Status: t.Status, Priority: t.Priority}
			}
			return map[string]any{"queue": items}, nil
		}),
	define("claim_ticket", "Start (or reconnect to) a run on a ticket assigned to you. Returns your scopes and the ticket (same as get_ticket), so you don't need get_ticket.", claim),
	define("get_ticket", "A ticket: description, numbered acceptance criteria, estimate, the parent epic with its numbered criteria, attached artifacts and recent comments.", getTicket),
	define("read_artifact", "Read a PRD, spec, ADR, report or UI mockup (SVG) attached to a ticket, optionally one section. Reads are recorded as citations.", readArtifact),
	define("post_plan", "Post (or replace) your execution plan. Do this before editing anything. Step 1 starts current.",
		func(ctx context.Context, d Deps, c agents.Caller, in PlanIn) (any, error) {
			steps, err := d.Runs.PostPlan(ctx, c, in.Ticket, in.Steps)
			if err != nil {
				return nil, err
			}
			return ok(map[string]any{"steps": len(steps)}), nil
		}),
	define("update_step", "Mark a plan step done (the next pending step becomes current automatically), needs_human or failed, or current to jump to a step. One step is current at a time.",
		func(ctx context.Context, d Deps, c agents.Caller, in StepIn) (any, error) {
			r, err := d.Runs.UpdateStep(ctx, c, in.Ticket, in.Step, in.State, in.Note)
			if err != nil {
				return nil, err
			}
			if r.Rollover {
				return map[string]any{"rollover": true, "message": fmt.Sprintf("Step %d is done. Your context is large (%d tokens). "+
					"Commit your work, then end your turn now without calling other tools: you will continue from step %d in a fresh session "+
					"that gets your plan, notes, criteria and commits. If your note is missing something the next step needs, "+
					"call update_step for this step again with a fuller note first.", in.Step, r.ContextTokens, r.Current)}, nil
			}
			if r.Current > 0 {
				return ok(map[string]any{"current": r.Current}), nil
			}
			return ok(nil), nil
		}),
	define("log_event", "Record a timeline event, e.g. kind test_run with {passed, failed, duration_s, command}.",
		func(ctx context.Context, d Deps, c agents.Caller, in LogEventIn) (any, error) {
			return ok(nil), d.Runs.LogEvent(ctx, c, in.Ticket, in.Kind, in.Payload)
		}),
	define("report_usage", "Unmanaged sessions only: add tool calls, tokens and cost for the run card.",
		func(ctx context.Context, d Deps, c agents.Caller, in UsageIn) (any, error) {
			return ok(nil), d.Runs.ReportUsage(ctx, c, in.Ticket, in.ToolCalls, in.InputTokens, in.OutputTokens, in.CostUSD)
		}),
	define("set_branch", "Record the branch you're working on.",
		func(ctx context.Context, d Deps, c agents.Caller, in BranchIn) (any, error) {
			return ok(nil), d.Runs.SetBranch(ctx, c, in.Ticket, in.Branch)
		}),
	define("set_pr", "Record the ticket's pull request once you've opened it.",
		func(ctx context.Context, d Deps, c agents.Caller, in PRIn) (any, error) {
			return ok(nil), d.Runs.SetPR(ctx, c, in.Ticket, in.URL, in.Draft)
		}),
	define("get_prior_attempts", "Earlier runs on your ticket, newest first: how each ended and why, its plan, and the branch its work was saved to. Read it before planning when your ticket was tried before, so you don't repeat a dead end.", getPriorAttempts),
	define("check_criterion", "Tick acceptance criteria once you've verified them; pass ns to tick several in one call.",
		func(ctx context.Context, d Deps, c agents.Caller, in CriterionIn) (any, error) {
			if (in.N != 0) == (len(in.Ns) > 0) {
				return nil, apperr.Invalid("n", "give exactly one of n or ns")
			}
			ns := in.Ns
			if in.N != 0 {
				ns = []int{in.N}
			}
			done := in.Done == nil || *in.Done
			return ok(nil), d.Runs.CheckCriteria(ctx, c, in.Ticket, ns, done)
		}),
	define("estimate_ticket", "Set story points (1, 2, 3, 5, 8 or 13) with a short rationale on your ticket or another open ticket in its project. A person's estimate can't be overwritten: comment instead.", estimateTicket),
	define("check_epic_criterion", "Tick an acceptance criterion of an epic in your ticket's project (numbered as in get_ticket's epic) once you've verified it. Only for agents whose tracker:epics scope is allowed.", checkEpicCriterion),
	define("create_artifact", "Attach a REPORT you wrote (dry-run results, analysis). Agents only create reports.",
		func(ctx context.Context, d Deps, c agents.Caller, in ReportIn) (any, error) {
			a, err := d.Runs.CreateReport(ctx, c, in.Ticket, in.Title, in.Body)
			if err != nil {
				return nil, err
			}
			return ok(map[string]any{"artifact_id": a.ID}), nil
		}),
	define("comment", "Comment on the ticket as yourself. People reply in comments; mention them by name.",
		func(ctx context.Context, d Deps, c agents.Caller, in CommentIn) (any, error) {
			_, err := d.Runs.Comment(ctx, c, in.Ticket, in.Body)
			return ok(nil), err
		}),
	define("search_memory", "Search your memory of this person (or, with about: persona, your own memory as this chat's persona): ranked over titles, tags, summaries and bodies. Returns entries without bodies; open one with read_memory.", searchMemory),
	define("read_memory", "Read one memory entry in full.", readMemory),
	define("save_memory", "Remember something about this person, or with about: persona something about yourself as this chat's persona (identity, traits, history, appearance) or a shared moment (type moment). Updates a near-duplicate entry instead of adding another. Never include secrets (credentials, tokens, passwords): they are refused. Tell the person what you saved.", saveMemory),
	define("update_memory", "Change a memory entry, retire it in favour of a newer one with superseded_by, or move it between the person's memory and your own with move_to.", updateMemory),
	define("forget_memory", "Delete a memory entry for good, e.g. when the person says 'forget that'.", forgetMemory),
	define("search_chats", "Search the person's earlier conversations with you for what was said but never saved to memory: best match first, one snippet per chat. Only your own chats with them unless any_persona; never temporary chats. Open one with read_chat before relying on it.", searchChats),
	define("read_chat", "Read part of an earlier conversation found with search_chats, around the message that matched.", readChat),
	define("search_repositories", "Find repositories in the person’s saved repository and GitHub owner catalogue. Saved sources are discovery shortcuts; explicit owner/repository and GitHub URLs work without saving.", searchRepositories),
	define("use_repository", "Attach and select a GitHub repository in this conversation. Returns its checkout directory and setup command, which you must run before working there. Keeps every other checkout and the conversation history.", useRepository),
	define("set_chat_title", "Name this conversation after the person's first message: a concise title of 2 to 6 words. Does nothing if the person already named it.", setChatTitle),
	define("generate_image", "Try to make an image. Only when the person asks for one and your instructions allow it. The image engine (Codex or Antigravity) attempts it right after your reply and it may fail (e.g. a moderation refusal), so say you're trying, never that it's done. You then get a follow-up turn with the image (or why it failed) to react to. At most 2 per reply; not available in that follow-up.", generateImage),
	define("start_video", "Start a video you'll render with code in this chat's workspace. The chat shows a card that follows its stages; returns the video_id and where the renderer writes its progress, stills, preview frames and the finished file.", startVideo),
	define("update_video", "Move a video on: stage stills once its stills are in place (with the checks you made on them), render as the full render starts, encode once every frame is done.", updateVideo),
	define("finish_video", "Save the finished video once its file is written; Vesper stores it in the chat and the person's Library.", finishVideo),
	define("fail_video", "End a video that can't be finished, with what went wrong and the failing command's log tail. The card keeps the stills and shows the error.", failVideo),
	define("save_file", "Keep a file you made in the person's Library under Files: a script, a zip, a spreadsheet, a CSV. Give its text, or base64 data for a binary, at most 25 MB. Executables and disk images are refused. It is only kept, never run.", saveFile),
	define("start_audio", "Start audio you'll render with code in this chat's workspace (MIDI through a soundfont, a synth script, ffmpeg). The chat shows a card that follows its stages; returns the audio_id and where the renderer writes its progress and the finished file. You can't hear audio: say so, and check numbers instead.", startAudio),
	define("update_audio", "Move audio on: stage render as the renderer starts, check once the file is written (with the numbers you measured on it).", updateAudio),
	define("finish_audio", "Save the finished audio once its file is written; Vesper stores it in the chat and the person's Library.", finishAudio),
	define("fail_audio", "End audio that can't be finished, with what went wrong and the failing command's log tail. The card shows the error.", failAudio),
	define("start_playground", "Start the app you're building in a playground the person opens beside this chat: its processes run from this workspace with fresh services, and keep running after your reply. Calling it again restarts it with what you pass.", startPlayground),
	define("playground_status", "Whether this chat's playground is starting, running, stopped or failed, with what it's doing and, when it failed, why and the end of the output.", playgroundStatus),
	define("stop_playground", "Stop this chat's playground.", stopPlayground),
	define("set_playground_openapi", "Point this chat's playground's API tab at an OpenAPI document in the workspace, such as one you inferred from the code (inferred, with the commit you read).", setPlaygroundOpenAPI),
	define("canvas_create", "Open a canvas beside this chat: a Markdown document (kind text) or an SVG mockup (kind svg) you and the person work on together. Use kind svg for a single screen or component; for several screens, a flow or a diagram, use design_create.", canvasCreate),
	define("canvas_patch", "Change a canvas, as a list of small edits against the version you last read. Refused if the canvas has moved on: read it again and redo your edit.", canvasPatch),
	define("canvas_read", "Read a canvas: its current version, or an earlier one. An SVG canvas comes with the data-vid of each element, which canvas_patch uses. The current version also lists its comment threads.", canvasRead),
	define("canvas_comment", "Comment on a passage or element of a canvas, to flag something for the person. On a text canvas you can include suggested replacement text, which they can apply with one click.", canvasComment),
	define("canvas_reply", "Answer a comment thread on a canvas. Set addressed once you have made the change it asked for.", canvasReply),
	define("design_list", "List the designs in this chat (the person's Designs app): canvas_id, title, pages, frames, current version and how many of your suggestions await their review.", designList),
	define("design_outline", "Start here when working on a design: a compact tree of its pages and nodes ({id, type, name, box, children, child_count}) with the boxes the renderer computed. Read the nodes you will change with design_read before patching.", designOutline),
	define("design_read", "Read nodes of a design in full (node_ids, or a page's top-level nodes): every field, each $token shown as {token, value} for the mode in effect, instance overrides, and the prototype links touching them, plus the design's version for design_patch.", designRead),
	define("design_render", "See a design: a PNG of a node or a whole page (scale 1 to 3), returned as an image with its size. Use it after a large patch has been accepted, and when a layout question needs eyes.", designRender),
	define("design_patch", "Suggest changes to a design as a list of ops against the version you last read, each with a why. By default the person reviews them one by one and the design stays unchanged until they do; wait for their review. If they let you edit directly, the ops apply at once. Refused if the design has moved on or the person paused you. "+patchOpsHelp+".", designPatch),
	define("design_import", "Import a Mermaid flowchart or an SVG into a page of a design. A flowchart becomes a section of shapes, subgraph sections and connectors laid out and routed automatically; an SVG becomes a group of shapes, paths and text where the mapping is clear. Like design_patch, it arrives as one suggestion for the person to review unless they let you edit directly. Text it can't import is refused with the line and the problem, and the design doesn't change; warnings list what was skipped (styling, unsupported SVG).", designImport),
	define("design_comments", "List the comment threads on a design, each anchored to a node (with an optional x, y inside its box), with replies.", designComments),
	define("design_comment", "Comment on a node of a design to flag something for the person, without changing it.", designComment),
	define("design_reply", "Answer a comment thread on a design. Set addressed once you have made the change it asked for.", designReply),
	define("design_create", "Start a design (a multi-screen flow, diagram or wireframe) beside this chat when the person asks for one, or when a mockup spans several screens or states; a single screen belongs in canvas_create kind svg: it opens next to the conversation and you work on it with the design_* tools. Returns its canvas_id; then design_outline it and design_patch in the frames. Starters: blank, mobile-flow, web-flow, diagram, wireframe.", designCreate),
	define("canvas_list", "List this chat's canvases and their current versions.", canvasList),
	define("design_flows", "A design's prototype: its frames and the links between them (hotspot, trigger, transition) as JSON, plus a Mermaid flowchart LR of the flow. Links whose target frame was removed are listed as broken_links.", designFlows),
	define("design_components", "A design's main components ({id, name, page, instances}). Place one with the instantiate op and change per-instance text, fill or visibility with set_overrides; editing the main changes every instance.", designComponents),
	define("design_tokens", "A design's token sets (its own snapshot of tokens.css plus per-design sets), the set in use (tokens_ref), the tokens it uses, and whether tokens.css has changed since the person last synced. Use these $tokens for colours; propose set_token edits only on sets whose source is null.", designTokens),
	define("design_inspect", "A node (usually a frame) as code to build from: target css, tailwind or react (default), with its box, spacing, type styles, the tokens it uses with their values, and its images. Components appear as React components with text overrides as props.", designInspect),
	define("design_link_ticket", "Link a frame (or component) of a design to a ticket, or unlink it. Like design_patch it's a suggestion the person reviews unless they let you edit directly. Runs on a linked ticket receive the frame's PNG and Inspect output.", designLinkTicket),
	define("finance_summary", "The person's finances from their imported bank statements: cash flow per month (money in and out, transfers between their accounts left out), net worth, savings rate, spending by category for a month against the months before, and their accounts. Only in the Finance app's Ask chat.", financeSummary),
	define("finance_query", "Find the person's transactions by month or dates, category, words in the description, direction or account; returns up to 50, newest first, with the count and total of every match. Only in the Finance app's Ask chat.", financeQuery),
	define("finance_recurring", "The person's monthly recurring charges (subscriptions, rent, memberships): the latest amount, price changes and which are new. Only in the Finance app's Ask chat.", financeRecurring),
	define("finance_categorize", "Set a transaction's category when the person says what it is. By default it saves a rule that categorizes this merchant's past and future transactions too; tell them. Only in the Finance app's Ask chat.", financeCategorize),
	define("finance_map_csv", "Map the columns of a CSV the person is importing in the Finance app, when Vesper asks you to. Vesper reads every row with your mapping and refuses it with the first row that doesn't read; fix it and call again. Only in the Finance app's Ask chat.", financeMapCSV),
	define("list_saved_links", "List the pages and videos this person saved to their Library, newest first: what's still to read and what they've finished. Use it when it's useful to bring up something they saved.", listSavedLinks),
	define("search_library", "Find things in the person's Library made with their personas: images, videos, diagrams and saved links, newest first. Shows what each is and where it came from, not its file; their documents aren't searched.", searchLibrary),
	define("read_library_item", "One Library item in full: a saved link's note and summary, and the chat and persona it came from.", readLibraryItem),
	define("save_link", "Save a page or video to the person's reading list in their Library when they ask you to keep it. Vesper doesn't open the page: give its title and why it's worth reading.", saveLink),
	define("list_inbox", "What needs the person: the open items in their Inbox (approvals, agents' questions, reviews, blocked runs, mockups, suggestions, scheduled results), newest first, with how many are unread. Read-only: they decide each item on its own card, and reading here doesn't mark anything read.", listInbox),
	define("submit_findings", "Report what you found: specific claims, each with the pages that support it. Call it as you go; it adds to what you've already sent.", submitFindings),
	define("list_workflows", "List the person's workflows, drafts included: id, name, description and whether each is published.", listWorkflows),
	define("read_workflow", "Read a workflow's current draft graph before proposing a change to it.", readWorkflow),
	define("propose_workflow_edit", "Suggest a new workflow or a change to a draft: a list of graph edits the person reviews and applies in the editor. Omit workflow_id and give a name to start a new one. Refused with the reasons if the result wouldn't be a valid workflow.", proposeWorkflowEdit),
	define("submit_workflow_output", "Submit this workflow step's finished result. Only in a workflow step.", submitWorkflowOutput),
	define("submit_outline", "Submit the module's outline. Only when building a module. Refused with the reason if it isn't sound; fix it and call again.", submitOutline),
	define("submit_lesson", "Submit one finished lesson with its checks. Only when writing a module. Refused with the reason if it isn't valid; fix it and call again.", submitLesson),
	define("submit_review", "Submit your verdict on lessons you reviewed. Only when reviewing a module.", submitReview),
	define("submit_research_report", "Save the finished research report. Only when Vesper asks you to write one up.", submitResearchReport),
	define("get_video_transcript", "Read the timestamped captions of a YouTube video the person shared, to watch along with them: react to what's actually said. Pass from_seconds/to_seconds for the part they're at.", videoTranscript),
	define("list_connectors", "The person's MCP connectors: name, host, whether each is working (with its last error) and whether you can use it in this chat, plus connectors already proposed here. Check it before propose_connector.", listConnectors),
	define("list_secret_names", "The names of the person's API secrets (never their values): handle, allowed hosts, expiry and whether you can use each in this chat, plus secrets already proposed here. Check it before propose_secret.", listSecretNames),
	proposeConnector,
	proposeSecret,
	define("create_space", "Create a space for the person: a home for their chats on one topic, with instructions every chat there gets. New chats in it start with you. Use it when the person asks for one; tell them you made it and link it.", createSpace),
	define("create_scheduled_task", "Schedule a task that runs on its own (daily, weekly, monthly or cron): you get its instructions as a message each time and the result goes to the person's Inbox. Use it when the person asks for something recurring; confirm the time and time zone, then tell them it's scheduled.", createScheduledTask),
	define("list_scheduled_tasks", "List the person's scheduled tasks: when each runs, whether it's paused, its revision and how its last run went.", listScheduledTasks),
	define("update_scheduled_task", "Change one of the person's scheduled tasks when they ask: rename it, rewrite its instructions, move its time or repeat, or pause and resume it (enabled). Pass the revision from list_scheduled_tasks; what you leave out stays as it is.", updateScheduledTask),
	define("delete_scheduled_task", "Delete one of the person's scheduled tasks for good. Only when they ask; to stop it for a while, pause it with update_scheduled_task instead.", deleteScheduledTask),
	define("create_learning_module", "Start a Guided Learning module on a topic for the person. Vesper drafts an outline for them to approve, then writes lessons with checks; you're its tutor. Use it when the person wants to learn something in depth.", createLearningModule),
	define("list_learning_modules", "List the person's Guided Learning modules: topic, level, state and the lesson they're on.", listLearningModules),
	define("get_learning_progress", "Where the person is in a learning module you tutor: each lesson's progress (complete once every check is right, solid if right first time), the lesson they're on, and checks they've missed and not yet got right.", getLearningProgress),
	define("propose_persona", "Propose a new persona for the person (another voice of their assistant). Only when the person asks for one and your instructions allow it. Nothing is created until the person approves it in the chat; it starts with no coding or image permissions. If you can make images, give it a profile picture with avatar_prompt. Tell the person you proposed it.", proposePersona),
	define("reply_to_run", "Pass the person's answer to a run this chat started that asked them something. Only after they've answered in this chat.", replyToRun),
	define("list_runs", "List ticket runs in every project, newest first: live runs by default, or finished/all. Filter by project, ticket or agent; open one with get_run.", listChatRuns),
	define("get_run", "One ticket run, in any project: state, outcome, plan steps, cost, the sub agent runs it delegated, its latest context size in tokens and its tool output bytes by group (all 0 when the harness doesn't report them, as with Codex), and an efficiency summary from its events: setup wall time, tool calls before the first edit, test commands and their wall time, and (for runs recorded with per-call context) peak context and the call at which it crossed 100k/150k/200k tokens.", getChatRun),
	define("list_epics", "List epics, in every project unless you name one.", listChatEpics),
	define("list_tickets", "List tickets in every active project, most urgent first: the open ones unless you pass status. Filter by project, status, epic, assigned agent or words; open one with get_ticket.", listChatTickets),
	define("list_projects", "List the projects you can read: key, name, repository, and which one is this chat's default.", listChatProjects),
	define("update_ticket", "Edit an existing ticket from this chat: title, description, status (canceling or reopening a canceled ticket always waits for the person), priority, estimate, epic (or remove_from_epic), agent, labels, due date, mockup requirement, acceptance criteria (replace them, or tick_criteria by number), and link the pull request for work you did here (pr_url). Pass the revision from get_ticket. Only when the person asks, or to keep a ticket you're working on in this chat current. Unless the person lets you edit tickets without asking, this proposes the change: they apply or decline it on a card in the chat, so say it's proposed, not done.", updateChatTicket),
	define("comment_ticket", "Comment on a ticket as yourself, linked back to this chat: findings, repro details, corrections. Only when the person asks, or to record what you learned working on it here. Unless the person lets you edit tickets without asking, this proposes the change: they apply or decline it on a card in the chat, so say it's proposed, not done.", commentChatTicket),
	define("update_ticket_blockers", "Add or remove the tickets a ticket waits on: a started run of it queues until every blocker is Done. Returns what it's blocked by afterwards. Refused while the ticket has a live run, or when it would make a cycle. Unless the person lets you edit tickets without asking, this proposes the change: they apply or decline it on a card in the chat, so say it's proposed, not done.", updateTicketBlockers),
	define("get_epic", "One epic: objective, status, mockup requirement, its numbered acceptance criteria and its tickets.", getChatEpic),
	define("update_epic", "Change an epic when the person asks: its mockup requirement, status (open or done; done needs every criterion ticked and every ticket closed), and its acceptance criteria, numbered as in get_epic. Returns the epic afterwards.", updateChatEpic),
	define("create_epic", "Create an epic in the chat's default project unless you pass project.", createChatEpic),
	define("create_ticket", "Open a ticket in the backlog, with its acceptance criteria and any tickets it waits on (blocked_by). From a run it's a follow-up in the run's project; from a chat it goes to the chat's default project unless you pass project.",
		func(ctx context.Context, d Deps, c agents.Caller, in NewTicketIn) (any, error) {
			points, rationale, err := in.estimate()
			if err != nil {
				return nil, err
			}
			criteria, err := criteriaTexts(in.Criteria)
			if err != nil {
				return nil, err
			}
			scope, err := chatScopeFor(ctx, d, c)
			if err != nil {
				return nil, err
			}
			if scope != nil {
				p, err := scope.targetProject(ctx, d, c.Agent.WorkspaceID, in.Project)
				if err != nil {
					return nil, err
				}
				assignee, err := mainAgent(ctx, d, c.Agent.WorkspaceID, in.Agent)
				if err != nil {
					return nil, err
				}
				nt, err := d.Tracker.Create(ctx, c.Agent.WorkspaceID, tracker.AgentActor(c.Agent.ID), tracker.NewTicket{ProjectKey: p.Key, Title: in.Title, DescriptionMd: in.Description, Priority: in.Priority, EpicID: in.EpicID, RequiresMockup: in.RequiresMockup,
					AssigneeAgentID: assignee, EstimatePoints: points, EstimateRationale: rationale, Criteria: criteria, BlockedBy: in.BlockedBy})
				if err != nil {
					return nil, err
				}
				return ok(map[string]any{"ticket": nt.Key}), nil
			}
			if in.Project != "" || in.Agent != "" {
				return nil, apperr.Invalid("project", "a run's follow-up tickets stay in its project, unassigned; project and agent are for chats")
			}
			_, t, err := d.Runs.Active(ctx, d.Q, c, in.Ticket)
			if err != nil {
				return nil, err
			}
			p, err := d.Q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: t.WorkspaceID})
			if err != nil {
				return nil, err
			}
			nt, err := d.Tracker.Create(ctx, t.WorkspaceID, tracker.AgentActor(c.Agent.ID), tracker.NewTicket{
				ProjectKey: p.Key, Title: in.Title, DescriptionMd: in.Description + "\n\nOpened by @" + c.Agent.Handle + " from " + t.Key + ".",
				Priority: in.Priority, EpicID: t.EpicID, RequiresMockup: in.RequiresMockup,
				EstimatePoints: points, EstimateRationale: rationale, Criteria: criteria, BlockedBy: in.BlockedBy,
			})
			if err != nil {
				return nil, err
			}
			return ok(map[string]any{"ticket": nt.Key}), nil
		}),
	define("create_mockup", "Draft or revise a UI mockup as SVG (self-contained: no scripts, no external images). Wireframe the screen at its real size.",
		func(ctx context.Context, d Deps, c agents.Caller, in MockupIn) (any, error) {
			var id *uuid.UUID
			if strings.TrimSpace(in.MockupID) != "" {
				u, err := parseUUID("mockup_id", in.MockupID)
				if err != nil {
					return nil, err
				}
				id = &u
			} else if strings.TrimSpace(in.Title) == "" {
				return nil, apperr.Invalid("title", "is required for a new mockup")
			}
			out, err := d.Runs.CreateMockup(ctx, c, in.Ticket, strings.TrimSpace(in.Title), in.SVG, strings.TrimSpace(in.Note), id)
			if err != nil {
				return nil, err
			}
			res := map[string]any{"artifact_id": out.Artifact.ID, "version": out.Version.Label, "review_state": artifacts.ReviewPending, "state": "created"}
			if out.Waiting {
				res["state"] = "waiting_for_review"
				res["message"] = "A person has been asked to review this version. The run waits for that review even if another mockup is already approved, because this new version needs a decision. End your turn now (managed), or call await_signal to wait for the decision (unmanaged)."
			} else if out.ChildRun {
				res["message"] = "Mockup saved. Delegated runs don't wait: the main agent owns the review of this mockup."
			}
			return res, nil
		}),
	define("request_approval", "Ask a person before using a scope that requires approval. If it returns pending, your turn should end: call wait_for_approval (or stop, if you're managed).",
		func(ctx context.Context, d Deps, c agents.Caller, in ApprovalIn) (any, error) {
			out, err := d.Runs.RequestApproval(ctx, c, in.Ticket, in.Scope, in.Action, in.Detail, in.Risk)
			if err != nil {
				return nil, err
			}
			if out.NotRequired {
				return map[string]any{"state": "not_required", "message": in.Scope + " is allowed for you here; go ahead."}, nil
			}
			msg := "A person has been asked. Call wait_for_approval with this approval_id."
			if _, brokered := brokerFor(in.Scope); brokered {
				msg += " Once approved, call run_gated: Vesper runs the approved action itself."
			}
			return map[string]any{"state": "pending", "approval_id": out.Approval.ID, "message": msg}, nil
		}),
	define("wait_for_approval", "Wait (up to 50s per call) for a person to decide. Repeat while it returns pending.",
		func(ctx context.Context, d Deps, c agents.Caller, in WaitIn) (any, error) {
			id, err := parseUUID("approval_id", in.ApprovalID)
			if err != nil {
				return nil, err
			}
			ap, err := d.Runs.WaitApproval(ctx, c, id, timeoutOf(in.TimeoutS))
			if err != nil {
				return nil, err
			}
			return map[string]any{"state": ap.State, "note": ap.DecisionNote}, nil
		}),
	define("run_gated", "Execute an approved brokered action (e.g. db:migrate). You never see the credential; the result is returned.",
		func(ctx context.Context, d Deps, c agents.Caller, in GatedIn) (any, error) {
			id, err := parseUUID("approval_id", in.ApprovalID)
			if err != nil {
				return nil, err
			}
			res, err := d.Runs.RunGated(ctx, c, in.Ticket, id)
			if err != nil {
				return nil, err
			}
			return res, nil
		}),
	define("await_human", "End your turn until a person replies. A comment mentioning you resumes the run.",
		func(ctx context.Context, d Deps, c agents.Caller, in AwaitHumanIn) (any, error) {
			if err := d.Runs.AwaitHuman(ctx, c, in.Ticket, in.Reason); err != nil {
				return nil, err
			}
			return ok(map[string]any{"message": "Waiting. Unmanaged sessions: call await_signal to wait for the reply."}), nil
		}),
	define("await_signal", "Unmanaged sessions: wait (up to 50s) for a decision, a comment, or a pause/resume/cancel. Pass the returned cursor next time.",
		func(ctx context.Context, d Deps, c agents.Caller, in SignalIn) (any, error) {
			since := time.Time{}
			if in.Since != "" {
				t, err := time.Parse(time.RFC3339Nano, in.Since)
				if err != nil {
					return nil, apperr.Invalid("since", "use the cursor from the previous call")
				}
				since = t
			}
			sig, err := d.Runs.AwaitSignal(ctx, c, in.Ticket, since, timeoutOf(in.TimeoutS))
			if err != nil {
				return nil, err
			}
			comments := make([]map[string]any, len(sig.Comments))
			for i, cm := range sig.Comments {
				comments[i] = map[string]any{"author": cm.Author, "body": cm.BodyMd, "at": cm.CreatedAt}
			}
			decisions := make([]map[string]any, len(sig.Decisions))
			for i, ap := range sig.Decisions {
				decisions[i] = map[string]any{"approval_id": ap.ID, "state": ap.State, "note": ap.DecisionNote}
			}
			mockups := make([]map[string]any, len(sig.MockupReviews))
			for i, rv := range sig.MockupReviews {
				state := ""
				if rv.ReviewState != nil {
					state = *rv.ReviewState
				}
				mockups[i] = map[string]any{"artifact_id": rv.ArtifactID, "title": rv.Title, "version": rv.VersionLabel,
					"state": state, "note": rv.ReviewNote, "reviewed_at": rv.ReviewedAt}
			}
			return map[string]any{"run_state": sig.State, "wait_reason": sig.WaitReason, "comments": comments, "decisions": decisions, "mockup_reviews": mockups,
				"cursor": sig.Cursor.Format(time.RFC3339Nano)}, nil
		}),
	define("search_knowledge", "Search the wiki, agent memory, documents and tickets. Well-linked pages rank higher. For conventions use find_pattern.", searchKnowledge),
	define("find_pattern", "Look up published team conventions (architecture patterns, coding styles) before implementing. Fuzzy: typos and partial words work. Returns ref, title, topic, tags and a one-line summary; open one with read_page(ref). Empty q lists them all.", findPattern),
	define("propose_pattern", "Propose a reusable, general lesson as a pattern: one atomic rule (Go, React, Postgres, Testing, API, Architecture or Process) that applies beyond this codebase. Always allowed; an agent with wiki:write allowed reviews it. Not for run logs or project-specific decisions.", proposePattern),
	define("list_proposed_patterns", "Pattern proposals waiting for review: title, proposer, age. Only for agents whose wiki:write scope is allowed.", listProposedPatterns),
	define("publish_pattern", "Publish a proposed pattern to Patterns/<Topic>/<Title>, optionally with an edited title, topic or body; the proposal is removed. Only for agents whose wiki:write scope is allowed. Fails if that page exists: merge into it with write_note (mode replace) and reject_pattern.", publishPattern),
	define("reject_pattern", "Reject and remove a proposed pattern, giving the reason to relay to the proposer. Only for agents whose wiki:write scope is allowed.", rejectPattern),
	define("read_page", "Read a wiki page or any document by title, path, ADR id or [[Page#Section]]. Lists the page's outgoing [[links]]; reads count as citations.", readPage),
	define("librarian_pass", "Propose links for a folder/tag or all pages, and report orphans and unresolved links. Always creates suggestions; suitable for an existing scheduled task whose final result goes to Needs you.", librarianPass),
	define("daily_note", "Open the person's daily Knowledge note; create it from a template on first use. Imported daily notes are reused.", dailyNote),
	define("import_vault", "Start an Obsidian vault dry run from a chat attachment. Never confirms the import; the person reviews the report.", importVault),
	define("list_pages", "Find pages by folder, tag, property, date or audience. Returns summaries and version IDs; read only the sections you need.", listPages),
	define("page_outline", "Page headings, properties, current version ID and link/review counts, without its body.", pageOutline),
	define("patch_page", "Change a page with 1–100 anchored text replacements against base_version, each with a reason. In a person's chat the page's persona controls decide: a direct page applies them at once for review afterwards, a review-first page keeps them as a suggestion, a paused page refuses. Elsewhere they are always suggestions.", patchPage),
	define("set_properties", "Change property/tag/alias values against base_version, under the same page controls as patch_page. Null deletes a key. Cannot change audience.", setProperties),
	define("create_page", "Create a Knowledge page, optionally using a template or recording a literature source. Private in a person's chat; shared for runs.", createPage),
	define("move_page", "Move or rename one of the person's Knowledge pages: give its new path. Only in a person's chat; applies at once on pages whose persona changes apply directly, and is refused on paused or review-first pages. The old path stays as an alias.", movePage),
	define("move_folder", "Move or rename one of the person's Knowledge folders with every page under it, in one step. Only in a person's chat; moves nothing if any page in it is paused or review-first. Old paths stay as aliases.", moveFolder),
	define("delete_page", "Delete one of the person's Knowledge pages with its history, when they ask. Only in a person's chat; like move_page it applies at once on direct pages and is refused on paused, review-first and agent pages. Links to it become unresolved.", deletePageTool),
	define("delete_folder", "Delete one of the person's Knowledge folders with every page under it, when they ask. Deletes nothing if any page in it is paused or review-first.", deleteFolderTool),
	define("list_page_versions", "A page's published versions, newest first, with who made each and the current one marked.", listPageVersions),
	define("restore_page_version", "Bring back an earlier published version of a page as your new version, against base_version. The page's persona controls decide as for patch_page.", restorePageVersion),
	define("file_capture", "File an inbox capture: move it into folder, or append it to the merge page and delete the capture. Both pages must take persona changes directly.", fileCapture),
	define("attach_file", "Store a file among the person's Knowledge assets (a file they sent in this chat, or base64 data you made, at most 25 MB) and get the ![[embed]] to place in a page with patch_page.", attachFile),
	define("list_page_reviews", "A page's pending suggestions and direct edits awaiting review, with each change and whether it is yours.", listPageReviews),
	define("withdraw_suggestion", "Withdraw your own pending changes on a page: a suggestion is dropped, a direct edit is undone. Only the person accepts changes, and only theirs to reject others'.", withdrawSuggestion),
	define("set_page_controls", "Tighten a page's persona controls: pause persona edits or make them wait for review. Only the person can lift them.", setPageControls),
	define("attach_chat_to_page", "Attach this chat to a page, so it opens beside the page in the Knowledge app.", attachChatToPage),
	define("promote_canvas", "Save a text canvas from this chat to Knowledge as a private page with its history and comments; the canvas is removed. Use it when the person asks to keep a draft.", promoteCanvas),
	define("knowledge_graph", "The person's Knowledge graph as data: pages and the links between them (and unresolved links), optionally under one folder.", knowledgeGraph),
	define("list_imports", "The person's Obsidian vault imports, with each dry run's plan and report.", listImports),
	define("confirm_import", "Confirm a vault dry run the person has reviewed and asked you to apply, with their policy for pages that already exist (skip, replace or keep_both).", confirmImport),
	define("cancel_import", "Cancel a vault import that hasn't been confirmed.", cancelImport),
	define("undo_import", "Undo a finished vault import; refused if the person has since edited a page it wrote.", undoImport),
	define("capture_note", "Capture a fleeting note in the person's Knowledge inbox.", captureNote),
	define("suggest_links", "Find unlinked mentions and related pages; submit chosen changes with patch_page for review.", suggestLinks),
	define("write_note", "Write a wiki note. Under agents/<your handle>/ (always writable) keep only durable lessons that would help a future run on this codebase, not a log of what you did. General, reusable lessons go through propose_pattern; project decisions go in ADR/Architecture notes. Other pages follow your wiki:write scope (allowed edits directly, requires_approval saves a suggestion). Link what it's about with [[…]].", writeNote),
	define("get_backlinks", "What links to a page, document, ticket, epic or agent, with the sentence around each link.", getBacklinks),
	define("list_subagents", "Sub agents you can delegate part of a ticket to with delegate: handle, role, specialty, model and what each may do (can_write, can_run_tests). A sub agent that can't write can't take allowed_paths; ask it for findings in its report. Main agents only.",
		func(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
			subs, err := d.Runs.ListSubagents(ctx, c)
			if err != nil {
				return nil, err
			}
			items := make([]map[string]any, len(subs))
			for i, sa := range subs {
				a := sa.Agent
				item := map[string]any{"handle": a.Handle, "name": a.Name, "role": a.Role, "specialty": a.Specialty}
				if sa.Unavailable != "" {
					item["unavailable"] = sa.Unavailable
				} else {
					scopes := map[string]string{}
					for _, s := range sa.Spec.Scopes {
						scopes[s.Scope] = string(s.Mode)
					}
					item["harness"], item["model"], item["scopes"] = sa.Spec.Harness, sa.Spec.Model, scopes
					item["can_write"] = sa.CanWrite()
					item["can_run_tests"] = sa.Spec.Mode("tests:run") == agentdef.Allowed
				}
				items[i] = item
			}
			return map[string]any{"subagents": items}, nil
		}),
	define("delegate", fmt.Sprintf("Hand a self-contained part of your ticket (implementation, docs, tests) to a sub agent. Commit your work first: a delegated run fails to start if your checkout has uncommitted changes. The sub agent works in its own git worktree on its own branch cut from yours, and the server merges that branch into yours automatically when its checks pass. You can run up to %d delegations in parallel: call delegate once per sub agent in the same turn, each with non-empty allowed_paths that don't overlap (a delegation without disjoint allowed_paths is refused while another is running; delegate sequentially instead). Then end your turn: you're resumed once, when all of them have finished, with a report covering each (summary, checks, merge result). Unmerged work (failed checks, conflicts) stays on its branch for you to inspect and merge. To send fixes back to the same sub agent, pass its earlier run_id as continue_run_id: that keeps its context (same worktree and branch, conversation resumed) instead of starting a fresh agent. Delegating costs a fresh agent startup, a handoff and a verification pass, so keep small or tightly coupled changes (a few lines, one file) to yourself and delegate work that is substantial or needs a specialist. Pass acceptance_criteria, allowed_paths and test_command so the server can check the result for you: you're resumed with those results and a diff summary, and should read the diff only for what they can't judge. For a review by a sub agent that can write, pass allowed_paths limited to test files (e.g. *_test.go) and ask for a failing test per blocking finding (and give it no test_command that runs them): it returns repro_command, the server merges those tests into your branch when they fail, and recheck_review verifies your fix without another review run.", runs.MaxParallelDelegations),
		func(ctx context.Context, d Deps, c agents.Caller, in DelegateIn) (any, error) {
			dg, err := d.Runs.DelegateWithContract(ctx, c, in.Ticket, in.Agent, in.Task, runs.Contract{
				AcceptanceCriteria: in.AcceptanceCriteria, AllowedPaths: in.AllowedPaths, TestCommand: in.TestCommand, ContinueRunID: in.ContinueRunID})
			if err != nil {
				return nil, err
			}
			msg := "@" + dg.Agent.Handle + " is working on it in its own worktree. Delegate any other disjoint parts now, then end your turn: you'll be resumed once, when every delegated run has finished."
			out := map[string]any{"state": "delegated", "agent": dg.Agent.Handle, "run_id": dg.Run.ID}
			if dg.ReadOnly {
				msg += " It can't change files, so it will report findings instead of committing."
				out["read_only"] = true
			}
			out["message"] = msg
			return out, nil
		}),
	define("complete_run", "Finish the run: In Review and Done require all acceptance criteria verified and checked. Implement or delegate remaining work before finishing; use todo only to explicitly hand unfinished work back. Use status=done only when every reviewer/QA sub agent you delegated to completed with verdict=approved. If you were delegated a task, this reports your summary back to the main agent instead and leaves the ticket alone; a reviewer/QA agent sets verdict=approved or changes_requested.",
		func(ctx context.Context, d Deps, c agents.Caller, in CompleteIn) (any, error) {
			return ok(nil), d.Runs.CompleteWithRepro(ctx, c, in.Ticket, in.Outcome, in.Report, in.Status, in.Verdict,
				runs.Repro{Command: in.ReproCommand, CoversAll: in.ReproCoversAll})
		}),
	define("recheck_review", "Verify your fixes for a review without another review run: the server runs that review's repro_command (the failing tests it committed, already merged into your branch) in your checkout. Commit your fix first. Then end your turn: you're resumed with the result. A passing recheck clears the review's changes_requested for Done when the reviewer set repro_covers_all. Main agents only.",
		func(ctx context.Context, d Deps, c agents.Caller, in RecheckReviewIn) (any, error) {
			if err := d.Runs.RecheckReview(ctx, c, in.Ticket, in.RunID); err != nil {
				return nil, err
			}
			return map[string]any{"state": "rechecking", "message": "End your turn; you'll be resumed with the result."}, nil
		}),
}

// ByName indexes Tools.
var ByName = func() map[string]Tool {
	m := map[string]Tool{}
	for _, t := range Tools {
		m[t.Name] = t
	}
	return m
}()

// PublicError is what the agent sees: domain errors verbatim, anything else
// generic (internal details stay in the server log).
func PublicError(err error) (msg string, internal bool) {
	var ve *apperr.ValidationError
	var ce *apperr.ConflictError
	switch {
	case errors.As(err, &ve), errors.As(err, &ce):
		return err.Error(), false
	case errors.Is(err, apperr.ErrNotFound), errors.Is(err, pgx.ErrNoRows):
		return "not found", false
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return "the request was cancelled", false
	}
	return "internal error", true
}

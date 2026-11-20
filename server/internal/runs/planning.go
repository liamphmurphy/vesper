package runs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// PlannerEstimate preserves the planner’s estimate across human edits.
type PlannerEstimate struct {
	Points    *int    `json:"points,omitempty"`
	Rationale *string `json:"rationale,omitempty"`
}

// Proposal is deliberately separate from a ticket. Only a person can accept it.
type Proposal struct {
	PlannerEstimate *PlannerEstimate `json:"planner_estimate,omitempty"`
	Ref             string           `json:"ref,omitempty"`
	DependsOn       []string         `json:"depends_on,omitempty"`
	BlockedBy       []string         `json:"blocked_by,omitempty"`
	Title           string           `json:"title"`
	Description     string           `json:"description"`
	Criteria        []string         `json:"criteria"`
	AgentID         *uuid.UUID       `json:"agent_id,omitempty"`
	RequiresMockup  bool             `json:"requires_mockup,omitempty"`
	// EstimatePoints is copied to the ticket on acceptance, estimated by the planning agent.
	EstimatePoints    *int    `json:"estimate_points,omitempty"`
	EstimateRationale *string `json:"estimate_rationale,omitempty"`
}

type PlanningInput struct {
	Project    string     `json:"project"`
	AgentID    uuid.UUID  `json:"agent_id"`
	Goal       string     `json:"goal"`
	EpicID     *uuid.UUID `json:"epic_id,omitempty"`
	ArtifactID *uuid.UUID `json:"artifact_id,omitempty"`
	// ContextRefs are attached like chat context: resolved in the project at
	// start, delivered to the planner as files when its run starts.
	ContextRefs []ChatContextRef `json:"context_refs,omitempty"`
}

// PlanningRefPath is where the planner finds the i-th (0-based) attached reference.
// Generated from the position, never from the ref, so nothing escapes .lazyagents/context/.
func PlanningRefPath(i int) string {
	return fmt.Sprintf(".lazyagents/context/planning-ref-%d.md", i+1)
}

// planningOptions are the read-only options a harness understands.
func planningOptions() map[string]string {
	return map[string]string{"sandbox": "read-only", "readonly": "true"}
}

// PlanningSpec strips execution capabilities, including project setup and external MCP servers.
func PlanningSpec(r agentdef.Resolved) agentdef.Resolved {
	r.Scopes = []agentdef.ResolvedScope{{Scope: "repo:*", Mode: agentdef.Denied}, {Scope: "tests:run", Mode: agentdef.Denied}}
	r.Setup = []string{}
	r.MCPServers = []agentdef.MCPServer{}
	r.HarnessOptions = planningOptions()
	r.Fallbacks = append([]agentdef.Fallback{}, r.Fallbacks...)
	for i := range r.Fallbacks {
		r.Fallbacks[i].HarnessOptions = planningOptions()
	}
	r.Instructions = "You are a planner. Read the supplied goal, source documents, linked tickets and wiki. Propose a small, actionable set of tickets with acceptance criteria using propose_tickets. Give each a stable ref and suggest depends_on proposal refs or blocked_by existing ticket keys where work must finish first. Do not create tickets, modify files, or execute project work. Read supplied context with file tools or simple read-only shell commands. Calling propose_tickets ends this planning run; a person edits and accepts the draft. Set requires_mockup on tickets that change the UI, so a person approves a mockup before implementation. Estimate each ticket with points on the Fibonacci scale (1, 2, 3, 5, 8, 13) and a one-line estimate_rationale; split anything bigger than 8.\n"
	return r
}

func (s *Service) StartPlanning(ctx context.Context, ws, user uuid.UUID, in PlanningInput) (store.PlanningSession, error) {
	var out store.PlanningSession
	in.Goal = strings.TrimSpace(in.Goal)
	if len([]rune(in.Goal)) > 20000 {
		return out, apperr.Invalid("goal", "must be at most 20000 characters")
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		p, err := q.LockProjectByKey(ctx, store.LockProjectByKeyParams{WorkspaceID: ws, Key: in.Project})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Invalid("project", "unknown project")
		}
		if err != nil {
			return err
		}
		if p.Archived {
			return apperr.Conflict("restore the archived project before starting a plan")
		}
		a, err := q.GetAgent(ctx, store.GetAgentParams{ID: in.AgentID, WorkspaceID: ws})
		if err != nil || a.ArchivedAt != nil {
			return apperr.Invalid("agent_id", "unknown agent")
		}
		if a.Kind == agents.KindAssistant {
			return apperr.Invalid("agent_id", "the Personal Assistant only works in chats; pick a main agent to plan")
		}
		var sourceVersion *uuid.UUID
		source := ""
		if in.EpicID != nil {
			e, err := q.GetEpic(ctx, store.GetEpicParams{ID: *in.EpicID, WorkspaceID: ws})
			if err != nil || e.ProjectID != p.ID {
				return apperr.Invalid("epic_id", "pick an epic in this project")
			}
			if in.Goal == "" {
				in.Goal = "Plan work for " + e.Name
			}
			source += "\nEpic: " + e.Name + "\n" + e.Objective
			tickets, err := q.PlanningEpicTickets(ctx, &e.ID)
			if err != nil {
				return err
			}
			source += "\nExisting linked tickets (use get_ticket to inspect these; avoid duplicate proposals):"
			for _, tk := range tickets {
				source += fmt.Sprintf("\n%s [%s] %s", tk.Key, tk.Status, tk.Title)
			}
		}
		if in.ArtifactID != nil {
			a, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: *in.ArtifactID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
			if err == nil && a.Audience == "private" {
				return apperr.Invalid("artifact_id", "Share the page first")
			}
			if err != nil || (a.ProjectID == nil || *a.ProjectID != p.ID) || (a.Type != "prd" && a.Type != "spec") || a.CurrentVersionID == nil {
				return apperr.Invalid("artifact_id", "pick a markdown PRD or SPEC in this project")
			}
			v, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
			if err != nil {
				return err
			}
			if v.BodyMd == nil {
				return apperr.Invalid("artifact_id", "planning requires a markdown source")
			}
			sourceVersion = a.CurrentVersionID
			source += "\nSource document: " + a.Title + ". Read its pinned version from .lazyagents/planning-source.md before proposing."
			if in.Goal == "" {
				in.Goal = "Plan implementation of " + a.Title
			}
		}
		docs, err := ResolveChatRefs(ctx, q, ws, uuid.Nil, in.ContextRefs)
		if err != nil {
			return err
		}
		refs := make([]ChatContextRef, len(docs))
		if len(docs) > 0 {
			source += "\nThe person attached these references. Read them first:"
		}
		for i, d := range docs {
			refs[i] = d.Ref
			source += fmt.Sprintf("\n- `%s`: %s %q", PlanningRefPath(i), d.Ref.Kind, d.Title)
		}
		rawRefs, err := json.Marshal(refs)
		if err != nil {
			return err
		}
		if in.Goal == "" {
			return apperr.Invalid("goal", "describe the goal")
		}
		resolved, err := agents.ResolveRunnable(ctx, q, ws, a, p.Key)
		if err != nil {
			return err
		}
		resolved = PlanningSpec(resolved)
		if err := resolved.Validate(); err != nil {
			return apperr.Invalid("agent_id", "%s", err.Error())
		}
		raw, _ := json.Marshal(resolved)
		run, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, AgentID: a.ID, Mode: "managed", State: "queued", ResolvedSpec: raw, DefinitionVersionID: a.CurrentDefinitionVersionID, Harness: resolved.Harness, Model: resolved.Model, Purpose: "planning"})
		if err != nil {
			return err
		}
		if err = q.SetRunDispatcher(ctx, store.SetRunDispatcherParams{ID: run.ID, DispatchedByUserID: &user}); err != nil {
			return err
		}
		out, err = q.CreatePlanningSession(ctx, store.CreatePlanningSessionParams{WorkspaceID: ws, ProjectID: p.ID, EpicID: in.EpicID, ArtifactID: in.ArtifactID, SourceVersionID: sourceVersion, Goal: in.Goal, RunID: run.ID, CreatedBy: user, ContextRefs: rawRefs})
		if err != nil {
			return err
		}
		prompt := fmt.Sprintf("Plan %s for project %s. Goal: %s\n%s\nUse search_knowledge and get_ticket to inspect related work before proposing. Finish with propose_tickets({tickets:[{ref,title,description,criteria,points,estimate_rationale,agent_id?,depends_on?,blocked_by?}]}). points is one of 1, 2, 3, 5, 8, 13. Do not claim a ticket or call complete_run. Use unique ref strings for proposals; depends_on lists other proposal refs, and blocked_by lists existing ticket keys. Dependencies must be acyclic. The proposals remain drafts until a person accepts them.", out.ID, p.Key, in.Goal, source)
		if _, err = q.StartTurn(ctx, store.StartTurnParams{RunID: run.ID, Trigger: "start", InputMessage: prompt}); err != nil {
			return err
		}
		return event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "queued", "purpose": "planning", "planning_id": out.ID})
	})
	return out, err
}

func validateProposals(ctx context.Context, q *store.Queries, ws uuid.UUID, items []Proposal) error {
	if len(items) == 0 || len(items) > 50 {
		return apperr.Invalid("proposals", "provide 1–50 tickets")
	}
	for i := range items {
		p := &items[i]
		p.Title = strings.TrimSpace(p.Title)
		if p.Title == "" || len([]rune(p.Title)) > 300 {
			return apperr.Invalid("title", "each title must have 1–300 characters")
		}
		if len(p.Description) > 100000 || len(p.Criteria) > 30 {
			return apperr.Invalid("proposals", "each description is limited to 100000 bytes and 30 criteria")
		}
		criteria := []string{}
		for _, c := range p.Criteria {
			c = strings.TrimSpace(c)
			if c == "" {
				continue
			}
			if len([]rune(c)) > 2000 {
				return apperr.Invalid("criteria", "each criterion must be at most 2000 characters")
			}
			criteria = append(criteria, c)
		}
		p.Criteria = criteria
		if p.EstimateRationale != nil {
			if r := strings.TrimSpace(*p.EstimateRationale); r == "" || p.EstimatePoints == nil {
				p.EstimateRationale = nil
			} else {
				p.EstimateRationale = &r
			}
		}
		if err := tracker.ValidEstimate(p.EstimatePoints, p.EstimateRationale); err != nil {
			return err
		}
		if p.AgentID != nil {
			sa, err := q.GetAgent(ctx, store.GetAgentParams{ID: *p.AgentID, WorkspaceID: ws})
			if err != nil || sa.ArchivedAt != nil {
				return apperr.Invalid("agent_id", "unknown suggested agent")
			}
			if sa.Kind == agents.KindAssistant {
				return apperr.Invalid("agent_id", "@%s is the Personal Assistant; suggest a main agent", sa.Handle)
			}
		}
	}
	refs := map[string]int{}
	for i := range items {
		p := &items[i]
		p.Ref = strings.TrimSpace(p.Ref)
		if p.Ref == "" {
			p.Ref = fmt.Sprintf("ticket-%d", i+1)
		}
		if len(p.Ref) > 100 {
			return apperr.Invalid("ref", "proposal references are limited to 100 bytes")
		}
		if _, ok := refs[p.Ref]; ok {
			return apperr.Invalid("ref", "proposal references must be unique")
		}
		refs[p.Ref] = i
		if len(p.DependsOn)+len(p.BlockedBy) > 50 {
			return apperr.Invalid("depends_on", "use at most 50 dependencies per proposal")
		}
		for j, key := range p.BlockedBy {
			key = strings.ToUpper(strings.TrimSpace(key))
			if _, err := tracker.Get(ctx, q, ws, key); err != nil {
				return apperr.Invalid("blocked_by", "unknown ticket %s", key)
			}
			p.BlockedBy[j] = key
		}
	}
	states := make([]int, len(items))
	var visit func(int) error
	visit = func(i int) error {
		if states[i] == 1 {
			return apperr.Invalid("depends_on", "proposal dependencies contain a cycle")
		}
		if states[i] == 2 {
			return nil
		}
		states[i] = 1
		for _, ref := range items[i].DependsOn {
			j, ok := refs[ref]
			if !ok {
				return apperr.Invalid("depends_on", "unknown proposal reference %s; remove its dependency before dropping a proposal", ref)
			}
			if err := visit(j); err != nil {
				return err
			}
		}
		states[i] = 2
		return nil
	}
	for i := range items {
		if err := visit(i); err != nil {
			return err
		}
	}
	return nil
}

// ProposeTickets can only act on the caller's own managed planning run.
func (s *Service) ProposeTickets(ctx context.Context, c Caller, items []Proposal) (store.PlanningSession, error) {
	var out store.PlanningSession
	if c.RunID == nil {
		return out, apperr.Conflict("proposals require a planning run token")
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		run, err := q.LockRun(ctx, *c.RunID)
		if err != nil {
			return err
		}
		if run.AgentID != c.Agent.ID || run.WorkspaceID != c.Agent.WorkspaceID || run.TicketID != nil || run.State != "running" {
			return apperr.Conflict("this is not a running planning session")
		}
		plan, err := q.PlanningSessionForRun(ctx, run.ID)
		if err != nil {
			return apperr.Conflict("no planning session for this run")
		}
		if plan.State != "planning" {
			return apperr.Conflict("the draft was already submitted")
		}
		if err := validateProposals(ctx, q, run.WorkspaceID, items); err != nil {
			return err
		}
		for i := range items {
			items[i].PlannerEstimate = &PlannerEstimate{Points: items[i].EstimatePoints, Rationale: items[i].EstimateRationale}
		}
		raw, _ := json.Marshal(items)
		out, err = q.UpdatePlanningSession(ctx, store.UpdatePlanningSessionParams{ID: plan.ID, Proposals: raw, State: "review", TicketKeys: []string{}})
		if err != nil {
			return err
		}
		if err = q.SetPlanningProposalCount(ctx, store.SetPlanningProposalCountParams{ID: plan.ID, ProposalCount: int32(len(items))}); err != nil {
			return err
		}
		out.ProposalCount = int32(len(items))
		outcome := "Draft ready for human review"
		if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "completed", Outcome: &outcome}); err != nil {
			return err
		}
		if err = q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
			return err
		}
		if err = event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "completed", "outcome": outcome}); err != nil {
			return err
		}
		return RecomputeAgentStatus(ctx, q, run.AgentID)
	})
	return out, err
}

// ReviewPlanning atomically saves, accepts or dismisses a draft. Revision guards
// prevent overwriting another reviewer's edits, including double acceptance.
func (s *Service) ReviewPlanning(ctx context.Context, ws, user, id uuid.UUID, revision int32, action string, items []Proposal) (store.PlanningSession, error) {
	var out store.PlanningSession
	err := s.tx(ctx, func(q *store.Queries) error {
		if action == "accept" {
			if err := q.LockDependencyGraph(ctx, ws); err != nil {
				return err
			}
		}
		plan, err := q.LockPlanningSession(ctx, store.LockPlanningSessionParams{ID: id, WorkspaceID: ws})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		if plan.Revision != revision {
			return apperr.Conflict("the plan changed; reload before saving")
		}
		if plan.State != "review" {
			return apperr.Conflict("only a draft awaiting review can be changed")
		}
		// Trust only the stored baseline, never reviewer-supplied metadata.
		var stored []Proposal
		_ = json.Unmarshal(plan.Proposals, &stored)
		proposed := map[string]*PlannerEstimate{}
		for _, sp := range stored {
			baseline := sp.PlannerEstimate
			if baseline == nil {
				baseline = &PlannerEstimate{Points: sp.EstimatePoints, Rationale: sp.EstimateRationale}
			}
			proposed[sp.Ref] = baseline
		}
		for i := range items {
			items[i].PlannerEstimate = proposed[items[i].Ref]
			if items[i].PlannerEstimate == nil {
				items[i].PlannerEstimate = &PlannerEstimate{}
			}
		}
		state := "review"
		keys := []string{}
		if action == "dismiss" {
			state = "dismissed"
			_ = json.Unmarshal(plan.Proposals, &items)
		} else {
			if action != "save" && action != "accept" {
				return apperr.Invalid("action", "must be save, accept or dismiss")
			}
			if err := validateProposals(ctx, q, ws, items); err != nil {
				return err
			}
			if action == "accept" {
				state = "accepted"
				p, err := q.GetProject(ctx, store.GetProjectParams{ID: plan.ProjectID, WorkspaceID: ws})
				if err != nil {
					return err
				}
				// Create the grouping only on acceptance, in the ticket transaction.
				// Plans for existing epics extend that epic instead.
				if plan.EpicID == nil {
					name := []rune(plan.Goal)
					if len(name) > 120 {
						name = append(name[:119], '…')
					}
					epic, err := q.CreateEpic(ctx, store.CreateEpicParams{
						WorkspaceID: ws, ProjectID: plan.ProjectID, Name: string(name),
						Objective: plan.Goal, OwnerUserID: &user, Health: "on_track",
					})
					if err != nil {
						return err
					}
					plan.EpicID = &epic.ID
					if err := q.SetPlanningSessionEpic(ctx, store.SetPlanningSessionEpicParams{ID: plan.ID, EpicID: plan.EpicID}); err != nil {
						return err
					}
				}
				run, err := q.GetRun(ctx, store.GetRunParams{ID: plan.RunID, WorkspaceID: ws})
				if err != nil {
					return err
				}
				// Draft estimates belong to the planning agent that proposed them,
				// unless the reviewer changed them before accepting.
				planner := tracker.AgentActor(run.AgentID)
				created := []store.Ticket{}
				for _, item := range items {
					estimator := tracker.UserActor(user)
					if prev, ok := proposed[item.Ref]; ok && prev.Points != nil && item.EstimatePoints != nil && *prev.Points == *item.EstimatePoints {
						estimator = planner
					}
					t, err := tracker.CreateInTx(ctx, q, ws, tracker.UserActor(user), tracker.NewTicket{ProjectKey: p.Key, Title: item.Title, DescriptionMd: item.Description, Criteria: item.Criteria, AssigneeAgentID: item.AgentID, EpicID: plan.EpicID, RequiresMockup: item.RequiresMockup,
						EstimatePoints: item.EstimatePoints, EstimateRationale: item.EstimateRationale, EstimatedBy: &estimator})
					if err != nil {
						return err
					}
					if plan.ArtifactID != nil {
						if err := tracker.AttachArtifactInTx(ctx, q, ws, tracker.UserActor(user), t.Key, *plan.ArtifactID, "context"); err != nil {
							return err
						}
					}

					keys = append(keys, t.Key)
					created = append(created, t)
				}
				byRef := map[string]string{}
				for i, item := range items {
					byRef[item.Ref] = created[i].Key
				}
				for i, item := range items {
					deps := append([]string{}, item.BlockedBy...)
					for _, ref := range item.DependsOn {
						deps = append(deps, byRef[ref])
					}
					if len(deps) > 0 {
						if err := tracker.SetDependenciesInTx(ctx, q, ws, tracker.UserActor(user), created[i], deps); err != nil {
							return err
						}
					}
				}

			}
		}
		raw, _ := json.Marshal(items)
		out, err = q.UpdatePlanningSession(ctx, store.UpdatePlanningSessionParams{ID: plan.ID, Proposals: raw, State: state, TicketKeys: keys})
		return err
	})
	return out, err
}

func runRecord(ctx context.Context, q *store.Queries, ws, ticket uuid.UUID, epic *uuid.UUID, actor tracker.Actor, verb string, payload map[string]any, at *time.Time) error {
	if ticket == uuid.Nil {
		return nil
	}
	return tracker.Record(ctx, q, ws, ticket, epic, actor, verb, payload, at)
}

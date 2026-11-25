package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/broker"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (s *Server) toRun(ctx context.Context, r store.Run) (api.Run, error) {
	out, err := s.toRuns(ctx, r.WorkspaceID, []store.Run{r})
	if err != nil {
		return api.Run{}, err
	}
	return out[0], nil
}

// toRuns builds API run views for rows in ws with batched metadata queries.
func (s *Server) toRuns(ctx context.Context, ws uuid.UUID, rows []store.Run) ([]api.Run, error) {
	if len(rows) == 0 {
		return []api.Run{}, nil
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	runIDs := make([]uuid.UUID, len(rows))
	var topLevelIDs, ticketIDs, planningIDs, researchIDs, learningIDs, workflowIDs, chatIDs []uuid.UUID
	seenTicket := make(map[uuid.UUID]struct{})
	for i, r := range rows {
		runIDs[i] = r.ID
		if r.ParentRunID == nil {
			topLevelIDs = append(topLevelIDs, r.ID)
		}
		if r.TicketID != nil {
			if _, ok := seenTicket[*r.TicketID]; !ok {
				seenTicket[*r.TicketID] = struct{}{}
				ticketIDs = append(ticketIDs, *r.TicketID)
			}
			continue
		}
		switch r.Purpose {
		case "planning":
			planningIDs = append(planningIDs, r.ID)
		case runs.PurposeResearch:
			researchIDs = append(researchIDs, r.ID)
		case runs.PurposeLearning:
			learningIDs = append(learningIDs, r.ID)
		case runs.PurposeWorkflow:
			workflowIDs = append(workflowIDs, r.ID)
		case "chat":
			chatIDs = append(chatIDs, r.ID)
		}
	}

	ticketsByID := make(map[uuid.UUID]store.Ticket, len(ticketIDs))
	if len(ticketIDs) > 0 {
		tickets, err := s.Q.RunsTicketsByIDs(ctx, store.RunsTicketsByIDsParams{WorkspaceID: ws, Ids: ticketIDs})
		if err != nil {
			return nil, err
		}
		for _, t := range tickets {
			ticketsByID[t.ID] = t
		}
	}
	cacheRows, err := s.Q.CacheUsageForRuns(ctx, runIDs)
	if err != nil {
		return nil, err
	}
	cacheByRun := make(map[uuid.UUID]store.CacheUsageForRunsRow, len(cacheRows))
	for _, cr := range cacheRows {
		cacheByRun[cr.RunID] = cr
	}

	childCounts := make(map[uuid.UUID]int, len(topLevelIDs))
	if len(topLevelIDs) > 0 {
		counts, err := s.Q.ChildRunCounts(ctx, topLevelIDs)
		if err != nil {
			return nil, err
		}
		for _, c := range counts {
			childCounts[c.RunID] = int(c.Count)
		}
	}

	planRows, err := s.Q.PlansForRuns(ctx, runIDs)
	if err != nil {
		return nil, err
	}
	plansByRun := make(map[uuid.UUID][]store.PlanStep, len(rows))
	for _, step := range planRows {
		plansByRun[step.RunID] = append(plansByRun[step.RunID], step)
	}

	planningByRun := make(map[uuid.UUID]store.PlanningSession, len(planningIDs))
	if len(planningIDs) > 0 {
		ps, err := s.Q.PlanningSessionsForRuns(ctx, planningIDs)
		if err != nil {
			return nil, err
		}
		for _, p := range ps {
			planningByRun[p.RunID] = p
		}
	}
	researchByRun := make(map[uuid.UUID]store.ResearchRunsMetaRow, len(researchIDs))
	if len(researchIDs) > 0 {
		rs, err := s.Q.ResearchRunsMeta(ctx, researchIDs)
		if err != nil {
			return nil, err
		}
		for _, rm := range rs {
			researchByRun[rm.RunID] = rm
		}
	}
	learningByRun := make(map[uuid.UUID]store.LearningRunsMetaRow, len(learningIDs))
	if len(learningIDs) > 0 {
		ls, err := s.Q.LearningRunsMeta(ctx, learningIDs)
		if err != nil {
			return nil, err
		}
		for _, lm := range ls {
			learningByRun[lm.RunID] = lm
		}
	}
	workflowByRun := make(map[uuid.UUID]store.WorkflowRunsMetaRow, len(workflowIDs))
	if len(workflowIDs) > 0 {
		wsRows, err := s.Q.WorkflowRunsMeta(ctx, workflowIDs)
		if err != nil {
			return nil, err
		}
		for _, wm := range wsRows {
			workflowByRun[wm.RunID] = wm
		}
	}
	chatByRun := make(map[uuid.UUID]store.ChatSessionsOfRunsRow, len(chatIDs))
	if len(chatIDs) > 0 {
		cs, err := s.Q.ChatSessionsOfRuns(ctx, chatIDs)
		if err != nil {
			return nil, err
		}
		for _, cm := range cs {
			chatByRun[cm.RunID] = cm
		}
	}

	// Collect all project IDs resolved above so projects load in one query.
	projectIDForRun := make([]uuid.UUID, len(rows))
	var projectIDs []uuid.UUID
	seenProject := make(map[uuid.UUID]struct{})
	addProjectID := func(i int, pid uuid.UUID) {
		if pid == uuid.Nil {
			return
		}
		projectIDForRun[i] = pid
		if _, ok := seenProject[pid]; !ok {
			seenProject[pid] = struct{}{}
			projectIDs = append(projectIDs, pid)
		}
	}
	for i, r := range rows {
		switch {
		case r.TicketID != nil:
			if t, ok := ticketsByID[*r.TicketID]; ok {
				addProjectID(i, t.ProjectID)
			}
		case r.Purpose == "planning":
			if p, ok := planningByRun[r.ID]; ok {
				addProjectID(i, p.ProjectID)
			}
		case r.Purpose == runs.PurposeResearch:
			if m, ok := researchByRun[r.ID]; ok {
				addProjectID(i, runs.ProjectIDOrNil(m.ProjectID))
			}
		case r.Purpose == runs.PurposeLearning:
			if m, ok := learningByRun[r.ID]; ok {
				addProjectID(i, runs.ProjectIDOrNil(m.ProjectID))
			}
		case r.Purpose == runs.PurposeWorkflow:
			if m, ok := workflowByRun[r.ID]; ok {
				addProjectID(i, runs.ProjectIDOrNil(m.ProjectID))
			}
		case r.Purpose == "chat":
			if m, ok := chatByRun[r.ID]; ok {
				addProjectID(i, runs.ProjectIDOrNil(m.ProjectID))
			}
		}
	}
	projectsByID := make(map[uuid.UUID]store.Project, len(projectIDs))
	if len(projectIDs) > 0 {
		projs, err := s.Q.ProjectsByIDs(ctx, store.ProjectsByIDsParams{WorkspaceID: ws, Ids: projectIDs})
		if err != nil {
			return nil, err
		}
		for _, p := range projs {
			projectsByID[p.ID] = p
		}
	}

	result := make([]api.Run, 0, len(rows))
	for i, r := range rows {
		a, ok := dir.agents[r.AgentID]
		if !ok {
			var err error
			a, err = s.Q.GetAgent(ctx, store.GetAgentParams{ID: r.AgentID, WorkspaceID: r.WorkspaceID})
			if err != nil {
				return nil, err
			}
		}
		var t store.Ticket
		if r.TicketID != nil {
			var ok bool
			t, ok = ticketsByID[*r.TicketID]
			if !ok {
				var err error
				t, err = s.Q.GetTicketByID(ctx, *r.TicketID)
				if err != nil {
					return nil, err
				}
			}
		}
		out := api.Run{
			Id: r.ID, TicketKey: t.Key, Purpose: api.RunPurpose(r.Purpose), Agent: *toAgentRef(a), Mode: api.RunMode(r.Mode), State: api.RunState(r.State),
			Harness: r.Harness, Model: r.Model, Outcome: r.Outcome, StartedAt: r.StartedAt, EndedAt: r.EndedAt,
			ToolCalls: int(r.ToolCalls), InputTokens: r.InputTokens, OutputTokens: r.OutputTokens,
			CostUsd: float32(r.CostUsdMicros) / 1e6, CostSource: r.CostSource,
			SetupMs: r.SetupMs, HarnessMs: r.HarnessMs, ChecksMs: r.ChecksMs,
			Plan: []api.PlanStep{}, Scopes: []string{}, ApprovalScopes: []string{},
		}
		cr := cacheByRun[r.ID]
		cached, uncached, unknown := cacheBreakdown(r.InputTokens, cr.CachedInputTokens, cr.ReportedInputTokens)
		out.CachedInputTokens, out.UncachedInputTokens, out.UnreportedInputTokens = &cached, &uncached, &unknown
		switch {
		case r.TicketID != nil:
			out.WorkTitle = &t.Title
			out.Branch, out.PrUrl, out.PrState = t.Branch, t.PrUrl, t.PrState
			if t.PrNumber != nil {
				n := int(*t.PrNumber)
				out.PrNumber = &n
			}
		case r.Purpose == "planning":
			if p, ok := planningByRun[r.ID]; ok {
				out.PlanningId, out.WorkTitle = &p.ID, &p.Goal
			}
		case r.Purpose == runs.PurposeResearch:
			if m, ok := researchByRun[r.ID]; ok {
				out.ChatId, out.WorkTitle = &m.ChatID, &m.Title
			}
		case r.Purpose == runs.PurposeLearning:
			if m, ok := learningByRun[r.ID]; ok {
				out.WorkTitle = &m.Title
			}
		case r.Purpose == runs.PurposeWorkflow:
			if m, ok := workflowByRun[r.ID]; ok {
				out.ChatId, out.WorkTitle = &m.ChatID, &m.Title
			}
		case r.Purpose == "chat":
			// A chat run without its session (deleted chat) still renders.
			if m, ok := chatByRun[r.ID]; ok {
				out.ChatId, out.WorkTitle = &m.ChatID, &m.Title
			}
		}
		if pid := projectIDForRun[i]; pid != uuid.Nil {
			if p, ok := projectsByID[pid]; ok {
				out.ProjectKey = &p.Key
			}
		}
		if r.ParentRunID == nil {
			c := childCounts[r.ID]
			out.ChildCount = &c
		}
		if r.WaitReason != nil {
			w := api.RunWaitReason(*r.WaitReason)
			out.WaitReason = &w
		}
		out.ParentRunId = r.ParentRunID
		out.SessionId = r.HarnessSessionID
		if r.State == "waiting_for_quota" {
			attempts := int(r.HoldAttempts)
			out.HoldUntil, out.HoldResetKnown, out.HoldAttempts = r.HoldUntil, &r.HoldResetKnown, &attempts
		}
		out.CheckpointBranch, out.CheckpointError = r.CheckpointBranch, r.CheckpointError
		if r.WorkspaceVolume != nil { // the checkout still exists
			out.WorkspacePath = r.WorkspaceHostPath
		}
		if r.DispatchedByUserID != nil {
			if u, ok := dir.users[*r.DispatchedByUserID]; ok {
				out.DispatchedBy = toUserRef(u)
			}
		}
		if spec, err := runs.Spec(r); err == nil {
			for _, sc := range spec.Scopes {
				switch sc.Mode {
				case agentdef.Allowed:
					out.Scopes = append(out.Scopes, sc.Scope)
				case agentdef.RequiresApproval:
					out.ApprovalScopes = append(out.ApprovalScopes, sc.Scope)
				}
			}
		}
		for _, p := range plansByRun[r.ID] {
			out.Plan = append(out.Plan, api.PlanStep{Position: int(p.Position), Text: p.Text, State: api.PlanStepState(p.State)})
		}
		result = append(result, out)
	}
	return result, nil
}

func (s *Server) toApproval(ctx context.Context, ap store.ApprovalRequest, dir actorDirectory) (api.Approval, error) {
	ticketKey := ""
	if ap.TicketID != nil {
		t, err := s.Q.GetTicketByID(ctx, *ap.TicketID)
		if err != nil {
			return api.Approval{}, err
		}
		ticketKey = t.Key
	}
	detail := broker.DetailMap(ap.ActionDetail)
	out := api.Approval{
		Id: ap.ID, RunId: ap.RunID, TicketKey: ticketKey, ChatId: ap.ChatID, Scope: ap.Scope, ActionSummary: ap.ActionSummary,
		ActionDetail: detail, RiskSummary: ap.RiskSummary, State: api.ApprovalState(ap.State),
		DecidedAt: ap.DecidedAt, ExecutedAt: ap.ExecutedAt, CreatedAt: ap.CreatedAt,
	}
	if a, ok := dir.agents[ap.AgentID]; ok {
		out.Agent = *toAgentRef(a)
	}
	if action, ok := broker.For(ap.Scope); ok {
		out.Brokered = true
		preview := action.Describe(detail)
		out.ActionPreview = &preview
	} else if _, ok := detail["tool_name"]; ok {
		preview, _ := json.MarshalIndent(detail, "", "  ")
		text := string(preview)
		out.ActionPreview = &text
	}
	if ap.DecisionNote != "" {
		out.DecisionNote = &ap.DecisionNote
	}
	if ap.DecidedByUserID != nil {
		if u, ok := dir.users[*ap.DecidedByUserID]; ok {
			out.DecidedBy = toUserRef(u)
		}
	}
	if len(ap.Result) > 0 {
		m := map[string]any{}
		_ = json.Unmarshal(ap.Result, &m)
		out.Result = &m
	}
	return out, nil
}

// runParts fills a ticket's latest run and pending approvals.
func (s *Server) runParts(ctx context.Context, ws uuid.UUID, t store.Ticket, out *api.Ticket) error {
	out.Approvals = []api.Approval{}
	r, err := s.Q.LatestRunForTicket(ctx, &t.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	} else if err != nil {
		return err
	}
	run, err := s.toRun(ctx, r)
	if err != nil {
		return err
	}
	out.Run = &run
	pending, err := s.Q.PendingApprovalsForTicket(ctx, t.ID)
	if err != nil || len(pending) == 0 {
		return err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return err
	}
	for _, ap := range pending {
		a, err := s.toApproval(ctx, ap, dir)
		if err != nil {
			return err
		}
		out.Approvals = append(out.Approvals, a)
	}
	return nil
}

func (s *Server) DecideApproval(ctx context.Context, req api.DecideApprovalRequestObject) (api.DecideApprovalResponseObject, error) {
	u, _, ws := me(ctx)
	note := ""
	if req.Body != nil && req.Body.Note != nil {
		note = *req.Body.Note
	}
	if req.Decision != "approve" && req.Decision != "deny" {
		return nil, apperr.Invalid("decision", "must be approve or deny")
	}
	ap, err := s.Runs.Decide(ctx, ws, u.ID, req.Id, req.Decision == "approve", note)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out, err := s.toApproval(ctx, ap, dir)
	return api.DecideApproval200JSONResponse(out), err
}

// readableRun applies the chat's creator boundary to generic run surfaces too.
func (s *Server) readableRun(ctx context.Context, id uuid.UUID) (store.Run, error) {
	u, _, ws := me(ctx)
	r, err := s.Q.GetRun(ctx, store.GetRunParams{ID: id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) {
		return r, apperr.ErrNotFound
	}
	if err != nil {
		return r, err
	}
	if r.Purpose == runs.PurposeResearch {
		owns, err := s.Q.OwnsResearchRun(ctx, store.OwnsResearchRunParams{RunID: r.ID, UserID: u.ID})
		if err != nil {
			return r, err
		}
		if !owns {
			return r, apperr.ErrNotFound
		}
	}
	if r.Purpose == runs.PurposeLearning {
		owns, err := s.Q.OwnsLearningRun(ctx, store.OwnsLearningRunParams{RunID: r.ID, UserID: u.ID})
		if err != nil {
			return r, err
		}
		if !owns {
			return r, apperr.ErrNotFound
		}
	}
	if r.Purpose == runs.PurposeWorkflow {
		owns, err := s.Q.OwnsWorkflowAgentRun(ctx, store.OwnsWorkflowAgentRunParams{AgentRunID: &r.ID, UserID: u.ID})
		if err != nil {
			return r, err
		}
		if !owns {
			return r, apperr.ErrNotFound
		}
	}
	if r.Purpose == "chat" {
		owns, err := s.Q.OwnsChatRun(ctx, store.OwnsChatRunParams{WorkspaceID: ws, Viewer: u.ID, RunID: r.ID})
		if err != nil {
			return r, err
		}
		if !owns {
			return r, apperr.ErrNotFound
		}
	}
	return r, nil
}

func (s *Server) ControlRun(ctx context.Context, req api.ControlRunRequestObject) (api.ControlRunResponseObject, error) {
	u, _, ws := me(ctx)
	if _, err := s.readableRun(ctx, req.Id); err != nil {
		return nil, err
	}
	r, err := s.Runs.SetRunControl(ctx, ws, u.ID, req.Id, string(req.Action))
	if err != nil {
		return nil, err
	}
	out, err := s.toRun(ctx, r)
	return api.ControlRun200JSONResponse(out), err
}

func (s *Server) GetRun(ctx context.Context, req api.GetRunRequestObject) (api.GetRunResponseObject, error) {
	_, _, ws := me(ctx)
	r, err := s.readableRun(ctx, req.Id)
	if err != nil {
		return nil, apperr.ErrNotFound
	}
	run, err := s.toRun(ctx, r)
	if err != nil {
		return nil, err
	}
	out := api.GetRun200JSONResponse{Run: run, Turns: []api.RunTurn{}, Approvals: []api.Approval{}, Events: []api.RunEvent{}, ChildRuns: []api.Run{}}
	children, err := s.Q.ChildRuns(ctx, &r.ID)
	if err != nil {
		return nil, err
	}
	var inWSChildren []store.Run
	for _, child := range children {
		if child.WorkspaceID == ws {
			inWSChildren = append(inWSChildren, child)
		}
	}
	if len(inWSChildren) > 0 {
		out.ChildRuns, err = s.toRuns(ctx, ws, inWSChildren)
		if err != nil {
			return nil, err
		}
	}
	turns, err := s.Q.ListTurns(ctx, r.ID)
	if err != nil {
		return nil, err
	}
	for _, t := range turns {
		rt := api.RunTurn{Seq: int(t.Seq), Trigger: api.RunTurnTrigger(t.Trigger), InputMessage: t.InputMessage, StartedAt: t.StartedAt, EndedAt: t.EndedAt,
			Status: api.RunTurnStatus(t.Status), ProcessStartedAt: t.ProcessStartedAt, HasLog: t.LogKey != nil}
		if len(t.Usage) > 2 {
			u := map[string]any{}
			if json.Unmarshal(t.Usage, &u) == nil {
				rt.Usage = &u
			}
		}
		if t.ExitCode != nil {
			c := int(*t.ExitCode)
			rt.ExitCode = &c
		}
		out.Turns = append(out.Turns, rt)
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	aps, err := s.Q.ListApprovalsForRun(ctx, r.ID)
	if err != nil {
		return nil, err
	}
	for _, ap := range aps {
		a, err := s.toApproval(ctx, ap, dir)
		if err != nil {
			return nil, err
		}
		out.Approvals = append(out.Approvals, a)
	}
	out.Events, err = s.runEvents(ctx, r.ID, req.Params.After, nil)
	if err != nil {
		return nil, err
	}
	jobs, err := s.Q.ListSubagentJobsForRun(ctx, r.ID)
	if err != nil {
		return nil, err
	}
	subJobs := make([]api.SubagentJob, 0, len(jobs))
	for _, j := range jobs {
		subJobs = append(subJobs, api.SubagentJob{
			Id:            j.ID,
			BatchId:       nullableOf(j.BatchID),
			AgentType:     api.SubagentJobAgentType(j.AgentType),
			Role:          j.Role,
			Reason:        j.Reason,
			RequestedTier: j.RequestedTier,
			Tier:          j.Tier,
			Model:         j.Model,
			Effort:        j.Effort,
			Status:        api.SubagentJobStatus(j.Status),
			Prompt:        j.Prompt,
			ResultText:    j.ResultText,
			Error:         j.Error,
			InputTokens:   j.InputTokens,
			OutputTokens:  j.OutputTokens,
			CachedTokens:  j.CachedTokens,
			CostUsd:       nullableOf(j.CostUsd),
			ToolCalls:     int(j.ToolCalls),
			CreatedAt:     j.CreatedAt,
			StartedAt:     nullableOf(j.StartedAt),
			CompletedAt:   nullableOf(j.CompletedAt),
		})
	}
	out.SubagentJobs = &subJobs
	return out, nil
}

func (s *Server) runEvents(ctx context.Context, runID uuid.UUID, after *int64, since *time.Time) ([]api.RunEvent, error) {
	var (
		evs []store.RunEvent
		err error
	)
	switch {
	case after != nil:
		evs, err = s.Q.ListRunEvents(ctx, store.ListRunEventsParams{RunID: runID, Seq: *after})
	case since != nil:
		evs, err = s.Q.ListRunEventsSince(ctx, store.ListRunEventsSinceParams{RunID: runID, At: *since})
	default:
		evs, err = s.Q.ListLatestRunEvents(ctx, runID)
	}
	if err != nil {
		return nil, err
	}
	out := make([]api.RunEvent, 0, len(evs))
	for _, e := range evs {
		m := map[string]any{}
		_ = json.Unmarshal(e.Payload, &m)
		out = append(out, api.RunEvent{Seq: e.Seq, Type: api.RunEventType(e.Type), Payload: m, At: e.At})
	}
	return out, nil
}

func (s *Server) ListRunEvents(ctx context.Context, req api.ListRunEventsRequestObject) (api.ListRunEventsResponseObject, error) {
	r, err := s.readableRun(ctx, req.Id)
	if err != nil {
		return nil, apperr.ErrNotFound
	}
	evs, err := s.runEvents(ctx, r.ID, req.Params.After, req.Params.Since)
	if err != nil {
		return nil, err
	}
	return api.ListRunEvents200JSONResponse{Events: evs}, nil
}

// liveRunStates are the states the Runs index shows by default.
var liveRunStates = []string{"queued", "starting", "running", "waiting", "waiting_for_quota", "paused", "blocked"}

func (s *Server) ListRuns(ctx context.Context, req api.ListRunsRequestObject) (api.ListRunsResponseObject, error) {
	_, _, ws := me(ctx)
	out := api.ListRuns200JSONResponse{Runs: []api.Run{}}
	pr := req.Params
	offset := 0
	if pr.Offset != nil {
		offset = *pr.Offset
	}
	if offset < 0 || offset > 100000 {
		return nil, apperr.Invalid("offset", "must be between 0 and 100000")
	}
	// Personal Assistant chats belong to Chat, not the Runs index.
	arg := store.ListRunsParams{WorkspaceID: ws, States: liveRunStates, Skip: int32(offset), HideChat: true}
	if pr.State != nil {
		switch st := *pr.State; st {
		case api.ListRunsParamsStateLive:
		case api.ListRunsParamsStateAll:
			arg.States = append(append([]string{}, liveRunStates...), "completed", "failed", "cancelled")
		default:
			if !st.Valid() {
				return nil, apperr.Invalid("state", "unknown run state")
			}
			arg.States = []string{string(st)}
		}
	}
	if pr.Purpose != nil {
		if !pr.Purpose.Valid() {
			return nil, apperr.Invalid("purpose", "must be ticket, planning or chat")
		}
		p := string(*pr.Purpose)
		arg.Purpose = &p
	}
	// An unknown agent or project matches nothing rather than failing, so a
	// stale filter in the URL shows an empty table.
	if pr.Agent != nil && *pr.Agent != "" {
		a, err := s.Q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: *pr.Agent})
		if errors.Is(err, pgx.ErrNoRows) {
			return out, nil
		} else if err != nil {
			return nil, err
		}
		arg.AgentID = &a.ID
	}
	if pr.Project != nil && *pr.Project != "" {
		p, err := s.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: *pr.Project})
		if errors.Is(err, pgx.ErrNoRows) {
			return out, nil
		} else if err != nil {
			return nil, err
		}
		arg.ProjectID = &p.ID
	}
	if pr.Ticket != nil && *pr.Ticket != "" {
		t, err := s.Q.GetTicketByKey(ctx, store.GetTicketByKeyParams{WorkspaceID: ws, Key: *pr.Ticket})
		if errors.Is(err, pgx.ErrNoRows) {
			return out, nil
		} else if err != nil {
			return nil, err
		}
		arg.TicketID = &t.ID
	}
	rows, err := s.Q.ListRuns(ctx, arg)
	if err != nil {
		return nil, err
	}
	if len(rows) > 50 {
		out.HasMore, rows = true, rows[:50]
	}
	out.Runs, err = s.toRuns(ctx, ws, rows)
	if err != nil {
		return nil, err
	}
	return out, nil
}

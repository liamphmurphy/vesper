package httpapi

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/oapi-codegen/nullable"
	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

var viewStatuses = map[api.ListTicketsParamsView][]string{
	api.ListTicketsParamsViewActive:     {"todo", "in_progress", "in_review"},
	api.ListTicketsParamsViewBacklog:    {"backlog"},
	api.ListTicketsParamsViewAgentOwned: {"backlog", "todo", "in_progress", "in_review"},
	// Pending approvals also qualify, regardless of ticket status.
	api.ListTicketsParamsViewNeedsHuman: nil,
	api.ListTicketsParamsViewAll:        nil,
}

func (s *Server) ListTickets(ctx context.Context, req api.ListTicketsRequestObject) (api.ListTicketsResponseObject, error) {
	_, _, ws := me(ctx)
	p := req.Params
	view := api.ListTicketsParamsViewActive
	if p.View != nil {
		view = *p.View
	}
	statuses, ok := viewStatuses[view]
	if !ok {
		return nil, &tracker.ValidationError{Field: "view", Msg: "unknown view"}
	}
	empty := api.ListTickets200JSONResponse{Tickets: []api.TicketSummary{}}
	if p.Status != nil {
		st := string(*p.Status)
		if statuses != nil && !contains(statuses, st) {
			return empty, nil // the status falls outside this view
		}
		statuses = []string{st}
	}

	params := store.ListTicketsParams{
		WorkspaceID:    ws,
		Ready:          deref(p.Ready),
		Statuses:       statuses,
		OnlyAgentOwned: view == api.ListTicketsParamsViewAgentOwned,
		NeedsHuman:     view == api.ListTicketsParamsViewNeedsHuman,
		EpicID:         p.Epic,
		LabelID:        p.Label,
	}
	if p.Project != nil && *p.Project != "" {
		proj, err := s.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: *p.Project})
		if err != nil {
			return empty, nil
		}
		params.ProjectID = &proj.ID
	}
	if p.Assignee != nil && *p.Assignee != "" {
		agents, err := s.Q.ListAgents(ctx, ws)
		if err != nil {
			return nil, err
		}
		for _, a := range agents {
			if a.Handle == *p.Assignee {
				params.AssigneeAgentID = &a.ID
			}
		}
		if params.AssigneeAgentID == nil {
			return empty, nil
		}
	}
	if p.Q != nil && strings.TrimSpace(*p.Q) != "" {
		q := strings.TrimSpace(*p.Q)
		params.Q = &q
	}

	rows, err := s.Q.ListTickets(ctx, params)
	if err != nil {
		return nil, err
	}
	ids := make([]uuid.UUID, len(rows))
	var prURLs []string
	for i, r := range rows {
		ids[i] = r.ID
		if r.PrUrl != nil && *r.PrUrl != "" {
			prURLs = append(prURLs, *r.PrUrl)
		}
	}
	labels, err := s.labelsByTicket(ctx, ids)
	if err != nil {
		return nil, err
	}
	feedbackByURL, err := s.prFeedbackByURLs(ctx, ws, prURLs)
	if err != nil {
		return nil, err
	}
	out := api.ListTickets200JSONResponse{Tickets: make([]api.TicketSummary, 0, len(rows))}
	for _, r := range rows {
		pr := toPR(r.PrNumber, r.PrState, nil, nil, nil)
		if pr != nil && r.PrUrl != nil {
			if fb, ok := feedbackByURL[*r.PrUrl]; ok {
				pr.Feedback = toPRFeedback(fb)
			}
		}
		t := api.TicketSummary{
			Id: r.ID, Key: r.Key, ProjectKey: r.ProjectKey, Title: r.Title,
			UnmetDependencies: int(r.UnmetDependencies), Status: api.TicketStatus(r.Status), Priority: api.Priority(r.Priority),
			Labels: labels[r.ID], DueDate: toDate(r.DueDate),
			Pr:            pr,
			CriteriaTotal: int(r.CriteriaTotal), CriteriaDone: int(r.CriteriaDone), UpdatedAt: r.UpdatedAt,
		}
		if r.EstimatePoints != nil {
			v := int(*r.EstimatePoints)
			t.EstimatePoints = &v
		}
		if r.EpicID != nil {
			t.Epic = &api.EpicRef{Id: *r.EpicID, Name: deref(r.EpicName)}
		}
		if r.AgentID != nil {
			t.Assignee = &api.AgentRef{Id: *r.AgentID, Name: deref(r.AgentName), Handle: deref(r.AgentHandle), ColorIndex: int(deref(r.AgentColorIndex))}
		}
		out.Tickets = append(out.Tickets, t)
	}
	return out, nil
}

func (s *Server) labelsByTicket(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID][]api.Label, error) {
	rows, err := s.Q.ListLabelsForTickets(ctx, ids)
	if err != nil {
		return nil, err
	}
	m := make(map[uuid.UUID][]api.Label, len(ids))
	for _, id := range ids {
		m[id] = []api.Label{}
	}
	for _, r := range rows {
		m[r.TicketID] = append(m[r.TicketID], api.Label{Id: r.ID, Name: r.Name, Color: r.Color})
	}
	return m, nil
}

// ticketDetail assembles the full Ticket representation.
func (s *Server) ticketDetail(ctx context.Context, ws uuid.UUID, t store.Ticket) (api.Ticket, error) {
	proj, err := s.Q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: ws})
	if err != nil {
		return api.Ticket{}, err
	}
	out := api.Ticket{
		Id: t.ID, Key: t.Key, Project: toProject(proj), Title: t.Title, DescriptionMd: t.DescriptionMd,
		Status: api.TicketStatus(t.Status), Priority: api.Priority(t.Priority),
		Estimate: t.Estimate, DueDate: toDate(t.DueDate), Branch: t.Branch,
		Pr:        withSync(toPR(t.PrNumber, t.PrState, t.PrUrl, t.PrAdditions, t.PrDeletions), t),
		CreatedAt: t.CreatedAt, UpdatedAt: t.UpdatedAt, RequiresMockup: t.RequiresMockup, EpicReview: t.EpicReview,
	}
	if out.Pr != nil && t.PrUrl != nil && *t.PrUrl != "" {
		if fb, err := s.Q.GetPRFeedback(ctx, store.GetPRFeedbackParams{WorkspaceID: ws, PrUrl: *t.PrUrl}); err == nil {
			out.Pr.Feedback = toPRFeedback(fb)
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return api.Ticket{}, err
		}
	}
	out.Revision = int(t.Revision)
	if t.EstimatePoints != nil {
		v := int(*t.EstimatePoints)
		out.EstimatePoints = &v
	}
	out.EstimateRationale, out.EstimatedAt = t.EstimateRationale, t.EstimatedAt
	if t.EstimatedByType != nil {
		dir, err := s.directory(ctx, ws)
		if err != nil {
			return api.Ticket{}, err
		}
		a := dir.actor(*t.EstimatedByType, t.EstimatedByID)
		out.EstimatedBy = &a
	}
	out.DependencyRevision = int(t.DependencyRevision)
	out.BlockedBy = []api.TicketDependency{}
	out.Blocks = []api.TicketDependency{}
	deps, err := s.Q.TicketDependencies(ctx, t.ID)
	if err != nil {
		return out, err
	}
	for _, d := range deps {
		out.BlockedBy = append(out.BlockedBy, api.TicketDependency{Id: d.ID, Key: d.Key, Title: d.Title, Status: api.TicketStatus(d.Status)})
	}
	dependents, err := s.Q.TicketDependents(ctx, t.ID)
	if err != nil {
		return out, err
	}
	for _, d := range dependents {
		out.Blocks = append(out.Blocks, api.TicketDependency{Id: d.ID, Key: d.Key, Title: d.Title, Status: api.TicketStatus(d.Status)})
	}
	if t.EpicID != nil {
		if e, err := s.Q.GetEpic(ctx, store.GetEpicParams{ID: *t.EpicID, WorkspaceID: ws}); err == nil {
			out.Epic = &api.EpicRef{Id: e.ID, Name: e.Name}
		}
	}
	if t.AssigneeAgentID != nil {
		if a, err := s.Q.GetAgent(ctx, store.GetAgentParams{ID: *t.AssigneeAgentID, WorkspaceID: ws}); err == nil {
			out.Assignee = toAgentRef(a)
		}
	}
	if t.ReviewerUserID != nil {
		if u, err := s.Q.GetUser(ctx, store.GetUserParams{ID: *t.ReviewerUserID, WorkspaceID: ws}); err == nil {
			out.Reviewer = toUserRef(u)
		}
	}
	if t.CreatedByUserID != nil {
		if u, err := s.Q.GetUser(ctx, store.GetUserParams{ID: *t.CreatedByUserID, WorkspaceID: ws}); err == nil {
			out.CreatedBy = toUserRef(u)
		}
	}
	labels, err := s.labelsByTicket(ctx, []uuid.UUID{t.ID})
	if err != nil {
		return api.Ticket{}, err
	}
	out.Labels = labels[t.ID]
	crit, err := s.Q.ListCriteria(ctx, t.ID)
	if err != nil {
		return api.Ticket{}, err
	}
	out.Criteria = make([]api.Criterion, 0, len(crit))
	for _, c := range crit {
		out.Criteria = append(out.Criteria, toCriterion(c))
	}
	if out.Artifacts, err = s.docCards(ctx, ws, t); err != nil {
		return api.Ticket{}, err
	}
	if out.MockupGate, err = s.mockupGate(ctx, t); err != nil {
		return api.Ticket{}, err
	}
	if err := s.runParts(ctx, ws, t, &out); err != nil {
		return api.Ticket{}, err
	}
	return out, nil
}

func (s *Server) reloadTicket(ctx context.Context, ws uuid.UUID, key string) (api.Ticket, error) {
	t, err := tracker.Get(ctx, s.Q, ws, key)
	if err != nil {
		return api.Ticket{}, err
	}
	return s.ticketDetail(ctx, ws, t)
}

func (s *Server) GetTicket(ctx context.Context, req api.GetTicketRequestObject) (api.GetTicketResponseObject, error) {
	_, _, ws := me(ctx)
	t, err := tracker.Get(ctx, s.Q, ws, req.Key)
	if err != nil {
		return nil, err
	}
	d, err := s.ticketDetail(ctx, ws, t)
	return api.GetTicket200JSONResponse(d), err
}

func (s *Server) CreateTicket(ctx context.Context, req api.CreateTicketRequestObject) (api.CreateTicketResponseObject, error) {
	_, actor, ws := me(ctx)
	b := req.Body
	in := tracker.NewTicket{
		ProjectKey: b.ProjectKey, Title: b.Title, DescriptionMd: deref(b.DescriptionMd),
		EpicID: b.EpicId, AssigneeAgentID: b.AssigneeAgentId, ReviewerUserID: b.ReviewerUserId,
		Estimate: b.Estimate, RequiresMockup: deref(b.RequiresMockup),
	}
	if b.Status != nil {
		in.Status = string(*b.Status)
	}
	if b.Priority != nil {
		in.Priority = string(*b.Priority)
	}
	if b.LabelIds != nil {
		in.LabelIDs = *b.LabelIds
	}
	if b.Criteria != nil {
		in.Criteria = *b.Criteria
	}
	if b.DueDate != nil {
		in.DueDate = &b.DueDate.Time
	}
	t, err := s.Tracker.Create(ctx, ws, actor, in)
	if err != nil {
		return nil, err
	}
	d, err := s.ticketDetail(ctx, ws, t)
	return api.CreateTicket201JSONResponse(d), err
}

func optUUID(n nullable.Nullable[openapi_types.UUID]) tracker.Opt[uuid.UUID] {
	if !n.IsSpecified() {
		return tracker.Opt[uuid.UUID]{}
	}
	if n.IsNull() {
		return tracker.Clear[uuid.UUID]()
	}
	return tracker.SetTo(n.MustGet())
}

func toPatch(b api.TicketPatch) tracker.Patch {
	p := tracker.Patch{
		Title: b.Title, DescriptionMd: b.DescriptionMd, Revision: b.Revision,
		EpicID: optUUID(b.EpicId), AssigneeAgentID: optUUID(b.AssigneeAgentId), ReviewerUserID: optUUID(b.ReviewerUserId),
		LabelIDs: b.LabelIds, RequiresMockup: b.RequiresMockup,
	}
	if b.Criteria != nil {
		d := &tracker.CriteriaDraft{}
		for _, c := range b.Criteria.Expected {
			d.Expected = append(d.Expected, tracker.ExpectedCriterion{ID: c.Id, Position: c.Position, Text: c.Text, Done: c.Done})
		}
		for _, c := range b.Criteria.Items {
			d.Items = append(d.Items, tracker.CriterionDraft{ID: c.Id, Text: c.Text, Done: c.Done})
		}
		p.Criteria = d
	}
	if b.Status != nil {
		v := string(*b.Status)
		p.Status = &v
	}
	if b.Priority != nil {
		v := string(*b.Priority)
		p.Priority = &v
	}
	if b.EstimatePoints.IsSpecified() {
		if b.EstimatePoints.IsNull() {
			p.EstimatePoints = tracker.Clear[int]()
		} else {
			p.EstimatePoints = tracker.SetTo(b.EstimatePoints.MustGet())
		}
	}
	if b.Estimate.IsSpecified() {
		if b.Estimate.IsNull() {
			p.Estimate = tracker.Clear[string]()
		} else {
			p.Estimate = tracker.SetTo(b.Estimate.MustGet())
		}
	}
	if b.DueDate.IsSpecified() {
		if b.DueDate.IsNull() {
			p.DueDate = tracker.Clear[time.Time]()
		} else {
			p.DueDate = tracker.SetTo(b.DueDate.MustGet().Time)
		}
	}
	return p
}

func (s *Server) UpdateTicket(ctx context.Context, req api.UpdateTicketRequestObject) (api.UpdateTicketResponseObject, error) {
	_, actor, ws := me(ctx)
	t, err := s.Tracker.Update(ctx, ws, actor, req.Key, toPatch(*req.Body))
	if err != nil {
		return nil, err
	}
	if req.Body.RequiresMockup != nil && !*req.Body.RequiresMockup {
		if err := s.Runs.ReleaseMockupWaiters(ctx, ws, []string{req.Key}, nil, ""); err != nil {
			return nil, err
		}
	}
	d, err := s.ticketDetail(ctx, ws, t)
	return api.UpdateTicket200JSONResponse(d), err
}

func (s *Server) BulkUpdateTickets(ctx context.Context, req api.BulkUpdateTicketsRequestObject) (api.BulkUpdateTicketsResponseObject, error) {
	_, actor, ws := me(ctx)
	n, err := s.Tracker.Bulk(ctx, ws, actor, req.Body.Keys, toPatch(req.Body.Patch), req.Body.AttachArtifactId)
	if err != nil {
		return nil, err
	}
	if req.Body.Patch.RequiresMockup != nil && !*req.Body.Patch.RequiresMockup {
		if err := s.Runs.ReleaseMockupWaiters(ctx, ws, req.Body.Keys, nil, ""); err != nil {
			return nil, err
		}
	}
	return api.BulkUpdateTickets200JSONResponse{Updated: n}, nil
}

func (s *Server) directory(ctx context.Context, ws uuid.UUID) (actorDirectory, error) {
	d := actorDirectory{users: map[[16]byte]store.User{}, agents: map[[16]byte]store.Agent{}}
	users, err := s.Q.ListUsers(ctx, ws)
	if err != nil {
		return d, err
	}
	for _, u := range users {
		d.users[u.ID] = u
	}
	agents, err := s.Q.ListAllAgents(ctx, ws)
	if err != nil {
		return d, err
	}
	for _, a := range agents {
		d.agents[a.ID] = a
	}
	return d, nil
}

func (s *Server) ListTicketActivity(ctx context.Context, req api.ListTicketActivityRequestObject) (api.ListTicketActivityResponseObject, error) {
	_, _, ws := me(ctx)
	t, err := tracker.Get(ctx, s.Q, ws, req.Key)
	if err != nil {
		return nil, err
	}
	evs, err := s.Q.ListTicketActivity(ctx, &t.ID)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := api.ListTicketActivity200JSONResponse{Events: make([]api.ActivityEvent, 0, len(evs))}
	for _, e := range evs {
		out.Events = append(out.Events, dir.event(e))
	}
	return out, nil
}

func (s *Server) CreateComment(ctx context.Context, req api.CreateCommentRequestObject) (api.CreateCommentResponseObject, error) {
	_, actor, ws := me(ctx)
	ev, err := s.Tracker.Comment(ctx, ws, actor, req.Key, tracker.NewComment{BodyMd: req.Body.BodyMd, ParentCommentID: req.Body.ParentCommentId})
	if err != nil {
		return nil, err
	}
	// "@atlas …" resumes a run waiting for a reply (best effort: the comment stands).
	if err := s.Runs.OnHumanComment(ctx, ws, req.Key, req.Body.BodyMd); err != nil {
		s.Log.Warn("resume on comment", "ticket", req.Key, "err", err)
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.CreateComment201JSONResponse(dir.event(ev)), nil
}

func (s *Server) CreateCriterion(ctx context.Context, req api.CreateCriterionRequestObject) (api.CreateCriterionResponseObject, error) {
	_, actor, ws := me(ctx)
	c, err := s.Tracker.AddCriterion(ctx, ws, actor, req.Key, req.Body.Text)
	if err != nil {
		return nil, err
	}
	return api.CreateCriterion201JSONResponse(toCriterion(c)), nil
}

func (s *Server) UpdateCriterion(ctx context.Context, req api.UpdateCriterionRequestObject) (api.UpdateCriterionResponseObject, error) {
	_, actor, ws := me(ctx)
	c, err := s.Tracker.UpdateCriterion(ctx, ws, actor, req.Id, req.Body.Text, req.Body.Done)
	if err != nil {
		return nil, err
	}
	return api.UpdateCriterion200JSONResponse(toCriterion(c)), nil
}

func (s *Server) DeleteCriterion(ctx context.Context, req api.DeleteCriterionRequestObject) (api.DeleteCriterionResponseObject, error) {
	_, actor, ws := me(ctx)
	if err := s.Tracker.DeleteCriterion(ctx, ws, actor, req.Id); err != nil {
		return nil, err
	}
	return api.DeleteCriterion204Response{}, nil
}

func (s *Server) AddressTicketPRFeedback(ctx context.Context, req api.AddressTicketPRFeedbackRequestObject) (api.AddressTicketPRFeedbackResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	run, err := s.Runs.AddressTicketPRFeedback(ctx, ws, u.ID, req.Key, string(req.Body.Mode))
	if err != nil {
		return nil, err
	}
	out, err := s.toRun(ctx, run)
	if err != nil {
		return nil, err
	}
	return api.AddressTicketPRFeedback201JSONResponse(out), nil
}

// me returns the acting user; the localUser middleware guarantees one.
func me(ctx context.Context) (store.User, tracker.Actor, uuid.UUID) {
	u, _ := auth.UserFrom(ctx)
	return u, tracker.UserActor(u.ID), u.WorkspaceID
}

func deref[T any](p *T) T {
	var zero T
	if p == nil {
		return zero
	}
	return *p
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

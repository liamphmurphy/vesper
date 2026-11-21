package httpapi

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (s *Server) GetProjectBoard(ctx context.Context, req api.GetProjectBoardRequestObject) (api.GetProjectBoardResponseObject, error) {
	_, _, ws := me(ctx)
	project, err := s.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: req.Key})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	out := api.Board{Project: toProject(project), Columns: []api.BoardColumn{}}
	if req.Params.Epic != nil {
		e, err := s.Q.GetEpic(ctx, store.GetEpicParams{WorkspaceID: ws, ID: *req.Params.Epic})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		if e.ProjectID != project.ID {
			return nil, apperr.ErrNotFound
		}
		rollups, err := s.epicRollups(ctx, []store.Epic{e})
		if err != nil {
			return nil, err
		}
		criteria, err := s.Tracker.ListEpicCriteria(ctx, ws, e.ID)
		if err != nil {
			return nil, err
		}
		dir, err := s.directory(ctx, ws)
		if err != nil {
			return nil, err
		}
		blockers, err := s.Tracker.EpicBlockers(ctx, ws, e.ID)
		if err != nil {
			return nil, err
		}
		b := &api.BoardEpic{Epic: toEpic(e, rollups[e.ID]), Objective: &e.Objective, Criteria: []api.EpicCriterion{}}
		if rt, err := s.Q.GetEpicReviewTicket(ctx, &e.ID); err == nil {
			w := toWorkTicket(rt)
			b.Review = &w
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		b.DoneBlockers.OpenTickets = blockers.OpenTicketKeys
		if b.DoneBlockers.OpenTickets == nil {
			b.DoneBlockers.OpenTickets = []string{}
		}
		b.DoneBlockers.UncheckedCriteria = []int{}
		for _, p := range blockers.UncheckedPositions {
			b.DoneBlockers.UncheckedCriteria = append(b.DoneBlockers.UncheckedCriteria, int(p))
		}
		for _, c := range criteria {
			b.Criteria = append(b.Criteria, toEpicCriterion(c, dir))
		}
		out.Epic = b
	}
	rows, err := s.Q.BoardTickets(ctx, store.BoardTicketsParams{WorkspaceID: ws, ProjectID: project.ID, EpicID: req.Params.Epic, Assignee: req.Params.Assignee, IncludeCanceled: deref(req.Params.IncludeCanceled)})
	if err != nil {
		return nil, err
	}
	ids := make([]uuid.UUID, 0, len(rows))
	var prURLs []string
	for _, r := range rows {
		ids = append(ids, r.ID)
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
	statuses := []string{"backlog", "todo", "in_progress", "in_review", "done"}
	if deref(req.Params.IncludeCanceled) {
		statuses = append(statuses, "canceled")
	}
	for _, status := range statuses {
		col := api.BoardColumn{Status: api.TicketStatus(status), Cards: []api.TicketSummary{}}
		for _, r := range rows {
			if r.Status != status {
				continue
			}
			col.Count = int(r.ColumnCount)
			col.Points = int(r.ColumnPoints)
			col.Truncated = col.Count > 50 && (status == "done" || status == "canceled")
			pr := toPR(r.PrNumber, r.PrState, nil, nil, nil)
			if pr != nil && r.PrUrl != nil {
				if fb, ok := feedbackByURL[*r.PrUrl]; ok {
					pr.Feedback = toPRFeedback(fb)
				}
			}
			t := api.TicketSummary{Id: r.ID, Key: r.Key, ProjectKey: r.ProjectKey, Title: r.Title, Status: api.TicketStatus(r.Status), Priority: api.Priority(r.Priority), DueDate: toDate(r.DueDate), Pr: pr, UpdatedAt: r.UpdatedAt, Labels: labels[r.ID], UnmetDependencies: int(r.UnmetDependencies), CriteriaTotal: int(r.CriteriaTotal), CriteriaDone: int(r.CriteriaDone)}
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
			col.Cards = append(col.Cards, t)
		}
		out.Columns = append(out.Columns, col)
	}
	return api.GetProjectBoard200JSONResponse(out), nil
}
func (s *Server) ListEpicCriteria(ctx context.Context, req api.ListEpicCriteriaRequestObject) (api.ListEpicCriteriaResponseObject, error) {
	_, _, ws := me(ctx)
	cs, err := s.Tracker.ListEpicCriteria(ctx, ws, req.Id)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := api.ListEpicCriteria200JSONResponse{Criteria: []api.EpicCriterion{}}
	for _, c := range cs {
		out.Criteria = append(out.Criteria, toEpicCriterion(c, dir))
	}
	return out, nil
}
func (s *Server) CreateEpicCriterion(ctx context.Context, req api.CreateEpicCriterionRequestObject) (api.CreateEpicCriterionResponseObject, error) {
	_, _, ws := me(ctx)
	c, err := s.Tracker.CreateEpicCriterion(ctx, ws, req.Id, req.Body.Text)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.CreateEpicCriterion201JSONResponse(toEpicCriterion(c, dir)), nil
}
func (s *Server) UpdateEpicCriterion(ctx context.Context, req api.UpdateEpicCriterionRequestObject) (api.UpdateEpicCriterionResponseObject, error) {
	_, actor, ws := me(ctx)
	c, err := s.Tracker.PatchEpicCriterion(ctx, ws, actor, req.Id, req.Body.Text, req.Body.Done, req.Body.Position)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.UpdateEpicCriterion200JSONResponse(toEpicCriterion(c, dir)), nil
}
func (s *Server) DeleteEpicCriterion(ctx context.Context, req api.DeleteEpicCriterionRequestObject) (api.DeleteEpicCriterionResponseObject, error) {
	_, _, ws := me(ctx)
	if err := s.Tracker.DeleteEpicCriterion(ctx, ws, req.Id); err != nil {
		return nil, err
	}
	return api.DeleteEpicCriterion204Response{}, nil
}

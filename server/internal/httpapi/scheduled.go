package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func toScheduledInput(b api.ScheduledTaskInput) runs.ScheduledTaskInput {
	in := runs.ScheduledTaskInput{Name: b.Name, Kind: string(b.Kind), Instructions: deref(b.Instructions), WorkflowID: b.WorkflowId, PersonaID: b.PersonaId, Project: deref(b.Project), Enabled: b.Enabled}
	if b.Revision != nil {
		in.Revision = int32(*b.Revision)
	}
	if b.ConnectorIds != nil {
		in.ConnectorIDs = *b.ConnectorIds
	}
	if b.CustomAppSlug != nil {
		in.CustomAppSlug = *b.CustomAppSlug
	}
	if b.CustomAppTool != nil {
		in.CustomAppTool = *b.CustomAppTool
	}
	if b.CustomAppArgs != nil {
		in.CustomAppArgs = *b.CustomAppArgs
	}
	in.Schedule = runs.Schedule{Frequency: string(b.Frequency), AtTime: b.AtTime, Timezone: b.Timezone, Cron: deref(b.Cron), MonthDay: 1, Weekdays: []int32{}}
	if b.MonthDay != nil {
		in.Schedule.MonthDay = int32(*b.MonthDay)
	}
	if b.Weekdays != nil {
		for _, d := range *b.Weekdays {
			in.Schedule.Weekdays = append(in.Schedule.Weekdays, int32(d))
		}
	}
	if b.MaxMinutes != nil {
		in.MaxMinutes = int32(*b.MaxMinutes)
	}
	if b.MaxCostMicros != nil {
		in.MaxCostMicros = *b.MaxCostMicros
	}
	return in
}

func (s *Server) toScheduledTasks(ctx context.Context, ws, user uuid.UUID, rows []store.ScheduledTask) ([]api.ScheduledTask, error) {
	recent, err := s.Q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: user})
	if err != nil {
		return nil, err
	}
	projects, err := s.Q.ListProjects(ctx, ws)
	if err != nil {
		return nil, err
	}
	apps, err := s.Q.ListCustomApps(ctx, store.ListCustomAppsParams{WorkspaceID: ws, UserID: user})
	if err != nil {
		return nil, err
	}
	appSlugs := make(map[uuid.UUID]string, len(apps))
	for _, a := range apps {
		appSlugs[a.ID] = a.Slug
	}
	out := make([]api.ScheduledTask, len(rows))
	for i, t := range rows {
		weekdays := make([]int, len(t.Weekdays))
		for j, d := range t.Weekdays {
			weekdays[j] = int(d)
		}
		ids := make([]openapi_types.UUID, len(t.ConnectorIds))
		copy(ids, t.ConnectorIds)
		item := api.ScheduledTask{Id: t.ID, Name: t.Name, Kind: api.ScheduledTaskKind(t.Kind), Instructions: t.Instructions, WorkflowId: t.WorkflowID, PersonaId: t.PersonaID, ConnectorIds: ids,
			Frequency: api.ScheduledTaskFrequency(t.Frequency), Weekdays: weekdays, MonthDay: int(t.MonthDay), AtTime: t.AtTime, Timezone: t.Timezone, Cron: t.Cron, Enabled: t.Enabled,
			MaxMinutes: int(t.MaxMinutes), MaxCostMicros: t.MaxCostMicros, NextRunAt: t.NextRunAt, Revision: int(t.Revision), Runs: []api.ScheduledRun{}, Upcoming: []time.Time{}}
		var appSlug string
		if t.Kind == "custom_app" {
			if t.CustomAppID != nil {
				appSlug = appSlugs[*t.CustomAppID]
				if appSlug != "" {
					s := appSlug
					item.CustomAppSlug = &s
				}
			}
			if t.CustomAppTool != "" {
				tool := t.CustomAppTool
				item.CustomAppTool = &tool
			}
			if len(t.CustomAppArgs) > 0 {
				var args map[string]any
				if json.Unmarshal(t.CustomAppArgs, &args) == nil && args != nil {
					item.CustomAppArgs = &args
				}
			}
		}
		if t.ProjectID != nil {
			for _, p := range projects {
				if p.ID == *t.ProjectID {
					key := p.Key
					item.Project = &key
				}
			}
		}
		if t.NextRunAt != nil {
			sc := runs.Schedule{Frequency: t.Frequency, Weekdays: t.Weekdays, MonthDay: t.MonthDay, AtTime: t.AtTime, Timezone: t.Timezone, Cron: t.Cron}
			item.Upcoming = append(item.Upcoming, *t.NextRunAt)
			if second, err := sc.Next(*t.NextRunAt); err == nil {
				item.Upcoming = append(item.Upcoming, second)
			}
		}
		for _, r := range recent {
			if r.TaskID != t.ID {
				continue
			}
			run := api.ScheduledRun{Id: r.ID, Trigger: api.ScheduledRunTrigger(r.Trigger), State: api.ScheduledRunState(r.State), Summary: r.Summary, Error: r.Error, CostMicros: r.CostMicros, StartedAt: r.StartedAt, FinishedAt: r.FinishedAt}
			if t.Kind == "custom_app" {
				if appSlug != "" {
					href := "/apps/" + appSlug
					run.Href = &href
				}
			} else if r.WorkflowRunID != nil {
				href := "/workflows/runs/" + r.WorkflowRunID.String()
				run.Href = &href
			} else if r.ChatID != nil {
				href := "/chat/" + r.ChatID.String()
				run.Href = &href
			}
			item.Runs = append(item.Runs, run)
		}
		out[i] = item
	}
	return out, nil
}

func (s *Server) oneScheduled(ctx context.Context, t store.ScheduledTask) (api.ScheduledTask, error) {
	rows, err := s.toScheduledTasks(ctx, t.WorkspaceID, t.UserID, []store.ScheduledTask{t})
	if err != nil {
		return api.ScheduledTask{}, err
	}
	return rows[0], nil
}

func (s *Server) ListScheduledTasks(ctx context.Context, _ api.ListScheduledTasksRequestObject) (api.ListScheduledTasksResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListScheduledTasks(ctx, store.ListScheduledTasksParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out, err := s.toScheduledTasks(ctx, ws, u.ID, rows)
	return api.ListScheduledTasks200JSONResponse{Tasks: out}, err
}

func (s *Server) CreateScheduledTask(ctx context.Context, req api.CreateScheduledTaskRequestObject) (api.CreateScheduledTaskResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	t, err := s.Runs.CreateScheduledTask(ctx, ws, u.ID, toScheduledInput(*req.Body))
	if err != nil {
		return nil, err
	}
	out, err := s.oneScheduled(ctx, t)
	return api.CreateScheduledTask200JSONResponse(out), err
}

func (s *Server) UpdateScheduledTask(ctx context.Context, req api.UpdateScheduledTaskRequestObject) (api.UpdateScheduledTaskResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	if req.Body.Revision == nil {
		return nil, apperr.Invalid("revision", "required")
	}
	t, err := s.Runs.UpdateScheduledTask(ctx, ws, u.ID, req.Id, toScheduledInput(*req.Body))
	if err != nil {
		return nil, err
	}
	out, err := s.oneScheduled(ctx, t)
	return api.UpdateScheduledTask200JSONResponse(out), err
}

func (s *Server) DeleteScheduledTask(ctx context.Context, req api.DeleteScheduledTaskRequestObject) (api.DeleteScheduledTaskResponseObject, error) {
	u, _, ws := me(ctx)
	n, err := s.Q.DeleteScheduledTask(ctx, store.DeleteScheduledTaskParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, apperr.ErrNotFound
	}
	return api.DeleteScheduledTask204Response{}, nil
}

func (s *Server) RunScheduledTask(ctx context.Context, req api.RunScheduledTaskRequestObject) (api.RunScheduledTaskResponseObject, error) {
	u, _, ws := me(ctx)
	if err := s.Runs.RunScheduledTaskNow(ctx, ws, u.ID, req.Id); err != nil {
		return nil, err
	}
	t, err := s.Q.GetScheduledTask(ctx, store.GetScheduledTaskParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	out, err := s.oneScheduled(ctx, t)
	return api.RunScheduledTask200JSONResponse(out), err
}

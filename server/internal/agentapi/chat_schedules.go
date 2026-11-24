package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A chat that can schedule a task for the person can also find, change, pause
// and remove one: otherwise a wrong time or a task they've outgrown meant
// sending them to the Scheduled page to fix what the persona set up.

type chatScheduledTask struct {
	ID            uuid.UUID  `json:"task_id"`
	Name          string     `json:"name"`
	Kind          string     `json:"kind"`
	Instructions  string     `json:"instructions,omitempty"`
	CustomAppSlug string     `json:"custom_app_slug,omitempty"`
	CustomAppTool string     `json:"custom_app_tool,omitempty"`
	Frequency     string     `json:"frequency"`
	AtTime        string     `json:"at_time,omitempty"`
	Timezone      string     `json:"timezone"`
	Weekdays      []int32    `json:"weekdays,omitempty"`
	MonthDay      int32      `json:"month_day,omitempty"`
	Cron          string     `json:"cron,omitempty"`
	Enabled       bool       `json:"enabled"`
	NextRunAt     *time.Time `json:"next_run_at,omitempty"`
	Project       string     `json:"project,omitempty"`
	Space         string     `json:"space,omitempty"`
	Revision      int32      `json:"revision"`
	LastRun       *lastRun   `json:"last_run,omitempty"`
}

type lastRun struct {
	State     string    `json:"state"`
	StartedAt time.Time `json:"started_at"`
	Error     string    `json:"error,omitempty"`
}

func toChatScheduledTask(t store.ScheduledTask, project, space, customAppSlug string) chatScheduledTask {
	out := chatScheduledTask{ID: t.ID, Name: t.Name, Kind: t.Kind, Instructions: t.Instructions, CustomAppSlug: customAppSlug, Frequency: t.Frequency, Timezone: t.Timezone, Enabled: t.Enabled,
		NextRunAt: t.NextRunAt, Project: project, Space: space, Revision: t.Revision}
	if t.Kind == "custom_app" {
		out.CustomAppTool = t.CustomAppTool
	}
	switch t.Frequency {
	case "cron":
		out.Cron = t.Cron
	case "weekly":
		out.AtTime, out.Weekdays = t.AtTime, t.Weekdays
	case "monthly":
		out.AtTime, out.MonthDay = t.AtTime, t.MonthDay
	default:
		out.AtTime = t.AtTime
	}
	return out
}

// resolveScheduledSpace maps a space name, project key, or space UUID to an
// active project's (key, name). An empty string explicitly leaves the task
// without a space.
func resolveScheduledSpace(ctx context.Context, d Deps, ws, user uuid.UUID, raw string) (key, name string, err error) {
	ref := strings.TrimSpace(raw)
	if ref == "" {
		return "", "", nil
	}
	projects, err := d.Q.ListProjects(ctx, ws)
	if err != nil {
		return "", "", err
	}
	activeByID := make(map[uuid.UUID]store.Project, len(projects))
	activeBySpace := make(map[uuid.UUID]store.Project, len(projects))
	var byName []store.Project
	var archivedMatch bool
	for _, p := range projects {
		if p.Archived {
			if strings.EqualFold(p.Key, ref) || strings.EqualFold(p.Name, ref) {
				archivedMatch = true
			}
			continue
		}
		activeByID[p.ID] = p
		if p.SpaceID != nil {
			activeBySpace[*p.SpaceID] = p
		}
		if strings.EqualFold(p.Key, ref) {
			return p.Key, p.Name, nil
		}
		if strings.EqualFold(p.Name, ref) {
			byName = append(byName, p)
		}
	}
	if len(byName) == 1 {
		return byName[0].Key, byName[0].Name, nil
	}
	if len(byName) > 1 {
		return "", "", apperr.Invalid("space", "ambiguous space %q; pass its project key instead", ref)
	}

	spaces, err := d.Q.ListChatSpaces(ctx, store.ListChatSpacesParams{WorkspaceID: ws, UserID: user})
	if err != nil {
		return "", "", err
	}
	refID, isUUID := uuid.Parse(ref)
	var matchedSpaces []store.ChatSpace
	for _, sp := range spaces {
		if isUUID == nil && sp.ID == refID {
			matchedSpaces = []store.ChatSpace{sp}
			break
		}
		if strings.EqualFold(sp.Name, ref) {
			matchedSpaces = append(matchedSpaces, sp)
		}
	}
	if len(matchedSpaces) > 1 {
		return "", "", apperr.Invalid("space", "ambiguous space %q; pass its project key instead", ref)
	}
	if len(matchedSpaces) == 1 {
		sp := matchedSpaces[0]
		if p, ok := activeBySpace[sp.ID]; ok {
			return p.Key, p.Name, nil
		}
		if sp.ProjectID != nil {
			if p, ok := activeByID[*sp.ProjectID]; ok {
				return p.Key, p.Name, nil
			}
		}
		return "", "", apperr.Invalid("space", "space %q does not track a project; scheduled tasks attach to spaces that track work", sp.Name)
	}
	if archivedMatch {
		return "", "", apperr.Invalid("space", "space %q is archived", ref)
	}
	return "", "", apperr.Invalid("space", "no space or project %q", ref)
}

// defaultScheduledProject picks the chat's active project when create_scheduled_task
// omits space: the chat's own project first, else the project tracked by its space.
func defaultScheduledProject(ctx context.Context, d Deps, ws uuid.UUID, s *chatScope) (key, name string, err error) {
	if s.ProjectKey != "" {
		p, err := d.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: s.ProjectKey})
		if errors.Is(err, pgx.ErrNoRows) {
			return s.ProjectKey, "", nil
		}
		if err != nil {
			return "", "", err
		}
		if p.Archived {
			return "", "", nil
		}
		return p.Key, p.Name, nil
	}
	if s.SpaceID == nil {
		return "", "", nil
	}
	if p, err := d.Q.GetProjectBySpace(ctx, s.SpaceID); err == nil {
		if !p.Archived {
			return p.Key, p.Name, nil
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return "", "", err
	}
	sp, err := d.Q.GetChatSpace(ctx, store.GetChatSpaceParams{ID: *s.SpaceID, WorkspaceID: ws, UserID: s.UserID})
	if errors.Is(err, pgx.ErrNoRows) || sp.ProjectID == nil {
		return "", "", nil
	}
	if err != nil {
		return "", "", err
	}
	p, err := runs.OptionalProject(ctx, d.Q, ws, sp.ProjectID)
	if err != nil || p.Key == "" || p.Archived {
		return "", "", err
	}
	return p.Key, p.Name, nil
}

func listScheduledTasks(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	s, err := personChatScope(ctx, d, c, "list_scheduled_tasks")
	if err != nil {
		return nil, err
	}
	ws := c.Agent.WorkspaceID
	rows, err := d.Q.ListScheduledTasks(ctx, store.ListScheduledTasksParams{WorkspaceID: ws, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	recent, err := d.Q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	projects, err := d.Q.ListProjects(ctx, ws)
	if err != nil {
		return nil, err
	}
	projByID := make(map[uuid.UUID]store.Project, len(projects))
	for _, p := range projects {
		projByID[p.ID] = p
	}
	apps, err := d.Q.ListCustomApps(ctx, store.ListCustomAppsParams{WorkspaceID: ws, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	appSlugs := make(map[uuid.UUID]string, len(apps))
	for _, a := range apps {
		appSlugs[a.ID] = a.Slug
	}
	out := make([]chatScheduledTask, len(rows))
	for i, t := range rows {
		project, space := "", ""
		if t.ProjectID != nil {
			if p, ok := projByID[*t.ProjectID]; ok {
				project, space = p.Key, p.Name
			}
		}
		appSlug := ""
		if t.CustomAppID != nil {
			appSlug = appSlugs[*t.CustomAppID]
		}
		out[i] = toChatScheduledTask(t, project, space, appSlug)
		// Newest first, so the first run of this task is its latest.
		for _, r := range recent {
			if r.TaskID == t.ID {
				out[i].LastRun = &lastRun{State: r.State, StartedAt: r.StartedAt, Error: r.Error}
				break
			}
		}
	}
	return map[string]any{"tasks": out, "href": "/scheduled"}, nil
}

type UpdateScheduledTaskIn struct {
	TaskID       uuid.UUID `json:"task_id" jsonschema:"Task id from list_scheduled_tasks"`
	Revision     int32     `json:"revision" jsonschema:"The revision from your latest list_scheduled_tasks. A stale one is refused: list again and redo your change"`
	Name         *string   `json:"name,omitempty" jsonschema:"A new name, 1–120 characters"`
	Instructions *string   `json:"instructions,omitempty" jsonschema:"New instructions, for a prompt task: what to do each time, written as the message you'll get"`
	Space        *string   `json:"space,omitempty" jsonschema:"Space name or project key (e.g. Vesper or LAZYAGENTS), or empty string to clear"`
	Enabled      *bool     `json:"enabled,omitempty" jsonschema:"false pauses the task, true resumes it"`
	Frequency    *string   `json:"frequency,omitempty" jsonschema:"daily, weekly, monthly or cron"`
	AtTime       *string   `json:"at_time,omitempty" jsonschema:"Local time as HH:MM, 24-hour; not for cron"`
	Timezone     *string   `json:"timezone,omitempty" jsonschema:"IANA time zone, e.g. America/Los_Angeles"`
	Weekdays     *[]int32  `json:"weekdays,omitempty" jsonschema:"For weekly: days to run, 0 is Sunday"`
	MonthDay     *int32    `json:"month_day,omitempty" jsonschema:"For monthly: day of the month, 1–31"`
	Cron         *string   `json:"cron,omitempty" jsonschema:"For cron: a five-field cron expression"`
}

// updateScheduledTask changes what's given and keeps the rest, including the
// limits and connectors only the person sets in the app.
func updateScheduledTask(ctx context.Context, d Deps, c agents.Caller, in UpdateScheduledTaskIn) (any, error) {
	s, err := personChatScope(ctx, d, c, "update_scheduled_task")
	if err != nil {
		return nil, err
	}
	ws := c.Agent.WorkspaceID
	t, err := d.Q.GetScheduledTask(ctx, store.GetScheduledTaskParams{ID: in.TaskID, WorkspaceID: ws, UserID: s.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Invalid("task_id", "no scheduled task %s", in.TaskID)
	} else if err != nil {
		return nil, err
	}
	if in.Instructions != nil && t.Kind != "prompt" {
		if t.Kind == "custom_app" {
			return nil, apperr.Invalid("instructions", "this task runs a Custom App tool; change the app instead")
		}
		return nil, apperr.Invalid("instructions", "this task runs a workflow; change the workflow instead")
	}
	project, err := runs.OptionalProject(ctx, d.Q, ws, t.ProjectID)
	if err != nil {
		return nil, err
	}
	projectKey, spaceName := project.Key, project.Name
	if in.Space != nil {
		if t.Kind == "custom_app" && strings.TrimSpace(*in.Space) != "" {
			return nil, apperr.Invalid("space", "custom_app tasks do not run in a space")
		}
		projectKey, spaceName, err = resolveScheduledSpace(ctx, d, ws, s.UserID, *in.Space)
		if err != nil {
			return nil, err
		}
	}
	var appSlug string
	var appArgs map[string]any
	if t.Kind == "custom_app" {
		if t.CustomAppID != nil {
			app, err := d.Q.GetCustomAppWithMCPByID(ctx, store.GetCustomAppWithMCPByIDParams{WorkspaceID: ws, UserID: s.UserID, ID: *t.CustomAppID})
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return nil, err
			}
			appSlug = app.Slug
		}
		if len(t.CustomAppArgs) > 0 {
			_ = json.Unmarshal(t.CustomAppArgs, &appArgs)
		}
	}
	next := runs.ScheduledTaskInput{Revision: in.Revision, Name: t.Name, Kind: t.Kind, Instructions: t.Instructions, WorkflowID: t.WorkflowID, PersonaID: t.PersonaID, Project: projectKey,
		ConnectorIDs: t.ConnectorIds, CustomAppSlug: appSlug, CustomAppTool: t.CustomAppTool, CustomAppArgs: appArgs,
		Enabled: t.Enabled, MaxMinutes: t.MaxMinutes, MaxCostMicros: t.MaxCostMicros,
		Schedule: runs.Schedule{Frequency: t.Frequency, Weekdays: t.Weekdays, MonthDay: t.MonthDay, AtTime: t.AtTime, Timezone: t.Timezone, Cron: t.Cron}}
	set := func(dst *string, v *string) {
		if v != nil {
			*dst = *v
		}
	}
	set(&next.Name, in.Name)
	set(&next.Instructions, in.Instructions)
	set(&next.Schedule.Frequency, in.Frequency)
	set(&next.Schedule.AtTime, in.AtTime)
	set(&next.Schedule.Timezone, in.Timezone)
	set(&next.Schedule.Cron, in.Cron)
	if in.Enabled != nil {
		next.Enabled = *in.Enabled
	}
	if in.Weekdays != nil {
		next.Schedule.Weekdays = *in.Weekdays
	}
	if in.MonthDay != nil {
		next.Schedule.MonthDay = *in.MonthDay
	}
	updated, err := d.Runs.UpdateScheduledTask(ctx, ws, s.UserID, t.ID, next)
	if err != nil {
		return nil, err
	}
	return map[string]any{"task": toChatScheduledTask(updated, projectKey, spaceName, appSlug), "href": "/scheduled",
		"tell_the_person": "Changed. Say what's different and when it next runs; they can review it in [Scheduled](/scheduled)."}, nil
}

type DeleteScheduledTaskIn struct {
	TaskID uuid.UUID `json:"task_id" jsonschema:"Task id from list_scheduled_tasks"`
}

func deleteScheduledTask(ctx context.Context, d Deps, c agents.Caller, in DeleteScheduledTaskIn) (any, error) {
	s, err := personChatScope(ctx, d, c, "delete_scheduled_task")
	if err != nil {
		return nil, err
	}
	n, err := d.Q.DeleteScheduledTask(ctx, store.DeleteScheduledTaskParams{ID: in.TaskID, WorkspaceID: c.Agent.WorkspaceID, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, apperr.Invalid("task_id", "no scheduled task %s", in.TaskID)
	}
	return map[string]any{"task_id": in.TaskID, "state": "deleted", "tell_the_person": "Deleted: it won't run again."}, nil
}

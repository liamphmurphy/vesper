package agentapi

import (
	"context"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A chat may set up spaces, scheduled tasks and learning modules for the
// person directly: they're the person's own, need no persona capability, and
// the person can change or delete them from the app. Each defaults to the
// persona answering, so what it sets up keeps its voice.

// maxChatScheduledTasks bounds how many tasks a person may have before a chat
// can't add more, so a confused turn can't fill their schedule.
const maxChatScheduledTasks = 50

// personChatScope is the chat a creating tool works in: a person's chat, not a
// workflow step (which has no persona and no one watching).
func personChatScope(ctx context.Context, d Deps, c agents.Caller, tool string) (*chatScope, error) {
	refuse := apperr.Conflict("%s only works in a chat with a person", tool)
	if c.RunID == nil {
		return nil, refuse
	}
	run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
	if err != nil {
		return nil, err
	}
	if run.Purpose != "chat" {
		return nil, refuse
	}
	return chatScopeFor(ctx, d, c)
}

type ListSpacesIn struct{}

type chatSpaceRow struct {
	ID          uuid.UUID `json:"id"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitempty"`
	Color       string    `json:"color"`
	SpaceMemory bool      `json:"space_memory"`
	Current     bool      `json:"current,omitempty"`
	Href        string    `json:"href"`
}

func listSpaces(ctx context.Context, d Deps, c agents.Caller, _ ListSpacesIn) (any, error) {
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	rows, err := d.Q.ListChatSpaces(ctx, store.ListChatSpacesParams{WorkspaceID: c.Agent.WorkspaceID, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	out := make([]chatSpaceRow, 0, len(rows))
	for _, sp := range rows {
		out = append(out, chatSpaceRow{
			ID:          sp.ID,
			Name:        sp.Name,
			Description: sp.Description,
			Color:       sp.Color,
			SpaceMemory: sp.SpaceMemory,
			Current:     s.SpaceID != nil && sp.ID == *s.SpaceID,
			Href:        "/spaces/" + sp.ID.String(),
		})
	}
	return map[string]any{"spaces": out}, nil
}

type CreateSpaceIn struct {
	Name         string `json:"name" jsonschema:"The space's name, 1–80 characters, e.g. Health"`
	Description  string `json:"description,omitempty" jsonschema:"One line on what it's for, at most 300 characters"`
	Color        string `json:"color,omitempty" jsonschema:"Its tile colour: green (default), amber, red, blue, violet, pink, teal or orange"`
	Instructions string `json:"instructions,omitempty" jsonschema:"Guidance every chat in the space gets, at most 4000 characters, written to the assistant in the second person"`
	SpaceMemory  *bool  `json:"space_memory,omitempty" jsonschema:"Keep what the assistant learns about the person in this space to the space (default true)"`
}

func createSpace(ctx context.Context, d Deps, c agents.Caller, in CreateSpaceIn) (any, error) {
	s, err := personChatScope(ctx, d, c, "create_space")
	if err != nil {
		return nil, err
	}
	si := runs.SpaceInput{Name: &in.Name, Description: &in.Description, Instructions: &in.Instructions, PersonaID: s.PersonaID, SpaceMemory: in.SpaceMemory}
	if in.Color != "" {
		si.Color = &in.Color
	}
	sp, err := d.Runs.CreateSpace(ctx, c.Agent.WorkspaceID, s.UserID, si)
	if err != nil {
		return nil, err
	}
	href := "/spaces/" + sp.ID.String()
	return map[string]any{"space_id": sp.ID, "name": sp.Name, "href": href,
		"tell_the_person": "Created. It's in their Spaces list; new chats there start with you and its instructions. Link it as [" + sp.Name + "](" + href + ")."}, nil
}

type CreateScheduledTaskIn struct {
	Name          string         `json:"name" jsonschema:"A short name, 1–120 characters"`
	Instructions  string         `json:"instructions,omitempty" jsonschema:"For prompt tasks: what to do each time, written as the message you'll get. Nobody watches it run and the result goes to the person's Inbox, so make it self-contained"`
	Space         *string        `json:"space,omitempty" jsonschema:"Optional space name (from list_spaces); defaults to the chat's space when omitted. Pass an empty string for none"`
	CustomAppSlug string         `json:"custom_app_slug,omitempty" jsonschema:"For custom_app tasks: Custom App URL slug with an MCP server (runs without an LLM turn)"`
	CustomAppTool string         `json:"custom_app_tool,omitempty" jsonschema:"For custom_app tasks: MCP tool name exported by that app"`
	CustomAppArgs map[string]any `json:"custom_app_args,omitempty" jsonschema:"Optional JSON object arguments passed to custom_app_tool"`
	Frequency     string         `json:"frequency" jsonschema:"daily, weekly, monthly or cron"`
	AtTime        string         `json:"at_time,omitempty" jsonschema:"Local time as HH:MM, 24-hour (default 09:00); not for cron"`
	Timezone      string         `json:"timezone" jsonschema:"IANA time zone, e.g. America/Los_Angeles. Ask the person if you don't know it"`
	Weekdays      []int32        `json:"weekdays,omitempty" jsonschema:"For weekly: days to run, 0 is Sunday"`
	MonthDay      int32          `json:"month_day,omitempty" jsonschema:"For monthly: day of the month, 1–31 (shorter months use their last day)"`
	Cron          string         `json:"cron,omitempty" jsonschema:"For cron: a five-field cron expression"`
	MaxMinutes    *int32         `json:"max_minutes,omitempty" jsonschema:"Optional per-run time limit in minutes (1–240); omit for unlimited"`
	MaxCostMicros *int64         `json:"max_cost_micros,omitempty" jsonschema:"Optional per-run cost limit in micro-USD; omit for unlimited"`
}

func createScheduledTask(ctx context.Context, d Deps, c agents.Caller, in CreateScheduledTaskIn) (any, error) {
	s, err := personChatScope(ctx, d, c, "create_scheduled_task")
	if err != nil {
		return nil, err
	}
	have, err := d.Q.ListScheduledTasks(ctx, store.ListScheduledTasksParams{WorkspaceID: c.Agent.WorkspaceID, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	if len(have) >= maxChatScheduledTasks {
		return nil, apperr.Conflict("the person already has %d scheduled tasks; ask them to remove some in Scheduled first", len(have))
	}
	sc := runs.Schedule{Frequency: in.Frequency, AtTime: in.AtTime, Timezone: in.Timezone, Cron: in.Cron, Weekdays: in.Weekdays, MonthDay: in.MonthDay}
	if sc.AtTime == "" {
		sc.AtTime = "09:00"
	}
	if sc.Weekdays == nil {
		sc.Weekdays = []int32{}
	}
	if sc.MonthDay == 0 {
		sc.MonthDay = 1
	}
	var taskIn runs.ScheduledTaskInput
	var projectKey, spaceName string
	tell := "Scheduled. It runs on its own with no time or cost cap unless configured, and each result goes to their Inbox; they can pause, set limits, change or delete it in [Scheduled](/scheduled)."
	if strings.TrimSpace(in.CustomAppSlug) != "" || strings.TrimSpace(in.CustomAppTool) != "" {
		if in.Space != nil && strings.TrimSpace(*in.Space) != "" {
			return nil, apperr.Invalid("space", "custom_app tasks do not run in a space")
		}
		taskIn = runs.ScheduledTaskInput{
			Name:          in.Name,
			Kind:          "custom_app",
			CustomAppSlug: in.CustomAppSlug,
			CustomAppTool: in.CustomAppTool,
			CustomAppArgs: in.CustomAppArgs,
			Schedule:      sc,
			Enabled:       true,
			MaxMinutes:    in.MaxMinutes,
		}
		tell = "Scheduled. It runs the Custom App tool directly without an LLM turn and only posts to their Inbox if a run fails; they can pause, change or delete it in [Scheduled](/scheduled)."
	} else {
		if in.Space != nil {
			projectKey, spaceName, err = resolveScheduledSpace(ctx, d, c.Agent.WorkspaceID, s.UserID, *in.Space)
		} else {
			projectKey, spaceName, err = defaultScheduledProject(ctx, d, c.Agent.WorkspaceID, s)
		}
		if err != nil {
			return nil, err
		}
		// A prompt task in the chosen (or chat's) space, answered by this persona, with
		// unlimited time/cost by default (unless explicitly capped) and no connectors.
		taskIn = runs.ScheduledTaskInput{
			Name:          in.Name,
			Kind:          "prompt",
			Instructions:  in.Instructions,
			PersonaID:     s.PersonaID,
			Project:       projectKey,
			Schedule:      sc,
			Enabled:       true,
			MaxMinutes:    in.MaxMinutes,
			MaxCostMicros: in.MaxCostMicros,
		}
	}
	t, err := d.Runs.CreateScheduledTask(ctx, c.Agent.WorkspaceID, s.UserID, taskIn)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"task_id": t.ID, "name": t.Name, "href": "/scheduled", "tell_the_person": tell}
	if projectKey != "" {
		out["project"] = projectKey
	}
	if spaceName != "" {
		out["space"] = spaceName
	}
	if t.NextRunAt != nil {
		out["next_run_at"] = t.NextRunAt
	}
	return out, nil
}

type CreateLearningModuleIn struct {
	Topic         string `json:"topic" jsonschema:"What to learn, at most 200 characters"`
	Goal          string `json:"goal,omitempty" jsonschema:"What the person wants to be able to do afterwards, at most 1000 characters"`
	Level         string `json:"level" jsonschema:"Where they start: new, some or experienced"`
	MinutesBudget int    `json:"minutes_budget,omitempty" jsonschema:"How long they want to spend studying in total, 15–1200 minutes (default 60). Over 480 it's built in parts, each outlined as they near it"`
}

func createLearningModule(ctx context.Context, d Deps, c agents.Caller, in CreateLearningModuleIn) (any, error) {
	s, err := personChatScope(ctx, d, c, "create_learning_module")
	if err != nil {
		return nil, err
	}
	if in.MinutesBudget == 0 {
		in.MinutesBudget = 60
	}
	course, err := d.Runs.StartCourse(ctx, c.Agent.WorkspaceID, s.UserID, runs.CourseInput{Project: s.ProjectKey, Topic: in.Topic, Goal: in.Goal, Level: in.Level, MinutesBudget: in.MinutesBudget, PersonaID: s.PersonaID})
	if err != nil {
		return nil, err
	}
	href := "/learn/" + course.ID.String()
	return map[string]any{"module_id": course.ID, "topic": course.Topic, "state": course.State, "href": href,
		"tell_the_person": "Started. Vesper is drafting an outline now; they review and approve it in [Learn](" + href + ") before the lessons are written. Don't describe the module as ready yet."}, nil
}

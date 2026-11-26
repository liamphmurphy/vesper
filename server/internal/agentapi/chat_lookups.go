package agentapi

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// Tracker lookups for chats: what's in a project and which projects exist,
// so the assistant can answer "what's left in X" and pick keys for a Start
// card without guessing them from a text search.

// openTicketStatuses are the statuses list_tickets shows by default.
var openTicketStatuses = []string{"backlog", "todo", "in_progress", "in_review"}

const (
	listTicketsDefault = 50
	listTicketsMax     = 200
	// boardTicketCap is where ListTickets stops when no project or epic narrows it.
	boardTicketCap = 500
)

type ListTicketsIn struct {
	Project string     `json:"project,omitempty" jsonschema:"Only tickets in this project key, e.g. PAY; default every active project"`
	Status  []string   `json:"status,omitempty" jsonschema:"Only these statuses: backlog, todo, in_progress, in_review, done or canceled; default every open one (all but done and canceled). Pass [\"all\"] for every status"`
	EpicID  *uuid.UUID `json:"epic_id,omitempty" jsonschema:"Only tickets in this epic, id from list_epics"`
	Agent   string     `json:"agent,omitempty" jsonschema:"Only tickets assigned to this persona, by its @handle, e.g. pike"`
	Query   string     `json:"q,omitempty" jsonschema:"Words in the title or description, the start of a key, or a ticket number like 214"`
	Limit   int        `json:"limit,omitempty" jsonschema:"Up to 200, default 50"`
	Offset  int        `json:"offset,omitempty" jsonschema:"Skip this many tickets, to page through more"`
}

// chatTicketRow is a ticket as list_tickets shows it: enough to choose one,
// with get_ticket for the rest.
type chatTicketRow struct {
	Key       string     `json:"key"`
	Title     string     `json:"title"`
	Status    string     `json:"status"`
	Priority  string     `json:"priority"`
	Project   string     `json:"project"`
	EpicID    *uuid.UUID `json:"epic_id,omitempty"`
	Epic      string     `json:"epic,omitempty"`
	Agent     string     `json:"agent,omitempty"`
	Points    *int32     `json:"points,omitempty"`
	Criteria  string     `json:"criteria,omitempty"`
	Blocked   bool       `json:"blocked"`
	PRState   string     `json:"pr_state,omitempty"`
	UpdatedAt string     `json:"updated_at"`
}

func listChatTickets(ctx context.Context, d Deps, c agents.Caller, in ListTicketsIn) (any, error) {
	if _, err := requireChat(ctx, d, c); err != nil {
		return nil, err
	}
	ws := c.Agent.WorkspaceID
	if in.Limit <= 0 {
		in.Limit = listTicketsDefault
	}
	if in.Limit > listTicketsMax {
		return nil, apperr.Invalid("limit", "at most %d", listTicketsMax)
	}
	if in.Offset < 0 || in.Offset > 100000 {
		return nil, apperr.Invalid("offset", "must be between 0 and 100000")
	}
	project, err := projectFilter(ctx, d, ws, in.Project)
	if err != nil {
		return nil, err
	}
	arg := store.ListTicketsParams{WorkspaceID: ws, ProjectID: project, EpicID: in.EpicID}
	switch {
	case len(in.Status) == 0:
		arg.Statuses = openTicketStatuses
	case len(in.Status) == 1 && strings.EqualFold(strings.TrimSpace(in.Status[0]), "all"):
	default:
		for _, st := range in.Status {
			st = strings.ToLower(strings.TrimSpace(st))
			if !slices.Contains(tracker.Statuses, st) {
				return nil, apperr.Invalid("status", "%q isn't a status: use %s, or all", st, strings.Join(tracker.Statuses, ", "))
			}
			arg.Statuses = append(arg.Statuses, st)
		}
	}
	if h := strings.ToLower(strings.TrimPrefix(strings.TrimSpace(in.Agent), "@")); h != "" {
		a, err := d.Q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: h})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.Invalid("agent", "no persona @%s works on tickets or runs", h)
		} else if err != nil {
			return nil, err
		}
		arg.AssigneeAgentID = &a.ID
	}
	if q := strings.TrimSpace(in.Query); q != "" {
		arg.Q = &q
	}
	rows, err := d.Q.ListTickets(ctx, arg)
	if err != nil {
		return nil, err
	}
	total := len(rows)
	rows = rows[min(in.Offset, total):min(in.Offset+in.Limit, total)]
	out := make([]chatTicketRow, len(rows))
	for i, t := range rows {
		out[i] = chatTicketRow{Key: t.Key, Title: t.Title, Status: t.Status, Priority: t.Priority, Project: t.ProjectKey, EpicID: t.EpicID, Epic: strOr(t.EpicName),
			Agent: strOr(t.AgentHandle), Points: t.EstimatePoints, Blocked: t.UnmetDependencies > 0, PRState: strOr(t.PrState), UpdatedAt: t.UpdatedAt.Format(time.RFC3339)}
		if t.CriteriaTotal > 0 {
			out[i].Criteria = fmt.Sprintf("%d/%d", t.CriteriaDone, t.CriteriaTotal)
		}
	}
	res := map[string]any{"tickets": out, "total": total, "has_more": in.Offset+len(out) < total}
	if project == nil && in.EpicID == nil && total == boardTicketCap {
		res["total"] = fmt.Sprintf("at least %d", boardTicketCap)
		res["note"] = "Only the most urgent 500 are listed across every project; pass project or epic_id to see the rest."
	}
	return res, nil
}

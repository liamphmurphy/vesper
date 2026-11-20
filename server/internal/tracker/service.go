package tracker

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/links"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

var (
	Statuses      = []string{"backlog", "todo", "in_progress", "in_review", "done", "canceled"}
	EstimateScale = []int{1, 2, 3, 5, 8, 13}
	Priorities    = []string{"none", "low", "medium", "high", "urgent"}
)

type Service struct {
	Pool *pgxpool.Pool
}

func (s *Service) tx(ctx context.Context, fn func(q *store.Queries) error) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error { return fn(store.New(tx)) })
}

func notFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return ErrNotFound
	}
	return err
}

// Opt distinguishes "leave unchanged" (Set=false) from "clear" (Set, Value=nil).
type Opt[T any] struct {
	Set   bool
	Value *T
}

func SetTo[T any](v T) Opt[T] { return Opt[T]{Set: true, Value: &v} }
func Clear[T any]() Opt[T]    { return Opt[T]{Set: true} }

type NewTicket struct {
	ProjectKey      string
	Title           string
	DescriptionMd   string
	Status          string
	Priority        string
	EpicID          *uuid.UUID
	AssigneeAgentID *uuid.UUID
	ReviewerUserID  *uuid.UUID
	LabelIDs        []uuid.UUID
	Estimate        *string
	DueDate         *time.Time
	Criteria        []string
	// BlockedBy are ticket keys that must be Done before this one starts.
	// Only Create sets them; CreateInTx callers manage the graph lock themselves.
	BlockedBy      []string
	RequiresMockup bool
	// EpicReview marks the epic's final review ticket (server-created only).
	EpicReview bool
	// EstimatePoints (optional) is set right after creation, with
	// EstimateRationale, attributed to EstimatedBy (default: the creating actor).
	EstimatePoints    *int
	EstimateRationale *string
	EstimatedBy       *Actor
	// CreatedAt backdates the "created" event (seeding only).
	CreatedAt *time.Time
}

type Patch struct {
	Revision          *int
	EstimatePoints    Opt[int]
	EstimateRationale *string
	Title             *string
	DescriptionMd     *string
	Status            *string
	Priority          *string
	EpicID            Opt[uuid.UUID]
	AssigneeAgentID   Opt[uuid.UUID]
	ReviewerUserID    Opt[uuid.UUID]
	Estimate          Opt[string]
	DueDate           Opt[time.Time]
	LabelIDs          *[]uuid.UUID
	RequiresMockup    *bool
	// Criteria replaces the ticket's criteria atomically; needs Revision. Not for bulk.
	Criteria *CriteriaDraft
}

func validTitle(t string) (string, error) {
	t = strings.TrimSpace(t)
	if t == "" {
		return "", invalid("title", "is required")
	}
	if len([]rune(t)) > 300 {
		return "", invalid("title", "must be at most 300 characters")
	}
	return t, nil
}

func checkEnum(field, v string, allowed []string) error {
	if !slices.Contains(allowed, v) {
		return invalid(field, "must be one of %s", strings.Join(allowed, ", "))
	}
	return nil
}

// refs validates that referenced records exist in the workspace and returns
// display names for activity payloads.
type refs struct {
	q  *store.Queries
	ws uuid.UUID
}

func (r refs) agent(ctx context.Context, id *uuid.UUID) (store.Agent, error) {
	a, err := r.q.GetAgent(ctx, store.GetAgentParams{ID: *id, WorkspaceID: r.ws})
	if errors.Is(err, pgx.ErrNoRows) {
		return a, invalid("assignee_agent_id", "unknown persona")
	}
	if err == nil && a.ArchivedAt != nil {
		return a, invalid("assignee_agent_id", "@%s no longer works on tickets", a.Handle)
	}
	return a, err
}

// assignee is agent for a ticket's assignee: the work record of a persona that takes
// tickets.
func (r refs) assignee(ctx context.Context, id *uuid.UUID) (store.Agent, error) {
	a, err := r.agent(ctx, id)
	if err == nil && a.Kind == "assistant" {
		return a, invalid("assignee_agent_id", "@%s is the Personal Assistant and can't be assigned tickets; assign a persona that takes tickets", a.Handle)
	}
	return a, err
}

func (r refs) user(ctx context.Context, id *uuid.UUID) (store.User, error) {
	u, err := r.q.GetUser(ctx, store.GetUserParams{ID: *id, WorkspaceID: r.ws})
	if errors.Is(err, pgx.ErrNoRows) {
		return u, invalid("reviewer_user_id", "unknown user")
	}
	return u, err
}

func (r refs) epic(ctx context.Context, id *uuid.UUID, projectID uuid.UUID) (store.Epic, error) {
	e, err := r.q.GetEpic(ctx, store.GetEpicParams{ID: *id, WorkspaceID: r.ws})
	if errors.Is(err, pgx.ErrNoRows) {
		return e, invalid("epic_id", "unknown epic")
	}
	if err == nil && e.ProjectID != projectID {
		return e, invalid("epic_id", "epic belongs to another project")
	}
	return e, err
}

func (r refs) labels(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]store.Label, error) {
	all, err := r.q.ListLabels(ctx, r.ws)
	if err != nil {
		return nil, err
	}
	byID := make(map[uuid.UUID]store.Label, len(all))
	for _, l := range all {
		byID[l.ID] = l
	}
	for _, id := range ids {
		if _, ok := byID[id]; !ok {
			return nil, invalid("label_ids", "unknown label %s", id)
		}
	}
	return byID, nil
}

// Create allocates the next number in the project and records "created".
// BlockedBy is set in the same transaction, so a ticket never exists without
// the blockers it was created with.
func (s *Service) Create(ctx context.Context, ws uuid.UUID, actor Actor, in NewTicket) (store.Ticket, error) {
	var out store.Ticket
	err := s.tx(ctx, func(q *store.Queries) error {
		// The graph lock comes before the project and ticket locks, as in
		// planning acceptance, so concurrent edges can't both pass cycle checks.
		if len(in.BlockedBy) > 0 {
			if err := q.LockDependencyGraph(ctx, ws); err != nil {
				return err
			}
		}
		var err error
		if out, err = CreateInTx(ctx, q, ws, actor, in); err != nil {
			return err
		}
		if len(in.BlockedBy) > 0 {
			return SetDependenciesInTx(ctx, q, ws, actor, out, in.BlockedBy)
		}
		return nil
	})
	return out, err
}

// CreateInTx creates a ticket inside a caller's transaction, including validation and activity.
func CreateInTx(ctx context.Context, q *store.Queries, ws uuid.UUID, actor Actor, in NewTicket) (store.Ticket, error) {
	title, err := validTitle(in.Title)
	if err != nil {
		return store.Ticket{}, err
	}
	if in.Status == "" {
		in.Status = "backlog"
	}
	if in.Priority == "" {
		in.Priority = "none"
	}
	if err := checkEnum("status", in.Status, Statuses); err != nil {
		return store.Ticket{}, err
	}
	if in.Status == "canceled" && actor.Type != "user" {
		return store.Ticket{}, apperr.Conflict("only a person may cancel a ticket")
	}
	if err := checkEnum("priority", in.Priority, Priorities); err != nil {
		return store.Ticket{}, err
	}
	if err := ValidEstimate(in.EstimatePoints, in.EstimateRationale); err != nil {
		return store.Ticket{}, err
	}

	var t store.Ticket
	err = func(q *store.Queries) error {
		r := refs{q, ws}
		p, err := q.LockProjectByKey(ctx, store.LockProjectByKeyParams{WorkspaceID: ws, Key: in.ProjectKey})
		if errors.Is(err, pgx.ErrNoRows) {
			return invalid("project_key", "unknown project")
		} else if err != nil {
			return err
		}
		if p.Archived {
			return apperr.Conflict("restore the archived project before creating tickets")
		}
		if in.EpicID != nil {
			if e, err := r.epic(ctx, in.EpicID, p.ID); err != nil {
				return err
			} else if e.Status == "done" {
				return apperr.Conflict("epic is done")
			}
		}
		var agent *store.Agent
		if in.AssigneeAgentID != nil {
			a, err := r.assignee(ctx, in.AssigneeAgentID)
			if err != nil {
				return err
			}
			agent = &a
		}
		if in.ReviewerUserID != nil {
			if _, err := r.user(ctx, in.ReviewerUserID); err != nil {
				return err
			}
		}
		if _, err := r.labels(ctx, in.LabelIDs); err != nil {
			return err
		}
		n, err := q.AllocateTicketNumber(ctx, p.ID)
		if err != nil {
			return err
		}
		t, err = q.CreateTicket(ctx, store.CreateTicketParams{
			WorkspaceID: ws, ProjectID: p.ID, Number: n, Key: fmt.Sprintf("%s-%d", p.Key, n),
			Title: title, DescriptionMd: in.DescriptionMd, Status: in.Status, Priority: in.Priority,
			EpicID: in.EpicID, AssigneeAgentID: in.AssigneeAgentID, ReviewerUserID: in.ReviewerUserID,
			CreatedByUserID: userID(actor), Estimate: emptyToNil(in.Estimate), DueDate: in.DueDate,
			RequiresMockup: in.RequiresMockup, EpicReview: in.EpicReview,
		})
		if err != nil {
			return err
		}
		if len(in.LabelIDs) > 0 {
			if err := q.AddTicketLabels(ctx, store.AddTicketLabelsParams{TicketID: t.ID, LabelIds: in.LabelIDs}); err != nil {
				return err
			}
		}
		for _, c := range in.Criteria {
			if c = strings.TrimSpace(c); c != "" {
				if _, err := q.CreateCriterion(ctx, store.CreateCriterionParams{TicketID: t.ID, Text: c}); err != nil {
					return err
				}
			}
		}
		if err := links.Index(ctx, q, ws, links.Source{Kind: links.SourceTicket, ID: t.ID, TicketID: &t.ID}, t.DescriptionMd); err != nil {
			return err
		}
		// [[PAY-230]] written before the ticket existed resolves now.
		if err := links.ResolvePending(ctx, q, ws); err != nil {
			return err
		}
		at := in.CreatedAt
		if err := record(ctx, q, ws, t.ID, t.EpicID, actor, event{verb: VerbCreated, at: at}); err != nil {
			return err
		}
		if in.RequiresMockup {
			if err := record(ctx, q, ws, t.ID, t.EpicID, actor, event{verb: VerbMockupRequirementChanged, at: at,
				payload: map[string]any{"from": false, "to": true}}); err != nil {
				return err
			}
		}
		if agent != nil {
			if err := record(ctx, q, ws, t.ID, t.EpicID, actor, event{verb: VerbAssigned, at: at,
				payload: map[string]any{"agent_id": agent.ID, "agent_name": agent.Name}}); err != nil {
				return err
			}
		}
		if in.EstimatePoints != nil {
			by := actor
			if in.EstimatedBy != nil {
				by = *in.EstimatedBy
			}
			if t, err = applyPatch(ctx, q, ws, by, t.Key, Patch{EstimatePoints: SetTo(*in.EstimatePoints), EstimateRationale: emptyToNil(in.EstimateRationale)}); err != nil {
				return err
			}
		}
		return nil
	}(q)
	return t, err
}

// ValidEstimate checks optional points against EstimateScale and the rationale length.
func ValidEstimate(points *int, rationale *string) error {
	if points != nil && !slices.Contains(EstimateScale, *points) {
		return invalid("estimate_points", "must be one of 1, 2, 3, 5, 8, 13")
	}
	if rationale != nil && len([]rune(*rationale)) > 2000 {
		return invalid("estimate_rationale", "must be at most 2000 characters")
	}
	return nil
}

func userID(a Actor) *uuid.UUID {
	if a.Type == "user" {
		return a.ID
	}
	return nil
}

func emptyToNil(s *string) *string {
	if s == nil || strings.TrimSpace(*s) == "" {
		return nil
	}
	v := strings.TrimSpace(*s)
	return &v
}

func Get(ctx context.Context, q *store.Queries, ws uuid.UUID, key string) (store.Ticket, error) {
	t, err := q.GetTicketByKey(ctx, store.GetTicketByKeyParams{WorkspaceID: ws, Key: key})
	return t, notFound(err)
}

// Update applies a patch to one ticket.
func (s *Service) Update(ctx context.Context, ws uuid.UUID, actor Actor, key string, p Patch) (store.Ticket, error) {
	return s.UpdateThen(ctx, ws, actor, key, p, nil)
}

// UpdateThen is Update with the caller's own checks and writes in the same
// transaction: then sees the ticket before and after the patch, and an error
// from it rolls the patch back.
func (s *Service) UpdateThen(ctx context.Context, ws uuid.UUID, actor Actor, key string, p Patch, then func(q *store.Queries, before, after store.Ticket) error) (store.Ticket, error) {
	var t store.Ticket
	err := s.tx(ctx, func(q *store.Queries) error {
		if err := LockTicketProjects(ctx, q, ws, []string{key}); err != nil {
			return err
		}
		before, err := Get(ctx, q, ws, key)
		if err != nil {
			return err
		}
		if t, err = applyPatch(ctx, q, ws, actor, key, p); err != nil {
			return err
		}
		if then != nil {
			return then(q, before, t)
		}
		return nil
	})
	return t, err
}

// Bulk applies the same patch to many tickets atomically, optionally
// attaching one artifact to each. Title and description are per-ticket and
// rejected here.
func (s *Service) Bulk(ctx context.Context, ws uuid.UUID, actor Actor, keys []string, p Patch, attach *uuid.UUID) (int, error) {
	if p.Revision != nil {
		return 0, invalid("revision", "not allowed in bulk updates")
	}
	if p.Criteria != nil {
		return 0, invalid("criteria", "not allowed in bulk updates")
	}
	if p.Title != nil || p.DescriptionMd != nil {
		return 0, invalid("patch", "title and description can't be bulk-edited")
	}
	if len(keys) == 0 || len(keys) > 200 {
		return 0, invalid("keys", "must list 1 to 200 tickets")
	}
	n := 0
	err := s.tx(ctx, func(q *store.Queries) error {
		if err := LockTicketProjects(ctx, q, ws, keys); err != nil {
			if errors.Is(err, ErrNotFound) {
				return invalid("keys", "unknown ticket")
			}
			return err
		}
		for _, k := range keys {
			if _, err := applyPatch(ctx, q, ws, actor, k, p); err != nil {
				if errors.Is(err, ErrNotFound) {
					return invalid("keys", "unknown ticket %s", k)
				}
				return err
			}
			if attach != nil {
				if err := attachArtifact(ctx, q, ws, actor, k, *attach, "context"); err != nil {
					return err
				}
			}
			n++
		}
		return nil
	})
	return n, err
}

func ptrEq[T comparable](a, b *T) bool {
	if a == nil || b == nil {
		return a == b
	}
	return *a == *b
}

func dateEq(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == b
	}
	return a.Format(time.DateOnly) == b.Format(time.DateOnly)
}

func applyPatch(ctx context.Context, q *store.Queries, ws uuid.UUID, actor Actor, key string, p Patch) (store.Ticket, error) {
	var draftTexts []string
	if p.Criteria != nil {
		if p.Revision == nil {
			return store.Ticket{}, invalid("revision", "is required when saving criteria")
		}
		var err error
		if draftTexts, err = validateDraft(p.Criteria); err != nil {
			return store.Ticket{}, err
		}
	}
	cur, err := q.LockTicketByKey(ctx, store.LockTicketByKeyParams{WorkspaceID: ws, Key: key})
	if err != nil {
		return cur, notFound(err)
	}
	if p.Revision != nil && *p.Revision != int(cur.Revision) {
		return cur, apperr.ConflictField("revision", "ticket revision is stale")
	}
	if p.Criteria != nil {
		if err := applyCriteriaDraft(ctx, q, ws, actor, cur.ID, cur.EpicID, p.Criteria, draftTexts); err != nil {
			return cur, err
		}
	}
	r := refs{q, ws}
	next := store.UpdateTicketParams{
		ID: cur.ID, Title: cur.Title, DescriptionMd: cur.DescriptionMd, Status: cur.Status, Priority: cur.Priority,
		EpicID: cur.EpicID, AssigneeAgentID: cur.AssigneeAgentID, ReviewerUserID: cur.ReviewerUserID,
		Estimate: cur.Estimate, DueDate: cur.DueDate, RequiresMockup: cur.RequiresMockup,
		EstimatePoints: cur.EstimatePoints, EstimateRationale: cur.EstimateRationale,
		EstimatedByType: cur.EstimatedByType, EstimatedByID: cur.EstimatedByID, EstimatedAt: cur.EstimatedAt,
	}
	var events []event
	add := func(verb string, payload map[string]any) {
		events = append(events, event{verb: verb, payload: payload})
	}

	if p.Title != nil {
		title, err := validTitle(*p.Title)
		if err != nil {
			return cur, err
		}
		if title != cur.Title {
			next.Title = title
			add(VerbTitleChanged, map[string]any{"from": cur.Title, "to": title})
		}
	}
	if p.DescriptionMd != nil && *p.DescriptionMd != cur.DescriptionMd {
		next.DescriptionMd = *p.DescriptionMd
		add(VerbDescriptionEdited, nil)
	}
	if p.Status != nil {
		if err := checkEnum("status", *p.Status, Statuses); err != nil {
			return cur, err
		}
	}
	// Delayed completion, runner and PR callbacks must not reopen work a person
	// canceled after the callback's own transaction ended. Only people reopen it.
	if cur.Status == "canceled" && !actor.personDecided() {
		p.Status = nil
	}
	if p.Status != nil && *p.Status != cur.Status {
		if *p.Status == "canceled" {
			if !actor.personDecided() {
				return cur, apperr.Conflict("only a person may cancel a ticket")
			}
			if _, err := q.ActiveRunForTicket(ctx, &cur.ID); err == nil {
				return cur, apperr.Conflict("cancel the run first")
			} else if !errors.Is(err, pgx.ErrNoRows) {
				return cur, err
			}
		}
		next.Status = *p.Status
		add(VerbStatusChanged, map[string]any{"from": cur.Status, "to": *p.Status})
	}
	if p.Priority != nil && *p.Priority != cur.Priority {
		if err := checkEnum("priority", *p.Priority, Priorities); err != nil {
			return cur, err
		}
		next.Priority = *p.Priority
		add(VerbPriorityChanged, map[string]any{"from": cur.Priority, "to": *p.Priority})
	}
	if p.AssigneeAgentID.Set && !ptrEq(p.AssigneeAgentID.Value, cur.AssigneeAgentID) {
		if cur.AssigneeAgentID != nil {
			old, err := r.agent(ctx, cur.AssigneeAgentID)
			if err != nil {
				return cur, err
			}
			add(VerbUnassigned, map[string]any{"agent_id": old.ID, "agent_name": old.Name})
		}
		if p.AssigneeAgentID.Value != nil {
			a, err := r.assignee(ctx, p.AssigneeAgentID.Value)
			if err != nil {
				return cur, err
			}
			add(VerbAssigned, map[string]any{"agent_id": a.ID, "agent_name": a.Name})
		}
		next.AssigneeAgentID = p.AssigneeAgentID.Value
	}
	if p.ReviewerUserID.Set && !ptrEq(p.ReviewerUserID.Value, cur.ReviewerUserID) {
		if p.ReviewerUserID.Value != nil {
			u, err := r.user(ctx, p.ReviewerUserID.Value)
			if err != nil {
				return cur, err
			}
			add(VerbReviewerSet, map[string]any{"user_id": u.ID, "user_name": u.Name})
		} else {
			add(VerbReviewerCleared, nil)
		}
		next.ReviewerUserID = p.ReviewerUserID.Value
	}
	if p.EpicID.Set && !ptrEq(p.EpicID.Value, cur.EpicID) {
		if cur.EpicReview {
			return cur, apperr.Conflict("an epic's final review can't change epics")
		}
		payload := map[string]any{}
		if p.EpicID.Value != nil {
			e, err := r.epic(ctx, p.EpicID.Value, cur.ProjectID)
			if err != nil {
				return cur, err
			}
			if e.Status == "done" {
				return cur, apperr.Conflict("epic is done")
			}
			payload["epic_id"], payload["epic_name"] = e.ID, e.Name
		}
		next.EpicID = p.EpicID.Value
		add(VerbEpicChanged, payload)
	}
	if next.EpicID != nil && next.Status != "done" && next.Status != "canceled" && (cur.Status == "done" || cur.Status == "canceled") {
		e, err := r.epic(ctx, next.EpicID, cur.ProjectID)
		if err != nil {
			return cur, err
		}
		if e.Status == "done" {
			return cur, apperr.Conflict("epic is done")
		}
	}
	if p.Estimate.Set {
		v := emptyToNil(p.Estimate.Value)
		if !ptrEq(v, cur.Estimate) {
			next.Estimate = v
			add(VerbEstimateChanged, map[string]any{"to": v})
		}
	}
	if p.EstimatePoints.Set {
		var points *int32
		if p.EstimatePoints.Value != nil {
			if !slices.Contains(EstimateScale, *p.EstimatePoints.Value) {
				return cur, invalid("estimate_points", "must be one of 1, 2, 3, 5, 8, 13")
			}
			v := int32(*p.EstimatePoints.Value)
			points = &v
		}
		rationale := p.EstimateRationale
		if points == nil {
			rationale = nil
		} else if actor.Type == "user" {
			rationale = nil
		} else if rationale == nil && ptrEq(points, cur.EstimatePoints) {
			rationale = cur.EstimateRationale
		}
		ownershipChanged := points != nil && actor.Type == "user" &&
			(cur.EstimatedByType == nil || *cur.EstimatedByType != "user" || !ptrEq(actor.ID, cur.EstimatedByID))
		if !ptrEq(points, cur.EstimatePoints) || !ptrEq(rationale, cur.EstimateRationale) || ownershipChanged {
			if actor.Type == "agent" && actor.ApprovedBy == nil && cur.EstimatedByType != nil && *cur.EstimatedByType == "user" {
				return cur, apperr.Conflict("a person estimated this; comment instead")
			}
			if actor.Type == "agent" && (next.Status == "done" || next.Status == "canceled") {
				return cur, apperr.Conflict("%s is %s; closed tickets can't be estimated", cur.Key, next.Status)
			}
			if p.EstimateRationale != nil && len([]rune(*p.EstimateRationale)) > 2000 {
				return cur, invalid("estimate_rationale", "must be at most 2000 characters")
			}
			next.EstimatePoints, next.EstimateRationale = points, rationale
			if points == nil {
				next.EstimatedByType, next.EstimatedByID, next.EstimatedAt = nil, nil, nil
			} else {
				now := time.Now()
				next.EstimatedByType, next.EstimatedByID, next.EstimatedAt = &actor.Type, actor.ID, &now
			}
			add(VerbEstimateChanged, map[string]any{"to_points": points, "rationale": rationale})
		}
	}
	if p.DueDate.Set && !dateEq(p.DueDate.Value, cur.DueDate) {
		next.DueDate = p.DueDate.Value
		var to any
		if p.DueDate.Value != nil {
			to = p.DueDate.Value.Format(time.DateOnly)
		}
		add(VerbDueChanged, map[string]any{"to": to})
	}
	if p.RequiresMockup != nil && *p.RequiresMockup != cur.RequiresMockup {
		next.RequiresMockup = *p.RequiresMockup
		add(VerbMockupRequirementChanged, map[string]any{"from": cur.RequiresMockup, "to": *p.RequiresMockup})
	}

	if p.LabelIDs != nil {
		ev, err := setLabels(ctx, q, r, cur.ID, *p.LabelIDs)
		if err != nil {
			return cur, err
		}
		if ev != nil {
			events = append(events, *ev)
		}
	}
	t := cur
	if len(events) > 0 {
		if t, err = q.UpdateTicket(ctx, next); err != nil {
			return cur, err
		}
		if t.DescriptionMd != cur.DescriptionMd {
			if err := links.Index(ctx, q, ws, links.Source{Kind: links.SourceTicket, ID: t.ID, TicketID: &t.ID}, t.DescriptionMd); err != nil {
				return cur, err
			}
		}
	}
	for _, e := range events {
		if err := record(ctx, q, ws, t.ID, t.EpicID, actor, e); err != nil {
			return cur, err
		}
	}
	if !cur.EpicReview {
		finished := t.Status != cur.Status && (t.Status == "in_review" || t.Status == "done" || t.Status == "canceled")
		moved := !ptrEq(t.EpicID, cur.EpicID)
		var check []*uuid.UUID
		if moved {
			check = append(check, cur.EpicID) // the epic it left may now be finished
		}
		if finished || (moved && t.Status != "backlog" && t.Status != "todo" && t.Status != "in_progress") {
			check = append(check, t.EpicID) // a finished ticket arrived or finished here
		}
		for _, id := range check {
			if id == nil {
				continue
			}
			if err := maybeCreateEpicReview(ctx, q, ws, *id); err != nil {
				return cur, err
			}
		}
	}
	return t, nil
}

// maybeCreateEpicReview creates the epic's final review ticket once every
// regular ticket has finished (in_review counts: its PR is consolidated by the
// review). Runs inside the caller's transaction, which holds the project lock.
// Anything that only means "no review needed" is a quiet no-op.
func maybeCreateEpicReview(ctx context.Context, q *store.Queries, ws, epicID uuid.UUID) error {
	e, err := q.GetEpic(ctx, store.GetEpicParams{ID: epicID, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	} else if err != nil {
		return err
	}
	if e.Status != "open" {
		return nil
	}
	st, err := q.EpicReviewState(ctx, &epicID)
	if err != nil {
		return err
	}
	if st.Total == 0 || st.Unfinished > 0 || st.HasReview {
		return nil
	}
	p, err := q.GetProject(ctx, store.GetProjectParams{ID: e.ProjectID, WorkspaceID: ws})
	if err != nil {
		return err
	}
	if p.Archived {
		return nil // no new tickets in an archived project
	}
	_, err = createEpicReview(ctx, q, ws, e, p)
	return err
}

// EnsureEpicReview returns the epic's final review ticket, creating it on
// demand whatever state the other tickets are in.
func (s *Service) EnsureEpicReview(ctx context.Context, ws, epicID uuid.UUID) (store.Ticket, error) {
	var out store.Ticket
	err := s.tx(ctx, func(q *store.Queries) error {
		e, err := lockEpicProject(ctx, q, ws, epicID)
		if err != nil {
			return err
		}
		if t, err := q.GetEpicReviewTicket(ctx, &epicID); err == nil {
			out = t
			return nil
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if e.Status != "open" {
			return apperr.Conflict("epic is done")
		}
		p, err := q.GetProject(ctx, store.GetProjectParams{ID: e.ProjectID, WorkspaceID: ws})
		if err != nil {
			return notFound(err)
		}
		if p.Archived {
			return apperr.Conflict("restore the archived project before adding tickets")
		}
		out, err = createEpicReview(ctx, q, ws, e, p)
		return err
	})
	return out, err
}

func createEpicReview(ctx context.Context, q *store.Queries, ws uuid.UUID, e store.Epic, p store.Project) (store.Ticket, error) {
	epicID := e.ID
	tickets, err := q.ListEpicReviewTickets(ctx, &epicID)
	if err != nil {
		return store.Ticket{}, err
	}
	var b strings.Builder
	fmt.Fprintf(&b, "This is the final review for the epic **%s**. It runs once the epic's other tickets have finished.\n\n", e.Name)
	fmt.Fprintf(&b, "The epic's tickets built and typechecked but did not run tests. This run consolidates any ticket branches not yet merged into the epic branch `%s`, runs the full test suite once, fixes failures and verifies the epic's acceptance criteria.\n\nTickets in this epic:\n\n", agentdef.EpicBranch(p.Key, e.ID.String()))
	for _, t := range tickets {
		fmt.Fprintf(&b, "- [[%s]] %s (%s)\n", t.Key, t.Title, t.Status)
	}
	title := "Final review: " + e.Name
	if r := []rune(title); len(r) > 300 {
		title = string(r[:300])
	}
	in := NewTicket{
		ProjectKey: p.Key, Title: title, DescriptionMd: b.String(), Status: "todo", EpicID: &epicID, EpicReview: true,
		Criteria: []string{
			"Every ticket branch and PR in the epic is merged into the epic branch",
			"The full test suite passes on the epic branch",
			"The epic's acceptance criteria are verified and checked",
			"The epic's pull request is marked ready for review",
		},
	}
	r := refs{q, ws}
	// The tech lead does the final review when the workspace has one.
	if a, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "tech-lead"}); err == nil {
		if _, err := r.assignee(ctx, &a.ID); err == nil {
			in.AssigneeAgentID = &a.ID
		} else if !errors.As(err, new(*apperr.ValidationError)) {
			return store.Ticket{}, err
		}
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return store.Ticket{}, err
	}
	if in.AssigneeAgentID == nil {
		if id, err := q.EpicTopAssignee(ctx, &epicID); err == nil && id != nil {
			// A deleted or non-assignable agent leaves the review unassigned.
			if _, err := r.assignee(ctx, id); err == nil {
				in.AssigneeAgentID = id
			} else if !errors.As(err, new(*apperr.ValidationError)) {
				return store.Ticket{}, err
			}
		} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return store.Ticket{}, err
		}
	}
	return CreateInTx(ctx, q, ws, Actor{Type: "system"}, in)
}

func setLabels(ctx context.Context, q *store.Queries, r refs, ticketID uuid.UUID, ids []uuid.UUID) (*event, error) {
	byID, err := r.labels(ctx, ids)
	if err != nil {
		return nil, err
	}
	existing, err := q.ListLabelsForTickets(ctx, []uuid.UUID{ticketID})
	if err != nil {
		return nil, err
	}
	had := map[uuid.UUID]bool{}
	for _, l := range existing {
		had[l.ID] = true
	}
	want := map[uuid.UUID]bool{}
	for _, id := range ids {
		want[id] = true
	}
	added, removed := []string{}, []string{}
	for id := range want {
		if !had[id] {
			added = append(added, byID[id].Name)
		}
	}
	for _, l := range existing {
		if !want[l.ID] {
			removed = append(removed, l.Name)
		}
	}
	if len(added) == 0 && len(removed) == 0 {
		return nil, nil
	}
	slices.Sort(added)
	slices.Sort(removed)
	if err := q.ClearTicketLabels(ctx, ticketID); err != nil {
		return nil, err
	}
	if len(ids) > 0 {
		if err := q.AddTicketLabels(ctx, store.AddTicketLabelsParams{TicketID: ticketID, LabelIds: ids}); err != nil {
			return nil, err
		}
	}
	return &event{verb: VerbLabelsChanged, payload: map[string]any{"added": added, "removed": removed}}, nil
}

// AttachArtifact links an artifact to a ticket. Attaching twice is a no-op.
func (s *Service) AttachArtifact(ctx context.Context, ws uuid.UUID, actor Actor, key string, artifactID uuid.UUID, relation string) error {
	return s.tx(ctx, func(q *store.Queries) error { return attachArtifact(ctx, q, ws, actor, key, artifactID, relation) })
}

// AttachArtifactInTx attaches context and writes its complete activity payload in the caller's transaction.
func AttachArtifactInTx(ctx context.Context, q *store.Queries, ws uuid.UUID, actor Actor, key string, artifactID uuid.UUID, relation string) error {
	return attachArtifact(ctx, q, ws, actor, key, artifactID, relation)
}

func attachArtifact(ctx context.Context, q *store.Queries, ws uuid.UUID, actor Actor, key string, artifactID uuid.UUID, relation string) error {
	if relation == "" {
		relation = "context"
	}
	if relation != "context" && relation != "generated" {
		return invalid("relation", "must be context or generated")
	}
	t, err := Get(ctx, q, ws, key)
	if err != nil {
		return err
	}
	a, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: artifactID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return invalid("artifact_id", "unknown artifact")
	} else if err != nil {
		return err
	}
	if a.Audience == "private" {
		return invalid("artifact_id", "Share the page first")
	}
	n, err := q.AttachArtifact(ctx, store.AttachArtifactParams{TicketID: t.ID, ArtifactID: a.ID, Relation: relation})
	if err != nil || n == 0 {
		return err
	}
	return record(ctx, q, ws, t.ID, t.EpicID, actor, event{verb: VerbArtifactAttached,
		payload: map[string]any{"artifact_id": a.ID, "title": a.Title, "type": a.Type, "relation": relation}})
}

// DetachArtifact unlinks an artifact from a ticket.
func (s *Service) DetachArtifact(ctx context.Context, ws uuid.UUID, actor Actor, key string, artifactID uuid.UUID) error {
	return s.tx(ctx, func(q *store.Queries) error {
		t, err := Get(ctx, q, ws, key)
		if err != nil {
			return err
		}
		a, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: artifactID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return notFound(err)
		}
		n, err := q.DetachArtifact(ctx, store.DetachArtifactParams{TicketID: t.ID, ArtifactID: a.ID})
		if err != nil || n == 0 {
			return err
		}
		return record(ctx, q, ws, t.ID, t.EpicID, actor, event{verb: VerbArtifactDetached,
			payload: map[string]any{"artifact_id": a.ID, "title": a.Title, "type": a.Type}})
	})
}

// SetEpicRequiresMockup flags (or clears) the whole epic as needing person-approved mockups.
func (s *Service) SetEpicRequiresMockup(ctx context.Context, ws, epicID uuid.UUID, requires bool) (store.Epic, error) {
	return s.UpdateEpic(ctx, ws, epicID, nil, &requires)
}

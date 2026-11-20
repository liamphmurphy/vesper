package personas

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// What a persona does besides chatting. A persona that works takes tickets and has a work
// record: the agents row with the persona's own id, whose versioned definition holds its
// harness, model, work brief, scopes and limits. Turning work off archives the record, so
// its runs and history stay intact. Help within a run comes from the run's own sub agents
// and delegated copies of the persona, not from other personas.
const (
	WorkNone    = "none"
	WorkTickets = "tickets"
)

// WorkOf is the work a persona's record says it does; a nil or archived record is none.
func WorkOf(a *store.Agent) string {
	if a == nil || a.ArchivedAt != nil || a.Kind != agents.KindMain {
		return WorkNone
	}
	return WorkTickets
}

// WorkRecords maps each of the owner's working (or formerly working) personas to its record.
func (s *Service) WorkRecords(ctx context.Context, o Owner) (map[uuid.UUID]store.Agent, error) {
	rows, err := store.New(s.Pool).ListPersonaWork(ctx, store.ListPersonaWorkParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if err != nil {
		return nil, err
	}
	out := make(map[uuid.UUID]store.Agent, len(rows))
	for _, a := range rows {
		out[a.ID] = a
	}
	return out, nil
}

// WorkRecord is one persona's record, nil when it has never worked.
func WorkRecord(ctx context.Context, q *store.Queries, ws, id uuid.UUID) (*store.Agent, error) {
	a, err := q.GetAgent(ctx, store.GetAgentParams{ID: id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if a.Kind != agents.KindMain {
		return nil, nil
	}
	return &a, nil
}

// SetWork turns a persona's work on or off. Off is refused while the persona holds open
// tickets or has a run in progress, as deleting an agent was. by is the person, recorded on
// the definition version a change writes.
func (s *Service) SetWork(ctx context.Context, o Owner, id uuid.UUID, work string, by uuid.UUID) (store.Persona, *store.Agent, error) {
	if work != WorkNone && work != WorkTickets {
		return store.Persona{}, nil, apperr.Invalid("work", "must be none or tickets")
	}
	var p store.Persona
	var rec *store.Agent
	err := s.tx(ctx, o, func(q *store.Queries) error {
		var err error
		if p, err = get(ctx, q, o, id); err != nil {
			return err
		}
		if rec, err = WorkRecord(ctx, q, o.WorkspaceID, id); err != nil {
			return err
		}
		if WorkOf(rec) == work {
			return nil
		}
		if rec != nil && rec.ArchivedAt == nil {
			// Hold the live record while checking its tickets and runs, as deleting an agent
			// did, so two changes to its work (or a definition save) can't interleave.
			locked, err := q.LockAgentByHandle(ctx, store.LockAgentByHandleParams{WorkspaceID: o.WorkspaceID, Handle: rec.Handle})
			if err != nil {
				return err
			}
			rec = &locked
		}
		switch {
		case work == WorkNone:
			return stopWork(ctx, q, rec)
		case rec == nil:
			rec, err = startWork(ctx, q, p, by)
			return err
		default:
			rec, err = resumeWork(ctx, q, p, *rec, by)
			return err
		}
	})
	return p, rec, err
}

func busy(ctx context.Context, q *store.Queries, a store.Agent, doing string) error {
	n, err := q.CountOpenTicketsForAgent(ctx, &a.ID)
	if err != nil {
		return err
	}
	if n > 0 {
		return apperr.Conflict("%s is assigned %d open ticket(s); reassign or finish them before %s", a.Name, n, doing)
	}
	return nil
}

func stopWork(ctx context.Context, q *store.Queries, a *store.Agent) error {
	if err := busy(ctx, q, *a, "turning its work off"); err != nil {
		return err
	}
	runs, err := q.CountActiveRunsForAgent(ctx, a.ID)
	if err != nil {
		return err
	}
	if runs > 0 {
		return apperr.Conflict("%s has %d run(s) in progress; wait for them to finish or cancel them before turning its work off", a.Name, runs)
	}
	if err := q.RevokeAgentTokensForAgent(ctx, a.ID); err != nil {
		return err
	}
	return q.ArchiveAgent(ctx, a.ID)
}

// startWork gives a persona its first work record: a handle from its name and the default
// definition (inheriting the persona's default harness/model/effort when set).
func startWork(ctx context.Context, q *store.Queries, p store.Persona, by uuid.UUID) (*store.Agent, error) {
	handle, err := freeHandle(ctx, q, p.WorkspaceID, p.Name)
	if err != nil {
		return nil, err
	}
	spec := agents.DefaultSpec()
	if p.DefaultHarness != "" && p.DefaultModel != "" || p.DefaultEffort != "" {
		spec.SetModel(p.DefaultHarness, p.DefaultModel, p.DefaultEffort)
	}
	a, err := q.CreatePersonaAgent(ctx, store.CreatePersonaAgentParams{
		ID: p.ID, WorkspaceID: p.WorkspaceID, Name: p.Name, Handle: handle,
		ColorIndex: int32(agents.NearestHue(p.Color)), Model: spec.Model, Kind: agents.KindMain,
	})
	if err != nil {
		return nil, err
	}
	a, err = agents.WriteVersion(ctx, q, a, agents.Identity{Name: p.Name, ColorIndex: int(a.ColorIndex)}, spec, "Started work", &by, nil)
	return &a, err
}

// resumeWork revives an archived record (under a free handle), keeping its definition and
// syncing the persona's default model into it.
func resumeWork(ctx context.Context, q *store.Queries, p store.Persona, a store.Agent, by uuid.UUID) (*store.Agent, error) {
	handle := a.Handle
	taken, err := q.AgentHandleTaken(ctx, store.AgentHandleTakenParams{WorkspaceID: a.WorkspaceID, Handle: handle})
	if err != nil {
		return nil, err
	}
	if taken {
		if handle, err = freeHandle(ctx, q, a.WorkspaceID, p.Name); err != nil {
			return nil, err
		}
	}
	if a, err = q.ReviveAgent(ctx, store.ReviveAgentParams{ID: a.ID, Handle: handle}); err != nil {
		return nil, err
	}
	if !(p.DefaultHarness != "" && p.DefaultModel != "" || p.DefaultEffort != "") {
		return &a, nil
	}
	spec, _, err := agents.CurrentSpec(ctx, q, a)
	if err != nil {
		return nil, err
	}
	spec.SetModel(p.DefaultHarness, p.DefaultModel, p.DefaultEffort)
	a, err = agents.WriteVersion(ctx, q, a, agents.Identity{Name: p.Name, Role: a.Role, Specialty: a.Specialty, ColorIndex: int(a.ColorIndex)}, spec, "Resumed work", &by, nil)
	return &a, err
}

// freeHandle makes a handle from a name ("Dr. Mara" → dr-mara) that no live agent uses,
// adding -2, -3… when it's taken.
func freeHandle(ctx context.Context, q *store.Queries, ws uuid.UUID, name string) (string, error) {
	base := slug(name)
	for n := 1; n < 100; n++ {
		h := base
		if n > 1 {
			suffix := "-" + strconv.Itoa(n)
			h = strings.TrimRight(base[:min(len(base), 32-len(suffix))], "-") + suffix
		}
		taken, err := q.AgentHandleTaken(ctx, store.AgentHandleTakenParams{WorkspaceID: ws, Handle: h})
		if err != nil {
			return "", err
		}
		if !taken {
			return h, nil
		}
	}
	return "", apperr.Conflict("no free handle for %q", name)
}

func slug(name string) string {
	var b strings.Builder
	dash := false
	for _, r := range strings.ToLower(name) {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9':
			b.WriteRune(r)
			dash = false
		case b.Len() > 0 && !dash:
			b.WriteByte('-')
			dash = true
		}
	}
	s := strings.Trim(b.String(), "-")
	if s == "" || s[0] < 'a' || s[0] > 'z' {
		s = "p-" + s
	}
	s = strings.TrimRight(s, "-")
	if len(s) > 32 {
		s = strings.TrimRight(s[:32], "-")
	}
	if len(s) < 2 {
		s += "-1"
	}
	return s
}

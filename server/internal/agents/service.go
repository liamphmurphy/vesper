// Package agents manages agent identities, their versioned definitions and
// per-project overrides (docs/dev/plan.md §6.1). The merge rules live in agentdef.
package agents

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type Service struct {
	Pool *pgxpool.Pool
}

// Identity is the part of an agent that isn't versioned with the definition.
type Identity struct {
	Name       string
	Role       string
	Specialty  string
	ColorIndex int
	// Kind is "main" (takes tickets) or "sub" (only runs when a main agent
	// delegates to it). Empty keeps the current kind, or "main" for a new agent.
	Kind string
}

const (
	KindMain = "main"
	KindSub  = "sub"
)

var handleRe = regexp.MustCompile(`^[a-z][a-z0-9-]{1,31}$`)

func (id *Identity) normalize() error {
	id.Name = strings.TrimSpace(id.Name)
	id.Role = strings.TrimSpace(id.Role)
	id.Specialty = strings.TrimSpace(id.Specialty)
	if id.Name == "" || utf8.RuneCountInString(id.Name) > 40 {
		return apperr.Invalid("name", "is required (at most 40 characters)")
	}
	if id.Kind != "" && id.Kind != KindMain && id.Kind != KindSub {
		return apperr.Invalid("kind", "must be main or sub")
	}
	if id.ColorIndex < 0 || id.ColorIndex > 7 {
		return apperr.Invalid("color_index", "must be 0–7 (the fixed identity palette)")
	}
	return nil
}

// toAppErr maps agentdef validation onto the API's error type.
func toAppErr(err error) error {
	if ve, ok := errors.AsType[*agentdef.ValidationError](err); ok {
		return &apperr.ValidationError{Field: ve.Field, Msg: ve.Msg}
	}
	return err
}

func notFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound
	}
	return err
}

// DecodeSpec reads a stored definition. Stored specs were normalized on save.
func DecodeSpec(raw []byte) (agentdef.Spec, error) {
	var s agentdef.Spec
	err := json.Unmarshal(raw, &s)
	return s, err
}

func DecodeOverride(raw []byte) (agentdef.Override, error) {
	var o agentdef.Override
	err := json.Unmarshal(raw, &o)
	return o, err
}

// DefaultSpec is what a new agent starts with: read and write the repo, run
// tests, anything touching shared environments needs a person.
func DefaultSpec() agentdef.Spec {
	s := agentdef.Spec{
		Harness: agentdef.HarnessClaudeCode, Model: "sonnet-5.5",
		Instructions: "Post a plan with lazyagents.post_plan before editing anything.\n",
		Scopes: map[string]agentdef.Mode{
			"repo:read": agentdef.Allowed, "repo:write": agentdef.Allowed, "tests:run": agentdef.Allowed,
			"db:migrate": agentdef.RequiresApproval, "deploy:staging": agentdef.Denied,
		},
		Budget: agentdef.Budget{MaxRuntime: "2h", MaxTurns: 20},
	}
	_ = s.Normalize()
	return s
}

func kindPtr(k string) *string {
	if k == "" {
		return nil
	}
	return &k
}

// WriteVersion appends a definition version and makes it current. at
// backdates it (seeding only).
func WriteVersion(ctx context.Context, q *store.Queries, a store.Agent, id Identity, spec agentdef.Spec, note string, by *uuid.UUID, at *time.Time) (store.Agent, error) {
	raw, err := json.Marshal(spec)
	if err != nil {
		return a, err
	}
	v, err := q.CreateDefinitionVersion(ctx, store.CreateDefinitionVersionParams{
		AgentID: a.ID, Spec: raw, Note: strings.TrimSpace(note), CreatedByUserID: by, CreatedAt: at,
	})
	if err != nil {
		return a, err
	}
	return q.UpdateAgentFromDefinition(ctx, store.UpdateAgentFromDefinitionParams{
		ID: a.ID, Name: id.Name, Role: id.Role, Specialty: id.Specialty, ColorIndex: int32(id.ColorIndex),
		Model: spec.Model, MaxConcurrency: int32(spec.MaxConcurrency), CurrentDefinitionVersionID: &v.ID, Kind: kindPtr(id.Kind),
	})
}

// Create adds an agent with its first definition version.
func (s *Service) Create(ctx context.Context, ws uuid.UUID, by uuid.UUID, handle string, id Identity, spec *agentdef.Spec) (store.Agent, error) {
	handle = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(handle), "@"))
	if !handleRe.MatchString(handle) {
		return store.Agent{}, apperr.Invalid("handle", "must be 2–32 lowercase letters, digits or -, starting with a letter")
	}
	if err := id.normalize(); err != nil {
		return store.Agent{}, err
	}
	sp := DefaultSpec()
	if spec != nil {
		sp = *spec
	}
	if err := sp.Normalize(); err != nil {
		return store.Agent{}, toAppErr(err)
	}
	var a store.Agent
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if _, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: handle}); err == nil {
			return apperr.Invalid("handle", "@%s is taken", handle)
		}
		var err error
		a, err = q.CreateAgent(ctx, store.CreateAgentParams{
			WorkspaceID: ws, Name: id.Name, Handle: handle, ColorIndex: int32(id.ColorIndex),
			Role: id.Role, Specialty: id.Specialty, Model: sp.Model, Status: "idle", Kind: kindPtr(id.Kind),
		})
		if err != nil {
			return err
		}
		if a, err = WriteVersion(ctx, q, a, id, sp, "Created", &by, nil); err != nil {
			return err
		}
		if a.Kind == KindMain || a.Kind == KindSub {
			return GivePersona(ctx, q, a, by)
		}
		return nil
	})
	return a, err
}

// SaveDefinition writes a new immutable version (the "Save as v8" button).
// Runs already in progress keep their snapshot (§6.4).
func (s *Service) SaveDefinition(ctx context.Context, ws uuid.UUID, by uuid.UUID, handle string, id Identity, spec agentdef.Spec, note string) (store.Agent, error) {
	if err := id.normalize(); err != nil {
		return store.Agent{}, err
	}
	if err := spec.Normalize(); err != nil {
		return store.Agent{}, toAppErr(err)
	}
	var a store.Agent
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		cur, err := q.LockAgentByHandle(ctx, store.LockAgentByHandleParams{WorkspaceID: ws, Handle: handle})
		if err != nil {
			return notFound(err)
		}
		if cur.Kind == KindAssistant {
			return apperr.Conflict("the Personal Assistant's definition is managed by Vesper")
		}
		// The persona owns the name: its profile renames both.
		var ownerPersona *store.Persona
		if p, err := q.PersonaOwnerOf(ctx, store.PersonaOwnerOfParams{ID: cur.ID, WorkspaceID: ws}); err == nil {
			id.Name = p.Name
			ownerPersona = &p
		} else if !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if id.Kind == KindSub && cur.Kind != KindSub {
			// Sub agents can't hold tickets: hand the open ones to someone else first.
			n, err := q.CountOpenTicketsForAgent(ctx, &cur.ID)
			if err != nil {
				return err
			}
			if n > 0 {
				return apperr.Conflict("@%s is assigned %d open ticket(s); reassign them before making it a sub agent", cur.Handle, n)
			}
		}
		a, err = WriteVersion(ctx, q, cur, id, spec, note, &by, nil)
		if err != nil {
			return err
		}
		if ownerPersona != nil {
			effort := spec.Effort()
			if ownerPersona.DefaultHarness != spec.Harness || ownerPersona.DefaultModel != spec.Model || ownerPersona.DefaultEffort != effort {
				if _, err := q.SyncPersonaDefaultModel(ctx, store.SyncPersonaDefaultModelParams{
					ID: ownerPersona.ID, WorkspaceID: ws,
					DefaultHarness: spec.Harness, DefaultModel: spec.Model, DefaultEffort: effort,
				}); err != nil {
					return err
				}
			}
		}
		return nil
	})
	return a, err
}

// Delete archives an agent: it disappears from lists and can't be assigned or
// delegated to, but its runs, chats and finished tickets stay intact. It is
// refused while the agent holds open tickets or has a run in progress.
func (s *Service) Delete(ctx context.Context, ws uuid.UUID, handle string) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		a, err := q.LockAgentByHandle(ctx, store.LockAgentByHandleParams{WorkspaceID: ws, Handle: handle})
		if err != nil {
			return notFound(err)
		}
		if a.Kind == KindAssistant {
			return apperr.Conflict("the Personal Assistant can't be deleted")
		}
		n, err := q.CountOpenTicketsForAgent(ctx, &a.ID)
		if err != nil {
			return err
		}
		if n > 0 {
			return apperr.Conflict("@%s is assigned %d open ticket(s); reassign or finish them before deleting it", a.Handle, n)
		}
		runs, err := q.CountActiveRunsForAgent(ctx, a.ID)
		if err != nil {
			return err
		}
		if runs > 0 {
			return apperr.Conflict("@%s has %d run(s) in progress; wait for them to finish or cancel them before deleting it", a.Handle, runs)
		}
		if err := q.RevokeAgentTokensForAgent(ctx, a.ID); err != nil {
			return err
		}
		return q.ArchiveAgent(ctx, a.ID)
	})
}

// SetOverride stores a project's override; an empty override deletes it.
func (s *Service) SetOverride(ctx context.Context, ws uuid.UUID, by uuid.UUID, handle, projectKey string, o agentdef.Override) error {
	if err := o.Normalize(); err != nil {
		return toAppErr(err)
	}
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		a, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: handle})
		if err != nil {
			return notFound(err)
		}
		p, err := q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: projectKey})
		if err != nil {
			return notFound(err)
		}
		if o.Empty() {
			_, err = q.DeleteOverride(ctx, store.DeleteOverrideParams{AgentID: a.ID, ProjectID: p.ID})
			return err
		}
		raw, err := json.Marshal(o)
		if err != nil {
			return err
		}
		_, err = q.UpsertOverride(ctx, store.UpsertOverrideParams{AgentID: a.ID, ProjectID: p.ID, Spec: raw, UpdatedByUserID: &by})
		return err
	})
}

// CurrentSpec loads the agent's current definition.
func CurrentSpec(ctx context.Context, q *store.Queries, a store.Agent) (agentdef.Spec, store.AgentDefinitionVersion, error) {
	if a.CurrentDefinitionVersionID == nil {
		return DefaultSpec(), store.AgentDefinitionVersion{}, nil
	}
	v, err := q.GetDefinitionVersion(ctx, *a.CurrentDefinitionVersionID)
	if err != nil {
		return agentdef.Spec{}, v, err
	}
	sp, err := DecodeSpec(v.Spec)
	return sp, v, err
}

// Resolve merges the agent's current definition with a project's override.
// projectKey "" resolves the bare definition.
func Resolve(ctx context.Context, q *store.Queries, ws uuid.UUID, a store.Agent, projectKey string) (agentdef.Resolved, error) {
	sp, _, err := CurrentSpec(ctx, q, a)
	if err != nil {
		return agentdef.Resolved{}, err
	}
	if projectKey == "" {
		return agentdef.Resolve(sp, nil), nil
	}
	p, err := q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: projectKey})
	if err != nil {
		return agentdef.Resolved{}, notFound(err)
	}
	row, err := q.GetOverride(ctx, store.GetOverrideParams{AgentID: a.ID, ProjectID: p.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return agentdef.Resolve(sp, nil), nil
	} else if err != nil {
		return agentdef.Resolved{}, err
	}
	o, err := DecodeOverride(row.Spec)
	if err != nil {
		return agentdef.Resolved{}, err
	}
	return agentdef.Resolve(sp, &o), nil
}

// ResolveRunnable is Resolve for callers that are about to start work: a
// target the runner cannot execute fails here with a field error instead of
// in the queue.
func ResolveRunnable(ctx context.Context, q *store.Queries, ws uuid.UUID, a store.Agent, projectKey string) (agentdef.Resolved, error) {
	r, err := Resolve(ctx, q, ws, a, projectKey)
	if err != nil {
		return r, err
	}
	if err := r.Validate(); err != nil {
		return r, apperr.Invalid("model", "%s", err.Error())
	}
	return r, nil
}

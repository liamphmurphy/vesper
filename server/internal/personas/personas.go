// Package personas stores a person's Assistant personas (wiki: Architecture/ADR -
// Assistant personas). Personas are private: every call takes the Owner and
// every query filters on it, so another person's persona is ErrNotFound.
package personas

import (
	"context"
	"errors"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	MaxPerPerson    = 40
	MaxNameRunes    = 60
	MaxInstructions = 2000
	DefaultColor    = "#64748b"
	DefaultTone     = "neutral"
)

// Tones are the accepted tone values; each maps to one fixed prompt sentence.
var Tones = []string{"neutral", "friendly", "concise", "formal", "playful"}

var colorRe = regexp.MustCompile(`^#[0-9a-fA-F]{6}$`)

// Owner is the person whose personas a call may see.
type Owner struct{ WorkspaceID, UserID uuid.UUID }

type Service struct{ Pool *pgxpool.Pool }

// NewInput creates a persona; nil fields take the defaults.
type NewInput struct {
	Name         string
	Tone         *string
	Color        *string
	Instructions *string
	IsDefault    bool
	// Capabilities and Repos are the structured settings that widen what the
	// persona's chats may do (runs.ChatSpec); nil takes the defaults (off, none).
	// Personas is whether it may propose new personas (each one approved by
	// the person); SVG whether its replies may show SVG images; Workflows
	// whether it may propose workflows and edits to them.
	Code, Images, Personas, SVG, Workflows, Connectors *bool
	Repos                                              *[]string
	// ImageEngine is the harness that makes this persona's images; "" (or nil)
	// inherits the workspace's choice.
	ImageEngine *string
	// TicketEdits is "ask" (nil: the default) or "allow": whether its ticket
	// edits from a chat wait for the person.
	TicketEdits *string
	// DefaultHarness/DefaultModel/DefaultEffort override Auto for new chats
	// and set the primary model for work definitions.
	DefaultHarness, DefaultModel, DefaultEffort *string
	// CharacterSVG is an optional sanitized 64x64 animated SVG character.
	CharacterSVG *string
}

// Patch edits a persona at Revision; nil fields are unchanged.
type Patch struct {
	Revision                                           int32
	Name                                               *string
	Tone                                               *string
	Color                                              *string
	Instructions                                       *string
	Code, Images, Personas, SVG, Workflows, Connectors *bool
	// Repos replaces the whole list; existing chats keep the repo they chose.
	Repos *[]string
	// ImageEngine changes the image engine ("" inherits the workspace's).
	ImageEngine *string
	// TicketEdits changes whether its ticket edits wait for the person.
	TicketEdits *string
	// InChatList changes whether it's offered in the chat switcher and the @ menu.
	InChatList *bool
	// DefaultHarness/DefaultModel/DefaultEffort update the persona's default
	// harness, model, and reasoning effort (empty / "auto" clears back to Auto).
	DefaultHarness, DefaultModel, DefaultEffort *string
	// RevealPace is how fast a new reply is revealed while the persona's
	// talking loop plays: auto, off, relaxed, natural or deliberate.
	RevealPace *string
	// VoiceMode, VoiceName and VoiceStyle set how its replies are spoken:
	// off, popout (only in the companion pop-out) or always; a provider voice
	// ("" for the default); a short delivery direction.
	VoiceMode, VoiceName, VoiceStyle *string
	// LoopSeconds is how long each of its state loops is (MinLoopSeconds-MaxLoopSeconds).
	LoopSeconds *int32
}

// The range a persona's loop length may take: Omni pins first and last
// frames, which makes a clip loop, only for clips up to 10s.
const (
	MinLoopSeconds = 4
	MaxLoopSeconds = 10
)

// VoiceModes are the accepted voice modes.
var VoiceModes = []string{"off", "popout", "always"}

// MaxVoiceStyleRunes bounds a voice's delivery direction.
const MaxVoiceStyleRunes = 200

// RevealPaces are the accepted reveal paces; auto lets the clients decide.
var RevealPaces = []string{"auto", "off", "relaxed", "natural", "deliberate"}

// checkTicketEdits accepts "ask" or "allow".
func checkTicketEdits(v *string) error {
	if v != nil && *v != "ask" && *v != "allow" {
		return apperr.Invalid("ticket_edits", "must be ask or allow")
	}
	return nil
}

func resolveDefaultModel(curHarness, curModel, curEffort string, inHarness, inModel, inEffort *string) (harness, model, effort string, changed bool, err error) {
	harness, model, effort = curHarness, curModel, curEffort
	if inHarness != nil || inModel != nil {
		var h, m string
		if inHarness != nil {
			h = strings.TrimSpace(*inHarness)
		}
		if inModel != nil {
			m = strings.TrimSpace(*inModel)
		}
		switch {
		case m == "" && h == "":
			if inModel != nil || inHarness != nil {
				harness, model = "", ""
			}
		case m == "auto":
			if h != "" {
				return "", "", "", false, apperr.Invalid("default_model", "cannot combine auto with a specific default_harness")
			}
			harness, model = "", ""
		case h == "" && m != "":
			if curHarness == "" {
				return "", "", "", false, apperr.Invalid("default_harness", "is required with default_model")
			}
			harness, model = curHarness, m
		case h != "" && m == "":
			return "", "", "", false, apperr.Invalid("default_model", "is required with default_harness")
		default:
			harness, model = h, m
		}
		if harness != "" && !slices.Contains(agentdef.Harnesses, harness) {
			return "", "", "", false, apperr.Invalid("default_harness", "must be one of %s", strings.Join(agentdef.Harnesses, ", "))
		}
		if utf8.RuneCountInString(model) > 100 {
			return "", "", "", false, apperr.Invalid("default_model", "must be at most 100 characters")
		}
	}
	if inEffort != nil {
		e := strings.TrimSpace(*inEffort)
		switch {
		case e == "", e == "default":
			effort = ""
		case slices.Contains(agentdef.Efforts, e):
			effort = e
		default:
			return "", "", "", false, apperr.Invalid("default_effort", "must be default, %s", strings.Join(agentdef.Efforts, ", "))
		}
	}
	changed = harness != curHarness || model != curModel || effort != curEffort
	return harness, model, effort, changed, nil
}

// checkImageEngine accepts "" (inherit), "auto" or an image-capable harness.
func checkImageEngine(engine *string) error {
	if engine == nil || *engine == "" || *engine == "auto" || slices.Contains(agentdef.ImageHarnesses, *engine) {
		return nil
	}
	return apperr.Invalid("capabilities.image_engine", "must be empty, auto, %s", strings.Join(agentdef.ImageHarnesses, " or "))
}

func normName(s string) (string, error) {
	s = strings.TrimSpace(s)
	if n := utf8.RuneCountInString(s); n < 1 || n > MaxNameRunes {
		return "", apperr.Invalid("name", "must be 1–%d characters", MaxNameRunes)
	}
	return s, nil
}

func checkTone(s string) error {
	if !slices.Contains(Tones, s) {
		return apperr.Invalid("tone", "must be one of %s", strings.Join(Tones, ", "))
	}
	return nil
}

func normColor(s string) (string, error) {
	if !colorRe.MatchString(s) {
		return "", apperr.Invalid("color", "must be a #rrggbb colour")
	}
	return strings.ToLower(s), nil
}

func checkInstructions(s string) error {
	if utf8.RuneCountInString(s) > MaxInstructions {
		return apperr.Invalid("custom_instructions", "must be at most %d characters", MaxInstructions)
	}
	if kind := memory.DetectSecret(s); kind != "" {
		return apperr.Invalid("custom_instructions", "looks like it contains a %s; remove it", kind)
	}
	return nil
}

// tx runs fn in a transaction holding the owner's persona lock, so default
// swaps, the per-person cap and name checks never race.
func (s *Service) tx(ctx context.Context, o Owner, fn func(q *store.Queries) error) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if err := LockOwner(ctx, q, o); err != nil {
			return err
		}
		return fn(q)
	})
}

// nameTaken maps a lost race on personas_name (or any unique name clash) to a 422.
func nameTaken(err error) error {
	var pe *pgconn.PgError
	if errors.As(err, &pe) && pe.Code == "23505" && pe.ConstraintName == "personas_name" {
		return apperr.Invalid("name", "you already have a persona with this name")
	}
	return err
}

func checkNameFree(ctx context.Context, q *store.Queries, o Owner, name string, except *uuid.UUID) error {
	taken, err := q.PersonaNameTaken(ctx, store.PersonaNameTakenParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Name: name, ExceptID: except})
	if err != nil {
		return err
	}
	if taken {
		return apperr.Invalid("name", "you already have a persona with this name")
	}
	return nil
}

func get(ctx context.Context, q *store.Queries, o Owner, id uuid.UUID) (store.Persona, error) {
	p, err := q.GetPersona(ctx, store.GetPersonaParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.ErrNotFound
	}
	return p, err
}

// List returns the owner's personas: the default first, then most recently used, then by name.
func (s *Service) List(ctx context.Context, o Owner) ([]store.Persona, error) {
	return store.New(s.Pool).ListPersonas(ctx, store.ListPersonasParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
}

// Get returns one of the owner's personas, or ErrNotFound.
func (s *Service) Get(ctx context.Context, o Owner, id uuid.UUID) (store.Persona, error) {
	return get(ctx, store.New(s.Pool), o, id)
}

// Default returns the owner's default persona, or nil for the built-in Assistant.
func (s *Service) Default(ctx context.Context, o Owner) (*store.Persona, error) {
	p, err := store.New(s.Pool).DefaultPersona(ctx, store.DefaultPersonaParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	return &p, nil
}

// Create adds a persona. With IsDefault it replaces the current default.
func (s *Service) Create(ctx context.Context, o Owner, in NewInput) (store.Persona, error) {
	var out store.Persona
	err := s.tx(ctx, o, func(q *store.Queries) error {
		var err error
		out, err = CreateLocked(ctx, q, o, in)
		return err
	})
	return out, err
}

// CreateLocked is Create inside the caller's transaction, which must already
// hold the owner's persona lock (LockPersonaOwner).
func CreateLocked(ctx context.Context, q *store.Queries, o Owner, in NewInput) (store.Persona, error) {
	if err := checkImageEngine(in.ImageEngine); err != nil {
		return store.Persona{}, err
	}
	if err := checkTicketEdits(in.TicketEdits); err != nil {
		return store.Persona{}, err
	}
	defHarness, defModel, defEffort, _, err := resolveDefaultModel("", "", "", in.DefaultHarness, in.DefaultModel, in.DefaultEffort)
	if err != nil {
		return store.Persona{}, err
	}
	var charSVG *string
	if in.CharacterSVG != nil && strings.TrimSpace(*in.CharacterSVG) != "" {
		checked, err := CheckCharacterSVG(*in.CharacterSVG)
		if err != nil {
			return store.Persona{}, err
		}
		charSVG = &checked
	}
	var out store.Persona
	name, err := normName(in.Name)
	if err != nil {
		return out, err
	}
	tone, color, instr := DefaultTone, DefaultColor, ""
	if in.Tone != nil {
		tone = *in.Tone
	}
	if err := checkTone(tone); err != nil {
		return out, err
	}
	if in.Color != nil {
		if color, err = normColor(*in.Color); err != nil {
			return out, err
		}
	}
	if in.Instructions != nil {
		instr = *in.Instructions
	}
	if err := checkInstructions(instr); err != nil {
		return out, err
	}
	repos := []string{}
	if in.Repos != nil {
		if repos, err = NormalizeRepos(*in.Repos); err != nil {
			return out, err
		}
	}
	n, err := q.CountPersonas(ctx, store.CountPersonasParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if err != nil {
		return out, err
	}
	if n >= MaxPerPerson {
		return out, apperr.Invalid("personas", "you can have at most %d personas", MaxPerPerson)
	}
	if err := checkNameFree(ctx, q, o, name, nil); err != nil {
		return out, err
	}
	if in.IsDefault {
		if err := q.ClearDefaultPersona(ctx, store.ClearDefaultPersonaParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, KeepID: uuid.Nil}); err != nil {
			return out, err
		}
	}
	out, err = q.CreatePersona(ctx, store.CreatePersonaParams{
		WorkspaceID: o.WorkspaceID, UserID: o.UserID, Name: name, Tone: tone, Color: color, CustomInstructions: instr, IsDefault: in.IsDefault,
		CanCode: in.Code != nil && *in.Code, CanGenerateImages: in.Images != nil && *in.Images, Repos: repos,
		CanCreatePersonas: in.Personas != nil && *in.Personas, CanCreateSvgs: in.SVG != nil && *in.SVG, CanCreateWorkflows: in.Workflows != nil && *in.Workflows,
		CanCreateConnectors: in.Connectors != nil && *in.Connectors,
		DefaultHarness:      defHarness, DefaultModel: defModel, DefaultEffort: defEffort,
	})
	if err == nil {
		for _, repo := range repos {
			if e := q.AddRepositorySource(ctx, store.AddRepositorySourceParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Kind: "repository", Name: repo}); e != nil {
				return out, e
			}
		}
		if in.ImageEngine != nil && *in.ImageEngine != "" {
			out, err = q.SetPersonaImageEngine(ctx, store.SetPersonaImageEngineParams{ID: out.ID, WorkspaceID: o.WorkspaceID, UserID: o.UserID, ImageEngine: *in.ImageEngine})
		}
		if err == nil && in.TicketEdits != nil && *in.TicketEdits != out.TicketEdits {
			out, err = q.SetPersonaTicketEdits(ctx, store.SetPersonaTicketEditsParams{ID: out.ID, WorkspaceID: o.WorkspaceID, UserID: o.UserID, TicketEdits: *in.TicketEdits})
		}
		if err == nil && charSVG != nil {
			out, err = q.SetPersonaCharacter(ctx, store.SetPersonaCharacterParams{
				ID: out.ID, WorkspaceID: o.WorkspaceID, UserID: o.UserID, CharacterSvg: *charSVG, SetAvatar: false,
			})
		}
	}
	return out, nameTaken(err)
}

// Draft is a persona another persona proposes: only the voice, never
// capabilities. CheckDraft normalizes it the way Create would.
type Draft struct {
	Name, Tone, Color, Instructions string
}

// CheckDraft validates and normalizes a proposed persona; empty tone and
// colour take the defaults.
func CheckDraft(d Draft) (Draft, error) {
	name, err := normName(d.Name)
	if err != nil {
		return d, err
	}
	d.Name = name
	if d.Tone == "" {
		d.Tone = DefaultTone
	}
	if err := checkTone(d.Tone); err != nil {
		return d, err
	}
	if d.Color == "" {
		d.Color = DefaultColor
	}
	if d.Color, err = normColor(d.Color); err != nil {
		return d, err
	}
	d.Instructions = strings.TrimSpace(d.Instructions)
	return d, checkInstructions(d.Instructions)
}

// LockOwner takes the owner's persona lock in the caller's transaction, for
// CreateLocked. Take it before any chat row lock: Delete holds it while it
// locks the persona's chats.
func LockOwner(ctx context.Context, q *store.Queries, o Owner) error {
	return q.LockPersonaOwner(ctx, store.LockPersonaOwnerParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
}

// Update edits a persona, checking the revision (stale is a 409). A change to
// the name, colour or capabilities re-renders the summary embedded in its chats, so those
// chats get chat.updated.
func (s *Service) Update(ctx context.Context, o Owner, id uuid.UUID, p Patch) (store.Persona, error) {
	var out store.Persona
	if err := checkImageEngine(p.ImageEngine); err != nil {
		return out, err
	}
	if err := checkTicketEdits(p.TicketEdits); err != nil {
		return out, err
	}
	if p.RevealPace != nil && !slices.Contains(RevealPaces, *p.RevealPace) {
		return out, apperr.Invalid("reveal_pace", "use one of %s", strings.Join(RevealPaces, ", "))
	}
	if p.LoopSeconds != nil && (*p.LoopSeconds < MinLoopSeconds || *p.LoopSeconds > MaxLoopSeconds) {
		return out, apperr.Invalid("loop_seconds", "use %d to %d seconds", MinLoopSeconds, MaxLoopSeconds)
	}
	if p.VoiceMode != nil && !slices.Contains(VoiceModes, *p.VoiceMode) {
		return out, apperr.Invalid("voice_mode", "use one of %s", strings.Join(VoiceModes, ", "))
	}
	if p.VoiceName != nil {
		v := strings.TrimSpace(*p.VoiceName)
		if len(v) > 60 || strings.ContainsFunc(v, func(r rune) bool {
			return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || r == '-' || r == '_')
		}) {
			return out, apperr.Invalid("voice_name", "pick a voice from the list")
		}
		p.VoiceName = &v
	}
	if p.VoiceStyle != nil {
		v := strings.TrimSpace(*p.VoiceStyle)
		if utf8.RuneCountInString(v) > MaxVoiceStyleRunes {
			return out, apperr.Invalid("voice_style", "at most %d characters", MaxVoiceStyleRunes)
		}
		p.VoiceStyle = &v
	}
	if p.Name != nil {
		name, err := normName(*p.Name)
		if err != nil {
			return out, err
		}
		p.Name = &name
	}
	if p.Tone != nil {
		if err := checkTone(*p.Tone); err != nil {
			return out, err
		}
	}
	if p.Color != nil {
		color, err := normColor(*p.Color)
		if err != nil {
			return out, err
		}
		p.Color = &color
	}
	if p.Instructions != nil {
		if err := checkInstructions(*p.Instructions); err != nil {
			return out, err
		}
	}
	var repos []string // nil leaves the list alone; an empty list clears it
	if p.Repos != nil {
		var err error
		if repos, err = NormalizeRepos(*p.Repos); err != nil {
			return out, err
		}
	}
	err := s.tx(ctx, o, func(q *store.Queries) error {
		cur, err := get(ctx, q, o, id)
		if err != nil {
			return err
		}
		if cur.Revision != p.Revision {
			return apperr.Conflict("the persona changed since you loaded it")
		}
		if p.Name != nil {
			if err := checkNameFree(ctx, q, o, *p.Name, &id); err != nil {
				return err
			}
		}
		defHarness, defModel, defEffort, modelChanged, err := resolveDefaultModel(
			cur.DefaultHarness, cur.DefaultModel, cur.DefaultEffort,
			p.DefaultHarness, p.DefaultModel, p.DefaultEffort,
		)
		if err != nil {
			return err
		}
		// Lock any active work record before updating personas so lock order
		// (agent, then persona) matches SaveDefinition and prevents deadlocks.
		var lockedAgent *store.Agent
		if modelChanged {
			rec, err := WorkRecord(ctx, q, o.WorkspaceID, id)
			if err != nil {
				return err
			}
			if WorkOf(rec) != WorkNone {
				locked, err := q.LockAgentByHandle(ctx, store.LockAgentByHandleParams{WorkspaceID: o.WorkspaceID, Handle: rec.Handle})
				if err != nil {
					return err
				}
				lockedAgent = &locked
			}
		}
		var nextHarness, nextModel, nextEffort *string
		if modelChanged {
			nextHarness, nextModel, nextEffort = &defHarness, &defModel, &defEffort
		}
		out, err = q.UpdatePersona(ctx, store.UpdatePersonaParams{
			ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID, Revision: p.Revision,
			Name: p.Name, Tone: p.Tone, Color: p.Color, CustomInstructions: p.Instructions,
			CanCode: p.Code, CanGenerateImages: p.Images, CanCreatePersonas: p.Personas, CanCreateSvgs: p.SVG, CanCreateWorkflows: p.Workflows, CanCreateConnectors: p.Connectors, Repos: repos,
			InChatList:     p.InChatList,
			DefaultHarness: nextHarness, DefaultModel: nextModel, DefaultEffort: nextEffort,
			RevealPace: p.RevealPace, VoiceMode: p.VoiceMode, VoiceName: p.VoiceName, VoiceStyle: p.VoiceStyle, LoopSeconds: p.LoopSeconds,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("the persona changed since you loaded it")
		}
		if err != nil {
			return nameTaken(err)
		}
		if p.ImageEngine != nil && *p.ImageEngine != out.ImageEngine {
			if out, err = q.SetPersonaImageEngine(ctx, store.SetPersonaImageEngineParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID, ImageEngine: *p.ImageEngine}); err != nil {
				return err
			}
		}
		if p.TicketEdits != nil && *p.TicketEdits != out.TicketEdits {
			if out, err = q.SetPersonaTicketEdits(ctx, store.SetPersonaTicketEditsParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID, TicketEdits: *p.TicketEdits}); err != nil {
				return err
			}
		}
		if lockedAgent != nil {
			spec, _, err := agents.CurrentSpec(ctx, q, *lockedAgent)
			if err != nil {
				return err
			}
			if defHarness != "" && defModel != "" {
				spec.SetModel(defHarness, defModel, defEffort)
			} else {
				def := agents.DefaultSpec()
				spec.SetModel(def.Harness, def.Model, defEffort)
			}
			if err := spec.Normalize(); err != nil {
				return apperr.Invalid("default_model", "%s", err.Error())
			}
			if _, err := agents.WriteVersion(ctx, q, *lockedAgent, agents.Identity{
				Name: out.Name, Role: lockedAgent.Role, Specialty: lockedAgent.Specialty, ColorIndex: int(lockedAgent.ColorIndex),
			}, spec, "Updated persona default model", &o.UserID, nil); err != nil {
				return err
			}
		} else if out.Name != cur.Name {
			// Its work record (if any) is named after it.
			if err := q.RenameAgent(ctx, store.RenameAgentParams{ID: id, Name: out.Name}); err != nil {
				return err
			}
		}
		for _, repo := range repos {
			if e := q.AddRepositorySource(ctx, store.AddRepositorySourceParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Kind: "repository", Name: repo}); e != nil {
				return e
			}
		}
		if out.Name != cur.Name || out.Color != cur.Color || out.CanCode != cur.CanCode || out.CanGenerateImages != cur.CanGenerateImages || out.CanCreatePersonas != cur.CanCreatePersonas || out.CanCreateSvgs != cur.CanCreateSvgs || out.CanCreateWorkflows != cur.CanCreateWorkflows {
			return NotifyChats(ctx, q, id)
		}
		return nil
	})
	return out, err
}

// SetDefault makes a persona the owner's default (idempotent). The old default
// is cleared before the new one is set, in one transaction.
func (s *Service) SetDefault(ctx context.Context, o Owner, id uuid.UUID) (store.Persona, error) {
	var out store.Persona
	err := s.tx(ctx, o, func(q *store.Queries) error {
		var err error
		if out, err = get(ctx, q, o, id); err != nil || out.IsDefault {
			return err
		}
		if err := q.ClearDefaultPersona(ctx, store.ClearDefaultPersonaParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, KeepID: id}); err != nil {
			return err
		}
		out, err = q.MarkDefaultPersona(ctx, store.MarkDefaultPersonaParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID})
		return err
	})
	return out, err
}

// Delete removes a persona and returns the deleted row (its avatar blob is the
// caller's to remove). A non-nil revision must match (409 when stale). Its
// chats fall back to the built-in Assistant through ON DELETE SET NULL, which
// fires chat.updated. Deleting the default promotes the most recently used
// remaining persona; with none left, the built-in Assistant is the default.
func (s *Service) Delete(ctx context.Context, o Owner, id uuid.UUID, revision *int32) (store.Persona, error) {
	var out store.Persona
	err := s.tx(ctx, o, func(q *store.Queries) error {
		cur, err := get(ctx, q, o, id)
		if err != nil {
			return err
		}
		if revision != nil && *revision != cur.Revision {
			return apperr.Conflict("the persona changed since you loaded it")
		}
		// A working persona's runs and tickets name it: turn its work off first, which keeps
		// that history and refuses while it holds open tickets or live runs.
		if rec, err := WorkRecord(ctx, q, o.WorkspaceID, id); err != nil {
			return err
		} else if WorkOf(rec) != WorkNone {
			return apperr.Conflict("%s still works on tickets or runs; turn its work off before deleting it", cur.Name)
		}
		if err := q.LockPersonaChats(ctx, id); err != nil {
			return err
		}
		if out, err = q.DeletePersona(ctx, store.DeletePersonaParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID}); err != nil {
			return err
		}
		if out.IsDefault {
			return q.PromoteDefaultPersona(ctx, store.PromoteDefaultPersonaParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
		}
		return nil
	})
	return out, err
}

// SetAvatar points the persona at an avatar already stored under key with the
// sniffed content type, or clears it when key is nil (a no-op without an
// avatar, so removing is idempotent). It returns the row and the key it
// replaced: that blob is the caller's to delete once this has committed. The
// owner lock serializes concurrent uploads, so each replaced key is returned
// to exactly one caller. Its chats get chat.updated, since their embedded
// summary carries the avatar URL.
func (s *Service) SetAvatar(ctx context.Context, o Owner, id uuid.UUID, key, contentType *string) (store.Persona, *string, error) {
	var out store.Persona
	var old *string
	if (key == nil) != (contentType == nil) {
		return out, nil, errors.New("personas: avatar key and content type go together")
	}
	err := s.tx(ctx, o, func(q *store.Queries) error {
		cur, err := get(ctx, q, o, id)
		if err != nil {
			return err
		}
		if key == nil && cur.AvatarKey == nil && cur.CharacterSvg == nil {
			out = cur
			return nil
		}
		out, err = q.SetPersonaAvatar(ctx, store.SetPersonaAvatarParams{
			ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID, AvatarKey: key, AvatarContentType: contentType,
		})
		if err != nil {
			return err
		}
		old = cur.AvatarKey
		return NotifyChats(ctx, q, id)
	})
	if err != nil {
		return out, nil, err
	}
	return out, old, nil
}

// SetCharacter validates and stores a persona's animated SVG character and
// updates or clears its fallback raster avatar (both key and contentType nil
// clears any old avatar blob). Returns the updated persona and any replaced
// avatar blob key for the caller to delete post-commit.
func (s *Service) SetCharacter(ctx context.Context, o Owner, id uuid.UUID, rawSVG string, key, contentType *string) (store.Persona, *string, error) {
	var out store.Persona
	var old *string
	if (key == nil) != (contentType == nil) {
		return out, nil, errors.New("personas: avatar key and content type go together")
	}
	checked, err := CheckCharacterSVG(rawSVG)
	if err != nil {
		return out, nil, err
	}
	err = s.tx(ctx, o, func(q *store.Queries) error {
		cur, err := get(ctx, q, o, id)
		if err != nil {
			return err
		}
		out, err = q.SetPersonaCharacter(ctx, store.SetPersonaCharacterParams{
			ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID,
			CharacterSvg: checked, SetAvatar: true, AvatarKey: key, AvatarContentType: contentType,
		})
		if err != nil {
			return err
		}
		old = cur.AvatarKey
		return NotifyChats(ctx, q, id)
	})
	if err != nil {
		return out, nil, err
	}
	return out, old, nil
}

// SetCharacterFallback attaches a rasterized PNG fallback avatar to a persona
// that already has a character_svg, returning any replaced avatar blob key.
func (s *Service) SetCharacterFallback(ctx context.Context, o Owner, id uuid.UUID, key, contentType string) (store.Persona, *string, error) {
	var out store.Persona
	var old *string
	err := s.tx(ctx, o, func(q *store.Queries) error {
		cur, err := get(ctx, q, o, id)
		if err != nil {
			return err
		}
		if cur.CharacterSvg == nil {
			out = cur
			return nil
		}
		out, err = q.SetPersonaCharacter(ctx, store.SetPersonaCharacterParams{
			ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID,
			CharacterSvg: *cur.CharacterSvg, SetAvatar: true, AvatarKey: &key, AvatarContentType: &contentType,
		})
		if err != nil {
			return err
		}
		old = cur.AvatarKey
		return NotifyChats(ctx, q, id)
	})
	if err != nil {
		return out, nil, err
	}
	return out, old, nil
}

// ClearCharacter removes a persona's animated SVG character and its fallback
// raster avatar (idempotent when the persona has no SVG character, leaving any
// uploaded photo untouched).
func (s *Service) ClearCharacter(ctx context.Context, o Owner, id uuid.UUID) (store.Persona, *string, error) {
	var out store.Persona
	var old *string
	err := s.tx(ctx, o, func(q *store.Queries) error {
		cur, err := get(ctx, q, o, id)
		if err != nil {
			return err
		}
		if cur.CharacterSvg == nil {
			out = cur
			return nil
		}
		out, err = q.ClearPersonaCharacter(ctx, store.ClearPersonaCharacterParams{
			ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID,
		})
		if err != nil {
			return err
		}
		old = cur.AvatarKey
		return NotifyChats(ctx, q, id)
	})
	if err != nil {
		return out, nil, err
	}
	return out, old, nil
}

// notifyBatch keeps each payload well under pg_notify's 8000 byte limit.
const notifyBatch = 50

// NotifyChats sends chat.updated for every chat using the persona, for changes
// that alter the embedded summary without writing chat_sessions (rename,
// colour, avatar). Run it inside the writing transaction: NOTIFY is delivered
// on commit.
func NotifyChats(ctx context.Context, q *store.Queries, persona uuid.UUID) error {
	ids, err := q.PersonaChatIDs(ctx, persona)
	if err != nil {
		return err
	}
	for len(ids) > 0 {
		n := min(len(ids), notifyBatch)
		batch := make([]string, n)
		for i, id := range ids[:n] {
			batch[i] = id.String()
		}
		if err := q.NotifyChatsUpdated(ctx, batch); err != nil {
			return err
		}
		ids = ids[n:]
	}
	return nil
}

// SeedDefault gives a new person the built-in "Assistant" default persona.
// It does nothing when they already have a default.
func SeedDefault(ctx context.Context, q *store.Queries, ws, user uuid.UUID) error {
	_, err := q.SeedDefaultPersona(ctx, store.SeedDefaultPersonaParams{WorkspaceID: ws, UserID: user})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	return err
}

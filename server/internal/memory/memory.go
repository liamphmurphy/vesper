// Package memory is the personal assistant's per-person memory store, kept
// apart from the shared wiki. Every operation takes an Owner and touches only
// that person's entries: there is no cross-person read or write.
//
// A person's memory splits in two: what the assistant remembers about the
// person (persona_id NULL), and each persona's own memory of who it is and of
// the moments it shared with the person (persona_id set). The Owner's
// PersonaID and Scope say which part an operation reaches.
package memory

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// RunTypes are the person's memory types a ticket run may read (ScopeRun).
var RunTypes = []string{"project", "work"}

// Types are the kinds of memory an entry can be. A moment (something the
// persona and the person shared) belongs in a persona's own memory only.
var Types = []string{"preference", "project", "person", "life", "work", "fact", "other", TypeMoment}

const TypeMoment = "moment"

const (
	maxTitle   = 200
	maxSummary = 300
	maxBody    = 20000
	maxTags    = 12
	maxTag     = 40
	maxReason  = 300

	// IndexSize caps the always-loaded index: enough to recognise what's
	// remembered, small enough to load every turn.
	IndexSize = 50
	// IndexProjectCap caps how many project entries occupy the always-loaded
	// index when non-project entries also exist, so project churn cannot evict
	// personal facts, preferences, or life context. Unused slots in either
	// bucket spill over to the other up to IndexSize.
	IndexProjectCap = 15
	// Near-duplicate thresholds (pg_trgm similarity, 0–1).
	dupTitle   = 0.6
	dupSummary = 0.75
)

// Owner is the one person whose memory an operation reads or writes, and
// which part of it.
type Owner struct {
	WorkspaceID uuid.UUID
	UserID      uuid.UUID
	// PersonaID is the persona whose own memory this is; nil is the person's
	// own memory. Save always writes exactly here.
	PersonaID *uuid.UUID
	// Scope widens what reads, edits and deletes reach beyond PersonaID's
	// memory. The zero value reaches only that memory.
	Scope Scope
	// SpaceID is the chat space the owner is in, when it keeps its own
	// memory: the person's memory also reaches that space's entries, and what
	// is saved about the person goes there. Nil reaches no space's entries
	// (ScopeAll reaches every one regardless).
	SpaceID *uuid.UUID
}

// Scope is how much of a person's memory an Owner reaches.
type Scope string

const (
	ScopeOwn  Scope = ""     // exactly PersonaID's memory (the person's own when nil)
	ScopeChat Scope = "chat" // the person's own plus PersonaID's: a persona chat
	// ScopeRun is what a ticket run may read: the person's project and work entries (never
	// life, preferences or anything else private) plus its persona's own memory. Runs read
	// untrusted text and write to the outside world, so the rest of a person's memory stays
	// out of them.
	ScopeRun      Scope = "run"
	ScopePersonas Scope = "personas" // every persona's, none of the person's own
	ScopeAll      Scope = "all"      // everything: the person's memory manager
)

// Person is the person's own memory, in the same space.
func (o Owner) Person() Owner {
	return Owner{WorkspaceID: o.WorkspaceID, UserID: o.UserID, SpaceID: o.SpaceID}
}

// Persona is one persona's own memory, which no space keeps apart.
func (o Owner) Persona(id uuid.UUID) Owner {
	return Owner{WorkspaceID: o.WorkspaceID, UserID: o.UserID, PersonaID: &id}
}

// InSpace is o inside a space that keeps its own memory; nil is outside any.
func (o Owner) InSpace(id *uuid.UUID) Owner {
	o.SpaceID = id
	return o
}

// saveSpace is the space a save lands in: the owner's, for the person's memory.
func (o Owner) saveSpace() *uuid.UUID {
	if o.PersonaID != nil {
		return nil
	}
	return o.SpaceID
}

func (o Owner) scope() string {
	if o.Scope == ScopeOwn {
		return "own"
	}
	return string(o.Scope)
}

// Source records where a memory came from.
type Source struct {
	Label  string // e.g. "chat 01a1…" or "manual"
	ChatID *uuid.UUID
	RunID  *uuid.UUID
}

// Input is a memory to save. Type defaults to "other".
type Input struct {
	Title   string
	Summary string
	Body    string
	Tags    []string
	Type    string
}

// Patch changes some fields of an entry; nil leaves a field alone. Move
// moves the entry to ToPersona's own memory, or the person's when nil.
type Patch struct {
	Title     *string
	Summary   *string
	Body      *string
	Tags      *[]string
	Type      *string
	Move      bool
	ToPersona *uuid.UUID
}

type Service struct{ Q *store.Queries }

func New(q *store.Queries) *Service { return &Service{Q: q} }

// SaveResult says whether Save added an entry or updated a near-duplicate;
// Previous is that entry as it was before the update.
type SaveResult struct {
	Memory   store.Memory
	Updated  bool
	Previous *store.Memory
}

// Save adds a memory to exactly o.PersonaID's memory (the person's own when
// nil), or updates that memory's near-duplicate entry instead. A moment is
// always added: each is its own thing. Secrets are refused.
func (s *Service) Save(ctx context.Context, o Owner, in Input, src Source) (SaveResult, error) {
	typeGiven := strings.TrimSpace(in.Type) != ""
	in, err := normalizeInput(in)
	if err != nil {
		return SaveResult{}, err
	}
	if err := checkMoment(in.Type, o.PersonaID); err != nil {
		return SaveResult{}, err
	}
	o = Owner{WorkspaceID: o.WorkspaceID, UserID: o.UserID, PersonaID: o.PersonaID, SpaceID: o.saveSpace()}
	if o.PersonaID != nil {
		if err := s.checkPersona(ctx, o, *o.PersonaID); err != nil {
			return SaveResult{}, err
		}
	}
	dup, err := store.NearDuplicateMemoryRow{}, pgx.ErrNoRows
	if in.Type != TypeMoment {
		dup, err = s.Q.NearDuplicateMemory(ctx, store.NearDuplicateMemoryParams{
			WorkspaceID: o.WorkspaceID, UserID: o.UserID, PersonaID: o.PersonaID, SpaceID: o.SpaceID, Title: in.Title, Summary: in.Summary,
			TitleThreshold: dupTitle, SummaryThreshold: dupSummary,
		})
	}
	switch {
	case err == nil:
		prev := dup.Memory
		p := Patch{Tags: new(mergeTags(prev.Tags, in.Tags))}
		// A match on the summary alone keeps the entry's title.
		if dup.TitleScore >= dupTitle {
			p.Title = &in.Title
		}
		if in.Summary != "" {
			p.Summary = &in.Summary
		}
		if in.Body != "" {
			p.Body = &in.Body
		}
		if typeGiven {
			p.Type = &in.Type
		}
		u, err := s.update(ctx, o, prev.ID, p, src)
		return SaveResult{Memory: u, Updated: true, Previous: &prev}, err
	case !errors.Is(err, pgx.ErrNoRows):
		return SaveResult{}, err
	}
	m, err := s.Q.CreateMemory(ctx, store.CreateMemoryParams{
		WorkspaceID: o.WorkspaceID, UserID: o.UserID, PersonaID: o.PersonaID, SpaceID: o.SpaceID, Title: in.Title, Summary: in.Summary, Body: in.Body,
		Tags: in.Tags, Type: in.Type, Source: src.Label, SourceChatID: src.ChatID, SourceRunID: src.RunID,
	})
	return SaveResult{Memory: m}, err
}

// Update edits an entry o reaches and, with p.Move, moves it between the
// person's and a persona's memory. A non-empty src.Label replaces the entry's
// source.
func (s *Service) Update(ctx context.Context, o Owner, id uuid.UUID, p Patch, src Source) (store.Memory, error) {
	if p.Title != nil {
		p.Title = new(strings.TrimSpace(*p.Title))
		if err := checkLen("title", *p.Title, 1, maxTitle); err != nil {
			return store.Memory{}, err
		}
	}
	if p.Summary != nil {
		p.Summary = new(oneLine(*p.Summary))
		if err := checkLen("summary", *p.Summary, 0, maxSummary); err != nil {
			return store.Memory{}, err
		}
	}
	if p.Body != nil {
		p.Body = new(strings.TrimSpace(*p.Body))
		if err := checkLen("body", *p.Body, 0, maxBody); err != nil {
			return store.Memory{}, err
		}
	}
	if p.Tags != nil {
		tags, err := normalizeTags(*p.Tags)
		if err != nil {
			return store.Memory{}, err
		}
		p.Tags = &tags
	}
	if p.Type != nil && !slices.Contains(Types, *p.Type) {
		return store.Memory{}, apperr.Invalid("type", "must be one of %s", strings.Join(Types, ", "))
	}
	if err := checkSecrets(deref(p.Title), deref(p.Summary), deref(p.Body), derefTags(p.Tags)); err != nil {
		return store.Memory{}, err
	}
	if p.Move || (p.Type != nil && *p.Type == TypeMoment) {
		if err := s.checkPlacement(ctx, o, id, p); err != nil {
			return store.Memory{}, err
		}
	}
	return s.update(ctx, o, id, p, src)
}

// checkPlacement refuses a patch that would leave a moment in the person's
// memory, move a retired entry, or move an entry to someone else's persona.
func (s *Service) checkPlacement(ctx context.Context, o Owner, id uuid.UUID, p Patch) error {
	cur, err := s.Get(ctx, o, id)
	if err != nil {
		return err
	}
	persona, typ := cur.PersonaID, cur.Type
	if p.Move {
		if cur.SupersededBy != nil {
			return apperr.Invalid("id", "a retired entry can't move; restore it first")
		}
		persona = p.ToPersona
	}
	if p.Type != nil {
		typ = *p.Type
	}
	if err := checkMoment(typ, persona); err != nil {
		return err
	}
	if p.Move && p.ToPersona != nil {
		return s.checkPersona(ctx, o, *p.ToPersona)
	}
	return nil
}

// checkPersona refuses a persona that isn't one of o's person's.
func (s *Service) checkPersona(ctx context.Context, o Owner, id uuid.UUID) error {
	_, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Invalid("persona_id", "must be one of your personas")
	}
	return err
}

func (s *Service) update(ctx context.Context, o Owner, id uuid.UUID, p Patch, src Source) (store.Memory, error) {
	arg := store.UpdateMemoryParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID, Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID,
		Title: p.Title, Summary: p.Summary, Body: p.Body, Type: p.Type, Move: p.Move, ToPersonaID: p.ToPersona}
	if p.Tags != nil {
		arg.Tags = *p.Tags
		if arg.Tags == nil {
			arg.Tags = []string{}
		}
	}
	if src.Label != "" {
		arg.Source, arg.SourceChatID, arg.SourceRunID = &src.Label, src.ChatID, src.RunID
	}
	m, err := s.Q.UpdateMemory(ctx, arg)
	return m, notFound(err)
}

// Supersede retires an entry in favour of another live entry of the same
// memory (the person's own, or the same persona's), recording why, or
// restores it when by is nil. A restored entry is never merged by
// consolidation again.
func (s *Service) Supersede(ctx context.Context, o Owner, id uuid.UUID, by *uuid.UUID, reason string) (store.Memory, error) {
	if by != nil && *by == id {
		return store.Memory{}, apperr.Invalid("superseded_by", "an entry can't supersede itself")
	}
	m, err := s.Q.SetMemorySupersededBy(ctx, store.SetMemorySupersededByParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID,
		Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID, SupersededBy: by,
		// Only a person restores (the memory manager), and that exempts the
		// entry from consolidation.
		RetiredReason: truncate(oneLine(reason), maxReason), RestoredByPerson: by == nil})
	if errors.Is(err, pgx.ErrNoRows) && by != nil {
		if _, gerr := s.Get(ctx, o, id); gerr != nil {
			return m, gerr
		}
		return m, apperr.Invalid("superseded_by", "must be another current entry of the same memory")
	}
	return m, notFound(err)
}

func (s *Service) Get(ctx context.Context, o Owner, id uuid.UUID) (store.Memory, error) {
	m, err := s.Q.GetMemory(ctx, store.GetMemoryParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID, Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID})
	return m, notFound(err)
}

// Query filters List and Search. An empty Text lists newest change first, or
// newest first with ByCreated.
type Query struct {
	Text           string
	Type           string
	IncludeRetired bool
	ByCreated      bool
	// Space, when set, keeps only that space's entries.
	Space         *uuid.UUID
	Limit, Offset int
}

// Hit is a memory with its search rank (0 when listing).
type Hit struct {
	store.Memory
	Rank float64
}

// Find searches (ranked) when q.Text is set, and lists otherwise.
func (s *Service) Find(ctx context.Context, o Owner, q Query) ([]Hit, error) {
	if q.Limit <= 0 || q.Limit > 200 {
		q.Limit = 20
	}
	var typ *string
	if q.Type != "" {
		if !slices.Contains(Types, q.Type) {
			return nil, apperr.Invalid("type", "must be one of %s", strings.Join(Types, ", "))
		}
		typ = &q.Type
	}
	text := strings.TrimSpace(q.Text)
	out := []Hit{}
	if text == "" {
		rows, err := s.Q.ListMemories(ctx, store.ListMemoriesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID,
			OnlySpace: q.Space, IncludeRetired: q.IncludeRetired, Type: typ, ByCreated: q.ByCreated, Lim: int32(q.Limit), Off: int32(max(q.Offset, 0))})
		for _, m := range rows {
			out = append(out, Hit{Memory: m})
		}
		return out, err
	}
	rows, err := s.Q.SearchMemories(ctx, store.SearchMemoriesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID,
		OnlySpace: q.Space, Q: text, IncludeRetired: q.IncludeRetired, Type: typ, Lim: int32(q.Limit)})
	for _, r := range rows {
		out = append(out, Hit{Memory: r.Memory, Rank: r.Rank})
	}
	return out, err
}

// Count is how many entries match q's type and retired filter (not its text).
func (s *Service) Count(ctx context.Context, o Owner, q Query) (int, error) {
	var typ *string
	if q.Type != "" {
		typ = &q.Type
	}
	n, err := s.Q.CountMemories(ctx, store.CountMemoriesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID,
		OnlySpace: q.Space, IncludeRetired: q.IncludeRetired, Type: typ})
	return int(n), err
}

// IndexEntry is one line of the always-loaded index.
type IndexEntry struct {
	ID      uuid.UUID `json:"id"`
	Title   string    `json:"title"`
	Summary string    `json:"summary"`
	Type    string    `json:"type"`
	// Space says the entry is the current space's, not the general memory's.
	Space bool `json:"space,omitempty"`
}

// Index lists up to IndexSize of the person's live entries (titles and
// summaries only) and the total number of live entries. Personas' own memories
// are never in it. At most IndexProjectCap slots are reserved for project
// entries when non-project entries also exist; unused slots spill over up to
// IndexSize.
func (s *Service) Index(ctx context.Context, o Owner) ([]IndexEntry, int, error) {
	o = o.Person()
	rows, err := s.Q.ListIndexMemories(ctx, store.ListIndexMemoriesParams{
		WorkspaceID: o.WorkspaceID, UserID: o.UserID, SpaceID: o.SpaceID, Lim: IndexSize,
	})
	if err != nil {
		return nil, 0, err
	}
	total, err := s.Count(ctx, o, Query{})
	if err != nil {
		return nil, 0, err
	}
	selected := selectIndexMemories(rows)
	out := make([]IndexEntry, len(selected))
	for i, m := range selected {
		out[i] = IndexEntry{ID: m.ID, Title: m.Title, Summary: m.Summary, Type: m.Type, Space: m.SpaceID != nil}
	}
	return out, total, nil
}

func compareMemoriesNewestFirst(a, b store.Memory) int {
	if !a.UpdatedAt.Equal(b.UpdatedAt) {
		if a.UpdatedAt.After(b.UpdatedAt) {
			return -1
		}
		return 1
	}
	return bytes.Compare(b.ID[:], a.ID[:])
}

func selectIndexMemories(rows []store.Memory) []store.Memory {
	var personal, project []store.Memory
	for _, m := range rows {
		if m.Type == "project" {
			project = append(project, m)
		} else {
			personal = append(personal, m)
		}
	}
	slices.SortFunc(personal, compareMemoriesNewestFirst)
	slices.SortFunc(project, compareMemoriesNewestFirst)

	personalQuota := IndexSize - IndexProjectCap
	takePersonal := min(len(personal), personalQuota)
	takeProject := min(len(project), IndexProjectCap)
	if rem := IndexSize - takePersonal - takeProject; rem > 0 {
		if extra := min(len(personal)-takePersonal, rem); extra > 0 {
			takePersonal += extra
			rem -= extra
		}
		if extra := min(len(project)-takeProject, rem); extra > 0 {
			takeProject += extra
		}
	}

	selected := make([]store.Memory, 0, takePersonal+takeProject)
	selected = append(selected, personal[:takePersonal]...)
	selected = append(selected, project[:takeProject]...)
	slices.SortFunc(selected, compareMemoriesNewestFirst)
	return selected
}

// IndexMarkdown renders the index for an assistant's context.
func IndexMarkdown(entries []IndexEntry, total int) string {
	var b strings.Builder
	b.WriteString("### Memory index\n\n")
	if total == 0 {
		b.WriteString("Nothing remembered yet.\n")
		return b.String()
	}
	b.WriteString("Titles and summaries only. Use read_memory(id) for the full entry, search_memory to find more.\n\n")
	for _, e := range entries {
		typ := e.Type
		if e.Space {
			typ += ", this space"
		}
		fmt.Fprintf(&b, "- `%s` [%s] %s", e.ID, typ, e.Title)
		if e.Summary != "" {
			fmt.Fprintf(&b, ": %s", e.Summary)
		}
		b.WriteString("\n")
	}
	if total > len(entries) {
		b.WriteString("\n…and more not listed here; search_memory finds them.\n")
	}
	return b.String()
}

// clearSuggestions drops the person's conversation starters before a forget,
// so a forgotten entry can't linger on the new-chat screen.
func (s *Service) clearSuggestions(ctx context.Context, o Owner) error {
	return s.Q.ClearChatSuggestions(ctx, store.ClearChatSuggestionsParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
}

// Forget deletes an entry o reaches and everything it superseded.
func (s *Service) Forget(ctx context.Context, o Owner, id uuid.UUID) error {
	if err := s.clearSuggestions(ctx, o); err != nil {
		return err
	}
	n, err := s.Q.DeleteMemory(ctx, store.DeleteMemoryParams{ID: id, WorkspaceID: o.WorkspaceID, UserID: o.UserID, Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID})
	if err == nil && n == 0 {
		return apperr.ErrNotFound
	}
	return err
}

// DeleteAll forgets everything o reaches and returns how many entries went
// (superseded entries cascade, so only top-level rows are counted).
func (s *Service) DeleteAll(ctx context.Context, o Owner) (int, error) {
	if err := s.clearSuggestions(ctx, o); err != nil {
		return 0, err
	}
	n, err := s.Q.DeleteAllMemories(ctx, store.DeleteAllMemoriesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Scope: o.scope(), PersonaID: o.PersonaID, SpaceID: o.SpaceID})
	return int(n), err
}

// Export returns every entry the person has, retired ones and personas'
// memories included.
func (s *Service) Export(ctx context.Context, o Owner) ([]store.Memory, error) {
	return s.Q.ExportMemories(ctx, store.ExportMemoriesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
}

func normalizeInput(in Input) (Input, error) {
	in.Title = strings.TrimSpace(in.Title)
	in.Summary = oneLine(in.Summary)
	in.Body = strings.TrimSpace(in.Body)
	if in.Type == "" {
		in.Type = "other"
	}
	if err := checkLen("title", in.Title, 1, maxTitle); err != nil {
		return in, err
	}
	if err := checkLen("summary", in.Summary, 0, maxSummary); err != nil {
		return in, err
	}
	if err := checkLen("body", in.Body, 0, maxBody); err != nil {
		return in, err
	}
	if !slices.Contains(Types, in.Type) {
		return in, apperr.Invalid("type", "must be one of %s", strings.Join(Types, ", "))
	}
	tags, err := normalizeTags(in.Tags)
	if err != nil {
		return in, err
	}
	in.Tags = tags
	if err := checkSecrets(in.Title, in.Summary, in.Body, in.Tags); err != nil {
		return in, err
	}
	return in, nil
}

// checkMoment refuses a moment outside a persona's own memory.
func checkMoment(typ string, persona *uuid.UUID) error {
	if typ == TypeMoment && persona == nil {
		return apperr.Invalid("type", "a moment belongs in a persona's own memory, not the person's")
	}
	return nil
}

// checkSecrets refuses any field that looks like it holds a credential.
func checkSecrets(title, summary, body string, tags []string) error {
	for _, f := range [][2]string{{"title", title}, {"summary", summary}, {"body", body}, {"tags", strings.Join(tags, " ")}} {
		if kind := DetectSecret(f[1]); kind != "" {
			return apperr.Invalid(f[0], "looks like it contains a %s; credentials and tokens are never stored in memory. Leave the secret out and save the rest", kind)
		}
	}
	return nil
}

// normalizeTags lowercases, trims, dedupes and caps tags. Never nil.
func normalizeTags(tags []string) ([]string, error) {
	out := []string{}
	for _, t := range tags {
		t = strings.ToLower(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(t), "#")))
		if t == "" || slices.Contains(out, t) {
			continue
		}
		if utf8.RuneCountInString(t) > maxTag {
			return nil, apperr.Invalid("tags", "%q is longer than %d characters", t, maxTag)
		}
		out = append(out, t)
	}
	if len(out) > maxTags {
		return nil, apperr.Invalid("tags", "at most %d tags", maxTags)
	}
	return out, nil
}

func mergeTags(old, add []string) []string {
	out := slices.Clone(old)
	for _, t := range add {
		if !slices.Contains(out, t) && len(out) < maxTags {
			out = append(out, t)
		}
	}
	return out
}

// truncate cuts s to at most n runes.
func truncate(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n-1]) + "…"
}

func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

func checkLen(field, v string, lo, hi int) error {
	if n := utf8.RuneCountInString(v); n < lo || n > hi {
		if lo > 0 {
			return apperr.Invalid(field, "must be %d–%d characters", lo, hi)
		}
		return apperr.Invalid(field, "must be at most %d characters", hi)
	}
	return nil
}

func notFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound
	}
	return err
}

func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func derefTags(p *[]string) []string {
	if p == nil {
		return nil
	}
	return *p
}

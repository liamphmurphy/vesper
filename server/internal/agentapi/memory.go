package agentapi

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Memory tools: the personal assistant's per-person memory. In a chat they work on the
// memory of the person the chat belongs to: the person's own memory, plus (in a persona
// chat) that one persona's own memory. No chat reaches another persona's memory.
//
// A ticket run of a persona (or a run it handed work to) may only search and read, and only
// the person's project and work entries plus that persona's own memory (memory.ScopeRun):
// runs read untrusted text and write to the outside world, so the rest of a person's
// memory, their life and preferences, never reaches one.

// temporaryChatRefusal is what memory and chat history tools answer in a
// temporary chat.
const temporaryChatRefusal = "this is a temporary chat: it doesn't use the person's memory or past chats"

const (
	aboutPerson  = "person"
	aboutPersona = "persona"
)

type SearchMemoryIn struct {
	Query          string `json:"query,omitempty" jsonschema:"Words to look for in titles, tags, summaries and bodies; empty lists the newest entries"`
	Type           string `json:"type,omitempty" jsonschema:"Only this type: preference, project, person, life, work, fact, other or moment"`
	Limit          int    `json:"limit,omitempty" jsonschema:"Up to 50, default 10"`
	IncludeRetired bool   `json:"include_retired,omitempty" jsonschema:"Also return entries superseded by newer ones"`
	About          string `json:"about,omitempty" jsonschema:"Whose memory: person (default, what you remember about the person) or persona (your own memory as this chat's persona)"`
}

type MemoryIDIn struct {
	ID string `json:"id" jsonschema:"Memory id from the index, your own memory, search_memory or save_memory"`
}

type SaveMemoryIn struct {
	Title   string   `json:"title" jsonschema:"Short name for the memory, e.g. Prefers metric units"`
	Summary string   `json:"summary,omitempty" jsonschema:"One line saying what to remember"`
	Body    string   `json:"body,omitempty" jsonschema:"Details, if the summary isn't enough"`
	Tags    []string `json:"tags,omitempty" jsonschema:"A few lowercase keywords"`
	Type    string   `json:"type,omitempty" jsonschema:"One of preference, project (standing high-level project context only — not PR logs or technical decisions), person, life, work, fact, other (default other); moment (a shared moment) only with about persona"`
	About   string   `json:"about,omitempty" jsonschema:"Whose memory: person (default: facts about the person) or persona (your own identity, traits, history, appearance and shared moments; persona chats only)"`
}

type UpdateMemoryIn struct {
	ID           string    `json:"id" jsonschema:"Memory id"`
	Title        *string   `json:"title,omitempty"`
	Summary      *string   `json:"summary,omitempty"`
	Body         *string   `json:"body,omitempty"`
	Tags         *[]string `json:"tags,omitempty" jsonschema:"Replaces all tags"`
	Type         *string   `json:"type,omitempty" jsonschema:"One of preference, project, person, life, work, fact, other, moment (persona memory only)"`
	SupersededBy string    `json:"superseded_by,omitempty" jsonschema:"Retire this entry in favour of the newer entry with this id (in the same memory)"`
	MoveTo       string    `json:"move_to,omitempty" jsonschema:"Move the entry to person (the person's memory) or persona (your own memory as this chat's persona)"`
}

// memoryEntry is a memory as the assistant reads it.
type memoryEntry struct {
	ID uuid.UUID `json:"id"`
	// About is person (the person's memory) or persona (the chat persona's own).
	About string `json:"about"`
	// ThisSpace marks an entry of this chat's space memory: only chats in the
	// space see it.
	ThisSpace    bool       `json:"this_space,omitempty"`
	Title        string     `json:"title"`
	Summary      string     `json:"summary"`
	Body         string     `json:"body,omitempty"`
	Tags         []string   `json:"tags"`
	Type         string     `json:"type"`
	Source       string     `json:"source,omitempty"`
	SupersededBy *uuid.UUID `json:"superseded_by,omitempty"`
	// RetiredReason says why a retired entry was retired (e.g. merged by
	// memory consolidation).
	RetiredReason string `json:"retired_reason,omitempty"`
	CreatedAt     string `json:"created_at"`
	UpdatedAt     string `json:"updated_at"`
}

func toMemoryEntry(m store.Memory, withBody bool) memoryEntry {
	e := memoryEntry{ID: m.ID, About: aboutPerson, Title: m.Title, Summary: m.Summary, Tags: m.Tags, Type: m.Type, Source: m.Source,
		SupersededBy: m.SupersededBy, RetiredReason: m.RetiredReason, CreatedAt: m.CreatedAt.UTC().Format("2006-01-02T15:04:05Z"), UpdatedAt: m.UpdatedAt.UTC().Format("2006-01-02T15:04:05Z")}
	if m.PersonaID != nil {
		e.About = aboutPersona
	}
	e.ThisSpace = m.SpaceID != nil
	if withBody {
		e.Body = m.Body
	}
	return e
}

// chatMemory is the memory a chat run may use: the person's own, and the
// chat's persona (nil without one).
type chatMemory struct {
	person  memory.Owner
	persona *uuid.UUID
	src     memory.Source
}

// memoryOwner is the person whose memory a chat run may use, and the source
// to stamp on what it writes.
func memoryOwner(ctx context.Context, d Deps, c agents.Caller) (chatMemory, error) {
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return chatMemory{}, err
	}
	if s == nil {
		return chatMemory{}, apperr.Conflict("memory tools only work in a chat with a person (a persona's ticket run may search and read its project and work memories)")
	}
	if s.Temporary {
		return chatMemory{}, apperr.Conflict(temporaryChatRefusal)
	}
	return chatMemory{person: memory.Owner{WorkspaceID: c.Agent.WorkspaceID, UserID: s.UserID, SpaceID: s.MemorySpaceID}, persona: s.PersonaID,
		src: memory.Source{Label: "chat " + s.ChatID.String(), ChatID: &s.ChatID, RunID: c.RunID}}, nil
}

// about picks the person's memory or the chat persona's own. A chat without a
// persona has no persona memory.
func (m chatMemory) about(field, v string) (memory.Owner, error) {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "", aboutPerson:
		return m.person, nil
	case aboutPersona:
		if m.persona == nil {
			return memory.Owner{}, apperr.Invalid(field, "this chat has no persona, so there's no persona memory; use person")
		}
		return m.person.Persona(*m.persona), nil
	}
	return memory.Owner{}, apperr.Invalid(field, "must be person or persona")
}

// reach is everything the chat may read, change or forget by id: the person's
// memory plus its own persona's.
func (m chatMemory) reach() memory.Owner {
	o := m.person
	o.PersonaID, o.Scope = m.persona, memory.ScopeChat
	return o
}

// runMemory is what a persona's ticket run may read (ScopeRun): nil when the caller isn't
// a ticket run, or its work record has no persona.
func runMemory(ctx context.Context, d Deps, c agents.Caller) (*memory.Owner, error) {
	if c.RunID == nil {
		return nil, nil
	}
	run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
	if err != nil || run.TicketID == nil || run.Purpose == "chat" {
		return nil, err
	}
	p, err := d.Q.PersonaOwnerOf(ctx, store.PersonaOwnerOfParams{ID: run.AgentID, WorkspaceID: run.WorkspaceID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	o := memory.Owner{WorkspaceID: p.WorkspaceID, UserID: p.UserID, PersonaID: &p.ID, Scope: memory.ScopeRun}
	// Entries saved in the ticket's space (when it keeps its own memory) are part of it too.
	t, err := d.Q.GetTicketByID(ctx, *run.TicketID)
	if err != nil {
		return nil, err
	}
	proj, err := d.Q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: run.WorkspaceID})
	if err != nil {
		return nil, err
	}
	if proj.SpaceID != nil {
		sp, err := d.Q.GetChatSpace(ctx, store.GetChatSpaceParams{ID: *proj.SpaceID, WorkspaceID: run.WorkspaceID, UserID: p.UserID})
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		if err == nil && sp.SpaceMemory {
			o.SpaceID = &sp.ID
		}
	}
	return &o, nil
}

func searchMemory(ctx context.Context, d Deps, c agents.Caller, in SearchMemoryIn) (any, error) {
	if ro, err := runMemory(ctx, d, c); err != nil {
		return nil, err
	} else if ro != nil {
		o := *ro
		if strings.EqualFold(strings.TrimSpace(in.About), aboutPersona) {
			o = o.Persona(*ro.PersonaID)
		} else if in.Type != "" && in.Type != "project" && in.Type != "work" {
			return nil, apperr.Invalid("type", "a run reads only project and work memories")
		}
		return findMemory(ctx, d, o, in)
	}
	cm, err := memoryOwner(ctx, d, c)
	if err != nil {
		return nil, err
	}
	o, err := cm.about("about", in.About)
	if err != nil {
		return nil, err
	}
	return findMemory(ctx, d, o, in)
}

func findMemory(ctx context.Context, d Deps, o memory.Owner, in SearchMemoryIn) (any, error) {
	if in.Limit <= 0 || in.Limit > 50 {
		in.Limit = 10
	}
	hits, err := memory.New(d.Q).Find(ctx, o, memory.Query{Text: in.Query, Type: in.Type, Limit: in.Limit, IncludeRetired: in.IncludeRetired})
	if err != nil {
		return nil, err
	}
	out := make([]memoryEntry, len(hits))
	for i, h := range hits {
		out[i] = toMemoryEntry(h.Memory, false)
	}
	return map[string]any{"memories": out, "hint": "Open one with read_memory(id)."}, nil
}

func readMemory(ctx context.Context, d Deps, c agents.Caller, in MemoryIDIn) (any, error) {
	id, err := parseUUID("id", in.ID)
	if err != nil {
		return nil, err
	}
	reach := memory.Owner{}
	if ro, err := runMemory(ctx, d, c); err != nil {
		return nil, err
	} else if ro != nil {
		reach = *ro
	} else {
		cm, err := memoryOwner(ctx, d, c)
		if err != nil {
			return nil, err
		}
		reach = cm.reach()
	}
	m, err := memory.New(d.Q).Get(ctx, reach, id)
	if err != nil {
		return nil, err
	}
	return toMemoryEntry(m, true), nil
}

func saveMemory(ctx context.Context, d Deps, c agents.Caller, in SaveMemoryIn) (any, error) {
	cm, err := memoryOwner(ctx, d, c)
	if err != nil {
		return nil, err
	}
	o, err := cm.about("about", in.About)
	if err != nil {
		return nil, err
	}
	r, err := memory.New(d.Q).Save(ctx, o, memory.Input{Title: in.Title, Summary: in.Summary, Body: in.Body, Tags: in.Tags, Type: in.Type}, cm.src)
	if err != nil {
		return nil, err
	}
	where := ""
	if o.PersonaID != nil {
		where = " (in my own memory)"
	} else if r.Memory.SpaceID != nil {
		where = " (in this space's memory)"
	}
	out := map[string]any{"id": r.Memory.ID, "action": "created", "about": toMemoryEntry(r.Memory, false).About, "title": r.Memory.Title,
		"tell_the_person": "Remembered" + where + ": " + r.Memory.Title + ". Say so in your reply, and that they can ask you to forget it."}
	if r.Updated {
		p := r.Previous
		out["action"] = "updated"
		out["previous"] = map[string]any{"id": p.ID, "title": p.Title, "summary": p.Summary, "type": p.Type}
		out["tell_the_person"] = "Updated what I remember" + where + ": '" + p.Title + "' is now '" + r.Memory.Title + "'. Say so in your reply; if this wasn't the same thing, save it again with a more distinct title and restore the old entry with update_memory."
	}
	return out, nil
}

func updateMemory(ctx context.Context, d Deps, c agents.Caller, in UpdateMemoryIn) (any, error) {
	cm, err := memoryOwner(ctx, d, c)
	if err != nil {
		return nil, err
	}
	id, err := parseUUID("id", in.ID)
	if err != nil {
		return nil, err
	}
	p := memory.Patch{Title: in.Title, Summary: in.Summary, Body: in.Body, Tags: in.Tags, Type: in.Type}
	if strings.TrimSpace(in.MoveTo) != "" {
		to, err := cm.about("move_to", in.MoveTo)
		if err != nil {
			return nil, err
		}
		p.Move, p.ToPersona = true, to.PersonaID
	}
	o, svc := cm.reach(), memory.New(d.Q)
	var m store.Memory
	if p.Title != nil || p.Summary != nil || p.Body != nil || p.Tags != nil || p.Type != nil || p.Move {
		if m, err = svc.Update(ctx, o, id, p, cm.src); err != nil {
			return nil, err
		}
	}
	if s := strings.TrimSpace(in.SupersededBy); s != "" {
		by, err := parseUUID("superseded_by", s)
		if err != nil {
			return nil, err
		}
		if m, err = svc.Supersede(ctx, o, id, &by, "Replaced by the assistant"); err != nil {
			return nil, err
		}
	}
	if m.ID == uuid.Nil {
		return nil, apperr.Invalid("id", "give at least one field to change")
	}
	tell := "Updated what I remember: " + m.Title + "."
	if p.Move {
		tell = "Moved '" + m.Title + "' to the person's memory."
		if m.PersonaID != nil {
			tell = "Moved '" + m.Title + "' to my own memory."
		}
	}
	return map[string]any{"memory": toMemoryEntry(m, false), "tell_the_person": tell}, nil
}

func forgetMemory(ctx context.Context, d Deps, c agents.Caller, in MemoryIDIn) (any, error) {
	cm, err := memoryOwner(ctx, d, c)
	if err != nil {
		return nil, err
	}
	id, err := parseUUID("id", in.ID)
	if err != nil {
		return nil, err
	}
	o, svc := cm.reach(), memory.New(d.Q)
	m, err := svc.Get(ctx, o, id)
	if err != nil {
		return nil, err
	}
	if err := svc.Forget(ctx, o, id); err != nil {
		return nil, err
	}
	return map[string]any{"forgotten": m.ID, "title": m.Title, "tell_the_person": "Forgot: " + m.Title + "."}, nil
}

type SetChatTitleIn struct {
	Title string `json:"title" jsonschema:"Concise title for this conversation, 2–6 words"`
}

// setChatTitle names the chat; it never overwrites a title the person set.
func setChatTitle(ctx context.Context, d Deps, c agents.Caller, in SetChatTitleIn) (any, error) {
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, apperr.Conflict("set_chat_title only works in a chat with a person")
	}
	title := strings.Join(strings.Fields(in.Title), " ")
	title = strings.TrimSpace(strings.TrimRight(strings.Trim(title, "\"'`“”‘’"), "."))
	if n := len([]rune(title)); n < 1 || n > 80 {
		return nil, apperr.Invalid("title", "provide 1–80 characters")
	}
	applied, chat, err := d.Runs.SetAgentChatTitle(ctx, s.ChatID, title)
	if err != nil {
		return nil, err
	}
	if !applied {
		return map[string]any{"applied": false, "title": chat.Title, "reason": "The person already named this conversation; leave it."}, nil
	}
	return map[string]any{"title": chat.Title, "applied": true}, nil
}

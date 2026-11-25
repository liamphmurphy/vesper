package agentapi

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// chatTools is the whole MCP surface of a chat run (runs.ChatTools, which a
// chat segment compares to tell the model when its tools change). Everything
// else, including tools added later, is refused for chats.
var chatTools = runs.ChatTools

// asideTools is the MCP surface of an aside (a chat answering a question
// about another chat's running reply): chatTools that only read.
var asideTools = []string{"list_pages", "page_outline", "list_page_versions", "list_page_reviews", "knowledge_graph", "list_imports", "suggest_links", "whoami", "search_knowledge", "read_page", "read_artifact", "get_backlinks", "list_projects",
	"search_memory", "read_memory", "search_chats", "read_chat", "search_repositories", "get_video_transcript", "list_saved_links", "search_library", "read_library_item", "list_inbox", "canvas_read", "canvas_list", "design_flows", "list_workflows", "read_workflow", "list_scheduled_tasks", "list_learning_modules", "get_learning_progress", "list_connectors", "list_secret_names", "list_custom_apps", "get_custom_app", "http_list_workspaces", "http_get_workspace"}

// isAsideRun reports whether a chat run answers an aside. An unreadable spec
// counts as one, so the check fails closed.
func isAsideRun(run store.Run) bool {
	spec, err := runs.Spec(run)
	return err != nil || spec.HarnessOptions[agentdef.OptionAside] == "true"
}

// chatScope is who a chat run acts for. A chat reads the whole workspace, like
// ticket agents do: the person can open every project, so a project boundary
// here protected nothing and only got in the way. ProjectKey is the chat's
// default project ("" when it has none): where new tickets and epics go
// unless the persona names another.
type chatScope struct {
	ChatID     uuid.UUID
	ProjectKey string
	// UserID is the person the chat belongs to: the owner of its memory.
	UserID uuid.UUID
	// PersonaID is the persona answering the chat (its speaker, else its host),
	// the one persona memory it may reach.
	PersonaID *uuid.UUID
	// SpaceID is the chat's space, if any, regardless of its memory setting.
	SpaceID *uuid.UUID
	// MemorySpaceID is the chat's space when that space keeps its own memory.
	MemorySpaceID *uuid.UUID
	// Temporary chats reach neither the person's memory nor their past chats.
	Temporary bool
}

// chatScopeFor is nil unless the caller's token belongs to a chat run.
func chatScopeFor(ctx context.Context, d Deps, c agents.Caller) (*chatScope, error) {
	if c.RunID == nil {
		return nil, nil
	}
	run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
	if err != nil {
		return nil, err
	}
	if run.Purpose == runs.PurposeWorkflow {
		return workflowScope(ctx, d, run)
	}
	if run.Purpose != "chat" {
		return nil, nil
	}
	chat, err := d.Q.ChatSessionForRun(ctx, c.RunID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Conflict("this chat run is no longer attached to a chat")
	}
	if err != nil {
		return nil, err
	}
	p, err := runs.OptionalProject(ctx, d.Q, chat.WorkspaceID, chat.ProjectID)
	if err != nil {
		return nil, err
	}
	memSpace, err := runs.ChatMemorySpace(ctx, d.Q, chat)
	if err != nil {
		return nil, err
	}
	return &chatScope{ChatID: chat.ID, ProjectKey: p.Key, UserID: chat.CreatedBy, PersonaID: runs.ChatSpeakerID(chat), SpaceID: chat.SpaceID, MemorySpaceID: memSpace, Temporary: chat.Temporary}, nil
}

// projectFilter resolves the optional project key a listing or search is
// narrowed to; nil means every project.
func projectFilter(ctx context.Context, d Deps, ws uuid.UUID, key string) (*uuid.UUID, error) {
	key = strings.ToUpper(strings.TrimSpace(key))
	if key == "" {
		return nil, nil
	}
	p, err := d.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: key})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Invalid("project", "no project %s", key)
	}
	if err != nil {
		return nil, err
	}
	return &p.ID, nil
}

// where names the chat for its instructions.
func (s *chatScope) where() string {
	if s.ProjectKey == "" {
		return "a chat with no default project"
	}
	return "a chat whose default project is " + s.ProjectKey
}

// mainAgent resolves the optional handle a chat assigns a new ticket to.
// Only main agents can be dispatched, so sub agents and the assistant are
// refused up front rather than when the ticket is started.
func mainAgent(ctx context.Context, d Deps, ws uuid.UUID, handle string) (*uuid.UUID, error) {
	handle = strings.ToLower(strings.TrimPrefix(strings.TrimSpace(handle), "@"))
	if handle == "" {
		return nil, nil
	}
	a, err := d.Q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: handle})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Invalid("agent", "no persona @%s works on tickets", handle)
	}
	if err != nil {
		return nil, err
	}
	if a.Kind != agents.KindMain {
		return nil, apperr.Invalid("agent", "@%s helps on runs and can't take tickets; assign a persona that takes tickets, which can hand it work", a.Handle)
	}
	return &a.ID, nil
}

// targetProject is where a chat creates a ticket or epic: the project the
// persona named, else the chat's default. With neither, the error lists the
// projects so the persona can ask which one.
func (s *chatScope) targetProject(ctx context.Context, d Deps, ws uuid.UUID, key string) (store.Project, error) {
	key = strings.ToUpper(strings.TrimSpace(key))
	if key == "" {
		key = s.ProjectKey
	}
	if key == "" {
		all, err := d.Q.ListProjects(ctx, ws)
		if err != nil {
			return store.Project{}, err
		}
		var keys []string
		for _, p := range all {
			if !p.Archived {
				keys = append(keys, p.Key)
			}
		}
		return store.Project{}, apperr.Invalid("project", "this chat has no default project; pass one of %s, or ask the person which", strings.Join(keys, ", "))
	}
	p, err := d.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: key})
	if errors.Is(err, pgx.ErrNoRows) {
		return p, apperr.Invalid("project", "no project %s", key)
	}
	if err != nil {
		return p, err
	}
	if p.Archived {
		return p, apperr.Conflict("project %s is archived; restore it first", p.Key)
	}
	return p, nil
}

const chatInstructions = `You are the person's Personal Assistant, chatting in %s (chat %s). Answer directly.
Look things up with list_tickets, list_projects, list_runs, get_run, get_ticket, list_epics, search_knowledge, read_page, read_artifact and get_backlinks; search first and open only what matters. Cite what you used with [[…]] links.
You can read every project. Use create_ticket and create_epic when asked and return their identifiers: they go to the chat's default project unless you pass project, and with no default, ask the person which project. Change existing tickets with update_ticket and comment_ticket when asked, or to keep a ticket you're working on in this chat current. Unless the person lets you edit tickets without asking, those edits are proposals the person applies or declines on a card in the chat: say so, and never call a proposed change done. Never claim tickets, execute project work, or delegate.
You keep a private memory of this person: find entries with search_memory and read_memory, save with save_memory (it updates near-duplicates), and tell the person whenever you save something. Never store credentials or tokens. Honour "forget that" with forget_memory, and save nothing when told "don't remember this". In a persona chat, about: "persona" reaches the persona's own memory (its identity and shared moments) instead.
set_chat_title names the conversation on its first message. When the person shares a YouTube link, read it with get_video_transcript before reacting to the video.
Tools from other MCP servers are the person's connectors. A write tool may pause until the person approves it. If a tool says it was denied, don't retry it. To add a connector, check list_connectors first, then use propose_connector when you're allowed to; never ask for a token in chat.
To call an API with the person's token or key, use http_request from vesper_secrets (list_secrets shows what you may use); you never see a value. If you need one they haven't added (list_secret_names shows what they have), use propose_secret when you're allowed to, and never ask for it in chat. If someone pastes a token into chat anyway, don't repeat it; suggest saving it in Customization › Secrets.
When the person asks, set things up for them with create_space, create_scheduled_task and create_learning_module, then link what you made. Change, pause or remove their scheduled tasks with list_scheduled_tasks, update_scheduled_task and delete_scheduled_task.`

type NewEpicIn struct {
	Project        string   `json:"project,omitempty" jsonschema:"Project key, e.g. PAY; default the chat's default project"`
	Name           string   `json:"name"`
	Objective      string   `json:"objective,omitempty"`
	RequiresMockup bool     `json:"requires_mockup,omitempty" jsonschema:"Tickets in the epic need a person-approved UI mockup before they can be finished"`
	Criteria       []string `json:"criteria,omitempty" jsonschema:"Optional final acceptance criteria for the epic, one checkable sentence each"`
}

// chatEpic is a list_epics row: the epic plus its status, points and criteria counts.
type chatEpic struct {
	store.Epic
	Project       string
	CriteriaTotal int32
	CriteriaDone  int32
	PointsTotal   int32
	PointsDone    int32
	TicketsTotal  int32
	TicketsOpen   int32
}

type ListEpicsIn struct {
	Project string `json:"project,omitempty" jsonschema:"Only epics in this project key, e.g. PAY; default every project"`
}

func listChatEpics(ctx context.Context, d Deps, c agents.Caller, in ListEpicsIn) (any, error) {
	if _, err := requireChat(ctx, d, c); err != nil {
		return nil, err
	}
	project, err := projectFilter(ctx, d, c.Agent.WorkspaceID, in.Project)
	if err != nil {
		return nil, err
	}
	rows, err := d.Q.ListEpics(ctx, c.Agent.WorkspaceID)
	if err != nil {
		return nil, err
	}
	projects, err := d.Q.ListProjects(ctx, c.Agent.WorkspaceID)
	if err != nil {
		return nil, err
	}
	keys := make(map[uuid.UUID]string, len(projects))
	for _, p := range projects {
		keys[p.ID] = p.Key
	}
	out := []chatEpic{}
	ids := []uuid.UUID{}
	for _, e := range rows {
		if project == nil || e.ProjectID == *project {
			out = append(out, chatEpic{Epic: e, Project: keys[e.ProjectID]})
			ids = append(ids, e.ID)
		}
	}
	rolls, err := d.Q.EpicRollups(ctx, ids)
	if err != nil {
		return nil, err
	}
	byID := make(map[uuid.UUID]store.EpicRollupsRow, len(rolls))
	for _, r := range rolls {
		byID[r.EpicID] = r
	}
	for i := range out {
		r := byID[out[i].ID]
		out[i].CriteriaTotal, out[i].CriteriaDone = r.CriteriaTotal, r.CriteriaDone
		out[i].PointsTotal, out[i].PointsDone = r.PointsTotal, r.PointsDone
		out[i].TicketsTotal, out[i].TicketsOpen = r.TicketsTotal, r.TicketsOpen
	}
	return map[string]any{"epics": out}, nil
}

func createChatEpic(ctx context.Context, d Deps, c agents.Caller, in NewEpicIn) (any, error) {
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, apperr.Conflict("this tool requires a chat")
	}
	name := strings.TrimSpace(in.Name)
	if name == "" || len([]rune(name)) > 200 {
		return nil, apperr.Invalid("name", "must be 1–200 characters")
	}
	p, err := s.targetProject(ctx, d, c.Agent.WorkspaceID, in.Project)
	if err != nil {
		return nil, err
	}
	e, err := d.Tracker.CreateEpic(ctx, store.CreateEpicParams{WorkspaceID: c.Agent.WorkspaceID, ProjectID: p.ID, Name: name, Objective: in.Objective, Health: "on_track", RequiresMockup: in.RequiresMockup}, in.Criteria)
	if err != nil {
		return nil, err
	}
	return map[string]any{"epic_id": e.ID, "name": e.Name, "project": p.Key, "criteria": len(in.Criteria)}, nil
}

type GenerateImageIn struct {
	Prompt     string   `json:"prompt" jsonschema:"A detailed description of the image to create (1–4000 characters)"`
	References []string `json:"references,omitempty" jsonschema:"Likenesses to keep: persona when the image shows you, person when it shows the person. Each uses the reference image set in the person's Library; omit when the image shows neither."`
}

// generateImage queues an image for the runner to make with the image engine
// (Codex or Antigravity) after this reply (see runs.Service.QueueChatImage).
func generateImage(ctx context.Context, d Deps, c agents.Caller, in GenerateImageIn) (any, error) {
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, apperr.Conflict("generate_image only works in a chat with a person")
	}
	job, err := d.Runs.QueueChatImage(ctx, c.Agent.WorkspaceID, *c.RunID, in.Prompt, in.References)
	if err != nil {
		return nil, err
	}
	return map[string]any{"queued": true, "tell_the_person": "Queued. " + runs.ImageEngineLabel(job.Harness) + " tries to make the image right after your reply; it may still fail (for example if moderation refuses it). " +
		"Tell the person you're trying to make it; don't describe it as finished or promise it will appear. " +
		"You'll get a follow-up turn with the image to look at, or the reason it failed, to react to."}, nil
}

type ProposePersonaIn struct {
	Name         string `json:"name" jsonschema:"The new persona's name, 1–60 characters, unique among the person's personas; others mention it as @Name"`
	Tone         string `json:"tone,omitempty" jsonschema:"One of neutral, friendly, concise, formal, playful (default neutral)"`
	Color        string `json:"color,omitempty" jsonschema:"Its colour in the chat as #rrggbb (default #64748b)"`
	Instructions string `json:"instructions,omitempty" jsonschema:"Its style and focus, at most 2000 characters, written to it in the second person"`
	Reason       string `json:"reason,omitempty" jsonschema:"One sentence for the person on why it helps, at most 500 characters"`
	AvatarPrompt string `json:"avatar_prompt,omitempty" jsonschema:"A detailed prompt for its profile picture, a portrait of it, at most 4000 characters. Needs your image permission. Once the person approves, the image becomes its avatar and its reference likeness"`
	CharacterSVG string `json:"character_svg,omitempty" jsonschema:"Optional animated 64x64 SVG character instead of avatar_prompt (mutually exclusive with avatar_prompt). Read the vesper-persona-character skill first"`
}

// proposePersona asks the person to approve a new persona (see
// runs.Service.ProposePersona); only a persona allowed to create personas may.
func proposePersona(ctx context.Context, d Deps, c agents.Caller, in ProposePersonaIn) (any, error) {
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, apperr.Conflict("propose_persona only works in a chat with a person")
	}
	p, err := d.Runs.ProposePersona(ctx, c.Agent.WorkspaceID, *c.RunID, runs.PersonaProposalInput{Name: in.Name, Tone: in.Tone, Color: in.Color, Instructions: in.Instructions, Reason: in.Reason, AvatarPrompt: in.AvatarPrompt, CharacterSVG: in.CharacterSVG})
	if err != nil {
		return nil, err
	}
	tell := "Proposed. The person sees Approve and Decline in the chat; " + p.Name + " is only created if they approve. Don't describe it as created yet."
	if p.AvatarJobID != nil {
		tell += " Its picture is made right after your reply and shows on the proposal; it may still fail. Don't describe the picture: you'll see it in a follow-up turn."
	} else if p.CharacterSvg != nil {
		tell += " Its animated character preview shows on the proposal card in chat."
	}
	return map[string]any{"proposal_id": p.ID, "name": p.Name, "state": p.State, "tell_the_person": tell}, nil
}

type ProposePersonaCharacterIn struct {
	Persona string `json:"persona,omitempty" jsonschema:"Name of the persona to update (defaults to you if you are a persona, or the chat's host)"`
	SVG     string `json:"svg" jsonschema:"Complete 64x64 SVG document (<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\">...</svg>) using whitelisted elements and data-motion-* / data-show attributes, at most 32 KB"`
	Summary string `json:"summary,omitempty" jsonschema:"Short summary of the character design or what changed in this revision, at most 500 characters"`
}

func proposePersonaCharacter(ctx context.Context, d Deps, c agents.Caller, in ProposePersonaCharacterIn) (any, error) {
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, apperr.Conflict("propose_persona_character only works in a chat with a person")
	}
	prop, target, err := d.Runs.ProposePersonaCharacter(ctx, c.Agent.WorkspaceID, *c.RunID, runs.PersonaCharacterProposalInput{
		PersonaName: in.Persona, SVG: in.SVG, Summary: in.Summary,
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"proposal_id":     prop.ID,
		"target_persona":  target.Name,
		"state":           prop.State,
		"tell_the_person": fmt.Sprintf("Proposed an animated character preview for %s. The person can test its Idle/Working/Action states and sizes on the card and click Use for %s or ask for changes. Nothing is applied until they approve.", target.Name, target.Name),
	}, nil
}

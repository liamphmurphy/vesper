package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"slices"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Chat endpoints (wiki: Architecture/ADR - Project chat sessions). Every
// lookup is scoped to the workspace and the creator: someone else's chat is a 404.

const chatPageSize = 50

// ownChat loads a chat the caller created, or ErrNotFound.
func (s *Server) ownChat(ctx context.Context, id uuid.UUID) (store.ChatSession, error) {
	u, _, ws := me(ctx)
	c, err := s.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && c.CreatedBy != u.ID) {
		return c, apperr.ErrNotFound
	}
	return c, err
}

// toChats renders chats with batched lookups (projects, agents, counts, errors).
// chatWorkspacePaths maps each chat's current run to the host folder holding
// its checkout, for the runs that have one.
func (s *Server) chatWorkspacePaths(ctx context.Context, chats []store.ChatSession) (map[uuid.UUID]string, error) {
	var runIDs []uuid.UUID
	for _, c := range chats {
		if c.CurrentRunID != nil {
			runIDs = append(runIDs, *c.CurrentRunID)
		}
	}
	out := map[uuid.UUID]string{}
	if len(runIDs) == 0 {
		return out, nil
	}
	rows, err := s.Q.RunWorkspaceHostPaths(ctx, runIDs)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out[r.ID] = r.Path
	}
	return out, nil
}

func (s *Server) toChats(ctx context.Context, chats []store.ChatSession) ([]api.ChatSession, error) {
	out := make([]api.ChatSession, 0, len(chats))
	if len(chats) == 0 {
		return out, nil
	}
	u, _, ws := me(ctx)
	projects, err := s.Q.ListProjects(ctx, ws)
	if err != nil {
		return nil, err
	}
	agentRows, err := s.Q.ListAllAgents(ctx, ws)
	if err != nil {
		return nil, err
	}
	ids := make([]uuid.UUID, len(chats))
	var failed, personaIDs []uuid.UUID
	addPersona := func(id *uuid.UUID) {
		if id != nil && !slices.Contains(personaIDs, *id) {
			personaIDs = append(personaIDs, *id)
		}
	}
	for i, c := range chats {
		ids[i] = c.ID
		if c.State == "failed" {
			failed = append(failed, c.ID)
		}
		addPersona(c.PersonaID)
		addPersona(c.SpeakerPersonaID)
	}
	joined, err := s.Q.ChatParticipants(ctx, ids)
	if err != nil {
		return nil, err
	}
	guests := map[uuid.UUID][]uuid.UUID{}
	for _, j := range joined {
		guests[j.ChatID] = append(guests[j.ChatID], j.PersonaID)
		addPersona(&j.PersonaID)
	}
	personaRows := map[uuid.UUID]store.Persona{}
	if len(personaIDs) > 0 {
		// Only the caller's own personas; chats are listed for their creator.
		rows, err := s.Q.PersonasByIDs(ctx, store.PersonasByIDsParams{Ids: personaIDs, WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		for _, p := range rows {
			personaRows[p.ID] = p
		}
	}
	counts := map[uuid.UUID]store.ChatMessageCountsRow{}
	rows, err := s.Q.ChatMessageCounts(ctx, ids)
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		counts[r.SessionID] = r
	}
	spaces, err := s.chatSpaceRefs(ctx, chats)
	if err != nil {
		return nil, err
	}
	paths, err := s.chatWorkspacePaths(ctx, chats)
	if err != nil {
		return nil, err
	}
	reasons := map[uuid.UUID]string{}
	if len(failed) > 0 {
		errs, err := s.Q.ChatLastErrors(ctx, failed)
		if err != nil {
			return nil, err
		}
		for _, e := range errs {
			reasons[e.SessionID] = e.BodyMd
		}
	}
	repositoryRows, err := s.Q.ChatRepositoriesForChats(ctx, ids)
	if err != nil {
		return nil, err
	}
	repositoriesByChat := map[uuid.UUID][]api.ChatRepository{}
	for _, r := range repositoryRows {
		repositoriesByChat[r.ChatID] = append(repositoriesByChat[r.ChatID], api.ChatRepository{RepoUrl: r.RepoUrl, Directory: r.Directory, WorkBranches: r.WorkBranches})
	}
	for _, c := range chats {
		item := api.ChatSession{
			Id: c.ID, Title: c.Title, Harness: api.Harness(c.Harness), Model: c.Model, State: api.ChatState(c.State),
			CurrentRunId: c.CurrentRunID, Archived: c.Archived, Revision: int(c.Revision), MessageCount: int(counts[c.ID].N), Unread: int(counts[c.ID].Unread),
			CreatedAt: c.CreatedAt, UpdatedAt: c.UpdatedAt, LastMessageAt: c.LastMessageAt, RepoUrl: c.RepoUrl,
		}
		repos := repositoriesByChat[c.ID]
		if repos == nil {
			repos = []api.ChatRepository{}
		}
		item.Repositories = &repos
		item.PendingRepoUrl = c.PendingRepoUrl
		if c.Temporary {
			item.Temporary = &c.Temporary
		}
		item.ParentChatId = c.ParentChatID
		item.AnchorMessageId = c.AnchorMessageID
		if c.SecondOpinion {
			item.SecondOpinion = &c.SecondOpinion
		}
		if c.RepoUrl != nil {
			item.WorkBranches = &c.WorkBranches
			// Only while it is still one of the creator's addresses (chats are
			// listed for their creator); otherwise the primary is used again.
			if c.CommitEmail != nil {
				if e, ok := auth.OwnEmail(u, *c.CommitEmail); ok {
					item.CommitEmail = &e
				}
			}
		}
		if c.Effort != "" {
			e := api.ChatEffort(c.Effort)
			item.Effort = &e
		}
		if c.AutoModel {
			item.AutoModel = &c.AutoModel
		}
		if c.ProjectID != nil {
			if i := slices.IndexFunc(projects, func(p store.Project) bool { return p.ID == *c.ProjectID }); i >= 0 {
				item.Project = &projects[i].Key
			}
		}
		if i := slices.IndexFunc(agentRows, func(a store.Agent) bool { return a.ID == c.AgentID }); i >= 0 {
			item.Agent = *toAgentRef(agentRows[i])
		}
		if c.PersonaID != nil {
			if p, ok := personaRows[*c.PersonaID]; ok {
				item.Persona = toPersonaSummary(p)
			}
		}
		// The host first, then the personas mentioned in; deleted ones drop out.
		parts := []api.PersonaSummary{}
		if item.Persona != nil {
			parts = append(parts, *item.Persona)
		}
		for _, id := range guests[c.ID] {
			if p, ok := personaRows[id]; ok && (c.PersonaID == nil || *c.PersonaID != id) {
				parts = append(parts, *toPersonaSummary(p))
			}
		}
		item.Participants = &parts
		if c.SpeakerPersonaID != nil {
			if p, ok := personaRows[*c.SpeakerPersonaID]; ok {
				item.Speaker = toPersonaSummary(p)
			}
		} else {
			item.Speaker = item.Persona
		}
		if c.CurrentRunID != nil {
			if p, ok := paths[*c.CurrentRunID]; ok {
				item.WorkspacePath = &p
			}
		}
		if r, ok := reasons[c.ID]; ok && c.State == "failed" {
			item.Error = &r
		}
		if c.SpaceID != nil {
			if sp, ok := spaces[*c.SpaceID]; ok {
				item.Space = &sp
			}
		}
		out = append(out, item)
	}
	return out, nil
}

func (s *Server) toChat(ctx context.Context, c store.ChatSession) (api.ChatSession, error) {
	out, err := s.toChats(ctx, []store.ChatSession{c})
	if err != nil {
		return api.ChatSession{}, err
	}
	return out[0], nil
}

// toMessages renders messages; turn numbers and efforts come from the few runs involved.
func (s *Server) toMessages(ctx context.Context, msgs []store.ChatMessage) ([]api.ChatMessage, error) {
	u, _, _ := me(ctx)
	turnsByID := map[uuid.UUID]store.RunTurn{}
	seenRuns := map[uuid.UUID]bool{}
	for _, m := range msgs {
		if m.RunID == nil || m.RunTurnID == nil || seenRuns[*m.RunID] {
			continue
		}
		seenRuns[*m.RunID] = true
		turns, err := s.Q.ListTurns(ctx, *m.RunID)
		if err != nil {
			return nil, err
		}
		for _, t := range turns {
			turnsByID[t.ID] = t
		}
	}
	files, err := s.messageAttachments(ctx, msgs)
	if err != nil {
		return nil, err
	}
	var personaIDs []uuid.UUID
	for _, m := range msgs {
		if m.PersonaID != nil && !slices.Contains(personaIDs, *m.PersonaID) {
			personaIDs = append(personaIDs, *m.PersonaID)
		}
	}
	authors := map[uuid.UUID]store.Persona{}
	if len(personaIDs) > 0 {
		_, _, ws := me(ctx)
		rows, err := s.Q.PersonasByIDs(ctx, store.PersonasByIDsParams{Ids: personaIDs, WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		for _, p := range rows {
			authors[p.ID] = p
		}
	}
	out := make([]api.ChatMessage, 0, len(msgs))
	for _, m := range msgs {
		item := api.ChatMessage{Id: m.ID, Seq: int(m.Seq), Role: api.ChatMessageRole(m.Role), BodyMd: m.BodyMd, RunId: m.RunID, Model: m.Model, CreatedAt: m.CreatedAt}
		if m.Harness != nil {
			h := api.Harness(*m.Harness)
			item.Harness = &h
		}
		if m.RunTurnID != nil && (m.Role == "assistant" || m.Role == "system") {
			if t, ok := turnsByID[*m.RunTurnID]; ok {
				// A system message with a turn is how that turn ended (it failed), so the
				// chat can keep the turn's steps beside it.
				n := int(t.Seq)
				item.TurnSeq = &n
				if m.Role == "assistant" {
					setTurnEffort(&item, t)
				}
			}
		}
		refs, _ := recode[[]api.ChatContextRef](jsonOrEmpty(m.ContextRefs))
		cites, _ := recode[[]api.ChatCitation](jsonOrEmpty(m.Citations))
		item.ContextRefs, item.Citations = &refs, &cites
		if m.Role == "assistant" && len(m.CodeChanges) > 2 {
			if changes, err := recode[[]api.ChatCodeChange](m.CodeChanges); err == nil && len(changes) > 0 {
				item.CodeChanges = &changes
			}
		}
		if m.Role == "user" {
			item.Author = toUserRef(u)
		}
		// Which persona wrote a reply; absent is the chat's host.
		if p, ok := authors[deref(m.PersonaID)]; ok && m.Role == "assistant" {
			item.Persona = toPersonaSummary(p)
		}
		// A user message always lists its attachments; an assistant message
		// only when it has generated files.
		if attached := files[m.ID]; m.Role == "user" || len(attached) > 0 {
			if attached == nil {
				attached = []api.ChatAttachment{}
			}
			item.Attachments = &attached
		}
		if len(m.Usage) > 0 {
			var usage harness.Usage
			if json.Unmarshal(m.Usage, &usage) == nil && m.Role == "assistant" {
				in, outTok, cost := usage.InputTokens, usage.OutputTokens, float32(usage.CostUSD)
				item.InputTokens, item.OutputTokens, item.CostUsd = &in, &outTok, &cost
				var saved map[string]json.RawMessage
				_ = json.Unmarshal(m.Usage, &saved)
				reported := usage.CacheReportedInputTokens
				legacySupported := m.Harness != nil && (*m.Harness == "codex" || *m.Harness == "claude-code")
				if _, modern := saved["cache_reported_input_tokens"]; !modern && legacySupported && saved["cached_tokens"] != nil && (usage.SessionInputTokens > 0 || usage.CostSource == "harness") {
					reported = usage.InputTokens
				}
				cached, uncached, unknown := cacheBreakdown(in, usage.CachedTokens, reported)
				item.CachedInputTokens, item.UncachedInputTokens, item.UnreportedInputTokens = &cached, &uncached, &unknown
			}
		}
		out = append(out, item)
	}
	return out, nil
}

// setTurnEffort shows the effort the reply's turn ran at and, when Vesper
// picked it, the level it aimed for and the rules that raised it.
func setTurnEffort(item *api.ChatMessage, t store.RunTurn) {
	if t.Effort != nil {
		e := api.ChatEffort(*t.Effort)
		item.Effort = &e
	}
	if t.EffortLevel == nil {
		return
	}
	level := api.ChatMessageEffortLevel(*t.EffortLevel)
	item.EffortLevel = &level
	if len(t.EffortReasons) > 0 {
		reasons := make([]api.ChatMessageEffortReasons, len(t.EffortReasons))
		for i, r := range t.EffortReasons {
			reasons[i] = api.ChatMessageEffortReasons(r)
		}
		item.EffortReasons = &reasons
	}
}

// jsonOrEmpty keeps recode working on a NULL-ish column.
func jsonOrEmpty(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 {
		return json.RawMessage("[]")
	}
	return raw
}

func (s *Server) ListChatModels(ctx context.Context, _ api.ListChatModelsRequestObject) (api.ListChatModelsResponseObject, error) {
	_, _, ws := me(ctx)
	list, err := s.Runs.ChatCatalog().ListWaiting(ctx, s.Q, ws)
	if err != nil {
		return nil, err
	}
	out := make(api.ListChatModels200JSONResponse, 0, len(list))
	for _, h := range list {
		item := api.ChatHarnessModels{Harness: api.Harness(h.Harness), Label: h.Label, Available: h.Available, Models: make([]api.ChatModel, len(h.Models))}
		if h.Checking {
			item.Checking = &h.Checking
		}
		if h.UnavailableReason != "" {
			reason := h.UnavailableReason
			item.UnavailableReason = &reason
		}
		for i, m := range h.Models {
			item.Models[i] = api.ChatModel{Id: m.ID, Label: m.Label, Default: m.Default, Efforts: make([]api.ChatEffort, len(m.Efforts))}
			for j, e := range m.Efforts {
				item.Models[i].Efforts[j] = api.ChatEffort(e)
			}
			if m.DefaultEffort != "" {
				e := api.ChatEffort(m.DefaultEffort)
				item.Models[i].DefaultEffort = &e
			}
		}
		out = append(out, item)
	}
	return out, nil
}

func (s *Server) ListChats(ctx context.Context, req api.ListChatsRequestObject) (api.ListChatsResponseObject, error) {
	u, _, ws := me(ctx)
	offset := deref(req.Params.Offset)
	if offset < 0 || offset > 100000 {
		return nil, apperr.Invalid("offset", "must be between 0 and 100000")
	}
	filter, personaID, err := s.chatPersonaFilter(ctx, req.Params.PersonaId)
	if err != nil {
		return nil, err
	}
	spaceFilter, spaceID, err := s.chatSpaceFilter(ctx, req.Params.Space)
	if err != nil {
		return nil, err
	}
	chats, err := s.Q.ListChatsForUser(ctx, store.ListChatsForUserParams{
		WorkspaceID: ws, CreatedBy: u.ID, Archived: deref(req.Params.Archived), ProjectKey: req.Params.Project,
		PersonaFilter: filter, PersonaID: personaID, SpaceFilter: spaceFilter, SpaceID: spaceID, RowOffset: int32(offset), RowLimit: chatPageSize + 1,
	})
	if err != nil {
		return nil, err
	}
	more := len(chats) > chatPageSize
	if more {
		chats = chats[:chatPageSize]
	}
	items, err := s.toChats(ctx, chats)
	if err != nil {
		return nil, err
	}
	if spaceID != nil {
		if err := s.chatPreviews(ctx, items); err != nil {
			return nil, err
		}
	}
	return api.ListChats200JSONResponse{Chats: items, HasMore: more}, nil
}

// chatPersonaFilter resolves GET /chats?persona_id= to ListChatsForUser's
// filter: `all`, `none`, or one of the caller's personas. Omitted means the
// caller's default persona, or `none` when they have no default.
func (s *Server) chatPersonaFilter(ctx context.Context, raw *string) (string, *uuid.UUID, error) {
	o := personaOwner(ctx)
	if raw == nil {
		p, err := s.personas().Default(ctx, o)
		if err != nil || p == nil {
			return "none", nil, err
		}
		return "id", &p.ID, nil
	}
	switch *raw {
	case "all", "none":
		return *raw, nil, nil
	}
	id, err := uuid.Parse(*raw)
	if err != nil {
		return "", nil, apperr.Invalid("persona_id", "must be a persona id, all or none")
	}
	if _, err := s.personas().Get(ctx, o, id); errors.Is(err, apperr.ErrNotFound) {
		return "", nil, apperr.Invalid("persona_id", "unknown persona")
	} else if err != nil {
		return "", nil, err
	}
	return "id", &id, nil
}

// toMessageInput converts the contract's message body.
func toMessageInput(b api.NewChatMessage) (runs.ChatMessageInput, error) {
	in := runs.ChatMessageInput{Body: b.Body, Model: deref(b.Model), Research: b.Research != nil && *b.Research}
	if b.Harness != nil {
		in.Harness = string(*b.Harness)
	}
	if b.Effort != nil {
		in.Effort = string(*b.Effort)
	}
	if b.ContextRefs != nil {
		refs, err := recode[[]runs.ChatContextRef](*b.ContextRefs)
		if err != nil {
			return in, err
		}
		in.ContextRefs = refs
	}
	if b.AttachmentIds != nil {
		in.AttachmentIDs = *b.AttachmentIds
	}
	return in, nil
}

func (s *Server) CreateChat(ctx context.Context, req api.CreateChatRequestObject) (api.CreateChatResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	in := runs.ChatInput{Project: deref(b.Project), Title: deref(b.Title), Model: deref(b.Model), PersonaID: b.PersonaId, RepoURL: deref(b.RepoUrl), Hidden: deref(b.Hidden), Temporary: deref(b.Temporary), SpaceID: b.SpaceId, CommitEmail: deref(b.CommitEmail)}
	if b.Harness != nil {
		in.Harness = string(*b.Harness)
	}
	if b.Effort != nil {
		in.Effort = string(*b.Effort)
	}
	if b.Message != nil {
		m, err := toMessageInput(*b.Message)
		if err != nil {
			return nil, err
		}
		in.Message = &m
	}
	chat, err := s.Runs.StartChat(ctx, ws, u.ID, in)
	if err != nil {
		return nil, err
	}
	out, err := s.toChat(ctx, chat)
	return api.CreateChat201JSONResponse(out), err
}

func (s *Server) GetChat(ctx context.Context, req api.GetChatRequestObject) (api.GetChatResponseObject, error) {
	c, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out, err := s.toChat(ctx, c)
	return api.GetChat200JSONResponse(out), err
}

func (s *Server) UpdateChat(ctx context.Context, req api.UpdateChatRequestObject) (api.UpdateChatResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	if req.Body.Revision < 1 || req.Body.Revision > 2147483647 {
		return nil, apperr.Invalid("revision", "invalid revision")
	}
	c, err := s.Runs.UpdateChat(ctx, ws, u.ID, req.Id, runs.ChatPatchInput{Revision: int32(req.Body.Revision), Title: req.Body.Title, Archived: req.Body.Archived, Project: req.Body.Project, Space: req.Body.SpaceId})
	if err != nil {
		return nil, err
	}
	out, err := s.toChat(ctx, c)
	return api.UpdateChat200JSONResponse(out), err
}

func (s *Server) SetChatCommitEmail(ctx context.Context, req api.SetChatCommitEmailRequestObject) (api.SetChatCommitEmailResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	c, err := s.Runs.SetChatCommitEmail(ctx, ws, u.ID, req.Id, req.Body.Email)
	if err != nil {
		return nil, err
	}
	out, err := s.toChat(ctx, c)
	return api.SetChatCommitEmail200JSONResponse(out), err
}

// ListChatSuggestions returns the person's conversation starters: none until
// the runner has written a batch, or once the last one is too old.
func (s *Server) ListChatSuggestions(ctx context.Context, _ api.ListChatSuggestionsRequestObject) (api.ListChatSuggestionsResponseObject, error) {
	u, _, ws := me(ctx)
	out := api.ListChatSuggestions200JSONResponse{Suggestions: []api.ChatSuggestion{}}
	items, err := s.Q.GetChatSuggestions(ctx, store.GetChatSuggestionsParams{WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return out, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(items, &out.Suggestions); err != nil {
		return nil, err
	}
	return out, nil
}

func (s *Server) DeleteChat(ctx context.Context, req api.DeleteChatRequestObject) (api.DeleteChatResponseObject, error) {
	u, _, ws := me(ctx)
	if err := s.Runs.DeleteChat(ctx, ws, u.ID, req.Id); err != nil {
		return nil, err
	}
	return api.DeleteChat204Response{}, nil
}

func (s *Server) ListChatMessages(ctx context.Context, req api.ListChatMessagesRequestObject) (api.ListChatMessagesResponseObject, error) {
	c, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	limit := 100
	if req.Params.Limit != nil {
		limit = *req.Params.Limit
	}
	if limit < 1 || limit > 1000 {
		return nil, apperr.Invalid("limit", "must be between 1 and 1000")
	}
	if req.Params.After != nil && *req.Params.After < 0 {
		return nil, apperr.Invalid("after", "must be 0 or more")
	}
	if req.Params.Before != nil && *req.Params.Before < 1 {
		return nil, apperr.Invalid("before", "must be 1 or more")
	}
	p := store.PageChatMessagesParams{SessionID: c.ID, RowLimit: int32(limit)}
	if req.Params.After != nil {
		v := int64(*req.Params.After)
		p.AfterSeq = &v
	}
	if req.Params.Before != nil {
		v := int64(*req.Params.Before)
		p.BeforeSeq = &v
	}
	// Without `after`, return the newest page (before the cursor); with it,
	// everything newer, oldest first.
	p.NewestFirst = p.AfterSeq == nil
	rows, err := s.Q.PageChatMessages(ctx, p)
	if err != nil {
		return nil, err
	}
	if p.NewestFirst {
		slices.Reverse(rows)
	}
	msgs, err := s.toMessages(ctx, rows)
	if err != nil {
		return nil, err
	}
	return api.ListChatMessages200JSONResponse{Messages: msgs, HasMore: len(rows) > 0 && rows[0].Seq > 1}, nil
}

func (s *Server) PostChatMessage(ctx context.Context, req api.PostChatMessageRequestObject) (api.PostChatMessageResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	in, err := toMessageInput(*req.Body)
	if err != nil {
		return nil, err
	}
	msg, err := s.Runs.PostChatMessage(ctx, ws, u.ID, req.Id, in)
	if err != nil {
		return nil, err
	}
	c, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	chat, err := s.toChat(ctx, c)
	if err != nil {
		return nil, err
	}
	msgs, err := s.toMessages(ctx, []store.ChatMessage{msg})
	if err != nil {
		return nil, err
	}
	return api.PostChatMessage202JSONResponse{Chat: chat, Message: msgs[0]}, nil
}

func (s *Server) CancelChatTurn(ctx context.Context, req api.CancelChatTurnRequestObject) (api.CancelChatTurnResponseObject, error) {
	u, _, ws := me(ctx)
	c, err := s.Runs.CancelChat(ctx, ws, u.ID, req.Id)
	if err != nil {
		return nil, err
	}
	out, err := s.toChat(ctx, c)
	return api.CancelChatTurn200JSONResponse(out), err
}

func (s *Server) toProposals(ctx context.Context, rows []store.PersonaProposal) ([]api.PersonaProposal, error) {
	u, _, ws := me(ctx)
	var ids []uuid.UUID
	for _, r := range rows {
		for _, id := range []*uuid.UUID{r.ProposedBy, r.PersonaID} {
			if id != nil && !slices.Contains(ids, *id) {
				ids = append(ids, *id)
			}
		}
	}
	pids := make([]uuid.UUID, len(rows))
	for i, r := range rows {
		pids[i] = r.ID
	}
	avatars, err := runs.PersonaProposalAvatars(ctx, s.Q, pids)
	if err != nil {
		return nil, err
	}
	byID := map[uuid.UUID]store.Persona{}
	if len(ids) > 0 {
		ps, err := s.Q.PersonasByIDs(ctx, store.PersonasByIDsParams{Ids: ids, WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		for _, p := range ps {
			byID[p.ID] = p
		}
	}
	out := make([]api.PersonaProposal, 0, len(rows))
	for _, r := range rows {
		item := api.PersonaProposal{
			Id: r.ID, ChatId: r.ChatID, Name: r.Name, Tone: api.PersonaTone(r.Tone), Color: r.Color, CustomInstructions: r.CustomInstructions,
			Reason: r.Reason, State: api.PersonaProposalState(r.State), CreatedAt: r.CreatedAt, DecidedAt: r.DecidedAt,
		}
		if p, ok := byID[deref(r.ProposedBy)]; ok {
			item.ProposedBy = toPersonaSummary(p)
		}
		if p, ok := byID[deref(r.PersonaID)]; ok {
			item.Persona = toPersonaSummary(p)
		}
		if a, ok := avatars[r.ID]; ok {
			state := api.PersonaProposalAvatarState(a.AvatarState)
			item.AvatarState = &state
			item.AvatarAttachmentId = a.AttachmentID
		}
		out = append(out, item)
	}
	return out, nil
}

func (s *Server) ListPersonaProposals(ctx context.Context, req api.ListPersonaProposalsRequestObject) (api.ListPersonaProposalsResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Runs.ListPersonaProposals(ctx, ws, u.ID, req.Id)
	if err != nil {
		return nil, err
	}
	out, err := s.toProposals(ctx, rows)
	return api.ListPersonaProposals200JSONResponse{Proposals: out}, err
}

func (s *Server) DecidePersonaProposal(ctx context.Context, req api.DecidePersonaProposalRequestObject) (api.DecidePersonaProposalResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil || !req.Body.Decision.Valid() {
		return nil, apperr.Invalid("decision", "must be approve or decline")
	}
	d, err := s.Runs.DecidePersonaProposal(ctx, ws, u.ID, req.Id, req.ProposalId, req.Body.Decision == api.Approve)
	if err != nil {
		return nil, err
	}
	if d.Avatar != nil && d.Proposal.PersonaID != nil {
		// The persona exists now whatever happens here: a picture that can't
		// be stored leaves it without an avatar, which the person can add in
		// Manage personas.
		if err := s.avatarFromAttachment(ctx, personaOwner(ctx), *d.Proposal.PersonaID, *d.Avatar); err != nil {
			s.Log.Warn("proposed persona avatar", "proposal", d.Proposal.ID, "err", err)
		}
	}
	out, err := s.toProposals(ctx, []store.PersonaProposal{d.Proposal})
	if err != nil {
		return nil, err
	}
	return api.DecidePersonaProposal200JSONResponse(out[0]), nil
}

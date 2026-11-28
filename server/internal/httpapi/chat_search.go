package httpapi

import (
	"context"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const chatSearchLimit = 30

// SearchChats finds messages in the caller's own chats, private like the chats are.
func (s *Server) SearchChats(ctx context.Context, req api.SearchChatsRequestObject) (api.SearchChatsResponseObject, error) {
	u, _, ws := me(ctx)
	out := api.ChatSearchResults{Hits: []api.ChatSearchHit{}}
	q := strings.TrimSpace(req.Params.Q)
	if len([]rune(q)) < 2 {
		return api.SearchChats200JSONResponse(out), nil
	}
	rows, err := s.Q.SearchChatMessages(ctx, store.SearchChatMessagesParams{Query: q, WorkspaceID: ws, UserID: u.ID, RowLimit: chatSearchLimit})
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		out.Hits = append(out.Hits, api.ChatSearchHit{MessageId: r.ID, ChatId: r.SessionID, ChatTitle: r.ChatTitle, ProjectKey: r.ProjectKey,
			Role: api.ChatSearchHitRole(r.Role), Archived: r.Archived, PersonaName: r.PersonaName, Snippet: r.Snippet, CreatedAt: r.CreatedAt})
	}
	return api.SearchChats200JSONResponse(out), nil
}

// EditLastChatMessage redoes the turn of the caller's newest message.
func (s *Server) EditLastChatMessage(ctx context.Context, req api.EditLastChatMessageRequestObject) (api.EditLastChatMessageResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	var opts runs.ChatEditOptions
	if req.Body.Harness != nil {
		opts.Harness = string(*req.Body.Harness)
	}
	if req.Body.Model != nil {
		opts.Model = *req.Body.Model
	}
	if req.Body.Effort != nil {
		opts.Effort = string(*req.Body.Effort)
	}
	msg, err := s.Runs.EditLastChatMessage(ctx, ws, u.ID, req.Id, req.Body.Body, opts)
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
	return api.EditLastChatMessage202JSONResponse{Chat: chat, Message: msgs[0]}, nil
}

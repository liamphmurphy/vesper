package httpapi

import (
	"context"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

func (s *Server) AddChatParticipant(ctx context.Context, req api.AddChatParticipantRequestObject) (api.AddChatParticipantResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	c, err := s.Runs.AddChatParticipant(ctx, ws, u.ID, req.Id, req.Body.PersonaId)
	if err != nil {
		return nil, err
	}
	chat, err := s.toChat(ctx, c)
	if err != nil {
		return nil, err
	}
	return api.AddChatParticipant200JSONResponse(chat), nil
}

func (s *Server) RemoveChatParticipant(ctx context.Context, req api.RemoveChatParticipantRequestObject) (api.RemoveChatParticipantResponseObject, error) {
	u, _, ws := me(ctx)
	c, err := s.Runs.RemoveChatParticipant(ctx, ws, u.ID, req.Id, req.PersonaId)
	if err != nil {
		return nil, err
	}
	chat, err := s.toChat(ctx, c)
	if err != nil {
		return nil, err
	}
	return api.RemoveChatParticipant200JSONResponse(chat), nil
}

func (s *Server) SetChatSpeaker(ctx context.Context, req api.SetChatSpeakerRequestObject) (api.SetChatSpeakerResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	var target *uuid.UUID
	if req.Body.PersonaId.IsSpecified() && !req.Body.PersonaId.IsNull() {
		id := req.Body.PersonaId.MustGet()
		target = &id
	}
	c, err := s.Runs.SetChatDefaultSpeaker(ctx, ws, u.ID, req.Id, target)
	if err != nil {
		return nil, err
	}
	chat, err := s.toChat(ctx, c)
	if err != nil {
		return nil, err
	}
	return api.SetChatSpeaker200JSONResponse(chat), nil
}

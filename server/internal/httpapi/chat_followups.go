package httpapi

import (
	"context"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func toFollowup(f store.ChatFollowup) api.ChatFollowup {
	return api.ChatFollowup{Id: f.ID, Body: f.Body, CreatedAt: f.CreatedAt}
}

func (s *Server) ListChatFollowups(ctx context.Context, req api.ListChatFollowupsRequestObject) (api.ListChatFollowupsResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Runs.ListChatFollowups(ctx, ws, u.ID, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.ChatFollowup, len(rows))
	for i, f := range rows {
		out[i] = toFollowup(f)
	}
	return api.ListChatFollowups200JSONResponse{Followups: out}, nil
}

func (s *Server) QueueChatFollowup(ctx context.Context, req api.QueueChatFollowupRequestObject) (api.QueueChatFollowupResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	f, err := s.Runs.QueueChatFollowup(ctx, ws, u.ID, req.Id, req.Body.Body)
	if err != nil {
		return nil, err
	}
	return api.QueueChatFollowup201JSONResponse(toFollowup(f)), nil
}

func (s *Server) DeleteChatFollowup(ctx context.Context, req api.DeleteChatFollowupRequestObject) (api.DeleteChatFollowupResponseObject, error) {
	u, _, ws := me(ctx)
	if err := s.Runs.DeleteChatFollowup(ctx, ws, u.ID, req.Id, req.FollowupId); err != nil {
		return nil, err
	}
	return api.DeleteChatFollowup204Response{}, nil
}

func (s *Server) ListChatAsides(ctx context.Context, req api.ListChatAsidesRequestObject) (api.ListChatAsidesResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Runs.ListChatAsides(ctx, ws, u.ID, req.Id)
	if err != nil {
		return nil, err
	}
	out, err := s.toChats(ctx, rows)
	if err != nil {
		return nil, err
	}
	if out == nil {
		out = []api.ChatSession{}
	}
	return api.ListChatAsides200JSONResponse{Asides: out}, nil
}

func (s *Server) StartChatAside(ctx context.Context, req api.StartChatAsideRequestObject) (api.StartChatAsideResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	in := runs.AsideInput{
		Body:            req.Body.Body,
		AnchorMessageID: req.Body.AnchorMessageId,
		SecondOpinion:   req.Body.SecondOpinion != nil && *req.Body.SecondOpinion,
	}
	if req.Body.Harness != nil {
		in.Harness = string(*req.Body.Harness)
	}
	if req.Body.Model != nil {
		in.Model = *req.Body.Model
	}
	if req.Body.Effort != nil {
		in.Effort = string(*req.Body.Effort)
	}
	if req.Body.Repository != nil {
		in.Repository = *req.Body.Repository
	}
	aside, err := s.Runs.StartChatAsideWith(ctx, ws, u.ID, req.Id, in)
	if err != nil {
		return nil, err
	}
	out, err := s.toChat(ctx, aside)
	return api.StartChatAside201JSONResponse(out), err
}

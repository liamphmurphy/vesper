package httpapi

import (
	"context"
	"errors"
	"regexp"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/oapi-codegen/nullable"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

var promptTemplateSlugRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,47}$`)

var reservedPromptTemplateSlugs = map[string]struct{}{
	"model": {}, "effort": {}, "persona": {}, "workflow": {},
	"new": {}, "temp": {}, "compact": {}, "repo": {},
	"memory": {}, "stop": {}, "steer": {}, "aside": {},
	"queue": {}, "design": {}, "music": {}, "compare": {},
	"roundtable": {}, "outline": {}, "thinking": {},
}

func normalizePromptTemplateSlug(raw string) (string, error) {
	slug := strings.ToLower(strings.TrimSpace(raw))
	slug = strings.TrimPrefix(slug, "/")
	slug = strings.TrimPrefix(slug, "#")
	if !promptTemplateSlugRe.MatchString(slug) {
		return "", apperr.Invalid("slug", "must start with a letter and use only lowercase letters, numbers, and hyphens (max 48 chars)")
	}
	if _, reserved := reservedPromptTemplateSlugs[slug]; reserved {
		return "", apperr.Invalid("slug", "conflicts with a built-in slash command")
	}
	return slug, nil
}

func toPromptTemplate(row store.PromptTemplate) api.PromptTemplate {
	out := api.PromptTemplate{
		Id:          row.ID,
		Slug:        row.Slug,
		Title:       row.Title,
		Description: row.Description,
		Body:        row.Body,
		CreatedAt:   row.CreatedAt,
		UpdatedAt:   row.UpdatedAt,
	}
	if row.PersonaID != nil {
		out.PersonaId = nullable.NewNullableWithValue(*row.PersonaID)
	}
	if row.SpaceID != nil {
		out.SpaceId = nullable.NewNullableWithValue(*row.SpaceID)
	}
	return out
}

func (s *Server) validateTemplateScope(ctx context.Context, ws, user uuid.UUID, personaID, spaceID *uuid.UUID) error {
	if personaID != nil {
		if _, err := s.Q.KeySharePersona(ctx, store.KeySharePersonaParams{ID: *personaID, WorkspaceID: ws, UserID: user}); errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		} else if err != nil {
			return err
		}
	}
	if spaceID != nil {
		if _, err := s.Q.GetChatSpace(ctx, store.GetChatSpaceParams{ID: *spaceID, WorkspaceID: ws, UserID: user}); errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		} else if err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) ListPromptTemplates(ctx context.Context, req api.ListPromptTemplatesRequestObject) (api.ListPromptTemplatesResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListPromptTemplates(ctx, store.ListPromptTemplatesParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out := make([]api.PromptTemplate, 0, len(rows))
	for _, row := range rows {
		if req.Params.PersonaId != nil && row.PersonaID != nil && *row.PersonaID != *req.Params.PersonaId {
			continue
		}
		if req.Params.SpaceId != nil && row.SpaceID != nil && *row.SpaceID != *req.Params.SpaceId {
			continue
		}
		out = append(out, toPromptTemplate(row))
	}
	return api.ListPromptTemplates200JSONResponse{Templates: out}, nil
}

func (s *Server) CreatePromptTemplate(ctx context.Context, req api.CreatePromptTemplateRequestObject) (api.CreatePromptTemplateResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	slug, err := normalizePromptTemplateSlug(req.Body.Slug)
	if err != nil {
		return nil, err
	}
	title := strings.TrimSpace(req.Body.Title)
	if title == "" || len([]rune(title)) > 120 {
		return nil, apperr.Invalid("title", "must be 1 to 120 characters")
	}
	desc := ""
	if req.Body.Description != nil {
		desc = strings.TrimSpace(*req.Body.Description)
		if len([]rune(desc)) > 300 {
			return nil, apperr.Invalid("description", "must be at most 300 characters")
		}
	}
	body := strings.TrimSpace(req.Body.Body)
	if body == "" || len([]rune(body)) > 16000 {
		return nil, apperr.Invalid("body", "must be 1 to 16000 characters")
	}

	var personaID, spaceID *uuid.UUID
	if req.Body.PersonaId.IsSpecified() && !req.Body.PersonaId.IsNull() {
		id := req.Body.PersonaId.MustGet()
		personaID = &id
	}
	if req.Body.SpaceId.IsSpecified() && !req.Body.SpaceId.IsNull() {
		id := req.Body.SpaceId.MustGet()
		spaceID = &id
	}
	if err := s.validateTemplateScope(ctx, ws, u.ID, personaID, spaceID); err != nil {
		return nil, err
	}

	row, err := s.Q.CreatePromptTemplate(ctx, store.CreatePromptTemplateParams{
		WorkspaceID: ws,
		UserID:      u.ID,
		Slug:        slug,
		Title:       title,
		Description: desc,
		Body:        body,
		PersonaID:   personaID,
		SpaceID:     spaceID,
	})
	if err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "23505" {
			return nil, apperr.Conflict("a prompt template with slug /%s already exists in this scope", slug)
		}
		return nil, err
	}
	return api.CreatePromptTemplate201JSONResponse(toPromptTemplate(row)), nil
}

func (s *Server) UpdatePromptTemplate(ctx context.Context, req api.UpdatePromptTemplateRequestObject) (api.UpdatePromptTemplateResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	params := store.UpdatePromptTemplateParams{
		ID:          req.Id,
		WorkspaceID: ws,
		UserID:      u.ID,
	}
	if req.Body.Slug != nil {
		slug, err := normalizePromptTemplateSlug(*req.Body.Slug)
		if err != nil {
			return nil, err
		}
		params.Slug = &slug
	}
	if req.Body.Title != nil {
		title := strings.TrimSpace(*req.Body.Title)
		if title == "" || len([]rune(title)) > 120 {
			return nil, apperr.Invalid("title", "must be 1 to 120 characters")
		}
		params.Title = &title
	}
	if req.Body.Description != nil {
		desc := strings.TrimSpace(*req.Body.Description)
		if len([]rune(desc)) > 300 {
			return nil, apperr.Invalid("description", "must be at most 300 characters")
		}
		params.Description = &desc
	}
	if req.Body.Body != nil {
		body := strings.TrimSpace(*req.Body.Body)
		if body == "" || len([]rune(body)) > 16000 {
			return nil, apperr.Invalid("body", "must be 1 to 16000 characters")
		}
		params.Body = &body
	}
	if req.Body.PersonaId.IsSpecified() {
		if req.Body.PersonaId.IsNull() {
			params.ClearPersona = true
		} else {
			id := req.Body.PersonaId.MustGet()
			params.PersonaID = &id
		}
	}
	if req.Body.SpaceId.IsSpecified() {
		if req.Body.SpaceId.IsNull() {
			params.ClearSpace = true
		} else {
			id := req.Body.SpaceId.MustGet()
			params.SpaceID = &id
		}
	}
	if err := s.validateTemplateScope(ctx, ws, u.ID, params.PersonaID, params.SpaceID); err != nil {
		return nil, err
	}

	row, err := s.Q.UpdatePromptTemplate(ctx, params)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		var pe *pgconn.PgError
		if errors.As(err, &pe) && pe.Code == "23505" {
			return nil, apperr.Conflict("a prompt template with that slug already exists in this scope")
		}
		return nil, err
	}
	return api.UpdatePromptTemplate200JSONResponse(toPromptTemplate(row)), nil
}

func (s *Server) DeletePromptTemplate(ctx context.Context, req api.DeletePromptTemplateRequestObject) (api.DeletePromptTemplateResponseObject, error) {
	u, _, ws := me(ctx)
	_, err := s.Q.DeletePromptTemplate(ctx, store.DeletePromptTemplateParams{
		ID:          req.Id,
		WorkspaceID: ws,
		UserID:      u.ID,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return api.DeletePromptTemplate204Response{}, nil
}

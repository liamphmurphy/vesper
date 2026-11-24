package httpapi

import (
	"context"
	"errors"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/repositories"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	maxSpaceRepos          = 20
	maxSpaceKnowledgeLinks = 50
	maxSpaceTaskTitle      = 300
	maxSpaceTaskNotes      = 4000
)

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func toSpaceRepo(r store.ChatSpaceRepository) api.ChatSpaceRepository {
	return api.ChatSpaceRepository{
		Id:        r.ID,
		RepoUrl:   r.RepoUrl,
		ReadOnly:  r.ReadOnly,
		CreatedAt: r.CreatedAt,
	}
}

func toSpaceRepos(rows []store.ChatSpaceRepository) []api.ChatSpaceRepository {
	out := make([]api.ChatSpaceRepository, len(rows))
	for i, r := range rows {
		out[i] = toSpaceRepo(r)
	}
	return out
}

func (s *Server) toSpaceKnowledgeLink(ctx context.Context, ws, userID uuid.UUID, l store.ChatSpaceKnowledgeLink) (api.ChatSpaceKnowledgeLink, error) {
	pageCount := 1
	if l.Kind == "folder" {
		n, err := s.Q.CountNotesInFolderPrefix(ctx, store.CountNotesInFolderPrefixParams{
			WorkspaceID: ws,
			UserID:      &userID,
			Folder:      l.Path,
		})
		if err != nil {
			return api.ChatSpaceKnowledgeLink{}, err
		}
		pageCount = int(n)
	}
	return api.ChatSpaceKnowledgeLink{
		Id:              l.ID,
		Kind:            api.ChatSpaceKnowledgeLinkKind(l.Kind),
		Path:            l.Path,
		IsDefaultTarget: l.IsDefaultTarget,
		Pinned:          l.Pinned,
		PageCount:       pageCount,
		CreatedAt:       l.CreatedAt,
	}, nil
}

func (s *Server) toSpaceKnowledgeLinks(ctx context.Context, ws, userID uuid.UUID, rows []store.ChatSpaceKnowledgeLink) ([]api.ChatSpaceKnowledgeLink, error) {
	out := make([]api.ChatSpaceKnowledgeLink, len(rows))
	for i, l := range rows {
		item, err := s.toSpaceKnowledgeLink(ctx, ws, userID, l)
		if err != nil {
			return nil, err
		}
		out[i] = item
	}
	return out, nil
}

func toSpaceTask(t store.ChatSpaceTask, chatTitle *string) api.ChatSpaceTask {
	return api.ChatSpaceTask{
		Id:        t.ID,
		SpaceId:   t.SpaceID,
		Title:     t.Title,
		Notes:     t.Notes,
		Done:      t.Done,
		ChatId:    t.ChatID,
		ChatTitle: chatTitle,
		Position:  int(t.Position),
		CreatedAt: t.CreatedAt,
		UpdatedAt: t.UpdatedAt,
	}
}

func normalizeKnowledgeLinkPath(raw string) (string, error) {
	p := strings.Trim(strings.TrimSpace(raw), "/")
	if p == "" || utf8.RuneCountInString(p) > 500 {
		return "", apperr.Invalid("path", "must be 1–500 characters")
	}
	if strings.Contains(p, "..") || strings.ContainsAny(p, "\x00\r\n") {
		return "", apperr.Invalid("path", "invalid path")
	}
	return p, nil
}

func (s *Server) ListChatSpaceRepositories(ctx context.Context, req api.ListChatSpaceRepositoriesRequestObject) (api.ListChatSpaceRepositoriesResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListChatSpaceRepositories(ctx, sp.ID)
	if err != nil {
		return nil, err
	}
	return api.ListChatSpaceRepositories200JSONResponse{Repositories: toSpaceRepos(rows)}, nil
}

func (s *Server) AddChatSpaceRepository(ctx context.Context, req api.AddChatSpaceRepositoryRequestObject) (api.AddChatSpaceRepositoryResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	raw := strings.TrimSpace(req.Body.RepoUrl)
	if raw == "" {
		return nil, apperr.Invalid("repo_url", "required")
	}
	repoURL, err := repositories.Canonical(raw)
	if err != nil {
		// Allow unambiguous saved repository short names when available.
		resolved, rerr := s.Runs.Repositories().Resolve(ctx, repositories.Owner{WorkspaceID: ws, UserID: u.ID}, raw)
		if rerr != nil {
			return nil, apperr.Invalid("repo_url", "must be a GitHub URL or owner/repo")
		}
		repoURL = resolved
	}
	existing, err := s.Q.ListChatSpaceRepositories(ctx, sp.ID)
	if err != nil {
		return nil, err
	}
	if len(existing) >= maxSpaceRepos {
		return nil, apperr.Invalid("repo_url", "a space can attach up to %d repositories", maxSpaceRepos)
	}
	row, err := s.Q.AddChatSpaceRepository(ctx, store.AddChatSpaceRepositoryParams{
		SpaceID:  sp.ID,
		RepoUrl:  repoURL,
		ReadOnly: deref(req.Body.ReadOnly),
	})
	if isUniqueViolation(err) {
		return nil, apperr.Conflict("that repository is already attached to this space")
	}
	if err != nil {
		return nil, err
	}
	return api.AddChatSpaceRepository201JSONResponse(toSpaceRepo(row)), nil
}

func (s *Server) UpdateChatSpaceRepository(ctx context.Context, req api.UpdateChatSpaceRepositoryRequestObject) (api.UpdateChatSpaceRepositoryResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	row, err := s.Q.UpdateChatSpaceRepository(ctx, store.UpdateChatSpaceRepositoryParams{
		ID:       req.RepoId,
		SpaceID:  sp.ID,
		ReadOnly: req.Body.ReadOnly,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return api.UpdateChatSpaceRepository200JSONResponse(toSpaceRepo(row)), nil
}

func (s *Server) DeleteChatSpaceRepository(ctx context.Context, req api.DeleteChatSpaceRepositoryRequestObject) (api.DeleteChatSpaceRepositoryResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if _, err := s.Q.DeleteChatSpaceRepository(ctx, store.DeleteChatSpaceRepositoryParams{ID: req.RepoId, SpaceID: sp.ID}); errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return api.DeleteChatSpaceRepository204Response{}, nil
}

func (s *Server) ListChatSpaceKnowledgeLinks(ctx context.Context, req api.ListChatSpaceKnowledgeLinksRequestObject) (api.ListChatSpaceKnowledgeLinksResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListChatSpaceKnowledgeLinks(ctx, sp.ID)
	if err != nil {
		return nil, err
	}
	links, err := s.toSpaceKnowledgeLinks(ctx, ws, u.ID, rows)
	if err != nil {
		return nil, err
	}
	return api.ListChatSpaceKnowledgeLinks200JSONResponse{Links: links}, nil
}

func (s *Server) AddChatSpaceKnowledgeLink(ctx context.Context, req api.AddChatSpaceKnowledgeLinkRequestObject) (api.AddChatSpaceKnowledgeLinkResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	kind := string(req.Body.Kind)
	if kind != "folder" && kind != "page" {
		return nil, apperr.Invalid("kind", "must be folder or page")
	}
	p, err := normalizeKnowledgeLinkPath(req.Body.Path)
	if err != nil {
		return nil, err
	}
	existing, err := s.Q.ListChatSpaceKnowledgeLinks(ctx, sp.ID)
	if err != nil {
		return nil, err
	}
	if len(existing) >= maxSpaceKnowledgeLinks {
		return nil, apperr.Invalid("path", "a space can link up to %d knowledge items", maxSpaceKnowledgeLinks)
	}
	isDefault := kind == "folder" && deref(req.Body.IsDefaultTarget)
	// First linked folder becomes the default note folder unless explicitly opted out.
	if kind == "folder" && req.Body.IsDefaultTarget == nil {
		hasDefault := false
		for _, ex := range existing {
			if ex.IsDefaultTarget {
				hasDefault = true
				break
			}
		}
		if !hasDefault {
			isDefault = true
		}
	}
	pinned := kind == "page" && deref(req.Body.Pinned)

	var row store.ChatSpaceKnowledgeLink
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if isDefault {
			if err := q.ClearSpaceDefaultKnowledgeTarget(ctx, sp.ID); err != nil {
				return err
			}
		}
		var err error
		row, err = q.AddChatSpaceKnowledgeLink(ctx, store.AddChatSpaceKnowledgeLinkParams{
			SpaceID:         sp.ID,
			Kind:            kind,
			Path:            p,
			IsDefaultTarget: isDefault,
			Pinned:          pinned,
		})
		return err
	})
	if isUniqueViolation(err) {
		return nil, apperr.Conflict("that knowledge item is already linked to this space")
	}
	if err != nil {
		return nil, err
	}
	item, err := s.toSpaceKnowledgeLink(ctx, ws, u.ID, row)
	if err != nil {
		return nil, err
	}
	return api.AddChatSpaceKnowledgeLink201JSONResponse(item), nil
}

func (s *Server) UpdateChatSpaceKnowledgeLink(ctx context.Context, req api.UpdateChatSpaceKnowledgeLinkRequestObject) (api.UpdateChatSpaceKnowledgeLinkResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	var row store.ChatSpaceKnowledgeLink
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if req.Body.IsDefaultTarget != nil && *req.Body.IsDefaultTarget {
			if err := q.ClearSpaceDefaultKnowledgeTarget(ctx, sp.ID); err != nil {
				return err
			}
		}
		var err error
		row, err = q.UpdateChatSpaceKnowledgeLink(ctx, store.UpdateChatSpaceKnowledgeLinkParams{
			ID:              req.LinkId,
			SpaceID:         sp.ID,
			IsDefaultTarget: req.Body.IsDefaultTarget,
			Pinned:          req.Body.Pinned,
		})
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	item, err := s.toSpaceKnowledgeLink(ctx, ws, u.ID, row)
	if err != nil {
		return nil, err
	}
	return api.UpdateChatSpaceKnowledgeLink200JSONResponse(item), nil
}

func (s *Server) DeleteChatSpaceKnowledgeLink(ctx context.Context, req api.DeleteChatSpaceKnowledgeLinkRequestObject) (api.DeleteChatSpaceKnowledgeLinkResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if _, err := s.Q.DeleteChatSpaceKnowledgeLink(ctx, store.DeleteChatSpaceKnowledgeLinkParams{ID: req.LinkId, SpaceID: sp.ID}); errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return api.DeleteChatSpaceKnowledgeLink204Response{}, nil
}

func (s *Server) ListChatSpaceTasks(ctx context.Context, req api.ListChatSpaceTasksRequestObject) (api.ListChatSpaceTasksResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListChatSpaceTasks(ctx, sp.ID)
	if err != nil {
		return nil, err
	}
	out := make([]api.ChatSpaceTask, len(rows))
	for i, r := range rows {
		out[i] = toSpaceTask(store.ChatSpaceTask{
			ID: r.ID, SpaceID: r.SpaceID, Title: r.Title, Notes: r.Notes, Done: r.Done,
			ChatID: r.ChatID, Position: r.Position, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt,
		}, r.ChatTitle)
	}
	return api.ListChatSpaceTasks200JSONResponse{Tasks: out}, nil
}

func (s *Server) CreateChatSpaceTask(ctx context.Context, req api.CreateChatSpaceTaskRequestObject) (api.CreateChatSpaceTaskResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	title := strings.Join(strings.Fields(req.Body.Title), " ")
	if n := utf8.RuneCountInString(title); n < 1 || n > maxSpaceTaskTitle {
		return nil, apperr.Invalid("title", "must be 1–%d characters", maxSpaceTaskTitle)
	}
	notes := strings.TrimSpace(deref(req.Body.Notes))
	if utf8.RuneCountInString(notes) > maxSpaceTaskNotes {
		return nil, apperr.Invalid("notes", "must be at most %d characters", maxSpaceTaskNotes)
	}
	row, err := s.Q.CreateChatSpaceTask(ctx, store.CreateChatSpaceTaskParams{
		SpaceID: sp.ID,
		Title:   title,
		Notes:   notes,
	})
	if err != nil {
		return nil, err
	}
	return api.CreateChatSpaceTask201JSONResponse(toSpaceTask(row, nil)), nil
}

func (s *Server) UpdateChatSpaceTask(ctx context.Context, req api.UpdateChatSpaceTaskRequestObject) (api.UpdateChatSpaceTaskResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	var title *string
	if req.Body.Title != nil {
		t := strings.Join(strings.Fields(*req.Body.Title), " ")
		if n := utf8.RuneCountInString(t); n < 1 || n > maxSpaceTaskTitle {
			return nil, apperr.Invalid("title", "must be 1–%d characters", maxSpaceTaskTitle)
		}
		title = &t
	}
	var notes *string
	if req.Body.Notes != nil {
		n := strings.TrimSpace(*req.Body.Notes)
		if utf8.RuneCountInString(n) > maxSpaceTaskNotes {
			return nil, apperr.Invalid("notes", "must be at most %d characters", maxSpaceTaskNotes)
		}
		notes = &n
	}
	var pos *int32
	if req.Body.Position != nil {
		v := int32(*req.Body.Position)
		pos = &v
	}
	if req.Body.ChatId != nil && !deref(req.Body.ClearChat) {
		if _, err := s.ownChat(ctx, *req.Body.ChatId); err != nil {
			return nil, apperr.Invalid("chat_id", "unknown chat")
		}
	}
	if _, err := s.Q.UpdateChatSpaceTask(ctx, store.UpdateChatSpaceTaskParams{
		ID:        req.TaskId,
		SpaceID:   sp.ID,
		Title:     title,
		Notes:     notes,
		Done:      req.Body.Done,
		ClearChat: deref(req.Body.ClearChat),
		ChatID:    req.Body.ChatId,
		Position:  pos,
	}); errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	full, err := s.Q.GetChatSpaceTask(ctx, store.GetChatSpaceTaskParams{ID: req.TaskId, SpaceID: sp.ID})
	if err != nil {
		return nil, err
	}
	return api.UpdateChatSpaceTask200JSONResponse(toSpaceTask(store.ChatSpaceTask{
		ID: full.ID, SpaceID: full.SpaceID, Title: full.Title, Notes: full.Notes, Done: full.Done,
		ChatID: full.ChatID, Position: full.Position, CreatedAt: full.CreatedAt, UpdatedAt: full.UpdatedAt,
	}, full.ChatTitle)), nil
}

func (s *Server) DeleteChatSpaceTask(ctx context.Context, req api.DeleteChatSpaceTaskRequestObject) (api.DeleteChatSpaceTaskResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if _, err := s.Q.DeleteChatSpaceTask(ctx, store.DeleteChatSpaceTaskParams{ID: req.TaskId, SpaceID: sp.ID}); errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return api.DeleteChatSpaceTask204Response{}, nil
}

func (s *Server) ListChatSpaceBranches(ctx context.Context, req api.ListChatSpaceBranchesRequestObject) (api.ListChatSpaceBranchesResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	reviews, err := s.Q.ListChatSpaceCodeReviews(ctx, store.ListChatSpaceCodeReviewsParams{
		SpaceID: &sp.ID, WorkspaceID: ws, UserID: u.ID,
	})
	if err != nil {
		return nil, err
	}
	pushes, err := s.Q.ListChatSpacePushRequests(ctx, store.ListChatSpacePushRequestsParams{
		SpaceID: &sp.ID, WorkspaceID: ws, UserID: u.ID,
	})
	if err != nil {
		return nil, err
	}
	type key struct {
		chatID  uuid.UUID
		repoURL string
		branch  string
	}
	byKey := map[key]*api.ChatSpaceBranch{}
	order := []key{}
	for _, r := range reviews {
		if r.Branch == nil || *r.Branch == "" {
			continue
		}
		k := key{chatID: r.ChatID, repoURL: r.RepoUrl, branch: *r.Branch}
		byKey[k] = &api.ChatSpaceBranch{
			ChatId:    r.ChatID,
			ChatTitle: r.ChatTitle,
			RepoUrl:   r.RepoUrl,
			Branch:    *r.Branch,
			Dirty:     r.Dirty,
			Live:      r.Live,
			UpdatedAt: r.UpdatedAt,
		}
		order = append(order, k)
	}
	for _, pr := range pushes {
		k := key{chatID: pr.ChatID, repoURL: pr.RepoUrl, branch: pr.Branch}
		state := pr.State
		prTitle := pr.PrTitle
		var prNum *int
		if pr.PrNumber != nil {
			n := int(*pr.PrNumber)
			prNum = &n
		}
		ts := pr.CreatedAt
		if pr.DecidedAt != nil && pr.DecidedAt.After(ts) {
			ts = *pr.DecidedAt
		}
		if cur, ok := byKey[k]; ok {
			if cur.PushState == nil {
				cur.PushState = &state
				cur.PrUrl = pr.PrUrl
				cur.PrNumber = prNum
				cur.PrTitle = &prTitle
				if ts.After(cur.UpdatedAt) {
					cur.UpdatedAt = ts
				}
			}
			continue
		}
		byKey[k] = &api.ChatSpaceBranch{
			ChatId:    pr.ChatID,
			ChatTitle: pr.ChatTitle,
			RepoUrl:   pr.RepoUrl,
			Branch:    pr.Branch,
			Dirty:     false,
			Live:      false,
			PrUrl:     pr.PrUrl,
			PrNumber:  prNum,
			PrTitle:   &prTitle,
			PushState: &state,
			UpdatedAt: ts,
		}
		order = append(order, k)
	}
	out := make([]api.ChatSpaceBranch, 0, len(order))
	for _, k := range order {
		out = append(out, *byKey[k])
	}
	// Newest activity first.
	for i := 0; i < len(out); i++ {
		for j := i + 1; j < len(out); j++ {
			if out[j].UpdatedAt.After(out[i].UpdatedAt) {
				out[i], out[j] = out[j], out[i]
			}
		}
	}
	// Keep return time non-zero.
	_ = time.UTC
	return api.ListChatSpaceBranches200JSONResponse{Branches: out}, nil
}

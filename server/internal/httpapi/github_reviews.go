package httpapi

import (
	"context"
	"errors"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/githubpr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

func (s *Server) githubPRService() *githubpr.Service {
	s.githubPROnce.Do(func() {
		if s.GitHubPR == nil {
			s.GitHubPR = &githubpr.Service{BaseURL: s.GitHubAPIURL}
		}
	})
	return s.GitHubPR
}

func (s *Server) ListGitHubReviewRequests(ctx context.Context, req api.ListGitHubReviewRequestsRequestObject) (api.ListGitHubReviewRequestsResponseObject, error) {
	_, _, ws := me(ctx)
	var token string
	if s.Secrets != nil {
		var err error
		token, err = s.Secrets.Reveal(ctx, ws, nil, "git:pat")
		if err != nil && !errors.Is(err, apperr.ErrNotFound) && !errors.Is(err, secrets.ErrNoKey) {
			return nil, err
		}
	}
	if token == "" {
		return api.ListGitHubReviewRequests200JSONResponse{
			Configured: false,
			SyncedAt:   time.Now().UTC(),
			Items:      []api.GitHubReviewRequest{},
		}, nil
	}

	refresh := req.Params.Refresh != nil && *req.Params.Refresh
	feed, err := s.githubPRService().ListReviewRequests(ctx, ws, token, refresh)
	if err != nil {
		return nil, err
	}

	items := make([]api.GitHubReviewRequest, 0, len(feed.Items))
	for _, it := range feed.Items {
		item := api.GitHubReviewRequest{
			Id:          it.ID,
			Number:      it.Number,
			Title:       it.Title,
			Url:         it.URL,
			Repository:  it.Repository,
			AuthorLogin: it.AuthorLogin,
			Draft:       it.Draft,
			Direct:      it.Direct,
			Team:        it.Team,
			Additions:   it.Additions,
			Deletions:   it.Deletions,
			CreatedAt:   it.CreatedAt,
			UpdatedAt:   it.UpdatedAt,
		}
		if it.AuthorAvatarURL != "" {
			avatar := it.AuthorAvatarURL
			item.AuthorAvatarUrl = &avatar
		}
		if len(it.Teams) > 0 {
			teams := it.Teams
			item.Teams = &teams
		}
		items = append(items, item)
	}

	out := api.ListGitHubReviewRequests200JSONResponse{
		Configured: true,
		SyncedAt:   feed.SyncedAt,
		Items:      items,
	}
	if feed.ViewerLogin != "" {
		login := feed.ViewerLogin
		out.ViewerLogin = &login
	}
	return out, nil
}

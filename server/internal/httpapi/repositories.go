package httpapi

import (
	"context"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/repositories"
)

func repositoryOwner(ctx context.Context) repositories.Owner {
	u, _, ws := me(ctx)
	return repositories.Owner{WorkspaceID: ws, UserID: u.ID}
}
func (s *Server) ListRepositorySources(ctx context.Context, _ api.ListRepositorySourcesRequestObject) (api.ListRepositorySourcesResponseObject, error) {
	rows, err := s.Runs.Repositories().Sources(ctx, repositoryOwner(ctx))
	if err != nil {
		return nil, err
	}
	out := api.ListRepositorySources200JSONResponse{}
	for _, r := range rows {
		out = append(out, api.RepositorySource{Kind: api.RepositorySourceKind(r.Kind), Name: r.Name})
	}
	return out, nil
}
func (s *Server) SaveRepositorySource(ctx context.Context, req api.SaveRepositorySourceRequestObject) (api.SaveRepositorySourceResponseObject, error) {
	if err := s.Runs.Repositories().Save(ctx, repositoryOwner(ctx), string(req.Body.Kind), req.Body.Name, false); err != nil {
		return nil, err
	}
	return api.SaveRepositorySource204Response{}, nil
}
func (s *Server) DeleteRepositorySource(ctx context.Context, req api.DeleteRepositorySourceRequestObject) (api.DeleteRepositorySourceResponseObject, error) {
	if err := s.Runs.Repositories().Save(ctx, repositoryOwner(ctx), string(req.Body.Kind), req.Body.Name, true); err != nil {
		return nil, err
	}
	return api.DeleteRepositorySource204Response{}, nil
}
func (s *Server) SearchRepositories(ctx context.Context, req api.SearchRepositoriesRequestObject) (api.SearchRepositoriesResponseObject, error) {
	rows, err := s.Runs.Repositories().Search(ctx, repositoryOwner(ctx), derefString(req.Params.Q), req.Params.Refresh != nil && *req.Params.Refresh)
	if err != nil {
		return nil, err
	}
	out := api.SearchRepositories200JSONResponse{}
	for _, r := range rows {
		out = append(out, api.RepositoryEntry{Name: r.Name, Url: r.URL})
	}
	return out, nil
}
func (s *Server) SetChatRepository(ctx context.Context, req api.SetChatRepositoryRequestObject) (api.SetChatRepositoryResponseObject, error) {
	u, _, ws := me(ctx)
	chat, err := s.Runs.SetChatRepository(ctx, ws, u.ID, req.Id, req.Body.Repository, nil)
	if err != nil {
		return nil, err
	}
	out, err := s.toChat(ctx, chat)
	return api.SetChatRepository200JSONResponse(out), err
}
func derefString(p *string) string {
	if p != nil {
		return *p
	}
	return ""
}

func (s *Server) GetRepositoryPresets(ctx context.Context, _ api.GetRepositoryPresetsRequestObject) (api.GetRepositoryPresetsResponseObject, error) {
	presets, err := s.Runs.Repositories().Presets(ctx, repositoryOwner(ctx))
	if err != nil {
		return nil, err
	}
	out := api.RepositoryPresets{Owners: []api.RepositoryOwnerPreset{}}
	for _, owner := range presets.Owners {
		out.Owners = append(out.Owners, api.RepositoryOwnerPreset{Login: owner.Login, Organization: owner.Organization})
	}
	if presets.Warning != "" {
		out.Warning = &presets.Warning
	}
	return api.GetRepositoryPresets200JSONResponse(out), nil
}

func (s *Server) ListOwnerRepositories(ctx context.Context, req api.ListOwnerRepositoriesRequestObject) (api.ListOwnerRepositoriesResponseObject, error) {
	rows, err := s.Runs.Repositories().OwnerRepos(ctx, repositoryOwner(ctx), req.Owner, req.Params.Refresh != nil && *req.Params.Refresh)
	if err != nil {
		return nil, err
	}
	out := api.ListOwnerRepositories200JSONResponse{}
	for _, r := range rows {
		out = append(out, api.RepositoryEntry{Name: r.Name, Url: r.URL})
	}
	return out, nil
}

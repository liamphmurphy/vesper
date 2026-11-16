package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/devworkspace"
	"github.com/liamphmurphy/vesper/server/internal/repositories"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (s *Server) GetDevWorkspace(ctx context.Context, _ api.GetDevWorkspaceRequestObject) (api.GetDevWorkspaceResponseObject, error) {
	_, _, ws := me(ctx)
	row, err := s.Q.GetDevWorkspace(ctx, ws)
	if errors.Is(err, pgx.ErrNoRows) {
		return api.GetDevWorkspace200JSONResponse{
			Enabled:    false,
			NixMode:    api.DevWorkspaceNixModeDefault,
			Repos:      []api.DevWorkspaceRepo{},
			TmuxPrefix: api.DevWorkspaceTmuxPrefixCB,
			State:      api.DevWorkspaceStateStopped,
			UpdatedAt:  time.Now().UTC(),
		}, nil
	}
	if err != nil {
		return nil, err
	}
	return api.GetDevWorkspace200JSONResponse(devWorkspaceOut(row)), nil
}

func (s *Server) UpdateDevWorkspace(ctx context.Context, req api.UpdateDevWorkspaceRequestObject) (api.UpdateDevWorkspaceResponseObject, error) {
	u, _, ws := me(ctx)
	cur, err := s.Q.GetDevWorkspace(ctx, ws)
	hasCur := true
	if errors.Is(err, pgx.ErrNoRows) {
		hasCur = false
		cur = store.DevWorkspace{
			WorkspaceID: ws,
			UserID:      u.ID,
			Enabled:     false,
			NixMode:     "default",
			Repos:       []byte("[]"),
			TmuxPrefix:  "C-b",
			State:       "stopped",
		}
	} else if err != nil {
		return nil, err
	}

	enabled := cur.Enabled
	if req.Body.Enabled != nil {
		enabled = *req.Body.Enabled
	}
	nixMode := cur.NixMode
	if req.Body.NixMode != nil {
		nixMode = string(*req.Body.NixMode)
	}
	if nixMode == "" {
		nixMode = "default"
	}

	var repos []devworkspace.RepoSpec
	_ = json.Unmarshal(cur.Repos, &repos)
	reposChanged := false
	if req.Body.Repos != nil {
		owner := repositoryOwner(ctx)
		resolved := make([]string, 0, len(*req.Body.Repos))
		seen := map[string]bool{}
		for _, raw := range *req.Body.Repos {
			repoURL, rerr := s.Runs.Repositories().Resolve(ctx, owner, raw)
			if rerr != nil {
				if canonical, cerr := repositories.Canonical(raw); cerr == nil {
					repoURL = canonical
				} else {
					return nil, rerr
				}
			}
			if !seen[repoURL] {
				seen[repoURL] = true
				resolved = append(resolved, repoURL)
			}
		}
		repos = devworkspace.DeriveRepoDirs(resolved)
		reposChanged = true
	}

	reposJSON, err := json.Marshal(repos)
	if err != nil {
		return nil, err
	}

	customZshrc := cur.CustomZshrc
	shellChanged := false
	if req.Body.CustomZshrc.IsSpecified() {
		if req.Body.CustomZshrc.IsNull() || strings.TrimSpace(req.Body.CustomZshrc.MustGet()) == "" {
			if customZshrc != nil {
				customZshrc = nil
				shellChanged = true
			}
		} else {
			v := req.Body.CustomZshrc.MustGet()
			if customZshrc == nil || *customZshrc != v {
				customZshrc = &v
				shellChanged = true
			}
		}
	}

	customTmuxConf := cur.CustomTmuxConf
	if req.Body.CustomTmuxConf.IsSpecified() {
		if req.Body.CustomTmuxConf.IsNull() || strings.TrimSpace(req.Body.CustomTmuxConf.MustGet()) == "" {
			if customTmuxConf != nil {
				customTmuxConf = nil
				shellChanged = true
			}
		} else {
			v := req.Body.CustomTmuxConf.MustGet()
			if customTmuxConf == nil || *customTmuxConf != v {
				customTmuxConf = &v
				shellChanged = true
			}
		}
	}

	tmuxPrefix := cur.TmuxPrefix
	if tmuxPrefix == "" {
		tmuxPrefix = "C-b"
	}
	if req.Body.TmuxPrefix != nil && string(*req.Body.TmuxPrefix) != tmuxPrefix {
		tmuxPrefix = string(*req.Body.TmuxPrefix)
		shellChanged = true
	}

	var action *string
	switch {
	case !enabled && hasCur && (cur.Enabled || cur.State != "stopped"):
		a := "stop"
		action = &a
	case enabled && (!hasCur || !cur.Enabled || cur.State == "stopped" || cur.State == "error"):
		a := "start"
		action = &a
	case enabled && (reposChanged || shellChanged):
		a := "sync"
		action = &a
	}

	row, err := s.Q.UpsertDevWorkspace(ctx, store.UpsertDevWorkspaceParams{
		WorkspaceID:    ws,
		UserID:         u.ID,
		Enabled:        enabled,
		NixMode:        nixMode,
		Repos:          reposJSON,
		CustomZshrc:    customZshrc,
		CustomTmuxConf: customTmuxConf,
		TmuxPrefix:     tmuxPrefix,
		Action:         action,
	})
	if err != nil {
		return nil, err
	}
	return api.UpdateDevWorkspace200JSONResponse(devWorkspaceOut(row)), nil
}

func (s *Server) DevWorkspaceAction(ctx context.Context, req api.DevWorkspaceActionRequestObject) (api.DevWorkspaceActionResponseObject, error) {
	_, _, ws := me(ctx)
	cur, err := s.Q.GetDevWorkspace(ctx, ws)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Conflict("Enable the persistent dev workspace in Settings first.")
	}
	if err != nil {
		return nil, err
	}
	act := string(req.Body.Action)
	if !cur.Enabled && act != "stop" {
		return nil, apperr.Conflict("Enable the persistent dev workspace in Settings first.")
	}
	row, err := s.Q.RequestDevWorkspaceAction(ctx, store.RequestDevWorkspaceActionParams{
		WorkspaceID: ws,
		Action:      &act,
	})
	if err != nil {
		return nil, err
	}
	return api.DevWorkspaceAction200JSONResponse(devWorkspaceOut(row)), nil
}

func devWorkspaceOut(row store.DevWorkspace) api.DevWorkspace {
	var repos []devworkspace.RepoSpec
	_ = json.Unmarshal(row.Repos, &repos)
	apiRepos := make([]api.DevWorkspaceRepo, 0, len(repos))
	for _, r := range repos {
		apiRepos = append(apiRepos, api.DevWorkspaceRepo{RepoUrl: r.RepoURL, Directory: r.Directory})
	}
	tmuxPrefix := api.DevWorkspaceTmuxPrefix(row.TmuxPrefix)
	if tmuxPrefix == "" {
		tmuxPrefix = api.DevWorkspaceTmuxPrefixCB
	}
	out := api.DevWorkspace{
		Enabled:    row.Enabled,
		NixMode:    api.DevWorkspaceNixMode(row.NixMode),
		Repos:      apiRepos,
		TmuxPrefix: tmuxPrefix,
		State:      api.DevWorkspaceState(row.State),
		Step:       nullableOf(row.Step),
		Error:      nullableOf(row.Error),
		Arch:       nullableOf(row.Arch),
		UpdatedAt:  row.UpdatedAt,
	}
	if row.CustomZshrc != nil {
		out.CustomZshrc.Set(*row.CustomZshrc)
	} else {
		out.CustomZshrc.SetNull()
	}
	if row.CustomTmuxConf != nil {
		out.CustomTmuxConf.Set(*row.CustomTmuxConf)
	} else {
		out.CustomTmuxConf.SetNull()
	}
	if row.Port != nil {
		out.Port.Set(int(*row.Port))
	} else {
		out.Port.SetNull()
	}
	if row.Action != nil {
		a := api.DevWorkspaceAction(*row.Action)
		out.Action.Set(a)
	} else {
		out.Action.SetNull()
	}
	return out
}

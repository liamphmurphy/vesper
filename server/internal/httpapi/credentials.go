package httpapi

import (
	"context"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (s *Server) mcpURL() string { return strings.TrimRight(s.PublicURL, "/") + "/mcp" }

func toToken(t store.AgentToken, dir actorDirectory) api.AgentToken {
	out := api.AgentToken{Id: t.ID, Prefix: t.Prefix, Label: t.Label, CreatedAt: t.CreatedAt, LastUsedAt: t.LastUsedAt, RevokedAt: t.RevokedAt}
	if t.CreatedByUserID != nil {
		if u, ok := dir.users[*t.CreatedByUserID]; ok {
			out.CreatedBy = toUserRef(u)
		}
	}
	return out
}

func (s *Server) ListAgentTokens(ctx context.Context, req api.ListAgentTokensRequestObject) (api.ListAgentTokensResponseObject, error) {
	_, _, ws := me(ctx)
	a, err := s.agentByHandle(ctx, ws, req.Handle)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListAgentTokens(ctx, a.ID)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := api.ListAgentTokens200JSONResponse{Tokens: make([]api.AgentToken, 0, len(rows)), McpUrl: s.mcpURL()}
	for _, t := range rows {
		out.Tokens = append(out.Tokens, toToken(t, dir))
	}
	return out, nil
}

func (s *Server) CreateAgentToken(ctx context.Context, req api.CreateAgentTokenRequestObject) (api.CreateAgentTokenResponseObject, error) {
	u, _, ws := me(ctx)
	a, err := s.agentByHandle(ctx, ws, req.Handle)
	if err != nil {
		return nil, err
	}
	label := deref(req.Body.Label)
	if len(label) > 80 {
		return nil, apperr.Invalid("label", "is limited to 80 characters")
	}
	tok, row, err := agents.IssueToken(ctx, s.Q, a.ID, "unmanaged", label, nil, &u.ID, nil)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.CreateAgentToken201JSONResponse{Token: tok, Info: toToken(row, dir), McpUrl: s.mcpURL()}, nil
}

func (s *Server) RevokeAgentToken(ctx context.Context, req api.RevokeAgentTokenRequestObject) (api.RevokeAgentTokenResponseObject, error) {
	_, _, ws := me(ctx)
	a, err := s.agentByHandle(ctx, ws, req.Handle)
	if err != nil {
		return nil, err
	}
	if err := agents.RevokeToken(ctx, s.Q, a.ID, req.TokenId); err != nil {
		return nil, err
	}
	return api.RevokeAgentToken204Response{}, nil
}

var knownSecrets = []struct{ name, grants, desc string }{
	{"git:pat", "repo:write", "GitHub personal access token for clone, push and PRs"},
	{"git:ssh", "repo:write", "SSH private key for cloning and pushing over git@github.com"},
	{"harness:anthropic", "", "API key for Claude Code runs"},
	{"harness:openai", "", "API key for Codex runs"},
	{"harness:google", "", "Antigravity login bundle for Antigravity runs"},
	{"db:staging", "db:migrate", "Staging database URL, used by the db:migrate broker"},
	{"db:staging-readonly", "db:read-staging", "Read-only staging database URL"},
	{"deploy:staging", "deploy:staging", "Token for triggering staging deploys"},
}

func (s *Server) ListSecrets(ctx context.Context, _ api.ListSecretsRequestObject) (api.ListSecretsResponseObject, error) {
	_, _, ws := me(ctx)
	rows, err := s.Q.ListSecrets(ctx, ws)
	if err != nil {
		return nil, err
	}
	live, err := s.Q.LiveIsolatingRunnerExists(ctx)
	if err != nil {
		return nil, err
	}
	out := api.ListSecrets200JSONResponse{Secrets: make([]api.SecretInfo, 0, len(rows)), KeyConfigured: s.Secrets.Box != nil,
		SignInAvailable: live && s.Secrets.Box != nil}
	keys := s.Runs != nil && s.Runs.RequireHarnessKey
	out.HarnessKeysRequired = &keys
	for _, r := range rows {
		si := api.SecretInfo{Id: r.ID, Name: r.Name, GrantsScope: r.GrantsScope, CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt, LastUsedAt: r.LastUsedAt}
		if r.ProjectID != nil {
			si.Project = &api.Project{Id: *r.ProjectID, Key: deref(r.ProjectKey), Name: deref(r.ProjectName), Color: deref(r.ProjectColor)}
		}
		out.Secrets = append(out.Secrets, si)
	}
	for _, k := range knownSecrets {
		item := struct {
			Description string  `json:"description"`
			GrantsScope *string `json:"grants_scope,omitempty"`
			Name        string  `json:"name"`
		}{Description: k.desc, Name: k.name}
		if k.grants != "" {
			g := k.grants
			item.GrantsScope = &g
		}
		out.Known = append(out.Known, item)
	}
	return out, nil
}

func (s *Server) SetSecret(ctx context.Context, req api.SetSecretRequestObject) (api.SetSecretResponseObject, error) {
	u, _, ws := me(ctx)
	b := req.Body
	in := secrets.SetInput{Name: b.Name, Value: b.Value, GrantsScope: deref(b.GrantsScope)}
	var project *api.Project
	if k := deref(b.ProjectKey); k != "" {
		p, err := s.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: k})
		if err != nil {
			return nil, apperr.Invalid("project_key", "unknown project")
		}
		in.ProjectID = &p.ID
		ap := toProject(p)
		project = &ap
	}
	r, err := s.Secrets.Set(ctx, ws, u.ID, in)
	if err != nil {
		return nil, err
	}
	return api.SetSecret200JSONResponse{Id: r.ID, Name: r.Name, Project: project, GrantsScope: r.GrantsScope,
		CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt, LastUsedAt: r.LastUsedAt}, nil
}

func (s *Server) DeleteSecret(ctx context.Context, req api.DeleteSecretRequestObject) (api.DeleteSecretResponseObject, error) {
	_, _, ws := me(ctx)
	n, err := s.Q.DeleteSecret(ctx, store.DeleteSecretParams{ID: req.Id, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, apperr.ErrNotFound
	}
	return api.DeleteSecret204Response{}, nil
}

package httpapi

import (
	"context"
	"encoding/json"
	"sort"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// recode converts between agentdef and API types, which share JSON shapes.
func recode[T any](v any) (T, error) {
	var out T
	b, err := json.Marshal(v)
	if err != nil {
		return out, err
	}
	err = json.Unmarshal(b, &out)
	return out, err
}

var harnessLabels = map[string]string{agentdef.HarnessClaudeCode: "Claude Code", agentdef.HarnessCodex: "Codex", agentdef.HarnessAntigravity: "Antigravity"}

func (s *Server) agentByHandle(ctx context.Context, ws uuid.UUID, handle string) (store.Agent, error) {
	a, err := s.Q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: handle})
	if err != nil {
		return a, apperr.ErrNotFound
	}
	return a, nil
}

func (s *Server) agentDetail(ctx context.Context, ws uuid.UUID, a store.Agent) (api.AgentDetail, error) {
	spec, cur, err := agents.CurrentSpec(ctx, s.Q, a)
	if err != nil {
		return api.AgentDetail{}, err
	}
	apiSpec, err := recode[api.AgentSpec](spec)
	if err != nil {
		return api.AgentDetail{}, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return api.AgentDetail{}, err
	}
	version := func(v store.AgentDefinitionVersion) api.DefinitionVersion {
		dv := api.DefinitionVersion{Id: v.ID, Version: int(v.Version), Note: v.Note, CreatedAt: v.CreatedAt}
		if v.CreatedByUserID != nil {
			if u, ok := dir.users[*v.CreatedByUserID]; ok {
				dv.CreatedBy = toUserRef(u)
			}
		}
		return dv
	}
	out := api.AgentDetail{
		Agent: toAgent(a), Specialty: a.Specialty, Spec: apiSpec, Definition: version(cur),
		Versions: []api.DefinitionVersion{}, Overrides: []api.ProjectOverride{},
	}
	versions, err := s.Q.ListDefinitionVersions(ctx, a.ID)
	if err != nil {
		return out, err
	}
	for _, v := range versions {
		out.Versions = append(out.Versions, version(v))
	}
	overrides, err := s.Q.ListOverrides(ctx, a.ID)
	if err != nil {
		return out, err
	}
	for _, o := range overrides {
		ov, err := agents.DecodeOverride(o.Spec)
		if err != nil {
			return out, err
		}
		apiOv, err := recode[api.AgentOverride](ov)
		if err != nil {
			return out, err
		}
		out.Overrides = append(out.Overrides, api.ProjectOverride{
			Project:  api.Project{Id: o.ProjectID, Key: o.ProjectKey, Name: o.ProjectName, Color: o.ProjectColor},
			Override: apiOv, Changes: ov.Changes(), Version: int(o.Version), UpdatedAt: o.UpdatedAt,
		})
	}
	for _, h := range agentdef.Harnesses {
		c := agentdef.Capabilities[h]
		out.Harnesses = append(out.Harnesses, api.HarnessInfo{
			Name: api.Harness(h), Label: harnessLabels[h],
			ToolGating: c.ToolGating, PermissionPrompt: c.PermissionPrompt, NativeCost: c.NativeCost, Resume: c.Resume,
		})
	}
	names := make([]string, 0, len(agentdef.Catalog))
	for k := range agentdef.Catalog {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		info := agentdef.Catalog[k]
		si := api.ScopeInfo{Scope: k, Description: info.Description, Brokered: info.Brokered, ApiOnly: &info.APIOnly}
		if info.Secret != "" {
			si.Secret = &info.Secret
		}
		out.Catalog = append(out.Catalog, si)
	}
	return out, nil
}

func (s *Server) GetAgent(ctx context.Context, req api.GetAgentRequestObject) (api.GetAgentResponseObject, error) {
	_, _, ws := me(ctx)
	a, err := s.agentByHandle(ctx, ws, req.Handle)
	if err != nil {
		return nil, err
	}
	d, err := s.agentDetail(ctx, ws, a)
	return api.GetAgent200JSONResponse(d), err
}

func (s *Server) DeleteAgent(ctx context.Context, req api.DeleteAgentRequestObject) (api.DeleteAgentResponseObject, error) {
	_, _, ws := me(ctx)
	if err := s.Agents.Delete(ctx, ws, req.Handle); err != nil {
		return nil, err
	}
	return api.DeleteAgent204Response{}, nil
}

func (s *Server) SaveAgentDefinition(ctx context.Context, req api.SaveAgentDefinitionRequestObject) (api.SaveAgentDefinitionResponseObject, error) {
	u, _, ws := me(ctx)
	b := req.Body
	spec, err := recode[agentdef.Spec](b.Spec)
	if err != nil {
		return nil, apperr.Invalid("spec", "malformed definition")
	}
	a, err := s.Agents.SaveDefinition(ctx, ws, u.ID, req.Handle,
		agents.Identity{Name: b.Name, Role: b.Role, Specialty: b.Specialty, ColorIndex: b.ColorIndex}, spec, deref(b.Note))
	if err != nil {
		return nil, err
	}
	d, err := s.agentDetail(ctx, ws, a)
	return api.SaveAgentDefinition200JSONResponse(d), err
}

func (s *Server) SetAgentOverride(ctx context.Context, req api.SetAgentOverrideRequestObject) (api.SetAgentOverrideResponseObject, error) {
	u, _, ws := me(ctx)
	o, err := recode[agentdef.Override](req.Body)
	if err != nil {
		return nil, apperr.Invalid("override", "malformed override")
	}
	if err := s.Agents.SetOverride(ctx, ws, u.ID, req.Handle, req.Project, o); err != nil {
		return nil, err
	}
	a, err := s.agentByHandle(ctx, ws, req.Handle)
	if err != nil {
		return nil, err
	}
	d, err := s.agentDetail(ctx, ws, a)
	return api.SetAgentOverride200JSONResponse(d), err
}

func (s *Server) GetResolvedDefinition(ctx context.Context, req api.GetResolvedDefinitionRequestObject) (api.GetResolvedDefinitionResponseObject, error) {
	_, _, ws := me(ctx)
	a, err := s.agentByHandle(ctx, ws, req.Handle)
	if err != nil {
		return nil, err
	}
	r, err := agents.Resolve(ctx, s.Q, ws, a, deref(req.Params.Project))
	if err != nil {
		return nil, err
	}
	out, err := recode[api.GetResolvedDefinition200JSONResponse](r)
	if err != nil {
		return nil, err
	}
	out.Scopes = make([]api.ResolvedScope, 0, len(r.Scopes))
	for _, sc := range r.Scopes {
		enf, how := agentdef.EnforcementFor(sc.Scope, sc.Mode, r.Harness)
		out.Scopes = append(out.Scopes, api.ResolvedScope{
			Scope: sc.Scope, Mode: api.ScopeMode(sc.Mode), Source: api.ResolvedScopeSource(sc.Source),
			Enforcement: api.ResolvedScopeEnforcement(enf), How: how, Description: agentdef.Catalog[sc.Scope].Description,
		})
	}
	return out, nil
}

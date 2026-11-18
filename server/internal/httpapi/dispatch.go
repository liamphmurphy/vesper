package httpapi

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// Dispatch (docs/dev/plan.md §6.6): a person reviews exactly what a run gets, then
// queues it for the runner.

func (s *Server) runnerStatus(ctx context.Context) (api.RunnerStatus, error) {
	out := api.RunnerStatus{Runners: []api.RunnerInfo{}}
	_, _, ws := me(ctx)
	on, err := s.Q.HostFolderWorkspaces(ctx, ws)
	if err != nil {
		return out, err
	}
	out.HostFolderWorkspaces = on
	rs, err := s.Q.LiveRunners(ctx)
	if err != nil {
		return out, err
	}
	for _, r := range rs {
		info := api.RunnerInfo{Id: r.ID, Backend: api.RunnerInfoBackend(r.Backend), MaxConcurrent: int(r.MaxConcurrent),
			Running: int(r.Running), Version: &r.Version, HeartbeatAt: r.HeartbeatAt}
		if r.HostWorkspacesDir != "" {
			info.HostWorkspacesDir = &r.HostWorkspacesDir
		}
		slots := int(r.MaxConcurrent)
		if r.SlotLimit != nil {
			limit := int(*r.SlotLimit)
			info.SlotLimit = &limit
			slots = min(slots, limit)
		}
		out.Runners = append(out.Runners, info)
		out.Slots += slots
		out.Busy += int(r.Running)
	}
	out.Online = len(rs) > 0
	if !out.Online && s.RunnerStarting != nil && s.RunnerStarting() {
		starting := true
		out.Starting = &starting
	}
	live, err := s.Q.LiveWorkRunsCount(ctx)
	if err != nil {
		return out, err
	}
	out.Live = int(live)
	n, err := s.Q.QueuedRunsCount(ctx)
	out.Queued = int(n)
	return out, err
}

func (s *Server) GetRunnerStatus(ctx context.Context, _ api.GetRunnerStatusRequestObject) (api.GetRunnerStatusResponseObject, error) {
	st, err := s.runnerStatus(ctx)
	return api.GetRunnerStatus200JSONResponse(st), err
}

func (s *Server) UpdateRunnerSettings(ctx context.Context, req api.UpdateRunnerSettingsRequestObject) (api.UpdateRunnerSettingsResponseObject, error) {
	_, _, ws := me(ctx)
	if err := s.Q.SetHostFolderWorkspaces(ctx, store.SetHostFolderWorkspacesParams{ID: ws, HostFolderWorkspaces: req.Body.HostFolderWorkspaces}); err != nil {
		return nil, err
	}
	st, err := s.runnerStatus(ctx)
	return api.UpdateRunnerSettings200JSONResponse(st), err
}

// SetRunnerSlotLimit caps (or uncaps) the runners for the desktop's thermal
// back-off. Runners apply it on their next heartbeat.
func (s *Server) SetRunnerSlotLimit(ctx context.Context, req api.SetRunnerSlotLimitRequestObject) (api.SetRunnerSlotLimitResponseObject, error) {
	if !req.Body.Limit.IsSpecified() {
		return nil, apperr.Invalid("limit", "required: a number from 1 to 32, or null")
	}
	var limit *int32
	if !req.Body.Limit.IsNull() {
		n := req.Body.Limit.MustGet()
		if n < 1 || n > 32 {
			return nil, apperr.Invalid("limit", "must be between 1 and 32, or null")
		}
		v := int32(n)
		limit = &v
	}
	if err := s.Q.SetRunnerSlotLimit(ctx, limit); err != nil {
		return nil, err
	}
	st, err := s.runnerStatus(ctx)
	return api.SetRunnerSlotLimit200JSONResponse(st), err
}

func (s *Server) GetDispatchPreview(ctx context.Context, req api.GetDispatchPreviewRequestObject) (api.GetDispatchPreviewResponseObject, error) {
	_, _, ws := me(ctx)
	t, err := tracker.Get(ctx, s.Q, ws, req.Key)
	if err != nil {
		return nil, err
	}
	out := api.GetDispatchPreview200JSONResponse{TicketKey: t.Key, Setup: []string{}, Context: []api.DispatchContext{},
		Scopes: []api.DispatchScope{}, Secrets: []api.DispatchSecret{}, Blockers: []string{}, QueuedBehind: []string{}}
	if out.Runner, err = s.runnerStatus(ctx); err != nil {
		return nil, err
	}
	blockers, err := tracker.HardBlockers(ctx, s.Q, t)
	if err != nil {
		return nil, err
	}
	out.Blockers = append(out.Blockers, blockers...)
	if out.QueuedBehind, err = tracker.QueuedBehind(ctx, s.Q, t); err != nil {
		return nil, err
	}
	if t.Status == "done" {
		out.Blockers = append(out.Blockers, t.Key+" is done")
	}
	if live, err := s.Q.ActiveRunForTicket(ctx, &t.ID); err == nil {
		out.Blockers = append(out.Blockers, fmt.Sprintf("%s already has a %s run", t.Key, live.State))
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	if t.AssigneeAgentID == nil {
		out.Blockers = append(out.Blockers, "No agent is assigned")
		return out, nil
	}
	agent, err := s.Q.GetAgent(ctx, store.GetAgentParams{ID: *t.AssigneeAgentID, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	out.Agent = *toAgentRef(agent)
	p, err := s.Q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	out.RepoUrl = p.RepoUrl
	out.BaseBranch = &p.DefaultBranch
	if repo, err := runs.RepositoryFor(ctx, s.Q, p, t); err != nil {
		return nil, err
	} else if repo.EpicBranch != "" {
		out.BaseBranch = &repo.EpicBranch
	}
	if agent.CurrentDefinitionVersionID != nil {
		if v, err := s.Q.GetDefinitionVersion(ctx, *agent.CurrentDefinitionVersionID); err == nil {
			n := int(v.Version)
			out.DefinitionVersion = &n
		}
	}
	if _, err := s.Q.GetOverride(ctx, store.GetOverrideParams{AgentID: agent.ID, ProjectID: p.ID}); err == nil {
		yes := true
		out.HasOverride = &yes
	}
	resolved, err := agents.ResolveRunnable(ctx, s.Q, ws, agent, p.Key)
	if err != nil {
		return nil, err
	}
	if out.Resolved, err = recode[api.ResolvedDefinition](resolved); err != nil {
		return nil, err
	}
	out.Setup = append(out.Setup, resolved.Setup...)
	out.Branch = runner.BranchName(agent.Handle, t.Key, t.Title)
	if t.Branch != nil && *t.Branch != "" {
		out.Branch = *t.Branch
	}
	for _, sc := range resolved.Scopes {
		enf, how := agentdef.EnforcementFor(sc.Scope, sc.Mode, resolved.Harness)
		d := api.DispatchScope{Scope: sc.Scope, Mode: api.ScopeMode(sc.Mode), Source: api.DispatchScopeSource(sc.Source),
			Enforcement: api.DispatchScopeEnforcement(enf), How: how}
		if info, ok := agentdef.Catalog[sc.Scope]; ok {
			d.Description = &info.Description
		}
		out.Scopes = append(out.Scopes, d)
	}
	plan, err := runner.PlanSecrets(ctx, s.Q, ws, &p.ID, resolved)
	if err != nil {
		return nil, err
	}
	key, err := runner.HarnessKey(resolved)
	if err != nil {
		return nil, apperr.Invalid("model", "%s", err.Error())
	}
	out.HarnessKey.Secret = key.Secret
	for _, d := range plan {
		sec := api.DispatchSecret{Name: d.Name, Injected: d.Injected, Reason: d.Reason}
		if d.Scope != "" {
			sec.Scope = &d.Scope
		}
		out.Secrets = append(out.Secrets, sec)
		if d.Name == key.Secret {
			out.HarnessKey.Present = true
		}
	}
	files, err := runner.ContextFiles(ctx, s.Q, agent, t, resolved.Memory)
	if err != nil {
		return nil, err
	}
	for _, f := range files {
		title, kind := f.Path, "artifact"
		if a, err := s.Q.GetArtifact(ctx, store.GetArtifactParams{ID: f.ArtifactID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID}); err == nil {
			title, kind = a.Title, a.Type
			if a.Path != nil {
				title, kind = *a.Path, "wiki"
			}
		}
		out.Context = append(out.Context, api.DispatchContext{Title: title, Kind: kind, Path: f.Path})
	}
	return out, nil
}

func (s *Server) DispatchTicket(ctx context.Context, req api.DispatchTicketRequestObject) (api.DispatchTicketResponseObject, error) {
	u, _, ws := me(ctx)
	if _, err := s.Runs.Dispatch(ctx, ws, u.ID, []string{req.Key}); err != nil {
		return nil, err
	}
	t, err := tracker.Get(ctx, s.Q, ws, req.Key)
	if err != nil {
		return nil, err
	}
	d, err := s.ticketDetail(ctx, ws, t)
	return api.DispatchTicket200JSONResponse(d), err
}

func (s *Server) DispatchTickets(ctx context.Context, req api.DispatchTicketsRequestObject) (api.DispatchTicketsResponseObject, error) {
	u, _, ws := me(ctx)
	out, err := s.Runs.Dispatch(ctx, ws, u.ID, req.Body.Keys)
	if err != nil {
		return nil, err
	}
	return api.DispatchTickets200JSONResponse{Dispatched: len(out)}, nil
}

func (s *Server) GetTurnLog(ctx context.Context, req api.GetTurnLogRequestObject) (api.GetTurnLogResponseObject, error) {
	run, err := s.readableRun(ctx, req.Id)
	if err != nil {
		return nil, apperr.ErrNotFound
	}
	turns, err := s.Q.ListTurns(ctx, run.ID)
	if err != nil {
		return nil, err
	}
	for _, t := range turns {
		if int(t.Seq) != req.Seq || t.LogKey == nil {
			continue
		}
		if s.Blobs == nil {
			return nil, apperr.ErrNotFound
		}
		obj, err := s.Blobs.Get(ctx, "run-logs", *t.LogKey)
		if err != nil {
			return nil, err
		}
		return turnLog{body: obj.Body, size: obj.ContentLength, name: fmt.Sprintf("run-%s-turn-%d.jsonl", run.ID.String()[:8], t.Seq)}, nil
	}
	return nil, apperr.ErrNotFound
}

type turnLog struct {
	body io.ReadCloser
	size int64
	name string
}

func (l turnLog) VisitGetTurnLogResponse(w http.ResponseWriter) error {
	defer l.body.Close()
	w.Header().Set("Content-Type", "application/x-ndjson; charset=utf-8")
	w.Header().Set("Content-Disposition", `attachment; filename="`+strings.ReplaceAll(l.name, `"`, "")+`"`)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	_, err := io.Copy(w, l.body)
	return err
}

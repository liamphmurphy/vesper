package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/pushreq"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// GetChatCodeReview is what the Code dock shows: each repository's branch as
// the runner last read it, kept after the workspace is gone.
func (s *Server) GetChatCodeReview(ctx context.Context, req api.GetChatCodeReviewRequestObject) (api.GetChatCodeReviewResponseObject, error) {
	if _, err := s.ownChat(ctx, req.Id); err != nil {
		return nil, err
	}
	rows, err := s.Q.ChatCodeReviews(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.CodeReview, 0, len(rows))
	for _, r := range rows {
		tree := []api.CodeReviewFile{}
		_ = json.Unmarshal(r.Tree, &tree)
		treeTruncated := r.TreeTruncated
		cr := api.CodeReview{Repository: r.RepoUrl, Branch: r.Branch, BaseSha: r.BaseSha, HeadSha: r.HeadSha, Dirty: r.Dirty, Live: r.Live,
			UpdatedAt: r.UpdatedAt, Commits: []api.CodeCommit{}, Files: []api.ChatCodeChange{}, Tree: &tree, TreeTruncated: &treeTruncated}
		_ = json.Unmarshal(r.Commits, &cr.Commits)
		_ = json.Unmarshal(r.Files, &cr.Files)
		out = append(out, cr)
	}
	return api.GetChatCodeReview200JSONResponse{Repositories: out}, nil
}

// ListPushRequests is the push cards under a chat.
func (s *Server) ListPushRequests(ctx context.Context, req api.ListPushRequestsRequestObject) (api.ListPushRequestsResponseObject, error) {
	if _, err := s.ownChat(ctx, req.Id); err != nil {
		return nil, err
	}
	rows, err := s.Q.ChatPushRequests(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.PushRequest, 0, len(rows))
	for _, r := range rows {
		out = append(out, s.toPushRequest(ctx, r))
	}
	return api.ListPushRequests200JSONResponse{Requests: out}, nil
}

// DecidePushRequest pushes a staged branch and opens its pull request, or
// declines it. Claiming the request (pending → pushing) is the only step in a
// transaction, so a second click finds it decided; the GitHub calls run after,
// and the request always ends pushed or failed with why.
func (s *Server) DecidePushRequest(ctx context.Context, req api.DecidePushRequestRequestObject) (api.DecidePushRequestResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil || !req.Body.Decision.Valid() {
		return nil, apperr.Invalid("decision", "must be push, always or deny")
	}
	cur, err := s.Q.GetPushRequest(ctx, store.GetPushRequestParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if cur.State != "pending" {
		return nil, apperr.Conflict("this push is no longer waiting")
	}
	chat, err := s.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: cur.ChatID, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	gh := &pushreq.GitHub{BaseURL: s.GitHubAPIURL}
	if s.Secrets != nil {
		project := runs.ProjectIDOrNil(chat.ProjectID)
		token, err := s.Secrets.Reveal(ctx, ws, &project, "git:pat")
		if err != nil && !errors.Is(err, apperr.ErrNotFound) && !errors.Is(err, secrets.ErrNoKey) {
			return nil, err
		}
		gh.Token = token
	}
	if req.Body.Decision == api.PushRequestDecisionDecisionDeny {
		r, err := s.Q.DeclinePushRequest(ctx, store.DeclinePushRequestParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.Conflict("this push is no longer waiting")
		}
		if err != nil {
			return nil, err
		}
		if gh.Token != "" {
			pushreq.Discard(context.WithoutCancel(ctx), gh, r)
		}
		return api.DecidePushRequest200JSONResponse(s.toPushRequest(ctx, r)), nil
	}
	if gh.Token == "" {
		return nil, apperr.Conflict("no GitHub token: add git:pat in Settings → Connections & secrets")
	}
	title, body, draft := cur.Title, cur.Body, cur.Draft
	if req.Body.Title != nil {
		if title = strings.TrimSpace(*req.Body.Title); title == "" {
			return nil, apperr.Invalid("title", "required")
		}
	}
	if req.Body.Body != nil {
		body = *req.Body.Body
	}
	if req.Body.Draft != nil {
		draft = *req.Body.Draft
	}
	always := req.Body.Decision == api.PushRequestDecisionDecisionAlways
	claimed, err := s.Q.ClaimPushRequest(ctx, store.ClaimPushRequestParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID,
		Title: title, Body: body, Draft: draft, Auto: false})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Conflict("this push is no longer waiting")
	}
	if err != nil {
		return nil, err
	}
	if always {
		if _, err := s.Q.SetRepositoryPushPolicy(ctx, store.SetRepositoryPushPolicyParams{WorkspaceID: ws, UserID: u.ID, RepoUrl: claimed.RepoUrl, AutoPush: true}); err != nil {
			s.Log.Warn("always allow pushes", "repo", claimed.RepoUrl, "err", err)
		}
	}
	// The person's click must not be lost to a closed tab: finish regardless.
	sctx := context.WithoutCancel(ctx)
	res, shipErr := pushreq.Ship(sctx, gh, claimed)
	done, err := pushreq.Finish(sctx, s.Q, claimed, res, shipErr)
	if err != nil {
		return nil, err
	}
	return api.DecidePushRequest200JSONResponse(s.toPushRequest(ctx, done)), nil
}

// ListRepositoryPushPolicies is the repositories the person always allows.
func (s *Server) ListRepositoryPushPolicies(ctx context.Context, _ api.ListRepositoryPushPoliciesRequestObject) (api.ListRepositoryPushPoliciesResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListRepositoryPushPolicies(ctx, store.ListRepositoryPushPoliciesParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out := make([]api.RepositoryPushPolicy, 0, len(rows))
	for _, r := range rows {
		out = append(out, api.RepositoryPushPolicy{Repository: r.RepoUrl, AutoPush: r.AutoPush})
	}
	return api.ListRepositoryPushPolicies200JSONResponse{Policies: out}, nil
}

// SetRepositoryPushPolicy always allows a repository's pushes, or asks again.
func (s *Server) SetRepositoryPushPolicy(ctx context.Context, req api.SetRepositoryPushPolicyRequestObject) (api.SetRepositoryPushPolicyResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil || strings.TrimSpace(req.Body.Repository) == "" {
		return nil, apperr.Invalid("repository", "required")
	}
	r, err := s.Q.SetRepositoryPushPolicy(ctx, store.SetRepositoryPushPolicyParams{WorkspaceID: ws, UserID: u.ID, RepoUrl: strings.TrimSpace(req.Body.Repository), AutoPush: req.Body.AutoPush})
	if err != nil {
		return nil, err
	}
	return api.SetRepositoryPushPolicy200JSONResponse{Repository: r.RepoUrl, AutoPush: r.AutoPush}, nil
}

func (s *Server) toPushRequest(ctx context.Context, r store.PushRequest) api.PushRequest {
	out := api.PushRequest{Id: r.ID, Repository: r.RepoUrl, Branch: r.Branch, BaseBranch: r.BaseBranch, BaseSha: r.BaseSha, HeadSha: r.HeadSha,
		Title: r.Title, Body: r.Body, Draft: r.Draft, State: api.PushRequestState(r.State), Auto: r.Auto, PrUrl: r.PrUrl, Error: r.Error,
		CreatedAt: r.CreatedAt, DecidedAt: r.DecidedAt, Commits: []api.CodeCommit{}, Files: []api.ChatCodeChange{}}
	if r.PrNumber != nil {
		n := int(*r.PrNumber)
		out.PrNumber = &n
	}
	_ = json.Unmarshal(r.Commits, &out.Commits)
	_ = json.Unmarshal(r.Files, &out.Files)
	if r.PersonaID != nil {
		if p, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: *r.PersonaID, WorkspaceID: r.WorkspaceID, UserID: r.UserID}); err == nil {
			out.Persona = toPersonaSummary(p)
		}
	}
	return out
}

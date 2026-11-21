package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentapi"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/pushreq"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// agentDeps is what the Agent API, and applying a persona's approved ticket
// edit, run with.
func (s *Server) agentDeps() agentapi.Deps {
	return agentapi.Deps{
		Q:          s.Q,
		Runs:       s.Runs,
		Tracker:    s.Tracker,
		Wiki:       s.Wiki,
		Connectors: s.connectors(),
		Secrets:    s.userSecrets(),
		Designs:    s.designs(),
		CustomApps: s.customApps(),
		AppAPICall: func(ctx context.Context, user store.User, method, rawPath string, body any) (any, error) {
			cleaned, _, err := validateCustomAppAPIRequest(method, rawPath)
			if err != nil {
				return nil, err
			}
			return s.dispatchCustomAppAPI(ctx, user, method, cleaned, body)
		},
		Files: s,
		PDF:   s.DesignWorker,
		Music: s.musicRunner(),
		DiscardPush: func(ctx context.Context, r store.PushRequest) {
			if s.Secrets == nil || r.StagingRef == nil || *r.StagingRef == "" {
				return
			}
			dctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
			defer cancel()
			chat, err := s.Q.GetChatSession(dctx, store.GetChatSessionParams{ID: r.ChatID, WorkspaceID: r.WorkspaceID})
			if err != nil {
				return
			}
			project := runs.ProjectIDOrNil(chat.ProjectID)
			token, err := s.Secrets.Reveal(dctx, r.WorkspaceID, &project, "git:pat")
			if err != nil || token == "" {
				return
			}
			pushreq.Discard(dctx, &pushreq.GitHub{BaseURL: s.GitHubAPIURL, Token: token}, r)
		},
	}
}

// ListTicketChangeRequests is the ticket edits a persona proposed in this
// chat that wait for the person: the cards under the conversation.
func (s *Server) ListTicketChangeRequests(ctx context.Context, req api.ListTicketChangeRequestsRequestObject) (api.ListTicketChangeRequestsResponseObject, error) {
	u, _, ws := me(ctx)
	chat, err := s.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: req.Id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && chat.CreatedBy != u.ID) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.PendingTicketChangeRequests(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.TicketChangeRequest, 0, len(rows))
	for _, r := range rows {
		out = append(out, s.toTicketChangeRequest(ctx, r.TicketChangeRequest, r.TicketKey, r.TicketTitle))
	}
	return api.ListTicketChangeRequests200JSONResponse{Requests: out}, nil
}

// DecideTicketChangeRequest applies or declines a proposed ticket edit. The
// request's row stays locked while the edit applies, so a second click waits
// and then finds it decided. An edit the ticket no longer allows (it changed
// since, or a run started) is recorded as failed and answered with why; an
// internal error rolls back and leaves the request waiting.
func (s *Server) DecideTicketChangeRequest(ctx context.Context, req api.DecideTicketChangeRequestRequestObject) (api.DecideTicketChangeRequestResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	decision := req.Body.Decision
	if !decision.Valid() {
		return nil, apperr.Invalid("decision", "must be allow, always or deny")
	}
	var refused error
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		r, err := q.LockPendingTicketChangeRequest(ctx, store.LockPendingTicketChangeRequestParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("this change is no longer waiting")
		}
		if err != nil {
			return err
		}
		state, reason := "declined", (*string)(nil)
		if decision != api.TicketChangeDecisionDecisionDeny {
			state = "applied"
			if err := agentapi.ApplyTicketChange(ctx, s.agentDeps(), r); err != nil {
				if !refusal(err) {
					return err
				}
				refused, state = err, "failed"
				msg := err.Error()
				reason = &msg
			}
		}
		if _, err := q.FinishTicketChangeRequest(ctx, store.FinishTicketChangeRequestParams{ID: r.ID, State: state, Error: reason}); err != nil {
			return err
		}
		if decision == api.TicketChangeDecisionDecisionAlways && r.PersonaID != nil {
			_, err := q.SetPersonaTicketEdits(ctx, store.SetPersonaTicketEditsParams{ID: *r.PersonaID, WorkspaceID: ws, UserID: u.ID, TicketEdits: agentapi.TicketEditsAllow})
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if refused != nil {
		return nil, refused
	}
	row, err := s.Q.GetTicketChangeRequest(ctx, store.GetTicketChangeRequestParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	return api.DecideTicketChangeRequest200JSONResponse(s.toTicketChangeRequest(ctx, row.TicketChangeRequest, row.TicketKey, row.TicketTitle)), nil
}

// refusal reports an error that says why the edit can't apply, as opposed to
// one that went wrong on the way.
func refusal(err error) bool {
	var invalid *apperr.ValidationError
	var conflict *apperr.ConflictError
	return errors.As(err, &invalid) || errors.As(err, &conflict) || errors.Is(err, apperr.ErrNotFound)
}

func (s *Server) toTicketChangeRequest(ctx context.Context, r store.TicketChangeRequest, key, title string) api.TicketChangeRequest {
	out := api.TicketChangeRequest{Id: r.ID, TicketKey: key, TicketTitle: title, Tool: api.TicketChangeRequestTool(r.Tool),
		State: api.TicketChangeRequestState(r.State), Error: r.Error, CreatedAt: r.CreatedAt, Changes: []api.TicketChange{}}
	_ = json.Unmarshal(r.Changes, &out.Changes)
	if r.PersonaID != nil {
		if p, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: *r.PersonaID, WorkspaceID: r.WorkspaceID, UserID: r.UserID}); err == nil {
			out.Persona = toPersonaSummary(p)
		}
	}
	return out
}

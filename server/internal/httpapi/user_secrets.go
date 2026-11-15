package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/connectors"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

func (s *Server) userSecrets() *usersecrets.Service {
	var box *secrets.Box
	if s.Secrets != nil {
		box = s.Secrets.Box
	}
	return &usersecrets.Service{Q: s.Q, Box: box}
}

// toApiSecrets never includes a value or any part of one.
func (s *Server) toApiSecrets(ctx context.Context, rows []store.UserSecret) ([]api.ApiSecret, error) {
	ids := make([]uuid.UUID, len(rows))
	for i, r := range rows {
		ids[i] = r.ID
	}
	access, err := s.Q.ListUserSecretPersonas(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]api.ApiSecret, len(rows))
	for i, r := range rows {
		personas := []openapi_types.UUID{}
		for _, a := range access {
			if a.SecretID == r.ID {
				personas = append(personas, a.PersonaID)
			}
		}
		out[i] = api.ApiSecret{Id: r.ID, Name: r.Name, Handle: r.Handle, Kind: api.ApiSecretKind(r.Kind), Placement: api.ApiSecretPlacement(r.Placement), PlacementKey: r.PlacementKey, AllowedHosts: r.AllowedHosts,
			ReadPolicy: api.ApiSecretPolicy(r.ReadPolicy), WritePolicy: api.ApiSecretPolicy(r.WritePolicy), PersonaIds: personas, ExpiresAt: r.ExpiresAt, LastUsedAt: r.LastUsedAt,
			Revision: int(r.Revision), CreatedAt: r.CreatedAt, UpdatedAt: r.UpdatedAt}
		if r.Kind == usersecrets.KindOAuth {
			st := usersecrets.Settings(r)
			scopes := st.Scopes
			if scopes == nil {
				scopes = []string{}
			}
			out[i].Oauth = &api.ApiSecretOAuth{AuthorizeUrl: st.AuthorizeURL, TokenUrl: st.TokenURL, ClientId: st.ClientID, Scopes: scopes,
				HasClientSecret: st.HasClientSecret, SignedInAt: r.SignedInAt, Error: r.OauthError}
		}
	}
	return out, nil
}

func (s *Server) toApiSecret(ctx context.Context, r store.UserSecret) (api.ApiSecret, error) {
	rows, err := s.toApiSecrets(ctx, []store.UserSecret{r})
	if err != nil {
		return api.ApiSecret{}, err
	}
	return rows[0], nil
}

func (s *Server) ownApiSecret(ctx context.Context, id uuid.UUID) (store.UserSecret, error) {
	u, _, ws := me(ctx)
	r, err := s.Q.GetUserSecret(ctx, store.GetUserSecretParams{ID: id, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return r, apperr.ErrNotFound
	}
	return r, err
}

// setSecretPersonas replaces who may use a secret; every persona must be the person's own.
func setSecretPersonas(ctx context.Context, q *store.Queries, ws, user, secret uuid.UUID, ids []uuid.UUID) error {
	if err := q.ClearUserSecretPersonas(ctx, secret); err != nil {
		return err
	}
	for _, id := range ids {
		if _, err := q.GetPersona(ctx, store.GetPersonaParams{ID: id, WorkspaceID: ws, UserID: user}); errors.Is(err, pgx.ErrNoRows) {
			return apperr.Invalid("persona_ids", "unknown persona")
		} else if err != nil {
			return err
		}
		if err := q.AddUserSecretPersona(ctx, store.AddUserSecretPersonaParams{SecretID: secret, PersonaID: id}); err != nil {
			return err
		}
	}
	return nil
}

func (s *Server) ListApiSecrets(ctx context.Context, _ api.ListApiSecretsRequestObject) (api.ListApiSecretsResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListUserSecrets(ctx, store.ListUserSecretsParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out, err := s.toApiSecrets(ctx, rows)
	return api.ListApiSecrets200JSONResponse{Secrets: out, KeyConfigured: s.userSecrets().Box != nil, OauthRedirectUri: s.oauthRedirect()}, err
}

func (s *Server) CreateApiSecret(ctx context.Context, req api.CreateApiSecretRequestObject) (api.CreateApiSecretResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	in := usersecrets.Input{Name: b.Name, Value: deref(b.Value), Placement: string(b.Placement), PlacementKey: deref(b.PlacementKey), AllowedHosts: b.AllowedHosts, ProposalID: b.ProposalId}
	if o := b.Oauth; o != nil {
		in.OAuth = &usersecrets.OAuthInput{AuthorizeURL: o.AuthorizeUrl, TokenURL: o.TokenUrl, ClientID: o.ClientId, ClientSecret: deref(o.ClientSecret)}
		if o.Scopes != nil {
			in.OAuth.Scopes = *o.Scopes
		}
	}
	if b.ReadPolicy != nil {
		in.ReadPolicy = string(*b.ReadPolicy)
	}
	if b.WritePolicy != nil {
		in.WritePolicy = string(*b.WritePolicy)
	}
	var out store.UserSecret
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		svc := s.userSecrets()
		svc.Q = q
		var err error
		if out, err = svc.Create(ctx, ws, u.ID, in); err != nil {
			return err
		}
		if b.PersonaIds == nil {
			return nil
		}
		ids := *b.PersonaIds
		if b.ProposalId != nil {
			// Create granted the proposing persona; keep it alongside any chosen here.
			granted, err := q.ListUserSecretPersonas(ctx, []uuid.UUID{out.ID})
			if err != nil {
				return err
			}
			for _, g := range granted {
				if !slices.Contains(ids, g.PersonaID) {
					ids = append(ids, g.PersonaID)
				}
			}
		}
		return setSecretPersonas(ctx, q, ws, u.ID, out.ID, ids)
	})
	if err != nil {
		return nil, err
	}
	res, err := s.toApiSecret(ctx, out)
	return api.CreateApiSecret200JSONResponse(res), err
}

func (s *Server) UpdateApiSecret(ctx context.Context, req api.UpdateApiSecretRequestObject) (api.UpdateApiSecretResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	cur, err := s.ownApiSecret(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	if cur.Kind == usersecrets.KindOAuth {
		if b.Value != nil {
			return nil, apperr.Invalid("value", "an OAuth secret's token comes from signing in; sign in again instead")
		}
		if b.Placement != nil && string(*b.Placement) != usersecrets.PlacementBearer {
			return nil, apperr.Invalid("placement", "an OAuth secret is always sent as Authorization: Bearer")
		}
	}
	name, placement, key, hosts, read, write := cur.Name, cur.Placement, cur.PlacementKey, cur.AllowedHosts, cur.ReadPolicy, cur.WritePolicy
	if b.Name != nil {
		if name, err = usersecrets.ValidName(*b.Name); err != nil {
			return nil, err
		}
	}
	if b.Placement != nil || b.PlacementKey != nil {
		if b.Placement != nil {
			placement = string(*b.Placement)
		}
		if placement != cur.Placement && b.Value == nil {
			// The stored value was shaped for the old placement (Basic needs user:password).
			return nil, apperr.Invalid("value", "enter the value again when changing how it's sent")
		}
		if key, err = usersecrets.ValidPlacement(placement, deref(b.PlacementKey)); err != nil {
			return nil, err
		}
	}
	if b.AllowedHosts != nil {
		if hosts, err = usersecrets.ValidHosts(*b.AllowedHosts); err != nil {
			return nil, err
		}
	}
	if b.ReadPolicy != nil {
		read = string(*b.ReadPolicy)
	}
	if b.WritePolicy != nil {
		write = string(*b.WritePolicy)
	}
	if err := usersecrets.ValidPolicy("read_policy", read); err != nil {
		return nil, err
	}
	if err := usersecrets.ValidPolicy("write_policy", write); err != nil {
		return nil, err
	}
	var out store.UserSecret
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		var err error
		out, err = q.UpdateUserSecret(ctx, store.UpdateUserSecretParams{ID: cur.ID, WorkspaceID: ws, Revision: int32(b.Revision), Name: name, Placement: placement, PlacementKey: key,
			AllowedHosts: hosts, ReadPolicy: read, WritePolicy: write})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("the secret changed; reload and try again")
		} else if err != nil {
			return err
		}
		if b.Value != nil {
			svc := s.userSecrets()
			svc.Q = q
			if out, err = svc.SetValue(ctx, out, placement, *b.Value); err != nil {
				return err
			}
		}
		if b.PersonaIds == nil {
			return nil
		}
		return setSecretPersonas(ctx, q, ws, u.ID, cur.ID, *b.PersonaIds)
	})
	if err != nil {
		return nil, err
	}
	res, err := s.toApiSecret(ctx, out)
	return api.UpdateApiSecret200JSONResponse(res), err
}

// oauthRedirect is where sign-in providers return the browser, for OAuth
// secrets and connectors alike.
func (s *Server) oauthRedirect() string {
	return strings.TrimRight(s.PublicURL, "/") + connectors.CallbackPath
}

// SignInApiSecret starts an OAuth secret's sign-in. The provider returns the
// browser to the same callback connectors use, so one redirect URI registered
// on the person's OAuth client serves both.
func (s *Server) SignInApiSecret(ctx context.Context, req api.SignInApiSecretRequestObject) (api.SignInApiSecretResponseObject, error) {
	sec, err := s.ownApiSecret(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	link, err := s.userSecrets().BeginOAuth(ctx, sec, s.oauthRedirect())
	if err != nil {
		return nil, err
	}
	res, err := s.toApiSecret(ctx, sec)
	return api.SignInApiSecret200JSONResponse{Secret: res, AuthorizeUrl: link}, err
}

func (s *Server) DeleteApiSecret(ctx context.Context, req api.DeleteApiSecretRequestObject) (api.DeleteApiSecretResponseObject, error) {
	u, _, ws := me(ctx)
	n, err := s.Q.DeleteUserSecret(ctx, store.DeleteUserSecretParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, apperr.ErrNotFound
	}
	return api.DeleteApiSecret204Response{}, nil
}

func (s *Server) ListApiSecretCalls(ctx context.Context, req api.ListApiSecretCallsRequestObject) (api.ListApiSecretCallsResponseObject, error) {
	sec, err := s.ownApiSecret(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListUserSecretCalls(ctx, sec.ID)
	if err != nil {
		return nil, err
	}
	out := make([]api.ApiSecretCall, len(rows))
	for i, r := range rows {
		out[i] = api.ApiSecretCall{Id: r.ID, Method: r.Method, Host: r.Host, Path: r.Path, Decision: api.ApiSecretCallDecision(r.Decision), Error: r.Error,
			Redactions: int(r.Redactions), DurationMs: int(r.DurationMs), PersonaName: deref(r.PersonaName), ChatId: r.ChatID, CreatedAt: r.CreatedAt}
		if r.Status != nil {
			st := int(*r.Status)
			out[i].Status = &st
		}
	}
	return api.ListApiSecretCalls200JSONResponse{Calls: out}, nil
}

func (s *Server) ListChatApiSecrets(ctx context.Context, req api.ListChatApiSecretsRequestObject) (api.ListChatApiSecretsResponseObject, error) {
	u, _, ws := me(ctx)
	chat, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ChatSecretUsage(ctx, store.ChatSecretUsageParams{ChatID: &chat.ID, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out := make([]api.ChatApiSecret, len(rows))
	for i, r := range rows {
		out[i] = api.ChatApiSecret{Id: r.ID, Name: r.Name, Handle: r.Handle, Calls: int(r.Calls), Methods: r.Methods, LastUsedAt: r.LastUsedAt,
			Enabled: chat.SecretIds == nil || slices.Contains(chat.SecretIds, r.ID)}
	}
	return api.ListChatApiSecrets200JSONResponse{Secrets: out}, nil
}

// DisableChatApiSecret narrows the chat to the secrets it may use now, minus
// this one, so turning one off never turns another on.
func (s *Server) DisableChatApiSecret(ctx context.Context, req api.DisableChatApiSecretRequestObject) (api.DisableChatApiSecretResponseObject, error) {
	u, _, ws := me(ctx)
	chat, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	if _, err := s.ownApiSecret(ctx, req.SecretId); err != nil {
		return nil, err
	}
	allowed := chat.SecretIds
	if allowed == nil {
		allowed = []uuid.UUID{}
		if speaker := runs.ChatSpeakerID(chat); speaker != nil {
			rows, err := s.Q.UserSecretsForPersona(ctx, store.UserSecretsForPersonaParams{WorkspaceID: ws, UserID: u.ID, PersonaID: *speaker})
			if err != nil {
				return nil, err
			}
			for _, r := range rows {
				allowed = append(allowed, r.ID)
			}
		}
	}
	next := slices.DeleteFunc(slices.Clone(allowed), func(id uuid.UUID) bool { return id == req.SecretId })
	if _, err := s.Q.SetChatSecrets(ctx, store.SetChatSecretsParams{ID: chat.ID, SecretIds: next}); err != nil {
		return nil, err
	}
	return api.DisableChatApiSecret204Response{}, nil
}

func (s *Server) ListApiSecretApprovals(ctx context.Context, req api.ListApiSecretApprovalsRequestObject) (api.ListApiSecretApprovalsResponseObject, error) {
	u, _, ws := me(ctx)
	if _, err := s.ownChat(ctx, req.Id); err != nil {
		return nil, err
	}
	rows, err := s.Q.PendingUserSecretApprovals(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.ApiSecretApproval, 0, len(rows))
	for _, r := range rows {
		item := api.ApiSecretApproval{Id: r.ID, SecretId: r.SecretID, SecretName: r.SecretName, SecretHandle: r.SecretHandle, Placement: api.ApiSecretPlacement(r.SecretPlacement), PlacementKey: r.SecretPlacementKey,
			Method: r.Method, Url: r.Url, Headers: map[string]string{}, Body: r.Body, CreatedAt: r.CreatedAt}
		_ = json.Unmarshal(r.Headers, &item.Headers)
		if r.PersonaID != nil {
			if p, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: *r.PersonaID, WorkspaceID: ws, UserID: u.ID}); err == nil {
				item.Persona = toPersonaSummary(p)
			}
		}
		out = append(out, item)
	}
	return api.ListApiSecretApprovals200JSONResponse{Approvals: out}, nil
}

// DecideApiSecretApproval allows once, denies, or for a read, sets reads to
// Allow. Writes can only be set to Allow deliberately, in the secret's settings.
func (s *Server) DecideApiSecretApproval(ctx context.Context, req api.DecideApiSecretApprovalRequestObject) (api.DecideApiSecretApprovalResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	decision := string(req.Body.Decision)
	if decision == "always" {
		a, err := s.Q.GetUserSecretApproval(ctx, req.Id)
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && (a.WorkspaceID != ws || a.UserID != u.ID)) {
			return nil, apperr.ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		if a.Method != "GET" && a.Method != "HEAD" {
			return nil, apperr.Invalid("decision", "only reads can be always allowed from here; set writes to Allow in the secret's settings")
		}
	}
	state := "allowed"
	if decision == "deny" {
		state = "denied"
	}
	a, err := s.Q.DecideUserSecretApproval(ctx, store.DecideUserSecretApprovalParams{ID: req.Id, State: state, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Conflict("this request is no longer waiting")
	}
	if err != nil {
		return nil, err
	}
	if decision == "always" {
		if err := s.Q.SetUserSecretPolicy(ctx, store.SetUserSecretPolicyParams{ID: a.SecretID, Write: false, Policy: usersecrets.PolicyAllow}); err != nil {
			return nil, err
		}
	}
	return api.DecideApiSecretApproval204Response{}, nil
}

func (s *Server) ListApiSecretProposals(ctx context.Context, req api.ListApiSecretProposalsRequestObject) (api.ListApiSecretProposalsResponseObject, error) {
	u, _, ws := me(ctx)
	if _, err := s.ownChat(ctx, req.Id); err != nil {
		return nil, err
	}
	rows, err := s.Q.ListUserSecretProposals(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.ApiSecretProposal, 0, len(rows))
	for _, r := range rows {
		item := api.ApiSecretProposal{Id: r.ID, Name: r.Name, Host: r.Host, Placement: api.ApiSecretPlacement(r.Placement), PlacementKey: r.PlacementKey, Reason: r.Reason, CreatedAt: r.CreatedAt}
		if r.ProposedBy != nil {
			if p, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: *r.ProposedBy, WorkspaceID: ws, UserID: u.ID}); err == nil {
				item.ProposedBy = toPersonaSummary(p)
			}
		}
		out = append(out, item)
	}
	return api.ListApiSecretProposals200JSONResponse{Proposals: out}, nil
}

func (s *Server) DeclineApiSecretProposal(ctx context.Context, req api.DeclineApiSecretProposalRequestObject) (api.DeclineApiSecretProposalResponseObject, error) {
	u, _, ws := me(ctx)
	if _, err := s.Q.GetUserSecretProposal(ctx, store.GetUserSecretProposalParams{ID: req.Id, WorkspaceID: ws, CreatedBy: u.ID}); errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if _, err := s.Q.FinishUserSecretProposal(ctx, store.FinishUserSecretProposalParams{ID: req.Id, State: "declined"}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	return api.DeclineApiSecretProposal204Response{}, nil
}

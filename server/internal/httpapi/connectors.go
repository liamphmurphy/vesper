package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"html"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	openapi_types "github.com/oapi-codegen/runtime/types"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/connectors"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

func (s *Server) connectors() *connectors.Service {
	var box *secrets.Box
	if s.Secrets != nil {
		box = s.Secrets.Box
	}
	return &connectors.Service{Q: s.Q, Box: box, PublicURL: s.PublicURL}
}

func (s *Server) toConnectors(ctx context.Context, rows []store.Connector) ([]api.Connector, error) {
	ids := make([]uuid.UUID, len(rows))
	for i, c := range rows {
		ids[i] = c.ID
	}
	access, err := s.Q.ListConnectorPersonas(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make([]api.Connector, len(rows))
	for i, c := range rows {
		tools := []api.ConnectorTool{}
		for _, t := range connectors.Tools(c) {
			tools = append(tools, api.ConnectorTool{Name: t.Name, Description: t.Description, Write: t.Write, Policy: api.ConnectorToolPolicy(t.Policy)})
		}
		personas := []openapi_types.UUID{}
		for _, a := range access {
			if a.ConnectorID == c.ID {
				personas = append(personas, a.PersonaID)
			}
		}
		item := api.Connector{Id: c.ID, Name: c.Name, Slug: c.Slug, Url: c.Url, AuthKind: api.ConnectorAuthKind(c.AuthKind), Status: api.ConnectorStatus(c.Status), LastError: c.LastError,
			LastCheckedAt: c.LastCheckedAt, Tools: tools, PersonaIds: personas, Revision: int(c.Revision), CreatedAt: c.CreatedAt}
		clientID, hasSecret, scopes := connectors.OAuthConfig(c)
		if clientID != "" {
			item.OauthClientId = &clientID
		}
		if hasSecret {
			item.HasOauthClientSecret = &hasSecret
		}
		if len(scopes) > 0 {
			item.OauthScopes = &scopes
		}
		out[i] = item
	}
	return out, nil
}

func (s *Server) toConnector(ctx context.Context, c store.Connector) (api.Connector, error) {
	rows, err := s.toConnectors(ctx, []store.Connector{c})
	if err != nil {
		return api.Connector{}, err
	}
	return rows[0], nil
}

func (s *Server) ListConnectors(ctx context.Context, _ api.ListConnectorsRequestObject) (api.ListConnectorsResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListConnectors(ctx, store.ListConnectorsParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out, err := s.toConnectors(ctx, rows)
	if err != nil {
		return nil, err
	}
	rawPresets := connectors.Presets()
	presets := make([]api.ConnectorPreset, len(rawPresets))
	for i, p := range rawPresets {
		item := api.ConnectorPreset{
			Id:                  p.ID,
			Name:                p.Name,
			Url:                 p.URL,
			AuthKind:            api.ConnectorPresetAuthKind(p.AuthKind),
			Description:         p.Description,
			OauthClientRequired: p.OAuthClientRequired,
			DefaultScopes:       p.DefaultScopes,
		}
		if p.SetupHint != "" {
			hint := p.SetupHint
			item.SetupHint = &hint
		}
		presets[i] = item
	}
	return api.ListConnectors200JSONResponse{Connectors: out, Presets: presets}, nil
}

func (s *Server) CreateConnector(ctx context.Context, req api.CreateConnectorRequestObject) (api.CreateConnectorResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	c, link, err := s.connectors().Create(ctx, ws, u.ID, connectors.CreateInput{
		Name:         b.Name,
		URL:          b.Url,
		Auth:         string(b.AuthKind),
		Token:        deref(b.Token),
		ProposalID:   b.ProposalId,
		ClientID:     deref(b.OauthClientId),
		ClientSecret: deref(b.OauthClientSecret),
		Scopes:       deref(b.OauthScopes),
	})
	if err != nil {
		return nil, err
	}
	out, err := s.toConnector(ctx, c)
	res := api.CreateConnector200JSONResponse{Connector: out}
	if link != "" {
		res.AuthorizeUrl = &link
	}
	return res, err
}

func (s *Server) ProbeConnector(ctx context.Context, req api.ProbeConnectorRequestObject) (api.ProbeConnectorResponseObject, error) {
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	p, err := s.connectors().Probe(ctx, req.Body.Url, deref(req.Body.Token))
	if err != nil {
		return nil, err
	}
	res := api.ProbeConnector200JSONResponse{Reachable: p.Reachable, NeedsAuth: p.NeedsAuth, Tools: p.Tools}
	if p.Error != "" {
		res.Error = &p.Error
	}
	return res, nil
}

func (s *Server) ownConnector(ctx context.Context, id uuid.UUID) (store.Connector, error) {
	u, _, ws := me(ctx)
	c, err := s.Q.GetConnector(ctx, store.GetConnectorParams{ID: id, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return c, apperr.ErrNotFound
	}
	return c, err
}

func (s *Server) UpdateConnector(ctx context.Context, req api.UpdateConnectorRequestObject) (api.UpdateConnectorResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	c, err := s.ownConnector(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	name := c.Name
	if b.Name != nil {
		if name = *b.Name; name == "" {
			return nil, apperr.Invalid("name", "required")
		}
	}
	tools := connectors.Tools(c)
	if b.Policies != nil {
		for i := range tools {
			if p, ok := (*b.Policies)[tools[i].Name]; ok {
				tools[i].Policy = string(p)
			}
		}
	}
	raw, err := json.Marshal(tools)
	if err != nil {
		return nil, err
	}
	var updated store.Connector
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		var err error
		if updated, err = q.UpdateConnector(ctx, store.UpdateConnectorParams{ID: c.ID, WorkspaceID: ws, Revision: int32(b.Revision), Name: name, Tools: raw}); errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("the connector changed; reload and try again")
		} else if err != nil {
			return err
		}
		if b.PersonaIds == nil {
			return nil
		}
		if err := q.ClearConnectorPersonas(ctx, c.ID); err != nil {
			return err
		}
		for _, id := range *b.PersonaIds {
			if _, err := q.GetPersona(ctx, store.GetPersonaParams{ID: id, WorkspaceID: ws, UserID: u.ID}); errors.Is(err, pgx.ErrNoRows) {
				return apperr.Invalid("persona_ids", "unknown persona")
			} else if err != nil {
				return err
			}
			if err := q.AddConnectorPersona(ctx, store.AddConnectorPersonaParams{ConnectorID: c.ID, PersonaID: id}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	if b.Token != nil {
		if updated, err = s.connectors().SetToken(ctx, updated, *b.Token); err != nil {
			return nil, err
		}
	}
	if b.OauthClientId != nil || b.OauthClientSecret != nil || b.OauthScopes != nil {
		if updated, err = s.connectors().SetOAuthConfig(ctx, updated, b.OauthClientId, b.OauthClientSecret, b.OauthScopes); err != nil {
			return nil, err
		}
	}
	out, err := s.toConnector(ctx, updated)
	return api.UpdateConnector200JSONResponse(out), err
}

func (s *Server) DeleteConnector(ctx context.Context, req api.DeleteConnectorRequestObject) (api.DeleteConnectorResponseObject, error) {
	u, _, ws := me(ctx)
	n, err := s.Q.DeleteConnector(ctx, store.DeleteConnectorParams{ID: req.Id, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, apperr.ErrNotFound
	}
	return api.DeleteConnector204Response{}, nil
}

func (s *Server) TestConnector(ctx context.Context, req api.TestConnectorRequestObject) (api.TestConnectorResponseObject, error) {
	c, err := s.ownConnector(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	if c, err = s.connectors().Refresh(ctx, c); err != nil {
		return nil, err
	}
	out, err := s.toConnector(ctx, c)
	return api.TestConnector200JSONResponse(out), err
}

func (s *Server) AuthorizeConnector(ctx context.Context, req api.AuthorizeConnectorRequestObject) (api.AuthorizeConnectorResponseObject, error) {
	c, err := s.ownConnector(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	link, err := s.connectors().BeginOAuth(ctx, c)
	if err != nil {
		return nil, apperr.Conflict("%s", err.Error())
	}
	out, err := s.toConnector(ctx, c)
	return api.AuthorizeConnector200JSONResponse{Connector: out, AuthorizeUrl: &link}, err
}

// connectorCallback is where a sign-in provider returns the browser, for a
// connector or an OAuth API secret: the one-time state says which. The page
// opened in its own window, so it closes itself; the settings page polls for the result.
func (s *Server) connectorCallback(w http.ResponseWriter, r *http.Request) {
	msg := "Connected. You can close this window."
	script := "<script>window.close()</script>"
	code, state := r.URL.Query().Get("code"), r.URL.Query().Get("state")
	if code == "" || state == "" {
		msg, script = "Sign-in was cancelled.", ""
	} else if _, err := s.userSecrets().FinishOAuth(r.Context(), state, code); err == nil {
		msg = "Signed in. You can close this window."
	} else if !errors.Is(err, usersecrets.ErrUnknownState) {
		msg, script = "Sign-in didn't finish: "+err.Error(), ""
	} else if _, err := s.connectors().FinishOAuth(r.Context(), state, code); err != nil {
		msg, script = "Sign-in didn't finish: "+err.Error(), ""
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write([]byte("<!doctype html><title>Vesper</title><body style=\"font-family:system-ui;padding:2rem\">" + html.EscapeString(msg) + script))
}

func (s *Server) ListConnectorApprovals(ctx context.Context, req api.ListConnectorApprovalsRequestObject) (api.ListConnectorApprovalsResponseObject, error) {
	u, _, ws := me(ctx)
	chat, err := s.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: req.Id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && chat.CreatedBy != u.ID) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.PendingConnectorApprovals(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.ConnectorApproval, 0, len(rows))
	for _, r := range rows {
		item := api.ConnectorApproval{Id: r.ID, ConnectorId: r.ConnectorID, ConnectorName: r.ConnectorName, Tool: r.Tool, CreatedAt: r.CreatedAt, Arguments: map[string]any{}}
		_ = json.Unmarshal(r.Arguments, &item.Arguments)
		if r.PersonaID != nil {
			if p, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: *r.PersonaID, WorkspaceID: ws, UserID: u.ID}); err == nil {
				item.Persona = toPersonaSummary(p)
			}
		}
		out = append(out, item)
	}
	return api.ListConnectorApprovals200JSONResponse{Approvals: out}, nil
}

func (s *Server) DecideConnectorApproval(ctx context.Context, req api.DecideConnectorApprovalRequestObject) (api.DecideConnectorApprovalResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	state := "allowed"
	if string(req.Body.Decision) == "deny" {
		state = "denied"
	}
	a, err := s.Q.DecideConnectorApproval(ctx, store.DecideConnectorApprovalParams{ID: req.Id, State: state, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Conflict("this request is no longer waiting")
	}
	if err != nil {
		return nil, err
	}
	if string(req.Body.Decision) == "always" {
		c, err := s.Q.GetConnector(ctx, store.GetConnectorParams{ID: a.ConnectorID, WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		tools := connectors.Tools(c)
		for i := range tools {
			if tools[i].Name == a.Tool {
				tools[i].Policy = connectors.PolicyAllow
			}
		}
		raw, err := json.Marshal(tools)
		if err != nil {
			return nil, err
		}
		if _, err := s.Q.UpdateConnector(ctx, store.UpdateConnectorParams{ID: c.ID, WorkspaceID: ws, Revision: c.Revision, Name: c.Name, Tools: raw}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
	}
	return api.DecideConnectorApproval204Response{}, nil
}

func (s *Server) ListConnectorProposals(ctx context.Context, req api.ListConnectorProposalsRequestObject) (api.ListConnectorProposalsResponseObject, error) {
	u, _, ws := me(ctx)
	chat, err := s.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: req.Id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && chat.CreatedBy != u.ID) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListConnectorProposals(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := make([]api.ConnectorProposal, 0, len(rows))
	for _, r := range rows {
		item := api.ConnectorProposal{Id: r.ID, Name: r.Name, Url: r.Url, AuthKind: api.ConnectorProposalAuthKind(r.AuthKind), Reason: r.Reason, CreatedAt: r.CreatedAt}
		if r.ProposedBy != nil {
			if p, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: *r.ProposedBy, WorkspaceID: ws, UserID: u.ID}); err == nil {
				item.ProposedBy = toPersonaSummary(p)
			}
		}
		out = append(out, item)
	}
	return api.ListConnectorProposals200JSONResponse{Proposals: out}, nil
}

func (s *Server) DeclineConnectorProposal(ctx context.Context, req api.DeclineConnectorProposalRequestObject) (api.DeclineConnectorProposalResponseObject, error) {
	u, _, ws := me(ctx)
	if _, err := s.Q.GetConnectorProposal(ctx, store.GetConnectorProposalParams{ID: req.Id, WorkspaceID: ws, CreatedBy: u.ID}); errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if _, err := s.Q.FinishConnectorProposal(ctx, store.FinishConnectorProposalParams{ID: req.Id, State: "declined"}); err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	return api.DeclineConnectorProposal204Response{}, nil
}

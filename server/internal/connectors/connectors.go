// Package connectors keeps the MCP servers a person has added: their sign-in,
// their tools and who may use them. Runs never see a server's URL or token;
// they reach it through Vesper (see agentapi.ConnectorHandler).
package connectors

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	AuthOAuth = "oauth"
	AuthToken = "token"
	AuthNone  = "none"

	PolicyAllow = "allow"
	PolicyAsk   = "ask"
	PolicyOff   = "off"

	StatusConnected  = "connected"
	StatusNeedsLogin = "needs_sign_in"
	StatusOffline    = "offline"

	probeTimeout = 20 * time.Second
	callTimeout  = 5 * time.Minute
)

// Tool is one entry of connectors.tools.
type Tool struct {
	Name        string          `json:"name"`
	Description string          `json:"description"`
	InputSchema json.RawMessage `json:"input_schema,omitempty"`
	Write       bool            `json:"write"`
	Policy      string          `json:"policy"`
}

// Tools decodes a connector's stored tool list.
func Tools(c store.Connector) []Tool {
	out := []Tool{}
	_ = json.Unmarshal(c.Tools, &out)
	return out
}

type credential struct {
	AccessToken  string    `json:"access_token"`
	RefreshToken string    `json:"refresh_token,omitempty"`
	ExpiresAt    time.Time `json:"expires_at,omitzero"`
	ClientSecret string    `json:"client_secret,omitempty"`
}

// Service works on connectors. HTTP is overridable for tests.
type Service struct {
	Q         *store.Queries
	Box       *secrets.Box
	PublicURL string
	HTTP      http.RoundTripper
}

func (s *Service) base() http.RoundTripper {
	if s.HTTP != nil {
		return s.HTTP
	}
	return http.DefaultTransport
}

// ValidateURL accepts https anywhere and plain http only on this machine, so a
// bearer token never crosses a network unencrypted.
func ValidateURL(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || len(raw) > 2000 {
		return "", apperr.Invalid("url", "enter a full server URL")
	}
	if u.User != nil {
		return "", apperr.Invalid("url", "put credentials in Sign-in, not the URL")
	}
	host := u.Hostname()
	ip := net.ParseIP(host)
	local := host == "localhost" || host == "host.docker.internal" || (ip != nil && ip.IsLoopback())
	if u.Scheme != "https" && !(u.Scheme == "http" && local) {
		return "", apperr.Invalid("url", "use https (http only works for localhost)")
	}
	return raw, nil
}

var nonSlug = regexp.MustCompile(`[^a-z0-9]+`)

// Slug is the name harnesses show tools under: mcp__<slug>__<tool>.
func Slug(name string) (string, error) {
	s := strings.Trim(nonSlug.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if s == "" {
		return "", apperr.Invalid("name", "use at least one letter or digit")
	}
	if s[0] >= '0' && s[0] <= '9' {
		s = "c-" + s
	}
	if len(s) > 40 {
		s = strings.TrimRight(s[:40], "-")
	}
	if s == agentdef.ReservedMCPName {
		return "", apperr.Invalid("name", "that name is reserved")
	}
	return s, nil
}

// recorder sets the bearer token and remembers the last HTTP status, so a
// rejected sign-in can be told from a server that's down.
type recorder struct {
	base   http.RoundTripper
	token  string
	status atomic.Int32
}

func (r *recorder) RoundTrip(req *http.Request) (*http.Response, error) {
	if r.token != "" {
		req = req.Clone(req.Context())
		req.Header.Set("Authorization", "Bearer "+r.token)
	}
	res, err := r.base.RoundTrip(req)
	if err == nil {
		r.status.Store(int32(res.StatusCode))
	}
	return res, err
}

func (s *Service) open(ctx context.Context, server, token string) (*mcp.ClientSession, *recorder, error) {
	rec := &recorder{base: s.base(), token: token}
	client := mcp.NewClient(&mcp.Implementation{Name: "vesper", Version: "1"}, nil)
	sess, err := client.Connect(ctx, &mcp.StreamableClientTransport{
		Endpoint:             server,
		DisableStandaloneSSE: true,
		MaxRetries:           -1,
		// A redirect must not carry the token somewhere the person didn't choose.
		HTTPClient: &http.Client{Transport: rec, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }},
	}, nil)
	return sess, rec, err
}

func authRejected(rec *recorder) bool {
	if rec == nil {
		return false
	}
	st := rec.status.Load()
	return st == http.StatusUnauthorized || st == http.StatusForbidden
}

func list(ctx context.Context, sess *mcp.ClientSession) ([]Tool, error) {
	out := []Tool{}
	for t, err := range sess.Tools(ctx, nil) {
		if err != nil {
			return nil, err
		}
		schema, _ := json.Marshal(t.InputSchema)
		write := t.Annotations == nil || !t.Annotations.ReadOnlyHint
		policy := PolicyAllow
		if write {
			policy = PolicyAsk
		}
		out = append(out, Tool{Name: t.Name, Description: t.Description, InputSchema: schema, Write: write, Policy: policy})
	}
	return out, nil
}

// Probe is what an MCP server answered before anything was saved.
type Probe struct {
	Reachable, NeedsAuth bool
	Tools                int
	Error                string
}

func (s *Service) Probe(ctx context.Context, raw, token string) (Probe, error) {
	server, err := ValidateURL(raw)
	if err != nil {
		return Probe{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	sess, rec, err := s.open(ctx, server, token)
	if err != nil {
		if authRejected(rec) {
			return Probe{Reachable: true, NeedsAuth: true}, nil
		}
		return Probe{Error: "Couldn't reach an MCP server at that URL."}, nil
	}
	defer sess.Close()
	tools, err := list(ctx, sess)
	if err != nil {
		return Probe{Reachable: true, NeedsAuth: authRejected(rec), Error: "The server didn't list its tools."}, nil
	}
	return Probe{Reachable: true, Tools: len(tools)}, nil
}

func (s *Service) seal(ctx context.Context, c store.Connector, cred credential) error {
	if s.Box == nil {
		return apperr.Conflict("set SECRETS_KEY on the server to store connector sign-ins")
	}
	raw, err := json.Marshal(cred)
	if err != nil {
		return err
	}
	nonce, ct, err := s.Box.Seal(c.WorkspaceID, "connector:"+c.ID.String(), raw)
	if err != nil {
		return err
	}
	return s.Q.SetConnectorCredential(ctx, store.SetConnectorCredentialParams{ID: c.ID, CredNonce: nonce, CredCiphertext: ct})
}

func (s *Service) unseal(c store.Connector) (credential, error) {
	var cred credential
	if c.CredCiphertext == nil {
		return cred, nil
	}
	if s.Box == nil {
		return cred, apperr.Conflict("set SECRETS_KEY on the server to use connector sign-ins")
	}
	raw, err := s.Box.Open(c.WorkspaceID, "connector:"+c.ID.String(), c.CredNonce, c.CredCiphertext)
	if err != nil {
		return cred, err
	}
	return cred, json.Unmarshal(raw, &cred)
}

// CreateInput adds a connector; Token is only for token sign-in.
type CreateInput struct {
	Name, URL, Auth, Token string
	ProposalID             *uuid.UUID
	ClientID, ClientSecret string
	Scopes                 []string
}

// Create stores a connector and, unless it waits for OAuth, checks it. The
// returned URL, when set, is where the person signs in. A proposal's persona
// is the only one given access: the person just approved exactly that.
func (s *Service) Create(ctx context.Context, ws, user uuid.UUID, in CreateInput) (store.Connector, string, error) {
	var out store.Connector
	name := strings.TrimSpace(in.Name)
	if name == "" || len([]rune(name)) > 60 {
		return out, "", apperr.Invalid("name", "must be 1–60 characters")
	}
	server, err := ValidateURL(in.URL)
	if err != nil {
		return out, "", err
	}
	if !slices.Contains([]string{AuthOAuth, AuthToken, AuthNone}, in.Auth) {
		return out, "", apperr.Invalid("auth_kind", "must be oauth, token or none")
	}
	if in.Auth == AuthToken && strings.TrimSpace(in.Token) == "" {
		return out, "", apperr.Invalid("token", "enter the API token")
	}
	if in.Auth != AuthNone && s.Box == nil {
		return out, "", apperr.Conflict("set SECRETS_KEY on the server to store connector sign-ins")
	}
	var clientID, clientSecret string
	var scopes []string
	if in.Auth == AuthOAuth {
		clientID = strings.TrimSpace(in.ClientID)
		clientSecret = strings.TrimSpace(in.ClientSecret)
		if clientID == "" && clientSecret != "" {
			return out, "", apperr.Invalid("oauth_client_id", "enter the OAuth client ID")
		}
		scopes = NormalizeScopes(in.Scopes)
		if len(scopes) == 0 {
			if p, ok := PresetForURL(server); ok && len(p.DefaultScopes) > 0 {
				scopes = slices.Clone(p.DefaultScopes)
			}
		}
	}
	slug, err := Slug(name)
	if err != nil {
		return out, "", err
	}
	if _, err := s.Q.GetConnectorBySlug(ctx, store.GetConnectorBySlugParams{Slug: slug, WorkspaceID: ws, UserID: user}); err == nil {
		return out, "", apperr.Invalid("name", "you already have a connector with this name")
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return out, "", err
	}
	var proposal *store.ConnectorProposal
	if in.ProposalID != nil {
		p, err := s.Q.GetConnectorProposal(ctx, store.GetConnectorProposalParams{ID: *in.ProposalID, WorkspaceID: ws, CreatedBy: user})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && p.State != "pending") {
			return out, "", apperr.Invalid("proposal_id", "that proposal is no longer open")
		}
		if err != nil {
			return out, "", err
		}
		proposal = &p
	}
	out, err = s.Q.CreateConnector(ctx, store.CreateConnectorParams{WorkspaceID: ws, UserID: user, Name: name, Slug: slug, Url: server, AuthKind: in.Auth})
	if err != nil {
		return out, "", err
	}
	if proposal != nil {
		if _, err := s.Q.FinishConnectorProposal(ctx, store.FinishConnectorProposalParams{ID: proposal.ID, State: "approved", ConnectorID: &out.ID}); err != nil {
			return out, "", err
		}
		if proposal.ProposedBy != nil {
			if err := s.Q.AddConnectorPersona(ctx, store.AddConnectorPersonaParams{ConnectorID: out.ID, PersonaID: *proposal.ProposedBy}); err != nil {
				return out, "", err
			}
		}
	}
	switch in.Auth {
	case AuthOAuth:
		if clientID != "" || len(scopes) > 0 || clientSecret != "" {
			stored, err := json.Marshal(oauthState{
				ClientID:        clientID,
				Scopes:          scopes,
				CustomClient:    clientID != "",
				HasClientSecret: clientSecret != "",
			})
			if err != nil {
				return out, "", err
			}
			if err := s.Q.SetConnectorOAuth(ctx, store.SetConnectorOAuthParams{ID: out.ID, Oauth: stored}); err != nil {
				return out, "", err
			}
			if clientSecret != "" {
				if err := s.seal(ctx, out, credential{ClientSecret: clientSecret}); err != nil {
					return out, "", err
				}
			}
			if out, err = s.Q.GetConnector(ctx, store.GetConnectorParams{ID: out.ID, WorkspaceID: ws, UserID: user}); err != nil {
				return out, "", err
			}
		}
		link, err := s.BeginOAuth(ctx, out)
		if err != nil {
			out, _ = s.setHealth(ctx, out, StatusNeedsLogin, err.Error(), Tools(out))
			return out, "", nil
		}
		return out, link, nil
	case AuthToken:
		if err := s.seal(ctx, out, credential{AccessToken: strings.TrimSpace(in.Token)}); err != nil {
			return out, "", err
		}
		if out, err = s.Q.GetConnector(ctx, store.GetConnectorParams{ID: out.ID, WorkspaceID: ws, UserID: user}); err != nil {
			return out, "", err
		}
	}
	out, err = s.Refresh(ctx, out)
	return out, "", err
}

// SetOAuthConfig updates a connector's pre-registered OAuth client and requested scopes.
func (s *Service) SetOAuthConfig(ctx context.Context, c store.Connector, clientID, clientSecret *string, scopes *[]string) (store.Connector, error) {
	if c.AuthKind != AuthOAuth {
		return c, apperr.Conflict("this connector doesn't use OAuth")
	}
	var st oauthState
	if len(c.Oauth) > 0 {
		_ = json.Unmarshal(c.Oauth, &st)
	}
	cred, err := s.unseal(c)
	if err != nil {
		return c, err
	}
	prevSecret := cred.ClientSecret
	if clientID != nil {
		id := strings.TrimSpace(*clientID)
		st.ClientID = id
		st.CustomClient = id != ""
		if id == "" {
			cred.ClientSecret = ""
			st.HasClientSecret = false
		}
	}
	if clientSecret != nil {
		sec := strings.TrimSpace(*clientSecret)
		cred.ClientSecret = sec
		st.HasClientSecret = sec != ""
	}
	if (st.CustomClient && st.ClientID == "") || (!st.CustomClient && st.HasClientSecret) {
		return c, apperr.Invalid("oauth_client_id", "enter the OAuth client ID")
	}
	if scopes != nil {
		st.Scopes = NormalizeScopes(*scopes)
	}
	needSeal := (clientSecret != nil && (strings.TrimSpace(*clientSecret) != "" || prevSecret != "")) ||
		(clientID != nil && strings.TrimSpace(*clientID) == "" && prevSecret != "")
	if needSeal {
		if err := s.seal(ctx, c, cred); err != nil {
			return c, err
		}
	}
	raw, err := json.Marshal(st)
	if err != nil {
		return c, err
	}
	if err := s.Q.SetConnectorOAuth(ctx, store.SetConnectorOAuthParams{ID: c.ID, Oauth: raw, OauthState: c.OauthState}); err != nil {
		return c, err
	}
	return s.Q.GetConnector(ctx, store.GetConnectorParams{ID: c.ID, WorkspaceID: c.WorkspaceID, UserID: c.UserID})
}

// SetToken replaces an API token and rechecks the connector.
func (s *Service) SetToken(ctx context.Context, c store.Connector, token string) (store.Connector, error) {
	if c.AuthKind != AuthToken {
		return c, apperr.Conflict("this connector doesn't use an API token")
	}
	token = strings.TrimSpace(token)
	if token == "" {
		return c, apperr.Invalid("token", "enter the API token")
	}
	if err := s.seal(ctx, c, credential{AccessToken: token}); err != nil {
		return c, err
	}
	c, err := s.Q.GetConnector(ctx, store.GetConnectorParams{ID: c.ID, WorkspaceID: c.WorkspaceID, UserID: c.UserID})
	if err != nil {
		return c, err
	}
	return s.Refresh(ctx, c)
}

func (s *Service) setHealth(ctx context.Context, c store.Connector, status, msg string, tools []Tool) (store.Connector, error) {
	raw, err := json.Marshal(tools)
	if err != nil {
		return c, err
	}
	return s.Q.SetConnectorHealth(ctx, store.SetConnectorHealthParams{ID: c.ID, Status: status, LastError: msg, Tools: raw})
}

// Refresh reconnects, updates the tool list and records the connector's
// health. New tools start on their safe default; existing ones keep the
// person's setting. Being unreachable is a status here, not an error.
func (s *Service) Refresh(ctx context.Context, c store.Connector) (store.Connector, error) {
	known := Tools(c)
	token, err := s.token(ctx, &c)
	if err != nil {
		return s.setHealth(ctx, c, StatusNeedsLogin, "Sign in again to keep using this connector.", known)
	}
	ctx, cancel := context.WithTimeout(ctx, probeTimeout)
	defer cancel()
	sess, rec, err := s.open(ctx, c.Url, token)
	if err == nil {
		defer sess.Close()
		var tools []Tool
		if tools, err = list(ctx, sess); err == nil {
			for i := range tools {
				if j := slices.IndexFunc(known, func(k Tool) bool { return k.Name == tools[i].Name }); j >= 0 {
					tools[i].Policy = known[j].Policy
				}
			}
			return s.setHealth(context.WithoutCancel(ctx), c, StatusConnected, "", tools)
		}
	}
	if authRejected(rec) {
		return s.setHealth(context.WithoutCancel(ctx), c, StatusNeedsLogin, "The server rejected the sign-in.", known)
	}
	return s.setHealth(context.WithoutCancel(ctx), c, StatusOffline, "Couldn't reach the server.", known)
}

// token returns a bearer token, refreshing an expiring OAuth one. It may
// update *c. "" means the connector sends none.
func (s *Service) token(ctx context.Context, c *store.Connector) (string, error) {
	if c.AuthKind == AuthNone {
		return "", nil
	}
	cred, err := s.unseal(*c)
	if err != nil {
		return "", err
	}
	if cred.AccessToken == "" {
		return "", errors.New("not signed in")
	}
	if c.AuthKind == AuthOAuth && !cred.ExpiresAt.IsZero() && time.Until(cred.ExpiresAt) < time.Minute {
		if cred, err = s.refreshOAuth(ctx, *c, cred); err != nil {
			return "", err
		}
	}
	return cred.AccessToken, nil
}

// Call forwards one tool call with the person's credentials. A rejected
// sign-in also flips the connector's status, so the page shows why.
func (s *Service) Call(ctx context.Context, c store.Connector, tool string, args json.RawMessage) (*mcp.CallToolResult, error) {
	token, err := s.token(ctx, &c)
	if err != nil {
		_, _ = s.setHealth(context.WithoutCancel(ctx), c, StatusNeedsLogin, "Sign in again to keep using this connector.", Tools(c))
		return nil, fmt.Errorf("%s needs you to sign in again", c.Name)
	}
	// A fresh context: the incoming MCP request's values (its negotiated
	// protocol version) must not leak into this separate client connection.
	parent := ctx
	ctx, cancel := context.WithTimeout(context.Background(), callTimeout)
	defer cancel()
	defer context.AfterFunc(parent, cancel)()
	sess, rec, err := s.open(ctx, c.Url, token)
	if err != nil {
		if authRejected(rec) {
			_, _ = s.setHealth(context.WithoutCancel(ctx), c, StatusNeedsLogin, "The server rejected the sign-in.", Tools(c))
			return nil, fmt.Errorf("%s needs you to sign in again", c.Name)
		}
		_, _ = s.setHealth(context.WithoutCancel(ctx), c, StatusOffline, "Couldn't reach the server.", Tools(c))
		return nil, fmt.Errorf("couldn't reach %s", c.Name)
	}
	defer sess.Close()
	if usesParamHeaders(c, tool) {
		// The SDK sends the Mcp-Param-<name> headers a server checks only for
		// tools this session has listed; a fresh session has listed none.
		for t, err := range sess.Tools(ctx, nil) {
			if err != nil || t.Name == tool {
				break
			}
		}
	}
	return sess.CallTool(ctx, &mcp.CallToolParams{Name: tool, Arguments: args})
}

// usesParamHeaders reports whether the stored schema of tool marks any
// parameter with x-mcp-header (SEP-2243), so a call must send it as a header.
func usesParamHeaders(c store.Connector, tool string) bool {
	for _, t := range Tools(c) {
		if t.Name == tool {
			return bytes.Contains(t.InputSchema, []byte(`"x-mcp-header"`))
		}
	}
	return false
}

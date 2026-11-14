package connectors

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// oauthState is connectors.oauth: public registration details, plus the PKCE
// verifier for the few minutes a sign-in is in progress.
type oauthState struct {
	TokenEndpoint   string   `json:"token_endpoint,omitempty"`
	ClientID        string   `json:"client_id,omitempty"`
	ClientSecret    string   `json:"client_secret,omitempty"`
	Scopes          []string `json:"scopes,omitempty"`
	CustomClient    bool     `json:"custom_client,omitempty"`
	HasClientSecret bool     `json:"has_client_secret,omitempty"`
	Verifier        string   `json:"verifier,omitempty"`
	Redirect        string   `json:"redirect,omitempty"`
}

// OAuthConfig returns any pre-registered OAuth client ID, whether a client secret
// is stored encrypted, and the configured OAuth scopes for a connector.
func OAuthConfig(c store.Connector) (clientID string, hasSecret bool, scopes []string) {
	var st oauthState
	if len(c.Oauth) > 0 {
		_ = json.Unmarshal(c.Oauth, &st)
	}
	if st.CustomClient {
		return st.ClientID, st.HasClientSecret, st.Scopes
	}
	return "", false, st.Scopes
}

type authServer struct {
	Issuer                string   `json:"issuer"`
	AuthorizationEndpoint string   `json:"authorization_endpoint"`
	TokenEndpoint         string   `json:"token_endpoint"`
	RegistrationEndpoint  string   `json:"registration_endpoint"`
	ScopesSupported       []string `json:"-"`
}

func (s *Service) client() *http.Client {
	return &http.Client{Transport: s.base(), Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

func (s *Service) getJSON(ctx context.Context, link string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, link, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/json")
	res, err := s.client().Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("status %d", res.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(v)
}

// wellKnown tries the path-aware location first, as the MCP spec orders them.
func wellKnown(base *url.URL, suffix string) []string {
	origin := base.Scheme + "://" + base.Host
	path := strings.TrimRight(base.Path, "/")
	if path == "" {
		return []string{origin + "/.well-known/" + suffix}
	}
	return []string{origin + "/.well-known/" + suffix + path, origin + "/.well-known/" + suffix}
}

// discover finds the authorization server: the server's protected-resource
// metadata names it; older servers host the metadata themselves.
func (s *Service) discover(ctx context.Context, server string) (authServer, error) {
	var as authServer
	u, err := url.Parse(server)
	if err != nil {
		return as, err
	}
	issuer := u.Scheme + "://" + u.Host
	var protectedScopes []string
	for _, link := range wellKnown(u, "oauth-protected-resource") {
		var meta struct {
			AuthorizationServers []string `json:"authorization_servers"`
			ScopesSupported      []string `json:"scopes_supported"`
		}
		if s.getJSON(ctx, link, &meta) == nil && len(meta.AuthorizationServers) > 0 {
			issuer = meta.AuthorizationServers[0]
			protectedScopes = NormalizeScopes(meta.ScopesSupported)
			break
		}
	}
	iu, err := url.Parse(issuer)
	if err != nil || iu.Host == "" {
		return as, errors.New("the server named an invalid sign-in provider")
	}
	for _, link := range append(wellKnown(iu, "oauth-authorization-server"), wellKnown(iu, "openid-configuration")...) {
		var candidate authServer
		if s.getJSON(ctx, link, &candidate) == nil && candidate.AuthorizationEndpoint != "" && candidate.TokenEndpoint != "" {
			for _, e := range []string{candidate.AuthorizationEndpoint, candidate.TokenEndpoint} {
				if _, err := ValidateURL(e); err != nil {
					return as, errors.New("the sign-in provider uses an insecure address")
				}
			}
			candidate.ScopesSupported = protectedScopes
			return candidate, nil
		}
	}
	return as, errors.New("this server doesn't advertise OAuth sign-in; use an API token instead")
}

func randomString() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// CallbackPath is where sign-in providers send the browser back.
const CallbackPath = "/api/v1/connector-oauth/callback"

// BeginOAuth starts an OAuth sign-in with PKCE, using a pre-registered client
// when present or dynamic registration (RFC 7591) otherwise, and returns the URL
// where the person signs in.
func (s *Service) BeginOAuth(ctx context.Context, c store.Connector) (string, error) {
	if c.AuthKind != AuthOAuth {
		return "", apperr.Conflict("this connector doesn't use OAuth")
	}
	var prev oauthState
	if len(c.Oauth) > 0 {
		_ = json.Unmarshal(c.Oauth, &prev)
	}
	as, err := s.discover(ctx, c.Url)
	if err != nil {
		return "", err
	}
	redirect := strings.TrimRight(s.PublicURL, "/") + CallbackPath
	var clientID, dcrSecret string
	customClient := prev.CustomClient && prev.ClientID != ""
	if customClient {
		clientID = prev.ClientID
	} else {
		if as.RegistrationEndpoint == "" {
			return "", errors.New("this server's sign-in needs an OAuth client ID; enter one in Sign-in or use an API token")
		}
		raw, _ := json.Marshal(map[string]any{"client_name": "Vesper", "redirect_uris": []string{redirect}, "grant_types": []string{"authorization_code", "refresh_token"},
			"response_types": []string{"code"}, "token_endpoint_auth_method": "none"})
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, as.RegistrationEndpoint, strings.NewReader(string(raw)))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/json")
		res, err := s.client().Do(req)
		if err != nil {
			return "", errors.New("couldn't register with the server's sign-in provider")
		}
		defer res.Body.Close()
		var reg struct {
			ClientID     string `json:"client_id"`
			ClientSecret string `json:"client_secret"`
		}
		if res.StatusCode >= 300 || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&reg) != nil || reg.ClientID == "" {
			return "", errors.New("the server's sign-in provider refused to register Vesper; use an API token instead")
		}
		clientID = reg.ClientID
		dcrSecret = reg.ClientSecret
	}
	verifier, err := randomString()
	if err != nil {
		return "", err
	}
	state, err := randomString()
	if err != nil {
		return "", err
	}
	stored, _ := json.Marshal(oauthState{
		TokenEndpoint:   as.TokenEndpoint,
		ClientID:        clientID,
		ClientSecret:    dcrSecret,
		Scopes:          prev.Scopes,
		CustomClient:    customClient,
		HasClientSecret: prev.HasClientSecret,
		Verifier:        verifier,
		Redirect:        redirect,
	})
	if err := s.Q.SetConnectorOAuth(ctx, store.SetConnectorOAuthParams{ID: c.ID, Oauth: stored, OauthState: &state}); err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(verifier))
	q := url.Values{"response_type": {"code"}, "client_id": {clientID}, "redirect_uri": {redirect}, "state": {state}, "resource": {c.Url},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])}, "code_challenge_method": {"S256"}}
	scopes := prev.Scopes
	if len(scopes) == 0 && len(as.ScopesSupported) > 0 {
		scopes = as.ScopesSupported
	}
	if len(scopes) > 0 {
		q.Set("scope", strings.Join(scopes, " "))
	}
	if customClient || strings.Contains(as.AuthorizationEndpoint, "accounts.google.com") {
		q.Set("access_type", "offline")
		q.Set("prompt", "consent")
	}
	sep := "?"
	if strings.Contains(as.AuthorizationEndpoint, "?") {
		sep = "&"
	}
	return as.AuthorizationEndpoint + sep + q.Encode(), nil
}

func (s *Service) tokenRequest(ctx context.Context, st oauthState, form url.Values) (credential, error) {
	var cred credential
	form.Set("client_id", st.ClientID)
	if st.ClientSecret != "" {
		form.Set("client_secret", st.ClientSecret)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, st.TokenEndpoint, strings.NewReader(form.Encode()))
	if err != nil {
		return cred, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	res, err := s.client().Do(req)
	if err != nil {
		return cred, err
	}
	defer res.Body.Close()
	var body struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		ExpiresIn    int64  `json:"expires_in"`
	}
	if res.StatusCode >= 300 || json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&body) != nil || body.AccessToken == "" {
		return cred, errors.New("the sign-in provider didn't issue a token")
	}
	cred = credential{AccessToken: body.AccessToken, RefreshToken: body.RefreshToken}
	if body.ExpiresIn > 0 {
		cred.ExpiresAt = time.Now().Add(time.Duration(body.ExpiresIn) * time.Second)
	}
	return cred, nil
}

// FinishOAuth completes a sign-in from the provider's redirect.
func (s *Service) FinishOAuth(ctx context.Context, state, code string) (store.Connector, error) {
	c, err := s.Q.ConnectorByOAuthState(ctx, &state)
	if errors.Is(err, pgx.ErrNoRows) {
		return c, errors.New("this sign-in link has expired; start again from Connectors")
	}
	if err != nil {
		return c, err
	}
	var st oauthState
	if err := json.Unmarshal(c.Oauth, &st); err != nil {
		return c, err
	}
	prevCred, err := s.unseal(c)
	if err != nil {
		return c, err
	}
	reqState := st
	if reqState.ClientSecret == "" && prevCred.ClientSecret != "" {
		reqState.ClientSecret = prevCred.ClientSecret
	}
	cred, err := s.tokenRequest(ctx, reqState, url.Values{"grant_type": {"authorization_code"}, "code": {code}, "redirect_uri": {st.Redirect}, "code_verifier": {st.Verifier}, "resource": {c.Url}})
	if err != nil {
		return c, err
	}
	cred.ClientSecret = prevCred.ClientSecret
	if cred.RefreshToken == "" && prevCred.RefreshToken != "" {
		cred.RefreshToken = prevCred.RefreshToken
	}
	if err := s.seal(ctx, c, cred); err != nil {
		return c, err
	}
	st.Verifier, st.Redirect = "", ""
	stored, _ := json.Marshal(st)
	if err := s.Q.SetConnectorOAuth(ctx, store.SetConnectorOAuthParams{ID: c.ID, Oauth: stored}); err != nil {
		return c, err
	}
	c, err = s.Q.GetConnector(ctx, store.GetConnectorParams{ID: c.ID, WorkspaceID: c.WorkspaceID, UserID: c.UserID})
	if err != nil {
		return c, err
	}
	return s.Refresh(ctx, c)
}

func (s *Service) refreshOAuth(ctx context.Context, c store.Connector, cred credential) (credential, error) {
	if cred.RefreshToken == "" {
		return cred, errors.New("the sign-in expired")
	}
	var st oauthState
	if err := json.Unmarshal(c.Oauth, &st); err != nil {
		return cred, err
	}
	if st.ClientSecret == "" && cred.ClientSecret != "" {
		st.ClientSecret = cred.ClientSecret
	}
	next, err := s.tokenRequest(ctx, st, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {cred.RefreshToken}, "resource": {c.Url}})
	if err != nil {
		return cred, err
	}
	next.ClientSecret = cred.ClientSecret
	if next.RefreshToken == "" {
		next.RefreshToken = cred.RefreshToken
	}
	return next, s.seal(ctx, c, next)
}

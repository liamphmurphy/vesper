package usersecrets

import (
	"bytes"
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
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	KindStatic = "static"
	KindOAuth  = "oauth"

	// refreshEarly refreshes a token this long before it expires, so a request
	// never leaves with one that lapses on the way.
	refreshEarly = time.Minute
	maxScopes    = 30
)

// ErrUnknownState means no secret is waiting on this sign-in; the callback it
// arrived on may belong to a connector instead.
var ErrUnknownState = errors.New("no secret sign-in with this state")

// OAuthInput is how a person sets up an OAuth secret: their own registered
// client, and the provider's two endpoints.
type OAuthInput struct {
	AuthorizeURL, TokenURL, ClientID, ClientSecret string
	Scopes                                         []string
}

// OAuthSettings is the public half of an OAuth secret, safe to show.
type OAuthSettings struct {
	AuthorizeURL    string   `json:"authorize_url"`
	TokenURL        string   `json:"token_url"`
	ClientID        string   `json:"client_id"`
	Scopes          []string `json:"scopes,omitempty"`
	HasClientSecret bool     `json:"has_client_secret,omitempty"`
	// Only while a sign-in is in progress.
	Verifier string `json:"verifier,omitempty"`
	Redirect string `json:"redirect,omitempty"`
}

// Settings reads an OAuth secret's public settings.
func Settings(sec store.UserSecret) OAuthSettings {
	var st OAuthSettings
	if len(sec.Oauth) > 0 {
		_ = json.Unmarshal(sec.Oauth, &st)
	}
	st.Verifier, st.Redirect = "", ""
	return st
}

// credential is what an OAuth secret seals in place of a plain value.
type credential struct {
	ClientSecret string    `json:"client_secret,omitempty"`
	AccessToken  string    `json:"access_token,omitempty"`
	RefreshToken string    `json:"refresh_token,omitempty"`
	ExpiresAt    time.Time `json:"expires_at,omitzero"`
	// Granted is the scope the provider says it granted, when it says. A
	// person may untick scopes on the consent screen, so it can be narrower
	// than the scopes asked for.
	Granted []string `json:"granted,omitempty"`
}

// endpointURL accepts https anywhere and plain http only on this machine, as
// for connectors: the token endpoint receives the client secret.
func endpointURL(field, raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" || len(raw) > 2000 {
		return "", apperr.Invalid(field, "enter a full URL")
	}
	if u.User != nil {
		return "", apperr.Invalid(field, "the URL can't contain credentials")
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && isLocal(strings.ToLower(u.Hostname()))) {
		return "", apperr.Invalid(field, "use https (http only works for localhost)")
	}
	return raw, nil
}

// NormalizeScopes splits scopes typed with spaces or commas and drops repeats.
func NormalizeScopes(raw []string) []string {
	out := []string{}
	for _, r := range raw {
		for _, s := range strings.FieldsFunc(r, func(c rune) bool { return c == ',' || c == ' ' || c == '\n' || c == '\t' }) {
			if !slices.Contains(out, s) {
				out = append(out, s)
			}
		}
	}
	return out
}

func validOAuth(in OAuthInput) (OAuthSettings, error) {
	var st OAuthSettings
	var err error
	if st.AuthorizeURL, err = endpointURL("oauth.authorize_url", in.AuthorizeURL); err != nil {
		return st, err
	}
	if st.TokenURL, err = endpointURL("oauth.token_url", in.TokenURL); err != nil {
		return st, err
	}
	st.ClientID = strings.TrimSpace(in.ClientID)
	if st.ClientID == "" || len(st.ClientID) > 500 {
		return st, apperr.Invalid("oauth.client_id", "enter the OAuth client ID")
	}
	if len(in.ClientSecret) > maxValue {
		return st, apperr.Invalid("oauth.client_secret", "is too long")
	}
	st.Scopes = NormalizeScopes(in.Scopes)
	if len(st.Scopes) > maxScopes {
		return st, apperr.Invalid("oauth.scopes", "at most 30 scopes")
	}
	st.HasClientSecret = strings.TrimSpace(in.ClientSecret) != ""
	return st, nil
}

func (s *Service) seal(sec store.UserSecret, c credential) (nonce, ct []byte, err error) {
	raw, err := json.Marshal(c)
	if err != nil {
		return nil, nil, err
	}
	return s.Box.Seal(sec.WorkspaceID, scope(sec.ID), raw)
}

func (s *Service) unseal(sec store.UserSecret) (credential, error) {
	var c credential
	if s.Box == nil {
		return c, ErrNoKey
	}
	pt, err := s.Box.Open(sec.WorkspaceID, scope(sec.ID), sec.Nonce, sec.Ciphertext)
	if err != nil {
		return c, err
	}
	return c, json.Unmarshal(pt, &c)
}

func randomString() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// BeginOAuth starts a sign-in with PKCE and returns where the person signs
// in. redirect is the callback the provider sends the browser back to; it
// must match one registered on the person's OAuth client.
func (s *Service) BeginOAuth(ctx context.Context, sec store.UserSecret, redirect string) (string, error) {
	if sec.Kind != KindOAuth {
		return "", apperr.Conflict("this secret doesn't use OAuth sign-in")
	}
	st := Settings(sec)
	verifier, err := randomString()
	if err != nil {
		return "", err
	}
	state, err := randomString()
	if err != nil {
		return "", err
	}
	st.Verifier, st.Redirect = verifier, redirect
	raw, _ := json.Marshal(st)
	if err := s.Q.BeginUserSecretOAuth(ctx, store.BeginUserSecretOAuthParams{ID: sec.ID, Oauth: raw, OauthState: &state}); err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(verifier))
	q := url.Values{"response_type": {"code"}, "client_id": {st.ClientID}, "redirect_uri": {redirect}, "state": {state},
		"code_challenge": {base64.RawURLEncoding.EncodeToString(sum[:])}, "code_challenge_method": {"S256"},
		// Ask for a refresh token. Google issues one only with both; other
		// providers ignore parameters they don't know.
		"access_type": {"offline"}, "prompt": {"consent"}}
	if len(st.Scopes) > 0 {
		q.Set("scope", strings.Join(st.Scopes, " "))
	}
	sep := "?"
	if strings.Contains(st.AuthorizeURL, "?") {
		sep = "&"
	}
	return st.AuthorizeURL + sep + q.Encode(), nil
}

// tokenError is a refusal from the token endpoint itself, as opposed to the
// network: the grant is bad, so retrying won't help until the person signs in.
type tokenError struct {
	Status int
	Code   string
}

func (e *tokenError) Error() string {
	if e.Code != "" {
		return fmt.Sprintf("the sign-in provider refused the token request (%s)", e.Code)
	}
	return fmt.Sprintf("the sign-in provider refused the token request (status %d)", e.Status)
}

func (s *Service) tokenClient(tokenURL string) *http.Client {
	var rt http.RoundTripper = s.HTTP
	if rt == nil {
		host := ""
		if u, err := url.Parse(tokenURL); err == nil {
			host = strings.ToLower(u.Hostname())
		}
		rt = s.transport(host)
	}
	return &http.Client{Transport: rt, Timeout: sendTimeout, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
}

// oauthScope accepts either a standard space-delimited string or a JSON array
// of scope strings (e.g. Twitch's token response).
type oauthScope []string

func (s *oauthScope) UnmarshalJSON(data []byte) error {
	trimmed := bytes.TrimSpace(data)
	if len(trimmed) == 0 || bytes.Equal(trimmed, []byte("null")) {
		*s = nil
		return nil
	}
	switch trimmed[0] {
	case '"':
		var raw string
		if err := json.Unmarshal(trimmed, &raw); err != nil {
			return err
		}
		*s = NormalizeScopes([]string{raw})
		return nil
	case '[':
		var raw []string
		if err := json.Unmarshal(trimmed, &raw); err != nil {
			return err
		}
		*s = NormalizeScopes(raw)
		return nil
	default:
		return fmt.Errorf("oauth scope must be string or array")
	}
}

func (s *Service) tokenRequest(ctx context.Context, st OAuthSettings, clientSecret string, form url.Values) (credential, error) {
	var c credential
	form.Set("client_id", st.ClientID)
	if clientSecret != "" {
		form.Set("client_secret", clientSecret)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, st.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return c, err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")
	client := s.tokenClient(st.TokenURL)
	res, err := client.Do(req)
	if err != nil {
		var b *Blocked
		if errors.As(err, &b) {
			return c, b
		}
		return c, errors.New("couldn't reach the sign-in provider")
	}
	defer res.Body.Close()
	var body struct {
		AccessToken  string     `json:"access_token"`
		RefreshToken string     `json:"refresh_token"`
		ExpiresIn    int64      `json:"expires_in"`
		Scope        oauthScope `json:"scope"`
		Error        string     `json:"error"`
	}
	decodeErr := json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&body)
	if res.StatusCode >= 300 {
		return c, &tokenError{Status: res.StatusCode, Code: body.Error}
	}
	if decodeErr != nil || body.AccessToken == "" {
		return c, errors.New("the sign-in provider didn't issue a token")
	}
	c = credential{AccessToken: body.AccessToken, RefreshToken: body.RefreshToken}
	if len(body.Scope) > 0 {
		c.Granted = []string(body.Scope)
	}
	if body.ExpiresIn > 0 {
		c.ExpiresAt = s.now().Add(time.Duration(body.ExpiresIn) * time.Second)
	}
	return c, nil
}

// FinishOAuth completes a sign-in from the provider's redirect. It returns
// ErrUnknownState when no secret started this sign-in.
func (s *Service) FinishOAuth(ctx context.Context, state, code string) (store.UserSecret, error) {
	sec, err := s.Q.UserSecretByOAuthState(ctx, &state)
	if errors.Is(err, pgx.ErrNoRows) {
		return sec, ErrUnknownState
	}
	if err != nil {
		return sec, err
	}
	var st OAuthSettings
	if err := json.Unmarshal(sec.Oauth, &st); err != nil {
		return sec, err
	}
	prev, err := s.unseal(sec)
	if err != nil {
		return sec, err
	}
	next, err := s.tokenRequest(ctx, st, prev.ClientSecret, url.Values{"grant_type": {"authorization_code"}, "code": {code},
		"redirect_uri": {st.Redirect}, "code_verifier": {st.Verifier}})
	if err != nil {
		return sec, err
	}
	if next.RefreshToken == "" {
		next.RefreshToken = prev.RefreshToken
	}
	if next.RefreshToken == "" && !next.ExpiresAt.IsZero() {
		// It would work until it expires, then fail with nothing to renew it.
		return sec, errors.New("the provider gave no refresh token, so Vesper couldn't keep this signed in; check that the OAuth client allows offline access")
	}
	next.ClientSecret = prev.ClientSecret
	nonce, ct, err := s.seal(sec, next)
	if err != nil {
		return sec, err
	}
	st.Verifier, st.Redirect = "", ""
	raw, _ := json.Marshal(st)
	return s.Q.FinishUserSecretOAuth(ctx, store.FinishUserSecretOAuthParams{ID: sec.ID, Oauth: raw, Nonce: nonce, Ciphertext: ct})
}

// refreshLocks keeps two requests from refreshing the same secret at once.
// Some providers rotate refresh tokens, and the loser would store a dead one.
var refreshLocks sync.Map

func lockSecret(id uuid.UUID) func() {
	m, _ := refreshLocks.LoadOrStore(id, &sync.Mutex{})
	mu := m.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

func (s *Service) fresh(c credential) bool {
	return c.AccessToken != "" && (c.ExpiresAt.IsZero() || s.now().Add(refreshEarly).Before(c.ExpiresAt))
}

// Value is what Send adds to a request: a static secret's value, or an OAuth
// secret's access token, refreshed first when it's about to expire.
func (s *Service) Value(ctx context.Context, sec store.UserSecret) (string, error) {
	if sec.Kind != KindOAuth {
		return s.Reveal(sec)
	}
	if sec.SignedInAt == nil {
		return "", notSignedIn(sec)
	}
	c, err := s.unseal(sec)
	if err != nil {
		return "", err
	}
	if s.fresh(c) {
		return c.AccessToken, nil
	}
	unlock := lockSecret(sec.ID)
	defer unlock()
	// Another request may have refreshed it while this one waited.
	if sec, err = s.Q.UserSecretByID(ctx, sec.ID); err != nil {
		return "", err
	}
	if c, err = s.unseal(sec); err != nil {
		return "", err
	}
	if s.fresh(c) {
		return c.AccessToken, nil
	}
	if c.RefreshToken == "" {
		return "", s.signInLapsed(ctx, sec, "the access token expired and there's no refresh token")
	}
	var st OAuthSettings
	if err := json.Unmarshal(sec.Oauth, &st); err != nil {
		return "", err
	}
	next, err := s.tokenRequest(ctx, st, c.ClientSecret, url.Values{"grant_type": {"refresh_token"}, "refresh_token": {c.RefreshToken}})
	var te *tokenError
	if errors.As(err, &te) {
		return "", s.signInLapsed(ctx, sec, te.Error())
	}
	if err != nil {
		// The network or the provider is down; the grant may still be good.
		return "", err
	}
	next.ClientSecret = c.ClientSecret
	if next.RefreshToken == "" {
		next.RefreshToken = c.RefreshToken
	}
	if len(next.Granted) == 0 {
		// A refresh that doesn't name its scope keeps the grant's.
		next.Granted = c.Granted
	}
	nonce, ct, err := s.seal(sec, next)
	if err != nil {
		return "", err
	}
	if err := s.Q.StoreUserSecretToken(ctx, store.StoreUserSecretTokenParams{ID: sec.ID, Nonce: nonce, Ciphertext: ct}); err != nil {
		return "", err
	}
	return next.AccessToken, nil
}

// signInLapsed records why a refresh failed, so Secrets can show it and later
// requests stop before they reach the provider, until the person signs in again.
func (s *Service) signInLapsed(ctx context.Context, sec store.UserSecret, why string) error {
	_ = s.Q.SetUserSecretOAuthError(context.WithoutCancel(ctx), store.SetUserSecretOAuthErrorParams{ID: sec.ID, OauthError: why})
	return blocked("%s needs signing in again (%s). Ask the person to sign in from Customization › Secrets.", sec.Handle, why)
}

func notSignedIn(sec store.UserSecret) error {
	return blocked("%s isn't signed in yet. Ask the person to sign in from Customization › Secrets.", sec.Handle)
}

// RequireScope reports, in words the person can act on, why an OAuth secret
// can't be used for something that needs one of anyOf: it isn't an OAuth
// secret, it isn't signed in, its grant lapsed, or it wasn't granted any of
// those scopes. It checks the scope the provider granted when it said, and
// otherwise the scopes the secret asks for. It sends nothing.
func (s *Service) RequireScope(sec store.UserSecret, anyOf ...string) error {
	if sec.Kind != KindOAuth {
		return apperr.Conflict("%s isn't an OAuth secret. Add one that signs in with OAuth in Customization › Secrets.", sec.Handle)
	}
	if sec.SignedInAt == nil {
		return apperr.Conflict("%s isn't signed in yet. Sign in from Customization › Secrets.", sec.Handle)
	}
	if sec.OauthError != "" {
		return apperr.Conflict("%s needs signing in again (%s). Sign in from Customization › Secrets.", sec.Handle, sec.OauthError)
	}
	scopes := Settings(sec).Scopes
	c, err := s.unseal(sec)
	if err != nil {
		return err
	}
	if len(c.Granted) > 0 {
		scopes = c.Granted
	}
	if slices.ContainsFunc(anyOf, func(want string) bool { return slices.Contains(scopes, want) }) {
		return nil
	}
	has := "no scopes"
	if len(scopes) > 0 {
		has = strings.Join(scopes, " ")
	}
	return apperr.Conflict("%s doesn't have the access this needs: it has %s. Add %s to its scopes in Customization › Secrets and sign in again.",
		sec.Handle, has, strings.Join(anyOf, " or "))
}

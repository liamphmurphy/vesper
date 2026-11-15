// Package usersecrets keeps the secrets a person stores for their personas'
// API calls (a JWT, an API key) and sends requests with them. A run never
// receives a value: it names a secret by handle, and Send adds the value where
// the person said, only on requests to hosts the person allowed, then masks
// the value anywhere it comes back. See agentapi.SecretsHandler.
package usersecrets

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	PlacementBearer = "bearer"
	PlacementHeader = "header"
	PlacementQuery  = "query"
	PlacementBasic  = "basic"

	PolicyAllow = "allow"
	PolicyAsk   = "ask"
	PolicyOff   = "off"

	maxValue = 16 << 10
	maxHosts = 10
)

// ErrNoKey means SECRETS_KEY isn't set, so values can't be stored or read.
var ErrNoKey = apperr.Conflict("set SECRETS_KEY on the server to store secrets")

// Service stores secrets and sends requests with them. LookupIP, Now and
// HTTP (the OAuth token endpoint's transport) are overridable for tests.
type Service struct {
	Q        *store.Queries
	Box      *secrets.Box
	LookupIP func(ctx context.Context, host string) ([]net.IP, error)
	Now      func() time.Time
	HTTP     http.RoundTripper
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// scope binds a ciphertext to its row, so it can't be moved to another secret.
func scope(id uuid.UUID) string { return "user-secret:" + id.String() }

var (
	nonHandle   = regexp.MustCompile(`[^a-z0-9]+`)
	headerName  = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)
	queryName   = regexp.MustCompile(`^[A-Za-z0-9_.\-\[\]]{1,64}$`)
	hostnameRe  = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`)
	reservedHdr = []string{"host", "cookie", "content-length", "content-type", "transfer-encoding", "connection", "proxy-authorization", "te", "upgrade"}
)

// handleFor turns a display name into the handle personas see.
func handleFor(name string) (string, error) {
	h := strings.Trim(nonHandle.ReplaceAllString(strings.ToLower(name), "-"), "-")
	if h == "" {
		return "", apperr.Invalid("name", "use at least one letter or digit")
	}
	if h[0] >= '0' && h[0] <= '9' {
		h = "s-" + h
	}
	if len(h) > 36 {
		h = strings.TrimRight(h[:36], "-")
	}
	return h, nil
}

// ValidName checks a display name.
func ValidName(name string) (string, error) {
	name = strings.TrimSpace(name)
	if name == "" || utf8.RuneCountInString(name) > 60 {
		return "", apperr.Invalid("name", "must be 1–60 characters")
	}
	return name, nil
}

// ValidPlacement checks where a value goes and normalizes its key: bearer and
// basic take none, header and query need a name.
func ValidPlacement(placement, key string) (string, error) {
	key = strings.TrimSpace(key)
	switch placement {
	case PlacementBearer, PlacementBasic:
		return "", nil
	case PlacementHeader:
		if !headerName.MatchString(key) {
			return "", apperr.Invalid("placement_key", "enter a header name, e.g. X-Api-Key")
		}
		if slices.Contains(reservedHdr, strings.ToLower(key)) {
			return "", apperr.Invalid("placement_key", "that header can't carry a secret")
		}
		return key, nil
	case PlacementQuery:
		if !queryName.MatchString(key) {
			return "", apperr.Invalid("placement_key", "enter a query parameter name, e.g. api_key")
		}
		return key, nil
	}
	return "", apperr.Invalid("placement", "must be bearer, header, query or basic")
}

// ValidPolicy checks an Allow / Ask / Off setting.
func ValidPolicy(field, p string) error {
	if p != PolicyAllow && p != PolicyAsk && p != PolicyOff {
		return apperr.Invalid(field, "must be allow, ask or off")
	}
	return nil
}

// NormalizeHost reduces what a person typed (a hostname, or a pasted URL) to a
// lowercase hostname. Wildcards, paths and ports aren't hosts: any port on an
// allowed host is fine, but nothing else on the domain is.
func NormalizeHost(raw string) (string, error) {
	h := strings.ToLower(strings.TrimSpace(raw))
	if i := strings.Index(h, "://"); i >= 0 {
		h = h[i+3:]
	}
	if i := strings.IndexAny(h, "/?#"); i >= 0 {
		h = h[:i]
	}
	if i := strings.LastIndex(h, "@"); i >= 0 {
		h = h[i+1:]
	}
	if strings.HasPrefix(h, "[") {
		if i := strings.Index(h, "]"); i > 0 {
			h = h[1:i]
		}
	} else if i := strings.LastIndex(h, ":"); i >= 0 && strings.Count(h, ":") == 1 {
		h = h[:i]
	}
	h = strings.TrimSuffix(h, ".")
	if net.ParseIP(h) != nil || hostnameRe.MatchString(h) {
		return h, nil
	}
	return "", apperr.Invalid("allowed_hosts", "enter hostnames like api.example.com (no wildcards)")
}

// ValidHosts normalizes and de-duplicates the allowed hosts.
func ValidHosts(raw []string) ([]string, error) {
	out := []string{}
	for _, r := range raw {
		h, err := NormalizeHost(r)
		if err != nil {
			return nil, err
		}
		if !slices.Contains(out, h) {
			out = append(out, h)
		}
	}
	if len(out) == 0 {
		return nil, apperr.Invalid("allowed_hosts", "add at least one host the secret may be sent to")
	}
	if len(out) > maxHosts {
		return nil, apperr.Invalid("allowed_hosts", "at most 10 hosts")
	}
	return out, nil
}

func validValue(placement, value string) error {
	if value == "" || len(value) > maxValue || !utf8.ValidString(value) {
		return apperr.Invalid("value", "must be 1 B–16 KB of text")
	}
	if strings.ContainsAny(value, "\r\n") && placement != PlacementQuery {
		return apperr.Invalid("value", "can't contain line breaks")
	}
	if placement == PlacementBasic && !strings.Contains(value, ":") {
		return apperr.Invalid("value", "for Basic auth, enter username:password")
	}
	return nil
}

// SentAs describes where a value goes without the value, e.g. "Authorization: Bearer".
func SentAs(placement, key string) string {
	switch placement {
	case PlacementBearer:
		return "Authorization: Bearer"
	case PlacementHeader:
		return key + " header"
	case PlacementQuery:
		return key + " query parameter"
	}
	return "Basic auth"
}

// JWTExpiry reads the exp claim of a value shaped like a JWT. The signature
// isn't checked: this only tells the person when the token stops working.
func JWTExpiry(value string) *time.Time {
	parts := strings.Split(strings.TrimSpace(value), ".")
	if len(parts) != 3 {
		return nil
	}
	raw, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return nil
	}
	var claims struct {
		Exp json.Number `json:"exp"`
	}
	if json.Unmarshal(raw, &claims) != nil || claims.Exp == "" {
		return nil
	}
	sec, err := claims.Exp.Float64()
	if err != nil || sec <= 0 {
		return nil
	}
	t := time.Unix(int64(sec), 0).UTC()
	return &t
}

// Input creates a secret. A proposal's persona is the only one given access:
// the person just approved exactly that. With OAuth set, there's no Value:
// the person signs in afterwards (BeginOAuth), and the token is sent as a bearer.
type Input struct {
	Name, Value, Placement, PlacementKey string
	AllowedHosts                         []string
	ReadPolicy, WritePolicy              string
	ProposalID                           *uuid.UUID
	OAuth                                *OAuthInput
}

// Create validates and stores a secret.
func (s *Service) Create(ctx context.Context, ws, user uuid.UUID, in Input) (store.UserSecret, error) {
	var out store.UserSecret
	if s.Box == nil {
		return out, ErrNoKey
	}
	name, err := ValidName(in.Name)
	if err != nil {
		return out, err
	}
	var oauth OAuthSettings
	if in.OAuth != nil {
		if in.Value != "" {
			return out, apperr.Invalid("value", "leave the value out: Vesper gets the token when you sign in")
		}
		if in.Placement != "" && in.Placement != PlacementBearer {
			return out, apperr.Invalid("placement", "an OAuth secret is always sent as Authorization: Bearer")
		}
		in.Placement = PlacementBearer
		if oauth, err = validOAuth(*in.OAuth); err != nil {
			return out, err
		}
	}
	key, err := ValidPlacement(in.Placement, in.PlacementKey)
	if err != nil {
		return out, err
	}
	hosts, err := ValidHosts(in.AllowedHosts)
	if err != nil {
		return out, err
	}
	if in.ReadPolicy == "" {
		in.ReadPolicy = PolicyAllow
	}
	if in.WritePolicy == "" {
		in.WritePolicy = PolicyAsk
	}
	if err := ValidPolicy("read_policy", in.ReadPolicy); err != nil {
		return out, err
	}
	if err := ValidPolicy("write_policy", in.WritePolicy); err != nil {
		return out, err
	}
	if in.OAuth == nil {
		if err := validValue(in.Placement, in.Value); err != nil {
			return out, err
		}
	}
	base, err := handleFor(name)
	if err != nil {
		return out, err
	}
	handle := base
	for n := 2; ; n++ {
		taken, err := s.Q.UserSecretHandleTaken(ctx, store.UserSecretHandleTakenParams{WorkspaceID: ws, UserID: user, Handle: handle})
		if err != nil {
			return out, err
		}
		if !taken {
			break
		}
		if n > 50 {
			return out, apperr.Invalid("name", "you already have many secrets with this name")
		}
		handle = base + "-" + strconv.Itoa(n)
	}
	var proposal *store.UserSecretProposal
	if in.ProposalID != nil {
		p, err := s.Q.GetUserSecretProposal(ctx, store.GetUserSecretProposalParams{ID: *in.ProposalID, WorkspaceID: ws, CreatedBy: user})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && p.State != "pending") {
			return out, apperr.Invalid("proposal_id", "that request is no longer open")
		}
		if err != nil {
			return out, err
		}
		proposal = &p
	}
	id := uuid.Must(uuid.NewV7())
	params := store.CreateUserSecretParams{ID: id, WorkspaceID: ws, UserID: user, Name: name, Handle: handle, Placement: in.Placement,
		PlacementKey: key, AllowedHosts: hosts, ReadPolicy: in.ReadPolicy, WritePolicy: in.WritePolicy, ExpiresAt: JWTExpiry(in.Value)}
	if in.OAuth != nil {
		// Until sign-in, the sealed credential holds only the client secret.
		kind := KindOAuth
		params.Kind, params.ExpiresAt = &kind, nil
		params.Oauth, _ = json.Marshal(oauth)
		params.Nonce, params.Ciphertext, err = s.seal(store.UserSecret{ID: id, WorkspaceID: ws}, credential{ClientSecret: strings.TrimSpace(in.OAuth.ClientSecret)})
	} else {
		params.Nonce, params.Ciphertext, err = s.Box.Seal(ws, scope(id), []byte(in.Value))
	}
	if err != nil {
		return out, err
	}
	out, err = s.Q.CreateUserSecret(ctx, params)
	if err != nil {
		return out, err
	}
	if proposal != nil {
		if _, err := s.Q.FinishUserSecretProposal(ctx, store.FinishUserSecretProposalParams{ID: proposal.ID, State: "approved", SecretID: &out.ID}); err != nil {
			return out, err
		}
		if proposal.ProposedBy != nil {
			if err := s.Q.AddUserSecretPersona(ctx, store.AddUserSecretPersonaParams{SecretID: out.ID, PersonaID: *proposal.ProposedBy}); err != nil {
				return out, err
			}
		}
	}
	return out, nil
}

// SetValue replaces a secret's value, re-reading its expiry. placement is the
// one the secret will have, so a change to Basic auth checks the new shape.
func (s *Service) SetValue(ctx context.Context, sec store.UserSecret, placement, value string) (store.UserSecret, error) {
	if s.Box == nil {
		return sec, ErrNoKey
	}
	if sec.Kind == KindOAuth {
		return sec, apperr.Invalid("value", "an OAuth secret's token comes from signing in; sign in again instead")
	}
	if err := validValue(placement, value); err != nil {
		return sec, err
	}
	nonce, ct, err := s.Box.Seal(sec.WorkspaceID, scope(sec.ID), []byte(value))
	if err != nil {
		return sec, err
	}
	return s.Q.SetUserSecretValue(ctx, store.SetUserSecretValueParams{ID: sec.ID, Nonce: nonce, Ciphertext: ct, ExpiresAt: JWTExpiry(value)})
}

// Reveal decrypts a static value. Never return it through an API. Send's
// callers use Value, which also handles OAuth secrets.
func (s *Service) Reveal(sec store.UserSecret) (string, error) {
	if s.Box == nil {
		return "", ErrNoKey
	}
	if sec.Kind == KindOAuth {
		// The sealed credential holds a refresh token and client secret, which
		// must never be sent as if they were the value.
		return "", errors.New("an OAuth secret has no single value; use Value")
	}
	pt, err := s.Box.Open(sec.WorkspaceID, scope(sec.ID), sec.Nonce, sec.Ciphertext)
	if err != nil {
		return "", err
	}
	return string(pt), nil
}

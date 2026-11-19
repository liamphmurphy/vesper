package agentapi

import (
	"context"
	"net/url"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// What the person has connected, from a chat: a persona checks here before
// proposing a connector or secret they already have, and can explain why one
// isn't working. Only names, hosts and status leave the server: never a
// connector's address path or query, a credential or a secret's value.

// maxConnectorError bounds a connector's last error as a persona sees it.
const maxConnectorError = 200

type chatConnector struct {
	Name       string     `json:"name"`
	Slug       string     `json:"slug"`
	Host       string     `json:"host"`
	Auth       string     `json:"auth"`
	Status     string     `json:"status"`
	LastError  string     `json:"last_error,omitempty"`
	CheckedAt  *time.Time `json:"checked_at,omitempty"`
	UsableHere bool       `json:"usable_here"`
}

type pendingProposal struct {
	Name string `json:"name"`
	Host string `json:"host"`
}

// hostOf is a URL's host alone: a connector's address can carry a token in its
// path or query.
func hostOf(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

// chatSpeaker is the chat a tool runs in and the persona answering it, or nil
// when nobody but the default assistant is.
func chatSpeaker(ctx context.Context, d Deps, c agents.Caller) (store.ChatSession, *uuid.UUID, error) {
	chat, err := d.Q.ChatSessionForRun(ctx, c.RunID)
	if err != nil {
		return chat, nil, err
	}
	return chat, runs.ChatSpeakerID(chat), nil
}

func listConnectors(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	s, err := personChatScope(ctx, d, c, "list_connectors")
	if err != nil {
		return nil, err
	}
	ws := c.Agent.WorkspaceID
	rows, err := d.Q.ListConnectors(ctx, store.ListConnectorsParams{WorkspaceID: ws, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	chat, speaker, err := chatSpeaker(ctx, d, c)
	if err != nil {
		return nil, err
	}
	usable := map[uuid.UUID]bool{}
	if speaker != nil {
		mine, err := d.Q.ConnectorsForPersona(ctx, store.ConnectorsForPersonaParams{WorkspaceID: ws, UserID: s.UserID, PersonaID: *speaker, AllowedIds: chat.ConnectorIds})
		if err != nil {
			return nil, err
		}
		for _, m := range mine {
			usable[m.ID] = true
		}
	}
	out := make([]chatConnector, len(rows))
	for i, r := range rows {
		lastError := r.LastError
		if rs := []rune(lastError); len(rs) > maxConnectorError {
			lastError = string(rs[:maxConnectorError]) + "…"
		}
		out[i] = chatConnector{Name: r.Name, Slug: r.Slug, Host: hostOf(r.Url), Auth: r.AuthKind, Status: r.Status, LastError: lastError, CheckedAt: r.LastCheckedAt, UsableHere: usable[r.ID]}
	}
	proposals, err := d.Q.ListConnectorProposals(ctx, chat.ID)
	if err != nil {
		return nil, err
	}
	pending := make([]pendingProposal, len(proposals))
	for i, p := range proposals {
		pending[i] = pendingProposal{Name: p.Name, Host: hostOf(p.Url)}
	}
	return map[string]any{"connectors": out, "pending_proposals": pending, "href": "/settings?section=connectors"}, nil
}

type chatSecretName struct {
	Name         string     `json:"name"`
	Handle       string     `json:"handle"`
	AllowedHosts []string   `json:"allowed_hosts"`
	ExpiresAt    *time.Time `json:"expires_at,omitempty"`
	Expired      bool       `json:"expired,omitempty"`
	UsableHere   bool       `json:"usable_here"`
}

func listSecretNames(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	s, err := personChatScope(ctx, d, c, "list_secret_names")
	if err != nil {
		return nil, err
	}
	ws := c.Agent.WorkspaceID
	rows, err := d.Q.ListUserSecrets(ctx, store.ListUserSecretsParams{WorkspaceID: ws, UserID: s.UserID})
	if err != nil {
		return nil, err
	}
	chat, speaker, err := chatSpeaker(ctx, d, c)
	if err != nil {
		return nil, err
	}
	usable := map[uuid.UUID]bool{}
	if speaker != nil {
		mine, err := d.Q.UserSecretsForPersona(ctx, store.UserSecretsForPersonaParams{WorkspaceID: ws, UserID: s.UserID, PersonaID: *speaker, AllowedIds: chat.SecretIds})
		if err != nil {
			return nil, err
		}
		for _, m := range mine {
			usable[m.ID] = true
		}
	}
	now := time.Now()
	out := make([]chatSecretName, len(rows))
	for i, r := range rows {
		out[i] = chatSecretName{Name: r.Name, Handle: r.Handle, AllowedHosts: r.AllowedHosts, ExpiresAt: r.ExpiresAt, Expired: r.ExpiresAt != nil && !r.ExpiresAt.After(now), UsableHere: usable[r.ID]}
	}
	proposals, err := d.Q.ListUserSecretProposals(ctx, chat.ID)
	if err != nil {
		return nil, err
	}
	pending := make([]pendingProposal, len(proposals))
	for i, p := range proposals {
		pending[i] = pendingProposal{Name: p.Name, Host: p.Host}
	}
	return map[string]any{"secrets": out, "pending_proposals": pending, "href": "/settings?section=secrets&tab=api"}, nil
}

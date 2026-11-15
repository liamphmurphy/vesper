package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

// parseLoose reads a URL the checks refused, for the log only.
func parseLoose(raw string) *url.URL {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return nil
	}
	return u
}

// maxPendingApprovals caps the requests one chat can have waiting: each one
// holds a tool call open for up to 30 minutes and lands in the inbox.
const maxPendingApprovals = 3

// secretsFor are the secrets this run's persona may use in its chat. Anything
// else fails closed, as connectorFor does.
func secretsFor(ctx context.Context, d Deps, c agents.Caller) ([]store.UserSecret, store.ChatSession, error) {
	var chat store.ChatSession
	if c.RunID == nil {
		return nil, chat, apperr.ErrNotFound
	}
	chat, err := d.Q.ChatSessionForRun(ctx, c.RunID)
	if err != nil {
		return nil, chat, err
	}
	speaker := runs.ChatSpeakerID(chat)
	if speaker == nil {
		return nil, chat, apperr.ErrNotFound
	}
	rows, err := d.Q.UserSecretsForPersona(ctx, store.UserSecretsForPersonaParams{WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy, PersonaID: *speaker, AllowedIds: chat.SecretIds})
	return rows, chat, err
}

type ListSecretsOut struct {
	Secrets []SecretInfo `json:"secrets"`
}

type SecretInfo struct {
	Handle       string     `json:"handle"`
	Name         string     `json:"name"`
	AllowedHosts []string   `json:"allowed_hosts"`
	SentAs       string     `json:"sent_as"`
	Reads        string     `json:"reads"`
	Writes       string     `json:"writes"`
	ExpiresAt    *time.Time `json:"expires_at,omitempty"`
}

type HTTPRequestIn struct {
	Secret  string            `json:"secret" jsonschema:"The secret's handle, from list_secrets"`
	Method  string            `json:"method,omitempty" jsonschema:"GET (default), HEAD, POST, PUT, PATCH or DELETE"`
	URL     string            `json:"url" jsonschema:"The full https URL, on one of the secret's allowed hosts"`
	Headers map[string]string `json:"headers,omitempty" jsonschema:"Extra request headers. Never Authorization or the secret's own header: Vesper adds the secret"`
	JSON    any               `json:"json,omitempty" jsonschema:"A JSON body, sent as application/json"`
	Body    string            `json:"body,omitempty" jsonschema:"A raw text body, when json doesn't fit; set Content-Type in headers"`
}

const listSecretsDesc = "The person's API secrets you may use: each one's handle, the hosts it may be sent to, how it's sent, and whether reads (GET, HEAD) and writes (other methods) run, ask the person, or are off. You never see a value."

const httpRequestDesc = "Make an HTTPS request with one of the person's secrets. Name it by handle; Vesper adds the value where the person configured it and sends the request, but only to the secret's allowed hosts. Requests set to ask wait for the person's approval. Any copy of the value in the response comes back as ‹handle›. If a request is denied or blocked, don't retry it; tell the person."

// SecretsHandler serves a chat's API secrets at
// /mcp/connectors/vesper_secrets. It's the only way a run uses a secret, and
// the enforcement point: the run holds only its own token and a handle, and
// every request is checked, approved when the person asked to be, sent by
// Vesper and logged.
func SecretsHandler(d Deps, version string) http.Handler {
	h := mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
		info := auth.TokenInfoFromContext(r.Context())
		if info == nil {
			return nil
		}
		caller, _ := info.Extra[callerKey].(agents.Caller)
		rows, _, err := secretsFor(r.Context(), d, caller)
		if err != nil || len(rows) == 0 {
			return nil
		}
		srv := mcp.NewServer(&mcp.Implementation{Name: agentdef.SecretsMCPName, Version: version}, nil)
		mcp.AddTool(srv, &mcp.Tool{Name: "list_secrets", Description: listSecretsDesc, Annotations: &mcp.ToolAnnotations{ReadOnlyHint: true}},
			func(ctx context.Context, _ *mcp.CallToolRequest, _ Empty) (*mcp.CallToolResult, ListSecretsOut, error) {
				rows, _, err := secretsFor(ctx, d, caller)
				if err != nil {
					return toolFailure("Couldn't load your secrets."), ListSecretsOut{}, nil
				}
				out := ListSecretsOut{Secrets: make([]SecretInfo, len(rows))}
				for i, s := range rows {
					out.Secrets[i] = SecretInfo{Handle: s.Handle, Name: s.Name, AllowedHosts: s.AllowedHosts, SentAs: usersecrets.SentAs(s.Placement, s.PlacementKey), Reads: s.ReadPolicy, Writes: s.WritePolicy, ExpiresAt: s.ExpiresAt}
				}
				return nil, out, nil
			})
		mcp.AddTool(srv, &mcp.Tool{Name: "http_request", Description: httpRequestDesc},
			func(ctx context.Context, _ *mcp.CallToolRequest, in HTTPRequestIn) (*mcp.CallToolResult, any, error) {
				return secretRequest(ctx, d, caller, in), nil, nil
			})
		return srv
	}, &mcp.StreamableHTTPOptions{Stateless: true, JSONResponse: true, DisableLocalhostProtection: true})
	return auth.RequireBearerToken(verifier(d), nil)(h)
}

// secretByHandle looks the secret up again on every use, so access the
// person removed (or a narrowed chat) applies to the next request.
func secretByHandle(ctx context.Context, d Deps, c agents.Caller, handle string) (store.UserSecret, store.ChatSession, error) {
	rows, chat, err := secretsFor(ctx, d, c)
	if err != nil {
		return store.UserSecret{}, chat, err
	}
	for _, s := range rows {
		if s.Handle == strings.TrimSpace(handle) {
			return s, chat, nil
		}
	}
	return store.UserSecret{}, chat, apperr.ErrNotFound
}

func secretRequest(ctx context.Context, d Deps, c agents.Caller, in HTTPRequestIn) *mcp.CallToolResult {
	sec, chat, err := secretByHandle(ctx, d, c, in.Secret)
	if err != nil {
		return toolFailure(fmt.Sprintf("You can't use a secret named %q here. list_secrets shows the ones you can.", in.Secret))
	}
	req := usersecrets.Request{Method: in.Method, URL: in.URL, Headers: in.Headers}
	switch {
	case in.JSON != nil && in.Body != "":
		return toolFailure("Send either json or body, not both.")
	case in.JSON != nil:
		raw, err := json.Marshal(in.JSON)
		if err != nil {
			return toolFailure("json must be a JSON value.")
		}
		req.Body, req.ContentType = raw, "application/json"
	case in.Body != "":
		req.Body = []byte(in.Body)
	}
	persona := runs.ChatSpeakerID(chat)
	logged := context.WithoutCancel(ctx)
	log := func(ck usersecrets.Checked, decision string, status *int32, msg string, redactions int, took time.Duration) {
		logSecretRequest(d, &chat.ID, persona, sec, ck, in.URL, decision, status, msg, redactions, took)
	}

	ck, err := d.Secrets.Check(sec, req)
	if err != nil {
		log(ck, "blocked", nil, err.Error(), 0, 0)
		return toolFailure(err.Error())
	}
	decision := "auto"
	if ck.Policy == usersecrets.PolicyAsk {
		refusal, askErr := requestSecretApproval(ctx, d, chat.ID, persona, sec, ck, req)
		if askErr != nil {
			return toolFailure(askErr.Error())
		}
		if refusal != "" {
			log(ck, "denied", nil, refusal, 0, 0)
			return toolFailure(refusal)
		}
		decision = "approved"
		// The person may have changed the secret while deciding: send only
		// what its rules allow now.
		if sec, _, err = secretByHandle(ctx, d, c, in.Secret); err != nil {
			log(ck, "blocked", nil, "access was removed while waiting", 0, 0)
			return toolFailure("Access to this secret was removed while you waited.")
		}
		if ck, err = d.Secrets.Check(sec, req); err != nil {
			log(ck, "blocked", nil, err.Error(), 0, 0)
			return toolFailure(err.Error())
		}
	}
	value, err := d.Secrets.Reveal(sec)
	if err != nil {
		log(ck, "blocked", nil, "couldn't decrypt the secret", 0, 0)
		return toolFailure("Vesper couldn't decrypt this secret. Ask the person to replace it.")
	}
	start := time.Now()
	res, err := d.Secrets.Send(ctx, sec, value, ck, req)
	took := time.Since(start)
	if err != nil {
		var b *usersecrets.Blocked
		if errors.As(err, &b) {
			log(ck, "blocked", nil, err.Error(), 0, took)
		} else {
			log(ck, decision, nil, err.Error(), 0, took)
		}
		return toolFailure(err.Error())
	}
	_ = d.Q.TouchUserSecret(logged, sec.ID)
	status := int32(res.Status)
	log(ck, decision, &status, "", res.Redactions, took)
	raw, _ := json.Marshal(res)
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(raw)}}}
}

func requestSecretApproval(ctx context.Context, d Deps, chatID uuid.UUID, persona *uuid.UUID, sec store.UserSecret, ck usersecrets.Checked, req usersecrets.Request) (string, error) {
	logged := context.WithoutCancel(ctx)
	headers, _ := json.Marshal(req.Headers)
	if req.Headers == nil {
		headers = []byte("{}")
	}
	if n, err := d.Q.CountPendingUserSecretApprovals(ctx, chatID); err != nil {
		return "", errors.New("Couldn't ask the person for approval.")
	} else if n >= maxPendingApprovals {
		logSecretRequest(d, &chatID, persona, sec, ck, req.URL, "blocked", nil, "too many requests waiting", 0, 0)
		return "", errors.New("Three requests are already waiting for the person in this chat. Wait for them before asking again.")
	}
	// The whole body, not a preview: the person approves exactly what's sent.
	a, err := d.Q.CreateUserSecretApproval(logged, store.CreateUserSecretApprovalParams{
		WorkspaceID: sec.WorkspaceID,
		UserID:      sec.UserID,
		SecretID:    sec.ID,
		PersonaID:   persona,
		ChatID:      chatID,
		Method:      ck.Method,
		Url:         ck.URL.String(),
		Headers:     headers,
		Body:        string(req.Body),
	})
	if err != nil {
		return "", errors.New("Couldn't ask the person for approval.")
	}
	refusal := awaitDecision(ctx, func(ctx context.Context) (string, error) {
		cur, err := d.Q.GetUserSecretApproval(ctx, a.ID)
		return cur.State, err
	}, func() { _ = d.Q.ExpireUserSecretApproval(logged, a.ID) })
	return refusal, nil
}

func logSecretRequest(d Deps, chatID, persona *uuid.UUID, sec store.UserSecret, ck usersecrets.Checked, rawURL, decision string, status *int32, msg string, redactions int, took time.Duration) {
	if d.Q == nil {
		return
	}
	var method, host, path string
	if ck.URL != nil {
		method, host, path = ck.Method, ck.URL.Hostname(), ck.URL.EscapedPath()
	} else if u := parseLoose(rawURL); u != nil {
		host, path = u.Hostname(), u.EscapedPath()
	}
	if method == "" {
		method = http.MethodGet
	}
	_ = d.Q.LogUserSecretCall(context.Background(), store.LogUserSecretCallParams{
		SecretID:   sec.ID,
		ChatID:     chatID,
		PersonaID:  persona,
		Method:     method,
		Host:       host,
		Path:       path,
		Decision:   decision,
		Status:     status,
		Error:      msg,
		Redactions: int32(redactions),
		DurationMs: int32(took.Milliseconds()),
	})
}

type ProposeSecretIn struct {
	Name   string `json:"name" jsonschema:"A short display name, 1–60 characters, e.g. Acme API JWT"`
	Host   string `json:"host" jsonschema:"The API host it should be sent to, e.g. api.acme.com"`
	SentAs string `json:"sent_as,omitempty" jsonschema:"How the API expects it: bearer (default), header, query or basic"`
	Key    string `json:"key,omitempty" jsonschema:"The header or query parameter name, for header and query"`
	Reason string `json:"reason,omitempty" jsonschema:"One sentence for the person on what you'll use it for, at most 500 characters"`
}

var proposeSecret = define("propose_secret", "Ask the person to add an API secret (a token or key) for you to use with http_request. They enter the value in Vesper, never in chat, and approve which host gets it. Never ask for the value in chat.",
	func(ctx context.Context, d Deps, c agents.Caller, in ProposeSecretIn) (any, error) {
		s, err := chatScopeFor(ctx, d, c)
		if err != nil {
			return nil, err
		}
		if s == nil || s.PersonaID == nil {
			return nil, apperr.Conflict("propose_secret only works in a chat with a persona")
		}
		p, err := d.Q.GetPersona(ctx, store.GetPersonaParams{ID: *s.PersonaID, WorkspaceID: c.Agent.WorkspaceID, UserID: s.UserID})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanCreateConnectors) {
			return nil, apperr.Conflict("This persona can't propose secrets; tell the person it isn't enabled in Manage personas.")
		}
		if err != nil {
			return nil, err
		}
		name, err := usersecrets.ValidName(in.Name)
		if err != nil {
			return nil, err
		}
		host, err := usersecrets.NormalizeHost(in.Host)
		if err != nil {
			return nil, apperr.Invalid("host", "enter one hostname, like api.example.com")
		}
		placement := in.SentAs
		if placement == "" {
			placement = usersecrets.PlacementBearer
		}
		key, err := usersecrets.ValidPlacement(placement, in.Key)
		if err != nil {
			return nil, err
		}
		reason := strings.TrimSpace(in.Reason)
		if len([]rune(reason)) > 500 {
			return nil, apperr.Invalid("reason", "must be at most 500 characters")
		}
		n, err := d.Q.CountPendingUserSecretProposals(ctx, s.ChatID)
		if err != nil {
			return nil, err
		}
		if n >= 3 {
			return nil, apperr.Conflict("the person already has secret requests waiting in this chat")
		}
		out, err := d.Q.CreateUserSecretProposal(ctx, store.CreateUserSecretProposalParams{ChatID: s.ChatID, RunID: *c.RunID, ProposedBy: s.PersonaID, Name: name, Host: host,
			Placement: placement, PlacementKey: key, Reason: reason})
		if err != nil {
			return nil, err
		}
		return map[string]any{"proposal_id": out.ID, "state": out.State, "tell_the_person": "Requested. The person sees a card in the chat to add the secret in Vesper. Don't ask for the value in chat, and don't describe it as added yet. Once they add it, it's available from your next message."}, nil
	})

package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

type customAppRunScope struct {
	workspaceID uuid.UUID
	userID      uuid.UUID
	chat        *store.ChatSession
	personaID   *uuid.UUID
}

func customAppForMCP(ctx context.Context, d Deps, c agents.Caller, rawSlug string) (customapps.MCPServerApp, customAppRunScope, error) {
	var app customapps.MCPServerApp
	var scope customAppRunScope
	if d.CustomApps == nil || c.RunID == nil {
		return app, scope, apperr.ErrNotFound
	}
	slug := strings.TrimPrefix(strings.TrimSpace(rawSlug), agentdef.CustomAppMCPPrefix)
	if _, err := customapps.ValidSlug(slug); err != nil {
		return app, scope, apperr.ErrNotFound
	}
	chat, err := d.Q.ChatSessionForRun(ctx, c.RunID)
	if err == nil {
		scope.workspaceID = chat.WorkspaceID
		scope.userID = chat.CreatedBy
		scope.chat = &chat
		scope.personaID = runs.ChatSpeakerID(chat)
	} else if errors.Is(err, pgx.ErrNoRows) {
		wfRun, werr := d.Q.WorkflowRunForAgentRun(ctx, c.RunID)
		if werr != nil {
			return app, scope, apperr.ErrNotFound
		}
		scope.workspaceID = wfRun.WorkspaceID
		scope.userID = wfRun.UserID
	} else {
		return app, scope, err
	}

	app, err = d.CustomApps.GetMCPServer(ctx, scope.workspaceID, scope.userID, slug)
	if err != nil || strings.TrimSpace(app.BundleMCPJS) == "" {
		return app, scope, apperr.ErrNotFound
	}

	if app.Manifest.ToolScope == customapps.ToolScopeAppOnly {
		if scope.chat == nil || scope.chat.SpaceID == nil {
			return app, scope, apperr.ErrNotFound
		}
		sp, err := d.Q.GetChatSpaceByID(ctx, *scope.chat.SpaceID)
		if err != nil || sp.UserID != scope.userID || sp.App == nil || *sp.App != "custom:"+app.Slug {
			return app, scope, apperr.ErrNotFound
		}
	}
	return app, scope, nil
}

// CustomAppMCPHandler serves each custom app's bundled MCP server at
// /mcp/connectors/app_<slug>. Every request enforces ownership, tool_scope
// (chats vs app_only), and per-app capabilities.
func CustomAppMCPHandler(d Deps, version string) http.Handler {
	h := mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
		info := auth.TokenInfoFromContext(r.Context())
		if info == nil {
			return nil
		}
		caller, _ := info.Extra[callerKey].(agents.Caller)
		app, scope, err := customAppForMCP(r.Context(), d, caller, r.PathValue("slug"))
		if err != nil {
			return nil
		}
		srv := mcp.NewServer(&mcp.Implementation{Name: agentdef.CustomAppMCPPrefix + app.Slug, Version: version}, nil)
		for _, t := range app.Tools {
			schema := t.InputSchema
			if schema == nil || schema["type"] != "object" {
				schema = map[string]any{"type": "object", "properties": map[string]any{}}
			}
			srv.AddTool(&mcp.Tool{Name: t.Name, Description: t.Description, InputSchema: schema}, customAppMCPTool(d, app, scope, t.Name))
		}
		return srv
	}, &mcp.StreamableHTTPOptions{Stateless: true, JSONResponse: true, DisableLocalhostProtection: true})
	return auth.RequireBearerToken(verifier(d), nil)(h)
}

func customAppMCPTool(d Deps, app customapps.MCPServerApp, scope customAppRunScope, toolName string) mcp.ToolHandler {
	return func(ctx context.Context, req *mcp.CallToolRequest) (*mcp.CallToolResult, error) {
		args := map[string]any{}
		if len(req.Params.Arguments) > 0 {
			if err := json.Unmarshal(req.Params.Arguments, &args); err != nil {
				return toolFailure("invalid arguments JSON"), nil
			}
		}

		var ownerUser store.User
		var ownerLoaded bool
		getOwner := func(uctx context.Context) (store.User, error) {
			if ownerLoaded {
				return ownerUser, nil
			}
			u, err := d.Q.GetUser(uctx, store.GetUserParams{ID: scope.userID, WorkspaceID: scope.workspaceID})
			if err != nil {
				return store.User{}, err
			}
			ownerUser = u
			ownerLoaded = true
			return u, nil
		}

		opts := customapps.MCPCallContext{
			Q:           d.Q,
			Secrets:     d.Secrets,
			Interactive: false,
		}
		if d.AppAPICall != nil {
			opts.APICall = func(actx context.Context, method, rawPath string, body any) (any, error) {
				u, err := getOwner(actx)
				if err != nil {
					return nil, err
				}
				return d.AppAPICall(actx, u, method, rawPath, body)
			}
		}
		if scope.chat != nil {
			chatID := scope.chat.ID
			opts.SecretApprover = func(sctx context.Context, sec store.UserSecret, ck usersecrets.Checked, sreq usersecrets.Request) error {
				refusal, err := requestSecretApproval(sctx, d, chatID, scope.personaID, sec, ck, sreq)
				if err != nil {
					return err
				}
				if refusal != "" {
					return errors.New(refusal)
				}
				return nil
			}
			opts.SecretLogger = func(lctx context.Context, sec store.UserSecret, ck usersecrets.Checked, sreq usersecrets.Request, decision string, status *int32, msg string, redactions int, took time.Duration) {
				if status != nil {
					_ = d.Q.TouchUserSecret(context.Background(), sec.ID)
				}
				logSecretRequest(d, &chatID, scope.personaID, sec, ck, sreq.URL, decision, status, msg, redactions, took)
			}
		}

		res, err := d.CustomApps.CallMCPTool(ctx, app, toolName, args, opts)
		if err != nil {
			return toolFailure(err.Error()), nil
		}
		if s, ok := res.(string); ok {
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: s}}}, nil
		}
		raw, _ := json.Marshal(res)
		return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(raw)}}}, nil
	}
}

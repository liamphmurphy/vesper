package agentapi

import (
	"context"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/httpclient"
)

func httpClientService(d Deps) *httpclient.Service {
	return &httpclient.Service{Q: d.Q, Secrets: d.Secrets}
}

type HTTPListWorkspacesIn struct{}

func httpListWorkspaces(ctx context.Context, d Deps, c agents.Caller, _ HTTPListWorkspacesIn) (any, error) {
	if _, err := requireChat(ctx, d, c); err != nil {
		return nil, err
	}
	list, err := httpClientService(d).ListWorkspaces(ctx, c.Agent.WorkspaceID)
	if err != nil {
		return nil, err
	}
	return map[string]any{"workspaces": list}, nil
}

type HTTPGetWorkspaceIn struct {
	WorkspaceID string `json:"workspace_id" jsonschema:"HTTP workspace UUID from http_list_workspaces"`
}

func httpGetWorkspace(ctx context.Context, d Deps, c agents.Caller, in HTTPGetWorkspaceIn) (any, error) {
	if _, err := requireChat(ctx, d, c); err != nil {
		return nil, err
	}
	id, err := uuid.Parse(strings.TrimSpace(in.WorkspaceID))
	if err != nil {
		return nil, apperr.Invalid("workspace_id", "must be a UUID")
	}
	return httpClientService(d).GetWorkspaceBundle(ctx, c.Agent.WorkspaceID, id)
}

type HTTPSaveRequestIn struct {
	RequestID   string                 `json:"request_id,omitempty" jsonschema:"Existing request UUID to update; omit to create a new request"`
	WorkspaceID string                 `json:"workspace_id" jsonschema:"HTTP workspace UUID"`
	FolderID    string                 `json:"folder_id,omitempty" jsonschema:"Optional folder UUID"`
	Name        string                 `json:"name" jsonschema:"Display name for the request"`
	Method      string                 `json:"method" jsonschema:"HTTP method (GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS)"`
	URL         string                 `json:"url" jsonschema:"Request URL, supporting {{variable}} placeholders"`
	Params      []httpclient.KeyValue  `json:"params,omitempty" jsonschema:"Optional query parameters"`
	Headers     []httpclient.KeyValue  `json:"headers,omitempty" jsonschema:"Optional request headers"`
	Auth        *httpclient.AuthConfig `json:"auth,omitempty" jsonschema:"Optional auth config (defaults to inherit from folder/workspace)"`
	BodyMode    string                 `json:"body_mode,omitempty" jsonschema:"none, json, raw, form_urlencoded, or multipart"`
	Body        string                 `json:"body,omitempty" jsonschema:"Request body text (for json or raw mode)"`
}

func httpSaveRequest(ctx context.Context, d Deps, c agents.Caller, in HTTPSaveRequestIn) (any, error) {
	if _, err := requireChat(ctx, d, c); err != nil {
		return nil, err
	}
	wsID, err := uuid.Parse(strings.TrimSpace(in.WorkspaceID))
	if err != nil {
		return nil, apperr.Invalid("workspace_id", "must be a UUID")
	}
	var folderID *uuid.UUID
	if strings.TrimSpace(in.FolderID) != "" {
		fid, err := uuid.Parse(strings.TrimSpace(in.FolderID))
		if err != nil {
			return nil, apperr.Invalid("folder_id", "must be a UUID")
		}
		folderID = &fid
	}
	auth := httpclient.AuthConfig{Type: httpclient.AuthInherit}
	if in.Auth != nil {
		auth = *in.Auth
	}
	reqIn := httpclient.RequestInput{
		FolderID: folderID,
		Name:     in.Name,
		Method:   in.Method,
		URL:      in.URL,
		Params:   in.Params,
		Headers:  in.Headers,
		Auth:     auth,
		BodyMode: in.BodyMode,
		Body:     in.Body,
	}
	svc := httpClientService(d)
	if strings.TrimSpace(in.RequestID) != "" {
		reqID, err := uuid.Parse(strings.TrimSpace(in.RequestID))
		if err != nil {
			return nil, apperr.Invalid("request_id", "must be a UUID")
		}
		return svc.UpdateRequest(ctx, c.Agent.WorkspaceID, reqID, reqIn)
	}
	return svc.CreateRequest(ctx, c.Agent.WorkspaceID, wsID, reqIn)
}

type HTTPRunRequestIn struct {
	RequestID     string `json:"request_id" jsonschema:"Saved HTTP request UUID"`
	EnvironmentID string `json:"environment_id,omitempty" jsonschema:"Optional environment UUID override (defaults to workspace active environment)"`
}

func httpRunRequest(ctx context.Context, d Deps, c agents.Caller, in HTTPRunRequestIn) (any, error) {
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	reqID, err := uuid.Parse(strings.TrimSpace(in.RequestID))
	if err != nil {
		return nil, apperr.Invalid("request_id", "must be a UUID")
	}
	var envID *uuid.UUID
	if strings.TrimSpace(in.EnvironmentID) != "" {
		eid, err := uuid.Parse(strings.TrimSpace(in.EnvironmentID))
		if err != nil {
			return nil, apperr.Invalid("environment_id", "must be a UUID")
		}
		envID = &eid
	}
	return httpClientService(d).RunSavedRequest(ctx, c.Agent.WorkspaceID, s.UserID, reqID, httpclient.RunOptions{
		EnvironmentID: envID,
	})
}

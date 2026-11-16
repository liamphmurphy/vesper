// Package httpclient stores HTTP workspaces, environments, folders, requests,
// and execution history, resolves workspace/folder inheritance and variables,
// imports Bruno/OpenAPI/cURL collections, and executes SSRF-guarded external HTTP calls.
package httpclient

import (
	"encoding/json"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Auth types supported at workspace, folder, and request levels.
const (
	AuthInherit = "inherit"
	AuthNone    = "none"
	AuthBearer  = "bearer"
	AuthBasic   = "basic"
	AuthAPIKey  = "apikey"
	AuthOAuth2  = "oauth2"
)

// APIKeyIn specifies where an API key is placed.
const (
	APIKeyInHeader = "header"
	APIKeyInQuery  = "query"
)

// Body modes supported by requests.
const (
	BodyNone           = "none"
	BodyJSON           = "json"
	BodyRaw            = "raw"
	BodyFormURLEncoded = "form_urlencoded"
	BodyMultipart      = "multipart"
)

// KeyValue is a toggleable key-value pair for headers, query params, or form fields.
type KeyValue struct {
	Key     string `json:"key"`
	Value   string `json:"value"`
	Enabled bool   `json:"enabled"`
}

// EnvVar is a workspace or environment variable. When SecretHandle is non-empty,
// Value is ignored during execution and resolved from user_secrets by handle.
type EnvVar struct {
	Key          string `json:"key"`
	Value        string `json:"value"`
	SecretHandle string `json:"secret_handle,omitempty"`
	Enabled      bool   `json:"enabled"`
}

// OAuth2Config configures OAuth 2.0 client_credentials token fetching.
type OAuth2Config struct {
	GrantType    string `json:"grant_type,omitempty"`
	TokenURL     string `json:"token_url,omitempty"`
	ClientID     string `json:"client_id,omitempty"`
	ClientSecret string `json:"client_secret,omitempty"`
	Scope        string `json:"scope,omitempty"`
	Audience     string `json:"audience,omitempty"`
}

// AuthConfig configures authentication for a workspace, folder, or request.
type AuthConfig struct {
	Type        string        `json:"type"`
	Token       string        `json:"token,omitempty"`
	Username    string        `json:"username,omitempty"`
	Password    string        `json:"password,omitempty"`
	APIKeyName  string        `json:"api_key_name,omitempty"`
	APIKeyValue string        `json:"api_key_value,omitempty"`
	APIKeyIn    string        `json:"api_key_in,omitempty"`
	OAuth2      *OAuth2Config `json:"oauth2,omitempty"`
}

// Workspace is a collection of HTTP calls, environments, and shared defaults for one app.
type Workspace struct {
	ID                  uuid.UUID  `json:"id"`
	Name                string     `json:"name"`
	Description         string     `json:"description"`
	ActiveEnvironmentID *uuid.UUID `json:"active_environment_id"`
	DefaultAuth         AuthConfig `json:"default_auth"`
	DefaultHeaders      []KeyValue `json:"default_headers"`
	DefaultVars         []EnvVar   `json:"default_vars"`
	CreatedAt           time.Time  `json:"created_at"`
	UpdatedAt           time.Time  `json:"updated_at"`
}

// Environment holds environment-specific variables (e.g. nonprod, prod).
type Environment struct {
	ID              uuid.UUID `json:"id"`
	HTTPWorkspaceID uuid.UUID `json:"http_workspace_id"`
	Name            string    `json:"name"`
	Color           string    `json:"color"`
	Variables       []EnvVar  `json:"variables"`
	SortOrder       int       `json:"sort_order"`
	CreatedAt       time.Time `json:"created_at"`
	UpdatedAt       time.Time `json:"updated_at"`
}

// Folder groups HTTP requests and can override or inherit workspace defaults.
type Folder struct {
	ID              uuid.UUID  `json:"id"`
	HTTPWorkspaceID uuid.UUID  `json:"http_workspace_id"`
	ParentFolderID  *uuid.UUID `json:"parent_folder_id"`
	Name            string     `json:"name"`
	DefaultAuth     AuthConfig `json:"default_auth"`
	DefaultHeaders  []KeyValue `json:"default_headers"`
	SortOrder       int        `json:"sort_order"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

// Request is a saved HTTP call inside a workspace (and optional folder).
type Request struct {
	ID              uuid.UUID  `json:"id"`
	HTTPWorkspaceID uuid.UUID  `json:"http_workspace_id"`
	FolderID        *uuid.UUID `json:"folder_id"`
	Name            string     `json:"name"`
	Method          string     `json:"method"`
	URL             string     `json:"url"`
	Params          []KeyValue `json:"params"`
	Headers         []KeyValue `json:"headers"`
	Auth            AuthConfig `json:"auth"`
	BodyMode        string     `json:"body_mode"`
	Body            string     `json:"body"`
	BodyForm        []KeyValue `json:"body_form"`
	TimeoutMS       int        `json:"timeout_ms"`
	FollowRedirects bool       `json:"follow_redirects"`
	SortOrder       int        `json:"sort_order"`
	CreatedAt       time.Time  `json:"created_at"`
	UpdatedAt       time.Time  `json:"updated_at"`
}

// Execution records one server-side HTTP call and its masked response.
type Execution struct {
	ID                uuid.UUID           `json:"id"`
	HTTPWorkspaceID   uuid.UUID           `json:"http_workspace_id"`
	RequestID         *uuid.UUID          `json:"request_id"`
	EnvironmentID     *uuid.UUID          `json:"environment_id"`
	EnvironmentName   string              `json:"environment_name"`
	Method            string              `json:"method"`
	ResolvedURL       string              `json:"resolved_url"`
	RequestHeaders    map[string]string   `json:"request_headers"`
	RequestBody       string              `json:"request_body"`
	StatusCode        int                 `json:"status_code"`
	StatusText        string              `json:"status_text"`
	DurationMS        int                 `json:"duration_ms"`
	SizeBytes         int                 `json:"size_bytes"`
	ResponseHeaders   map[string][]string `json:"response_headers"`
	ResponseBody      string              `json:"response_body"`
	ResponseTruncated bool                `json:"response_truncated"`
	Error             string              `json:"error,omitempty"`
	CreatedAt         time.Time           `json:"created_at"`
}

// WorkspaceBundle is the full state for one HTTP workspace.
type WorkspaceBundle struct {
	Workspace    Workspace     `json:"workspace"`
	Environments []Environment `json:"environments"`
	Folders      []Folder      `json:"folders"`
	Requests     []Request     `json:"requests"`
}

func decodeJSON[T any](raw json.RawMessage, fallback T) T {
	if len(raw) == 0 {
		return fallback
	}
	var v T
	if err := json.Unmarshal(raw, &v); err != nil {
		return fallback
	}
	return v
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		return json.RawMessage("null")
	}
	return b
}

func workspaceFromRow(r store.HttpWorkspace) Workspace {
	auth := decodeJSON(r.DefaultAuth, AuthConfig{Type: AuthNone})
	if auth.Type == "" {
		auth.Type = AuthNone
	}
	hdrs := decodeJSON(r.DefaultHeaders, []KeyValue{})
	if hdrs == nil {
		hdrs = []KeyValue{}
	}
	vars := decodeJSON(r.DefaultVars, []EnvVar{})
	if vars == nil {
		vars = []EnvVar{}
	}
	return Workspace{
		ID:                  r.ID,
		Name:                r.Name,
		Description:         r.Description,
		ActiveEnvironmentID: r.ActiveEnvironmentID,
		DefaultAuth:         auth,
		DefaultHeaders:      hdrs,
		DefaultVars:         vars,
		CreatedAt:           r.CreatedAt,
		UpdatedAt:           r.UpdatedAt,
	}
}

func envFromRow(r store.HttpEnvironment) Environment {
	vars := decodeJSON(r.Variables, []EnvVar{})
	if vars == nil {
		vars = []EnvVar{}
	}
	return Environment{
		ID:              r.ID,
		HTTPWorkspaceID: r.HttpWorkspaceID,
		Name:            r.Name,
		Color:           r.Color,
		Variables:       vars,
		SortOrder:       int(r.SortOrder),
		CreatedAt:       r.CreatedAt,
		UpdatedAt:       r.UpdatedAt,
	}
}

func folderFromRow(r store.HttpFolder) Folder {
	auth := decodeJSON(r.DefaultAuth, AuthConfig{Type: AuthInherit})
	if auth.Type == "" {
		auth.Type = AuthInherit
	}
	hdrs := decodeJSON(r.DefaultHeaders, []KeyValue{})
	if hdrs == nil {
		hdrs = []KeyValue{}
	}
	return Folder{
		ID:              r.ID,
		HTTPWorkspaceID: r.HttpWorkspaceID,
		ParentFolderID:  r.ParentFolderID,
		Name:            r.Name,
		DefaultAuth:     auth,
		DefaultHeaders:  hdrs,
		SortOrder:       int(r.SortOrder),
		CreatedAt:       r.CreatedAt,
		UpdatedAt:       r.UpdatedAt,
	}
}

func requestFromRow(r store.HttpRequest) Request {
	auth := decodeJSON(r.Auth, AuthConfig{Type: AuthInherit})
	if auth.Type == "" {
		auth.Type = AuthInherit
	}
	params := decodeJSON(r.Params, []KeyValue{})
	if params == nil {
		params = []KeyValue{}
	}
	hdrs := decodeJSON(r.Headers, []KeyValue{})
	if hdrs == nil {
		hdrs = []KeyValue{}
	}
	form := decodeJSON(r.BodyForm, []KeyValue{})
	if form == nil {
		form = []KeyValue{}
	}
	return Request{
		ID:              r.ID,
		HTTPWorkspaceID: r.HttpWorkspaceID,
		FolderID:        r.FolderID,
		Name:            r.Name,
		Method:          r.Method,
		URL:             r.Url,
		Params:          params,
		Headers:         hdrs,
		Auth:            auth,
		BodyMode:        r.BodyMode,
		Body:            r.Body,
		BodyForm:        form,
		TimeoutMS:       int(r.TimeoutMs),
		FollowRedirects: r.FollowRedirects,
		SortOrder:       int(r.SortOrder),
		CreatedAt:       r.CreatedAt,
		UpdatedAt:       r.UpdatedAt,
	}
}

func executionFromRow(r store.HttpExecution) Execution {
	reqHdrs := decodeJSON(r.RequestHeaders, map[string]string{})
	if reqHdrs == nil {
		reqHdrs = map[string]string{}
	}
	respHdrs := decodeJSON(r.ResponseHeaders, map[string][]string{})
	if respHdrs == nil {
		respHdrs = map[string][]string{}
	}
	return Execution{
		ID:                r.ID,
		HTTPWorkspaceID:   r.HttpWorkspaceID,
		RequestID:         r.RequestID,
		EnvironmentID:     r.EnvironmentID,
		EnvironmentName:   r.EnvironmentName,
		Method:            r.Method,
		ResolvedURL:       r.ResolvedUrl,
		RequestHeaders:    reqHdrs,
		RequestBody:       r.RequestBody,
		StatusCode:        int(r.StatusCode),
		StatusText:        r.StatusText,
		DurationMS:        int(r.DurationMs),
		SizeBytes:         int(r.SizeBytes),
		ResponseHeaders:   respHdrs,
		ResponseBody:      r.ResponseBody,
		ResponseTruncated: r.ResponseTruncated,
		Error:             r.Error,
		CreatedAt:         r.CreatedAt,
	}
}

package httpclient

import (
	"context"
	"errors"
	"net"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	defaultTimeoutMS = 30000
	minTimeoutMS     = 100
	maxTimeoutMS     = 120000
	maxExecLimit     = 100
)

var (
	validMethods  = []string{"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"}
	validBodyMode = []string{BodyNone, BodyJSON, BodyRaw, BodyFormURLEncoded, BodyMultipart}
	validColors   = []string{"green", "amber", "red", "blue", "purple", "gray"}
)

// Service manages HTTP workspaces, environments, folders, requests, and execution.
type Service struct {
	Q        *store.Queries
	Secrets  *usersecrets.Service
	LookupIP func(ctx context.Context, host string) ([]net.IP, error)
	Now      func() time.Time
	HTTP     http.RoundTripper

	oauthMu    sync.Mutex
	oauthCache map[string]cachedOAuthToken
}

type cachedOAuthToken struct {
	Token     string
	ExpiresAt time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// WorkspaceInput creates or updates an HTTP workspace.
type WorkspaceInput struct {
	Name                string     `json:"name"`
	Description         string     `json:"description"`
	ActiveEnvironmentID *uuid.UUID `json:"active_environment_id"`
	DefaultAuth         AuthConfig `json:"default_auth"`
	DefaultHeaders      []KeyValue `json:"default_headers"`
	DefaultVars         []EnvVar   `json:"default_vars"`
	SeedEnvironments    bool       `json:"seed_environments,omitempty"`
}

// EnvironmentInput creates or updates an HTTP environment.
type EnvironmentInput struct {
	Name      string   `json:"name"`
	Color     string   `json:"color"`
	Variables []EnvVar `json:"variables"`
	SortOrder int      `json:"sort_order"`
}

// FolderInput creates or updates an HTTP folder.
type FolderInput struct {
	ParentFolderID *uuid.UUID `json:"parent_folder_id"`
	Name           string     `json:"name"`
	DefaultAuth    AuthConfig `json:"default_auth"`
	DefaultHeaders []KeyValue `json:"default_headers"`
	SortOrder      int        `json:"sort_order"`
}

// RequestInput creates or updates an HTTP request.
type RequestInput struct {
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
	FollowRedirects *bool      `json:"follow_redirects"`
	SortOrder       int        `json:"sort_order"`
}

func validName(field, raw string, maxLen int) (string, error) {
	v := strings.TrimSpace(raw)
	if v == "" || len(v) > maxLen {
		return "", apperr.Invalid(field, "must be 1-%d characters", maxLen)
	}
	return v, nil
}

func validAuth(a AuthConfig, allowInherit bool) (AuthConfig, error) {
	t := strings.ToLower(strings.TrimSpace(a.Type))
	if t == "" {
		if allowInherit {
			t = AuthInherit
		} else {
			t = AuthNone
		}
	}
	switch t {
	case AuthInherit:
		if !allowInherit {
			return a, apperr.Invalid("auth.type", "workspace default auth cannot be inherit")
		}
	case AuthNone, AuthBearer, AuthBasic:
	case AuthAPIKey:
		in := strings.ToLower(strings.TrimSpace(a.APIKeyIn))
		if in == "" {
			in = APIKeyInHeader
		}
		if in != APIKeyInHeader && in != APIKeyInQuery {
			return a, apperr.Invalid("auth.api_key_in", "must be header or query")
		}
		a.APIKeyIn = in
	case AuthOAuth2:
		if a.OAuth2 == nil {
			a.OAuth2 = &OAuth2Config{GrantType: "client_credentials"}
		}
		if a.OAuth2.GrantType == "" {
			a.OAuth2.GrantType = "client_credentials"
		}
		if a.OAuth2.GrantType != "client_credentials" {
			return a, apperr.Invalid("auth.oauth2.grant_type", "only client_credentials is supported")
		}
	default:
		return a, apperr.Invalid("auth.type", "must be inherit, none, bearer, basic, apikey, or oauth2")
	}
	a.Type = t
	return a, nil
}

func cleanKeyValues(in []KeyValue) []KeyValue {
	if in == nil {
		return []KeyValue{}
	}
	out := make([]KeyValue, len(in))
	copy(out, in)
	return out
}

func cleanEnvVars(in []EnvVar) []EnvVar {
	if in == nil {
		return []EnvVar{}
	}
	out := make([]EnvVar, len(in))
	for i, v := range in {
		v.Key = strings.TrimSpace(v.Key)
		v.SecretHandle = strings.TrimSpace(v.SecretHandle)
		out[i] = v
	}
	return out
}

func normalizeMethod(raw string) (string, error) {
	m := strings.ToUpper(strings.TrimSpace(raw))
	if m == "" {
		m = "GET"
	}
	if !slices.Contains(validMethods, m) {
		return "", apperr.Invalid("method", "must be one of %s", strings.Join(validMethods, ", "))
	}
	return m, nil
}

func normalizeBodyMode(raw string) (string, error) {
	m := strings.ToLower(strings.TrimSpace(raw))
	if m == "" {
		m = BodyNone
	}
	if !slices.Contains(validBodyMode, m) {
		return "", apperr.Invalid("body_mode", "must be one of %s", strings.Join(validBodyMode, ", "))
	}
	return m, nil
}

func normalizeEnvColor(raw string) string {
	c := strings.ToLower(strings.TrimSpace(raw))
	if slices.Contains(validColors, c) {
		return c
	}
	return "green"
}

func mapNotFound(err error) error {
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound
	}
	return err
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

// ListWorkspaces returns all HTTP workspaces belonging to the Vesper workspace.
func (s *Service) ListWorkspaces(ctx context.Context, ws uuid.UUID) ([]Workspace, error) {
	rows, err := s.Q.ListHTTPWorkspaces(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := make([]Workspace, len(rows))
	for i, r := range rows {
		out[i] = workspaceFromRow(r)
	}
	return out, nil
}

// GetWorkspaceBundle returns the workspace plus its environments, folders, and requests.
func (s *Service) GetWorkspaceBundle(ctx context.Context, ws, id uuid.UUID) (WorkspaceBundle, error) {
	var out WorkspaceBundle
	row, err := s.Q.GetHTTPWorkspace(ctx, store.GetHTTPWorkspaceParams{ID: id, WorkspaceID: ws})
	if err != nil {
		return out, mapNotFound(err)
	}
	out.Workspace = workspaceFromRow(row)

	envRows, err := s.Q.ListHTTPEnvironments(ctx, id)
	if err != nil {
		return out, err
	}
	out.Environments = make([]Environment, len(envRows))
	for i, e := range envRows {
		out.Environments[i] = envFromRow(e)
	}

	folderRows, err := s.Q.ListHTTPFolders(ctx, id)
	if err != nil {
		return out, err
	}
	out.Folders = make([]Folder, len(folderRows))
	for i, f := range folderRows {
		out.Folders[i] = folderFromRow(f)
	}

	reqRows, err := s.Q.ListHTTPRequests(ctx, id)
	if err != nil {
		return out, err
	}
	out.Requests = make([]Request, len(reqRows))
	for i, r := range reqRows {
		out.Requests[i] = requestFromRow(r)
	}
	return out, nil
}

// CreateWorkspace creates a new HTTP workspace, optionally seeding nonprod/prod environments.
func (s *Service) CreateWorkspace(ctx context.Context, ws, user uuid.UUID, in WorkspaceInput) (WorkspaceBundle, error) {
	var out WorkspaceBundle
	name, err := validName("name", in.Name, 120)
	if err != nil {
		return out, err
	}
	auth, err := validAuth(in.DefaultAuth, false)
	if err != nil {
		return out, err
	}
	row, err := s.Q.CreateHTTPWorkspace(ctx, store.CreateHTTPWorkspaceParams{
		WorkspaceID:    ws,
		UserID:         user,
		Name:           name,
		Description:    strings.TrimSpace(in.Description),
		DefaultAuth:    mustJSON(auth),
		DefaultHeaders: mustJSON(cleanKeyValues(in.DefaultHeaders)),
		DefaultVars:    mustJSON(cleanEnvVars(in.DefaultVars)),
	})
	if err != nil {
		return out, err
	}
	if in.SeedEnvironments {
		nonprod, err := s.Q.CreateHTTPEnvironment(ctx, store.CreateHTTPEnvironmentParams{
			HttpWorkspaceID: row.ID,
			Name:            "nonprod",
			Color:           "green",
			Variables:       mustJSON([]EnvVar{{Key: "base_url", Value: "https://api.nonprod.example.com", Enabled: true}}),
			SortOrder:       0,
		})
		if err != nil {
			return out, err
		}
		if _, err := s.Q.CreateHTTPEnvironment(ctx, store.CreateHTTPEnvironmentParams{
			HttpWorkspaceID: row.ID,
			Name:            "prod",
			Color:           "red",
			Variables:       mustJSON([]EnvVar{{Key: "base_url", Value: "https://api.example.com", Enabled: true}}),
			SortOrder:       1,
		}); err != nil {
			return out, err
		}
		if _, err := s.Q.SetHTTPWorkspaceActiveEnvironment(ctx, store.SetHTTPWorkspaceActiveEnvironmentParams{
			ID:                  row.ID,
			WorkspaceID:         ws,
			ActiveEnvironmentID: &nonprod.ID,
		}); err != nil {
			return out, err
		}
	}
	return s.GetWorkspaceBundle(ctx, ws, row.ID)
}

// UpdateWorkspace updates an HTTP workspace's metadata, defaults, or active environment.
func (s *Service) UpdateWorkspace(ctx context.Context, ws, id uuid.UUID, in WorkspaceInput) (Workspace, error) {
	var out Workspace
	name, err := validName("name", in.Name, 120)
	if err != nil {
		return out, err
	}
	auth, err := validAuth(in.DefaultAuth, false)
	if err != nil {
		return out, err
	}
	if in.ActiveEnvironmentID != nil {
		env, err := s.Q.GetHTTPEnvironment(ctx, store.GetHTTPEnvironmentParams{ID: *in.ActiveEnvironmentID, WorkspaceID: ws})
		if err != nil {
			return out, apperr.Invalid("active_environment_id", "unknown environment")
		}
		if env.HttpWorkspaceID != id {
			return out, apperr.Invalid("active_environment_id", "environment belongs to another workspace")
		}
	}
	row, err := s.Q.UpdateHTTPWorkspace(ctx, store.UpdateHTTPWorkspaceParams{
		ID:                  id,
		WorkspaceID:         ws,
		Name:                name,
		Description:         strings.TrimSpace(in.Description),
		ActiveEnvironmentID: in.ActiveEnvironmentID,
		DefaultAuth:         mustJSON(auth),
		DefaultHeaders:      mustJSON(cleanKeyValues(in.DefaultHeaders)),
		DefaultVars:         mustJSON(cleanEnvVars(in.DefaultVars)),
	})
	if err != nil {
		return out, mapNotFound(err)
	}
	return workspaceFromRow(row), nil
}

// SetActiveEnvironment switches the active environment for a workspace.
func (s *Service) SetActiveEnvironment(ctx context.Context, ws, id uuid.UUID, envID *uuid.UUID) (Workspace, error) {
	var out Workspace
	if envID != nil {
		env, err := s.Q.GetHTTPEnvironment(ctx, store.GetHTTPEnvironmentParams{ID: *envID, WorkspaceID: ws})
		if err != nil {
			return out, apperr.Invalid("environment_id", "unknown environment")
		}
		if env.HttpWorkspaceID != id {
			return out, apperr.Invalid("environment_id", "environment belongs to another workspace")
		}
	}
	row, err := s.Q.SetHTTPWorkspaceActiveEnvironment(ctx, store.SetHTTPWorkspaceActiveEnvironmentParams{
		ID:                  id,
		WorkspaceID:         ws,
		ActiveEnvironmentID: envID,
	})
	if err != nil {
		return out, mapNotFound(err)
	}
	return workspaceFromRow(row), nil
}

// DeleteWorkspace deletes an HTTP workspace and all its children.
func (s *Service) DeleteWorkspace(ctx context.Context, ws, id uuid.UUID) error {
	n, err := s.Q.DeleteHTTPWorkspace(ctx, store.DeleteHTTPWorkspaceParams{ID: id, WorkspaceID: ws})
	if err != nil {
		return err
	}
	if n == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// CreateEnvironment creates an environment inside a workspace.
func (s *Service) CreateEnvironment(ctx context.Context, ws, httpWS uuid.UUID, in EnvironmentInput) (Environment, error) {
	var out Environment
	if _, err := s.Q.GetHTTPWorkspace(ctx, store.GetHTTPWorkspaceParams{ID: httpWS, WorkspaceID: ws}); err != nil {
		return out, mapNotFound(err)
	}
	name, err := validName("name", in.Name, 80)
	if err != nil {
		return out, err
	}
	row, err := s.Q.CreateHTTPEnvironment(ctx, store.CreateHTTPEnvironmentParams{
		HttpWorkspaceID: httpWS,
		Name:            name,
		Color:           normalizeEnvColor(in.Color),
		Variables:       mustJSON(cleanEnvVars(in.Variables)),
		SortOrder:       int32(in.SortOrder),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return out, apperr.ConflictField("name", "environment %q already exists", name)
		}
		return out, err
	}
	return envFromRow(row), nil
}

// UpdateEnvironment updates an environment's name, color, or variables.
func (s *Service) UpdateEnvironment(ctx context.Context, ws, envID uuid.UUID, in EnvironmentInput) (Environment, error) {
	var out Environment
	name, err := validName("name", in.Name, 80)
	if err != nil {
		return out, err
	}
	row, err := s.Q.UpdateHTTPEnvironment(ctx, store.UpdateHTTPEnvironmentParams{
		ID:          envID,
		WorkspaceID: ws,
		Name:        name,
		Color:       normalizeEnvColor(in.Color),
		Variables:   mustJSON(cleanEnvVars(in.Variables)),
		SortOrder:   int32(in.SortOrder),
	})
	if err != nil {
		if isUniqueViolation(err) {
			return out, apperr.ConflictField("name", "environment %q already exists", name)
		}
		return out, mapNotFound(err)
	}
	return envFromRow(row), nil
}

// DeleteEnvironment removes an environment from its workspace.
func (s *Service) DeleteEnvironment(ctx context.Context, ws, envID uuid.UUID) error {
	n, err := s.Q.DeleteHTTPEnvironment(ctx, store.DeleteHTTPEnvironmentParams{ID: envID, WorkspaceID: ws})
	if err != nil {
		return err
	}
	if n == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

func (s *Service) checkParentFolder(ctx context.Context, ws, httpWS uuid.UUID, selfID, parentID *uuid.UUID) error {
	if parentID == nil {
		return nil
	}
	if selfID != nil && *selfID == *parentID {
		return apperr.Invalid("parent_folder_id", "folder cannot be its own parent")
	}
	rows, err := s.Q.ListHTTPFolders(ctx, httpWS)
	if err != nil {
		return err
	}
	byID := make(map[uuid.UUID]store.HttpFolder, len(rows))
	for _, r := range rows {
		byID[r.ID] = r
	}
	cur := parentID
	for depth := 0; cur != nil; depth++ {
		if depth > 64 {
			return apperr.Invalid("parent_folder_id", "folder hierarchy cycle")
		}
		f, ok := byID[*cur]
		if !ok {
			return apperr.Invalid("parent_folder_id", "parent folder not in this workspace")
		}
		if selfID != nil && f.ID == *selfID {
			return apperr.Invalid("parent_folder_id", "folder hierarchy cannot contain a cycle")
		}
		cur = f.ParentFolderID
	}
	return nil
}

// CreateFolder creates a folder inside a workspace.
func (s *Service) CreateFolder(ctx context.Context, ws, httpWS uuid.UUID, in FolderInput) (Folder, error) {
	var out Folder
	if _, err := s.Q.GetHTTPWorkspace(ctx, store.GetHTTPWorkspaceParams{ID: httpWS, WorkspaceID: ws}); err != nil {
		return out, mapNotFound(err)
	}
	name, err := validName("name", in.Name, 120)
	if err != nil {
		return out, err
	}
	auth, err := validAuth(in.DefaultAuth, true)
	if err != nil {
		return out, err
	}
	if err := s.checkParentFolder(ctx, ws, httpWS, nil, in.ParentFolderID); err != nil {
		return out, err
	}
	row, err := s.Q.CreateHTTPFolder(ctx, store.CreateHTTPFolderParams{
		HttpWorkspaceID: httpWS,
		ParentFolderID:  in.ParentFolderID,
		Name:            name,
		DefaultAuth:     mustJSON(auth),
		DefaultHeaders:  mustJSON(cleanKeyValues(in.DefaultHeaders)),
		SortOrder:       int32(in.SortOrder),
	})
	if err != nil {
		return out, err
	}
	return folderFromRow(row), nil
}

// UpdateFolder updates a folder's metadata, parent, or defaults.
func (s *Service) UpdateFolder(ctx context.Context, ws, folderID uuid.UUID, in FolderInput) (Folder, error) {
	var out Folder
	existing, err := s.Q.GetHTTPFolder(ctx, store.GetHTTPFolderParams{ID: folderID, WorkspaceID: ws})
	if err != nil {
		return out, mapNotFound(err)
	}
	name, err := validName("name", in.Name, 120)
	if err != nil {
		return out, err
	}
	auth, err := validAuth(in.DefaultAuth, true)
	if err != nil {
		return out, err
	}
	if err := s.checkParentFolder(ctx, ws, existing.HttpWorkspaceID, &folderID, in.ParentFolderID); err != nil {
		return out, err
	}
	row, err := s.Q.UpdateHTTPFolder(ctx, store.UpdateHTTPFolderParams{
		ID:             folderID,
		WorkspaceID:    ws,
		ParentFolderID: in.ParentFolderID,
		Name:           name,
		DefaultAuth:    mustJSON(auth),
		DefaultHeaders: mustJSON(cleanKeyValues(in.DefaultHeaders)),
		SortOrder:      int32(in.SortOrder),
	})
	if err != nil {
		return out, mapNotFound(err)
	}
	return folderFromRow(row), nil
}

// DeleteFolder deletes a folder and its nested requests/subfolders.
func (s *Service) DeleteFolder(ctx context.Context, ws, folderID uuid.UUID) error {
	n, err := s.Q.DeleteHTTPFolder(ctx, store.DeleteHTTPFolderParams{ID: folderID, WorkspaceID: ws})
	if err != nil {
		return err
	}
	if n == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// CreateRequest creates a saved HTTP request inside a workspace.
func (s *Service) CreateRequest(ctx context.Context, ws, httpWS uuid.UUID, in RequestInput) (Request, error) {
	var out Request
	if _, err := s.Q.GetHTTPWorkspace(ctx, store.GetHTTPWorkspaceParams{ID: httpWS, WorkspaceID: ws}); err != nil {
		return out, mapNotFound(err)
	}
	if in.FolderID != nil {
		f, err := s.Q.GetHTTPFolder(ctx, store.GetHTTPFolderParams{ID: *in.FolderID, WorkspaceID: ws})
		if err != nil || f.HttpWorkspaceID != httpWS {
			return out, apperr.Invalid("folder_id", "unknown folder in this workspace")
		}
	}
	name, err := validName("name", in.Name, 160)
	if err != nil {
		return out, err
	}
	method, err := normalizeMethod(in.Method)
	if err != nil {
		return out, err
	}
	bodyMode, err := normalizeBodyMode(in.BodyMode)
	if err != nil {
		return out, err
	}
	auth, err := validAuth(in.Auth, true)
	if err != nil {
		return out, err
	}
	timeout := clampTimeout(in.TimeoutMS)
	follow := true
	if in.FollowRedirects != nil {
		follow = *in.FollowRedirects
	}
	row, err := s.Q.CreateHTTPRequest(ctx, store.CreateHTTPRequestParams{
		HttpWorkspaceID: httpWS,
		FolderID:        in.FolderID,
		Name:            name,
		Method:          method,
		Url:             strings.TrimSpace(in.URL),
		Params:          mustJSON(cleanKeyValues(in.Params)),
		Headers:         mustJSON(cleanKeyValues(in.Headers)),
		Auth:            mustJSON(auth),
		BodyMode:        bodyMode,
		Body:            in.Body,
		BodyForm:        mustJSON(cleanKeyValues(in.BodyForm)),
		TimeoutMs:       int32(timeout),
		FollowRedirects: follow,
		SortOrder:       int32(in.SortOrder),
	})
	if err != nil {
		return out, err
	}
	return requestFromRow(row), nil
}

// UpdateRequest updates a saved HTTP request.
func (s *Service) UpdateRequest(ctx context.Context, ws, reqID uuid.UUID, in RequestInput) (Request, error) {
	var out Request
	existing, err := s.Q.GetHTTPRequest(ctx, store.GetHTTPRequestParams{ID: reqID, WorkspaceID: ws})
	if err != nil {
		return out, mapNotFound(err)
	}
	if in.FolderID != nil {
		f, err := s.Q.GetHTTPFolder(ctx, store.GetHTTPFolderParams{ID: *in.FolderID, WorkspaceID: ws})
		if err != nil || f.HttpWorkspaceID != existing.HttpWorkspaceID {
			return out, apperr.Invalid("folder_id", "unknown folder in this workspace")
		}
	}
	name, err := validName("name", in.Name, 160)
	if err != nil {
		return out, err
	}
	method, err := normalizeMethod(in.Method)
	if err != nil {
		return out, err
	}
	bodyMode, err := normalizeBodyMode(in.BodyMode)
	if err != nil {
		return out, err
	}
	auth, err := validAuth(in.Auth, true)
	if err != nil {
		return out, err
	}
	timeout := clampTimeout(in.TimeoutMS)
	follow := existing.FollowRedirects
	if in.FollowRedirects != nil {
		follow = *in.FollowRedirects
	}
	row, err := s.Q.UpdateHTTPRequest(ctx, store.UpdateHTTPRequestParams{
		ID:              reqID,
		WorkspaceID:     ws,
		FolderID:        in.FolderID,
		Name:            name,
		Method:          method,
		Url:             strings.TrimSpace(in.URL),
		Params:          mustJSON(cleanKeyValues(in.Params)),
		Headers:         mustJSON(cleanKeyValues(in.Headers)),
		Auth:            mustJSON(auth),
		BodyMode:        bodyMode,
		Body:            in.Body,
		BodyForm:        mustJSON(cleanKeyValues(in.BodyForm)),
		TimeoutMs:       int32(timeout),
		FollowRedirects: follow,
		SortOrder:       int32(in.SortOrder),
	})
	if err != nil {
		return out, mapNotFound(err)
	}
	return requestFromRow(row), nil
}

// DeleteRequest deletes a saved HTTP request.
func (s *Service) DeleteRequest(ctx context.Context, ws, reqID uuid.UUID) error {
	n, err := s.Q.DeleteHTTPRequest(ctx, store.DeleteHTTPRequestParams{ID: reqID, WorkspaceID: ws})
	if err != nil {
		return err
	}
	if n == 0 {
		return apperr.ErrNotFound
	}
	return nil
}

// ListExecutionsByWorkspace returns recent HTTP execution logs for a workspace.
func (s *Service) ListExecutionsByWorkspace(ctx context.Context, ws, httpWS uuid.UUID, limit int) ([]Execution, error) {
	if _, err := s.Q.GetHTTPWorkspace(ctx, store.GetHTTPWorkspaceParams{ID: httpWS, WorkspaceID: ws}); err != nil {
		return nil, mapNotFound(err)
	}
	if limit <= 0 || limit > maxExecLimit {
		limit = 30
	}
	rows, err := s.Q.ListHTTPExecutionsByWorkspace(ctx, store.ListHTTPExecutionsByWorkspaceParams{
		HttpWorkspaceID: httpWS,
		WorkspaceID:     ws,
		Limit:           int32(limit),
	})
	if err != nil {
		return nil, err
	}
	out := make([]Execution, len(rows))
	for i, r := range rows {
		out[i] = executionFromRow(r)
	}
	return out, nil
}

// ListExecutionsByRequest returns recent HTTP execution logs for one saved request.
func (s *Service) ListExecutionsByRequest(ctx context.Context, ws, reqID uuid.UUID, limit int) ([]Execution, error) {
	if _, err := s.Q.GetHTTPRequest(ctx, store.GetHTTPRequestParams{ID: reqID, WorkspaceID: ws}); err != nil {
		return nil, mapNotFound(err)
	}
	if limit <= 0 || limit > maxExecLimit {
		limit = 30
	}
	rows, err := s.Q.ListHTTPExecutionsByRequest(ctx, store.ListHTTPExecutionsByRequestParams{
		RequestID:   &reqID,
		WorkspaceID: ws,
		Limit:       int32(limit),
	})
	if err != nil {
		return nil, err
	}
	out := make([]Execution, len(rows))
	for i, r := range rows {
		out[i] = executionFromRow(r)
	}
	return out, nil
}

func clampTimeout(ms int) int {
	if ms <= 0 {
		return defaultTimeoutMS
	}
	if ms < minTimeoutMS {
		return minTimeoutMS
	}
	if ms > maxTimeoutMS {
		return maxTimeoutMS
	}
	return ms
}

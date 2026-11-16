package httpclient

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	maxResponseBytes = 2 << 20 // 2 MiB
	maxRedirects     = 10
)

var varPattern = regexp.MustCompile(`\{\{\s*([a-zA-Z0-9_.:-]+)\s*\}\}`)

// RunOptions configures executing a saved or ad-hoc request.
type RunOptions struct {
	EnvironmentID *uuid.UUID    `json:"environment_id,omitempty"`
	Override      *RequestInput `json:"override,omitempty"`
}

// AdHocRunInput executes an unsaved request inside a workspace.
type AdHocRunInput struct {
	EnvironmentID *uuid.UUID   `json:"environment_id,omitempty"`
	RequestID     *uuid.UUID   `json:"request_id,omitempty"`
	Request       RequestInput `json:"request"`
}

type resolvedVars struct {
	values       map[string]string
	secretValues []string
}

// RunSavedRequest executes a saved request (optionally with unsaved UI overrides and a specific environment).
func (s *Service) RunSavedRequest(ctx context.Context, ws, user, reqID uuid.UUID, opts RunOptions) (Execution, error) {
	var out Execution
	row, err := s.Q.GetHTTPRequest(ctx, store.GetHTTPRequestParams{ID: reqID, WorkspaceID: ws})
	if err != nil {
		return out, mapNotFound(err)
	}
	req := requestFromRow(row)
	if opts.Override != nil {
		merged, err := applyRequestOverride(req, *opts.Override)
		if err != nil {
			return out, err
		}
		req = merged
	}
	return s.execute(ctx, ws, user, req.HTTPWorkspaceID, &req.ID, req, opts.EnvironmentID)
}

// RunAdHocRequest executes an ad-hoc request inside a workspace.
func (s *Service) RunAdHocRequest(ctx context.Context, ws, user, httpWS uuid.UUID, in AdHocRunInput) (Execution, error) {
	var out Execution
	method, err := normalizeMethod(in.Request.Method)
	if err != nil {
		return out, err
	}
	bodyMode, err := normalizeBodyMode(in.Request.BodyMode)
	if err != nil {
		return out, err
	}
	auth, err := validAuth(in.Request.Auth, true)
	if err != nil {
		return out, err
	}
	follow := true
	if in.Request.FollowRedirects != nil {
		follow = *in.Request.FollowRedirects
	}
	req := Request{
		HTTPWorkspaceID: httpWS,
		FolderID:        in.Request.FolderID,
		Name:            in.Request.Name,
		Method:          method,
		URL:             strings.TrimSpace(in.Request.URL),
		Params:          cleanKeyValues(in.Request.Params),
		Headers:         cleanKeyValues(in.Request.Headers),
		Auth:            auth,
		BodyMode:        bodyMode,
		Body:            in.Request.Body,
		BodyForm:        cleanKeyValues(in.Request.BodyForm),
		TimeoutMS:       clampTimeout(in.Request.TimeoutMS),
		FollowRedirects: follow,
	}
	return s.execute(ctx, ws, user, httpWS, in.RequestID, req, in.EnvironmentID)
}

func applyRequestOverride(base Request, in RequestInput) (Request, error) {
	method, err := normalizeMethod(in.Method)
	if err != nil {
		return base, err
	}
	bodyMode, err := normalizeBodyMode(in.BodyMode)
	if err != nil {
		return base, err
	}
	auth, err := validAuth(in.Auth, true)
	if err != nil {
		return base, err
	}
	base.FolderID = in.FolderID
	if strings.TrimSpace(in.Name) != "" {
		base.Name = strings.TrimSpace(in.Name)
	}
	base.Method = method
	base.URL = strings.TrimSpace(in.URL)
	base.Params = cleanKeyValues(in.Params)
	base.Headers = cleanKeyValues(in.Headers)
	base.Auth = auth
	base.BodyMode = bodyMode
	base.Body = in.Body
	base.BodyForm = cleanKeyValues(in.BodyForm)
	base.TimeoutMS = clampTimeout(in.TimeoutMS)
	if in.FollowRedirects != nil {
		base.FollowRedirects = *in.FollowRedirects
	}
	return base, nil
}

func (s *Service) execute(ctx context.Context, ws, user, httpWS uuid.UUID, reqID *uuid.UUID, req Request, envOverrideID *uuid.UUID) (Execution, error) {
	var out Execution
	wsRow, err := s.Q.GetHTTPWorkspace(ctx, store.GetHTTPWorkspaceParams{ID: httpWS, WorkspaceID: ws})
	if err != nil {
		return out, mapNotFound(err)
	}
	hws := workspaceFromRow(wsRow)

	envID := hws.ActiveEnvironmentID
	if envOverrideID != nil {
		envID = envOverrideID
	}
	var activeEnv *Environment
	if envID != nil {
		envRow, err := s.Q.GetHTTPEnvironment(ctx, store.GetHTTPEnvironmentParams{ID: *envID, WorkspaceID: ws})
		if err != nil {
			return out, apperr.Invalid("environment_id", "unknown environment")
		}
		if envRow.HttpWorkspaceID != httpWS {
			return out, apperr.Invalid("environment_id", "environment belongs to another workspace")
		}
		e := envFromRow(envRow)
		activeEnv = &e
	}

	folders, err := s.Q.ListHTTPFolders(ctx, httpWS)
	if err != nil {
		return out, err
	}
	folderList := make([]Folder, len(folders))
	for i, f := range folders {
		folderList[i] = folderFromRow(f)
	}

	effAuth, effHeaders := ResolveInheritance(hws, folderList, req)
	vars, err := s.resolveVariables(ctx, ws, user, hws.DefaultVars, activeEnv)
	if err != nil {
		return out, err
	}

	interpolate := func(raw string) (string, error) {
		return s.interpolateString(ctx, ws, user, raw, &vars)
	}

	rawURL, err := interpolate(req.URL)
	if err != nil {
		return out, err
	}
	u, err := parseExternalURL(rawURL)
	if err != nil {
		return out, err
	}

	// Merge enabled query params.
	q := u.Query()
	for _, p := range req.Params {
		if !p.Enabled || strings.TrimSpace(p.Key) == "" {
			continue
		}
		k, err := interpolate(p.Key)
		if err != nil {
			return out, err
		}
		v, err := interpolate(p.Value)
		if err != nil {
			return out, err
		}
		q.Add(k, v)
	}

	// Resolve headers (inheritance already flattened case-insensitively).
	hdr := make(http.Header)
	for _, h := range effHeaders {
		if !h.Enabled || strings.TrimSpace(h.Key) == "" {
			continue
		}
		k, err := interpolate(h.Key)
		if err != nil {
			return out, err
		}
		v, err := interpolate(h.Value)
		if err != nil {
			return out, err
		}
		if strings.ContainsAny(k+v, "\r\n") {
			return out, apperr.Invalid("headers", "header %q contains invalid line break", k)
		}
		hdr.Set(k, v)
	}

	// Apply resolved authentication.
	if err := s.applyAuth(ctx, ws, user, effAuth, &vars, hdr, &q); err != nil {
		return out, err
	}
	u.RawQuery = q.Encode()

	// Build request body.
	var bodyReader io.Reader
	var recordedBody string
	switch req.BodyMode {
	case BodyNone, "":
	case BodyJSON:
		b, err := interpolate(req.Body)
		if err != nil {
			return out, err
		}
		recordedBody = b
		bodyReader = strings.NewReader(b)
		if hdr.Get("Content-Type") == "" {
			hdr.Set("Content-Type", "application/json")
		}
	case BodyRaw:
		b, err := interpolate(req.Body)
		if err != nil {
			return out, err
		}
		recordedBody = b
		bodyReader = strings.NewReader(b)
		if hdr.Get("Content-Type") == "" {
			hdr.Set("Content-Type", "text/plain; charset=utf-8")
		}
	case BodyFormURLEncoded:
		form := url.Values{}
		for _, kv := range req.BodyForm {
			if !kv.Enabled || strings.TrimSpace(kv.Key) == "" {
				continue
			}
			k, err := interpolate(kv.Key)
			if err != nil {
				return out, err
			}
			v, err := interpolate(kv.Value)
			if err != nil {
				return out, err
			}
			form.Add(k, v)
		}
		encoded := form.Encode()
		recordedBody = encoded
		bodyReader = strings.NewReader(encoded)
		if hdr.Get("Content-Type") == "" {
			hdr.Set("Content-Type", "application/x-www-form-urlencoded")
		}
	case BodyMultipart:
		var buf bytes.Buffer
		mw := multipart.NewWriter(&buf)
		for _, kv := range req.BodyForm {
			if !kv.Enabled || strings.TrimSpace(kv.Key) == "" {
				continue
			}
			k, err := interpolate(kv.Key)
			if err != nil {
				return out, err
			}
			v, err := interpolate(kv.Value)
			if err != nil {
				return out, err
			}
			if err := mw.WriteField(k, v); err != nil {
				return out, err
			}
		}
		_ = mw.Close()
		recordedBody = buf.String()
		bodyReader = &buf
		hdr.Set("Content-Type", mw.FormDataContentType())
	}

	timeout := time.Duration(clampTimeout(req.TimeoutMS)) * time.Millisecond
	reqCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(reqCtx, req.Method, u.String(), bodyReader)
	if err != nil {
		return out, apperr.Invalid("url", "invalid request: %v", err)
	}
	httpReq.Header = hdr

	client := s.httpClient(req.FollowRedirects, timeout)
	start := s.now()
	resp, runErr := client.Do(httpReq)
	durationMS := int(s.now().Sub(start).Milliseconds())
	if durationMS < 0 {
		durationMS = 0
	}

	// If SSRF blocked the request, fail cleanly with 422 rather than pretending it ran.
	var blocked *usersecrets.Blocked
	if errors.As(runErr, &blocked) {
		return out, apperr.Invalid("url", "%s", blocked.Reason)
	}

	envName := ""
	var storedEnvID *uuid.UUID
	if activeEnv != nil {
		envName = activeEnv.Name
		storedEnvID = &activeEnv.ID
	}

	maskedURL := maskSecrets(u.String(), vars.secretValues)
	maskedReqHdrs := maskHeaderMap(hdr, vars.secretValues)
	maskedReqBody := maskSecrets(recordedBody, vars.secretValues)

	var (
		statusCode int
		statusText string
		sizeBytes  int
		respHdrs   = map[string][]string{}
		respBody   string
		truncated  bool
		errText    string
	)
	if runErr != nil {
		errText = maskSecrets(runErr.Error(), vars.secretValues)
	} else {
		defer resp.Body.Close()
		statusCode = resp.StatusCode
		statusText = resp.Status
		for k, vals := range resp.Header {
			cp := make([]string, len(vals))
			for i, v := range vals {
				cp[i] = maskSecrets(v, vars.secretValues)
			}
			respHdrs[k] = cp
		}
		rawBytes, readErr := io.ReadAll(io.LimitReader(resp.Body, maxResponseBytes+1))
		if len(rawBytes) > maxResponseBytes {
			truncated = true
			rawBytes = rawBytes[:maxResponseBytes]
		}
		sizeBytes = len(rawBytes)
		respBody = maskSecrets(string(rawBytes), vars.secretValues)
		if readErr != nil {
			errText = maskSecrets(readErr.Error(), vars.secretValues)
		}
	}

	saved, err := s.Q.CreateHTTPExecution(ctx, store.CreateHTTPExecutionParams{
		HttpWorkspaceID:   httpWS,
		RequestID:         reqID,
		EnvironmentID:     storedEnvID,
		EnvironmentName:   envName,
		Method:            req.Method,
		ResolvedUrl:       maskedURL,
		RequestHeaders:    mustJSON(maskedReqHdrs),
		RequestBody:       maskedReqBody,
		StatusCode:        int32(statusCode),
		StatusText:        statusText,
		DurationMs:        int32(durationMS),
		SizeBytes:         int32(sizeBytes),
		ResponseHeaders:   mustJSON(respHdrs),
		ResponseBody:      respBody,
		ResponseTruncated: truncated,
		Error:             errText,
	})
	if err != nil {
		return out, err
	}
	return executionFromRow(saved), nil
}

// ResolveInheritance flattens Workspace -> Folder chain -> Request auth and headers.
func ResolveInheritance(ws Workspace, folders []Folder, req Request) (AuthConfig, []KeyValue) {
	byID := make(map[uuid.UUID]Folder, len(folders))
	for _, f := range folders {
		byID[f.ID] = f
	}
	var chain []Folder
	cur := req.FolderID
	seen := map[uuid.UUID]bool{}
	for cur != nil && !seen[*cur] {
		seen[*cur] = true
		f, ok := byID[*cur]
		if !ok {
			break
		}
		chain = append(chain, f)
		cur = f.ParentFolderID
	}
	// Reverse so root folder applies first and innermost folder last.
	for i, j := 0, len(chain)-1; i < j; i, j = i+1, j-1 {
		chain[i], chain[j] = chain[j], chain[i]
	}

	auth := ws.DefaultAuth
	if auth.Type == "" || auth.Type == AuthInherit {
		auth = AuthConfig{Type: AuthNone}
	}
	for _, f := range chain {
		if f.DefaultAuth.Type != "" && f.DefaultAuth.Type != AuthInherit {
			auth = f.DefaultAuth
		}
	}
	if req.Auth.Type != "" && req.Auth.Type != AuthInherit {
		auth = req.Auth
	}

	mergedHeaders := mergeHeaders(ws.DefaultHeaders)
	for _, f := range chain {
		mergedHeaders = mergeHeaders(mergedHeaders, f.DefaultHeaders...)
	}
	mergedHeaders = mergeHeaders(mergedHeaders, req.Headers...)
	return auth, mergedHeaders
}

func mergeHeaders(base []KeyValue, overlays ...KeyValue) []KeyValue {
	byLower := map[string]KeyValue{}
	var order []string
	add := func(kv KeyValue) {
		k := strings.TrimSpace(kv.Key)
		if k == "" {
			return
		}
		lk := strings.ToLower(k)
		if _, exists := byLower[lk]; !exists {
			order = append(order, lk)
		}
		byLower[lk] = KeyValue{Key: k, Value: kv.Value, Enabled: kv.Enabled}
	}
	for _, kv := range base {
		add(kv)
	}
	for _, kv := range overlays {
		add(kv)
	}
	out := make([]KeyValue, 0, len(order))
	for _, lk := range order {
		out = append(out, byLower[lk])
	}
	return out
}

func (s *Service) resolveVariables(ctx context.Context, ws, user uuid.UUID, wsVars []EnvVar, env *Environment) (resolvedVars, error) {
	rv := resolvedVars{values: map[string]string{}}
	applyList := func(list []EnvVar) error {
		for _, v := range list {
			if !v.Enabled || strings.TrimSpace(v.Key) == "" {
				continue
			}
			key := strings.TrimSpace(v.Key)
			if v.SecretHandle != "" {
				val, err := s.lookupSecret(ctx, ws, user, v.SecretHandle)
				if err != nil {
					return err
				}
				rv.values[key] = val
				if val != "" {
					rv.secretValues = append(rv.secretValues, val)
				}
			} else {
				rv.values[key] = v.Value
			}
		}
		return nil
	}
	if err := applyList(wsVars); err != nil {
		return rv, err
	}
	if env != nil {
		if err := applyList(env.Variables); err != nil {
			return rv, err
		}
	}
	return rv, nil
}

func (s *Service) lookupSecret(ctx context.Context, ws, user uuid.UUID, handle string) (string, error) {
	if s.Secrets == nil {
		return "", apperr.Conflict("secrets service is not configured")
	}
	sec, err := s.Q.GetUserSecretByHandle(ctx, store.GetUserSecretByHandleParams{
		WorkspaceID: ws,
		UserID:      user,
		Handle:      strings.TrimSpace(handle),
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return "", apperr.Invalid("variables", "secret %q not found", handle)
	}
	if err != nil {
		return "", err
	}
	val, err := s.Secrets.Value(ctx, sec)
	if err != nil {
		return "", err
	}
	return val, nil
}

func (s *Service) interpolateString(ctx context.Context, ws, user uuid.UUID, raw string, vars *resolvedVars) (string, error) {
	if !strings.Contains(raw, "{{") {
		return raw, nil
	}
	var firstErr error
	out := varPattern.ReplaceAllStringFunc(raw, func(match string) string {
		if firstErr != nil {
			return match
		}
		sub := varPattern.FindStringSubmatch(match)
		if len(sub) < 2 {
			return match
		}
		name := sub[1]
		if strings.HasPrefix(name, "secret:") {
			handle := strings.TrimPrefix(name, "secret:")
			val, err := s.lookupSecret(ctx, ws, user, handle)
			if err != nil {
				firstErr = err
				return match
			}
			if val != "" {
				vars.secretValues = append(vars.secretValues, val)
			}
			return val
		}
		if v, ok := vars.values[name]; ok {
			return v
		}
		return match
	})
	return out, firstErr
}

func (s *Service) applyAuth(ctx context.Context, ws, user uuid.UUID, auth AuthConfig, vars *resolvedVars, hdr http.Header, query *url.Values) error {
	interp := func(raw string) (string, error) {
		return s.interpolateString(ctx, ws, user, raw, vars)
	}
	switch auth.Type {
	case "", AuthNone, AuthInherit:
		return nil
	case AuthBearer:
		tok, err := interp(auth.Token)
		if err != nil {
			return err
		}
		if tok != "" {
			vars.secretValues = append(vars.secretValues, tok)
			if hdr.Get("Authorization") == "" {
				hdr.Set("Authorization", "Bearer "+tok)
			}
		}
	case AuthBasic:
		u, err := interp(auth.Username)
		if err != nil {
			return err
		}
		p, err := interp(auth.Password)
		if err != nil {
			return err
		}
		if p != "" {
			vars.secretValues = append(vars.secretValues, p)
		}
		creds := base64.StdEncoding.EncodeToString([]byte(u + ":" + p))
		vars.secretValues = append(vars.secretValues, creds)
		if hdr.Get("Authorization") == "" {
			hdr.Set("Authorization", "Basic "+creds)
		}
	case AuthAPIKey:
		name, err := interp(auth.APIKeyName)
		if err != nil {
			return err
		}
		val, err := interp(auth.APIKeyValue)
		if err != nil {
			return err
		}
		if val != "" {
			vars.secretValues = append(vars.secretValues, val)
		}
		if strings.TrimSpace(name) == "" {
			return nil
		}
		if auth.APIKeyIn == APIKeyInQuery {
			query.Set(name, val)
		} else if hdr.Get(name) == "" {
			hdr.Set(name, val)
		}
	case AuthOAuth2:
		if auth.OAuth2 == nil {
			return apperr.Invalid("auth.oauth2", "oauth2 configuration is required")
		}
		tokenURL, err := interp(auth.OAuth2.TokenURL)
		if err != nil {
			return err
		}
		clientID, err := interp(auth.OAuth2.ClientID)
		if err != nil {
			return err
		}
		clientSecret, err := interp(auth.OAuth2.ClientSecret)
		if err != nil {
			return err
		}
		scope, err := interp(auth.OAuth2.Scope)
		if err != nil {
			return err
		}
		audience, err := interp(auth.OAuth2.Audience)
		if err != nil {
			return err
		}
		if clientSecret != "" {
			vars.secretValues = append(vars.secretValues, clientSecret)
		}
		tok, err := s.fetchOAuth2ClientCredentials(ctx, OAuth2Config{
			GrantType:    "client_credentials",
			TokenURL:     tokenURL,
			ClientID:     clientID,
			ClientSecret: clientSecret,
			Scope:        scope,
			Audience:     audience,
		})
		if err != nil {
			return err
		}
		if tok != "" {
			vars.secretValues = append(vars.secretValues, tok)
			if hdr.Get("Authorization") == "" {
				hdr.Set("Authorization", "Bearer "+tok)
			}
		}
	}
	return nil
}

func (s *Service) fetchOAuth2ClientCredentials(ctx context.Context, cfg OAuth2Config) (string, error) {
	if _, err := parseExternalURL(cfg.TokenURL); err != nil {
		return "", apperr.Invalid("auth.oauth2.token_url", "%v", err)
	}
	sum := sha256.Sum256([]byte(strings.Join([]string{cfg.TokenURL, cfg.ClientID, cfg.ClientSecret, cfg.Scope, cfg.Audience}, "\x00")))
	cacheKey := hex.EncodeToString(sum[:])

	s.oauthMu.Lock()
	if s.oauthCache != nil {
		if entry, ok := s.oauthCache[cacheKey]; ok && s.now().Add(30*time.Second).Before(entry.ExpiresAt) {
			s.oauthMu.Unlock()
			return entry.Token, nil
		}
	}
	s.oauthMu.Unlock()

	form := url.Values{}
	form.Set("grant_type", "client_credentials")
	if cfg.ClientID != "" {
		form.Set("client_id", cfg.ClientID)
	}
	if cfg.ClientSecret != "" {
		form.Set("client_secret", cfg.ClientSecret)
	}
	if cfg.Scope != "" {
		form.Set("scope", cfg.Scope)
	}
	if cfg.Audience != "" {
		form.Set("audience", cfg.Audience)
	}

	reqCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodPost, cfg.TokenURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", apperr.Invalid("auth.oauth2.token_url", "invalid token URL: %v", err)
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.Header.Set("Accept", "application/json")

	resp, err := s.httpClient(false, 15*time.Second).Do(req)
	if err != nil {
		var blocked *usersecrets.Blocked
		if errors.As(err, &blocked) {
			return "", apperr.Invalid("auth.oauth2.token_url", "%s", blocked.Reason)
		}
		return "", fmt.Errorf("oauth2 token request failed: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 256<<10))
	if err != nil {
		return "", err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", apperr.Invalid("auth.oauth2", "token endpoint returned %d", resp.StatusCode)
	}
	var parsed struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil || parsed.AccessToken == "" {
		return "", apperr.Invalid("auth.oauth2", "token endpoint response missing access_token")
	}
	ttl := 5 * time.Minute
	if parsed.ExpiresIn > 0 {
		ttl = time.Duration(parsed.ExpiresIn) * time.Second
	}

	s.oauthMu.Lock()
	if s.oauthCache == nil {
		s.oauthCache = map[string]cachedOAuthToken{}
	}
	s.oauthCache[cacheKey] = cachedOAuthToken{Token: parsed.AccessToken, ExpiresAt: s.now().Add(ttl)}
	s.oauthMu.Unlock()
	return parsed.AccessToken, nil
}

func parseExternalURL(raw string) (*url.URL, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || len(trimmed) > 8192 {
		return nil, apperr.Invalid("url", "enter a full http:// or https:// URL")
	}
	u, err := url.Parse(trimmed)
	if err != nil || u.Host == "" || (u.Scheme != "https" && u.Scheme != "http") {
		return nil, apperr.Invalid("url", "URL must start with http:// or https:// and include a host")
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if host == "" || host == "localhost" || host == "host.docker.internal" || strings.HasSuffix(host, ".local") || strings.HasSuffix(host, ".internal") {
		return nil, apperr.Invalid("url", "only external hosts are allowed in v1 (local/private hosts are blocked)")
	}
	if ip := net.ParseIP(host); ip != nil && isBlockedExternalIP(ip) {
		return nil, apperr.Invalid("url", "only external hosts are allowed in v1 (private/loopback IPs are blocked)")
	}
	u.Scheme = strings.ToLower(u.Scheme)
	return u, nil
}

func isBlockedExternalIP(ip net.IP) bool {
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() || ip.IsMulticast() || ip.IsInterfaceLocalMulticast()
}

func (s *Service) httpClient(followRedirects bool, timeout time.Duration) *http.Client {
	tr := s.HTTP
	if tr == nil {
		// SafeTransport(false, ...) enforces SSRF protection at dial time on every address.
		tr = usersecrets.SafeTransport(false, s.LookupIP)
	}
	return &http.Client{
		Transport: tr,
		Timeout:   timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if !followRedirects {
				return http.ErrUseLastResponse
			}
			if len(via) >= maxRedirects {
				return errors.New("stopped after 10 redirects")
			}
			if _, err := parseExternalURL(req.URL.String()); err != nil {
				return err
			}
			return nil
		},
	}
}

func maskSecrets(s string, secrets []string) string {
	if s == "" || len(secrets) == 0 {
		return s
	}
	uniq := make([]string, 0, len(secrets))
	seen := map[string]bool{}
	for _, sec := range secrets {
		if len(sec) >= 3 && !seen[sec] {
			seen[sec] = true
			uniq = append(uniq, sec)
		}
	}
	sort.Slice(uniq, func(i, j int) bool { return len(uniq[i]) > len(uniq[j]) })
	for _, sec := range uniq {
		s = strings.ReplaceAll(s, sec, "[secret]")
	}
	return s
}

func maskHeaderMap(h http.Header, secrets []string) map[string]string {
	out := make(map[string]string, len(h))
	for k, vals := range h {
		lk := strings.ToLower(k)
		joined := strings.Join(vals, ", ")
		if lk == "authorization" || lk == "proxy-authorization" || lk == "x-api-key" {
			out[k] = "[redacted]"
			continue
		}
		out[k] = maskSecrets(joined, secrets)
	}
	return out
}

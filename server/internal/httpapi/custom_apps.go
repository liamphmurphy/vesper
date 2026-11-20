package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

func (s *Server) customApps() *customapps.Service {
	return &customapps.Service{Pool: s.Pool, Secrets: s.userSecrets(), Media: s.mediaDownloads(), Nix: s.nixRunner()}
}

// CustomApps returns the custom apps service wired with this server's media
// downloader and Nix runner.
func (s *Server) CustomApps() *customapps.Service {
	return s.customApps()
}

// CloseCustomApps stops any running background media downloads or Nix package
// jobs created for custom apps and waits for them to record their final state.
func (s *Server) CloseCustomApps() {
	if s.customAppMedia != nil {
		s.customAppMedia.Close()
	}
	if s.customAppNix != nil {
		s.customAppNix.Close()
	}
}

func (s *Server) nixRunner() *customapps.Nix {
	s.customAppNixOnce.Do(func() {
		if s.Pool == nil {
			return
		}
		s.customAppNix = &customapps.Nix{
			Pool:           s.Pool,
			ScratchDir:     s.CustomAppNixScratchDir,
			Resolve:        s.CustomAppNixResolve,
			DisableSandbox: s.CustomAppNixDisableSandbox,
		}
	})
	return s.customAppNix
}

// mediaDownloads is the process-wide video downloader for custom apps, or nil
// without a blob store.
func (s *Server) mediaDownloads() *customapps.Media {
	s.customAppMediaOnce.Do(func() {
		if s.Blobs == nil {
			return
		}
		s.customAppMedia = &customapps.Media{
			Pool:      s.Pool,
			Blobs:     s.Blobs,
			Bucket:    s.ArtifactBucket,
			Transport: s.CustomAppMediaTransport,
		}
	})
	return s.customAppMedia
}

func customAppManifestOut(m customapps.Manifest) api.CustomAppManifest {
	out := api.CustomAppManifest{
		Entry:     m.Entry,
		ToolScope: api.CustomAppManifestToolScope(m.ToolScope),
	}
	if m.MCPEntry != "" {
		me := m.MCPEntry
		out.McpEntry = &me
	}
	if m.Instructions != "" {
		ins := m.Instructions
		out.Instructions = &ins
	}
	if len(m.Nav) > 0 {
		nav := make([]api.CustomAppNavItem, len(m.Nav))
		for i, n := range m.Nav {
			nav[i] = api.CustomAppNavItem{Id: n.ID, Label: n.Label}
			if n.Icon != "" {
				ic := n.Icon
				nav[i].Icon = &ic
			}
		}
		out.Nav = &nav
	}
	if len(m.RequestedCapabilities) > 0 {
		caps := customAppCapsOut(m.RequestedCapabilities)
		out.RequestedCapabilities = &caps
	}
	if len(m.RequestedMounts) > 0 {
		rm := make([]api.CustomAppMountRequest, len(m.RequestedMounts))
		for i, reqM := range m.RequestedMounts {
			rm[i] = api.CustomAppMountRequest{Name: reqM.Name}
			if reqM.Description != "" {
				d := reqM.Description
				rm[i].Description = &d
			}
		}
		out.RequestedMounts = &rm
	}
	return out
}

func customAppManifestIn(in *api.CustomAppManifest) *customapps.Manifest {
	if in == nil {
		return nil
	}
	m := &customapps.Manifest{
		Entry:     in.Entry,
		ToolScope: string(in.ToolScope),
	}
	if in.McpEntry != nil {
		m.MCPEntry = *in.McpEntry
	}
	if in.Instructions != nil {
		m.Instructions = *in.Instructions
	}
	if in.Nav != nil {
		m.Nav = make([]customapps.NavItem, len(*in.Nav))
		for i, n := range *in.Nav {
			m.Nav[i] = customapps.NavItem{ID: n.Id, Label: n.Label}
			if n.Icon != nil {
				m.Nav[i].Icon = *n.Icon
			}
		}
	}
	if in.RequestedCapabilities != nil {
		m.RequestedCapabilities = customAppCapsIn(in.RequestedCapabilities)
	}
	if in.RequestedMounts != nil {
		m.RequestedMounts = make([]customapps.MountRequest, len(*in.RequestedMounts))
		for i, reqM := range *in.RequestedMounts {
			m.RequestedMounts[i] = customapps.MountRequest{Name: reqM.Name}
			if reqM.Description != nil {
				m.RequestedMounts[i].Description = *reqM.Description
			}
		}
	}
	return m
}

func customAppMountsOut(m customapps.Mounts) *api.CustomAppMounts {
	out := make(api.CustomAppMounts, len(m))
	for k, v := range m {
		out[k] = v
	}
	return &out
}

func customAppMountsIn(in *api.CustomAppMounts) customapps.Mounts {
	if in == nil {
		return nil
	}
	out := make(customapps.Mounts, len(*in))
	for k, v := range *in {
		out[k] = v
	}
	return out
}

func customAppMountsPtrIn(in *api.CustomAppMounts) *customapps.Mounts {
	if in == nil {
		return nil
	}
	out := customAppMountsIn(in)
	return &out
}

func customAppCapsOut(c customapps.Capabilities) api.CustomAppCapabilities {
	out := make(api.CustomAppCapabilities, len(c))
	for k, v := range c {
		out[k] = api.CustomAppCapabilityMode(v)
	}
	return out
}

func customAppCapsIn(in *api.CustomAppCapabilities) customapps.Capabilities {
	if in == nil {
		return nil
	}
	out := make(customapps.Capabilities, len(*in))
	for k, v := range *in {
		out[k] = agentdef.Mode(v)
	}
	return out
}

func customAppMCPToolsOut(tools []customapps.MCPToolSpec) *[]api.CustomAppMCPTool {
	if len(tools) == 0 {
		return nil
	}
	out := make([]api.CustomAppMCPTool, len(tools))
	for i, t := range tools {
		schema := map[string]any{}
		if t.InputSchema != nil {
			schema = t.InputSchema
		}
		out[i] = api.CustomAppMCPTool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: schema,
		}
	}
	return &out
}

func customAppSummaryOut(a customapps.AppSummary) api.CustomAppSummary {
	return api.CustomAppSummary{
		Id:           a.ID,
		Slug:         a.Slug,
		Name:         a.Name,
		Description:  a.Description,
		Icon:         a.Icon,
		SpaceId:      nullUUID(a.SpaceID),
		CurrentSeq:   int(a.CurrentSeq),
		Manifest:     customAppManifestOut(a.Manifest),
		Capabilities: customAppCapsOut(a.Capabilities),
		Mounts:       customAppMountsOut(a.Mounts),
		DbSizeBytes:  int(a.DBSizeBytes),
		HasMcpServer: a.HasMCPServer,
		McpTools:     customAppMCPToolsOut(a.MCPTools),
		CreatedAt:    a.CreatedAt,
		UpdatedAt:    a.UpdatedAt,
	}
}

func customAppVersionOut(v customapps.Version) api.CustomAppVersion {
	files := make(map[string]string, len(v.Files))
	maps.Copy(files, v.Files)
	return api.CustomAppVersion{
		Seq:        int(v.Seq),
		Note:       v.Note,
		AuthorType: api.CustomAppVersionAuthorType(v.AuthorType),
		AgentId:    nullUUID(v.AgentID),
		CreatedAt:  v.CreatedAt,
		Manifest:   customAppManifestOut(v.Manifest),
		Files:      files,
		BundleJs:   v.BundleJS,
		BundleCss:  v.BundleCSS,
	}
}

func customAppDetailOut(d customapps.AppDetail) api.CustomAppDetail {
	versions := make([]api.CustomAppVersionSummary, len(d.Versions))
	for i, v := range d.Versions {
		versions[i] = api.CustomAppVersionSummary{
			Seq:        int(v.Seq),
			Note:       v.Note,
			AuthorType: api.CustomAppVersionSummaryAuthorType(v.AuthorType),
			AgentId:    nullUUID(v.AgentID),
			CreatedAt:  v.CreatedAt,
		}
	}
	schema := make([]api.CustomAppSchemaObject, len(d.Schema))
	for i, obj := range d.Schema {
		schema[i] = api.CustomAppSchemaObject{Type: obj.Type, Name: obj.Name, Sql: obj.SQL}
	}
	return api.CustomAppDetail{
		Id:           d.ID,
		Slug:         d.Slug,
		Name:         d.Name,
		Description:  d.Description,
		Icon:         d.Icon,
		SpaceId:      nullUUID(d.SpaceID),
		CurrentSeq:   int(d.CurrentSeq),
		Manifest:     customAppManifestOut(d.Manifest),
		Capabilities: customAppCapsOut(d.Capabilities),
		Mounts:       customAppMountsOut(d.Mounts),
		DbSizeBytes:  int(d.DBSizeBytes),
		HasMcpServer: d.HasMCPServer,
		McpTools:     customAppMCPToolsOut(d.MCPTools),
		CreatedAt:    d.CreatedAt,
		UpdatedAt:    d.UpdatedAt,
		Current:      customAppVersionOut(d.Current),
		Versions:     versions,
		Schema:       schema,
	}
}

func (s *Server) ListCustomApps(ctx context.Context, _ api.ListCustomAppsRequestObject) (api.ListCustomAppsResponseObject, error) {
	u, _, ws := me(ctx)
	apps, err := s.customApps().List(ctx, ws, u.ID)
	if err != nil {
		return nil, err
	}
	out := make([]api.CustomAppSummary, len(apps))
	for i, a := range apps {
		out[i] = customAppSummaryOut(a)
	}
	return api.ListCustomApps200JSONResponse{Apps: out}, nil
}

func (s *Server) CreateCustomApp(ctx context.Context, req api.CreateCustomAppRequestObject) (api.CreateCustomAppResponseObject, error) {
	u, _, ws := me(ctx)
	b := req.Body
	in := customapps.CreateInput{
		Slug:         b.Slug,
		Name:         b.Name,
		Manifest:     customAppManifestIn(b.Manifest),
		Capabilities: customAppCapsIn(b.Capabilities),
		Mounts:       customAppMountsIn(b.Mounts),
		AuthorType:   "user",
	}
	if b.Description != nil {
		in.Description = *b.Description
	}
	if b.Icon != nil {
		in.Icon = *b.Icon
	}
	if b.Template != nil {
		in.Template = string(*b.Template)
	}
	if b.Files != nil {
		in.Files = *b.Files
	}
	if b.Note != nil {
		in.Note = *b.Note
	}
	d, err := s.customApps().Create(ctx, ws, u.ID, in)
	if err != nil {
		return nil, err
	}
	return api.CreateCustomApp201JSONResponse(customAppDetailOut(d)), nil
}

func (s *Server) GetCustomApp(ctx context.Context, req api.GetCustomAppRequestObject) (api.GetCustomAppResponseObject, error) {
	u, _, ws := me(ctx)
	d, err := s.customApps().Get(ctx, ws, u.ID, req.Slug)
	if err != nil {
		return nil, err
	}
	return api.GetCustomApp200JSONResponse(customAppDetailOut(d)), nil
}

func (s *Server) UpdateCustomApp(ctx context.Context, req api.UpdateCustomAppRequestObject) (api.UpdateCustomAppResponseObject, error) {
	u, _, ws := me(ctx)
	b := req.Body
	in := customapps.UpdateInput{
		Name:         b.Name,
		Description:  b.Description,
		Icon:         b.Icon,
		Manifest:     customAppManifestIn(b.Manifest),
		Capabilities: customAppCapsIn(b.Capabilities),
		Mounts:       customAppMountsPtrIn(b.Mounts),
		AuthorType:   "user",
	}
	if b.Files != nil {
		in.Files = *b.Files
	}
	if b.ReplaceFiles != nil {
		in.ReplaceFiles = *b.ReplaceFiles
	}
	if b.RemoveFiles != nil {
		in.RemoveFiles = *b.RemoveFiles
	}
	if b.Note != nil {
		in.Note = *b.Note
	}
	if b.RestoreSeq != nil {
		seq := int32(*b.RestoreSeq)
		in.RestoreSeq = &seq
	}
	d, err := s.customApps().Update(ctx, ws, u.ID, req.Slug, in)
	if err != nil {
		return nil, err
	}
	return api.UpdateCustomApp200JSONResponse(customAppDetailOut(d)), nil
}

func (s *Server) DeleteCustomApp(ctx context.Context, req api.DeleteCustomAppRequestObject) (api.DeleteCustomAppResponseObject, error) {
	u, _, ws := me(ctx)
	if err := s.customApps().Delete(ctx, ws, u.ID, req.Slug); err != nil {
		return nil, err
	}
	return api.DeleteCustomApp204Response{}, nil
}

func (s *Server) GetCustomAppVersion(ctx context.Context, req api.GetCustomAppVersionRequestObject) (api.GetCustomAppVersionResponseObject, error) {
	u, _, ws := me(ctx)
	v, err := s.customApps().GetVersion(ctx, ws, u.ID, req.Slug, int32(req.Seq))
	if err != nil {
		return nil, err
	}
	return api.GetCustomAppVersion200JSONResponse(customAppVersionOut(v)), nil
}

func (s *Server) InvokeCustomApp(ctx context.Context, req api.InvokeCustomAppRequestObject) (api.InvokeCustomAppResponseObject, error) {
	u, _, ws := me(ctx)
	b := req.Body
	app, err := s.customApps().Get(ctx, ws, u.ID, req.Slug)
	if err != nil {
		return nil, err
	}

	var capKey string
	var summary string
	var apiMethod, apiPath string
	var isOwnMCP bool

	switch b.Kind {
	case api.Sql:
		if b.Query == nil || strings.TrimSpace(*b.Query) == "" {
			return nil, apperr.Invalid("query", "SQL query is required")
		}
		ro, err := customapps.ClassifySQL(*b.Query)
		if err != nil {
			return nil, err
		}
		if ro {
			capKey = "app.sql:read"
			summary = fmt.Sprintf("Run read-only SQLite query in %s", app.Name)
		} else {
			capKey = "app.sql:write"
			summary = fmt.Sprintf("Run SQLite write query in %s", app.Name)
		}
	case api.Api:
		method := http.MethodGet
		if b.Method != nil && strings.TrimSpace(*b.Method) != "" {
			method = strings.ToUpper(strings.TrimSpace(*b.Method))
		}
		rawPath := ""
		if b.Path != nil {
			rawPath = strings.TrimSpace(*b.Path)
		}
		cleanedPath, isRead, err := validateCustomAppAPIRequest(method, rawPath)
		if err != nil {
			return nil, err
		}
		apiMethod, apiPath = method, cleanedPath
		if isRead {
			capKey = "vesper.api:read"
		} else {
			capKey = "vesper.api:write"
		}
		summary = fmt.Sprintf("%s %s", apiMethod, apiPath)
	case api.Mcp:
		connSlug := ""
		if b.Connector != nil {
			connSlug = strings.TrimSpace(*b.Connector)
		}
		tool := ""
		if b.Tool != nil {
			tool = strings.TrimSpace(*b.Tool)
		}
		if connSlug == "" || tool == "" {
			return nil, apperr.Invalid("connector", "connector and tool are required")
		}
		isOwnMCP = connSlug == "self" || connSlug == agentdef.CustomAppMCPPrefix+app.Slug
		capSlug := connSlug
		if isOwnMCP {
			capSlug = "self"
		}
		capKey = "mcp:" + capSlug + ":" + tool
		if err := customapps.ValidCapabilityKey(capKey); err != nil {
			return nil, err
		}
		summary = fmt.Sprintf("Call MCP tool %s.%s", connSlug, tool)
	default:
		return nil, apperr.Invalid("kind", "must be sql, api, or mcp")
	}

	mode := customapps.ModeFor(app.Capabilities, capKey)
	if isOwnMCP {
		if explicit, ok := app.Capabilities[capKey]; ok {
			mode = explicit
		} else {
			mode = agentdef.Allowed
		}
	}
	approved := b.Approved != nil && *b.Approved
	alwaysAllow := b.AlwaysAllow != nil && *b.AlwaysAllow

	switch mode {
	case agentdef.Denied:
		return api.InvokeCustomApp403JSONResponse{ErrorJSONResponse: api.ErrorJSONResponse{
			Code:    api.Forbidden,
			Message: fmt.Sprintf("capability %s is denied for custom app %q", capKey, app.Slug),
		}}, nil
	case agentdef.RequiresApproval:
		if !approved {
			return api.InvokeCustomApp200JSONResponse{
				Status:     api.CustomAppInvokeResponseStatusApprovalRequired,
				Capability: capKey,
				Summary:    &summary,
			}, nil
		}
		if alwaysAllow {
			nextCaps := maps.Clone(app.Capabilities)
			if nextCaps == nil {
				nextCaps = customapps.Capabilities{}
			}
			nextCaps[capKey] = agentdef.Allowed
			if _, err := s.customApps().SetCapabilities(ctx, ws, u.ID, app.Slug, nextCaps); err != nil {
				return nil, err
			}
		}
	}

	switch b.Kind {
	case api.Sql:
		var params []any
		if b.Params != nil {
			params = *b.Params
		}
		res, err := s.customApps().QuerySQL(ctx, ws, u.ID, app.Slug, *b.Query, params)
		if err != nil {
			return nil, err
		}
		return api.InvokeCustomApp200JSONResponse{
			Status:     api.CustomAppInvokeResponseStatusOk,
			Capability: capKey,
			Result:     res,
		}, nil
	case api.Api:
		out, err := s.dispatchCustomAppAPI(ctx, u, apiMethod, apiPath, b.Body)
		if err != nil {
			return nil, err
		}
		return api.InvokeCustomApp200JSONResponse{
			Status:     api.CustomAppInvokeResponseStatusOk,
			Capability: capKey,
			Result:     out,
		}, nil
	case api.Mcp:
		if isOwnMCP {
			mcpApp, err := s.customApps().GetMCPServer(ctx, ws, u.ID, app.Slug)
			if err != nil {
				return nil, err
			}
			argsMap := map[string]any{}
			if b.Arguments != nil {
				argsMap = *b.Arguments
			}
			res, err := s.customApps().CallMCPTool(ctx, mcpApp, strings.TrimSpace(*b.Tool), argsMap, customapps.MCPCallContext{
				Interactive: true,
				Approved:    approved,
				AlwaysAllow: alwaysAllow,
				APICall: func(actx context.Context, method, rawPath string, body any) (any, error) {
					cleaned, _, err := validateCustomAppAPIRequest(method, rawPath)
					if err != nil {
						return nil, err
					}
					return s.dispatchCustomAppAPI(actx, u, method, cleaned, body)
				},
			})
			if err != nil {
				var appReq *customapps.ApprovalRequiredError
				if errors.As(err, &appReq) {
					return api.InvokeCustomApp200JSONResponse{
						Status:     api.CustomAppInvokeResponseStatusApprovalRequired,
						Capability: appReq.Capability,
						Summary:    &appReq.Summary,
					}, nil
				}
				return nil, apperr.Conflict("%v", err)
			}
			return api.InvokeCustomApp200JSONResponse{
				Status:     api.CustomAppInvokeResponseStatusOk,
				Capability: capKey,
				Result:     res,
			}, nil
		}
		conn, err := s.Q.GetConnectorBySlug(ctx, store.GetConnectorBySlugParams{
			Slug:        strings.TrimSpace(*b.Connector),
			WorkspaceID: ws,
			UserID:      u.ID,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		if err != nil {
			return nil, err
		}
		var argsJSON json.RawMessage = json.RawMessage(`{}`)
		if b.Arguments != nil {
			raw, err := json.Marshal(*b.Arguments)
			if err != nil {
				return nil, apperr.Invalid("arguments", "invalid JSON arguments")
			}
			argsJSON = raw
		}
		res, err := s.connectors().Call(ctx, conn, strings.TrimSpace(*b.Tool), argsJSON)
		if err != nil {
			return nil, apperr.Conflict("%v", err)
		}
		return api.InvokeCustomApp200JSONResponse{
			Status:     api.CustomAppInvokeResponseStatusOk,
			Capability: capKey,
			Result:     res,
		}, nil
	}
	return nil, apperr.Invalid("kind", "unsupported invoke kind")
}

const (
	maxCustomAppImageBytes     = 3 << 20
	maxCustomAppImageRedirects = 3
)

// GetCustomAppImage proxies a public HTTPS raster image for a custom app,
// gated by app.http:outbound and SSRF-checked via usersecrets.SafeTransport.
func (s *Server) GetCustomAppImage(ctx context.Context, req api.GetCustomAppImageRequestObject) (api.GetCustomAppImageResponseObject, error) {
	u, _, ws := me(ctx)
	app, err := s.customApps().Get(ctx, ws, u.ID, req.Slug)
	if err != nil {
		return nil, err
	}
	switch customapps.ModeFor(app.Capabilities, "app.http:outbound") {
	case agentdef.Denied:
		return api.GetCustomAppImage403JSONResponse{ErrorJSONResponse: api.ErrorJSONResponse{
			Code:    api.Forbidden,
			Message: fmt.Sprintf("capability app.http:outbound is denied for custom app %q", app.Slug),
		}}, nil
	case agentdef.RequiresApproval:
		if req.Params.Approved == nil || !*req.Params.Approved {
			return api.GetCustomAppImage403JSONResponse{ErrorJSONResponse: api.ErrorJSONResponse{
				Code:    api.Forbidden,
				Message: fmt.Sprintf("capability app.http:outbound requires approval for custom app %q", app.Slug),
			}}, nil
		}
	}

	rawURL := strings.TrimSpace(req.Params.Url)
	parsed, err := url.Parse(rawURL)
	if rawURL == "" || len(rawURL) > 2048 || err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil {
		return nil, apperr.Invalid("url", "image url must be a valid https URL")
	}

	body, ct, err := s.fetchCustomAppImage(ctx, parsed.String())
	if err != nil {
		return nil, err
	}
	return avatarResponse{body: io.NopCloser(bytes.NewReader(body)), contentType: ct, length: int64(len(body))}, nil
}

// GetCustomAppMediaContent serves a video the app downloaded, so the player can
// play it from Vesper instead of the site it came from. Players request many
// ranges, so this looks the app up directly rather than loading its detail.
func (s *Server) GetCustomAppMediaContent(ctx context.Context, req api.GetCustomAppMediaContentRequestObject) (api.GetCustomAppMediaContentResponseObject, error) {
	u, _, ws := me(ctx)
	app, err := s.Q.GetCustomAppBySlug(ctx, store.GetCustomAppBySlugParams{WorkspaceID: ws, UserID: u.ID, Slug: req.Slug})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	media := s.mediaDownloads()
	if media == nil {
		return nil, apperr.ErrNotFound
	}
	item, key, size, err := media.Playable(ctx, app.ID, req.MediaId)
	if err != nil {
		return nil, err
	}
	return s.serveRanged(ctx, key, item.ContentType, size, "", true, req.Params.Range)
}

// VisitGetCustomAppMediaContentResponse writes a downloaded video, whole or one range.
func (r rangedResponse) VisitGetCustomAppMediaContentResponse(w http.ResponseWriter) error {
	return r.write(w)
}

// VisitGetCustomAppImageResponse serves a proxied image with avatar security/cache headers.
func (r avatarResponse) VisitGetCustomAppImageResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (s *Server) fetchCustomAppImage(ctx context.Context, targetURL string) ([]byte, string, error) {
	rt := s.CustomAppImageTransport
	if rt == nil {
		t := usersecrets.SafeTransport(false, nil)
		defer t.CloseIdleConnections()
		rt = t
	}
	client := &http.Client{
		Timeout:   12 * time.Second,
		Transport: rt,
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if len(via) >= maxCustomAppImageRedirects {
				return errors.New("too many redirects")
			}
			if next.URL == nil || next.URL.Scheme != "https" || next.URL.Hostname() == "" || next.URL.User != nil || len(next.URL.String()) > 2048 {
				return errors.New("redirect to an unsupported image URL")
			}
			return nil
		},
	}
	outReq, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
	if err != nil {
		return nil, "", apperr.Invalid("url", "invalid image url: %v", err)
	}
	outReq.Header.Set("User-Agent", "Vesper")
	res, err := client.Do(outReq)
	if err != nil {
		var b *usersecrets.Blocked
		if errors.As(err, &b) {
			return nil, "", apperr.Invalid("url", "%s", b.Reason)
		}
		return nil, "", apperr.Conflict("failed to fetch image: %v", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, "", apperr.Conflict("image server returned HTTP %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, maxCustomAppImageBytes+1))
	if err != nil {
		return nil, "", apperr.Conflict("reading image: %v", err)
	}
	if len(body) > maxCustomAppImageBytes {
		return nil, "", apperr.Invalid("url", "image exceeds 3 MB limit")
	}
	ct := http.DetectContentType(body)
	switch ct {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return body, ct, nil
	default:
		return nil, "", apperr.Invalid("url", "unsupported image type %q", ct)
	}
}

func validateCustomAppAPIRequest(method, rawURL string) (cleaned string, isRead bool, err error) {
	switch method {
	case http.MethodGet, http.MethodHead:
		isRead = true
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		isRead = false
	default:
		return "", false, apperr.Invalid("method", "unsupported HTTP method %q", method)
	}
	u, err := url.Parse(rawURL)
	if err != nil || u.Scheme != "" || u.Host != "" {
		return "", false, apperr.Invalid("path", "must be a relative path under /api/v1/")
	}
	cleanPath := path.Clean(u.Path)
	if !strings.HasPrefix(cleanPath, "/api/v1/") && cleanPath != "/api/v1" {
		return "", false, apperr.Invalid("path", "path must start with /api/v1/")
	}
	for _, blocked := range []string{
		"/api/v1/auth",
		"/api/v1/signin",
		"/api/v1/agent",
		"/api/v1/user-secrets",
		"/api/v1/api-secrets",
		"/api/v1/custom-apps",
		"/api/v1/harness",
	} {
		if cleanPath == blocked || strings.HasPrefix(cleanPath, blocked+"/") {
			return "", false, apperr.Invalid("path", "access to %s from custom apps is restricted", blocked)
		}
	}
	target := cleanPath
	if u.RawQuery != "" {
		target += "?" + u.RawQuery
	}
	return target, isRead, nil
}

func (s *Server) dispatchCustomAppAPI(ctx context.Context, u store.User, method, target string, body any) (any, error) {
	var bodyReader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, apperr.Invalid("body", "invalid JSON body")
		}
		bodyReader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(auth.WithUser(ctx, u), method, target, bodyReader)
	if err != nil {
		return nil, apperr.Invalid("path", "invalid request: %v", err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	rec := httptest.NewRecorder()
	s.internalAPIHandler().ServeHTTP(rec, req)
	respBytes := rec.Body.Bytes()
	var parsed any
	if len(bytes.TrimSpace(respBytes)) > 0 {
		if err := json.Unmarshal(respBytes, &parsed); err != nil {
			parsed = string(respBytes)
		}
	}
	if rec.Code >= 400 {
		msg := fmt.Sprintf("Vesper API %s %s returned HTTP %d", method, target, rec.Code)
		if m, ok := parsed.(map[string]any); ok {
			if em, ok := m["message"].(string); ok && em != "" {
				msg = em
			}
		}
		if rec.Code == http.StatusNotFound {
			return nil, apperr.ErrNotFound
		}
		if rec.Code == http.StatusUnprocessableEntity || rec.Code == http.StatusBadRequest {
			return nil, apperr.Invalid("path", "%s", msg)
		}
		return nil, apperr.Conflict("%s", msg)
	}
	return parsed, nil
}

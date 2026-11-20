package customapps

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

type Service struct {
	Pool       *pgxpool.Pool
	Secrets    *usersecrets.Service
	NodeBinary string
}

type AppSummary struct {
	ID           uuid.UUID     `json:"id"`
	Slug         string        `json:"slug"`
	Name         string        `json:"name"`
	Description  string        `json:"description"`
	Icon         string        `json:"icon"`
	SpaceID      *uuid.UUID    `json:"space_id"`
	CurrentSeq   int32         `json:"current_seq"`
	Manifest     Manifest      `json:"manifest"`
	Capabilities Capabilities  `json:"capabilities"`
	DBSizeBytes  int32         `json:"db_size_bytes"`
	HasMCPServer bool          `json:"has_mcp_server"`
	MCPTools     []MCPToolSpec `json:"mcp_tools,omitempty"`
	CreatedAt    time.Time     `json:"created_at"`
	UpdatedAt    time.Time     `json:"updated_at"`
}

// MCPServerApp holds a custom app's active compiled MCP server bundle and metadata.
type MCPServerApp struct {
	ID           uuid.UUID
	WorkspaceID  uuid.UUID
	UserID       uuid.UUID
	Slug         string
	Name         string
	Description  string
	Manifest     Manifest
	Capabilities Capabilities
	CurrentSeq   int32
	BundleMCPJS  string
	Tools        []MCPToolSpec
}

type VersionSummary struct {
	Seq        int32      `json:"seq"`
	Note       string     `json:"note"`
	AuthorType string     `json:"author_type"`
	AgentID    *uuid.UUID `json:"agent_id,omitempty"`
	CreatedAt  time.Time  `json:"created_at"`
}

type Version struct {
	VersionSummary
	Manifest  Manifest          `json:"manifest"`
	Files     map[string]string `json:"files"`
	BundleJS  string            `json:"bundle_js"`
	BundleCSS string            `json:"bundle_css"`
}

type AppDetail struct {
	AppSummary
	Current  Version          `json:"current"`
	Versions []VersionSummary `json:"versions"`
	Schema   []SchemaObject   `json:"schema"`
}

type CreateInput struct {
	Slug         string
	Name         string
	Description  string
	Icon         string
	Template     string
	Manifest     *Manifest
	Files        map[string]string
	Capabilities Capabilities
	Note         string
	AuthorType   string
	AgentID      *uuid.UUID
}

type UpdateInput struct {
	Name         *string
	Description  *string
	Icon         *string
	Manifest     *Manifest
	Files        map[string]string
	ReplaceFiles bool
	RemoveFiles  []string
	Capabilities Capabilities
	Note         string
	RestoreSeq   *int32
	AuthorType   string
	AgentID      *uuid.UUID
}

func (s *Service) List(ctx context.Context, ws, userID uuid.UUID) ([]AppSummary, error) {
	rows, err := store.New(s.Pool).ListCustomApps(ctx, store.ListCustomAppsParams{WorkspaceID: ws, UserID: userID})
	if err != nil {
		return nil, err
	}
	out := make([]AppSummary, 0, len(rows))
	for _, r := range rows {
		var dbSize int32
		if r.SizeBytes != nil {
			dbSize = *r.SizeBytes
		}
		out = append(out, AppSummary{
			ID:           r.ID,
			Slug:         r.Slug,
			Name:         r.Name,
			Description:  r.Description,
			Icon:         r.Icon,
			SpaceID:      r.SpaceID,
			CurrentSeq:   r.CurrentSeq,
			Manifest:     decodeManifest(r.Manifest),
			Capabilities: decodeCapabilities(r.Capabilities),
			DBSizeBytes:  dbSize,
			HasMCPServer: r.HasMcpServer,
			MCPTools:     decodeMCPTools(r.McpTools),
			CreatedAt:    r.CreatedAt,
			UpdatedAt:    r.UpdatedAt,
		})
	}
	return out, nil
}

func (s *Service) Get(ctx context.Context, ws, userID uuid.UUID, slug string) (AppDetail, error) {
	q := store.New(s.Pool)
	app, err := q.GetCustomAppBySlug(ctx, store.GetCustomAppBySlugParams{WorkspaceID: ws, UserID: userID, Slug: slug})
	if errors.Is(err, pgx.ErrNoRows) {
		return AppDetail{}, apperr.ErrNotFound
	}
	if err != nil {
		return AppDetail{}, err
	}
	ver, err := q.GetCustomAppVersion(ctx, store.GetCustomAppVersionParams{AppID: app.ID, Seq: app.CurrentSeq})
	if errors.Is(err, pgx.ErrNoRows) {
		return AppDetail{}, apperr.ErrNotFound
	}
	if err != nil {
		return AppDetail{}, err
	}
	histRows, err := q.ListCustomAppVersions(ctx, app.ID)
	if err != nil {
		return AppDetail{}, err
	}
	versions := make([]VersionSummary, 0, len(histRows))
	for _, h := range histRows {
		versions = append(versions, VersionSummary{
			Seq:        h.Seq,
			Note:       h.Note,
			AuthorType: h.AuthorType,
			AgentID:    h.AgentID,
			CreatedAt:  h.CreatedAt,
		})
	}
	schema := []SchemaObject{}
	dbRow, err := q.GetCustomAppDatabase(ctx, app.ID)
	if err == nil && len(dbRow.SqliteBytes) > 0 {
		if objs, serr := schemaSummaryTx(ctx, dbRow.SqliteBytes); serr == nil {
			schema = objs
		}
	} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return AppDetail{}, err
	}

	var dbSize int32
	if app.SizeBytes != nil {
		dbSize = *app.SizeBytes
	}
	files := map[string]string{}
	_ = json.Unmarshal(ver.Files, &files)

	return AppDetail{
		AppSummary: AppSummary{
			ID:           app.ID,
			Slug:         app.Slug,
			Name:         app.Name,
			Description:  app.Description,
			Icon:         app.Icon,
			SpaceID:      app.SpaceID,
			CurrentSeq:   app.CurrentSeq,
			Manifest:     decodeManifest(app.Manifest),
			Capabilities: decodeCapabilities(app.Capabilities),
			DBSizeBytes:  dbSize,
			HasMCPServer: app.HasMcpServer,
			MCPTools:     decodeMCPTools(app.McpTools),
			CreatedAt:    app.CreatedAt,
			UpdatedAt:    app.UpdatedAt,
		},
		Current: Version{
			VersionSummary: VersionSummary{
				Seq:        ver.Seq,
				Note:       ver.Note,
				AuthorType: ver.AuthorType,
				AgentID:    ver.AgentID,
				CreatedAt:  ver.CreatedAt,
			},
			Manifest:  decodeManifest(ver.Manifest),
			Files:     files,
			BundleJS:  ver.BundleJs,
			BundleCSS: ver.BundleCss,
		},
		Versions: versions,
		Schema:   schema,
	}, nil
}

func (s *Service) GetVersion(ctx context.Context, ws, userID uuid.UUID, slug string, seq int32) (Version, error) {
	q := store.New(s.Pool)
	app, err := q.GetCustomAppBySlug(ctx, store.GetCustomAppBySlugParams{WorkspaceID: ws, UserID: userID, Slug: slug})
	if errors.Is(err, pgx.ErrNoRows) {
		return Version{}, apperr.ErrNotFound
	}
	if err != nil {
		return Version{}, err
	}
	ver, err := q.GetCustomAppVersion(ctx, store.GetCustomAppVersionParams{AppID: app.ID, Seq: seq})
	if errors.Is(err, pgx.ErrNoRows) {
		return Version{}, apperr.ErrNotFound
	}
	if err != nil {
		return Version{}, err
	}
	files := map[string]string{}
	_ = json.Unmarshal(ver.Files, &files)
	return Version{
		VersionSummary: VersionSummary{
			Seq:        ver.Seq,
			Note:       ver.Note,
			AuthorType: ver.AuthorType,
			AgentID:    ver.AgentID,
			CreatedAt:  ver.CreatedAt,
		},
		Manifest:  decodeManifest(ver.Manifest),
		Files:     files,
		BundleJS:  ver.BundleJs,
		BundleCSS: ver.BundleCss,
	}, nil
}

func (s *Service) Create(ctx context.Context, ws, userID uuid.UUID, in CreateInput) (AppDetail, error) {
	slug, err := ValidSlug(in.Slug)
	if err != nil {
		return AppDetail{}, err
	}
	name, err := ValidateName(in.Name)
	if err != nil {
		return AppDetail{}, err
	}
	desc, err := ValidateDescription(in.Description)
	if err != nil {
		return AppDetail{}, err
	}
	icon, err := ValidateIcon(in.Icon)
	if err != nil {
		return AppDetail{}, err
	}

	var files map[string]string
	var manifest Manifest
	if len(in.Files) > 0 {
		files, err = NormalizeFiles(in.Files)
		if err != nil {
			return AppDetail{}, err
		}
		if in.Manifest != nil {
			manifest = *in.Manifest
		}
	} else {
		starter, err := StarterFor(in.Template, name)
		if err != nil {
			return AppDetail{}, err
		}
		files, err = NormalizeFiles(starter.Files)
		if err != nil {
			return AppDetail{}, err
		}
		manifest = starter.Manifest
		if strings.TrimSpace(in.Description) == "" {
			desc = starter.Description
		}
		if strings.TrimSpace(in.Icon) == "" {
			icon = starter.Icon
		}
		if in.Manifest != nil {
			if in.Manifest.Entry != "" {
				manifest.Entry = in.Manifest.Entry
			}
			if in.Manifest.ToolScope != "" {
				manifest.ToolScope = in.Manifest.ToolScope
			}
			if in.Manifest.Instructions != "" {
				manifest.Instructions = in.Manifest.Instructions
			}
			if len(in.Manifest.Nav) > 0 {
				manifest.Nav = in.Manifest.Nav
			}
			if len(in.Manifest.RequestedCapabilities) > 0 {
				manifest.RequestedCapabilities = in.Manifest.RequestedCapabilities
			}
		}
	}
	manifest, err = NormalizeManifest(manifest, files)
	if err != nil {
		return AppDetail{}, err
	}

	var caps Capabilities
	if in.Capabilities != nil {
		caps, err = NormalizeCapabilities(in.Capabilities)
		if err != nil {
			return AppDetail{}, err
		}
	} else {
		caps = DefaultCapabilities(manifest.RequestedCapabilities)
	}

	authorType := in.AuthorType
	if authorType == "" {
		authorType = "user"
	}
	note := strings.TrimSpace(in.Note)
	if note == "" {
		note = "Initial version"
	}

	bundleJS, bundleCSS, err := Bundle(manifest.Entry, files)
	if err != nil {
		return AppDetail{}, err
	}
	bundleMCP, mcpToolsJSON, err := s.compileMCPServer(ctx, manifest, files)
	if err != nil {
		return AppDetail{}, err
	}

	manifestJSON, err := json.Marshal(manifest)
	if err != nil {
		return AppDetail{}, err
	}
	capsJSON, err := json.Marshal(caps)
	if err != nil {
		return AppDetail{}, err
	}
	filesJSON, err := json.Marshal(files)
	if err != nil {
		return AppDetail{}, err
	}

	err = pgx.BeginTxFunc(ctx, s.Pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		q := store.New(tx)
		sp, err := q.CreateAppSpace(ctx, store.CreateAppSpaceParams{
			WorkspaceID:  ws,
			UserID:       userID,
			Name:         name,
			Description:  desc,
			Color:        "teal",
			Instructions: manifest.Instructions,
			AppName:      "custom:" + slug,
		})
		if err != nil {
			return err
		}
		app, err := q.InsertCustomApp(ctx, store.InsertCustomAppParams{
			WorkspaceID:  ws,
			UserID:       userID,
			Slug:         slug,
			Name:         name,
			Description:  desc,
			Icon:         icon,
			SpaceID:      &sp.ID,
			CurrentSeq:   1,
			Manifest:     manifestJSON,
			Capabilities: capsJSON,
		})
		if err != nil {
			var pgErr *pgconn.PgError
			if errors.As(err, &pgErr) && pgErr.Code == "23505" {
				return apperr.Conflict("custom app %q already exists", slug)
			}
			return err
		}
		if _, err := q.InsertCustomAppVersion(ctx, store.InsertCustomAppVersionParams{
			AppID:       app.ID,
			Seq:         1,
			Note:        note,
			AuthorType:  authorType,
			AgentID:     in.AgentID,
			Manifest:    manifestJSON,
			Files:       filesJSON,
			BundleJs:    bundleJS,
			BundleCss:   bundleCSS,
			BundleMcpJs: bundleMCP,
			McpTools:    mcpToolsJSON,
		}); err != nil {
			return err
		}
		if err := q.EnsureCustomAppDatabase(ctx, app.ID); err != nil {
			return err
		}
		if schemaSQL := files["schema.sql"]; hasSQLTokens(schemaSQL) {
			if _, err := s.runSQLTx(ctx, q, app.ID, schemaSQL, nil, true); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return AppDetail{}, err
	}
	return s.Get(ctx, ws, userID, slug)
}

func (s *Service) Update(ctx context.Context, ws, userID uuid.UUID, slug string, in UpdateInput) (AppDetail, error) {
	authorType := in.AuthorType
	if authorType == "" {
		authorType = "user"
	}

	err := pgx.BeginTxFunc(ctx, s.Pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		q := store.New(tx)
		app, err := q.GetCustomAppForUpdate(ctx, store.GetCustomAppForUpdateParams{WorkspaceID: ws, UserID: userID, Slug: slug})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		curVer, err := q.GetCustomAppVersion(ctx, store.GetCustomAppVersionParams{AppID: app.ID, Seq: app.CurrentSeq})
		if err != nil {
			return err
		}
		curFiles := map[string]string{}
		if err := json.Unmarshal(curVer.Files, &curFiles); err != nil {
			return err
		}
		curManifest := decodeManifest(app.Manifest)
		curCaps := decodeCapabilities(app.Capabilities)

		name := app.Name
		if in.Name != nil {
			name, err = ValidateName(*in.Name)
			if err != nil {
				return err
			}
		}
		desc := app.Description
		if in.Description != nil {
			desc, err = ValidateDescription(*in.Description)
			if err != nil {
				return err
			}
		}
		icon := app.Icon
		if in.Icon != nil {
			icon, err = ValidateIcon(*in.Icon)
			if err != nil {
				return err
			}
		}
		if in.Capabilities != nil {
			curCaps, err = NormalizeCapabilities(in.Capabilities)
			if err != nil {
				return err
			}
		}

		nextSeq := app.CurrentSeq
		createVersion := false
		nextFiles := curFiles
		nextManifest := curManifest
		runSchema := false

		if in.RestoreSeq != nil {
			target, err := q.GetCustomAppVersion(ctx, store.GetCustomAppVersionParams{AppID: app.ID, Seq: *in.RestoreSeq})
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.Invalid("restore_seq", "version %d not found", *in.RestoreSeq)
			}
			if err != nil {
				return err
			}
			nextFiles = map[string]string{}
			if err := json.Unmarshal(target.Files, &nextFiles); err != nil {
				return err
			}
			nextManifest = decodeManifest(target.Manifest)
			createVersion = true
			if in.Note == "" {
				in.Note = fmt.Sprintf("Restored from v%d", *in.RestoreSeq)
			}
		} else {
			if len(in.Files) > 0 || len(in.RemoveFiles) > 0 {
				if in.ReplaceFiles && len(in.Files) > 0 {
					nextFiles = make(map[string]string, len(in.Files))
					for k, v := range in.Files {
						nextFiles[k] = v
					}
				} else {
					nextFiles = make(map[string]string, len(curFiles)+len(in.Files))
					for k, v := range curFiles {
						nextFiles[k] = v
					}
					for _, rm := range in.RemoveFiles {
						delete(nextFiles, rm)
						if nextManifest.MCPEntry == rm && in.Manifest == nil {
							nextManifest.MCPEntry = ""
						}
					}
					for k, v := range in.Files {
						nextFiles[k] = v
					}
				}
				if in.ReplaceFiles && in.Manifest == nil {
					if _, ok := nextFiles[nextManifest.MCPEntry]; !ok {
						nextManifest.MCPEntry = ""
					}
				}
				createVersion = true
				if nextFiles["schema.sql"] != curFiles["schema.sql"] && hasSQLTokens(nextFiles["schema.sql"]) {
					runSchema = true
				}
			}
			if in.Manifest != nil {
				nextManifest = *in.Manifest
				createVersion = true
			}
		}

		if createVersion {
			nextFiles, err = NormalizeFiles(nextFiles)
			if err != nil {
				return err
			}
			nextManifest, err = NormalizeManifest(nextManifest, nextFiles)
			if err != nil {
				return err
			}
			bundleJS, bundleCSS, err := Bundle(nextManifest.Entry, nextFiles)
			if err != nil {
				return err
			}
			bundleMCP, mcpToolsJSON, err := s.compileMCPServer(ctx, nextManifest, nextFiles)
			if err != nil {
				return err
			}
			nextSeq = app.CurrentSeq + 1
			mJSON, err := json.Marshal(nextManifest)
			if err != nil {
				return err
			}
			fJSON, err := json.Marshal(nextFiles)
			if err != nil {
				return err
			}
			note := strings.TrimSpace(in.Note)
			if _, err := q.InsertCustomAppVersion(ctx, store.InsertCustomAppVersionParams{
				AppID:       app.ID,
				Seq:         nextSeq,
				Note:        note,
				AuthorType:  authorType,
				AgentID:     in.AgentID,
				Manifest:    mJSON,
				Files:       fJSON,
				BundleJs:    bundleJS,
				BundleCss:   bundleCSS,
				BundleMcpJs: bundleMCP,
				McpTools:    mcpToolsJSON,
			}); err != nil {
				return err
			}
			if err := q.PruneCustomAppVersions(ctx, store.PruneCustomAppVersionsParams{
				AppID:      app.ID,
				OldestKept: nextSeq - MaxStoredVersions + 1,
			}); err != nil {
				return err
			}
			if runSchema {
				if _, err := s.runSQLTx(ctx, q, app.ID, nextFiles["schema.sql"], nil, true); err != nil {
					return err
				}
			}
		}

		manifestJSON, err := json.Marshal(nextManifest)
		if err != nil {
			return err
		}
		capsJSON, err := json.Marshal(curCaps)
		if err != nil {
			return err
		}
		if _, err := q.UpdateCustomAppHead(ctx, store.UpdateCustomAppHeadParams{
			ID:           app.ID,
			Name:         name,
			Description:  desc,
			Icon:         icon,
			CurrentSeq:   nextSeq,
			Manifest:     manifestJSON,
			Capabilities: capsJSON,
		}); err != nil {
			return err
		}
		if app.SpaceID != nil {
			if err := q.SyncAppSpaceMeta(ctx, store.SyncAppSpaceMetaParams{
				ID:           *app.SpaceID,
				Name:         name,
				Instructions: nextManifest.Instructions,
			}); err != nil {
				return err
			}
		}
		return nil
	})
	if err != nil {
		return AppDetail{}, err
	}
	return s.Get(ctx, ws, userID, slug)
}

func (s *Service) SetCapabilities(ctx context.Context, ws, userID uuid.UUID, slug string, caps Capabilities) (Capabilities, error) {
	norm, err := NormalizeCapabilities(caps)
	if err != nil {
		return nil, err
	}
	b, err := json.Marshal(norm)
	if err != nil {
		return nil, err
	}
	row, err := store.New(s.Pool).UpdateCustomAppCapabilities(ctx, store.UpdateCustomAppCapabilitiesParams{
		WorkspaceID:  ws,
		Capabilities: b,
		UserID:       userID,
		Slug:         slug,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return decodeCapabilities(row.Capabilities), nil
}

func (s *Service) Delete(ctx context.Context, ws, userID uuid.UUID, slug string) error {
	return pgx.BeginTxFunc(ctx, s.Pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		q := store.New(tx)
		app, err := q.DeleteCustomApp(ctx, store.DeleteCustomAppParams{WorkspaceID: ws, UserID: userID, Slug: slug})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		if err := q.DeleteCustomAppDockChats(ctx, store.DeleteCustomAppDockChatsParams{
			WorkspaceID: ws,
			UserID:      userID,
			Scope:       "app:custom:" + slug,
		}); err != nil {
			return err
		}
		if app.SpaceID != nil {
			if err := q.DeleteCustomAppSpace(ctx, *app.SpaceID); err != nil {
				return err
			}
		}
		return nil
	})
}

func (s *Service) ListMCPServers(ctx context.Context, ws, userID uuid.UUID) ([]MCPServerApp, error) {
	rows, err := store.New(s.Pool).ListCustomAppsWithMCP(ctx, store.ListCustomAppsWithMCPParams{WorkspaceID: ws, UserID: userID})
	if err != nil {
		return nil, err
	}
	out := make([]MCPServerApp, 0, len(rows))
	for _, r := range rows {
		out = append(out, MCPServerApp{
			ID:           r.ID,
			WorkspaceID:  ws,
			UserID:       userID,
			Slug:         r.Slug,
			Name:         r.Name,
			Description:  r.Description,
			Manifest:     decodeManifest(r.Manifest),
			Capabilities: decodeCapabilities(r.Capabilities),
			CurrentSeq:   r.CurrentSeq,
			BundleMCPJS:  r.BundleMcpJs,
			Tools:        decodeMCPTools(r.McpTools),
		})
	}
	return out, nil
}

func (s *Service) GetMCPServer(ctx context.Context, ws, userID uuid.UUID, slug string) (MCPServerApp, error) {
	row, err := store.New(s.Pool).GetCustomAppWithMCPBySlug(ctx, store.GetCustomAppWithMCPBySlugParams{
		WorkspaceID: ws,
		UserID:      userID,
		Slug:        slug,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return MCPServerApp{}, apperr.ErrNotFound
	}
	if err != nil {
		return MCPServerApp{}, err
	}
	return mcpServerFromRow(row.ID, row.WorkspaceID, row.UserID, row.Slug, row.Name, row.Description, row.Manifest, row.Capabilities, row.CurrentSeq, row.BundleMcpJs, row.McpTools), nil
}

func (s *Service) GetMCPServerByID(ctx context.Context, ws, userID, id uuid.UUID) (MCPServerApp, error) {
	row, err := store.New(s.Pool).GetCustomAppWithMCPByID(ctx, store.GetCustomAppWithMCPByIDParams{
		WorkspaceID: ws,
		UserID:      userID,
		ID:          id,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return MCPServerApp{}, apperr.ErrNotFound
	}
	if err != nil {
		return MCPServerApp{}, err
	}
	return mcpServerFromRow(row.ID, row.WorkspaceID, row.UserID, row.Slug, row.Name, row.Description, row.Manifest, row.Capabilities, row.CurrentSeq, row.BundleMcpJs, row.McpTools), nil
}

func mcpServerFromRow(id, ws, userID uuid.UUID, slug, name, desc string, manifest, caps json.RawMessage, seq int32, bundle string, tools json.RawMessage) MCPServerApp {
	return MCPServerApp{
		ID:           id,
		WorkspaceID:  ws,
		UserID:       userID,
		Slug:         slug,
		Name:         name,
		Description:  desc,
		Manifest:     decodeManifest(manifest),
		Capabilities: decodeCapabilities(caps),
		CurrentSeq:   seq,
		BundleMCPJS:  bundle,
		Tools:        decodeMCPTools(tools),
	}
}

// CallMCPTool invokes one named tool in a custom app's MCP server using
// the provided options (SQLite, Secrets, API bridge, interactivity flags).
func (s *Service) CallMCPTool(ctx context.Context, app MCPServerApp, tool string, args map[string]any, opts MCPCallContext) (any, error) {
	opts.WorkspaceID = app.WorkspaceID
	opts.UserID = app.UserID
	opts.Slug = app.Slug
	opts.AppName = app.Name
	opts.Capabilities = app.Capabilities
	opts.BundleJS = app.BundleMCPJS
	if opts.Q == nil && s.Pool != nil {
		opts.Q = store.New(s.Pool)
	}
	if opts.Secrets == nil {
		opts.Secrets = s.Secrets
	}
	if opts.NodeBinary == "" {
		opts.NodeBinary = s.NodeBinary
	}
	if opts.SQLQuery == nil {
		opts.SQLQuery = func(qctx context.Context, query string, params []any) (SQLResult, error) {
			return s.QuerySQL(qctx, app.WorkspaceID, app.UserID, app.Slug, query, params)
		}
	}
	if opts.OnGrantCapability == nil && opts.Interactive && opts.AlwaysAllow && s.Pool != nil {
		opts.OnGrantCapability = func(gctx context.Context, capKey string) error {
			nextCaps := make(Capabilities, len(app.Capabilities)+1)
			for k, v := range app.Capabilities {
				nextCaps[k] = v
			}
			nextCaps[capKey] = agentdef.Allowed
			_, err := s.SetCapabilities(gctx, app.WorkspaceID, app.UserID, app.Slug, nextCaps)
			return err
		}
	}
	return CallMCPTool(ctx, opts, tool, args)
}

func (s *Service) compileMCPServer(ctx context.Context, m Manifest, files map[string]string) (string, []byte, error) {
	if strings.TrimSpace(m.MCPEntry) == "" {
		return "", []byte("[]"), nil
	}
	bundleMCP, err := BundleMCPServer(m.MCPEntry, files)
	if err != nil {
		return "", nil, err
	}
	tools, err := ExtractMCPTools(ctx, s.NodeBinary, bundleMCP)
	if err != nil {
		return "", nil, err
	}
	toolsJSON, err := json.Marshal(tools)
	if err != nil {
		return "", nil, err
	}
	return bundleMCP, toolsJSON, nil
}

func decodeMCPTools(raw []byte) []MCPToolSpec {
	if len(raw) == 0 {
		return nil
	}
	var out []MCPToolSpec
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil
	}
	return out
}

func hasSQLTokens(s string) bool {
	tokens, _ := tokenizeSQL(s)
	return len(tokens) > 0
}

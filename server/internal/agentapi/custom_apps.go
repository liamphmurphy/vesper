package agentapi

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/customapps"
)

func customAppsService(d Deps) (*customapps.Service, error) {
	if d.CustomApps == nil {
		return nil, apperr.Conflict("custom apps are unavailable")
	}
	return d.CustomApps, nil
}

type ListCustomAppsIn struct{}

func listCustomApps(ctx context.Context, d Deps, c agents.Caller, _ ListCustomAppsIn) (any, error) {
	svc, err := customAppsService(d)
	if err != nil {
		return nil, err
	}
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	apps, err := svc.List(ctx, c.Agent.WorkspaceID, s.UserID)
	if err != nil {
		return nil, err
	}
	items := make([]map[string]any, len(apps))
	for i, a := range apps {
		items[i] = map[string]any{
			"slug":              a.Slug,
			"name":              a.Name,
			"description":       a.Description,
			"icon":              a.Icon,
			"version":           a.CurrentSeq,
			"tool_scope":        a.Manifest.ToolScope,
			"has_mcp_server":    a.HasMCPServer,
			"mcp_tools":         a.MCPTools,
			"capabilities":      a.Capabilities,
			"configured_mounts": configuredMounts(a.Mounts),
			"db_size_bytes":     a.DBSizeBytes,
			"url":               "/apps/" + a.Slug,
		}
	}
	return map[string]any{"apps": items}, nil
}

type GetCustomAppIn struct {
	Slug      string   `json:"slug" jsonschema:"Custom app URL slug, e.g. finance"`
	Files     []string `json:"files,omitempty" jsonschema:"Only return these source files, e.g. [\"app.tsx\"]; omit for all"`
	OmitFiles bool     `json:"omit_files,omitempty" jsonschema:"Return no file contents, only file_sizes (useful before reading or editing a large app)"`
}

func getCustomApp(ctx context.Context, d Deps, c agents.Caller, in GetCustomAppIn) (any, error) {
	svc, err := customAppsService(d)
	if err != nil {
		return nil, err
	}
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	slug, err := customapps.ValidSlug(in.Slug)
	if err != nil {
		return nil, err
	}
	app, err := svc.Get(ctx, c.Agent.WorkspaceID, s.UserID, slug)
	if err != nil {
		return nil, err
	}
	sizes := make(map[string]int, len(app.Current.Files))
	for name, content := range app.Current.Files {
		sizes[name] = len(content)
	}
	files, err := selectAppFiles(app.Current.Files, in.Files, in.OmitFiles)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"slug":              app.Slug,
		"name":              app.Name,
		"description":       app.Description,
		"icon":              app.Icon,
		"version":           app.CurrentSeq,
		"manifest":          app.Manifest,
		"capabilities":      app.Capabilities,
		"configured_mounts": configuredMounts(app.Mounts),
		"has_mcp_server":    app.HasMCPServer,
		"mcp_tools":         app.MCPTools,
		"db_size_bytes":     app.DBSizeBytes,
		"file_sizes":        sizes,
		"files":             files,
		"versions":          app.Versions,
		"schema":            app.Schema,
		"url":               "/apps/" + app.Slug,
	}, nil
}

// selectAppFiles narrows get_custom_app's file contents so large apps can be read
// one file at a time. Asking for a file the app doesn't have is an error.
func selectAppFiles(all map[string]string, want []string, omit bool) (map[string]string, error) {
	if omit {
		return map[string]string{}, nil
	}
	if len(want) == 0 {
		return all, nil
	}
	out := make(map[string]string, len(want))
	for _, name := range want {
		content, ok := all[name]
		if !ok {
			return nil, apperr.Invalid("files", "%q is not a file in this app", name)
		}
		out[name] = content
	}
	return out, nil
}

func configuredMounts(m customapps.Mounts) []string {
	names := make([]string, 0, len(m))
	for k, v := range m {
		if strings.TrimSpace(v) != "" {
			names = append(names, k)
		}
	}
	slices.Sort(names)
	return names
}

type CreateCustomAppIn struct {
	Slug        string               `json:"slug" jsonschema:"URL slug (lowercase letters, digits, hyphens, 1-48 chars, e.g. finance). Reserved: docs, slides, designs, new."`
	Name        string               `json:"name" jsonschema:"Display name, 1-80 characters"`
	Description string               `json:"description,omitempty" jsonschema:"Short summary shown in Apps menu and launcher"`
	Icon        string               `json:"icon,omitempty" jsonschema:"Vesper icon name (e.g. dashboard, chart, check, tickets, clock)"`
	Template    string               `json:"template,omitempty" jsonschema:"Starter template when files are omitted: blank, tracker, or ledger"`
	Manifest    *customapps.Manifest `json:"manifest,omitempty" jsonschema:"App manifest (entry, mcp_entry e.g. server.ts, tool_scope chats|app_only, instructions, nav, requested_capabilities, requested_mounts)"`
	Files       map[string]string    `json:"files,omitempty" jsonschema:"Source files keyed by path (e.g. app.tsx, server.ts, styles.css, schema.sql). UI compiles with React 19 + @vesper/bridge; optional server.ts compiles with @vesper/server (defineServer, sql, secretFetch, fetch, api, media, nix) and runs as a sandboxed MCP server."`
	Note        string               `json:"note,omitempty" jsonschema:"Short version note"`
}

func createCustomApp(ctx context.Context, d Deps, c agents.Caller, in CreateCustomAppIn) (any, error) {
	svc, err := customAppsService(d)
	if err != nil {
		return nil, err
	}
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	app, err := svc.Create(ctx, c.Agent.WorkspaceID, s.UserID, customapps.CreateInput{
		Slug:        in.Slug,
		Name:        in.Name,
		Description: in.Description,
		Icon:        in.Icon,
		Template:    in.Template,
		Manifest:    in.Manifest,
		Files:       in.Files,
		Note:        in.Note,
		AuthorType:  "persona",
		AgentID:     &c.Agent.ID,
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"slug":           app.Slug,
		"name":           app.Name,
		"version":        app.CurrentSeq,
		"has_mcp_server": app.HasMCPServer,
		"mcp_tools":      app.MCPTools,
		"schema":         app.Schema,
		"url":            "/apps/" + app.Slug,
	}, nil
}

type UpdateCustomAppIn struct {
	Slug         string                `json:"slug" jsonschema:"Custom app slug to update"`
	Name         *string               `json:"name,omitempty"`
	Description  *string               `json:"description,omitempty"`
	Icon         *string               `json:"icon,omitempty"`
	Manifest     *customapps.Manifest  `json:"manifest,omitempty"`
	Files        map[string]string     `json:"files,omitempty" jsonschema:"Files to add or overwrite (merged with existing unless replace_files is true)"`
	ReplaceFiles bool                  `json:"replace_files,omitempty" jsonschema:"Replace all source files with the passed files map"`
	RemoveFiles  []string              `json:"remove_files,omitempty" jsonschema:"Relative file paths to delete"`
	Edits        []customapps.FileEdit `json:"edits,omitempty" jsonschema:"Find/replace edits to existing files, applied in order after files and remove_files. Prefer these over resending whole files for small changes."`
	Note         string                `json:"note,omitempty" jsonschema:"Short version note"`
	RestoreSeq   *int32                `json:"restore_seq,omitempty" jsonschema:"Restore files and manifest from this earlier version number as a new version"`
}

func updateCustomApp(ctx context.Context, d Deps, c agents.Caller, in UpdateCustomAppIn) (any, error) {
	svc, err := customAppsService(d)
	if err != nil {
		return nil, err
	}
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	slug, err := customapps.ValidSlug(in.Slug)
	if err != nil {
		return nil, err
	}
	app, err := svc.Update(ctx, c.Agent.WorkspaceID, s.UserID, slug, customapps.UpdateInput{
		Name:         in.Name,
		Description:  in.Description,
		Icon:         in.Icon,
		Manifest:     in.Manifest,
		Files:        in.Files,
		ReplaceFiles: in.ReplaceFiles,
		RemoveFiles:  in.RemoveFiles,
		Edits:        in.Edits,
		Note:         in.Note,
		RestoreSeq:   in.RestoreSeq,
		AuthorType:   "persona",
		AgentID:      &c.Agent.ID,
	})
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"slug":           app.Slug,
		"name":           app.Name,
		"version":        app.CurrentSeq,
		"has_mcp_server": app.HasMCPServer,
		"mcp_tools":      app.MCPTools,
		"schema":         app.Schema,
		"url":            "/apps/" + app.Slug,
	}, nil
}

type DeleteCustomAppIn struct {
	Slug string `json:"slug" jsonschema:"Custom app slug to delete permanently"`
}

func deleteCustomApp(ctx context.Context, d Deps, c agents.Caller, in DeleteCustomAppIn) (any, error) {
	svc, err := customAppsService(d)
	if err != nil {
		return nil, err
	}
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	slug, err := customapps.ValidSlug(in.Slug)
	if err != nil {
		return nil, err
	}
	if err := svc.Delete(ctx, c.Agent.WorkspaceID, s.UserID, slug); err != nil {
		return nil, err
	}
	return map[string]any{"deleted": slug}, nil
}

type CustomAppSQLIn struct {
	Slug   string `json:"slug" jsonschema:"Custom app slug"`
	Query  string `json:"query" jsonschema:"Parameterized SQLite query (SELECT/INSERT/UPDATE/DELETE/CREATE/ALTER). Use ? placeholders for params."`
	Params []any  `json:"params,omitempty" jsonschema:"Positional ? parameters matching the SQL query"`
}

func customAppSQL(ctx context.Context, d Deps, c agents.Caller, in CustomAppSQLIn) (any, error) {
	svc, err := customAppsService(d)
	if err != nil {
		return nil, err
	}
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	slug, err := customapps.ValidSlug(in.Slug)
	if err != nil {
		return nil, err
	}
	app, err := svc.Get(ctx, c.Agent.WorkspaceID, s.UserID, slug)
	if err != nil {
		return nil, err
	}
	if app.Manifest.ToolScope == customapps.ToolScopeAppOnly {
		notHere := apperr.Conflict("custom_app_sql for %q is scoped to that app's own dock chat (/apps/%s)", app.Slug, app.Slug)
		if c.RunID == nil {
			return nil, notHere
		}
		chat, err := d.Q.ChatSessionForRun(ctx, c.RunID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, notHere
		}
		if err != nil {
			return nil, err
		}
		if chat.SpaceID == nil {
			return nil, notHere
		}
		sp, err := d.Q.GetChatSpaceByID(ctx, *chat.SpaceID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, notHere
		}
		if err != nil {
			return nil, err
		}
		if sp.UserID != s.UserID || sp.App == nil || *sp.App != "custom:"+app.Slug {
			return nil, notHere
		}
	}
	if strings.TrimSpace(in.Query) == "" {
		return nil, apperr.Invalid("query", "SQL query is required")
	}
	return svc.QuerySQL(ctx, c.Agent.WorkspaceID, s.UserID, app.Slug, in.Query, in.Params)
}

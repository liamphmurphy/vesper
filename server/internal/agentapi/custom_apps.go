package agentapi

import (
	"context"
	"errors"
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
			"slug":           a.Slug,
			"name":           a.Name,
			"description":    a.Description,
			"icon":           a.Icon,
			"version":        a.CurrentSeq,
			"tool_scope":     a.Manifest.ToolScope,
			"has_mcp_server": a.HasMCPServer,
			"mcp_tools":      a.MCPTools,
			"capabilities":   a.Capabilities,
			"db_size_bytes":  a.DBSizeBytes,
			"url":            "/apps/" + a.Slug,
		}
	}
	return map[string]any{"apps": items}, nil
}

type GetCustomAppIn struct {
	Slug string `json:"slug" jsonschema:"Custom app URL slug, e.g. finance"`
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
	return map[string]any{
		"slug":           app.Slug,
		"name":           app.Name,
		"description":    app.Description,
		"icon":           app.Icon,
		"version":        app.CurrentSeq,
		"manifest":       app.Manifest,
		"capabilities":   app.Capabilities,
		"has_mcp_server": app.HasMCPServer,
		"mcp_tools":      app.MCPTools,
		"db_size_bytes":  app.DBSizeBytes,
		"files":          app.Current.Files,
		"versions":       app.Versions,
		"schema":         app.Schema,
		"url":            "/apps/" + app.Slug,
	}, nil
}

type CreateCustomAppIn struct {
	Slug        string               `json:"slug" jsonschema:"URL slug (lowercase letters, digits, hyphens, 1-48 chars, e.g. finance). Reserved: docs, slides, designs, new."`
	Name        string               `json:"name" jsonschema:"Display name, 1-80 characters"`
	Description string               `json:"description,omitempty" jsonschema:"Short summary shown in Apps menu and launcher"`
	Icon        string               `json:"icon,omitempty" jsonschema:"Vesper icon name (e.g. dashboard, chart, check, tickets, clock)"`
	Template    string               `json:"template,omitempty" jsonschema:"Starter template when files are omitted: blank, tracker, or ledger"`
	Manifest    *customapps.Manifest `json:"manifest,omitempty" jsonschema:"App manifest (entry, mcp_entry e.g. server.ts, tool_scope chats|app_only, instructions, nav, requested_capabilities)"`
	Files       map[string]string    `json:"files,omitempty" jsonschema:"Source files keyed by path (e.g. app.tsx, server.ts, styles.css, schema.sql). UI compiles with React 19 + @vesper/bridge; optional server.ts compiles with @vesper/server (defineServer, sql, secretFetch, fetch, api) and runs as a sandboxed MCP server."`
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
	Slug         string               `json:"slug" jsonschema:"Custom app slug to update"`
	Name         *string              `json:"name,omitempty"`
	Description  *string              `json:"description,omitempty"`
	Icon         *string              `json:"icon,omitempty"`
	Manifest     *customapps.Manifest `json:"manifest,omitempty"`
	Files        map[string]string    `json:"files,omitempty" jsonschema:"Files to add or overwrite (merged with existing unless replace_files is true)"`
	ReplaceFiles bool                 `json:"replace_files,omitempty" jsonschema:"Replace all source files with the passed files map"`
	RemoveFiles  []string             `json:"remove_files,omitempty" jsonschema:"Relative file paths to delete"`
	Note         string               `json:"note,omitempty" jsonschema:"Short version note"`
	RestoreSeq   *int32               `json:"restore_seq,omitempty" jsonschema:"Restore files and manifest from this earlier version number as a new version"`
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

package wiki

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/links"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type PageQuery struct {
	Text         string               `json:"text,omitempty"`
	Folder       string               `json:"folder,omitempty"`
	Tag          string               `json:"tag,omitempty"`
	Audience     string               `json:"audience,omitempty"`
	Properties   artifacts.Properties `json:"properties,omitempty"`
	After        *time.Time           `json:"after,omitempty"`
	Before       *time.Time           `json:"before,omitempty"`
	LinksTo      *uuid.UUID           `json:"links_to,omitempty"`
	Orphans      bool                 `json:"orphans,omitempty"`
	Unresolved   bool                 `json:"unresolved,omitempty"`
	IncludeAgent bool                 `json:"include_agent,omitempty"`
	Limit        int                  `json:"limit,omitempty"`
	Offset       int                  `json:"offset,omitempty"`
}

type PageRow struct {
	ID         uuid.UUID            `json:"id"`
	Title      string               `json:"title"`
	Path       string               `json:"path"`
	Audience   string               `json:"audience"`
	Summary    string               `json:"summary"`
	Properties artifacts.Properties `json:"properties"`
	Updated    time.Time            `json:"updated_at"`
	Version    *uuid.UUID           `json:"version_id"`
	Pending    int                  `json:"pending"`
	Unresolved int                  `json:"unresolved"`
	// Kind is what the page holds: document, or a deck or design whose body is CanvasID (LAZYAGENTS-212).
	Kind     string     `json:"kind"`
	CanvasID *uuid.UUID `json:"canvas_id,omitempty"`
}

// PageKind is what a page linked to a canvas of canvasKind holds: a deck, a design, else a document.
func PageKind(canvasKind string) string {
	switch canvasKind {
	case "deck", "design":
		return canvasKind
	default:
		return "document"
	}
}

type PageTable struct {
	Columns []string  `json:"columns"`
	Rows    []PageRow `json:"rows"`
	HasMore bool      `json:"has_more"`
}

func QueryPages(ctx context.Context, q *store.Queries, ws uuid.UUID, in PageQuery) (PageTable, error) {
	out := PageTable{Columns: []string{"title", "path", "audience", "properties", "updated_at"}, Rows: []PageRow{}}
	if in.Limit <= 0 {
		in.Limit = 50
	}
	in.Limit = min(200, in.Limit)
	in.Offset = max(0, in.Offset)
	if in.LinksTo != nil {
		if _, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: *in.LinksTo, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return out, apperr.ErrNotFound
			}
			return out, err
		}
	}
	props, err := artifacts.NormalizeProperties(in.Properties)
	if in.Properties == nil {
		props = []byte("{}")
		err = nil
	}
	if err != nil {
		return out, err
	}
	rows, err := q.QueryPages(ctx, store.QueryPagesParams{WorkspaceID: ws, Viewer: pageview.From(ctx).UserID, IncludeAgent: in.IncludeAgent || pageview.From(ctx).IncludeAgent, Audience: in.Audience, Folder: strings.Trim(in.Folder, "/"), TextQuery: in.Text, Tag: strings.TrimPrefix(in.Tag, "#"), Properties: props, AfterDate: in.After, BeforeDate: in.Before, LinksTo: in.LinksTo, Orphans: in.Orphans, UnresolvedOnly: in.Unresolved, PageLimit: int32(in.Limit + 1), PageOffset: int32(in.Offset)})
	if err != nil {
		return out, err
	}
	if len(rows) > in.Limit {
		out.HasMore = true
		rows = rows[:in.Limit]
	}
	for _, a := range rows {
		out.Rows = append(out.Rows, PageRow{ID: a.ID, Title: a.Title, Path: deref(a.Path), Audience: a.Audience, Summary: a.Summary, Properties: artifacts.DecodeProperties(a.Properties), Updated: a.UpdatedAt, Version: a.CurrentVersionID, Pending: int(a.Pending), Unresolved: int(a.Unresolved), Kind: PageKind(a.CanvasKind), CanvasID: a.CanvasID})
	}
	return out, nil
}

// Saved queries are page properties, so they version, export and import with
// the structure note instead of living in another store.
func SavedPageQuery(ctx context.Context, q *store.Queries, ws, id uuid.UUID) (PageTable, error) {
	a, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return PageTable{}, err
	}
	if a.CurrentVersionID == nil {
		return PageTable{}, apperr.ErrNotFound
	}
	v, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return PageTable{}, err
	}
	p := artifacts.DecodeProperties(v.Properties)
	raw, err := json.Marshal(p["query"])
	if text, ok := p["query"].(string); ok {
		raw = []byte(text)
	}
	if err != nil {
		return PageTable{}, err
	}
	var query PageQuery
	if err = json.Unmarshal(raw, &query); err != nil || string(raw) == "null" {
		return PageTable{}, apperr.Invalid("query", "this page has no saved query")
	}
	return QueryPages(ctx, q, ws, query)
}

// OpenPage resolves IDs as well as paths without exposing whether an
// inaccessible private ID exists.
func OpenPage(ctx context.Context, q *store.Queries, ws uuid.UUID, ref string) (store.Artifact, store.ArtifactVersion, error) {
	var a store.Artifact
	var err error
	if id, parseErr := uuid.Parse(ref); parseErr == nil {
		a, err = q.GetArtifact(ctx, store.GetArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	} else {
		target, e := links.Resolve(ctx, q, ws, ref, "")
		if e != nil {
			return a, store.ArtifactVersion{}, e
		}
		if target.ID == nil || target.Kind != links.KindArtifact {
			return a, store.ArtifactVersion{}, apperr.ErrNotFound
		}
		a, err = q.GetArtifact(ctx, store.GetArtifactParams{ID: *target.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	}
	if err != nil {
		if err == pgx.ErrNoRows {
			err = apperr.ErrNotFound
		}
		return a, store.ArtifactVersion{}, err
	}
	if a.Type != "note" || a.CurrentVersionID == nil {
		return a, store.ArtifactVersion{}, apperr.ErrNotFound
	}
	v, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	return a, v, err
}

type PagePatch struct {
	Before string `json:"before"`
	After  string `json:"after"`
	Why    string `json:"why"`
}

func PageURL(id uuid.UUID, title string) string {
	return fmt.Sprintf("/knowledge/%s/%s", id, links.Slug(title))
}

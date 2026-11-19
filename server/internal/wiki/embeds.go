package wiki

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/design"
	"github.com/liamphmurphy/vesper/server/internal/links"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type Embed struct {
	Ref         string         `json:"ref"`
	Kind        string         `json:"kind"`
	Title       string         `json:"title,omitempty"`
	Markdown    string         `json:"markdown,omitempty"`
	URL         string         `json:"url,omitempty"`
	ContentType string         `json:"content_type,omitempty"`
	Available   bool           `json:"available"`
	Data        map[string]any `json:"data,omitempty"`
}

// ResolveEmbeds returns a single level. It never recursively expands cycles or
// lets the visibility of the containing page grant access to its targets.
func ResolveEmbeds(ctx context.Context, q *store.Queries, ws uuid.UUID, body string) ([]Embed, error) {
	return ResolvePageEmbeds(ctx, q, ws, uuid.Nil, body)
}
func ResolvePageEmbeds(ctx context.Context, q *store.Queries, ws, pageID uuid.UUID, body string) ([]Embed, error) {
	out := []Embed{}
	for _, ref := range links.Parse(body) {
		if !ref.Embed {
			continue
		}
		e := Embed{Ref: ref.Raw, Kind: "unresolved"}
		if raw, ok := strings.CutPrefix(ref.Target, "attachment:"); ok {
			id, err := uuid.Parse(strings.SplitN(raw, "/", 2)[0])
			if err != nil {
				out = append(out, e)
				continue
			}
			asset, err := q.GetKnowledgeAsset(ctx, store.GetKnowledgeAssetParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
			if err == nil {
				e = Embed{Ref: ref.Raw, Kind: "file", Title: asset.Filename, Available: true, URL: "/api/v1/knowledge/assets/" + id.String(), ContentType: asset.ContentType}
			} else if !errors.Is(err, pgx.ErrNoRows) {
				return nil, err
			}
			out = append(out, e)
			continue
		}
		if raw, ok := strings.CutPrefix(ref.Target, "library:"); ok {
			if viewer := pageview.From(ctx).UserID; viewer != nil {
				if id, err := uuid.Parse(raw); err == nil {
					item, err := q.GetLibraryItem(ctx, store.GetLibraryItemParams{ID: id, WorkspaceID: ws, UserID: *viewer})
					if err == nil && (item.Kind == "image" || item.Kind == "video") {
						e = Embed{Ref: ref.Raw, Kind: item.Kind, Title: item.Title, URL: "/api/v1/library/" + id.String() + "/content", ContentType: item.ContentType, Available: true}
					} else if err == nil && (item.Kind == "file" || item.Kind == "export" || item.Kind == "document") && item.ContentType == "application/pdf" {
						e = Embed{Ref: ref.Raw, Kind: "file", Title: item.Title, URL: "/api/v1/library/" + id.String() + "/content", ContentType: item.ContentType, Available: true}
					} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
						return nil, err
					}
				}
			}
			out = append(out, e)
			continue
		}
		if raw, ok := strings.CutPrefix(ref.Target, "design:"); ok {
			if viewer := pageview.From(ctx).UserID; viewer != nil {
				if id, err := uuid.Parse(raw); err == nil {
					canvas, err := q.GetUserCanvas(ctx, store.GetUserCanvasParams{ID: id, WorkspaceID: ws, UserID: *viewer})
					if err == nil && canvas.Kind == "design" {
						node, found := design.NodeOf(canvas.Body, ref.Anchor)
						if found && node["type"] == "frame" {
							e = Embed{Ref: ref.Raw, Kind: "design", Title: canvas.Title, URL: "/apps/designs/" + id.String() + "#" + ref.Anchor, Data: node, Available: true}
						}
					} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
						return nil, err
					}
				}
			}
			out = append(out, e)
			continue
		}
		target := ref.Target
		if target == "" && pageID != uuid.Nil {
			target = pageID.String()
		}
		a, v, err := OpenPage(ctx, q, ws, target)
		if err != nil {
			if !errors.Is(err, pgx.ErrNoRows) && !errors.Is(err, apperr.ErrNotFound) {
				return nil, err
			}
			out = append(out, e)
			continue
		}
		text := deref(v.BodyMd)
		if ref.Anchor != "" {
			anchor := links.Slug(ref.Anchor)
			if strings.HasPrefix(ref.Anchor, "^") {
				anchor = ref.Anchor
			}
			var ok bool
			text, ok = artifacts.SectionText(text, anchor)
			if !ok {
				out = append(out, e)
				continue
			}
		}
		out = append(out, Embed{Ref: ref.Raw, Kind: "page", Title: a.Title, Markdown: text, Available: true, URL: PageURL(a.ID, a.Title)})
	}
	return out, nil
}

func AttachmentRef(id uuid.UUID, filename string) string {
	return fmt.Sprintf("attachment:%s/%s", id, strings.NewReplacer("[", " ", "]", " ", "#", " ", "|", " ", "^", " ", "\n", " ").Replace(filename))
}

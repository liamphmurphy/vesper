package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// The Knowledge surface is mounted beside the generated legacy wiki API.
// Its streaming routes and JSON contracts are in api/knowledge.openapi.yaml.
func (s *Server) knowledgeRoutes(mux *http.ServeMux) {
	handle := func(pattern string, fn func(*http.Request) (any, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			result, err := fn(r)
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					err = apperr.ErrNotFound
				}
				s.responseError(w, r, err)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Cache-Control", "no-store")
			json.NewEncoder(w).Encode(result)
		})
	}
	handle("GET /api/v1/knowledge/pages", func(r *http.Request) (any, error) {
		_, _, ws := me(r.Context())
		query := wiki.PageQuery{Text: r.URL.Query().Get("q"), Tag: r.URL.Query().Get("tag"), Folder: r.URL.Query().Get("folder"), Audience: r.URL.Query().Get("audience"), IncludeAgent: r.URL.Query().Get("include_agent") == "true", Orphans: r.URL.Query().Get("orphans") == "true", Unresolved: r.URL.Query().Get("unresolved") == "true"}
		query.Limit, _ = strconv.Atoi(r.URL.Query().Get("limit"))
		query.Offset, _ = strconv.Atoi(r.URL.Query().Get("offset"))
		return wiki.QueryPages(r.Context(), s.Q, ws, query)
	})
	handle("POST /api/v1/knowledge/query", func(r *http.Request) (any, error) {
		_, _, ws := me(r.Context())
		var in wiki.PageQuery
		if err := knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		return wiki.QueryPages(r.Context(), s.Q, ws, in)
	})
	handle("POST /api/v1/knowledge/pages", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		var in knowledgePageInput
		if err := knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		res, err := s.Wiki.SaveAsUser(r.Context(), ws, u.ID, in.save(wiki.ModeCreate))
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, res.Note.ID)
	})
	handle("GET /api/v1/knowledge/pages/{id}", func(r *http.Request) (any, error) {
		_, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, id)
	})
	handle("PUT /api/v1/knowledge/pages/{id}", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		var in knowledgePageInput
		if err = knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		var body *string
		if in.Body != nil {
			body = in.Body
		}
		_, err = s.Wiki.UpdateAsUser(r.Context(), ws, u.ID, id, in.save(""), in.Path, body)
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, id)
	})
	handle("DELETE /api/v1/knowledge/pages/{id}", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		if err = s.Wiki.DeletePageAsUser(r.Context(), ws, u.ID, id); err != nil {
			return nil, err
		}
		return map[string]any{"deleted": []uuid.UUID{id}}, nil
	})
	// Folders are path prefixes, so these act on every page under one in the
	// explorer view it belongs to (agent knowledge or the person's own).
	handle("POST /api/v1/knowledge/folders/move", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		var in struct {
			From  string `json:"from"`
			To    string `json:"to"`
			Agent bool   `json:"agent"`
		}
		if err := knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		moved, err := s.Wiki.MoveFolder(r.Context(), ws, u.ID, wiki.FolderScope{Folder: in.From, Agent: in.Agent}, in.To)
		if err != nil {
			return nil, err
		}
		return map[string]any{"moved": moved}, nil
	})
	handle("POST /api/v1/knowledge/folders/delete", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		var in struct {
			Folder string `json:"folder"`
			Agent  bool   `json:"agent"`
		}
		if err := knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		deleted, err := s.Wiki.DeleteFolder(r.Context(), ws, u.ID, wiki.FolderScope{Folder: in.Folder, Agent: in.Agent})
		if err != nil {
			return nil, err
		}
		return map[string]any{"deleted": deleted}, nil
	})
	handle("PUT /api/v1/knowledge/pages/{id}/controls", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		var in struct {
			Direct bool `json:"direct"`
			Paused bool `json:"paused"`
		}
		if err = knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		_, err = s.Q.SetPageControls(r.Context(), store.SetPageControlsParams{ID: id, WorkspaceID: ws, Viewer: &u.ID, Direct: in.Direct, Paused: in.Paused})
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, id)
	})
	// A page's conversation: the person starts a chat from the page and it
	// stays attached, so its persona reads and edits the page with them.
	handle("PUT /api/v1/knowledge/pages/{id}/chat", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		var in struct {
			ChatID uuid.UUID `json:"chat_id"`
		}
		if err = knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		chat, err := s.Q.GetChatSession(r.Context(), store.GetChatSessionParams{ID: in.ChatID, WorkspaceID: ws})
		if err != nil || chat.CreatedBy != u.ID {
			return nil, apperr.ErrNotFound
		}
		if err = s.Q.SetPageChat(r.Context(), store.SetPageChatParams{ID: id, WorkspaceID: ws, Viewer: &u.ID, ChatID: &chat.ID}); err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, id)
	})
	handle("POST /api/v1/knowledge/pages/{id}/reviews/{version}/resolve", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		vid, err := knowledgeID(r, "version")
		if err != nil {
			return nil, err
		}
		var in struct {
			Decisions []wiki.ReviewDecision `json:"decisions"`
		}
		if err = knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		_, err = s.Wiki.ResolveChanges(r.Context(), ws, u.ID, id, vid, in.Decisions)
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, id)
	})
	handle("POST /api/v1/knowledge/pages/{id}/restore/{version}", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		vid, err := knowledgeID(r, "version")
		if err != nil {
			return nil, err
		}
		_, err = s.Wiki.RestorePage(r.Context(), ws, u.ID, id, vid)
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, id)
	})
	handle("GET /api/v1/knowledge/pages/{id}/query", func(r *http.Request) (any, error) {
		_, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		return wiki.SavedPageQuery(r.Context(), s.Q, ws, id)
	})
	handle("GET /api/v1/knowledge/templates", func(r *http.Request) (any, error) { return map[string]any{"templates": wiki.TemplateSet}, nil })
	handle("POST /api/v1/knowledge/daily", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		var in struct {
			Date     string `json:"date"`
			Folder   string `json:"folder"`
			Template string `json:"template"`
		}
		if err := knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		if in.Date == "" {
			in.Date = time.Now().UTC().Format("2006-01-02")
		}
		res, err := s.Wiki.DailyPage(r.Context(), ws, u.ID, in.Date, in.Folder, in.Template)
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, res.Note.ID)
	})
	handle("POST /api/v1/knowledge/capture", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		var in knowledgePageInput
		if err := knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		save := in.save(wiki.ModeCreate)
		if save.Title == nil {
			return nil, apperr.Invalid("title", "is required")
		}
		safe := wikiSafeTitle(*save.Title)
		save.Path = "Inbox/" + safe + " " + uuid.NewString()[:8]
		if save.Properties == nil {
			save.Properties = artifacts.Properties{}
		}
		save.Properties["type"] = "fleeting"
		save.Properties["zettel_id"] = uuid.NewString()
		res, err := s.Wiki.SaveAsUser(r.Context(), ws, u.ID, save)
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, res.Note.ID)
	})
	handle("POST /api/v1/knowledge/pages/{id}/file", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			return nil, err
		}
		var in struct {
			Folder string     `json:"folder"`
			Merge  *uuid.UUID `json:"merge"`
		}
		if err = knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		res, err := s.Wiki.FileCapture(r.Context(), ws, u.ID, id, in.Folder, in.Merge)
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, res.Note.ID)
	})
	handle("POST /api/v1/knowledge/pages/from-canvas", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		var in struct {
			ChatID   uuid.UUID `json:"chat_id"`
			CanvasID uuid.UUID `json:"canvas_id"`
			Folder   string    `json:"folder"`
		}
		if err := knowledgeJSON(r, &in); err != nil {
			return nil, err
		}
		res, err := s.Wiki.MoveCanvasToPage(r.Context(), ws, u.ID, in.ChatID, in.CanvasID, in.Folder)
		if err != nil {
			return nil, err
		}
		return s.knowledgePage(r.Context(), ws, res.Note.ID)
	})
	handle("GET /api/v1/knowledge/legacy", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		id, err := s.legacyPage(r.Context(), ws, u.ID, r.URL.Query().Get("path"))
		if err != nil {
			return nil, err
		}
		a, _, err := wiki.OpenPage(r.Context(), s.Q, ws, id.String())
		if err != nil {
			return nil, err
		}
		return map[string]any{"id": a.ID, "url": wiki.PageURL(a.ID, a.Title)}, nil
	})
	handle("GET /api/v1/knowledge/network", func(r *http.Request) (any, error) {
		u, _, ws := me(r.Context())
		params := store.KnowledgeNetworkNodesParams{WorkspaceID: ws, Viewer: &u.ID, IncludeAgent: r.URL.Query().Get("include_agent") == "true"}
		nodes, err := s.Q.KnowledgeNetworkNodes(r.Context(), params)
		if err != nil {
			return nil, err
		}
		links, err := s.Q.KnowledgeNetworkLinks(r.Context(), store.KnowledgeNetworkLinksParams(params))
		if err != nil {
			return nil, err
		}
		type node struct {
			ID       uuid.UUID `json:"id"`
			Title    string    `json:"title"`
			Path     string    `json:"path"`
			Audience string    `json:"audience"`
		}
		type edge struct {
			Source uuid.UUID  `json:"source"`
			Target *uuid.UUID `json:"target,omitempty"`
			// Unresolved names a page that doesn't exist yet.
			Unresolved string `json:"unresolved,omitempty"`
		}
		out := struct {
			Nodes []node `json:"nodes"`
			Links []edge `json:"links"`
		}{Nodes: []node{}, Links: []edge{}}
		for _, n := range nodes {
			out.Nodes = append(out.Nodes, node{ID: n.ID, Title: n.Title, Path: deref(n.Path), Audience: n.Audience})
		}
		for _, l := range links {
			if l.TargetKind == "unresolved" {
				out.Links = append(out.Links, edge{Source: l.SourceID, Unresolved: l.TargetText})
			} else if l.TargetID != nil && *l.TargetID != l.SourceID {
				out.Links = append(out.Links, edge{Source: l.SourceID, Target: l.TargetID})
			}
		}
		return out, nil
	})
	s.knowledgeAssetRoutes(mux)
	s.knowledgeImportRoutes(mux)
}

// legacyPage maps an address from before the merge, /apps/docs/<canvas id> or
// /wiki/<page path>, to the page that now holds it, so old links and
// bookmarks keep working. Visibility is the caller's, as for any page read.
func (s *Server) legacyPage(ctx context.Context, ws, user uuid.UUID, path string) (uuid.UUID, error) {
	if rest, ok := strings.CutPrefix(path, "/apps/docs/"); ok {
		canvasID, err := uuid.Parse(strings.SplitN(rest, "/", 2)[0])
		if err != nil {
			return uuid.Nil, apperr.ErrNotFound
		}
		a, err := s.Q.GetDocPageRedirect(ctx, store.GetDocPageRedirectParams{CanvasID: canvasID, WorkspaceID: ws, Viewer: &user})
		if err != nil {
			return uuid.Nil, err
		}
		return a.ID, nil
	}
	if rest, ok := strings.CutPrefix(path, "/wiki/"); ok && rest != "" {
		pagePath, err := url.PathUnescape(rest)
		if err != nil {
			return uuid.Nil, apperr.Invalid("path", "is not a valid address")
		}
		a, _, err := wiki.OpenPage(ctx, s.Q, ws, pagePath)
		if err != nil {
			return uuid.Nil, err
		}
		return a.ID, nil
	}
	return uuid.Nil, apperr.Invalid("path", "must start with /apps/docs/ or /wiki/")
}

type knowledgePageInput struct {
	Title       *string              `json:"title"`
	Path        *string              `json:"path"`
	Body        *string              `json:"body_md"`
	Properties  artifacts.Properties `json:"properties"`
	Audience    string               `json:"audience"`
	BaseVersion *uuid.UUID           `json:"base_version_id"`
	Note        string               `json:"note"`
	Template    string               `json:"template"`
}

func (in knowledgePageInput) save(mode string) wiki.Save {
	body := deref(in.Body)
	if in.Template != "" {
		body = wiki.RenderTemplate(wiki.TemplateSet[in.Template], deref(in.Title), time.Now().UTC().Format("2006-01-02"), in.Properties)
	}
	return wiki.Save{Title: in.Title, Path: deref(in.Path), Body: body, Properties: in.Properties, Audience: in.Audience, BaseID: in.BaseVersion, Note: in.Note, Mode: mode}
}
func wikiSafeTitle(s string) string {
	return strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		if strings.ContainsRune("[]#|^/\\", r) || r < 32 {
			return ' '
		}
		return r
	}, s)), " ")
}
func knowledgeJSON(r *http.Request, v any) error {
	dec := json.NewDecoder(io.LimitReader(r.Body, 4<<20))
	dec.DisallowUnknownFields()
	if err := dec.Decode(v); err != nil {
		return apperr.Invalid("body", "invalid JSON: %v", err)
	}
	var extra any
	if err := dec.Decode(&extra); err != io.EOF {
		return apperr.Invalid("body", "expected a single JSON object")
	}
	return nil
}
func knowledgeID(r *http.Request, key string) (uuid.UUID, error) {
	id, err := uuid.Parse(r.PathValue(key))
	if err != nil {
		return id, apperr.Invalid(key, "must be a UUID")
	}
	return id, nil
}
func (s *Server) knowledgePage(ctx context.Context, ws, id uuid.UUID) (any, error) {
	a, v, err := wiki.OpenPage(ctx, s.Q, ws, id.String())
	if err != nil {
		return nil, err
	}
	embeds, err := wiki.ResolvePageEmbeds(ctx, s.Q, ws, a.ID, deref(v.BodyMd))
	if err != nil {
		return nil, err
	}
	reviews, err := s.Q.ListPageReviews(ctx, store.ListPageReviewsParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	versions, err := s.Q.ListArtifactVersions(ctx, store.ListArtifactVersionsParams{ArtifactID: id, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	reviewRows := []map[string]any{}
	for _, rv := range reviews {
		reviewRows = append(reviewRows, map[string]any{"id": rv.ID, "state": rv.State, "review_state": rv.ReviewState, "changes": json.RawMessage(rv.Changes), "author_id": rv.CreatedByID, "created_at": rv.CreatedAt})
	}
	history := []map[string]any{}
	for _, version := range versions {
		history = append(history, map[string]any{"id": version.ID, "seq": version.Seq, "label": version.Label, "note": version.Note, "author_type": version.CreatedByType, "author_id": version.CreatedByID, "created_at": version.CreatedAt})
	}
	chatID := a.ChatSessionID
	if chatID != nil {
		chat, err := s.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: *chatID, WorkspaceID: ws})
		viewer := pageview.From(ctx).UserID
		if err != nil || viewer == nil || chat.CreatedBy != *viewer {
			chatID = nil
		}
	}
	kind := "document"
	if a.CanvasID != nil {
		ck, err := s.Q.CanvasKind(ctx, *a.CanvasID)
		if err != nil {
			return nil, err
		}
		kind = wiki.PageKind(ck)
	}
	return map[string]any{"id": a.ID, "title": a.Title, "path": a.Path, "audience": a.Audience, "kind": kind, "canvas_id": a.CanvasID, "body_md": v.BodyMd, "version_id": v.ID, "seq": v.Seq, "properties": artifacts.DecodeProperties(v.Properties), "direct": a.PersonaDirect, "paused": a.PersonaPaused, "chat_id": chatID, "embeds": embeds, "reviews": reviewRows, "versions": history, "url": wiki.PageURL(id, a.Title)}, nil
}

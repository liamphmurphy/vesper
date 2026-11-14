package httpapi

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/links"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// Wiki and knowledge endpoints (docs/dev/plan.md §12).

// same converts between structs that share JSON tags (domain → API); the
// shapes are fixed, so a failure is a programming error.
func same[T any](v any) T {
	out, err := recode[T](v)
	if err != nil {
		panic(err)
	}
	return out
}

func toTarget(t links.Target) api.LinkTarget { return same[api.LinkTarget](t) }

func toMentions(ms []wiki.Mention) []api.Mention { return same[[]api.Mention](ms) }

func (s *Server) ListWikiPages(ctx context.Context, req api.ListWikiPagesRequestObject) (api.ListWikiPagesResponseObject, error) {
	ctx = pageview.IncludeAgents(ctx, deref(req.Params.IncludeAgent))
	_, _, ws := me(ctx)
	rows, err := s.Q.ListNotes(ctx, store.ListNotesParams{WorkspaceID: ws, Tag: req.Params.Tag, Viewer: pageview.From(ctx).UserID, IncludeAgent: pageview.From(ctx).IncludeAgent})
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := api.ListWikiPages200JSONResponse{Pages: make([]api.WikiPageSummary, 0, len(rows))}
	for _, r := range rows {
		kind := pageKind(r.CanvasKind)
		out.Pages = append(out.Pages, api.WikiPageSummary{
			Audience: &r.Audience, Id: r.ID, Path: deref(r.Path), Title: r.Title, Author: dir.actor(r.AuthorType, &r.AuthorID),
			ProjectId: r.ProjectID, UpdatedAt: r.UpdatedAt, Published: r.Published, Suggestions: int(r.Suggestions),
			Kind: &kind, CanvasId: r.CanvasID,
		})
		out.Suggestions += int(r.Suggestions)
	}
	return out, nil
}

// pageKind is what a page holds: a deck or design page's body is its canvas (LAZYAGENTS-212).
func pageKind(canvasKind string) api.PageKind {
	switch canvasKind {
	case "deck":
		return api.PageKindDeck
	case "design":
		return api.PageKindDesign
	default:
		return api.PageKindDocument
	}
}

// GetCanvasPage finds the page a deck or design is, for links from before they moved into Knowledge.
func (s *Server) GetCanvasPage(ctx context.Context, req api.GetCanvasPageRequestObject) (api.GetCanvasPageResponseObject, error) {
	_, _, ws := me(ctx)
	p, err := s.Q.GetCanvasPage(ctx, store.GetCanvasPageParams{CanvasID: &req.CanvasId, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return api.GetCanvasPage200JSONResponse{Id: p.ID, Path: deref(p.Path), Title: p.Title}, nil
}

func (s *Server) noteDetail(ctx context.Context, ws, id uuid.UUID) (api.Artifact, error) {
	a, err := s.Q.GetArtifact(ctx, store.GetArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return api.Artifact{}, err
	}
	return s.artifactDetail(ctx, ws, a)
}

func (s *Server) CreateWikiPage(ctx context.Context, req api.CreateWikiPageRequestObject) (api.CreateWikiPageResponseObject, error) {
	u, _, ws := me(ctx)
	in := wiki.Save{Path: deref(req.Body.Path), Audience: string(deref(req.Body.Audience)), Title: req.Body.Title, Properties: artifacts.Properties(deref(req.Body.Properties)), Tags: req.Body.Tags, Aliases: req.Body.Aliases, Body: req.Body.BodyMd, Mode: wiki.ModeCreate, ProjectKey: deref(req.Body.ProjectKey)}
	if strings.TrimSpace(in.Body) == "" {
		// A new page from a ghost link starts with its title.
		title := links.TitleOf(links.NormalizePath(in.Path))
		if in.Title != nil {
			title = *in.Title
		}
		in.Body = "# " + title + "\n"
	}
	res, err := s.Wiki.SaveAsUser(ctx, ws, u.ID, in)
	if err != nil {
		return nil, err
	}
	a, err := s.noteDetail(ctx, ws, res.Note.ID)
	if err != nil {
		return nil, err
	}
	return api.CreateWikiPage201JSONResponse(a), nil
}

func (s *Server) GetWikiPage(ctx context.Context, req api.GetWikiPageRequestObject) (api.GetWikiPageResponseObject, error) {
	_, _, ws := me(ctx)
	p := links.NormalizePath(req.Params.Path)
	a, err := s.Q.GetNoteByPath(ctx, store.GetNoteByPathParams{WorkspaceID: ws, Path: p, Viewer: pageview.From(ctx).UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		a, err = s.Q.FindNoteByAlias(ctx, store.FindNoteByAliasParams{WorkspaceID: ws, Path: p, Viewer: pageview.From(ctx).UserID})
	}
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	out, err := s.artifactDetail(ctx, ws, a)
	if err != nil {
		return nil, err
	}
	return api.GetWikiPage200JSONResponse(out), nil
}

func (s *Server) SaveWikiPage(ctx context.Context, req api.SaveWikiPageRequestObject) (api.SaveWikiPageResponseObject, error) {
	u, _, ws := me(ctx)
	res, err := s.Wiki.UpdateAsUser(ctx, ws, u.ID, req.Id, wiki.Save{
		Audience: string(deref(req.Body.Audience)), Title: req.Body.Title, Properties: artifacts.Properties(deref(req.Body.Properties)), Tags: req.Body.Tags, Aliases: req.Body.Aliases, BaseID: req.Body.BaseVersionId, Note: deref(req.Body.Note),
	}, req.Body.Path, req.Body.BodyMd)
	if err != nil {
		return nil, err
	}
	out, err := s.noteDetail(ctx, ws, res.Note.ID)
	if err != nil {
		return nil, err
	}
	return api.SaveWikiPage200JSONResponse(out), nil
}

func (s *Server) ListWikiSuggestions(ctx context.Context, req api.ListWikiSuggestionsRequestObject) (api.ListWikiSuggestionsResponseObject, error) {
	_, _, ws := me(ctx)
	rows, err := s.Q.ListSuggestions(ctx, store.ListSuggestionsParams{WorkspaceID: ws, ArtifactID: req.Params.ArtifactId, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := api.ListWikiSuggestions200JSONResponse{Suggestions: []api.WikiSuggestion{}}
	for _, r := range rows {
		cur := ""
		if r.CurrentVersionID != nil {
			v, err := s.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *r.CurrentVersionID, ArtifactID: r.ArtifactID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
			if err != nil {
				return nil, err
			}
			cur = deref(v.BodyMd)
		}
		sg := api.WikiSuggestion{
			Id: r.ID, ArtifactId: r.ArtifactID, Path: deref(r.Path), Title: r.Title, BodyMd: deref(r.BodyMd), CurrentBodyMd: cur,
			Author: dir.actor(r.CreatedByType, &r.CreatedByID), CreatedAt: r.CreatedAt, NewPage: r.CurrentVersionID == nil,
			Stale: r.CurrentVersionID != nil && (r.BasedOnVersionID == nil || *r.BasedOnVersionID != *r.CurrentVersionID),
		}
		if r.Note != "" {
			sg.Note = &r.Note
		}
		out.Suggestions = append(out.Suggestions, sg)
	}
	return out, nil
}

func (s *Server) DecideWikiSuggestion(ctx context.Context, req api.DecideWikiSuggestionRequestObject) (api.DecideWikiSuggestionResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Decision != "accept" && req.Decision != "reject" {
		return nil, apperr.Invalid("decision", "must be accept or reject")
	}
	if _, err := s.Wiki.DecideSuggestion(ctx, ws, u.ID, req.VersionId, req.Decision == "accept"); err != nil {
		return nil, err
	}
	return api.DecideWikiSuggestion204Response{}, nil
}

func (s *Server) ExportWiki(ctx context.Context, _ api.ExportWikiRequestObject) (api.ExportWikiResponseObject, error) {
	_, _, ws := me(ctx)
	var buf bytes.Buffer
	if err := wiki.Export(ctx, s.Q, ws, &buf); err != nil {
		return nil, err
	}
	return exportZip{api.ExportWiki200ApplicationzipResponse{Body: &buf, ContentLength: int64(buf.Len())}}, nil
}

// exportZip adds a download filename to the generated response.
type exportZip struct {
	api.ExportWiki200ApplicationzipResponse
}

func (e exportZip) VisitExportWikiResponse(w http.ResponseWriter) error {
	w.Header().Set("Content-Disposition", `attachment; filename="lazyagents-wiki.zip"`)
	return e.ExportWiki200ApplicationzipResponse.VisitExportWikiResponse(w)
}

func (s *Server) ImportWiki(ctx context.Context, req api.ImportWikiRequestObject) (api.ImportWikiResponseObject, error) {
	u, _, ws := me(ctx)
	var data []byte
	for {
		part, err := req.Body.NextPart()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, apperr.Invalid("body", "malformed multipart form")
		}
		if part.FormName() == "file" {
			if data, err = io.ReadAll(io.LimitReader(part, 50<<20+1)); err != nil {
				return nil, err
			}
		}
	}
	if data == nil {
		return nil, apperr.Invalid("file", "is required")
	}
	res, err := s.Wiki.Import(ctx, ws, u.ID, data)
	if err != nil {
		return nil, err
	}
	return api.ImportWiki200JSONResponse(same[api.WikiImportResult](res)), nil
}

// ------------------------------------------------------------ knowledge

func (s *Server) ResolveLinks(ctx context.Context, req api.ResolveLinksRequestObject) (api.ResolveLinksResponseObject, error) {
	_, _, ws := me(ctx)
	out := api.ResolveLinks200JSONResponse{Links: []api.ResolvedLink{}}
	seen := map[string]bool{}
	for _, raw := range req.Params.Ref {
		if seen[raw] || len(seen) >= 200 {
			continue
		}
		seen[raw] = true
		r := links.ParseRef(raw)
		t, err := links.Resolve(ctx, s.Q, ws, r.Target, r.Anchor)
		if err != nil {
			return nil, err
		}
		out.Links = append(out.Links, api.ResolvedLink{Ref: raw, Target: toTarget(t)})
	}
	return out, nil
}

func (s *Server) SuggestLinks(ctx context.Context, req api.SuggestLinksRequestObject) (api.SuggestLinksResponseObject, error) {
	ctx = pageview.IncludeAgents(ctx, deref(req.Params.IncludeAgent))
	_, _, ws := me(ctx)
	ts, err := wiki.Autocomplete(ctx, s.Q, ws, strings.TrimSpace(deref(req.Params.Q)))
	if err != nil {
		return nil, err
	}
	out := api.SuggestLinks200JSONResponse{Targets: make([]api.LinkTarget, len(ts))}
	for i, t := range ts {
		out.Targets[i] = toTarget(t)
	}
	return out, nil
}

func (s *Server) GetBacklinks(ctx context.Context, req api.GetBacklinksRequestObject) (api.GetBacklinksResponseObject, error) {
	_, _, ws := me(ctx)
	ref := wiki.Ref{Kind: string(req.Params.Kind), ID: req.Params.Id}
	linked, err := wiki.Backlinks(ctx, s.Q, ws, ref)
	if err != nil {
		return nil, err
	}
	unlinked, err := wiki.UnlinkedMentions(ctx, s.Q, ws, ref, linked)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return api.GetBacklinks200JSONResponse{Linked: toMentions(linked), Unlinked: toMentions(unlinked)}, nil
}

func (s *Server) LinkMention(ctx context.Context, req api.LinkMentionRequestObject) (api.LinkMentionResponseObject, error) {
	u, _, ws := me(ctx)
	b := req.Body
	if err := s.Wiki.LinkMention(ctx, ws, u.ID, wiki.Ref{Kind: string(b.TargetKind), ID: b.TargetId}, string(b.SourceKind), b.SourceId); err != nil {
		return nil, err
	}
	return api.LinkMention204Response{}, nil
}

func (s *Server) GetGraph(ctx context.Context, req api.GetGraphRequestObject) (api.GetGraphResponseObject, error) {
	ctx = pageview.IncludeAgents(ctx, deref(req.Params.IncludeAgent))
	_, _, ws := me(ctx)
	depth := 2
	if req.Params.Depth != nil {
		depth = *req.Params.Depth
	}
	nodes, edges, err := wiki.LocalGraph(ctx, s.Q, ws, wiki.Ref{Kind: string(req.Params.Kind), ID: req.Params.Id}, depth)
	if err != nil {
		return nil, err
	}
	return api.GetGraph200JSONResponse(same[api.Graph](map[string]any{"nodes": nodes, "edges": edges})), nil
}

func (s *Server) SearchKnowledge(ctx context.Context, req api.SearchKnowledgeRequestObject) (api.SearchKnowledgeResponseObject, error) {
	ctx = pageview.IncludeAgents(ctx, deref(req.Params.IncludeAgent))
	_, _, ws := me(ctx)
	if strings.TrimSpace(req.Params.Q) == "" {
		return api.SearchKnowledge200JSONResponse{Hits: []api.SearchHit{}}, nil
	}
	var kinds []string
	if req.Params.Kind != nil {
		kinds = *req.Params.Kind
	}
	hits, err := wiki.Search(ctx, s.Q, ws, req.Params.Q, kinds, nil, 20)
	if err != nil {
		return nil, err
	}
	out := api.SearchKnowledge200JSONResponse{Hits: make([]api.SearchHit, len(hits))}
	for i, h := range hits {
		out.Hits[i] = api.SearchHit{Target: toTarget(h.Target), Snippet: h.Snippet, Score: float32(h.Score)}
	}
	return out, nil
}

func (s *Server) FindPatterns(ctx context.Context, req api.FindPatternsRequestObject) (api.FindPatternsResponseObject, error) {
	_, _, ws := me(ctx)
	limit := 0
	if req.Params.Limit != nil {
		limit = *req.Params.Limit
	}
	var tags []string
	if req.Params.Tag != nil {
		tags = *req.Params.Tag
	}
	ps, facet, err := wiki.BrowsePatterns(ctx, s.Q, ws, deref(req.Params.Q), deref(req.Params.Topic), tags, limit)
	if err != nil {
		return nil, err
	}
	out := api.FindPatterns200JSONResponse{Patterns: make([]api.WikiPattern, len(ps)), Tags: make([]api.TagCount, len(facet))}
	for i, p := range ps {
		out.Patterns[i] = api.WikiPattern{Title: p.Title, Path: p.Path, Topic: p.Topic, Tags: p.Tags, Summary: p.Summary, Snippet: p.Snippet, Score: float32(p.Score)}
	}
	for i, t := range facet {
		out.Tags[i] = api.TagCount{Tag: t.Tag, Count: t.Count}
	}
	return out, nil
}

func (s *Server) ListWikiADRs(ctx context.Context, _ api.ListWikiADRsRequestObject) (api.ListWikiADRsResponseObject, error) {
	_, _, ws := me(ctx)
	adrs, err := wiki.ListADRs(ctx, s.Q, ws)
	if err != nil {
		return nil, err
	}
	out := api.ListWikiADRs200JSONResponse{Adrs: make([]api.WikiADR, len(adrs))}
	for i, a := range adrs {
		qs := a.OpenQuestions
		if qs == nil {
			qs = []string{}
		}
		out.Adrs[i] = api.WikiADR{
			Id: a.ID, Title: a.Title, Path: nonEmpty(a.Path), DisplayId: nonEmpty(a.DisplayID), Href: a.Href,
			Status: a.Status, State: api.WikiADRState(a.State), Date: nonEmpty(a.Date), Ticket: nonEmpty(a.Ticket),
			OpenQuestions: qs, HasOpenQuestions: a.HasOpenQuestions, UpdatedAt: a.UpdatedAt,
		}
	}
	return out, nil
}

func (s *Server) GetWikiCitations(ctx context.Context, req api.GetWikiCitationsRequestObject) (api.GetWikiCitationsResponseObject, error) {
	u, _, ws := me(ctx)
	if _, err := s.Q.GetArtifact(ctx, store.GetArtifactParams{ID: req.Id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID}); errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListArtifactCitations(ctx, store.ListArtifactCitationsParams{ArtifactID: req.Id, WorkspaceID: ws, Viewer: u.ID})
	if err != nil {
		return nil, err
	}
	readers, err := s.Q.ListArtifactUnlinkedReaders(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	out := api.GetWikiCitations200JSONResponse{Citations: make([]api.WikiCitation, 0, len(rows)), Unlinked: make([]api.ArtifactReader, len(readers))}
	// Chats count by chat; another person's chat (not shown) by run.
	chats := map[string]bool{}
	for _, r := range rows {
		c := api.WikiCitation{
			RunId: r.RunID, Purpose: api.WikiCitationPurpose(r.Purpose), Reads: int(r.Reads), LastReadAt: r.LastReadAt,
			Agent:     api.AgentRef{Id: r.AgentID, Name: r.AgentName, Handle: r.AgentHandle, ColorIndex: int(r.AgentColorIndex)},
			TicketKey: r.TicketKey, TicketTitle: r.TicketTitle,
		}
		if id, err := uuid.Parse(r.ChatID); err == nil {
			c.ChatId = &id
			c.ChatTitle = &r.ChatTitle
			chats[r.ChatID] = true
		} else if r.Purpose == "chat" {
			chats["run:"+r.RunID.String()] = true
		}
		if r.Purpose != "chat" {
			out.Runs++
		}
		out.Citations = append(out.Citations, c)
	}
	out.Chats = len(chats)
	for i, r := range readers {
		out.Unlinked[i] = api.ArtifactReader{
			Agent: api.AgentRef{Id: r.ID, Name: r.Name, Handle: r.Handle, ColorIndex: int(r.ColorIndex)},
			Reads: int(r.Reads), LastReadAt: r.LastReadAt,
		}
	}
	return out, nil
}

// nonEmpty is nil for "", so optional fields are omitted.
func nonEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

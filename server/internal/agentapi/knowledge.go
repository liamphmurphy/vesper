package agentapi

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

type ListPagesIn struct {
	wiki.PageQuery
	SavedPage string `json:"saved_page,omitempty"`
}
type PatchPageIn struct {
	TicketArg
	Ref         string           `json:"ref"`
	BaseVersion uuid.UUID        `json:"base_version"`
	Changes     []wiki.PagePatch `json:"changes"`
}
type PropertiesIn struct {
	TicketArg
	Ref         string               `json:"ref"`
	BaseVersion uuid.UUID            `json:"base_version"`
	Properties  artifacts.Properties `json:"properties"`
	Note        string               `json:"note"`
}
type NewPageIn struct {
	TicketArg
	Title      string               `json:"title"`
	Folder     string               `json:"folder,omitempty"`
	Body       string               `json:"body"`
	Properties artifacts.Properties `json:"properties,omitempty"`
	Template   string               `json:"template,omitempty"`
	Source     string               `json:"source,omitempty" jsonschema:"For a literature note: the URL or citation it is about. A saved link's URL fills the title, source properties and a starting body from the link; for a video transcript pass the video URL and your notes as body."`
	Suggest    bool                 `json:"suggest,omitempty"`
}

type MovePageIn struct {
	Ref string `json:"ref" jsonschema:"The page to move: its id, title, path or [[link]]"`
	To  string `json:"to" jsonschema:"Its new path, folders and name, e.g. Projects/Harbour. Keep the name to only change its folder; keep the folder to only rename it."`
}
type MoveFolderIn struct {
	From string `json:"from" jsonschema:"The folder to move, e.g. Campaign/Sessions"`
	To   string `json:"to" jsonschema:"Its new path, e.g. Archive/Sessions. Every page under it keeps its place inside."`
}

func movePage(ctx context.Context, d Deps, c agents.Caller, in MovePageIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "move_page")
	if err != nil {
		return nil, err
	}
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	moved, err := d.Wiki.MovePageAsPersona(ctx, c.Agent.WorkspaceID, scope.UserID, a.ID, in.To)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": moved.ID, "from": a.Path, "path": moved.Path, "url": wiki.PageURL(moved.ID, moved.Title), "note": "Moved. The old path still resolves as an alias, so [[links]] to it keep working."}, nil
}

func moveFolder(ctx context.Context, d Deps, c agents.Caller, in MoveFolderIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "move_folder")
	if err != nil {
		return nil, err
	}
	moved, err := d.Wiki.MoveFolderAsPersona(ctx, c.Agent.WorkspaceID, scope.UserID, in.From, in.To)
	if err != nil {
		return nil, err
	}
	return map[string]any{"moved": len(moved), "page_ids": moved, "note": "Moved every page in one step. Old paths still resolve as aliases."}, nil
}

func listPages(ctx context.Context, d Deps, c agents.Caller, in ListPagesIn) (any, error) {
	if in.SavedPage != "" {
		a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.SavedPage)
		if err != nil {
			return nil, err
		}
		return wiki.SavedPageQuery(ctx, d.Q, c.Agent.WorkspaceID, a.ID)
	}
	return wiki.QueryPages(ctx, d.Q, c.Agent.WorkspaceID, in.PageQuery)
}
func pageOutline(ctx context.Context, d Deps, c agents.Caller, in PageIn) (any, error) {
	a, v, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	ls, err := d.Q.LinksFromSource(ctx, store.LinksFromSourceParams{SourceKind: "artifact", SourceID: a.ID})
	if err != nil {
		return nil, err
	}
	bs, err := wiki.Backlinks(ctx, d.Q, c.Agent.WorkspaceID, wiki.Ref{Kind: "artifact", ID: a.ID})
	if err != nil {
		return nil, err
	}
	reviews, err := d.Q.ListPageReviews(ctx, store.ListPageReviewsParams{ID: a.ID, WorkspaceID: a.WorkspaceID, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": a.ID, "title": a.Title, "path": a.Path, "version_id": v.ID, "properties": artifacts.DecodeProperties(v.Properties), "outline": artifacts.Outline(pageBody(v.BodyMd)), "outgoing_links": len(ls), "backlinks": len(bs), "pending_reviews": len(reviews)}, nil
}
func patchPage(ctx context.Context, d Deps, c agents.Caller, in PatchPageIn) (any, error) {
	a, v, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	if err := canvasPageBody(ctx, d, a); err != nil {
		return nil, err
	}
	if in.BaseVersion != v.ID {
		return nil, apperr.Conflict("this page changed; read it again before patching")
	}
	if len(in.Changes) == 0 || len(in.Changes) > 100 {
		return nil, apperr.Invalid("changes", "provide 1 to 100 anchored changes")
	}
	body := pageBody(v.BodyMd)
	reasons := []string{}
	for _, ch := range in.Changes {
		if ch.Before == "" || strings.Count(body, ch.Before) != 1 {
			return nil, apperr.Conflict("target text is missing or ambiguous; read the page again")
		}
		body = strings.Replace(body, ch.Before, ch.After, 1)
		reasons = append(reasons, ch.Why)
	}
	scopes, _, err := scopesFor(ctx, d, c, in.Ticket)
	if err != nil {
		return nil, err
	}
	result, err := d.Wiki.AgentWrite(ctx, c.Agent, scopes, wiki.Save{Path: *a.Path, Body: body, BaseID: &in.BaseVersion, ForceSuggestion: reviewOutsidePersonChat(ctx), Note: strings.Join(reasons, "; ")})
	if err != nil {
		return nil, err
	}
	return pageWriteSummary(result), nil
}

// canvasPageBody refuses to read or patch a deck's or design's page as text: its page body is
// empty, and the deck or design itself is the canvas it links to (LAZYAGENTS-212).
func canvasPageBody(ctx context.Context, d Deps, a store.Artifact) error {
	if a.CanvasID == nil {
		return nil
	}
	kind, err := d.Q.CanvasKind(ctx, *a.CanvasID)
	if err != nil {
		return err
	}
	if kind == "design" {
		return apperr.Invalid("ref", "%s is a design, not text: it is design %s, which design_outline and design_read open from its own chat", a.Title, a.CanvasID)
	}
	return apperr.Invalid("ref", "%s is a slide deck, not text: it is canvas %s, which canvas_read opens from its own chat", a.Title, a.CanvasID)
}

// reviewOutsidePersonChat is whether an edit must wait as a suggestion
// whatever the page says. In a person's chat the page's persona controls
// decide (wiki.Service.write): a page set to direct edits applies them at once
// for review afterwards, the rest wait. Runs without a person, such as ticket
// agents, always suggest.
func reviewOutsidePersonChat(ctx context.Context) bool {
	return pageview.From(ctx).UserID == nil
}

func setProperties(ctx context.Context, d Deps, c agents.Caller, in PropertiesIn) (any, error) {
	a, v, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	if in.BaseVersion != v.ID {
		return nil, apperr.Conflict("this page changed; read it again before setting properties")
	}
	scopes, _, err := scopesFor(ctx, d, c, in.Ticket)
	if err != nil {
		return nil, err
	}
	props := artifacts.DecodeProperties(v.Properties)
	for k, val := range in.Properties {
		if val == nil {
			delete(props, k)
		} else {
			props[k] = val
		}
	}
	result, err := d.Wiki.AgentWrite(ctx, c.Agent, scopes, wiki.Save{Path: *a.Path, Body: pageBody(v.BodyMd), BaseID: &in.BaseVersion, Properties: props, ForceSuggestion: reviewOutsidePersonChat(ctx), Note: in.Note})
	if err != nil {
		return nil, err
	}
	return pageWriteSummary(result), nil
}
func createPage(ctx context.Context, d Deps, c agents.Caller, in NewPageIn) (any, error) {
	if in.Source != "" {
		if err := literatureSource(ctx, d, c, &in); err != nil {
			return nil, err
		}
	}
	if in.Title == "" {
		return nil, apperr.Invalid("title", "is required")
	}
	if in.Properties == nil {
		in.Properties = artifacts.Properties{}
	}
	body := in.Body
	if in.Template != "" {
		if template, ok := wiki.TemplateSet[in.Template]; ok {
			body = template
		} else {
			_, v, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Template)
			if err != nil {
				return nil, err
			}
			body = pageBody(v.BodyMd)
		}
		body = wiki.RenderTemplate(body, in.Title, time.Now().UTC().Format("2006-01-02"), in.Properties)
	}
	scopes, _, err := scopesFor(ctx, d, c, in.Ticket)
	if err != nil {
		return nil, err
	}
	result, err := d.Wiki.AgentWrite(ctx, c.Agent, scopes, wiki.Save{AutoPath: true, Folder: in.Folder, Title: &in.Title, Body: body, Properties: in.Properties, Mode: wiki.ModeCreate, ForceSuggestion: in.Suggest})
	if err != nil {
		return nil, err
	}
	if scope, err := chatScopeFor(ctx, d, c); err != nil {
		return nil, err
	} else if scope != nil {
		if err = d.Q.SetPageChat(ctx, store.SetPageChatParams{ID: result.Note.ID, WorkspaceID: c.Agent.WorkspaceID, Viewer: &scope.UserID, ChatID: &scope.ChatID}); err != nil {
			return nil, err
		}
	}
	return map[string]any{"id": result.Note.ID, "path": result.Note.Path, "version_id": result.Version.ID, "state": result.State, "url": wiki.PageURL(result.Note.ID, result.Note.Title)}, nil
}

// literatureSource fills a literature note from the source it cites: when the
// source is one of the person's saved links, its title, site and (for a video)
// kind become properties, and its summary and note start an empty body. Any
// other source (a transcript's video URL, a book) is recorded as written.
func literatureSource(ctx context.Context, d Deps, c agents.Caller, in *NewPageIn) error {
	if in.Properties == nil {
		in.Properties = artifacts.Properties{}
	}
	in.Properties["source"] = in.Source
	in.Properties["type"] = "literature"
	scope, err := chatScopeFor(ctx, d, c)
	if err != nil || scope == nil {
		return err
	}
	link, err := d.Q.GetLibraryLink(ctx, store.GetLibraryLinkParams{WorkspaceID: c.Agent.WorkspaceID, UserID: scope.UserID, Url: in.Source})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	in.Properties["source_title"] = link.Title
	if link.Site != "" {
		in.Properties["source_site"] = link.Site
	}
	if link.VideoID != "" {
		in.Properties["source_kind"] = "video"
	}
	if in.Title == "" {
		in.Title = link.Title
	}
	if in.Body == "" && in.Template == "" {
		var b strings.Builder
		fmt.Fprintf(&b, "# %s\n\nSource: [%s](%s)\n", in.Title, link.Title, link.Url)
		if link.Summary != "" {
			fmt.Fprintf(&b, "\n## Summary\n\n%s\n", link.Summary)
		}
		if link.Note != "" {
			fmt.Fprintf(&b, "\n## Why I saved it\n\n%s\n", link.Note)
		}
		b.WriteString("\n## Notes\n")
		in.Body = b.String()
	}
	return nil
}

func captureNote(ctx context.Context, d Deps, c agents.Caller, in NewPageIn) (any, error) {
	if _, err := personChatScope(ctx, d, c, "capture_note"); err != nil {
		return nil, err
	}
	in.Folder = "Inbox"
	if in.Properties == nil {
		in.Properties = artifacts.Properties{}
	}
	in.Properties["type"] = "fleeting"
	in.Properties["zettel_id"] = uuid.NewString()
	return createPage(ctx, d, c, in)
}
func suggestLinks(ctx context.Context, d Deps, c agents.Caller, in PageIn) (any, error) {
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	linked, err := wiki.Backlinks(ctx, d.Q, c.Agent.WorkspaceID, wiki.Ref{Kind: "artifact", ID: a.ID})
	if err != nil {
		return nil, err
	}
	mentions, err := wiki.UnlinkedMentions(ctx, d.Q, c.Agent.WorkspaceID, wiki.Ref{Kind: "artifact", ID: a.ID}, linked)
	if err != nil {
		return nil, err
	}
	hits, err := wiki.Search(ctx, d.Q, c.Agent.WorkspaceID, a.Title, []string{"note"}, nil, 10)
	if err != nil {
		return nil, err
	}
	return map[string]any{"page_id": a.ID, "unlinked_mentions": mentions, "related_pages": hits, "hint": "Read one relevant section, then submit anchored patch_page changes for review."}, nil
}

// Keep the normal search ranking for unfiltered queries; filtered discovery
// shares exactly the same SQL as lists and saved queries.
func filteredSearch(ctx context.Context, d Deps, c agents.Caller, in SearchIn) (any, error) {
	props := in.Properties
	if props == nil {
		props = artifacts.Properties{}
	}
	result, err := wiki.QueryPages(ctx, d.Q, c.Agent.WorkspaceID, wiki.PageQuery{Text: in.Q, Folder: in.Folder, Tag: in.Tag, Audience: in.Audience, Properties: props, Limit: in.Limit})
	if err != nil {
		return nil, err
	}
	return map[string]any{"results": result.Rows, "has_more": result.HasMore}, nil
}

func pageBody(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

type DailyNoteIn struct {
	Date     string `json:"date,omitempty"`
	Folder   string `json:"folder,omitempty"`
	Template string `json:"template,omitempty"`
}

func dailyNote(ctx context.Context, d Deps, c agents.Caller, in DailyNoteIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "daily_note")
	if err != nil {
		return nil, err
	}
	if in.Date == "" {
		in.Date = time.Now().UTC().Format("2006-01-02")
	}
	r, err := d.Wiki.DailyPage(ctx, c.Agent.WorkspaceID, scope.UserID, in.Date, in.Folder, in.Template)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": r.Note.ID, "path": r.Note.Path, "version_id": r.Version.ID}, nil
}

type ImportVaultIn struct {
	AttachmentID uuid.UUID `json:"attachment_id"`
	Folder       string    `json:"folder,omitempty"`
}

func importVault(ctx context.Context, d Deps, c agents.Caller, in ImportVaultIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "import_vault")
	if err != nil {
		return nil, err
	}
	job, err := d.Wiki.QueueAttachedVault(ctx, c.Agent.WorkspaceID, scope.UserID, in.AttachmentID, in.Folder)
	if err != nil {
		return nil, err
	}
	return map[string]any{"import_id": job.ID, "state": job.State, "message": "Dry run queued. The person must review and confirm the report before anything imports."}, nil
}

func pageWriteSummary(r wiki.Result) map[string]any {
	return map[string]any{"id": r.Note.ID, "path": r.Note.Path, "version_id": r.Version.ID, "state": r.State, "created": r.Created, "changes": r.Version.Changes}
}

type LibrarianIn struct {
	Folder string `json:"folder,omitempty"`
	Tag    string `json:"tag,omitempty"`
	All    bool   `json:"all,omitempty"`
	Limit  int    `json:"limit,omitempty"`
}

func librarianPass(ctx context.Context, d Deps, c agents.Caller, in LibrarianIn) (any, error) {
	if in.Folder == "" && in.Tag == "" && !in.All {
		return nil, apperr.Invalid("folder", "provide a folder, a tag, or all=true")
	}
	if in.Limit <= 0 {
		in.Limit = 20
	}
	scopes, _, err := scopesFor(ctx, d, c, "")
	if err != nil {
		return nil, err
	}
	return d.Wiki.LibrarianPass(ctx, c.Agent, scopes, wiki.PageQuery{Folder: in.Folder, Tag: in.Tag, Limit: in.Limit})
}

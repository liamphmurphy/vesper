package httpapi

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/canvas"
	"github.com/liamphmurphy/vesper/server/internal/linkpreview"
	"github.com/liamphmurphy/vesper/server/internal/projects"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Chat spaces: a person's groups of chats with shared instructions, sources
// and memory. Every lookup filters on the caller; someone else's is a 404.

// spacePages reads a web page's text for a source; tests point it at a fake.
var spacePages interface {
	PageText(ctx context.Context, url string) (title, text string, err error)
} = linkpreview.New()

func spaceSourceKey(ws, user uuid.UUID) string {
	return "chat-spaces/" + ws.String() + "/" + user.String() + "/" + uuid.NewString()
}

// ownSpace loads one of the caller's spaces, or ErrNotFound.
func (s *Server) ownSpace(ctx context.Context, id uuid.UUID) (store.ChatSpace, error) {
	u, _, ws := me(ctx)
	sp, err := s.Q.GetChatSpace(ctx, store.GetChatSpaceParams{ID: id, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return sp, apperr.ErrNotFound
	}
	return sp, err
}

// toSpaces renders spaces with their counts, inline tokens and project keys.
func (s *Server) toSpaces(ctx context.Context, spaces []store.ChatSpace) ([]api.ChatSpace, error) {
	out := make([]api.ChatSpace, 0, len(spaces))
	if len(spaces) == 0 {
		return out, nil
	}
	_, _, ws := me(ctx)
	u, _, _ := me(ctx)
	ids := make([]uuid.UUID, len(spaces))
	for i, sp := range spaces {
		ids[i] = sp.ID
	}
	stats, err := s.Q.ChatSpaceStats(ctx, ids)
	if err != nil {
		return nil, err
	}
	byID := map[uuid.UUID]store.ChatSpaceStatsRow{}
	for _, st := range stats {
		byID[st.ID] = st
	}
	repoRows, err := s.Q.ListChatSpaceRepositoriesBySpaceIDs(ctx, ids)
	if err != nil {
		return nil, err
	}
	reposBySpace := map[uuid.UUID][]store.ChatSpaceRepository{}
	for _, r := range repoRows {
		reposBySpace[r.SpaceID] = append(reposBySpace[r.SpaceID], r)
	}
	linkRows, err := s.Q.ListChatSpaceKnowledgeLinksBySpaceIDs(ctx, ids)
	if err != nil {
		return nil, err
	}
	linksBySpace := map[uuid.UUID][]store.ChatSpaceKnowledgeLink{}
	for _, l := range linkRows {
		linksBySpace[l.SpaceID] = append(linksBySpace[l.SpaceID], l)
	}
	personaRows, err := s.Q.ListPersonas(ctx, store.ListPersonasParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	personasByID := map[uuid.UUID]store.Persona{}
	for _, p := range personaRows {
		personasByID[p.ID] = p
	}
	projects, err := s.Q.ListProjects(ctx, ws)
	if err != nil {
		return nil, err
	}
	for _, sp := range spaces {
		sources, err := s.Q.ListChatSpaceSources(ctx, sp.ID)
		if err != nil {
			return nil, err
		}
		st := byID[sp.ID]
		repoCount := int(st.RepoCount)
		knowledgeCount := int(st.KnowledgeCount)
		openTaskCount := int(st.OpenTaskCount)
		repos := toSpaceRepos(reposBySpace[sp.ID])
		links, err := s.toSpaceKnowledgeLinks(ctx, ws, u.ID, linksBySpace[sp.ID])
		if err != nil {
			return nil, err
		}
		item := api.ChatSpace{Id: sp.ID, Name: sp.Name, Description: sp.Description, Color: api.ChatSpaceColor(sp.Color), Instructions: sp.Instructions,
			PersonaId: sp.PersonaID, ConnectorIds: sp.ConnectorIds, SpaceMemory: sp.SpaceMemory, ChatCount: int(st.ChatCount), SourceCount: int(st.SourceCount),
			MemoryCount: int(st.MemoryCount), RepoCount: &repoCount, KnowledgeCount: &knowledgeCount, OpenTaskCount: &openTaskCount,
			Repositories: &repos, KnowledgeLinks: &links, InlineTokens: runs.SpaceInlineTokens(sources), CreatedAt: sp.CreatedAt, UpdatedAt: sp.UpdatedAt}
		if sp.PersonaID != nil {
			if p, ok := personasByID[*sp.PersonaID]; ok {
				item.Persona = &api.ChatSpacePersonaRef{Id: p.ID, Name: p.Name, Color: p.Color, AvatarUrl: personaAvatarURL(p)}
			}
		}
		if item.ConnectorIds == nil {
			item.ConnectorIds = []uuid.UUID{}
		}
		if sp.ProjectID != nil {
			if i := slices.IndexFunc(projects, func(p store.Project) bool { return p.ID == *sp.ProjectID }); i >= 0 {
				item.Project = &projects[i].Key
			}
		}
		if i := slices.IndexFunc(projects, func(p store.Project) bool { return p.SpaceID != nil && *p.SpaceID == sp.ID }); i >= 0 {
			p := projects[i]
			item.Work = &api.SpaceWork{Key: p.Key, RepoUrl: p.RepoUrl, DefaultBranch: p.DefaultBranch, Archived: p.Archived, Revision: int(p.Revision)}
		}
		out = append(out, item)
	}
	return out, nil
}

func (s *Server) toSpace(ctx context.Context, sp store.ChatSpace) (api.ChatSpace, error) {
	out, err := s.toSpaces(ctx, []store.ChatSpace{sp})
	if err != nil {
		return api.ChatSpace{}, err
	}
	return out[0], nil
}

func (s *Server) ListChatSpaces(ctx context.Context, _ api.ListChatSpacesRequestObject) (api.ListChatSpacesResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListChatSpaces(ctx, store.ListChatSpacesParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out, err := s.toSpaces(ctx, rows)
	if err != nil {
		return nil, err
	}
	return api.ListChatSpaces200JSONResponse{Spaces: out}, nil
}

func (s *Server) CreateChatSpace(ctx context.Context, req api.CreateChatSpaceRequestObject) (api.CreateChatSpaceResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	in := runs.SpaceInput{Name: &b.Name, Description: b.Description, Instructions: b.Instructions, PersonaID: b.PersonaId, Project: b.Project,
		ConnectorIDs: b.ConnectorIds, SpaceMemory: b.SpaceMemory}
	if w := b.Work; w != nil {
		if b.Project != nil {
			return nil, apperr.Invalid("project", "a space that tracks work files tickets under its own key")
		}
		in.Then = func(q *store.Queries, sp store.ChatSpace) error {
			_, err := projects.TrackWorkTx(ctx, q, ws, u.ID, sp.ID, spaceWork(*w))
			return err
		}
	}
	if b.Color != nil {
		in.Color = (*string)(b.Color)
	}
	sp, err := s.Runs.CreateSpace(ctx, ws, u.ID, in)
	if err != nil {
		return nil, err
	}
	if in.Then != nil {
		// Tracking work set where the space files tickets.
		if sp, err = s.ownSpace(ctx, sp.ID); err != nil {
			return nil, err
		}
	}
	out, err := s.toSpace(ctx, sp)
	return api.CreateChatSpace201JSONResponse(out), err
}

func (s *Server) GetChatSpace(ctx context.Context, req api.GetChatSpaceRequestObject) (api.GetChatSpaceResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	out, err := s.toSpace(ctx, sp)
	return api.GetChatSpace200JSONResponse(out), err
}

func (s *Server) UpdateChatSpace(ctx context.Context, req api.UpdateChatSpaceRequestObject) (api.UpdateChatSpaceResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	in := runs.SpaceInput{Name: b.Name, Description: b.Description, Instructions: b.Instructions, Project: b.Project, ConnectorIDs: b.ConnectorIds, SpaceMemory: b.SpaceMemory}
	if b.Color != nil {
		in.Color = (*string)(b.Color)
	}
	if b.PersonaId != nil {
		if *b.PersonaId == "" {
			in.ClearPersona = true
		} else {
			id, err := uuid.Parse(*b.PersonaId)
			if err != nil {
				return nil, apperr.Invalid("persona_id", "must be a persona id, or empty for the default persona")
			}
			in.PersonaID = &id
		}
	}
	sp, err := s.Runs.UpdateSpace(ctx, ws, u.ID, req.SpaceId, in)
	if err != nil {
		return nil, err
	}
	out, err := s.toSpace(ctx, sp)
	return api.UpdateChatSpace200JSONResponse(out), err
}

func (s *Server) DeleteChatSpace(ctx context.Context, req api.DeleteChatSpaceRequestObject) (api.DeleteChatSpaceResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if p, err := s.Q.GetProjectBySpace(ctx, &sp.ID); err == nil {
		return nil, apperr.Conflict("this space tracks work (%s); stop tracking it first, or archive it", p.Key)
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return nil, err
	}
	keys, err := s.Q.DeleteChatSpace(ctx, store.DeleteChatSpaceParams{ID: req.SpaceId, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	for _, k := range keys {
		s.dropSourceBlob(ctx, k)
	}
	return api.DeleteChatSpace204Response{}, nil
}

func spaceWork(w api.SpaceWorkInput) projects.Work {
	out := projects.Work{Key: w.Key}
	if w.RepoUrl != nil {
		out.RepoURL = *w.RepoUrl
	}
	if w.DefaultBranch != nil {
		out.DefaultBranch = *w.DefaultBranch
	}
	return out
}

// TrackSpaceWork makes one of the person's spaces track work (LAZYAGENTS-213).
func (s *Server) TrackSpaceWork(ctx context.Context, req api.TrackSpaceWorkRequestObject) (api.TrackSpaceWorkResponseObject, error) {
	u, _, ws := me(ctx)
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	if _, err := (projects.Service{Pool: s.Pool}).TrackWork(ctx, ws, u.ID, req.SpaceId, spaceWork(*req.Body)); err != nil {
		return nil, err
	}
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	out, err := s.toSpace(ctx, sp)
	return api.TrackSpaceWork200JSONResponse(out), err
}

// StopSpaceWork takes a space's work away while it has no tickets.
func (s *Server) StopSpaceWork(ctx context.Context, req api.StopSpaceWorkRequestObject) (api.StopSpaceWorkResponseObject, error) {
	u, _, ws := me(ctx)
	if err := (projects.Service{Pool: s.Pool}).StopTrackingWork(ctx, ws, u.ID, req.SpaceId); err != nil {
		return nil, err
	}
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	out, err := s.toSpace(ctx, sp)
	return api.StopSpaceWork200JSONResponse(out), err
}

// dropSourceBlob removes a deleted source's file; a failure only leaves an
// unreachable object behind.
func (s *Server) dropSourceBlob(ctx context.Context, key string) {
	if s.Blobs == nil || key == "" {
		return
	}
	if err := s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, key); err != nil && !errors.Is(err, blob.ErrNotFound) {
		s.Log.Warn("remove space source file", "key", key, "err", err)
	}
}

func toSources(rows []store.ChatSpaceSource) []api.ChatSpaceSource {
	d := runs.SpaceDelivery(rows)
	out := make([]api.ChatSpaceSource, len(rows))
	for i, r := range rows {
		ct := r.ContentType
		out[i] = api.ChatSpaceSource{Id: r.ID, Kind: api.ChatSpaceSourceKind(r.Kind), Title: r.Title, Url: r.Url, Filename: r.Filename, ContentType: &ct,
			SizeBytes: r.SizeBytes, Tokens: int(r.Tokens), Delivery: api.ChatSpaceSourceDelivery(d[r.ID]), CreatedAt: r.CreatedAt, ChatId: r.ChatID}
	}
	return out
}

func (s *Server) ListChatSpaceSources(ctx context.Context, req api.ListChatSpaceSourcesRequestObject) (api.ListChatSpaceSourcesResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	rows, err := s.Q.ListChatSpaceSources(ctx, sp.ID)
	if err != nil {
		return nil, err
	}
	return api.ListChatSpaceSources200JSONResponse{Sources: toSources(rows), InlineTokens: runs.SpaceInlineTokens(rows), InlineBudget: runs.SpaceInlineBudget}, nil
}

// sourceResult renders a new source with its delivery among the space's.
func (s *Server) sourceResult(ctx context.Context, src store.ChatSpaceSource) (api.ChatSpaceSource, error) {
	rows, err := s.Q.ListChatSpaceSources(ctx, src.SpaceID)
	if err != nil {
		return api.ChatSpaceSource{}, err
	}
	for _, r := range toSources(rows) {
		if r.Id == src.ID {
			return r, nil
		}
	}
	return toSources([]store.ChatSpaceSource{src})[0], nil
}

// checkSourceRoom refuses a source past the space's count or storage cap.
func (s *Server) checkSourceRoom(ctx context.Context, space uuid.UUID, size int64) error {
	rows, err := s.Q.ListChatSpaceSources(ctx, space)
	if err != nil {
		return err
	}
	if len(rows) >= runs.MaxSpaceSources {
		return apperr.Invalid("kind", "a space holds up to %d sources; remove one first", runs.MaxSpaceSources)
	}
	var total int64
	for _, r := range rows {
		total += r.SizeBytes
	}
	if total+size > runs.MaxSpaceStorageBytes {
		return apperr.Invalid("file", "a space holds up to 100 MB of sources; remove one first")
	}
	return nil
}

// sourceTitle is the title given, else the fallback, bounded to 300 runes.
func sourceTitle(given *string, fallback string) string {
	t := strings.Join(strings.Fields(deref(given)), " ")
	if t == "" {
		t = strings.Join(strings.Fields(fallback), " ")
	}
	if t == "" {
		t = "Untitled"
	}
	if r := []rune(t); len(r) > 300 {
		t = string(r[:299]) + "…"
	}
	return t
}

// sourceText bounds a source's text.
func sourceText(field, text string) (string, error) {
	text = strings.TrimSpace(strings.ToValidUTF8(text, ""))
	if text == "" {
		return "", apperr.Invalid(field, "is empty")
	}
	if utf8.RuneCountInString(text) > runs.MaxSpaceSourceText {
		return "", apperr.Invalid(field, "is too long: up to %d characters", runs.MaxSpaceSourceText)
	}
	return text, nil
}

// bareURL is a URL without its scheme or a trailing slash, as a title.
func bareURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	return strings.TrimSuffix(strings.TrimPrefix(u.Host, "www.")+u.EscapedPath(), "/")
}

func (s *Server) AddChatSpaceSource(ctx context.Context, req api.AddChatSpaceSourceRequestObject) (api.AddChatSpaceSourceResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	b := req.Body
	arg := store.CreateChatSpaceSourceParams{SpaceID: sp.ID, Kind: string(b.Kind), ContentType: "text/markdown"}
	switch b.Kind {
	case api.NewSpaceSourceText:
		text, err := sourceText("text", deref(b.Text))
		if err != nil {
			return nil, err
		}
		arg.Title, arg.Body = sourceTitle(b.Title, firstWords(text)), text
	case api.NewSpaceSourceWebsite:
		raw := strings.TrimSpace(deref(b.Url))
		if !linkpreview.Valid(raw) {
			return nil, apperr.Invalid("url", "must be a public http(s) address")
		}
		title, text, err := s.pageSource(ctx, raw)
		if err != nil {
			return nil, err
		}
		arg.Title, arg.Body, arg.Url = sourceTitle(b.Title, first(title, bareURL(raw))), text, &raw
	case api.NewSpaceSourceLink, api.NewSpaceSourceLibrary:
		if b.ItemId == nil {
			return nil, apperr.Invalid("item_id", "required")
		}
		item, err := s.Q.GetLibraryItem(ctx, store.GetLibraryItemParams{ID: *b.ItemId, WorkspaceID: ws, UserID: u.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.Invalid("item_id", "unknown Library item")
		} else if err != nil {
			return nil, err
		}
		if b.Kind == api.NewSpaceSourceLink && item.Kind != "link" {
			return nil, apperr.Invalid("item_id", "must be a saved link")
		}
		if err := s.libraryItemSource(ctx, ws, u.ID, item, &arg); err != nil {
			return nil, err
		}
		arg.Kind = string(b.Kind)
		arg.Title = sourceTitle(b.Title, arg.Title)
	case api.NewSpaceSourceCanvas:
		if b.CanvasId == nil {
			return nil, apperr.Invalid("canvas_id", "required")
		}
		cv, err := s.Q.GetUserCanvas(ctx, store.GetUserCanvasParams{ID: *b.CanvasId, WorkspaceID: ws, UserID: u.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.Invalid("canvas_id", "unknown canvas")
		} else if err != nil {
			return nil, err
		}
		if cv.Kind == canvas.KindDesign {
			return nil, apperr.Invalid("canvas_id", "a design can't be a source; export it to the Library instead")
		}
		text, err := sourceText("canvas_id", cv.Body)
		if err != nil {
			return nil, err
		}
		arg.Title, arg.Body = sourceTitle(b.Title, cv.Title), text
		if cv.Kind == "svg" {
			arg.ContentType = "image/svg+xml"
		}
	default:
		return nil, apperr.Invalid("kind", "must be text, website, library, link or canvas")
	}
	if arg.BlobKey == nil {
		arg.SizeBytes = int64(len(arg.Body))
		arg.Tokens = int32(runs.EstimateTokens(arg.Body))
	}
	if err := s.checkSourceRoom(ctx, sp.ID, arg.SizeBytes); err != nil {
		if arg.BlobKey != nil {
			s.dropSourceBlob(ctx, *arg.BlobKey)
		}
		return nil, err
	}
	src, err := s.Q.CreateChatSpaceSource(ctx, arg)
	if err != nil {
		if arg.BlobKey != nil {
			s.dropSourceBlob(ctx, *arg.BlobKey)
		}
		return nil, err
	}
	out, err := s.sourceResult(ctx, src)
	return api.AddChatSpaceSource201JSONResponse(out), err
}

func first(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// firstWords titles pasted text by its first line.
func firstWords(text string) string {
	line, _, _ := strings.Cut(text, "\n")
	line = strings.TrimLeft(strings.TrimSpace(line), "#> -*")
	if r := []rune(line); len(r) > 60 {
		line = strings.TrimSpace(string(r[:59])) + "…"
	}
	return line
}

// pageSource reads a page's text for a source.
func (s *Server) pageSource(ctx context.Context, raw string) (title, text string, err error) {
	title, text, err = spacePages.PageText(ctx, raw)
	if errors.Is(err, linkpreview.ErrNoText) {
		return "", "", apperr.Invalid("url", "that page has no text to read")
	}
	if err != nil {
		return "", "", apperr.Invalid("url", "couldn’t read that page: %s", err.Error())
	}
	text, err = sourceText("url", text)
	return title, text, err
}

// libraryItemSource fills a source from a Library item: a link's page text
// (or its saved summary when the page can't be read), a diagram's SVG, or a
// copy of an image's file.
func (s *Server) libraryItemSource(ctx context.Context, ws, user uuid.UUID, item store.LibraryItem, arg *store.CreateChatSpaceSourceParams) error {
	arg.Title = item.Title
	switch item.Kind {
	case "link":
		link := item.Url
		arg.Url = &link
		title, text, err := s.pageSource(ctx, link)
		if err != nil {
			// The page is gone or unreadable: keep what the Library knows.
			var b strings.Builder
			fmt.Fprintf(&b, "# %s\n\n%s\n", first(item.Title, link), link)
			if item.Note != "" {
				fmt.Fprintf(&b, "\n%s\n", item.Note)
			}
			if item.Summary != "" {
				fmt.Fprintf(&b, "\n%s\n", item.Summary)
			}
			text = b.String()
		}
		arg.Title, arg.Body = first(title, item.Title, bareURL(link)), text
		return nil
	}
	if s.Blobs == nil {
		return apperr.Invalid("item_id", "file storage isn't configured")
	}
	if item.SizeBytes > runs.MaxSpaceSourceBytes {
		return apperr.Invalid("item_id", "files are limited to 20 MB")
	}
	o, err := s.Blobs.Get(ctx, s.ArtifactBucket, item.BlobKey)
	if errors.Is(err, blob.ErrNotFound) {
		return apperr.Invalid("item_id", "that item's file is gone")
	} else if err != nil {
		return err
	}
	defer o.Body.Close()
	data, err := io.ReadAll(io.LimitReader(o.Body, runs.MaxSpaceSourceBytes+1))
	if err != nil {
		return err
	}
	name := runs.ChatAttachmentName(item.Filename)
	arg.Filename, arg.ContentType, arg.SizeBytes = &name, item.ContentType, int64(len(data))
	if strings.HasPrefix(item.ContentType, "image/svg") || strings.HasPrefix(item.ContentType, "text/") {
		// Text is kept as text, so it counts toward the inline budget.
		text, err := sourceText("item_id", string(data))
		if err != nil {
			return err
		}
		arg.Body = text
		return nil
	}
	key := spaceSourceKey(ws, user)
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, bytes.NewReader(data), int64(len(data)), item.ContentType); err != nil {
		return err
	}
	arg.BlobKey = &key
	return nil
}

func (s *Server) UploadChatSpaceSource(ctx context.Context, req api.UploadChatSpaceSourceRequestObject) (api.UploadChatSpaceSourceResponseObject, error) {
	u, _, ws := me(ctx)
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	f, err := readForm(req.Body)
	if err != nil {
		return nil, err
	}
	defer f.close()
	if f.file == nil {
		return nil, apperr.Invalid("file", "required")
	}
	if f.file.Size > runs.MaxSpaceSourceBytes {
		return nil, apperr.Invalid("file", "files are limited to 20 MB")
	}
	head := make([]byte, 512)
	n, err := io.ReadFull(f.tmp, head)
	if err != nil && !errors.Is(err, io.ErrUnexpectedEOF) && !errors.Is(err, io.EOF) {
		return nil, err
	}
	if _, err := f.tmp.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	name := runs.ChatAttachmentName(f.file.Name)
	ct, err := runs.ChatAttachmentType(name, f.file.Size, head[:n])
	if err != nil {
		return nil, err
	}
	if err := s.checkSourceRoom(ctx, sp.ID, f.file.Size); err != nil {
		return nil, err
	}
	arg := store.CreateChatSpaceSourceParams{SpaceID: sp.ID, Kind: "file", Title: sourceTitle(nil, name), Filename: &name, ContentType: ct, SizeBytes: f.file.Size}
	if strings.HasPrefix(ct, "text/") || ct == "application/json" {
		// Text files are kept as text: the assistant reads them like pasted
		// text, and they count toward the inline budget.
		data, err := io.ReadAll(f.tmp)
		if err != nil {
			return nil, err
		}
		if arg.Body, err = sourceText("file", string(data)); err != nil {
			return nil, err
		}
		arg.Tokens = int32(runs.EstimateTokens(arg.Body))
	} else {
		if s.Blobs == nil {
			return nil, apperr.Invalid("file", "file storage isn't configured")
		}
		key := spaceSourceKey(ws, u.ID)
		if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, f.tmp, f.file.Size, ct); err != nil {
			return nil, err
		}
		arg.BlobKey = &key
	}
	src, err := s.Q.CreateChatSpaceSource(ctx, arg)
	if err != nil {
		if arg.BlobKey != nil {
			s.dropSourceBlob(ctx, *arg.BlobKey)
		}
		return nil, err
	}
	out, err := s.sourceResult(ctx, src)
	return api.UploadChatSpaceSource201JSONResponse(out), err
}

func (s *Server) DeleteChatSpaceSource(ctx context.Context, req api.DeleteChatSpaceSourceRequestObject) (api.DeleteChatSpaceSourceResponseObject, error) {
	sp, err := s.ownSpace(ctx, req.SpaceId)
	if err != nil {
		return nil, err
	}
	src, err := s.Q.DeleteChatSpaceSource(ctx, store.DeleteChatSpaceSourceParams{ID: req.SourceId, SpaceID: sp.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if src.BlobKey != nil {
		s.dropSourceBlob(ctx, *src.BlobKey)
	}
	return api.DeleteChatSpaceSource204Response{}, nil
}

func (s *Server) ListMyCanvases(ctx context.Context, _ api.ListMyCanvasesRequestObject) (api.ListMyCanvasesResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListUserCanvases(ctx, store.ListUserCanvasesParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	out := api.ListMyCanvases200JSONResponse{Canvases: make([]api.MyCanvas, len(rows))}
	for i, r := range rows {
		out.Canvases[i] = api.MyCanvas{Id: r.ID, Kind: api.MyCanvasKind(r.Kind), Title: r.Title, ChatId: r.ChatID, ChatTitle: r.ChatTitle, UpdatedAt: r.UpdatedAt}
	}
	return out, nil
}

// chatSpaceRefs renders the spaces the chats are in, by space id.
func (s *Server) chatSpaceRefs(ctx context.Context, chats []store.ChatSession) (map[uuid.UUID]api.ChatSpaceRef, error) {
	out := map[uuid.UUID]api.ChatSpaceRef{}
	var ids []uuid.UUID
	for _, c := range chats {
		if c.SpaceID != nil && !slices.Contains(ids, *c.SpaceID) {
			ids = append(ids, *c.SpaceID)
		}
	}
	if len(ids) == 0 {
		return out, nil
	}
	u, _, ws := me(ctx)
	spaces, err := s.Q.ChatSpacesByIDs(ctx, store.ChatSpacesByIDsParams{Ids: ids, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	stats, err := s.Q.ChatSpaceStats(ctx, ids)
	if err != nil {
		return nil, err
	}
	sources := map[uuid.UUID]int{}
	for _, st := range stats {
		sources[st.ID] = int(st.SourceCount)
	}
	for _, sp := range spaces {
		out[sp.ID] = api.ChatSpaceRef{Id: sp.ID, Name: sp.Name, Color: api.ChatSpaceColor(sp.Color), SpaceMemory: sp.SpaceMemory,
			SourceCount: sources[sp.ID], HasInstructions: strings.TrimSpace(sp.Instructions) != ""}
	}
	return out, nil
}

// chatSpaceFilter resolves GET /chats?space= to ListChatsForUser's filter.
func (s *Server) chatSpaceFilter(ctx context.Context, raw *string) (string, *uuid.UUID, error) {
	if raw == nil || *raw == "none" {
		return "none", nil, nil
	}
	if *raw == "all" {
		return "all", nil, nil
	}
	id, err := uuid.Parse(*raw)
	if err != nil {
		return "", nil, apperr.Invalid("space", "must be a space id, all or none")
	}
	if _, err := s.ownSpace(ctx, id); errors.Is(err, apperr.ErrNotFound) {
		return "", nil, apperr.Invalid("space", "unknown space")
	} else if err != nil {
		return "", nil, err
	}
	return "id", &id, nil
}

// chatPreviews is the start of each chat's newest reply as plain text.
func (s *Server) chatPreviews(ctx context.Context, chats []api.ChatSession) error {
	ids := make([]uuid.UUID, len(chats))
	for i, c := range chats {
		ids[i] = c.Id
	}
	if len(ids) == 0 {
		return nil
	}
	rows, err := s.Q.ChatLastReplies(ctx, ids)
	if err != nil {
		return err
	}
	byID := map[uuid.UUID]string{}
	for _, r := range rows {
		byID[r.SessionID] = plainPreview(r.Body)
	}
	for i := range chats {
		if p, ok := byID[chats[i].Id]; ok && p != "" {
			chats[i].Preview = &p
		}
	}
	return nil
}

// plainPreview drops fenced blocks and Markdown marks from a reply's start
// and keeps one line of at most 160 characters.
func plainPreview(md string) string {
	var words []string
	inFence := false
	for _, line := range strings.Split(md, "\n") {
		t := strings.TrimSpace(line)
		if strings.HasPrefix(t, "```") || strings.HasPrefix(t, "~~~") {
			inFence = !inFence
			continue
		}
		if inFence || t == "" {
			continue
		}
		t = strings.TrimLeft(t, "#>-*+| ")
		t = strings.NewReplacer("**", "", "__", "", "`", "", "[[", "", "]]", "").Replace(t)
		words = append(words, strings.Fields(t)...)
		if len(words) > 40 {
			break
		}
	}
	out := strings.Join(words, " ")
	if r := []rune(out); len(r) > 160 {
		out = strings.TrimSpace(string(r[:159])) + "…"
	}
	return out
}

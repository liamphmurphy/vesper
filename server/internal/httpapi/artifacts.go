package httpapi

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/http"
	"os"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// ---------------------------------------------------------------- forms ---

// form is a parsed multipart body. A file part is spooled to a temp file so
// its exact size is known before it goes to object storage.
type form struct {
	fields map[string]string
	file   *artifacts.File
	tmp    *os.File
}

func (f *form) close() {
	if f.tmp != nil {
		f.tmp.Close()
		os.Remove(f.tmp.Name())
	}
}

func (f *form) str(k string) string { return strings.TrimSpace(f.fields[k]) }

func (f *form) content() artifacts.Content {
	if f.file != nil {
		return artifacts.Content{File: f.file}
	}
	if b, ok := f.fields["body_md"]; ok {
		return artifacts.Content{BodyMD: &b}
	}
	return artifacts.Content{}
}

const maxFieldBytes = artifacts.MaxMarkdownBytes + 1

func readForm(mr *multipart.Reader) (*form, error) {
	f := &form{fields: map[string]string{}}
	for {
		part, err := mr.NextPart()
		if errors.Is(err, io.EOF) {
			return f, nil
		}
		if err != nil {
			f.close()
			return nil, apperr.Invalid("body", "malformed multipart form")
		}
		name := part.FormName()
		if name == "file" && part.FileName() != "" {
			if f.tmp != nil {
				f.close()
				return nil, apperr.Invalid("file", "send one file per request")
			}
			tmp, err := os.CreateTemp("", "lazyagents-upload-*")
			if err != nil {
				f.close()
				return nil, err
			}
			f.tmp = tmp
			n, err := io.Copy(tmp, io.LimitReader(part, artifacts.MaxFileBytes+1))
			if err != nil {
				f.close()
				return nil, err
			}
			if n > artifacts.MaxFileBytes {
				f.close()
				return nil, apperr.Invalid("file", "files are limited to 25 MB")
			}
			if _, err := tmp.Seek(0, io.SeekStart); err != nil {
				f.close()
				return nil, err
			}
			f.file = &artifacts.File{Name: part.FileName(), ContentType: sniff(part, tmp), Size: n, Body: tmp}
			continue
		}
		b, err := io.ReadAll(io.LimitReader(part, maxFieldBytes))
		if err != nil {
			f.close()
			return nil, err
		}
		if len(b) >= maxFieldBytes {
			f.close()
			return nil, apperr.Invalid(name, "is too large")
		}
		f.fields[name] = string(b)
	}
}

// sniff picks a content type: the part's header, then the extension, then the bytes.
func sniff(part *multipart.Part, tmp *os.File) string {
	if ct := part.Header.Get("Content-Type"); ct != "" && ct != "application/octet-stream" {
		return ct
	}
	if ct := mime.TypeByExtension(strings.ToLower(extOf(part.FileName()))); ct != "" {
		return ct
	}
	buf := make([]byte, 512)
	n, _ := tmp.Read(buf)
	_, _ = tmp.Seek(0, io.SeekStart)
	return http.DetectContentType(buf[:n])
}

func extOf(name string) string {
	if i := strings.LastIndex(name, "."); i >= 0 {
		return name[i:]
	}
	return ""
}

// ---------------------------------------------------------- conversions ---

func contentOf(isMarkdown bool, ct *string, size *int64, filename *string, sections int32) api.ArtifactContent {
	c := api.ArtifactContent{Kind: api.ArtifactContentKindFile, ContentType: deref(ct), SizeBytes: deref(size), Filename: filename, Sections: int(sections)}
	switch {
	case isMarkdown && deref(ct) == artifacts.MockupContentType:
		c.Kind = api.ArtifactContentKindSvg
	case isMarkdown:
		c.Kind = api.ArtifactContentKindMarkdown
	}
	return c
}

func reviewState(s *string) *api.MockupReviewState {
	if s == nil {
		return nil
	}
	r := api.MockupReviewState(*s)
	return &r
}

func (s *Server) artifactDetail(ctx context.Context, ws uuid.UUID, a store.Artifact) (api.Artifact, error) {
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return api.Artifact{}, err
	}
	out := api.Artifact{
		Audience: &a.Audience, Id: a.ID, Type: api.ArtifactType(a.Type), Title: a.Title, DisplayId: artifacts.DisplayID(a.Type, a.Number),
		Summary: a.Summary, Path: a.Path, Author: dir.actor(a.AuthorType, &a.AuthorID),
		CreatedAt: a.CreatedAt, UpdatedAt: a.UpdatedAt,
		Outline: []api.OutlineSection{}, ReadBy: []api.ArtifactReader{}, Versions: []api.ArtifactVersion{}, Tickets: []api.LinkedTicket{},
	}
	if a.CanvasID != nil {
		ck, err := s.Q.CanvasKind(ctx, *a.CanvasID)
		if err != nil {
			return api.Artifact{}, err
		}
		kind := pageKind(ck)
		out.Kind, out.CanvasId = &kind, a.CanvasID
	} else if a.Type == "note" {
		kind := api.PageKindDocument
		out.Kind = &kind
	}
	if a.ProjectID != nil {
		proj, err := s.Q.GetProject(ctx, store.GetProjectParams{ID: *a.ProjectID, WorkspaceID: ws})
		if err != nil {
			return api.Artifact{}, err
		}
		p := toProject(proj)
		out.Project = &p
	}
	if a.EpicID != nil {
		if e, err := s.Q.GetEpic(ctx, store.GetEpicParams{ID: *a.EpicID, WorkspaceID: ws}); err == nil {
			out.Epic = &api.EpicRef{Id: e.ID, Name: e.Name}
		}
	}
	if a.CurrentVersionID == nil {
		// A page that so far exists only as an agent's suggestion.
		return out, apperr.ErrNotFound
	}
	if a.Type == "note" {
		sugg, err := s.Q.ListSuggestions(ctx, store.ListSuggestionsParams{WorkspaceID: ws, ArtifactID: &a.ID, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return out, err
		}
		out.Suggestions = len(sugg)
	}
	cur, err := s.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return out, err
	}
	sections, err := s.Q.ListSectionsWithCitations(ctx, store.ListSectionsWithCitationsParams{ArtifactID: a.ID, VersionID: cur.ID, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return out, err
	}
	for _, sec := range sections {
		out.Outline = append(out.Outline, api.OutlineSection{Id: sec.ID, Level: int(sec.Level), Anchor: sec.Anchor, Heading: sec.Heading, Citations: int(sec.Citations)})
	}
	if a.Type == "note" {
		props := api.PageProperties(artifacts.DecodeProperties(cur.Properties))
		out.Properties = &props
		aliases, _ := artifacts.StringList(props["aliases"])
		out.Aliases = &aliases
		tags, err := s.Q.PageTags(ctx, store.PageTagsParams{ArtifactID: a.ID, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return out, err
		}
		out.Tags = &tags
	}
	out.BodyMd.Set(deref(cur.BodyMd))
	if cur.BodyMd == nil {
		out.BodyMd.SetNull()
	}
	versions, err := s.Q.ListArtifactVersions(ctx, store.ListArtifactVersionsParams{ArtifactID: a.ID, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return out, err
	}
	for _, v := range versions {
		isMD := (v.ContentType == "text/markdown" || v.ContentType == artifacts.MockupContentType) && v.Filename == nil
		nSections := int32(0)
		if v.ID == cur.ID {
			nSections = int32(len(sections))
		}
		av := api.ArtifactVersion{
			Id: v.ID, Seq: int(v.Seq), Label: v.Label, Note: v.Note, CreatedAt: v.CreatedAt,
			CreatedBy: dir.actor(v.CreatedByType, &v.CreatedByID),
			Content:   contentOf(isMD, &v.ContentType, &v.SizeBytes, v.Filename, nSections),
		}
		if v.ReviewState != nil {
			av.Review = &api.MockupReview{State: api.MockupReviewState(*v.ReviewState), Note: v.ReviewNote, ReviewedAt: v.ReviewedAt, Pins: reviewPins(v.ReviewPins)}
			if v.ReviewedByUserID != nil {
				if u, err := s.Q.GetUser(ctx, store.GetUserParams{ID: *v.ReviewedByUserID, WorkspaceID: ws}); err == nil {
					av.Review.ReviewedBy = toUserRef(u)
				}
			}
		}
		out.Versions = append(out.Versions, av)
		if v.ID == cur.ID {
			out.CurrentVersion = av
		}
	}
	readers, err := s.Q.ListArtifactReaders(ctx, a.ID)
	if err != nil {
		return out, err
	}
	for _, r := range readers {
		out.ReadBy = append(out.ReadBy, api.ArtifactReader{
			Agent: api.AgentRef{Id: r.ID, Name: r.Name, Handle: r.Handle, ColorIndex: int(r.ColorIndex)},
			Reads: int(r.Reads), LastReadAt: r.LastReadAt,
		})
	}
	tickets, err := s.Q.ListArtifactTickets(ctx, a.ID)
	if err != nil {
		return out, err
	}
	for _, t := range tickets {
		out.Tickets = append(out.Tickets, api.LinkedTicket{Key: t.Key, Title: t.Title, Status: api.TicketStatus(t.Status), Relation: api.ArtifactRelation(t.Relation)})
	}
	return out, nil
}

func (s *Server) docCards(ctx context.Context, ws uuid.UUID, t store.Ticket) ([]api.DocCard, error) {
	rows, err := s.Q.ListTicketArtifacts(ctx, store.ListTicketArtifactsParams{TicketID: t.ID, AssigneeAgentID: t.AssigneeAgentID, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := make([]api.DocCard, 0, len(rows))
	for _, r := range rows {
		out = append(out, api.DocCard{
			Id: r.ID, Type: api.ArtifactType(r.Type), Title: r.Title, DisplayId: artifacts.DisplayID(r.Type, r.Number),
			VersionLabel: r.VersionLabel, Relation: api.ArtifactRelation(r.Relation), ReviewState: reviewState(r.ReviewState),
			Author: dir.actor(r.AuthorType, &r.AuthorID), ReadByAssignee: r.ReadByAssignee,
		})
	}
	return out, nil
}

// ------------------------------------------------------------- handlers ---

func actorOf(ctx context.Context) artifacts.Actor {
	u, _, _ := me(ctx)
	return artifacts.Actor{Type: "user", ID: u.ID}
}

func (s *Server) ListArtifacts(ctx context.Context, req api.ListArtifactsRequestObject) (api.ListArtifactsResponseObject, error) {
	_, _, ws := me(ctx)
	p := req.Params
	viewer := pageview.From(ctx)
	params := store.ListArtifactsParams{WorkspaceID: ws, Viewer: viewer.UserID, IncludeAgent: viewer.IncludeAgent}
	counts := store.CountArtifactsByTypeParams{WorkspaceID: ws, Viewer: viewer.UserID, IncludeAgent: viewer.IncludeAgent}
	empty := api.ListArtifacts200JSONResponse{Artifacts: []api.ArtifactSummary{}}
	if p.Project != nil && *p.Project != "" {
		proj, err := s.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: *p.Project})
		if err != nil {
			return empty, nil
		}
		params.ProjectID, counts.ProjectID = &proj.ID, &proj.ID
	}
	if p.Q != nil && strings.TrimSpace(*p.Q) != "" {
		q := strings.TrimSpace(*p.Q)
		params.Q, counts.Q = &q, &q
	}
	if p.Type != nil {
		t := string(*p.Type)
		params.Type = &t
	}
	rows, err := s.Q.ListArtifacts(ctx, params)
	if err != nil {
		return nil, err
	}
	byType, err := s.Q.CountArtifactsByType(ctx, counts)
	if err != nil {
		return nil, err
	}
	dir, err := s.directory(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := api.ListArtifacts200JSONResponse{Artifacts: make([]api.ArtifactSummary, 0, len(rows))}
	for _, c := range byType {
		if c.Type != "note" {
			out.Counts.All += int(c.N)
		}
		switch c.Type {
		case "note":
			out.Counts.Note = int(c.N)
		case "prd":
			out.Counts.Prd = int(c.N)
		case "spec":
			out.Counts.Spec = int(c.N)
		case "adr":
			out.Counts.Adr = int(c.N)
		case "report":
			out.Counts.Report = int(c.N)
		case "design":
			out.Counts.Design = int(c.N)
		case "mockup":
			out.Counts.Mockup = int(c.N)
		}
	}
	for _, r := range rows {
		a := api.ArtifactSummary{
			Id: r.ID, Type: api.ArtifactType(r.Type), Title: r.Title, DisplayId: artifacts.DisplayID(r.Type, r.Number),
			Summary: r.Summary, Path: r.Path,
			Author: dir.actor(r.AuthorType, &r.AuthorID), VersionLabel: &r.VersionLabel,
			Content:     contentOf(r.IsMarkdown, &r.ContentType, &r.SizeBytes, r.Filename, r.SectionCount),
			TicketCount: int(r.TicketCount), UpdatedAt: r.UpdatedAt, ReviewState: reviewState(r.ReviewState),
		}
		if r.ProjectKey != nil {
			a.Project = &api.Project{Key: *r.ProjectKey, Name: deref(r.ProjectName), Color: deref(r.ProjectColor)}
		}
		if r.EpicID != nil {
			a.Epic = &api.EpicRef{Id: *r.EpicID, Name: deref(r.EpicName)}
		}
		out.Artifacts = append(out.Artifacts, a)
	}
	return out, nil
}

func (s *Server) CreateArtifact(ctx context.Context, req api.CreateArtifactRequestObject) (api.CreateArtifactResponseObject, error) {
	_, trackerActor, ws := me(ctx)
	f, err := readForm(req.Body)
	if err != nil {
		return nil, err
	}
	defer f.close()
	in := artifacts.NewArtifact{
		ProjectKey: f.str("project_key"), Type: f.str("type"), Title: f.str("title"), Summary: f.str("summary"),
		VersionLabel: f.str("version_label"), Content: f.content(),
	}
	if e := f.str("epic_id"); e != "" {
		id, err := uuid.Parse(e)
		if err != nil {
			return nil, apperr.Invalid("epic_id", "must be a UUID")
		}
		in.EpicID = &id
	}
	var then func(q *store.Queries, a store.Artifact) error
	if key := f.str("ticket_key"); key != "" {
		then = func(q *store.Queries, a store.Artifact) error {
			t, err := tracker.Get(ctx, q, ws, key)
			if errors.Is(err, apperr.ErrNotFound) {
				return apperr.Invalid("ticket_key", "unknown ticket")
			} else if err != nil {
				return err
			}
			if a.ProjectID == nil || *a.ProjectID != t.ProjectID {
				return apperr.Invalid("ticket_key", "ticket is in a different project")
			}
			return tracker.AttachArtifactInTx(ctx, q, ws, trackerActor, key, a.ID, "context")
		}
	}
	a, err := s.Artifacts.CreateThen(ctx, ws, actorOf(ctx), in, then)
	if err != nil {
		return nil, err
	}
	a, err = s.Q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		return nil, err
	}
	d, err := s.artifactDetail(ctx, ws, a)
	return api.CreateArtifact201JSONResponse(d), err
}

func (s *Server) getArtifact(ctx context.Context, ws, id uuid.UUID) (store.Artifact, error) {
	a, err := s.Q.GetArtifact(ctx, store.GetArtifactParams{ID: id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return a, apperr.ErrNotFound
	}
	return a, err
}

func (s *Server) GetArtifact(ctx context.Context, req api.GetArtifactRequestObject) (api.GetArtifactResponseObject, error) {
	_, _, ws := me(ctx)
	a, err := s.getArtifact(ctx, ws, req.Id)
	if err != nil {
		return nil, err
	}
	d, err := s.artifactDetail(ctx, ws, a)
	return api.GetArtifact200JSONResponse(d), err
}

func (s *Server) UpdateArtifact(ctx context.Context, req api.UpdateArtifactRequestObject) (api.UpdateArtifactResponseObject, error) {
	_, _, ws := me(ctx)
	b := req.Body
	p := artifacts.MetaPatch{Title: b.Title, Summary: b.Summary}
	if b.EpicId.IsSpecified() {
		p.EpicSet = true
		if !b.EpicId.IsNull() {
			id := b.EpicId.MustGet()
			p.EpicID = &id
		}
	}
	if _, err := s.Artifacts.UpdateMeta(ctx, ws, req.Id, p); err != nil {
		return nil, err
	}
	a, err := s.getArtifact(ctx, ws, req.Id)
	if err != nil {
		return nil, err
	}
	d, err := s.artifactDetail(ctx, ws, a)
	return api.UpdateArtifact200JSONResponse(d), err
}

func (s *Server) CreateArtifactVersion(ctx context.Context, req api.CreateArtifactVersionRequestObject) (api.CreateArtifactVersionResponseObject, error) {
	_, _, ws := me(ctx)
	f, err := readForm(req.Body)
	if err != nil {
		return nil, err
	}
	defer f.close()
	if _, err := s.Artifacts.AddVersion(ctx, ws, actorOf(ctx), req.Id, artifacts.NewVersion{
		Label: f.str("version_label"), Note: f.str("note"), Content: f.content(),
	}); err != nil {
		return nil, err
	}
	a, err := s.getArtifact(ctx, ws, req.Id)
	if err != nil {
		return nil, err
	}
	d, err := s.artifactDetail(ctx, ws, a)
	return api.CreateArtifactVersion201JSONResponse(d), err
}

// contentResponse streams a version with an explicit disposition. Stored
// files are served as attachments unless they're inert media, so an uploaded
// HTML or SVG file can't run script on the app's origin.
type contentResponse struct {
	body        io.Reader
	closer      io.Closer
	contentType string
	length      int64
	filename    string
	inline      bool
	// ranged says the file serves byte ranges; with partial, body holds
	// bytes start.. of total (a 206).
	ranged, partial bool
	start, total    int64
	// cache is the Cache-Control to send, if any.
	cache string
}

var inlineSafe = map[string]bool{
	"application/pdf": true, "image/png": true, "image/jpeg": true, "image/gif": true, "image/webp": true,
	"text/plain": true, "text/markdown": true, "video/mp4": true,
}

func (r contentResponse) VisitGetArtifactContentResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (r contentResponse) VisitGetWorkflowRunImageContentResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (r contentResponse) VisitGetChatAttachmentContentResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (r contentResponse) VisitGetLibraryItemContentResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (r contentResponse) write(w http.ResponseWriter) error {
	if r.closer != nil {
		defer r.closer.Close()
	}
	base := strings.ToLower(strings.TrimSpace(strings.Split(r.contentType, ";")[0]))
	disp := "attachment"
	if r.inline && inlineSafe[base] {
		disp = "inline"
	}
	if !inlineSafe[base] {
		// Never let the browser render active content from user uploads.
		w.Header().Set("Content-Security-Policy", "sandbox")
	}
	w.Header().Set("Content-Type", r.contentType)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Disposition", mime.FormatMediaType(disp, map[string]string{"filename": r.filename}))
	if r.length > 0 {
		w.Header().Set("Content-Length", fmt.Sprint(r.length))
	}
	if r.cache != "" {
		w.Header().Set("Cache-Control", r.cache)
	}
	status := http.StatusOK
	if r.ranged {
		w.Header().Set("Accept-Ranges", "bytes")
	}
	if r.partial {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", r.start, r.start+r.length-1, r.total))
		status = http.StatusPartialContent
	}
	w.WriteHeader(status)
	_, err := io.Copy(w, r.body)
	return err
}

func (s *Server) GetArtifactContent(ctx context.Context, req api.GetArtifactContentRequestObject) (api.GetArtifactContentResponseObject, error) {
	_, _, ws := me(ctx)
	v, err := s.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: req.VersionId, ArtifactID: req.Id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	inline := req.Params.Download == nil || !*req.Params.Download
	if v.BodyMd != nil {
		a, err := s.getArtifact(ctx, ws, req.Id)
		if err != nil {
			return nil, err
		}
		if a.Type == "mockup" {
			// Not inlineSafe: served sandboxed as an attachment; <img> still renders it.
			name := artifacts.Slug(a.Title) + "-" + artifacts.Slug(v.Label) + ".svg"
			return contentResponse{body: strings.NewReader(*v.BodyMd), contentType: artifacts.MockupContentType + "; charset=utf-8",
				length: int64(len(*v.BodyMd)), filename: name, inline: inline}, nil
		}
		name := artifacts.Slug(a.Title) + "-" + artifacts.Slug(v.Label) + ".md"
		return contentResponse{body: strings.NewReader(*v.BodyMd), contentType: "text/markdown; charset=utf-8",
			length: int64(len(*v.BodyMd)), filename: name, inline: inline}, nil
	}
	o, err := s.Blobs.Get(ctx, s.ArtifactBucket, deref(v.BlobKey))
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return contentResponse{body: o.Body, closer: o.Body, contentType: v.ContentType, length: v.SizeBytes,
		filename: deref(v.Filename), inline: inline}, nil
}

func (s *Server) AttachArtifact(ctx context.Context, req api.AttachArtifactRequestObject) (api.AttachArtifactResponseObject, error) {
	_, actor, ws := me(ctx)
	rel := "context"
	if req.Body.Relation != nil {
		rel = string(*req.Body.Relation)
	}
	if err := s.Tracker.AttachArtifact(ctx, ws, actor, req.Key, req.Body.ArtifactId, rel); err != nil {
		return nil, err
	}
	t, err := s.reloadTicket(ctx, ws, req.Key)
	return api.AttachArtifact200JSONResponse(t), err
}

func (s *Server) DetachArtifact(ctx context.Context, req api.DetachArtifactRequestObject) (api.DetachArtifactResponseObject, error) {
	_, actor, ws := me(ctx)
	if err := s.Tracker.DetachArtifact(ctx, ws, actor, req.Key, req.ArtifactId); err != nil {
		return nil, err
	}
	if a, err := s.Q.GetArtifact(ctx, store.GetArtifactParams{ID: req.ArtifactId, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID}); err == nil && a.Type == "mockup" {
		if err := s.Runs.ReleaseMockupWaiters(ctx, ws, []string{req.Key}, nil, a.Title); err != nil {
			return nil, err
		}
	}
	t, err := s.reloadTicket(ctx, ws, req.Key)
	return api.DetachArtifact200JSONResponse(t), err
}

package httpapi

import (
	"bytes"
	"context"
	"errors"
	"io"
	"path"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// The Library is private to its owner like chat attachments: every lookup
// filters on the caller, and someone else's item is a 404.

const libraryPageSize = 60

const maxLibraryBulkDelete = 500

const libraryDiagramType = "image/svg+xml"

func toLibraryItem(l store.ListLibraryItemsRow) api.LibraryItem {
	out := api.LibraryItem{
		Id: l.ID, Kind: api.LibraryItemKind(l.Kind), Title: l.Title, Filename: l.Filename, ContentType: l.ContentType, SizeBytes: l.SizeBytes,
		ChatId: l.ChatID, ChatTitle: l.ChatTitle, ProjectKey: l.ProjectKey, PersonaId: l.PersonaID, PersonaName: l.PersonaName, CreatedAt: l.CreatedAt,
	}
	if l.Kind == "link" {
		out.Url, out.Note, out.Site, out.VideoId, out.Summary = &l.Url, &l.Note, &l.Site, &l.VideoID, &l.Summary
		status := api.LibraryLinkStatus(l.LinkStatus)
		out.LinkStatus = &status
	}
	if l.Kind == "video" {
		out.DurationMs, out.Width, out.Height = intp(l.DurationMs), intp(l.Width), intp(l.Height)
		hasPoster := l.PosterKey != nil
		out.HasPoster = &hasPoster
	}
	if l.Kind == "audio" {
		out.DurationMs = intp(l.DurationMs)
		if l.Method != "" {
			out.Method = &l.Method
		}
		if len(l.Peaks) > 0 {
			peaks := make([]int, len(l.Peaks))
			for i, b := range l.Peaks {
				peaks[i] = int(b)
			}
			out.Peaks = &peaks
		}
	}
	if (l.Kind == "file" || l.Kind == "export") && l.Detail != "" {
		out.Detail = &l.Detail
	}
	if l.Kind == "export" {
		out.ExportSource = exportSourceOf(l)
	}
	source := api.LibraryItemSource(l.Source)
	out.Source = &source
	// A persona reference whose persona was deleted stands for nobody.
	if l.Reference != nil && (*l.Reference == "self" || l.ReferencePersonaID != nil) {
		r := api.LibraryReferenceRole(*l.Reference)
		out.Reference, out.ReferencePersonaId, out.ReferencePersonaName = &r, l.ReferencePersonaID, l.ReferencePersonaName
	}
	return out
}

func (s *Server) ListLibraryItems(ctx context.Context, req api.ListLibraryItemsRequestObject) (api.ListLibraryItemsResponseObject, error) {
	u, _, ws := me(ctx)
	p := store.ListLibraryItemsParams{WorkspaceID: ws, UserID: u.ID, RowLimit: libraryPageSize + 1}
	if req.Params.Kind != nil {
		k := string(*req.Params.Kind)
		p.Kind = &k
	}
	if req.Params.Offset != nil {
		p.RowOffset = int32(*req.Params.Offset)
	}
	rows, err := s.Q.ListLibraryItems(ctx, p)
	if err != nil {
		return nil, err
	}
	out := api.ListLibraryItems200JSONResponse{Items: make([]api.LibraryItem, 0, len(rows)), HasMore: len(rows) > libraryPageSize}
	for i, r := range rows {
		if i == libraryPageSize {
			break
		}
		out.Items = append(out.Items, toLibraryItem(r))
	}
	return out, nil
}

func (s *Server) GetLibraryItem(ctx context.Context, req api.GetLibraryItemRequestObject) (api.GetLibraryItemResponseObject, error) {
	u, _, ws := me(ctx)
	row, err := s.Q.GetLibraryItemDetail(ctx, store.GetLibraryItemDetailParams{ID: req.ItemId, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return api.GetLibraryItem200JSONResponse(toLibraryItem(store.ListLibraryItemsRow(row))), nil
}

func (s *Server) GetLibraryItemContent(ctx context.Context, req api.GetLibraryItemContentRequestObject) (api.GetLibraryItemContentResponseObject, error) {
	u, _, ws := me(ctx)
	l, err := s.Q.GetLibraryItem(ctx, store.GetLibraryItemParams{ID: req.ItemId, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && l.BlobKey == "") {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	// A file is only ever downloaded: its type describes it, it is never shown in the page.
	download := (req.Params.Download != nil && *req.Params.Download) || l.Kind == "file"
	if l.Kind == "video" || l.Kind == "audio" {
		// Players seek with byte ranges.
		resp, err := s.serveRanged(ctx, l.BlobKey, l.ContentType, l.SizeBytes, l.Filename, !download, req.Params.Range)
		if err != nil {
			return nil, err
		}
		return resp, nil
	}
	o, err := s.Blobs.Get(ctx, s.ArtifactBucket, l.BlobKey)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return contentResponse{body: o.Body, closer: o.Body, contentType: l.ContentType, length: l.SizeBytes, filename: l.Filename, inline: !download}, nil
}

// DeleteLibraryItem removes the row, then the object unless a chat still
// shows it. Two deletes racing (this and the attachment sweep) can each see
// the other's row and leave the object behind; that only leaks storage.
func (s *Server) DeleteLibraryItem(ctx context.Context, req api.DeleteLibraryItemRequestObject) (api.DeleteLibraryItemResponseObject, error) {
	u, _, ws := me(ctx)
	d, err := s.Q.DeleteLibraryItem(ctx, store.DeleteLibraryItemParams{ID: req.ItemId, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	// A link saved without an image has no object.
	if d.Orphaned && d.BlobKey != "" {
		_ = s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, d.BlobKey)
	}
	if d.PosterKey != nil {
		_ = s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, *d.PosterKey)
	}
	return api.DeleteLibraryItem204Response{}, nil
}

// BulkDeleteLibraryItems removes many of the caller's items at once, then any
// objects nothing else still uses. Missing IDs or items owned by someone else
// are ignored so repeated deletes stay idempotent.
func (s *Server) BulkDeleteLibraryItems(ctx context.Context, req api.BulkDeleteLibraryItemsRequestObject) (api.BulkDeleteLibraryItemsResponseObject, error) {
	u, _, ws := me(ctx)
	if len(req.Body.Ids) == 0 {
		return nil, apperr.Invalid("ids", "provide at least one item id")
	}
	if len(req.Body.Ids) > maxLibraryBulkDelete {
		return nil, apperr.Invalid("ids", "at most %d items at once", maxLibraryBulkDelete)
	}
	ids := make([]uuid.UUID, 0, len(req.Body.Ids))
	seen := make(map[uuid.UUID]struct{}, len(req.Body.Ids))
	for _, id := range req.Body.Ids {
		if _, dup := seen[id]; dup {
			continue
		}
		seen[id] = struct{}{}
		ids = append(ids, id)
	}
	rows, err := s.Q.DeleteLibraryItems(ctx, store.DeleteLibraryItemsParams{Ids: ids, WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	delCtx := context.WithoutCancel(ctx)
	deletedBlobs := make(map[string]struct{}, len(rows))
	deletedPosters := make(map[string]struct{})
	for _, d := range rows {
		if d.Orphaned && d.BlobKey != "" {
			if _, done := deletedBlobs[d.BlobKey]; !done {
				deletedBlobs[d.BlobKey] = struct{}{}
				_ = s.Blobs.Delete(delCtx, s.ArtifactBucket, d.BlobKey)
			}
		}
		if d.PosterKey != nil && *d.PosterKey != "" {
			if _, done := deletedPosters[*d.PosterKey]; !done {
				deletedPosters[*d.PosterKey] = struct{}{}
				_ = s.Blobs.Delete(delCtx, s.ArtifactBucket, *d.PosterKey)
			}
		}
	}
	return api.BulkDeleteLibraryItems200JSONResponse{Deleted: len(rows)}, nil
}

// UploadLibraryItem stores an image of the person's own, e.g. their photo for
// "this is me". Uploads share the generated-image cap: both are what the
// Library keeps for good.
func (s *Server) UploadLibraryItem(ctx context.Context, req api.UploadLibraryItemRequestObject) (api.UploadLibraryItemResponseObject, error) {
	u, _, ws := me(ctx)
	f, err := readForm(req.Body)
	if err != nil {
		return nil, err
	}
	defer f.close()
	if f.file == nil {
		return nil, apperr.Invalid("file", "required")
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
	if runs.AudioNameType(name) != "" {
		return s.uploadLibraryAudio(ctx, u.ID, ws, f, name)
	}
	if !isImageName(name) {
		return s.uploadLibraryFile(ctx, u.ID, ws, f, name, head[:n])
	}
	ct, err := runs.ChatAttachmentType(name, f.file.Size, head[:n])
	if err != nil {
		return nil, err
	}
	if _, ok := runs.GeneratedImageType(head[:n]); !ok {
		return nil, apperr.Invalid("file", "%s isn't supported: the Library takes PNG, JPEG, GIF or WebP images and MP3, WAV, OGG or M4A audio", name)
	}
	// A soft cap: two concurrent uploads can each pass the check.
	stored, err := s.Q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: ws, UserID: u.ID})
	if err != nil {
		return nil, err
	}
	if stored+f.file.Size > runs.MaxGeneratedImageStorageBytes {
		return nil, apperr.Invalid("file", "your Library is full (1 GB): remove images you no longer need")
	}
	title := strings.TrimSpace(strings.TrimSuffix(name, path.Ext(name)))
	if title == "" {
		title = "Uploaded image"
	}
	if r := []rune(title); len(r) > runs.MaxLibraryTitleRunes {
		title = string(r[:runs.MaxLibraryTitleRunes])
	}
	key := runs.ChatAttachmentKey(ws, u.ID)
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, f.tmp, f.file.Size, ct); err != nil {
		return nil, err
	}
	l, err := s.Q.CreateUploadedLibraryItem(ctx, store.CreateUploadedLibraryItemParams{WorkspaceID: ws, UserID: u.ID, Title: title, Filename: name, ContentType: ct, SizeBytes: f.file.Size, BlobKey: key})
	if err != nil {
		_ = s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, key)
		return nil, err
	}
	source := api.LibraryItemSource(l.Source)
	return api.UploadLibraryItem201JSONResponse{Id: l.ID, Kind: api.LibraryItemKind(l.Kind), Title: l.Title, Filename: l.Filename, ContentType: l.ContentType, SizeBytes: l.SizeBytes,
		Source: &source, CreatedAt: l.CreatedAt}, nil
}

// isImageName reports whether name claims to be one of the image types the Library keeps as images.
func isImageName(name string) bool {
	switch strings.ToLower(path.Ext(name)) {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp":
		return true
	}
	return false
}

// uploadLibraryFile stores any other file the person added, as a file.
func (s *Server) uploadLibraryFile(ctx context.Context, userID, ws uuid.UUID, f *form, name string, head []byte) (api.UploadLibraryItemResponseObject, error) {
	l, err := s.keepFile(ctx, userID, ws, f.tmp, f.file.Size, name, head, fileOrigin{source: "upload"})
	if err != nil {
		return nil, err
	}
	return api.UploadLibraryItem201JSONResponse(toLibraryItem(libraryRow(l))), nil
}

// uploadLibraryAudio stores an audio file the person added. The file is read
// for its length and waveform here, so a tile never decodes audio in the browser.
func (s *Server) uploadLibraryAudio(ctx context.Context, userID, ws uuid.UUID, f *form, name string) (api.UploadLibraryItemResponseObject, error) {
	if f.file.Size <= 0 {
		return nil, apperr.Invalid("file", "the file is empty")
	}
	if f.file.Size > runs.MaxChatAttachmentBytes {
		return nil, apperr.Invalid("file", "audio files are limited to 25 MB")
	}
	info, err := runs.ReadAudioInfo(name, f.tmp, f.file.Size)
	if errors.Is(err, runs.ErrNotAudio) {
		return nil, apperr.Invalid("file", "%s isn't the %s audio file its name says", name, strings.TrimPrefix(path.Ext(name), "."))
	} else if err != nil {
		return nil, err
	}
	if _, err := f.tmp.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	stored, err := s.Q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: ws, UserID: userID})
	if err != nil {
		return nil, err
	}
	if stored+f.file.Size > runs.MaxGeneratedImageStorageBytes {
		return nil, apperr.Invalid("file", "your Library is full (1 GB): remove items you no longer need")
	}
	title := strings.TrimSpace(strings.TrimSuffix(name, path.Ext(name)))
	if title == "" {
		title = "Uploaded audio"
	}
	if r := []rune(title); len(r) > runs.MaxLibraryTitleRunes {
		title = string(r[:runs.MaxLibraryTitleRunes])
	}
	key := runs.ChatAttachmentKey(ws, userID)
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, f.tmp, f.file.Size, info.ContentType); err != nil {
		return nil, err
	}
	var duration *int32
	if info.DurationMS > 0 {
		d := int32(info.DurationMS)
		duration = &d
	}
	l, err := s.Q.CreateLibraryAudio(ctx, store.CreateLibraryAudioParams{WorkspaceID: ws, UserID: userID, Title: title, Filename: name, ContentType: info.ContentType,
		SizeBytes: f.file.Size, BlobKey: key, Source: "upload", DurationMs: duration, Peaks: info.Peaks})
	if err != nil {
		_ = s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, key)
		return nil, err
	}
	out := toLibraryItem(libraryRow(l))
	return api.UploadLibraryItem201JSONResponse(out), nil
}

// RenameLibraryItem retitles one of the caller's items.
func (s *Server) RenameLibraryItem(ctx context.Context, req api.RenameLibraryItemRequestObject) (api.RenameLibraryItemResponseObject, error) {
	u, _, ws := me(ctx)
	title := strings.TrimSpace(req.Body.Title)
	if n := len([]rune(title)); n < 1 || n > runs.MaxLibraryTitleRunes {
		return nil, apperr.Invalid("title", "provide 1–%d characters", runs.MaxLibraryTitleRunes)
	}
	l, err := s.Q.RenameLibraryItem(ctx, store.RenameLibraryItemParams{ID: req.ItemId, WorkspaceID: ws, UserID: u.ID, Title: title})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return api.RenameLibraryItem200JSONResponse(toLibraryItem(libraryRow(l))), nil
}

// SaveLibraryDiagram keeps an SVG from one of the caller's assistant replies.
// The object key comes from the content, so a repeat save (or two racing)
// lands on the same object and row.
func (s *Server) SaveLibraryDiagram(ctx context.Context, req api.SaveLibraryDiagramRequestObject) (api.SaveLibraryDiagramResponseObject, error) {
	u, _, ws := me(ctx)
	m, err := s.Q.GetChatMessage(ctx, req.Body.MessageId)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	chat, err := s.ownChat(ctx, m.SessionID)
	if err != nil {
		return nil, err
	}
	if m.Role != "assistant" {
		return nil, apperr.Invalid("message_id", "not an assistant reply")
	}
	svg, err := runs.CheckLibraryDiagram(req.Body.Svg)
	if err != nil {
		return nil, err
	}
	key := runs.LibraryDiagramKey(ws, u.ID, svg)
	l, err := s.Q.GetLibraryDiagram(ctx, store.GetLibraryDiagramParams{WorkspaceID: ws, UserID: u.ID, BlobKey: key})
	if errors.Is(err, pgx.ErrNoRows) {
		// A soft cap, as for uploads.
		stored, err := s.Q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		if stored+int64(len(svg)) > runs.MaxGeneratedImageStorageBytes {
			return nil, apperr.Invalid("svg", "your Library is full (1 GB): remove items you no longer need")
		}
		if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, bytes.NewReader(svg), int64(len(svg)), libraryDiagramType); err != nil {
			return nil, err
		}
		l, err = s.Q.CreateLibraryDiagram(ctx, store.CreateLibraryDiagramParams{WorkspaceID: ws, UserID: u.ID, Title: runs.LibraryDiagramTitle(chat.Title), Filename: "diagram.svg",
			ContentType: libraryDiagramType, SizeBytes: int64(len(svg)), BlobKey: key, ChatID: &chat.ID, MessageID: &m.ID, PersonaID: m.PersonaID})
		if err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	source := api.LibraryItemSource(l.Source)
	return api.SaveLibraryDiagram201JSONResponse{Id: l.ID, Kind: api.LibraryItemKind(l.Kind), Title: l.Title, Filename: l.Filename, ContentType: l.ContentType, SizeBytes: l.SizeBytes,
		ChatId: l.ChatID, PersonaId: l.PersonaID, Source: &source, CreatedAt: l.CreatedAt}, nil
}

// SetLibraryReference makes one of the caller's images the reference for a
// role, replacing the role's previous image and whatever this image stood for
// before. The persona must be the caller's own.
func (s *Server) SetLibraryReference(ctx context.Context, req api.SetLibraryReferenceRequestObject) (api.SetLibraryReferenceResponseObject, error) {
	u, _, ws := me(ctx)
	role := string(req.Body.Role)
	var persona *uuid.UUID
	switch req.Body.Role {
	case api.LibraryReferenceRoleSelf:
		if req.Body.PersonaId != nil {
			return nil, apperr.Invalid("persona_id", "only for role persona")
		}
	case api.LibraryReferenceRolePersona:
		if req.Body.PersonaId == nil {
			return nil, apperr.Invalid("persona_id", "required for role persona")
		}
		if _, err := s.Q.GetPersona(ctx, store.GetPersonaParams{ID: *req.Body.PersonaId, WorkspaceID: ws, UserID: u.ID}); errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.Invalid("persona_id", "not one of your personas")
		} else if err != nil {
			return nil, err
		}
		persona = req.Body.PersonaId
	default:
		return nil, apperr.Invalid("role", "persona or self")
	}
	if err := s.setLibraryReference(ctx, ws, u.ID, req.ItemId, &role, persona); err != nil {
		return nil, err
	}
	return api.SetLibraryReference204Response{}, nil
}

func (s *Server) ClearLibraryReference(ctx context.Context, req api.ClearLibraryReferenceRequestObject) (api.ClearLibraryReferenceResponseObject, error) {
	u, _, ws := me(ctx)
	if err := s.setLibraryReference(ctx, ws, u.ID, req.ItemId, nil, nil); err != nil {
		return nil, err
	}
	return api.ClearLibraryReference204Response{}, nil
}

// setLibraryReference marks item for role (nil clears it) under the person's
// reference lock, unmarking the role's current image first.
func (s *Server) setLibraryReference(ctx context.Context, ws, user, item uuid.UUID, role *string, persona *uuid.UUID) error {
	return pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		if err := q.LockLibraryReferences(ctx, store.LockLibraryReferencesParams{WorkspaceID: ws, UserID: user}); err != nil {
			return err
		}
		l, err := q.GetLibraryItem(ctx, store.GetLibraryItemParams{ID: item, WorkspaceID: ws, UserID: user})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		} else if err != nil {
			return err
		}
		if role != nil {
			if l.Kind != "image" {
				return apperr.Invalid("role", "only an image can be a reference")
			}
			if err := q.ClearLibraryReferenceRole(ctx, store.ClearLibraryReferenceRoleParams{WorkspaceID: ws, UserID: user, Role: *role, PersonaID: persona}); err != nil {
				return err
			}
		}
		_, err = q.SetLibraryReference(ctx, store.SetLibraryReferenceParams{ID: item, WorkspaceID: ws, UserID: user, Role: role, PersonaID: persona})
		return err
	})
}

func intp(v *int32) *int {
	if v == nil {
		return nil
	}
	n := int(*v)
	return &n
}

// libraryRow widens a bare item to the row a listing returns, with no chat,
// persona or project to name.
func libraryRow(l store.LibraryItem) store.ListLibraryItemsRow {
	return store.ListLibraryItemsRow{ID: l.ID, WorkspaceID: l.WorkspaceID, UserID: l.UserID, Kind: l.Kind, Title: l.Title, Filename: l.Filename, ContentType: l.ContentType,
		SizeBytes: l.SizeBytes, BlobKey: l.BlobKey, ChatID: l.ChatID, MessageID: l.MessageID, PersonaID: l.PersonaID, CreatedAt: l.CreatedAt, Reference: l.Reference,
		ReferencePersonaID: l.ReferencePersonaID, Source: l.Source, Url: l.Url, Note: l.Note, Site: l.Site, VideoID: l.VideoID, LinkStatus: l.LinkStatus, Summary: l.Summary,
		DurationMs: l.DurationMs, Width: l.Width, Height: l.Height, PosterKey: l.PosterKey, Peaks: l.Peaks, Method: l.Method,
		Detail: l.Detail, SourceID: l.SourceID, SourceStamp: l.SourceStamp}
}

package httpapi

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os"
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

// fileOrigin says where a file came from: the person's upload, or a persona
// handing it over in a chat.
type fileOrigin struct {
	source    string // "upload" or "generated"
	chatID    *uuid.UUID
	personaID *uuid.UUID
	title     string
	detail    string
}

// keepFile checks a file, describes it, stores its bytes and records the item.
// r holds size bytes from the start. A refused file stores nothing.
func (s *Server) keepFile(ctx context.Context, userID, ws uuid.UUID, r interface {
	io.ReadSeeker
	io.ReaderAt
}, size int64, name string, head []byte, from fileOrigin) (store.LibraryItem, error) {
	if size <= 0 {
		return store.LibraryItem{}, apperr.Invalid("file", "the file is empty")
	}
	if size > runs.MaxChatAttachmentBytes {
		return store.LibraryItem{}, apperr.Invalid("file", "files are limited to 25 MB")
	}
	ct, err := runs.FileType(name, head)
	if err != nil {
		return store.LibraryItem{}, apperr.Invalid("file", "%s", err.Error())
	}
	prev, err := runs.BuildFilePreview(name, r, size)
	if err != nil {
		return store.LibraryItem{}, err
	}
	if _, err := r.Seek(0, io.SeekStart); err != nil {
		return store.LibraryItem{}, err
	}
	// A soft cap: two concurrent saves can each pass the check.
	stored, err := s.Q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: ws, UserID: userID})
	if err != nil {
		return store.LibraryItem{}, err
	}
	if stored+size > runs.MaxGeneratedImageStorageBytes {
		return store.LibraryItem{}, apperr.Invalid("file", "your Library is full (1 GB): remove items you no longer need")
	}
	title := strings.TrimSpace(from.title)
	if title == "" {
		title = strings.TrimSpace(name)
	}
	if rs := []rune(title); len(rs) > runs.MaxLibraryTitleRunes {
		title = string(rs[:runs.MaxLibraryTitleRunes])
	}
	key := runs.ChatAttachmentKey(ws, userID)
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, r, size, ct); err != nil {
		return store.LibraryItem{}, err
	}
	detail := strings.TrimSpace(from.detail)
	if detail == "" {
		detail = runs.FileDetail(prev)
	}
	if rs := []rune(detail); len(rs) > 200 {
		detail = string(rs[:200])
	}
	l, err := s.Q.CreateLibraryFile(ctx, store.CreateLibraryFileParams{WorkspaceID: ws, UserID: userID, Title: title, Filename: name, ContentType: ct, SizeBytes: size, BlobKey: key,
		Source: from.source, ChatID: from.chatID, PersonaID: from.personaID, Detail: detail})
	if err != nil {
		_ = s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, key)
		return store.LibraryItem{}, err
	}
	return l, nil
}

// GetLibraryFilePreview shows a file's contents at a glance. Only the caller's
// own files have one; nothing is run, rendered or unpacked.
func (s *Server) GetLibraryFilePreview(ctx context.Context, req api.GetLibraryFilePreviewRequestObject) (api.GetLibraryFilePreviewResponseObject, error) {
	u, _, ws := me(ctx)
	l, err := s.Q.GetLibraryItem(ctx, store.GetLibraryItemParams{ID: req.ItemId, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && l.Kind != "file") {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	o, err := s.Blobs.Get(ctx, s.ArtifactBucket, l.BlobKey)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	defer o.Body.Close()
	// A zip's directory sits at its end, so the file is read from a temp copy.
	tmp, err := os.CreateTemp("", "vesper-preview-*")
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()
	if _, err := io.Copy(tmp, io.LimitReader(o.Body, runs.MaxChatAttachmentBytes+1)); err != nil {
		return nil, err
	}
	fi, err := tmp.Stat()
	if err != nil {
		return nil, err
	}
	p, err := runs.BuildFilePreview(l.Filename, tmp, fi.Size())
	if err != nil {
		return nil, err
	}
	out := api.LibraryFilePreview{Kind: api.LibraryFilePreviewKind(p.Kind), Total: p.Total, Truncated: p.Truncated}
	if p.Lines != nil {
		out.Lines = &p.Lines
	}
	if p.Rows != nil {
		out.Rows = &p.Rows
	}
	if p.Entries != nil {
		entries := make([]api.LibraryFileEntry, len(p.Entries))
		for i, e := range p.Entries {
			entries[i] = api.LibraryFileEntry{Name: e.Name, Size: e.Size}
		}
		out.Entries = &entries
	}
	return api.GetLibraryFilePreview200JSONResponse(out), nil
}

// exportSourceOf says which app an export came from and whether that source
// has been edited since. A canvas's updated_at moves on every edit, so a deck,
// design or document edited at all after the export reads as changed.
func exportSourceOf(l store.ListLibraryItemsRow) *api.LibraryExportSource {
	if l.SourceID == nil {
		return nil
	}
	out := api.LibraryExportSource{Id: *l.SourceID, Kind: api.LibraryExportSourceKind(exportApp(deref(l.SourceKind)))}
	switch {
	case l.SourceTitle == nil:
		out.Status = api.LibraryExportSourceStatusDeleted
	case l.SourceUpdatedAt != nil && l.SourceStamp != nil && l.SourceUpdatedAt.After(*l.SourceStamp):
		out.Status, out.Title = api.LibraryExportSourceStatusChanged, l.SourceTitle
	default:
		out.Status, out.Title = api.LibraryExportSourceStatusCurrent, l.SourceTitle
	}
	return &out
}

// exportApp names the app that owns a canvas kind.
func exportApp(canvasKind string) string {
	switch canvasKind {
	case "deck":
		return "slides"
	case "design":
		return "designs"
	}
	return "docs"
}

// exportFile is a finished export, built by an app's Export menu or from a document.
type exportFile struct {
	data        []byte
	contentType string
	filename    string
	title       string
	detail      string
}

// keepExport stores an export as a frozen copy linked to its source canvas.
// The copy is addressed by its content, so exporting unchanged work again
// returns the item already made.
func (s *Server) keepExport(ctx context.Context, userID, ws uuid.UUID, cv store.GetMyCanvasRow, f exportFile) (store.ListLibraryItemsRow, error) {
	key := runs.ExportKey(ws, userID, cv.ID, f.data)
	if old, err := s.Q.GetLibraryExportByBlob(ctx, store.GetLibraryExportByBlobParams{WorkspaceID: ws, UserID: userID, BlobKey: key}); err == nil {
		return exportRow(old, cv), nil
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return store.ListLibraryItemsRow{}, err
	}
	stored, err := s.Q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: ws, UserID: userID})
	if err != nil {
		return store.ListLibraryItemsRow{}, err
	}
	size := int64(len(f.data))
	if stored+size > runs.MaxGeneratedImageStorageBytes {
		return store.ListLibraryItemsRow{}, apperr.Invalid("file", "your Library is full (1 GB): remove items you no longer need")
	}
	title := strings.TrimSpace(f.title)
	if title == "" {
		title = cv.Title
	}
	if r := []rune(title); len(r) > runs.MaxLibraryTitleRunes {
		title = string(r[:runs.MaxLibraryTitleRunes])
	}
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, bytes.NewReader(f.data), size, f.contentType); err != nil {
		return store.ListLibraryItemsRow{}, err
	}
	l, err := s.Q.CreateLibraryExport(ctx, store.CreateLibraryExportParams{WorkspaceID: ws, UserID: userID, Title: title, Filename: f.filename, ContentType: f.contentType,
		SizeBytes: size, BlobKey: key, ChatID: &cv.ChatID, Detail: f.detail, SourceID: &cv.ID, SourceStamp: &cv.UpdatedAt})
	if err != nil {
		_ = s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, key)
		return store.ListLibraryItemsRow{}, err
	}
	return exportRow(l, cv), nil
}

// exportRow is an export as a listing shows it, with its source as it is now.
func exportRow(l store.LibraryItem, cv store.GetMyCanvasRow) store.ListLibraryItemsRow {
	row := libraryRow(l)
	row.SourceTitle, row.SourceKind, row.SourceUpdatedAt = &cv.Title, &cv.Kind, &cv.UpdatedAt
	return row
}

// exportExt is a filename's extension, lower-cased.
func exportExt(name string) string { return strings.ToLower(path.Ext(name)) }

// KeepChatFile saves a file a persona handed over in a chat (the save_file tool).
func (s *Server) KeepChatFile(ctx context.Context, userID, ws uuid.UUID, chatID, personaID *uuid.UUID, title, filename string, data []byte) (store.LibraryItem, error) {
	return s.KeepChatFileWithDetail(ctx, userID, ws, chatID, personaID, title, filename, "", data)
}

// KeepChatFileWithDetail saves a file a persona made in a chat with an optional
// summary line (such as "4 pages · Letter" for a rendered PDF).
func (s *Server) KeepChatFileWithDetail(ctx context.Context, userID, ws uuid.UUID, chatID, personaID *uuid.UUID, title, filename, detail string, data []byte) (store.LibraryItem, error) {
	head := data[:min(len(data), 512)]
	return s.keepFile(ctx, userID, ws, bytes.NewReader(data), int64(len(data)), filename, head, fileOrigin{source: "generated", chatID: chatID, personaID: personaID, title: title, detail: detail})
}

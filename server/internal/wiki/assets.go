package wiki

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Content keys are scoped to the uploader. The same lock serializes a
// re-upload with deletion of an older, unreferenced object of that hash.
func (s *Service) StoreKnowledgeAsset(ctx context.Context, ws, user uuid.UUID, hash, filename, typ string, size int64, reader io.Reader) (store.KnowledgeAsset, error) {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	key := fmt.Sprintf("knowledge-assets/%s/%s/%s", ws, user, hash)
	var asset store.KnowledgeAsset
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if err := q.LockKnowledgeBlob(ctx, key); err != nil {
			return err
		}
		if err := objects.Put(ctx, bucket, key, reader, size, typ); err != nil {
			return err
		}
		var err error
		asset, err = q.PutKnowledgeAsset(ctx, store.PutKnowledgeAssetParams{WorkspaceID: ws, OwnerUserID: user, ContentHash: hash, BlobKey: key, Filename: filename, ContentType: typ, SizeBytes: size})
		if err != nil {
			return err
		}
		return q.ClearKnowledgeAssetDeletion(ctx, key)
	})
	return asset, err
}

// Deletion uses persisted tombstones. A database failure or S3 outage cannot
// make the sweeper forget an orphan; a concurrent re-upload cancels deletion.
func (s *Service) SweepKnowledgeAssets(ctx context.Context) error {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return err
	}
	q := store.New(s.Pool)
	if err = q.StageOrphanKnowledgeAssets(ctx); err != nil {
		return err
	}
	keys, err := q.ListKnowledgeAssetDeletions(ctx)
	if err != nil {
		return err
	}
	for _, item := range keys {
		err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			q := store.New(tx)
			if err := q.LockKnowledgeBlob(ctx, item.BlobKey); err != nil {
				return err
			}
			used, err := q.KnowledgeBlobInUse(ctx, item.BlobKey)
			if err != nil {
				return err
			}
			if !used {
				if err = objects.Delete(ctx, bucket, item.BlobKey); err != nil {
					return err
				}
			}
			return q.ClearKnowledgeAssetDeletion(ctx, item.BlobKey)
		})
		if err != nil {
			return err
		}
	}
	archives, err := q.FinishedKnowledgeArchives(ctx)
	if err != nil {
		return err
	}
	for _, a := range archives {
		if err = objects.Delete(ctx, bucket, a.BlobKey); err != nil {
			return err
		}
		if err = q.MarkKnowledgeArchiveDeleted(ctx, a.ID); err != nil {
			return err
		}
	}
	return nil
}

// PersonaAssetLimit bounds what a persona attaches to a page in one call: it
// is read into memory, unlike the person's streamed uploads.
const PersonaAssetLimit = 25 << 20

// AttachmentFolder is the top-level Obsidian-style folder where Knowledge
// attachments are organized.
const AttachmentFolder = "attachments"

// AttachmentFolderPath returns the logical Knowledge path for an attachment
// inside the top-level attachments folder.
func AttachmentFolderPath(filename string) string {
	base := path.Base(strings.ReplaceAll(strings.TrimSpace(filename), "\\", "/"))
	if base == "." || base == ".." || base == "/" || base == "" {
		base = "attachment"
	}
	return AttachmentFolder + "/" + base
}

// SanitizeAttachmentFilename cleans a user-supplied attachment filename to a
// safe single path segment, returning "" if nothing usable remains.
func SanitizeAttachmentFilename(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || strings.ContainsAny(trimmed, "/\\\x00\r\n") {
		return ""
	}
	base := path.Base(trimmed)
	if base == "." || base == ".." || base == "/" || base == "" {
		return ""
	}
	return base
}

// AttachmentFilenameTarget extracts a candidate attachment filename from an
// Obsidian-style embed target such as "diagram.png" or "attachments/diagram.png".
// Returns "" when the target does not look like a file name (e.g. a note title
// without an extension or a nested folder path outside attachments/).
func AttachmentFilenameTarget(target string) string {
	t := strings.TrimSpace(strings.ReplaceAll(target, "\\", "/"))
	if t == "" {
		return ""
	}
	lower := strings.ToLower(t)
	if strings.HasPrefix(lower, AttachmentFolder+"/") {
		t = t[len(AttachmentFolder)+1:]
	}
	if strings.Contains(t, "/") {
		return ""
	}
	clean := SanitizeAttachmentFilename(t)
	if clean == "" || path.Ext(clean) == "" {
		return ""
	}
	return clean
}

// RenameKnowledgeAsset renames an attachment owned by user. Returns
// apperr.ErrNotFound if the attachment does not exist or is not visible to user,
// ErrAttachmentForbidden if visible via a shared page owned by someone else,
// and apperr.Invalid if the filename is invalid.
func (s *Service) RenameKnowledgeAsset(ctx context.Context, ws, user, id uuid.UUID, filename string) (store.KnowledgeAsset, error) {
	clean := SanitizeAttachmentFilename(filename)
	if clean == "" {
		return store.KnowledgeAsset{}, apperr.Invalid("filename", "must be a valid file name without slashes")
	}
	q := store.New(s.Pool)
	existing, err := q.GetKnowledgeAsset(ctx, store.GetKnowledgeAssetParams{ID: id, WorkspaceID: ws, Viewer: &user})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.KnowledgeAsset{}, apperr.ErrNotFound
	}
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	if existing.OwnerUserID != user {
		return store.KnowledgeAsset{}, ErrAttachmentForbidden
	}
	updated, err := q.RenameKnowledgeAsset(ctx, store.RenameKnowledgeAssetParams{
		ID:          id,
		WorkspaceID: ws,
		OwnerUserID: user,
		Filename:    clean,
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.KnowledgeAsset{}, apperr.ErrNotFound
	}
	return updated, err
}

// DeleteKnowledgeAsset deletes an attachment owned by user and cleans up its
// backing blob if no remaining knowledge_assets row references that blob key.
func (s *Service) DeleteKnowledgeAsset(ctx context.Context, ws, user, id uuid.UUID) (store.KnowledgeAsset, error) {
	q := store.New(s.Pool)
	existing, err := q.GetKnowledgeAsset(ctx, store.GetKnowledgeAssetParams{ID: id, WorkspaceID: ws, Viewer: &user})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.KnowledgeAsset{}, apperr.ErrNotFound
	}
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	if existing.OwnerUserID != user {
		return store.KnowledgeAsset{}, ErrAttachmentForbidden
	}

	var deleted store.KnowledgeAsset
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		if err := tq.LockKnowledgeBlob(ctx, existing.BlobKey); err != nil {
			return err
		}
		var err error
		deleted, err = tq.DeleteKnowledgeAsset(ctx, store.DeleteKnowledgeAssetParams{
			ID:          id,
			WorkspaceID: ws,
			OwnerUserID: user,
		})
		if err != nil {
			return err
		}
		return tq.QueueKnowledgeAssetDeletion(ctx, deleted.BlobKey)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.KnowledgeAsset{}, apperr.ErrNotFound
	}
	if err != nil {
		return store.KnowledgeAsset{}, err
	}

	// Best-effort immediate blob cleanup; any failure stays queued in
	// knowledge_asset_deletions for SweepKnowledgeAssets.
	if objects, bucket, err := s.vaultObjects(); err == nil {
		_ = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			tq := store.New(tx)
			if err := tq.LockKnowledgeBlob(ctx, deleted.BlobKey); err != nil {
				return err
			}
			used, err := tq.KnowledgeBlobInUse(ctx, deleted.BlobKey)
			if err != nil {
				return err
			}
			if !used {
				if err := objects.Delete(ctx, bucket, deleted.BlobKey); err != nil {
					return err
				}
			}
			return tq.ClearKnowledgeAssetDeletion(ctx, deleted.BlobKey)
		})
	}
	return deleted, nil
}

// DetectAssetContentType sniffs a Knowledge asset's MIME type from its leading
// bytes, preserving SVG detection for .svg files and recognizing common
// container formats that http.DetectContentType leaves as octet-stream.
func DetectAssetContentType(filename string, head []byte) string {
	if len(head) > 512 {
		head = head[:512]
	}
	typ := http.DetectContentType(head)
	ext := strings.ToLower(path.Ext(filename))
	if ext == ".svg" && strings.Contains(string(head), "<svg") {
		// Sniffing reads an SVG as text; the viewer serves it as a download either way.
		return "image/svg+xml"
	}
	if typ == "video/webm" && ext == ".mkv" {
		return "video/x-matroska"
	}
	if typ != "application/octet-stream" {
		return typ
	}
	if len(head) >= 12 && string(head[4:8]) == "ftyp" {
		switch string(head[8:12]) {
		case "avif", "avis":
			return "image/avif"
		case "heic", "heix", "hevc", "hevx":
			return "image/heic"
		case "mif1", "msf1":
			return "image/heif"
		case "qt  ":
			return "video/quicktime"
		case "M4A ", "M4B ":
			return "audio/mp4"
		case "M4V ", "mp41", "mp42", "isom", "iso2", "avc1":
			return "video/mp4"
		}
	}
	if len(head) >= 4 && string(head[:4]) == "fLaC" {
		return "audio/flac"
	}
	if len(head) >= 4 && string(head[:4]) == "OggS" {
		if ext == ".opus" {
			return "audio/opus"
		}
		return "audio/ogg"
	}
	if len(head) >= 12 && string(head[:4]) == "RIFF" && string(head[8:12]) == "WAVE" {
		return "audio/wav"
	}
	if len(head) >= 12 && string(head[:4]) == "FORM" && (string(head[8:12]) == "AIFF" || string(head[8:12]) == "AIFC") {
		return "audio/aiff"
	}
	if len(head) >= 4 && head[0] == 0x1a && head[1] == 0x45 && head[2] == 0xdf && head[3] == 0xa3 {
		if ext == ".webm" {
			return "video/webm"
		}
		return "video/x-matroska"
	}
	if (len(head) >= 3 && string(head[:3]) == "ID3") || (len(head) >= 2 && head[0] == 0xff && (head[1]&0xe0) == 0xe0) {
		return "audio/mpeg"
	}
	switch ext {
	case ".mp3":
		return "audio/mpeg"
	case ".m4a", ".m4b":
		return "audio/mp4"
	case ".aac":
		return "audio/aac"
	case ".wav":
		return "audio/wav"
	case ".aif", ".aiff":
		return "audio/aiff"
	case ".flac":
		return "audio/flac"
	case ".ogg":
		return "audio/ogg"
	case ".opus":
		return "audio/opus"
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".mov":
		return "video/quicktime"
	case ".webm":
		return "video/webm"
	case ".mkv":
		return "video/x-matroska"
	case ".heic":
		return "image/heic"
	case ".heif":
		return "image/heif"
	}
	return typ
}

// StoreAssetBytes stores a file a persona made (an SVG, a chart) as one of the
// person's Knowledge assets, typed from its content as uploads are.
func (s *Service) StoreAssetBytes(ctx context.Context, ws, user uuid.UUID, filename string, data []byte) (store.KnowledgeAsset, error) {
	if len(data) == 0 {
		return store.KnowledgeAsset{}, apperr.Invalid("data", "is empty")
	}
	if len(data) > PersonaAssetLimit {
		return store.KnowledgeAsset{}, apperr.Invalid("data", "is over the %d MB limit", PersonaAssetLimit>>20)
	}
	filename = path.Base(strings.ReplaceAll(strings.TrimSpace(filename), "\\", "/"))
	if filename == "." || filename == ".." || filename == "/" || filename == "" {
		filename = "attachment"
	}
	typ := DetectAssetContentType(filename, data[:min(len(data), 512)])
	sum := sha256.Sum256(data)
	return s.StoreKnowledgeAsset(ctx, ws, user, fmt.Sprintf("%x", sum), filename, typ, int64(len(data)), bytes.NewReader(data))
}

// StoreAttachmentAsset copies a file the person sent in chat into their
// Knowledge assets, so a persona can embed it in a page.
func (s *Service) StoreAttachmentAsset(ctx context.Context, ws, user, attachment uuid.UUID) (store.KnowledgeAsset, error) {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	a, err := store.New(s.Pool).GetChatAttachment(ctx, store.GetChatAttachmentParams{ID: attachment, WorkspaceID: ws, UserID: user})
	if err != nil {
		return store.KnowledgeAsset{}, apperr.ErrNotFound
	}
	if a.MessageID == nil {
		return store.KnowledgeAsset{}, apperr.Invalid("attachment_id", "send this file in chat before attaching it")
	}
	if a.SizeBytes > PersonaAssetLimit {
		return store.KnowledgeAsset{}, apperr.Invalid("attachment_id", "is over the %d MB limit; the person can upload it in the Knowledge app", PersonaAssetLimit>>20)
	}
	object, err := objects.Open(ctx, bucket, a.BlobKey)
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	defer object.Close()
	data, err := io.ReadAll(io.LimitReader(object, PersonaAssetLimit+1))
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	return s.StoreAssetBytes(ctx, ws, user, a.Filename, data)
}

// StoreLibraryItemAsset copies a file from the person's Library (such as a
// persona-generated PDF) into their Knowledge assets so it can be embedded in a page.
func (s *Service) StoreLibraryItemAsset(ctx context.Context, ws, user, itemID uuid.UUID) (store.KnowledgeAsset, error) {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	item, err := store.New(s.Pool).GetLibraryItem(ctx, store.GetLibraryItemParams{ID: itemID, WorkspaceID: ws, UserID: user})
	if err != nil {
		return store.KnowledgeAsset{}, apperr.ErrNotFound
	}
	if item.BlobKey == "" {
		return store.KnowledgeAsset{}, apperr.Invalid("library_item_id", "this Library item has no file to attach")
	}
	if item.SizeBytes > PersonaAssetLimit {
		return store.KnowledgeAsset{}, apperr.Invalid("library_item_id", "is over the %d MB limit; the person can upload it in the Knowledge app", PersonaAssetLimit>>20)
	}
	object, err := objects.Open(ctx, bucket, item.BlobKey)
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	defer object.Close()
	data, err := io.ReadAll(io.LimitReader(object, PersonaAssetLimit+1))
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	name := item.Filename
	if strings.TrimSpace(name) == "" {
		name = item.Title
	}
	return s.StoreAssetBytes(ctx, ws, user, name, data)
}

var (
	// ErrAssetTooLarge is returned when a Knowledge asset or Library item exceeds the caller's byte limit.
	ErrAssetTooLarge = errors.New("asset exceeds size limit")
	// ErrAssetNoFile is returned when a Library item has no backing blob (such as a saved link).
	ErrAssetNoFile = errors.New("library item has no file")
	// ErrAttachmentForbidden is returned when a non-owner tries to rename or delete a shared attachment.
	ErrAttachmentForbidden = errors.New("only the uploader can modify this attachment")
)

func readBoundedObject(ctx context.Context, objects VaultObjects, bucket, key string, maxBytes int64) ([]byte, error) {
	rc, err := objects.Open(ctx, bucket, key)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, apperr.ErrNotFound
		}
		return nil, err
	}
	defer rc.Close()
	if maxBytes <= 0 {
		return io.ReadAll(rc)
	}
	data, err := io.ReadAll(io.LimitReader(rc, maxBytes+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, ErrAssetTooLarge
	}
	return data, nil
}

// ReadKnowledgeAsset loads a Knowledge attachment's bytes if viewer can read it
// (either as owner or via a visible Knowledge page referencing it).
func (s *Service) ReadKnowledgeAsset(ctx context.Context, ws, viewer, id uuid.UUID, maxBytes int64) (store.KnowledgeAsset, []byte, error) {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return store.KnowledgeAsset{}, nil, err
	}
	asset, err := store.New(s.Pool).GetKnowledgeAsset(ctx, store.GetKnowledgeAssetParams{ID: id, WorkspaceID: ws, Viewer: &viewer})
	if errors.Is(err, pgx.ErrNoRows) {
		return store.KnowledgeAsset{}, nil, apperr.ErrNotFound
	}
	if err != nil {
		return store.KnowledgeAsset{}, nil, err
	}
	if maxBytes > 0 && asset.SizeBytes > maxBytes {
		return asset, nil, ErrAssetTooLarge
	}
	data, err := readBoundedObject(ctx, objects, bucket, asset.BlobKey, maxBytes)
	if err != nil {
		return asset, nil, err
	}
	return asset, data, nil
}

// ReadLibraryItem loads a Library item's bytes for its owning user. Private Docs
// and items belonging to other users return apperr.ErrNotFound.
func (s *Service) ReadLibraryItem(ctx context.Context, ws, user, id uuid.UUID, maxBytes int64) (store.LibraryItem, []byte, error) {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return store.LibraryItem{}, nil, err
	}
	item, err := store.New(s.Pool).GetLibraryItem(ctx, store.GetLibraryItemParams{ID: id, WorkspaceID: ws, UserID: user})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && item.Kind == "document") {
		return store.LibraryItem{}, nil, apperr.ErrNotFound
	}
	if err != nil {
		return store.LibraryItem{}, nil, err
	}
	if item.BlobKey == "" {
		return item, nil, ErrAssetNoFile
	}
	if maxBytes > 0 && item.SizeBytes > maxBytes {
		return item, nil, ErrAssetTooLarge
	}
	data, err := readBoundedObject(ctx, objects, bucket, item.BlobKey, maxBytes)
	if err != nil {
		return item, nil, err
	}
	return item, data, nil
}

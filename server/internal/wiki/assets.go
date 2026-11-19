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
	if filename == "." || filename == "/" || filename == "" {
		filename = "attachment"
	}
	typ := http.DetectContentType(data)
	if strings.EqualFold(path.Ext(filename), ".svg") && strings.Contains(string(data[:min(len(data), 512)]), "<svg") {
		// Sniffing reads an SVG as text; the viewer serves it as a download either way.
		typ = "image/svg+xml"
	}
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

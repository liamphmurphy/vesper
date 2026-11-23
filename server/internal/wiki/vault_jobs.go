package wiki

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type VaultObjects interface {
	Put(context.Context, string, string, io.Reader, int64, string) error
	Open(context.Context, string, string) (io.ReadCloser, error)
	Delete(context.Context, string, string) error
}

func (s *Service) vaultObjects() (VaultObjects, string, error) {
	if s.Objects != nil {
		return s.Objects, s.Artifacts.Bucket, nil
	}
	if s.Artifacts != nil && s.Artifacts.Blobs != nil {
		if objects, ok := s.Artifacts.Blobs.(VaultObjects); ok {
			return objects, s.Artifacts.Bucket, nil
		}
	}
	return nil, "", apperr.Conflict("vault storage is unavailable")
}
func VaultUploadLimit() int64 {
	if raw := os.Getenv("KNOWLEDGE_IMPORT_MAX_BYTES"); raw != "" {
		if n, err := strconv.ParseInt(raw, 10, 64); err == nil && n > 0 {
			return n
		}
	}
	return MaxVaultUpload
}

// QueueVault spools to bounded temporary storage because S3 requires an exact
// content length and ZIP needs random access. The archive never lives in RAM.
func (s *Service) QueueVault(ctx context.Context, ws, user uuid.UUID, folder string, reader io.Reader) (store.KnowledgeImport, error) {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return store.KnowledgeImport{}, err
	}
	if folder != "" {
		if _, err = artifacts.ValidNotePath(strings.Trim(folder, "/") + "/placeholder"); err != nil {
			return store.KnowledgeImport{}, err
		}
	}
	file, err := os.CreateTemp("", "vesper-vault-upload-*")
	if err != nil {
		return store.KnowledgeImport{}, err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	limit := VaultUploadLimit()
	n, err := io.Copy(file, io.LimitReader(reader, limit+1))
	if err != nil {
		return store.KnowledgeImport{}, err
	}
	if n > limit {
		return store.KnowledgeImport{}, apperr.Invalid("file", "vault exceeds the configured upload limit")
	}
	if n == 0 {
		return store.KnowledgeImport{}, apperr.Invalid("file", "archive is empty")
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return store.KnowledgeImport{}, err
	}
	key := fmt.Sprintf("knowledge-imports/%s/%s/%s.zip", ws, user, uuid.NewString())
	if err = objects.Put(ctx, bucket, key, file, n, "application/zip"); err != nil {
		return store.KnowledgeImport{}, err
	}
	job, err := store.New(s.Pool).NewKnowledgeImport(ctx, store.NewKnowledgeImportParams{WorkspaceID: ws, UserID: user, BlobKey: key, Folder: strings.Trim(folder, "/")})
	if err != nil {
		objects.Delete(ctx, bucket, key)
	}
	return job, err
}

const (
	vaultIdlePollInterval  = 60 * time.Second
	vaultRetryPollInterval = 2 * time.Second
	vaultAssetSweepEvery   = 10 * time.Minute
)

func (s *Service) RunVaultWorker(ctx context.Context, log *slog.Logger) {
	s.runVaultWorker(ctx, log, vaultIdlePollInterval, vaultAssetSweepEvery)
}

func (s *Service) runVaultWorker(ctx context.Context, log *slog.Logger, idlePoll, assetSweepEvery time.Duration) {
	if idlePoll <= 0 {
		idlePoll = vaultIdlePollInterval
	}
	if assetSweepEvery <= 0 {
		assetSweepEvery = vaultAssetSweepEvery
	}
	wake := make(chan struct{}, 1)
	var listenerUp bool
	listenerState := make(chan bool, 4)
	if s.Pool != nil {
		go s.listenForVaultWork(ctx, wake, listenerState)
	}
	lastSweep := time.Now()
	poll := time.NewTimer(vaultRetryPollInterval)
	defer poll.Stop()
	resetPoll := func() {
		if !poll.Stop() {
			select {
			case <-poll.C:
			default:
			}
		}
		d := vaultRetryPollInterval
		if listenerUp {
			d = idlePoll
		}
		poll.Reset(d)
	}
	for {
		if time.Since(lastSweep) > assetSweepEvery {
			if err := s.SweepKnowledgeAssets(ctx); err != nil && ctx.Err() == nil {
				log.Error("knowledge asset sweep", "error", err)
			}
			lastSweep = time.Now()
		}
		worked, err := s.ProcessNextVault(ctx)
		if err != nil && ctx.Err() == nil {
			log.Error("knowledge import", "error", err)
		}
		if worked && ctx.Err() == nil {
			continue
		}
		resetPoll()
		select {
		case <-ctx.Done():
			return
		case up := <-listenerState:
			listenerUp = up
			if up {
				// Process anything queued before LISTEN took effect.
				continue
			}
		case <-wake:
		case <-poll.C:
		}
	}
}

func (s *Service) listenForVaultWork(ctx context.Context, wake chan<- struct{}, listenerState chan<- bool) {
	for ctx.Err() == nil {
		s.listenVaultOnce(ctx, wake, listenerState)
		select {
		case listenerState <- false:
		default:
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

func (s *Service) listenVaultOnce(ctx context.Context, wake chan<- struct{}, listenerState chan<- bool) {
	conn, err := s.Pool.Acquire(ctx)
	if err != nil {
		return
	}
	defer func() {
		_ = conn.Conn().Close(context.Background())
		conn.Release()
	}()
	if _, err := conn.Exec(ctx, "LISTEN vesper_work"); err != nil {
		return
	}
	select {
	case listenerState <- true:
	default:
	}
	for {
		n, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			return
		}
		if n.Payload == "knowledge_import" {
			select {
			case wake <- struct{}{}:
			default:
			}
		}
	}
}
func (s *Service) ProcessNextVault(ctx context.Context) (bool, error) {
	q := store.New(s.Pool)
	lease := uuid.New()
	job, err := q.ClaimKnowledgeImport(ctx, &lease)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	ctx = pageview.Person(ctx, job.UserID)
	err = s.processVault(ctx, &job)
	if err != nil && ctx.Err() == nil {
		_, writeErr := q.UpdateKnowledgeImport(ctx, store.UpdateKnowledgeImportParams{ID: job.ID, LeaseID: &lease, State: "failed", Plan: job.Plan, Report: job.Report, Error: err.Error(), FilesDone: job.FilesDone})
		if writeErr != nil {
			return true, fmt.Errorf("%v; saving failure: %w", err, writeErr)
		}
	}
	return true, err
}
func (s *Service) openVault(ctx context.Context, job store.KnowledgeImport) (*os.File, *zip.Reader, error) {
	objects, bucket, err := s.vaultObjects()
	if err != nil {
		return nil, nil, err
	}
	object, err := objects.Open(ctx, bucket, job.BlobKey)
	if err != nil {
		return nil, nil, err
	}
	defer object.Close()
	file, err := os.CreateTemp("", "vesper-vault-job-*")
	if err != nil {
		return nil, nil, err
	}
	n, err := io.Copy(file, io.LimitReader(object, VaultUploadLimit()+1))
	if err == nil && n > VaultUploadLimit() {
		err = apperr.Invalid("file", "archive exceeds upload limit")
	}
	if err != nil {
		file.Close()
		os.Remove(file.Name())
		return nil, nil, err
	}
	z, err := zip.NewReader(file, n)
	if err != nil {
		file.Close()
		os.Remove(file.Name())
		return nil, nil, apperr.Invalid("file", "not a valid zip archive")
	}
	return file, z, nil
}
func (s *Service) processVault(ctx context.Context, job *store.KnowledgeImport) error {
	file, z, err := s.openVault(ctx, *job)
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	q := store.New(s.Pool)
	if job.State == "scanning" {
		plan, err := PlanVault(z, job.Folder)
		if err != nil {
			return err
		}
		for i := range plan.Entries {
			e := &plan.Entries[i]
			if e.Kind != "note" || e.Error != "" {
				continue
			}
			var a store.Artifact
			if e.ExportID != nil {
				a, err = q.GetArtifact(ctx, store.GetArtifactParams{ID: *e.ExportID, WorkspaceID: job.WorkspaceID, Viewer: &job.UserID})
			} else {
				err = pgx.ErrNoRows
			}
			if errors.Is(err, pgx.ErrNoRows) {
				source, sourceErr := q.GetImportSource(ctx, store.GetImportSourceParams{WorkspaceID: job.WorkspaceID, UserID: job.UserID, Folder: job.Folder, SourcePath: e.Source, Viewer: &job.UserID})
				if sourceErr == nil {
					a, err = q.GetArtifact(ctx, store.GetArtifactParams{ID: source.ArtifactID, WorkspaceID: job.WorkspaceID, Viewer: &job.UserID})
				} else if !errors.Is(sourceErr, pgx.ErrNoRows) {
					return sourceErr
				}
			}
			if errors.Is(err, pgx.ErrNoRows) {
				a, err = q.GetNoteByPath(ctx, store.GetNoteByPathParams{WorkspaceID: job.WorkspaceID, Path: e.Path, Viewer: &job.UserID})
			}
			if err == nil {
				e.ExistingID = &a.ID
				e.BeforeID = a.CurrentVersionID
				e.Conflict = true
				if a.Path != nil {
					e.Path = *a.Path
				}
			} else if !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
		}
		job.Plan, err = json.Marshal(plan)
		if err != nil {
			return err
		}
		job.State = "preview"
		return s.persistVault(ctx, job)
	}
	var plan VaultPlan
	if err = json.Unmarshal(job.Plan, &plan); err != nil {
		return err
	}
	files := map[string]*zip.File{}
	for _, f := range z.File {
		files[f.Name] = f
	}
	prior, err := q.ListImportFiles(ctx, job.ID)
	if err != nil {
		return err
	}
	done := map[string]store.KnowledgeImportFile{}
	assetRefs := map[string]string{}
	for _, item := range prior {
		done[item.SourcePath] = item
		if item.AssetID != nil {
			asset, err := q.GetKnowledgeAsset(ctx, store.GetKnowledgeAssetParams{ID: *item.AssetID, WorkspaceID: job.WorkspaceID, Viewer: &job.UserID})
			if err == nil {
				assetRefs[item.SourcePath] = AttachmentRef(asset.ID, asset.Filename)
			}
		}
	}
	reports := []map[string]any{}
	_ = json.Unmarshal(job.Report, &reports)
	reportIndex := map[string]int{}
	for i, r := range reports {
		if name, ok := r["source"].(string); ok {
			reportIndex[name] = i
		}
	}
	for pass := 0; pass < 2; pass++ {
		if pass == 1 && !plan.Prepared {
			if err = s.prepareVaultPlan(ctx, *job, &plan, files, assetRefs); err != nil {
				return err
			}
			plan.Prepared = true
			job.Plan, err = json.Marshal(plan)
			if err != nil {
				return err
			}
			if err = s.persistVault(ctx, job); err != nil {
				return err
			}
		}
		for _, e := range plan.Entries {
			if (pass == 0) != (e.Kind == "attachment") {
				continue
			}
			if _, ok := done[e.Source]; ok {
				continue
			}
			if err = ctx.Err(); err != nil {
				return err
			}
			status := "created"
			reason := e.Error
			if reason != "" {
				status = "skipped"
			} else if e.Kind == "attachment" {
				f := files[e.Source]
				if f == nil {
					return apperr.Invalid("file", "archive member disappeared")
				}
				_, lookupErr := q.OwnKnowledgeAssetByHash(ctx, store.OwnKnowledgeAssetByHashParams{WorkspaceID: job.WorkspaceID, OwnerUserID: job.UserID, ContentHash: e.Hash})
				reused := lookupErr == nil
				asset, assetErr := s.importAttachment(ctx, *job, f)
				if assetErr != nil {
					status = "failed"
					reason = assetErr.Error()
				} else {
					assetRefs[e.Source] = AttachmentRef(asset.ID, asset.Filename)
					if reused {
						status = "unchanged"
					}
					err = q.RecordImportFile(ctx, store.RecordImportFileParams{ImportID: job.ID, SourcePath: e.Source, AssetID: &asset.ID, Created: !reused, Status: status})
					if err != nil {
						return err
					}
				}
			} else {
				status, err = s.importNote(ctx, *job, e, files[e.Source], plan.Entries, assetRefs)
				if err != nil {
					status = "failed"
					reason = err.Error()
				}
			}
			report := map[string]any{"source": e.Source, "status": status, "reason": reason}
			if i, ok := reportIndex[e.Source]; ok {
				reports[i] = report
			} else {
				reportIndex[e.Source] = len(reports)
				reports = append(reports, report)
			}
			job.FilesDone = int32(len(reports))
			job.Report, _ = json.Marshal(reports)
			if err = s.persistVault(ctx, job); err != nil {
				return err
			}
		}
	}
	job.State = "done"
	return s.persistVault(ctx, job)
}
func (s *Service) persistVault(ctx context.Context, job *store.KnowledgeImport) error {
	n, err := store.New(s.Pool).UpdateKnowledgeImport(ctx, store.UpdateKnowledgeImportParams{ID: job.ID, LeaseID: job.LeaseID, State: job.State, Plan: job.Plan, Report: job.Report, Error: job.Error, FilesDone: job.FilesDone})
	if err != nil {
		return err
	}
	if n != 1 {
		return apperr.Conflict("import lease expired")
	}
	return nil
}
func (s *Service) importAttachment(ctx context.Context, job store.KnowledgeImport, f *zip.File) (store.KnowledgeAsset, error) {
	file, err := os.CreateTemp("", "vesper-vault-asset-*")
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	rc, err := f.Open()
	if err != nil {
		return store.KnowledgeAsset{}, err
	}
	defer rc.Close()
	hash := sha256.New()
	n, err := io.Copy(io.MultiWriter(file, hash), io.LimitReader(rc, int64(maxVaultEntry)+1))
	if err != nil || uint64(n) != f.UncompressedSize64 {
		return store.KnowledgeAsset{}, apperr.Invalid("file", "corrupt attachment")
	}
	head := make([]byte, 512)
	file.Seek(0, io.SeekStart)
	read, err := file.Read(head)
	if err != nil && err != io.EOF {
		return store.KnowledgeAsset{}, err
	}
	typ := http.DetectContentType(head[:read])
	file.Seek(0, io.SeekStart)
	digest := fmt.Sprintf("%x", hash.Sum(nil))
	previous, err := store.New(s.Pool).OwnKnowledgeAssetByHash(ctx, store.OwnKnowledgeAssetByHashParams{WorkspaceID: job.WorkspaceID, OwnerUserID: job.UserID, ContentHash: digest})
	if err == nil {
		return previous, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return store.KnowledgeAsset{}, err
	}
	return s.StoreKnowledgeAsset(ctx, job.WorkspaceID, job.UserID, digest, path.Base(f.Name), typ, n, file)
}
func (s *Service) importNote(ctx context.Context, job store.KnowledgeImport, e VaultEntry, f *zip.File, entries []VaultEntry, assets map[string]string) (string, error) {
	if f == nil {
		return "failed", apperr.Invalid("file", "archive member disappeared")
	}
	content, err := vaultNoteContent(f, e, entries, assets)
	if err != nil {
		return "failed", err
	}
	body, props, raw := content.Body, content.Properties, content.Raw
	created, updated := content.Created, content.Updated
	safeAliases := content.Aliases
	status := "created"
	err = s.tx(ctx, job.WorkspaceID, func(q *store.Queries) error {
		if _, err := q.LockKnowledgeImportLease(ctx, store.LockKnowledgeImportLeaseParams{ID: job.ID, LeaseID: job.LeaseID}); err != nil {
			return err
		}
		var existing store.Artifact
		if e.ExistingID != nil {
			existing, err = q.LockArtifact(ctx, store.LockArtifactParams{ID: *e.ExistingID, WorkspaceID: job.WorkspaceID, Viewer: &job.UserID})
			if err != nil {
				return err
			}
		}
		save := Save{Path: e.Path, Title: &e.Title, Body: body, Properties: props, Note: "Imported from " + e.Source, Mode: ModeCreate}
		state := artifacts.Published
		if e.ExistingID != nil {
			if existing.CurrentVersionID != nil {
				v, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *existing.CurrentVersionID, ArtifactID: existing.ID, WorkspaceID: job.WorkspaceID, Viewer: &job.UserID})
				if err != nil {
					return err
				}
				oldRaw, _ := artifacts.NormalizeProperties(artifacts.DecodeProperties(v.Properties))
				if !e.Duplicate && v.BodyMd != nil && *v.BodyMd == body && bytes.Equal(oldRaw, raw) && existing.Title == e.Title {
					status = "unchanged"
					return q.RecordImportFile(ctx, store.RecordImportFileParams{ImportID: job.ID, SourcePath: e.Source, ArtifactID: &existing.ID, BeforeID: existing.CurrentVersionID, AppliedID: existing.CurrentVersionID, Status: status})
				}
			}
			if job.Policy == "skip" {
				status = "skipped"
				return q.RecordImportFile(ctx, store.RecordImportFileParams{ImportID: job.ID, SourcePath: e.Source, ArtifactID: &existing.ID, Status: status})
			}
			if job.Policy == "keep_both" {
				if !e.Duplicate {
					return apperr.Conflict("page changed after the preview; scan the vault again")
				}

			} else {
				if existing.Audience != "private" {
					return apperr.Conflict("import replacement must remain private; use keep both for shared pages")
				}
				save.PageID = &existing.ID
				save.Mode = ModeReplace
				save.BaseID = e.BeforeID
				source, sourceErr := q.GetImportSource(ctx, store.GetImportSourceParams{WorkspaceID: job.WorkspaceID, UserID: job.UserID, Folder: job.Folder, SourcePath: e.Source, Viewer: &job.UserID})
				if sourceErr != nil && !errors.Is(sourceErr, pgx.ErrNoRows) {
					return sourceErr
				}
				if existing.CurrentVersionID != nil && ((sourceErr == nil && source.VersionID != nil && *source.VersionID != *existing.CurrentVersionID) || (e.BeforeID == nil || *e.BeforeID != *existing.CurrentVersionID)) {
					state = artifacts.Suggested
					save.BaseID = existing.CurrentVersionID
					status = "conflict"
				} else {
					status = "updated"
				}
			}
		}
		result, err := s.write(ctx, q, job.WorkspaceID, artifacts.Actor{Type: "user", ID: job.UserID}, save, state)
		if err != nil {
			return err
		}
		if result.Created {
			if err = q.SetImportedPageTimes(ctx, store.SetImportedPageTimesParams{ID: result.Note.ID, CreatedAt: created, UpdatedAt: updated, Viewer: &job.UserID}); err != nil {
				return err
			}
		}
		if e.Renamed || len(e.Aliases) > len(safeAliases) {
			for _, alias := range append([]string{strings.TrimSuffix(e.Source, path.Ext(e.Source))}, e.Aliases...) {
				if err = q.AddAlias(ctx, store.AddAliasParams{WorkspaceID: job.WorkspaceID, ArtifactID: result.Note.ID, Path: alias}); err != nil {
					return err
				}
			}
		}
		vid := result.Version.ID
		if vid == uuid.Nil && result.Note.CurrentVersionID != nil {
			vid = *result.Note.CurrentVersionID
		}
		var beforeTitle *string
		if e.ExistingID != nil {
			beforeTitle = &existing.Title
		}
		if err = q.RecordImportFile(ctx, store.RecordImportFileParams{ImportID: job.ID, SourcePath: e.Source, ArtifactID: &result.Note.ID, BeforeID: e.BeforeID, AppliedID: &vid, Created: result.Created, Status: status, BeforeTitle: beforeTitle, BeforePath: existing.Path, AppliedTitle: &result.Note.Title, AppliedPath: result.Note.Path}); err != nil {
			return err
		}
		if state == artifacts.Published {
			return q.SetImportSource(ctx, store.SetImportSourceParams{WorkspaceID: job.WorkspaceID, UserID: job.UserID, Folder: job.Folder, SourcePath: e.Source, ArtifactID: result.Note.ID, VersionID: &vid, Viewer: &job.UserID})
		}
		return nil
	})
	return status, err
}
func parseVaultTime(v any, fallback time.Time) time.Time {
	if text, ok := v.(string); ok {
		for _, layout := range []string{time.RFC3339, "2006-01-02"} {
			if parsed, err := time.Parse(layout, text); err == nil {
				return parsed
			}
		}
	}
	if fallback.IsZero() {
		return time.Now().UTC()
	}
	return fallback
}

func (s *Service) QueueAttachedVault(ctx context.Context, ws, user, attachment uuid.UUID, folder string) (store.KnowledgeImport, error) {
	objectStore, bucket, err := s.vaultObjects()
	if err != nil {
		return store.KnowledgeImport{}, err
	}
	a, err := store.New(s.Pool).GetChatAttachment(ctx, store.GetChatAttachmentParams{ID: attachment, WorkspaceID: ws, UserID: user})
	if err != nil {
		return store.KnowledgeImport{}, apperr.ErrNotFound
	}
	if a.MessageID == nil {
		return store.KnowledgeImport{}, apperr.Invalid("attachment", "send this file in chat before importing it")
	}
	object, err := objectStore.Open(ctx, bucket, a.BlobKey)
	if err != nil {
		return store.KnowledgeImport{}, err
	}
	defer object.Close()
	return s.QueueVault(ctx, ws, user, folder, object)
}

func (s *Service) UndoVault(ctx context.Context, ws, user, id uuid.UUID) error {
	ctx = pageview.Person(ctx, user)
	return s.tx(ctx, ws, func(q *store.Queries) error {
		job, err := q.LockKnowledgeImportForUndo(ctx, store.LockKnowledgeImportForUndoParams{ID: id, WorkspaceID: ws, UserID: user})
		if err != nil {
			return err
		}
		files, err := q.ListImportFiles(ctx, id)
		if err != nil {
			return err
		}
		// Validate every head before changing any of them. One later human edit
		// refuses the whole undo; a batch is never partially rolled back.
		for _, f := range files {
			if f.ArtifactID == nil || f.AppliedID == nil || f.Status == "unchanged" || f.Status == "skipped" {
				continue
			}
			a, err := q.LockArtifact(ctx, store.LockArtifactParams{ID: *f.ArtifactID, WorkspaceID: ws, Viewer: &user})
			if errors.Is(err, pgx.ErrNoRows) {
				continue
			}
			if err != nil {
				return err
			}
			if f.Status == "conflict" {
				proposal, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *f.AppliedID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: &user})
				if err != nil {
					return err
				}
				if proposal.State != artifacts.Suggested {
					return apperr.Conflict("an import suggestion was reviewed after this import")
				}
			} else {
				later, err := q.ImportUndoHasLaterWork(ctx, store.ImportUndoHasLaterWorkParams{ID: a.ID, VersionID: *f.AppliedID, Viewer: &user, AppliedAt: f.AppliedAt})
				if err != nil {
					return err
				}
				if deref(later) || a.Audience != "private" || (f.Created && (a.ChatSessionID != nil || a.PersonaPaused || !a.PersonaDirect)) {
					return apperr.Conflict("a page was used after this import; undo would discard later work")
				}
			}
			if f.Status != "conflict" && (a.CurrentVersionID == nil || *a.CurrentVersionID != *f.AppliedID || (f.AppliedTitle != nil && a.Title != *f.AppliedTitle) || (f.AppliedPath != nil && (a.Path == nil || *a.Path != *f.AppliedPath))) {
				return apperr.Conflict("a page changed after this import; undo would discard later edits")
			}
		}
		for _, f := range files {
			if f.ArtifactID == nil || f.AppliedID == nil || f.Status == "unchanged" || f.Status == "skipped" {
				continue
			}
			a, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: *f.ArtifactID, WorkspaceID: ws, Viewer: &user})
			if errors.Is(err, pgx.ErrNoRows) {
				continue
			}
			if err != nil {
				return err
			}
			if f.Status == "conflict" {
				if err = q.DeleteUndoneImportVersion(ctx, store.DeleteUndoneImportVersionParams{ID: *f.AppliedID, ArtifactID: a.ID, Viewer: &user}); err != nil {
					return err
				}
				continue
			}
			if f.Created {
				if err = q.DeleteArtifact(ctx, store.DeleteArtifactParams{ID: a.ID, WorkspaceID: ws}); err != nil {
					return err
				}
				continue
			}
			if f.BeforeID != nil {
				if f.BeforePath != nil {
					a, err = renameNote(ctx, q, ws, a.ID, *f.BeforePath)
					if err != nil {
						return err
					}
				}
				if f.BeforeTitle != nil {
					a, err = q.SetNotePath(ctx, store.SetNotePathParams{ID: a.ID, Path: a.Path, Title: *f.BeforeTitle})
					if err != nil {
						return err
					}
				}
				v, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *f.BeforeID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: &user})
				if err != nil {
					return err
				}
				if err = artifacts.Publish(ctx, q, a, v); err != nil {
					return err
				}
				if *f.BeforeID != *f.AppliedID {
					if err = q.DeleteUndoneImportVersion(ctx, store.DeleteUndoneImportVersionParams{ID: *f.AppliedID, ArtifactID: a.ID, Viewer: &user}); err != nil {
						return err
					}
				}
				if err = q.SetImportSource(ctx, store.SetImportSourceParams{WorkspaceID: ws, UserID: user, Folder: job.Folder, SourcePath: f.SourcePath, ArtifactID: a.ID, VersionID: f.BeforeID, Viewer: &user}); err != nil {
					return err
				}
			}
		}
		return q.MarkKnowledgeImportUndone(ctx, id)
	})
}

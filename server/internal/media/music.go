package media

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"regexp"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	MaxMusicPromptRunes = 4000
	MaxMusicLyricsRunes = 8000
	MaxMusicTitleRunes  = 200
	musicJobTimeout     = 5 * time.Minute
	musicClipDurationMS = 30000
	musicFullDurationMS = 120000
	progressThrottle    = 400 * time.Millisecond
)

var unsafeMusicFilename = regexp.MustCompile(`[^a-z0-9]+`)

// MusicRunner executes music generation jobs against the active MusicGenerator,
// updates chat_audio_jobs (triggering SSE audio.updated), and saves tracks to
// the blob store and Library.
type MusicRunner struct {
	Service *Service
	Pool    *pgxpool.Pool
	Blobs   *blob.Store
	Bucket  string
	Log     *slog.Logger

	mu     sync.Mutex
	closed bool
	active map[uuid.UUID]context.CancelFunc
	wg     sync.WaitGroup
}

// StartChatMusicInput describes a music generation request in a chat.
type StartChatMusicInput struct {
	WorkspaceID  uuid.UUID
	UserID       uuid.UUID
	ChatID       uuid.UUID
	RunID        *uuid.UUID
	TurnID       *uuid.UUID
	PersonaID    *uuid.UUID
	Title        string
	Prompt       string
	Lyrics       string
	Instrumental bool
	Length       MusicLength
	ProviderID   string
}

// Close cancels any in-flight music jobs and waits for their goroutines to finish.
func (r *MusicRunner) Close() {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.closed = true
	cancels := make([]context.CancelFunc, 0, len(r.active))
	for _, fn := range r.active {
		cancels = append(cancels, fn)
	}
	r.mu.Unlock()
	for _, fn := range cancels {
		fn()
	}
	r.wg.Wait()
}

// StartAsync validates input, creates the chat_audio_jobs row, and runs
// generation in a background goroutine tracked until Close().
func (r *MusicRunner) StartAsync(ctx context.Context, in StartChatMusicInput) (store.ChatAudioJob, error) {
	job, gen, desc, req, err := r.prepareJob(ctx, in)
	if err != nil {
		return store.ChatAudioJob{}, err
	}

	jobCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), musicJobTimeout)
	if !r.track(job.ID, cancel) {
		cancel()
		reason := "Stopped."
		kind := runs.VideoFailureStopped
		if failed, ferr := store.New(r.Pool).FailMusicAudioJob(context.Background(), store.FailMusicAudioJobParams{
			ID:          job.ID,
			Error:       &reason,
			FailureKind: &kind,
			ErrorKind:   "",
		}); ferr == nil {
			return failed, nil
		}
		return job, nil
	}

	r.wg.Go(func() {
		defer cancel()
		defer r.untrack(job.ID)
		r.executeJob(jobCtx, job, gen, desc, req)
	})
	return job, nil
}

// RunSync validates input, creates the job row, and executes generation
// synchronously (honoring ctx and StopJob cancellation).
func (r *MusicRunner) RunSync(ctx context.Context, in StartChatMusicInput) (store.ChatAudioJob, error) {
	job, gen, desc, req, err := r.prepareJob(ctx, in)
	if err != nil {
		return store.ChatAudioJob{}, err
	}

	jobCtx, cancel := context.WithTimeout(ctx, musicJobTimeout)
	defer cancel()
	if !r.track(job.ID, cancel) {
		reason := "Stopped."
		kind := runs.VideoFailureStopped
		_, _ = store.New(r.Pool).FailMusicAudioJob(context.Background(), store.FailMusicAudioJobParams{
			ID:          job.ID,
			Error:       &reason,
			FailureKind: &kind,
			ErrorKind:   "",
		})
		return store.ChatAudioJob{}, apperr.Conflict("music generation stopped because the server is shutting down")
	}
	defer r.untrack(job.ID)

	return r.executeJob(jobCtx, job, gen, desc, req)
}

// StopJob cancels an in-flight music job and marks it stopped.
func (r *MusicRunner) StopJob(ctx context.Context, ws, chatID, jobID uuid.UUID) (store.ChatAudioJob, error) {
	q := store.New(r.Pool)
	job, err := q.GetChatAudioJob(ctx, store.GetChatAudioJobParams{ID: jobID, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && (job.ChatID == nil || *job.ChatID != chatID)) {
		return store.ChatAudioJob{}, apperr.ErrNotFound
	}
	if err != nil {
		return store.ChatAudioJob{}, err
	}
	if job.State != "running" {
		return job, nil
	}
	if job.SourceKind != "music" {
		return store.ChatAudioJob{}, apperr.Conflict("Stop this audio by stopping the chat turn.")
	}

	r.mu.Lock()
	cancel := r.active[jobID]
	r.mu.Unlock()
	if cancel != nil {
		cancel()
	}

	reason := "Stopped."
	kind := runs.VideoFailureStopped
	stopped, err := q.FailMusicAudioJob(ctx, store.FailMusicAudioJobParams{
		ID:          jobID,
		Error:       &reason,
		FailureKind: &kind,
		ErrorKind:   "",
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return q.GetChatAudioJob(ctx, store.GetChatAudioJobParams{ID: jobID, WorkspaceID: ws})
	}
	return stopped, err
}

func (r *MusicRunner) prepareJob(ctx context.Context, in StartChatMusicInput) (store.ChatAudioJob, MusicGenerator, Descriptor, MusicRequest, error) {
	var zeroJob store.ChatAudioJob
	if r == nil || r.Service == nil || r.Pool == nil {
		return zeroJob, nil, Descriptor{}, MusicRequest{}, errors.New("media: music runner is not configured")
	}
	if r.Blobs == nil || r.Bucket == "" {
		return zeroJob, nil, Descriptor{}, MusicRequest{}, apperr.Conflict("Vesper has no storage configured for audio.")
	}

	prompt := strings.TrimSpace(in.Prompt)
	if n := utf8.RuneCountInString(prompt); n < 1 || n > MaxMusicPromptRunes {
		return zeroJob, nil, Descriptor{}, MusicRequest{}, apperr.Invalid("prompt", "provide 1–%d characters", MaxMusicPromptRunes)
	}
	lyrics := ""
	if !in.Instrumental {
		lyrics = strings.TrimSpace(in.Lyrics)
		if utf8.RuneCountInString(lyrics) > MaxMusicLyricsRunes {
			return zeroJob, nil, Descriptor{}, MusicRequest{}, apperr.Invalid("lyrics", "at most %d characters", MaxMusicLyricsRunes)
		}
	}

	length := in.Length
	if length == "" {
		length = LengthClip
	}
	var plannedMS int32
	switch length {
	case LengthClip:
		plannedMS = musicClipDurationMS
	case LengthFull:
		plannedMS = musicFullDurationMS
	default:
		return zeroJob, nil, Descriptor{}, MusicRequest{}, apperr.Invalid("length", "use clip or full")
	}

	title := strings.TrimSpace(strings.ReplaceAll(in.Title, "\n", " "))
	if title == "" {
		title = deriveMusicTitle(prompt)
	}
	if utf8.RuneCountInString(title) > MaxMusicTitleRunes {
		return zeroJob, nil, Descriptor{}, MusicRequest{}, apperr.Invalid("title", "at most %d characters", MaxMusicTitleRunes)
	}

	gen, desc, err := r.Service.ResolveMusic(ctx, in.WorkspaceID, in.ProviderID)
	if err != nil {
		var pe *ProviderError
		if errors.As(err, &pe) {
			return zeroJob, nil, Descriptor{}, MusicRequest{}, apperr.Conflict("%s", pe.Message)
		}
		return zeroJob, nil, Descriptor{}, MusicRequest{}, err
	}

	method := desc.Label
	if len([]rune(method)) > runs.MaxAudioMethodRunes {
		method = string([]rune(method)[:runs.MaxAudioMethodRunes])
	}

	q := store.New(r.Pool)
	createParams := store.CreateMusicAudioJobParams{
		WorkspaceID:  in.WorkspaceID,
		UserID:       in.UserID,
		ChatID:       &in.ChatID,
		RunID:        in.RunID,
		TurnID:       in.TurnID,
		PersonaID:    in.PersonaID,
		Title:        title,
		DurationMs:   plannedMS,
		Method:       method,
		StageNote:    "Queued for " + method + "…",
		ProviderID:   desc.ID,
		Prompt:       prompt,
		Lyrics:       lyrics,
		Instrumental: in.Instrumental,
	}
	var job store.ChatAudioJob
	if in.RunID != nil && in.TurnID != nil {
		err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
			tq := store.New(tx)
			if _, err := tq.LockChatSession(ctx, store.LockChatSessionParams{ID: in.ChatID, WorkspaceID: in.WorkspaceID}); err != nil {
				return err
			}
			n, err := tq.CountChatAudioJobsForTurn(ctx, store.CountChatAudioJobsForTurnParams{RunID: in.RunID, TurnID: in.TurnID})
			if err != nil {
				return err
			}
			if n >= runs.MaxChatAudioJobsPerTurn {
				return apperr.Conflict("You can generate at most %d audio tracks in one reply; tell the person to ask again for more.", runs.MaxChatAudioJobsPerTurn)
			}
			var cerr error
			job, cerr = tq.CreateMusicAudioJob(ctx, createParams)
			return cerr
		})
	} else {
		job, err = q.CreateMusicAudioJob(ctx, createParams)
	}
	if err != nil {
		return zeroJob, nil, Descriptor{}, MusicRequest{}, err
	}

	req := MusicRequest{
		Title:        title,
		Prompt:       prompt,
		Lyrics:       lyrics,
		Instrumental: in.Instrumental,
		Length:       length,
	}
	return job, gen, desc, req, nil
}

func (r *MusicRunner) executeJob(jobCtx context.Context, job store.ChatAudioJob, gen MusicGenerator, desc Descriptor, req MusicRequest) (store.ChatAudioJob, error) {
	q := store.New(r.Pool)
	_, _ = q.UpdateMusicAudioJobStage(jobCtx, store.UpdateMusicAudioJobStageParams{
		ID:        job.ID,
		Stage:     runs.AudioStageRender,
		Percent:   15,
		StageNote: "Generating with " + desc.Label + "…",
	})

	var (
		progMu   sync.Mutex
		lastPct  = 15
		lastSent = time.Now()
	)
	onProgress := func(p MusicProgress) {
		pct := min(max(p.Percent, 15), 85)
		note := strings.TrimSpace(p.Note)
		if note == "" {
			note = "Generating with " + desc.Label + "…"
		}
		progMu.Lock()
		if pct <= lastPct || time.Since(lastSent) < progressThrottle {
			progMu.Unlock()
			return
		}
		lastPct = pct
		lastSent = time.Now()
		progMu.Unlock()

		_ = q.UpdateMusicAudioJobProgress(jobCtx, store.UpdateMusicAudioJobProgressParams{
			ID:        job.ID,
			Percent:   int32(pct),
			StageNote: note,
		})
	}

	clip, err := gen.GenerateMusic(jobCtx, req, onProgress)
	if err != nil {
		return r.recordFailure(jobCtx, job, err)
	}
	if err := jobCtx.Err(); err != nil {
		return r.recordFailure(jobCtx, job, err)
	}

	size := int64(len(clip.Data))
	if size == 0 || size > runs.MaxChatAttachmentBytes {
		return r.recordFailure(jobCtx, job, fmt.Errorf("generated audio size %d is invalid", size))
	}

	stored, err := q.ChatGeneratedImageBytes(jobCtx, store.ChatGeneratedImageBytesParams{
		WorkspaceID: job.WorkspaceID,
		UserID:      job.UserID,
	})
	if err != nil {
		return r.recordFailure(jobCtx, job, err)
	}
	if stored+size > runs.MaxGeneratedImageStorageBytes {
		return r.recordFailure(jobCtx, job, errors.New("Library storage is full (1 GB), so the track couldn't be saved."))
	}

	_, _ = q.UpdateMusicAudioJobStage(jobCtx, store.UpdateMusicAudioJobStageParams{
		ID:        job.ID,
		Stage:     runs.AudioStageSave,
		Percent:   90,
		StageNote: "Saving to Library…",
	})

	ext := normalizeExt(clip.FilenameExt, clip.Data)
	filename := musicFilename(job.Title, ext)
	info, err := runs.ReadAudioInfo(filename, bytes.NewReader(clip.Data), size)
	if err != nil {
		// Fall back to adapter metadata if ReadAudioInfo rejects a valid format.
		info = runs.AudioInfo{ContentType: clip.ContentType, DurationMS: clip.DurationMS}
		if info.ContentType == "" {
			info.ContentType = "audio/mpeg"
		}
	}
	duration := info.DurationMS
	if duration == 0 {
		duration = clip.DurationMS
	}
	if duration == 0 {
		duration = int(job.DurationMs)
	}

	key := fmt.Sprintf("chat-audio/%s/%s/music-%s%s", job.WorkspaceID, job.ID, uuid.NewString()[:8], ext)
	if err := r.Blobs.Put(jobCtx, r.Bucket, key, bytes.NewReader(clip.Data), size, info.ContentType); err != nil {
		return r.recordFailure(jobCtx, job, fmt.Errorf("store music audio: %w", err))
	}

	var finished store.ChatAudioJob
	err = pgx.BeginFunc(jobCtx, r.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		// Re-fetch chat_id/message_id in case the chat changed while generating.
		cur, err := tq.GetChatAudioJob(jobCtx, store.GetChatAudioJobParams{ID: job.ID, WorkspaceID: job.WorkspaceID})
		if err != nil {
			return err
		}
		var libID *uuid.UUID
		if cur.ChatID != nil {
			item, err := tq.CreateLibraryAudio(jobCtx, store.CreateLibraryAudioParams{
				WorkspaceID: job.WorkspaceID,
				UserID:      job.UserID,
				Title:       job.Title,
				Filename:    filename,
				ContentType: info.ContentType,
				SizeBytes:   size,
				BlobKey:     key,
				Source:      "generated",
				ChatID:      cur.ChatID,
				MessageID:   cur.MessageID,
				PersonaID:   cur.PersonaID,
				DurationMs:  int32p(duration),
				Peaks:       info.Peaks,
				Method:      job.Method,
			})
			if err != nil {
				return err
			}
			libID = &item.ID
		}
		finished, err = tq.FinishChatAudioJob(jobCtx, store.FinishChatAudioJobParams{
			ID:                job.ID,
			OutputBlobKey:     &key,
			OutputFilename:    &filename,
			OutputContentType: &info.ContentType,
			OutputSizeBytes:   &size,
			OutputDurationMs:  int32p(duration),
			LibraryItemID:     libID,
		})
		return err
	})
	if err != nil {
		_ = r.Blobs.Delete(context.WithoutCancel(jobCtx), r.Bucket, key)
		return r.recordFailure(jobCtx, job, err)
	}
	return finished, nil
}

func (r *MusicRunner) recordFailure(jobCtx context.Context, job store.ChatAudioJob, err error) (store.ChatAudioJob, error) {
	fctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	var (
		reason      string
		failureKind = runs.VideoFailureError
		errorKind   string
	)
	if errors.Is(err, context.Canceled) || errors.Is(jobCtx.Err(), context.Canceled) {
		reason = "Stopped."
		failureKind = runs.VideoFailureStopped
	} else {
		k, msg := ClassifyError(err)
		reason = msg
		errorKind = string(k)
	}

	if runes := []rune(reason); len(runes) > runs.MaxVideoErrorRunes {
		reason = string(runes[:runs.MaxVideoErrorRunes])
	}

	q := store.New(r.Pool)
	failed, ferr := q.FailMusicAudioJob(fctx, store.FailMusicAudioJobParams{
		ID:          job.ID,
		Error:       &reason,
		FailureKind: &failureKind,
		ErrorKind:   errorKind,
	})
	if ferr != nil {
		if !errors.Is(ferr, pgx.ErrNoRows) && r.Log != nil {
			r.Log.Warn("fail music audio", "audio", job.ID, "err", ferr)
		}
		if cur, gerr := q.GetChatAudioJob(fctx, store.GetChatAudioJobParams{ID: job.ID, WorkspaceID: job.WorkspaceID}); gerr == nil {
			return cur, err
		}
		return job, err
	}
	return failed, err
}

func (r *MusicRunner) track(id uuid.UUID, cancel context.CancelFunc) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return false
	}
	if r.active == nil {
		r.active = map[uuid.UUID]context.CancelFunc{}
	}
	r.active[id] = cancel
	return true
}

func (r *MusicRunner) untrack(id uuid.UUID) {
	r.mu.Lock()
	delete(r.active, id)
	r.mu.Unlock()
}

func deriveMusicTitle(prompt string) string {
	clean := strings.Join(strings.Fields(prompt), " ")
	runes := []rune(clean)
	if len(runes) > 60 {
		clean = strings.TrimSpace(string(runes[:57])) + "…"
	}
	if clean == "" {
		return "Generated music"
	}
	return clean
}

func normalizeExt(ext string, data []byte) string {
	ext = strings.ToLower(strings.TrimSpace(ext))
	switch ext {
	case ".wav", ".mp3", ".ogg", ".m4a":
		return ext
	}
	switch runs.AudioTypeFromHead(data) {
	case "audio/wav":
		return ".wav"
	case "audio/ogg":
		return ".ogg"
	case "audio/mp4":
		return ".m4a"
	default:
		return ".mp3"
	}
}

func musicFilename(title, ext string) string {
	s := strings.Trim(unsafeMusicFilename.ReplaceAllString(strings.ToLower(title), "-"), "-")
	if len(s) > 80 {
		s = strings.TrimRight(s[:80], "-")
	}
	if s == "" {
		s = "music"
	}
	return s + ext
}

func int32p(v int) *int32 {
	x := int32(v)
	return &x
}

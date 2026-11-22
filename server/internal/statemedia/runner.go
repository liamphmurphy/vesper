package statemedia

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"image"
	"image/color"
	_ "image/gif" // a portrait may be any image the server holds
	"image/jpeg"
	_ "image/png"
	"log/slog"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"golang.org/x/image/draw"
	_ "golang.org/x/image/webp"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/looppack"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	// MaxTweakRunes bounds a follow-up edit instruction.
	MaxTweakRunes = 1000
	// DefaultLoopSeconds is a loop's length when the persona row doesn't say
	// (personas.loop_seconds, 4-10). Omni bookends only clips of 3-10s.
	DefaultLoopSeconds = 8
	// AspectRatio is the provider's portrait format; looppack keeps it.
	AspectRatio = "9:16"
	// LoopWidth and LoopHeight are the packed size: 9:16 at a size that stays
	// sharp on a Retina companion stage of about 180x320 points.
	LoopWidth  = 360
	LoopHeight = 640
	// LoopFPS is smooth for micro-motion and keeps a 10s loop to 200 frames.
	LoopFPS = 20
	// loopBytesPerSecond budgets a loop by its length (looppack lowers quality
	// to fit): 8s is 11 MB, 10s 14 MB, so a full set of eight stays near 100 MB.
	loopBytesPerSecond = 1400 << 10
	// headCropSize is the square head-crop PNG used for small avatars.
	headCropSize = 256
	// portraitSide bounds the portrait sent as the first and last frame.
	portraitSide = 1280
	// maxPortraitSourceSide bounds a source portrait's decoded size, so a small
	// but highly compressed file can't make the server allocate gigabytes.
	maxPortraitSourceSide = 8192
	// jobTimeout bounds one state's generation and packing.
	jobTimeout = 12 * time.Minute
	// DefaultParallel is how many states generate at once: enough to finish a
	// set in a couple of minutes without tripping provider rate limits.
	DefaultParallel  = 2
	progressThrottle = 500 * time.Millisecond
)

// Source is the portrait every loop starts and ends on.
type Source struct {
	Data []byte
}

// StartInput asks for new loops for some (or, empty, all) states.
type StartInput struct {
	Owner     personas.Owner
	PersonaID uuid.UUID
	States    []State
	// Tweak, when set, edits each state's previous clip conversationally
	// instead of generating it afresh (Gemini Omni previous_interaction_id).
	Tweak  string
	Source Source
}

// PackFunc mattes and packs a clip; looppack.Pack in production.
type PackFunc func(ctx context.Context, mp4 []byte, opts looppack.Options) (*looppack.Result, error)

// ResolveFunc picks the workspace's video provider.
type ResolveFunc func(ctx context.Context, ws uuid.UUID) (media.VideoGenerator, media.Descriptor, error)

// Runner runs state-loop generation in the background, one goroutine per
// request with a bounded number of states in flight, and tracks attempts so
// a clear or shutdown can cancel them.
type Runner struct {
	Pool     *pgxpool.Pool
	Blobs    *blob.Store
	Bucket   string
	Resolve  ResolveFunc
	Pack     PackFunc
	Log      *slog.Logger
	Parallel int

	mu     sync.Mutex
	closed bool
	active map[uuid.UUID]context.CancelFunc // by job id
	wg     sync.WaitGroup
}

// Close cancels every attempt in flight and waits for them to exit.
func (r *Runner) Close() {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.closed = true
	cancels := make([]context.CancelFunc, 0, len(r.active))
	for _, c := range r.active {
		cancels = append(cancels, c)
	}
	r.mu.Unlock()
	for _, c := range cancels {
		c()
	}
	r.wg.Wait()
}

// Active reports whether the attempt is still running in this process. A
// queued or running row whose attempt isn't active was cut off by a restart.
func (r *Runner) Active(job uuid.UUID) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	_, ok := r.active[job]
	return ok
}

// Cancel stops attempts by job id; unknown ids are ignored.
func (r *Runner) Cancel(jobs ...uuid.UUID) {
	r.mu.Lock()
	var cancels []context.CancelFunc
	for _, j := range jobs {
		if c, ok := r.active[j]; ok {
			cancels = append(cancels, c)
		}
	}
	r.mu.Unlock()
	for _, c := range cancels {
		c()
	}
}

type attempt struct {
	state   State
	job     uuid.UUID
	prompt  string
	seconds int
}

// Start validates the request, queues a new attempt for each state (keeping
// any loop the state already has) and generates them in the background. It
// returns the queued rows. A state already queued or running is a 409.
func (r *Runner) Start(ctx context.Context, in StartInput) ([]store.PersonaStateMedia, error) {
	if r == nil || r.Pool == nil || r.Resolve == nil {
		return nil, errors.New("statemedia: runner is not configured")
	}
	if r.Blobs == nil || r.Bucket == "" {
		return nil, apperr.Conflict("Vesper has no storage configured for persona loops.")
	}
	states, err := normStates(in.States)
	if err != nil {
		return nil, err
	}
	tweak := strings.TrimSpace(in.Tweak)
	if utf8.RuneCountInString(tweak) > MaxTweakRunes {
		return nil, apperr.Invalid("tweak", "at most %d characters", MaxTweakRunes)
	}
	portrait, err := normPortrait(in.Source.Data)
	if err != nil {
		return nil, err
	}
	gen, desc, err := r.Resolve(ctx, in.Owner.WorkspaceID)
	if err != nil {
		var pe *media.ProviderError
		if errors.As(err, &pe) {
			return nil, apperr.Conflict("%s", pe.Message)
		}
		return nil, err
	}

	// Each state's attempt is registered before its row is written, so a list
	// that runs meanwhile never mistakes the fresh row for one a restart cut off.
	base := context.WithoutCancel(ctx)
	attempts := make([]attempt, len(states))
	ctxs := make([]context.Context, len(states))
	cancels := make([]context.CancelFunc, len(states))
	for i, s := range states {
		attempts[i] = attempt{state: s, job: uuid.Must(uuid.NewV7())}
		ctxs[i], cancels[i] = context.WithCancel(base)
	}
	cancelAll := func() {
		for _, c := range cancels {
			c()
		}
	}
	if !r.track(attempts, cancels) {
		cancelAll()
		return nil, apperr.Conflict("Vesper is shutting down.")
	}

	var queued []store.PersonaStateMedia
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		p, err := q.GetPersona(ctx, store.GetPersonaParams{ID: in.PersonaID, WorkspaceID: in.Owner.WorkspaceID, UserID: in.Owner.UserID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.ErrNotFound
			}
			return err
		}
		seconds := int(p.LoopSeconds)
		if seconds < 3 || seconds > 10 {
			seconds = DefaultLoopSeconds
		}
		if err := q.LockPersonaStateMediaOwner(ctx, in.PersonaID); err != nil {
			return err
		}
		cur, err := q.LockPersonaStateMedia(ctx, in.PersonaID)
		if err != nil {
			return err
		}
		byState := map[State]store.PersonaStateMedia{}
		for _, row := range cur {
			byState[State(row.State)] = row
		}
		for _, s := range states {
			if row, ok := byState[s]; ok && (row.Status == "queued" || row.Status == "running") && r.Active(row.JobID) {
				return apperr.Conflict("The %s loop is already being generated.", label(s))
			}
		}
		for i, s := range states {
			a := &attempts[i]
			a.seconds, a.prompt = seconds, Prompt(s, seconds)
			if tweak != "" {
				row, ok := byState[s]
				if !ok || row.InteractionID == nil || *row.InteractionID == "" {
					return apperr.Invalid("tweak", "the %s loop has no earlier clip to edit; generate it first", label(s))
				}
				a.prompt = TweakPrompt(s, seconds, tweak)
			}
			row, err := q.QueuePersonaStateMedia(ctx, store.QueuePersonaStateMediaParams{
				PersonaID: in.PersonaID, State: string(s), JobID: a.job,
				StageNote: "Queued for " + desc.Label + "…", Prompt: a.prompt, Tweak: tweak, ProviderID: desc.ID,
			})
			if err != nil {
				return err
			}
			queued = append(queued, row)
		}
		return nil
	})
	if err != nil {
		r.untrack(attempts)
		cancelAll()
		return nil, err
	}
	r.wg.Go(func() {
		defer r.untrack(attempts)
		defer cancelAll()
		r.run(ctxs, in.PersonaID, gen, portrait, attempts)
	})
	return queued, nil
}

func (r *Runner) track(attempts []attempt, cancels []context.CancelFunc) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return false
	}
	if r.active == nil {
		r.active = map[uuid.UUID]context.CancelFunc{}
	}
	for i, a := range attempts {
		r.active[a.job] = cancels[i]
	}
	return true
}

func (r *Runner) untrack(attempts []attempt) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, a := range attempts {
		delete(r.active, a.job)
	}
}

// run generates the attempts with at most Parallel in flight. Each state has
// its own context, so it succeeds, fails or is cancelled (a cleared state) on
// its own.
func (r *Runner) run(ctxs []context.Context, persona uuid.UUID, gen media.VideoGenerator, portrait []byte, attempts []attempt) {
	n := r.Parallel
	if n <= 0 {
		n = DefaultParallel
	}
	sem := make(chan struct{}, n)
	var wg sync.WaitGroup
	for i, a := range attempts {
		ctx := ctxs[i]
		wg.Go(func() {
			select {
			case sem <- struct{}{}:
			case <-ctx.Done():
				r.fail(context.WithoutCancel(ctx), persona, a, ctx.Err())
				return
			}
			defer func() { <-sem }()
			r.one(ctx, persona, gen, portrait, a)
		})
	}
	wg.Wait()
}

func (r *Runner) one(parent context.Context, persona uuid.UUID, gen media.VideoGenerator, portrait []byte, a attempt) {
	ctx, cancel := context.WithTimeout(parent, jobTimeout)
	defer cancel()
	q := store.New(r.Pool)
	bg := context.WithoutCancel(ctx)

	var last time.Time
	progress := func(pct int, note string) {
		if time.Since(last) < progressThrottle && pct < 100 {
			return
		}
		last = time.Now()
		pct = max(0, min(99, pct))
		if err := q.ProgressPersonaStateMedia(bg, store.ProgressPersonaStateMediaParams{
			PersonaID: persona, State: string(a.state), JobID: a.job, Percent: int32(pct), StageNote: clip(note, 300),
		}); err != nil {
			r.logWarn("state loop progress", "persona", persona, "state", a.state, "err", err)
		}
	}
	progress(1, "Generating the "+label(a.state)+" clip…")

	// The portrait is both bookends, so the clip starts and ends on the same
	// frame and loops; a follow-up edit restates them to stay pinned to it.
	frame := &media.VideoFrame{Data: portrait, ContentType: "image/jpeg"}
	req := media.VideoRequest{
		Prompt:      a.prompt,
		FirstFrame:  frame,
		LastFrame:   frame,
		AspectRatio: AspectRatio,
		DurationSec: a.seconds,
	}
	clipOut, err := gen.GenerateVideo(ctx, req, func(p media.VideoProgress) {
		// The provider's 0-100 is the first 70% of the job; matting is the rest.
		progress(p.Percent*70/100, firstNonEmpty(p.Note, "Generating the "+label(a.state)+" clip…"))
	})
	if err != nil {
		r.fail(bg, persona, a, err)
		return
	}
	progress(72, "Cutting out the background…")
	pack := r.Pack
	if pack == nil {
		pack = looppack.Pack
	}
	res, err := pack(ctx, clipOut.Data, looppack.Options{
		TargetWidth:    LoopWidth,
		TargetHeight:   LoopHeight,
		FPS:            LoopFPS,
		ChromaColor:    ChromaHex,
		FeatherBottom:  0.08,
		Quality:        88,
		MaxOutputBytes: a.seconds * loopBytesPerSecond,
		HeadCropSize:   headCropSize,
	})
	if err != nil {
		r.fail(bg, persona, a, fmt.Errorf("packing the loop: %w", err))
		return
	}
	if len(res.WebP) == 0 {
		r.fail(bg, persona, a, errors.New("packing the loop produced no frames"))
		return
	}
	progress(94, "Saving…")

	loopKey := blobKey(persona, a.state, "loop")
	if err := r.Blobs.Put(bg, r.Bucket, loopKey, bytes.NewReader(res.WebP), int64(len(res.WebP)), "image/webp"); err != nil {
		r.fail(bg, persona, a, err)
		return
	}
	var headKey *string
	if len(res.HeadCropPNG) > 0 {
		k := blobKey(persona, a.state, "head")
		if err := r.Blobs.Put(bg, r.Bucket, k, bytes.NewReader(res.HeadCropPNG), int64(len(res.HeadCropPNG)), "image/png"); err != nil {
			r.deleteBlobs(bg, &loopKey)
			r.fail(bg, persona, a, err)
			return
		}
		headKey = &k
	}

	var replaced []*string
	stored := false
	err = pgx.BeginFunc(bg, r.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		cur, err := tq.LockPersonaStateMedia(bg, persona)
		if err != nil {
			return err
		}
		var prev *store.PersonaStateMedia
		for i := range cur {
			if cur[i].State == string(a.state) {
				prev = &cur[i]
			}
		}
		ct := "image/webp"
		size := int64(len(res.WebP))
		interaction := nilIfEmpty(clipOut.InteractionID)
		_, err = tq.FinishPersonaStateMedia(bg, store.FinishPersonaStateMediaParams{
			PersonaID: persona, State: string(a.state), JobID: a.job,
			Model: clipOut.Model, InteractionID: interaction, Backend: res.Backend,
			BlobKey: &loopKey, ContentType: &ct, HeadKey: headKey,
			Width: i32(res.Width), Height: i32(res.Height), Frames: i32(res.Frames), DurationMs: i32(res.DurationMS),
			SizeBytes: &size,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // cleared or superseded meanwhile
		}
		if err != nil {
			return err
		}
		stored = true
		if prev != nil {
			replaced = []*string{prev.BlobKey, prev.HeadKey}
		}
		return nil
	})
	if err != nil || !stored {
		r.deleteBlobs(bg, &loopKey, headKey)
		if err != nil {
			r.fail(bg, persona, a, err)
		}
		return
	}
	r.deleteBlobs(bg, replaced...)
}

// fail records a failed attempt; the state keeps whatever loop it had.
func (r *Runner) fail(ctx context.Context, persona uuid.UUID, a attempt, err error) {
	kind, msg := media.ClassifyError(err)
	switch {
	case errors.Is(err, context.Canceled):
		kind, msg = "stopped", "Stopped."
	case errors.Is(err, context.DeadlineExceeded):
		kind, msg = "timeout", "Timed out generating the "+label(a.state)+" loop."
	case errors.Is(err, looppack.ErrFFmpegNotFound):
		kind, msg = "unavailable", "ffmpeg isn't installed on the server, so the loop couldn't be matted."
	}
	k := string(kind)
	m := clip(msg, 2000)
	if ferr := store.New(r.Pool).FailPersonaStateMedia(ctx, store.FailPersonaStateMediaParams{
		PersonaID: persona, State: string(a.state), JobID: a.job, Error: &m, ErrorKind: &k,
	}); ferr != nil {
		r.logWarn("state loop failure", "persona", persona, "state", a.state, "err", ferr)
	}
	if !errors.Is(err, context.Canceled) {
		r.logWarn("state loop failed", "persona", persona, "state", a.state, "err", err)
	}
}

// RecoverInterrupted fails queued or running rows whose attempt no longer
// runs in this process (a restart cut it off), so they don't spin forever.
func (r *Runner) RecoverInterrupted(ctx context.Context, rows []store.PersonaStateMedia) ([]store.PersonaStateMedia, error) {
	q := store.New(r.Pool)
	out := make([]store.PersonaStateMedia, len(rows))
	for i, row := range rows {
		out[i] = row
		if (row.Status != "queued" && row.Status != "running") || r.Active(row.JobID) {
			continue
		}
		msg, kind := "Interrupted when Vesper restarted. Generate it again.", "stopped"
		if err := q.FailPersonaStateMedia(ctx, store.FailPersonaStateMediaParams{
			PersonaID: row.PersonaID, State: row.State, JobID: row.JobID, Error: &msg, ErrorKind: &kind,
		}); err != nil {
			return nil, err
		}
		out[i].Status, out[i].Percent, out[i].StageNote, out[i].Error, out[i].ErrorKind = "failed", 0, "", &msg, &kind
	}
	return out, nil
}

// Clear removes loops (one state, or all with a nil state), cancelling their
// attempts and deleting their blobs once the rows are gone.
func (r *Runner) Clear(ctx context.Context, o personas.Owner, persona uuid.UUID, state *State) error {
	var st *string
	if state != nil {
		if !Valid(*state) {
			return apperr.Invalid("state", "unknown state %q", *state)
		}
		s := string(*state)
		st = &s
	}
	var gone []store.PersonaStateMedia
	err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if _, err := q.GetPersona(ctx, store.GetPersonaParams{ID: persona, WorkspaceID: o.WorkspaceID, UserID: o.UserID}); err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				return apperr.ErrNotFound
			}
			return err
		}
		if err := q.LockPersonaStateMediaOwner(ctx, persona); err != nil {
			return err
		}
		var err error
		gone, err = q.DeletePersonaStateMedia(ctx, store.DeletePersonaStateMediaParams{PersonaID: persona, State: st})
		return err
	})
	if err != nil {
		return err
	}
	r.Forget(ctx, gone)
	return nil
}

// Forget cancels the attempts of rows already deleted (a cleared state or a
// deleted persona) and deletes their blobs.
func (r *Runner) Forget(ctx context.Context, rows []store.PersonaStateMedia) {
	jobs := make([]uuid.UUID, 0, len(rows))
	for _, row := range rows {
		jobs = append(jobs, row.JobID)
		r.deleteBlobs(context.WithoutCancel(ctx), row.BlobKey, row.HeadKey)
	}
	r.Cancel(jobs...)
}

func (r *Runner) deleteBlobs(ctx context.Context, keys ...*string) {
	if r.Blobs == nil {
		return
	}
	for _, k := range keys {
		if k == nil || *k == "" {
			continue
		}
		// Nothing points at the key any more; a failure only costs storage.
		if err := r.Blobs.Delete(ctx, r.Bucket, *k); err != nil {
			r.logWarn("delete state loop blob", "key", *k, "err", err)
		}
	}
}

func (r *Runner) logWarn(msg string, args ...any) {
	if r.Log != nil {
		r.Log.Warn(msg, args...)
	}
}

// blobKey is where a loop or head crop lives. Every attempt gets a new key,
// so a replaced loop is never served from a stale cache.
func blobKey(persona uuid.UUID, s State, kind string) string {
	return "persona-loops/" + persona.String() + "/" + string(s) + "/" + kind + "-" + uuid.NewString()
}

func normStates(in []State) ([]State, error) {
	if len(in) == 0 {
		return append([]State(nil), States...), nil
	}
	seen := map[State]bool{}
	var out []State
	for _, s := range in {
		if !Valid(s) {
			return nil, apperr.Invalid("states", "unknown state %q", s)
		}
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out, nil
}

// normPortrait decodes the portrait and re-encodes it as a JPEG no larger
// than portraitSide, dropping metadata and any trailing data the source had,
// and keeping the request to the provider small.
func normPortrait(src []byte) ([]byte, error) {
	if len(src) == 0 {
		return nil, apperr.Conflict("The persona has no portrait to animate. Give it a picture first.")
	}
	if len(src) > personas.MaxAvatarSourceBytes {
		return nil, apperr.Invalid("source", "the portrait must be under %d MB", personas.MaxAvatarSourceBytes>>20)
	}
	cfg, _, err := image.DecodeConfig(bytes.NewReader(src))
	if err != nil {
		return nil, apperr.Invalid("source", "the portrait isn't an image Vesper can read")
	}
	if cfg.Width < 64 || cfg.Height < 64 || cfg.Width > maxPortraitSourceSide || cfg.Height > maxPortraitSourceSide {
		return nil, apperr.Invalid("source", "the portrait must be between 64 and %d pixels a side", maxPortraitSourceSide)
	}
	img, _, err := image.Decode(bytes.NewReader(src))
	if err != nil {
		return nil, apperr.Invalid("source", "the portrait isn't an image Vesper can read")
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	if s := max(w, h); s > portraitSide {
		w, h = max(1, w*portraitSide/s), max(1, h*portraitSide/s)
	}
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	// Flatten any transparency onto the chroma backdrop the prompts ask for.
	draw.Draw(dst, dst.Bounds(), image.NewUniform(chromaRGBA()), image.Point{}, draw.Src)
	draw.CatmullRom.Scale(dst, dst.Bounds(), img, b, draw.Over, nil)
	var out bytes.Buffer
	if err := jpeg.Encode(&out, dst, &jpeg.Options{Quality: 92}); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

// chromaRGBA is ChromaHex as a colour.
func chromaRGBA() color.RGBA {
	var r, g, b uint8
	_, _ = fmt.Sscanf(ChromaHex, "#%02x%02x%02x", &r, &g, &b)
	return color.RGBA{R: r, G: g, B: b, A: 0xff}
}

func label(s State) string {
	if s == StateNeedsYou {
		return "needs-you"
	}
	return string(s)
}

func clip(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n-1]) + "…"
}

func firstNonEmpty(a, b string) string {
	if strings.TrimSpace(a) != "" {
		return a
	}
	return b
}

func nilIfEmpty(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func i32(v int) *int32 {
	x := int32(v)
	return &x
}

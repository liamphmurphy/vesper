package drivebackup

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"runtime/debug"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	// DefaultLeaseTTL is how long a run's lease lasts without renewal: a
	// process that dies mid-backup holds the workspace this long at most.
	DefaultLeaseTTL = 2 * time.Minute
	// maxErrorLen bounds last_error, which Attention shows.
	maxErrorLen = 1000
)

// Statuses of a finished run (drive_backups.last_status).
const (
	StatusSucceeded = "succeeded"
	StatusFailed    = "failed"
)

// Runner runs backups, by hand (Start) or on schedule (RunDue). Both take the
// workspace's lease first, so two never overlap, whichever process runs them.
type Runner struct {
	Pool     *pgxpool.Pool
	Secrets  *usersecrets.Service
	Exporter Exporter
	// Uploader configures the uploader for a run; nil uses Drive itself.
	// Tests point it at a fake Drive.
	Uploader func(u *Uploader)
	// Holder names this process in leases; each run adds its own ID.
	Holder string
	// LeaseTTL defaults to DefaultLeaseTTL; the lease is renewed every third of it.
	LeaseTTL time.Duration
	Now      func() time.Time
	Log      *slog.Logger

	wg       sync.WaitGroup
	baseOnce sync.Once
	base     context.Context
	stop     context.CancelFunc
}

// ctx is the context manual runs derive from: Shutdown cancels it, so a run
// started by a request still records why it stopped when Vesper exits.
func (r *Runner) ctx() context.Context {
	r.baseOnce.Do(func() { r.base, r.stop = context.WithCancel(context.Background()) })
	return r.base
}

func (r *Runner) now() time.Time {
	if r.Now != nil {
		return r.Now()
	}
	return time.Now()
}

func (r *Runner) ttl() time.Duration {
	if r.LeaseTTL > 0 {
		return r.LeaseTTL
	}
	return DefaultLeaseTTL
}

func (r *Runner) log() *slog.Logger {
	if r.Log != nil {
		return r.Log
	}
	return slog.Default()
}

func (r *Runner) holder() string {
	return r.Holder + "/" + uuid.NewString()
}

// Wait waits for runs Start began.
func (r *Runner) Wait() { r.wg.Wait() }

// Shutdown cancels the runs Start began and waits until each has recorded
// how it ended, or ctx ends.
func (r *Runner) Shutdown(ctx context.Context) error {
	r.ctx()
	r.stop()
	done := make(chan struct{})
	go func() { r.wg.Wait(); close(done) }()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

// ErrRunning means a backup of the workspace is already running.
var ErrRunning = apperr.Conflict("a backup is already running; wait for it to finish")

// Start begins a backup of the workspace now, in the background, whether or
// not the schedule is enabled. It returns once the lease is held: ErrRunning
// when another run holds it, or a conflict naming what to set up first.
// ctx only bounds taking the lease; the run outlives it until Shutdown.
func (r *Runner) Start(ctx context.Context, ws uuid.UUID) error {
	if r.ctx().Err() != nil {
		return apperr.Conflict("Vesper is shutting down; run the backup once it is back")
	}
	q := store.New(r.Pool)
	b, err := q.GetDriveBackup(ctx, ws)
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.Conflict("save the Google Drive backup settings first")
	}
	if err != nil {
		return err
	}
	if msg := incomplete(b); msg != "" {
		return apperr.Conflict("%s", msg)
	}
	holder := r.holder()
	if _, err := q.AcquireDriveBackupLock(ctx, store.AcquireDriveBackupLockParams{WorkspaceID: ws, Holder: holder, TtlSeconds: r.ttl().Seconds()}); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrRunning
		}
		return err
	}
	base := r.ctx()
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		r.execute(base, b, holder)
	}()
	return nil
}

// RunDue claims the backup that is most overdue, if any, moves its next run
// to the next day's time and runs it. The claim, the lease and the new
// next_run_at commit together, so a backup missed several times while Vesper
// was off runs once, and never while another run of it holds the lease. It
// reports whether it ran one; call it again until it doesn't.
func (r *Runner) RunDue(ctx context.Context) (bool, error) {
	holder := r.holder()
	var b store.DriveBackup
	err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		var err error
		if b, err = q.NextDueDriveBackup(ctx); err != nil {
			return err
		}
		// Due-ness is on the database's clock; never schedule the next run
		// at or before the one being claimed, or an app clock behind the
		// database's would leave the row due and run it twice.
		after := r.now()
		if b.NextRunAt != nil && b.NextRunAt.After(after) {
			after = *b.NextRunAt
		}
		next, err := NextRun(b.AtTime, b.Timezone, after)
		if err != nil {
			// Save validates the schedule, so only a hand-edited row lands
			// here; turn it off rather than claim it every tick.
			b.NextRunAt = nil
		} else {
			b.NextRunAt = &next
		}
		if err := q.AdvanceDriveBackup(ctx, store.AdvanceDriveBackupParams{WorkspaceID: b.WorkspaceID, NextRunAt: b.NextRunAt}); err != nil {
			return err
		}
		// Another process may have taken the lease since the query's snapshot.
		_, err = q.AcquireDriveBackupLock(ctx, store.AcquireDriveBackupLockParams{WorkspaceID: b.WorkspaceID, Holder: holder, TtlSeconds: r.ttl().Seconds()})
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	r.execute(ctx, b, holder)
	return true, nil
}

// incomplete says what a backup lacks before it can run, or "".
func incomplete(b store.DriveBackup) string {
	switch {
	case b.SecretID == nil:
		return "No Google Drive secret is selected. Choose one in Settings › Backup & move."
	case b.FolderID == "":
		return "No Google Drive folder is chosen. Choose one in Settings › Backup & move."
	}
	return ""
}

// execute runs one backup under holder's lease, records how it went and
// releases the lease. Losing the lease (another process took it after this
// one stalled) stops the upload.
func (r *Runner) execute(ctx context.Context, b store.DriveBackup, holder string) {
	q := store.New(r.Pool)
	ctx, cancel := context.WithCancelCause(ctx)
	defer cancel(nil)
	renewed := make(chan struct{})
	go func() {
		defer close(renewed)
		r.keepLease(ctx, cancel, b.WorkspaceID, holder)
	}()

	res, err := r.safeBackup(ctx, b)
	if cause := context.Cause(ctx); err != nil && cause != nil {
		// The upload saw a cancelled context; say why it was cancelled.
		err = cause
	}
	cancel(nil)
	<-renewed

	bg := context.WithoutCancel(ctx)
	if errors.Is(err, errLeaseLost) {
		// Another run holds the lease and records its own result; writing
		// ours could overwrite it.
		r.log().Warn("drive backup lost its lease", "workspace", b.WorkspaceID)
		return
	}
	status, msg := StatusSucceeded, ""
	if err != nil {
		status, msg = StatusFailed, r.explain(bg, b, err)
		r.log().Warn("drive backup failed", "workspace", b.WorkspaceID, "err", err)
	} else {
		r.log().Info("drive backup uploaded", "workspace", b.WorkspaceID, "file", res.Name, "bytes", res.Bytes, "pruned", len(res.Pruned))
	}
	if err := q.FinishDriveBackup(bg, store.FinishDriveBackupParams{WorkspaceID: b.WorkspaceID, LastStatus: status, LastError: msg}); err != nil {
		r.log().Error("record drive backup", "workspace", b.WorkspaceID, "err", err)
	}
	_ = q.NotifyDriveBackupFinished(bg)
	if err := q.ReleaseDriveBackupLock(bg, store.ReleaseDriveBackupLockParams{WorkspaceID: b.WorkspaceID, Holder: holder}); err != nil {
		r.log().Error("release drive backup lease", "workspace", b.WorkspaceID, "err", err)
	}
}

var errLeaseLost = errors.New("another process took over the backup")

// keepLease renews the lease every third of its TTL until ctx ends, and
// cancels the run if the lease is gone.
func (r *Runner) keepLease(ctx context.Context, cancel context.CancelCauseFunc, ws uuid.UUID, holder string) {
	q := store.New(r.Pool)
	t := time.NewTicker(r.ttl() / 3)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			n, err := q.ExtendDriveBackupLock(ctx, store.ExtendDriveBackupLockParams{WorkspaceID: ws, Holder: holder, TtlSeconds: r.ttl().Seconds()})
			if err != nil {
				if ctx.Err() == nil {
					r.log().Warn("renew drive backup lease", "workspace", ws, "err", err)
				}
				continue // the lease outlives a blip; the next renewal may work
			}
			if n == 0 {
				cancel(errLeaseLost)
				return
			}
		}
	}
}

// safeBackup is backup, with a panic turned into an error so that the run
// still records a failure and releases its lease.
func (r *Runner) safeBackup(ctx context.Context, b store.DriveBackup) (res Result, err error) {
	defer func() {
		if p := recover(); p != nil {
			r.log().Error("drive backup panicked", "workspace", b.WorkspaceID, "panic", p, "stack", string(debug.Stack()))
			res, err = Result{}, fmt.Errorf("internal error: %v", p)
		}
	}()
	return r.backup(ctx, b)
}

// backup checks the secret and uploads.
func (r *Runner) backup(ctx context.Context, b store.DriveBackup) (Result, error) {
	if msg := incomplete(b); msg != "" {
		return Result{}, errors.New(msg)
	}
	sec, err := store.New(r.Pool).UserSecretByID(ctx, *b.SecretID)
	if err != nil {
		return Result{}, err
	}
	if err := r.Secrets.RequireScope(sec, WriteScopes...); err != nil {
		return Result{}, err
	}
	u := &Uploader{Token: SecretToken(r.Secrets, sec), Now: r.Now}
	if r.Uploader != nil {
		r.Uploader(u)
	}
	return u.Upload(ctx, r.Exporter, b.FolderID, int(b.Retention))
}

// explain turns a failure into what the person reads in Attention. When the
// secret can no longer upload (its sign-in lapsed during the run, or it was
// deleted) that is the cause to fix, whatever the upload said.
func (r *Runner) explain(ctx context.Context, b store.DriveBackup, err error) string {
	switch {
	case errors.Is(err, context.Canceled):
		return "Vesper stopped before the backup finished. It runs again at the next scheduled time, or run it now from Settings › Backup & move."
	}
	msg := err.Error()
	if b.SecretID != nil {
		sec, serr := store.New(r.Pool).UserSecretByID(ctx, *b.SecretID)
		var ce *apperr.ConflictError
		switch {
		case errors.Is(serr, pgx.ErrNoRows):
			msg = "The Google Drive secret was deleted. Choose another in Settings › Backup & move."
		case serr == nil && errors.As(r.Secrets.RequireScope(sec, WriteScopes...), &ce):
			msg = ce.Msg
		}
	}
	if errors.Is(err, ErrPrune) {
		msg += ". The new backup is safe; older ones beyond the retention count are still in the folder."
	}
	if utf8.RuneCountInString(msg) > maxErrorLen {
		msg = string([]rune(msg)[:maxErrorLen-1]) + "…"
	}
	return msg
}

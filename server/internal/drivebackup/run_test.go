package drivebackup

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

// bytesExporter writes a fixed archive.
type bytesExporter string

func (e bytesExporter) Export(_ context.Context, w io.Writer) (*transfer.Manifest, error) {
	_, err := io.WriteString(w, string(e))
	return &transfer.Manifest{}, err
}

// newRunner is a Runner on the fixture's database that uploads to d.
func newRunner(f *fixture, pool *pgxpool.Pool, d *fakeDrive) *Runner {
	return &Runner{Pool: pool, Secrets: f.secrets, Exporter: bytesExporter("archive"), Holder: "test",
		Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Uploader: func(u *Uploader) {
			fake := d.uploader()
			u.HTTP, u.BaseURL, u.ChunkSize, u.Sleep, u.Now = fake.HTTP, fake.BaseURL, fake.ChunkSize, fake.Sleep, fake.Now
		}}
}

// dueBackup saves an enabled backup with secret whose next run is already due.
func (f *fixture) dueBackup(t *testing.T, sec store.UserSecret, retention int) store.DriveBackup {
	t.Helper()
	f.svc.Now = func() time.Time { return time.Now().Add(-48 * time.Hour) }
	b, err := f.svc.Save(f.ctx, f.ws, f.user, Config{Enabled: true, SecretID: &sec.ID, FolderID: "folder1", AtTime: "03:00", Timezone: "Europe/London", Retention: retention})
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func (f *fixture) inbox(t *testing.T) []store.ListInboxRow {
	t.Helper()
	rows, err := f.q.ListInbox(f.ctx, store.ListInboxParams{UserID: f.user, WorkspaceID: f.ws})
	if err != nil {
		t.Fatal(err)
	}
	var out []store.ListInboxRow
	for _, r := range rows {
		if r.Kind == "drive_backup" {
			out = append(out, r)
		}
	}
	return out
}

func TestRunDueUploadsOnceAndReschedules(t *testing.T) {
	f := newFixture(t)
	pool := f.pool
	d := newFakeDrive(t)
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	f.dueBackup(t, sec, 0)
	r := newRunner(f, pool, d)

	ran, err := r.RunDue(f.ctx)
	if err != nil || !ran {
		t.Fatalf("RunDue = %v, %v", ran, err)
	}
	if string(d.stored) != "archive" || d.meta["parents"] == nil {
		t.Fatalf("Drive got %q (meta %v)", d.stored, d.meta)
	}
	b, _ := f.q.GetDriveBackup(f.ctx, f.ws)
	if b.LastStatus != StatusSucceeded || b.LastError != "" || b.LastRunAt == nil {
		t.Fatalf("after the run: %+v", b)
	}
	// Two days of missed runs ran once; the next is tomorrow's 03:00 London time.
	london, _ := time.LoadLocation("Europe/London")
	if b.NextRunAt == nil || !b.NextRunAt.After(time.Now()) || b.NextRunAt.In(london).Format("15:04") != "03:00" {
		t.Fatalf("next run = %v", b.NextRunAt)
	}
	if ran, err := r.RunDue(f.ctx); ran || err != nil {
		t.Fatalf("second RunDue = %v, %v: nothing is due", ran, err)
	}
	if _, err := f.q.GetDriveBackupLock(f.ctx, f.ws); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("lease kept after the run: %v", err)
	}
	if got := f.inbox(t); len(got) != 0 {
		t.Fatalf("a successful run in Attention: %+v", got)
	}
}

func TestRunDueWaitsForARunningBackup(t *testing.T) {
	f := newFixture(t)
	pool := f.pool
	d := newFakeDrive(t)
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	due := f.dueBackup(t, sec, 0)
	if _, err := f.q.AcquireDriveBackupLock(f.ctx, store.AcquireDriveBackupLockParams{WorkspaceID: f.ws, Holder: "manual", TtlSeconds: 3600}); err != nil {
		t.Fatal(err)
	}
	r := newRunner(f, pool, d)
	if ran, err := r.RunDue(f.ctx); ran || err != nil {
		t.Fatalf("RunDue during another run = %v, %v", ran, err)
	}
	// The due run is kept for when the other one finishes.
	if b, _ := f.q.GetDriveBackup(f.ctx, f.ws); !b.NextRunAt.Equal(*due.NextRunAt) {
		t.Fatalf("next run moved from %v to %v", due.NextRunAt, b.NextRunAt)
	}
	if len(d.puts) != 0 {
		t.Fatal("uploaded while another run held the lease")
	}
	// A manual run is refused too.
	if err := r.Start(f.ctx, f.ws); !errors.Is(err, ErrRunning) {
		t.Fatalf("Start during another run: %v", err)
	}
	_ = f.q.ReleaseDriveBackupLock(f.ctx, store.ReleaseDriveBackupLockParams{WorkspaceID: f.ws, Holder: "manual"})
	if ran, err := r.RunDue(f.ctx); !ran || err != nil {
		t.Fatalf("RunDue after the other run = %v, %v", ran, err)
	}
}

func TestStartRunsByHandEvenWhenDisabled(t *testing.T) {
	f := newFixture(t)
	pool := f.pool
	d := newFakeDrive(t)
	r := newRunner(f, pool, d)
	var ce *apperr.ConflictError
	if err := r.Start(f.ctx, f.ws); !errors.As(err, &ce) || !strings.Contains(err.Error(), "save") {
		t.Fatalf("Start with no settings: %v", err)
	}
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	if _, err := f.svc.Save(f.ctx, f.ws, f.user, Config{SecretID: &sec.ID, AtTime: "03:00", Timezone: "UTC"}); err != nil {
		t.Fatal(err)
	}
	if err := r.Start(f.ctx, f.ws); !errors.As(err, &ce) || !strings.Contains(err.Error(), "folder") {
		t.Fatalf("Start with no folder: %v", err)
	}
	b, _ := f.q.GetDriveBackup(f.ctx, f.ws)
	if _, err := f.svc.Save(f.ctx, f.ws, f.user, Config{SecretID: &sec.ID, FolderID: "folder1", AtTime: "03:00", Timezone: "UTC", Revision: b.Revision}); err != nil {
		t.Fatal(err)
	}
	if err := r.Start(f.ctx, f.ws); err != nil {
		t.Fatal(err)
	}
	r.Wait()
	b, _ = f.q.GetDriveBackup(f.ctx, f.ws)
	if b.LastStatus != StatusSucceeded || string(d.stored) != "archive" || b.NextRunAt != nil {
		t.Fatalf("after a manual run: %+v, Drive has %q", b, d.stored)
	}
}

func TestFailedRunIsRecordedAndNeedsYou(t *testing.T) {
	f := newFixture(t)
	pool := f.pool
	d := newFakeDrive(t)
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	f.dueBackup(t, sec, 0)
	r := newRunner(f, pool, d)

	// Drive refuses: the reason is recorded and shown in Attention.
	d.startStatus = 403
	if ran, err := r.RunDue(f.ctx); !ran || err != nil {
		t.Fatalf("RunDue = %v, %v", ran, err)
	}
	b, _ := f.q.GetDriveBackup(f.ctx, f.ws)
	if b.LastStatus != StatusFailed || !strings.Contains(b.LastError, "Insufficient Permission") {
		t.Fatalf("after Drive refused: %+v", b)
	}
	items := f.inbox(t)
	if len(items) != 1 || items[0].Summary != "Failed: "+b.LastError || items[0].Href != "/settings#backup" || items[0].Resolved {
		t.Fatalf("Attention = %+v", items)
	}
	first := items[0].ID

	// The grant lapses: the person is told to sign in again, as a new item.
	d.startStatus = 0
	_ = f.q.SetUserSecretOAuthError(f.ctx, store.SetUserSecretOAuthErrorParams{ID: sec.ID, OauthError: "invalid_grant"})
	if err := r.Start(f.ctx, f.ws); err != nil {
		t.Fatal(err)
	}
	r.Wait()
	b, _ = f.q.GetDriveBackup(f.ctx, f.ws)
	if b.LastStatus != StatusFailed || !strings.Contains(b.LastError, "needs signing in again (invalid_grant)") || !strings.Contains(b.LastError, "Customization › Secrets") {
		t.Fatalf("after the grant lapsed: %+v", b)
	}
	if len(d.puts) != 0 {
		t.Fatal("uploaded with a lapsed grant")
	}
	items = f.inbox(t)
	if len(items) != 1 || items[0].ID == first || !strings.Contains(items[0].Summary, "signing in again") {
		t.Fatalf("Attention after the lapse = %+v", items)
	}
	// Another person doesn't see it.
	other, err := f.q.ListInbox(f.ctx, store.ListInboxParams{UserID: uuid.New(), WorkspaceID: f.ws})
	if err != nil {
		t.Fatal(err)
	}
	for _, r := range other {
		if r.Kind == "drive_backup" {
			t.Fatal("another person sees the failed backup")
		}
	}

	// Signing in again and a run that works clear it.
	sec = f.oauthSecret(t, "Drive again", true, ScopeFile)
	b, _ = f.q.GetDriveBackup(f.ctx, f.ws)
	if _, err := f.svc.Save(f.ctx, f.ws, f.user, Config{Enabled: true, SecretID: &sec.ID, FolderID: "folder1", AtTime: "03:00", Timezone: "Europe/London", Revision: b.Revision}); err != nil {
		t.Fatal(err)
	}
	if err := r.Start(f.ctx, f.ws); err != nil {
		t.Fatal(err)
	}
	r.Wait()
	if items := f.inbox(t); len(items) != 0 {
		t.Fatalf("Attention after a good run = %+v", items)
	}
}

func TestDeletedSecretIsExplained(t *testing.T) {
	f := newFixture(t)
	pool := f.pool
	d := newFakeDrive(t)
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	f.dueBackup(t, sec, 0)
	if _, err := f.q.DeleteUserSecret(f.ctx, store.DeleteUserSecretParams{ID: sec.ID, WorkspaceID: f.ws, UserID: f.user}); err != nil {
		t.Fatal(err)
	}
	r := newRunner(f, pool, d)
	if ran, err := r.RunDue(f.ctx); !ran || err != nil {
		t.Fatalf("RunDue = %v, %v", ran, err)
	}
	b, _ := f.q.GetDriveBackup(f.ctx, f.ws)
	if b.LastStatus != StatusFailed || !strings.Contains(b.LastError, "No Google Drive secret is selected") {
		t.Fatalf("after the secret was deleted: %+v", b)
	}
}

func TestLostLeaseStopsTheRun(t *testing.T) {
	f := newFixture(t)
	pool := f.pool
	d := newFakeDrive(t)
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	f.dueBackup(t, sec, 0)
	r := newRunner(f, pool, d)
	r.LeaseTTL = 300 * time.Millisecond
	// Another process takes the lease over while the upload hangs.
	ended := make(chan struct{})
	d.intercept = func(_ http.ResponseWriter, req *http.Request) bool {
		if req.Method != http.MethodPut {
			return false
		}
		_, _ = pool.Exec(context.Background(), `UPDATE drive_backup_locks SET holder = 'thief'`)
		_, _ = io.Copy(io.Discard, req.Body)
		select {
		case <-req.Context().Done():
		case <-ended:
		}
		return true
	}
	ran, err := r.RunDue(f.ctx)
	close(ended)
	if !ran || err != nil {
		t.Fatalf("RunDue = %v, %v", ran, err)
	}
	b, _ := f.q.GetDriveBackup(f.ctx, f.ws)
	if b.LastStatus != StatusFailed || !strings.Contains(b.LastError, "another run took over") {
		t.Fatalf("after losing the lease: %+v", b)
	}
	// The other holder's lease is left alone.
	if l, err := f.q.GetDriveBackupLock(f.ctx, f.ws); err != nil || l.Holder != "thief" {
		t.Fatalf("lease = %+v, %v", l, err)
	}
}

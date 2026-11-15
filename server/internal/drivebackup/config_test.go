package drivebackup

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

func field(err error) string {
	var ve *apperr.ValidationError
	if errors.As(err, &ve) {
		return ve.Field
	}
	var ce *apperr.ConflictError
	if errors.As(err, &ce) {
		return ce.Field
	}
	return ""
}

func TestNormalize(t *testing.T) {
	id := uuid.New()
	ok := Config{Enabled: true, SecretID: &id, FolderID: " 1AbC_d-9 ", AtTime: "03:00", Timezone: "Europe/London", Retention: 7}
	got, err := ok.Normalize()
	if err != nil || got.FolderID != "1AbC_d-9" {
		t.Fatalf("Normalize = %+v, %v", got, err)
	}
	if _, err := (Config{AtTime: "23:59", Timezone: "UTC"}).Normalize(); err != nil {
		t.Fatalf("a disabled, incomplete config: %v", err)
	}
	for name, tc := range map[string]struct {
		mut   func(*Config)
		field string
	}{
		"hour out of range":   {func(c *Config) { c.AtTime = "24:00" }, "at_time"},
		"seconds":             {func(c *Config) { c.AtTime = "03:00:00" }, "at_time"},
		"twelve-hour":         {func(c *Config) { c.AtTime = "3:00 AM" }, "at_time"},
		"single-digit hour":   {func(c *Config) { c.AtTime = "3:00" }, "at_time"},
		"empty time":          {func(c *Config) { c.AtTime = "" }, "at_time"},
		"unknown zone":        {func(c *Config) { c.Timezone = "Mars/Olympus" }, "timezone"},
		"server's local zone": {func(c *Config) { c.Timezone = "Local" }, "timezone"},
		"no zone":             {func(c *Config) { c.Timezone = "" }, "timezone"},
		"negative retention":  {func(c *Config) { c.Retention = -1 }, "retention"},
		"huge retention":      {func(c *Config) { c.Retention = 1001 }, "retention"},
		"query in folder id":  {func(c *Config) { c.FolderID = "x' or '1'='1" }, "folder_id"},
		"enabled, no secret":  {func(c *Config) { c.SecretID = nil }, "secret_id"},
		"enabled, no folder":  {func(c *Config) { c.FolderID = "" }, "folder_id"},
		"long folder name":    {func(c *Config) { c.FolderName = strings.Repeat("x", 501) }, "folder_name"},
	} {
		c := ok
		tc.mut(&c)
		if _, err := c.Normalize(); field(err) != tc.field {
			t.Errorf("%s: err = %v, want field %s", name, err, tc.field)
		}
	}
	c := ok
	c.Retention = 0 // keeps everything
	if _, err := c.Normalize(); err != nil {
		t.Fatalf("retention 0: %v", err)
	}
}

func TestNextRun(t *testing.T) {
	ny := "America/New_York"
	loc, _ := time.LoadLocation(ny)
	for _, tc := range []struct {
		after time.Time
		want  time.Time
	}{
		{time.Date(2026, 11, 15, 2, 0, 0, 0, loc), time.Date(2026, 11, 15, 3, 0, 0, 0, loc)},
		{time.Date(2026, 11, 15, 3, 0, 0, 0, loc), time.Date(2026, 11, 16, 3, 0, 0, 0, loc)}, // strictly after
		{time.Date(2026, 11, 15, 22, 0, 0, 0, time.UTC), time.Date(2026, 11, 16, 3, 0, 0, 0, loc)},
		// Across the spring change, still 03:00 local.
		{time.Date(2026, 3, 7, 12, 0, 0, 0, loc), time.Date(2026, 3, 8, 3, 0, 0, 0, loc)},
	} {
		got, err := NextRun("03:00", ny, tc.after)
		if err != nil || !got.Equal(tc.want) {
			t.Errorf("NextRun after %v = %v, %v; want %v", tc.after, got, err, tc.want)
		}
	}
}

type fixture struct {
	ctx      context.Context
	q        *store.Queries
	svc      *Service
	ws, user uuid.UUID
	secrets  *usersecrets.Service
	scope    string // what the token endpoint says it granted
}

func (f *fixture) RoundTrip(r *http.Request) (*http.Response, error) {
	body := `{"access_token":"a","refresh_token":"r","expires_in":3600,"scope":"` + f.scope + `"}`
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{ctx: ctx, q: q, ws: me.WorkspaceID, user: me.ID, scope: ScopeFile}
	f.secrets = &usersecrets.Service{Q: q, Box: box, HTTP: f}
	f.svc = &Service{Q: q, Secrets: f.secrets, Now: func() time.Time { return time.Date(2026, 11, 15, 9, 0, 0, 0, time.UTC) }}
	return f
}

// oauthSecret makes an OAuth secret asking for scopes, signed in when signIn.
func (f *fixture) oauthSecret(t *testing.T, name string, signIn bool, scopes ...string) store.UserSecret {
	t.Helper()
	sec, err := f.secrets.Create(f.ctx, f.ws, f.user, usersecrets.Input{Name: name, AllowedHosts: []string{"www.googleapis.com"}, ReadPolicy: usersecrets.PolicyAllow,
		OAuth: &usersecrets.OAuthInput{AuthorizeURL: "https://accounts.google.com/o/oauth2/auth", TokenURL: "https://oauth2.googleapis.com/token",
			ClientID: "client", ClientSecret: "shh", Scopes: scopes}})
	if err != nil {
		t.Fatal(err)
	}
	if !signIn {
		return sec
	}
	link, err := f.secrets.BeginOAuth(f.ctx, sec, "https://vesper.example.com/cb")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(link)
	if sec, err = f.secrets.FinishOAuth(f.ctx, u.Query().Get("state"), "code"); err != nil {
		t.Fatal(err)
	}
	return sec
}

func TestSaveChecksTheSecret(t *testing.T) {
	f := newFixture(t)
	good := f.oauthSecret(t, "Drive", true, ScopeFile)
	cfg := Config{Enabled: true, SecretID: &good.ID, FolderID: "folder1", FolderName: "Backups", AtTime: "03:00", Timezone: "America/New_York", Retention: 5}

	f.scope = ScopeFull
	full := f.oauthSecret(t, "Drive full", true, ScopeFull)
	f.scope = "https://www.googleapis.com/auth/drive.readonly"
	readOnly := f.oauthSecret(t, "Drive read", true, ScopeFile) // asked for drive.file, granted only read
	notSignedIn := f.oauthSecret(t, "Drive later", false, ScopeFile)
	lapsed := f.oauthSecret(t, "Drive lapsed", true, ScopeFull)
	_ = f.q.SetUserSecretOAuthError(f.ctx, store.SetUserSecretOAuthErrorParams{ID: lapsed.ID, OauthError: "invalid_grant"})
	static, err := f.secrets.Create(f.ctx, f.ws, f.user, usersecrets.Input{Name: "Static", Value: "tok", Placement: usersecrets.PlacementBearer,
		AllowedHosts: []string{"www.googleapis.com"}, ReadPolicy: usersecrets.PolicyAllow})
	if err != nil {
		t.Fatal(err)
	}
	missing := uuid.New()

	for name, tc := range map[string]struct {
		id  uuid.UUID
		msg string
	}{
		"missing":       {missing, "choose one of your secrets"},
		"static":        {static.ID, "isn't an OAuth secret"},
		"not signed in": {notSignedIn.ID, "isn't signed in"},
		"lapsed":        {lapsed.ID, "needs signing in again (invalid_grant)"},
		"read only":     {readOnly.ID, "Add " + ScopeFile + " or " + ScopeFull},
	} {
		c := cfg
		c.SecretID = &tc.id
		_, err := f.svc.Save(f.ctx, f.ws, f.user, c)
		if field(err) != "secret_id" || !strings.Contains(err.Error(), tc.msg) {
			t.Errorf("%s: err = %v, want secret_id error containing %q", name, err, tc.msg)
		}
	}
	if _, err := f.q.GetDriveBackup(f.ctx, f.ws); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("a rejected config was stored: %v", err)
	}

	// Another person's secret is as good as missing.
	other := uuid.New()
	if _, err := f.svc.CheckSecret(f.ctx, f.ws, other, good.ID); field(err) != "secret_id" {
		t.Fatalf("someone else's secret: %v", err)
	}

	b, err := f.svc.Save(f.ctx, f.ws, f.user, cfg)
	if err != nil {
		t.Fatal(err)
	}
	loc, _ := time.LoadLocation("America/New_York")
	if !b.Enabled || *b.SecretID != good.ID || *b.UserID != f.user || b.FolderID != "folder1" || b.Retention != 5 || b.Revision != 1 ||
		b.NextRunAt == nil || !b.NextRunAt.Equal(time.Date(2026, 11, 16, 3, 0, 0, 0, loc)) {
		t.Fatalf("saved = %+v (next %v)", b, b.NextRunAt)
	}

	// Stale revision.
	if _, err := f.svc.Save(f.ctx, f.ws, f.user, cfg); err == nil || !strings.Contains(err.Error(), "changed since") {
		t.Fatalf("stale save: %v", err)
	}
	// The full drive scope works too.
	c := cfg
	c.SecretID, c.Revision = &full.ID, b.Revision
	if b, err = f.svc.Save(f.ctx, f.ws, f.user, c); err != nil || *b.SecretID != full.ID {
		t.Fatalf("drive scope: %v", err)
	}
	// The person can still delete the secret an enabled backup uses; the
	// backup then has none, and a run reports that.
	if _, err := f.q.DeleteUserSecret(f.ctx, store.DeleteUserSecretParams{ID: full.ID, WorkspaceID: f.ws, UserID: f.user}); err != nil {
		t.Fatalf("delete the secret an enabled backup uses: %v", err)
	}
	if b, err = f.svc.Get(f.ctx, f.ws); err != nil || !b.Enabled || b.SecretID != nil {
		t.Fatalf("after deleting the enabled backup's secret: %+v, %v", b, err)
	}
	// A disabled backup may keep an OAuth secret that isn't signed in yet,
	// but not one that isn't OAuth.
	c.Enabled, c.SecretID, c.Revision = false, &notSignedIn.ID, b.Revision
	if b, err = f.svc.Save(f.ctx, f.ws, f.user, c); err != nil || b.NextRunAt != nil || *b.SecretID != notSignedIn.ID {
		t.Fatalf("disabled with a secret not signed in: %+v, %v", b, err)
	}
	c.SecretID, c.Revision = &static.ID, b.Revision
	if _, err := f.svc.Save(f.ctx, f.ws, f.user, c); field(err) != "secret_id" {
		t.Fatalf("disabled with a static secret: %v", err)
	}

	// Deleting the secret turns the backup off but keeps the settings.
	if _, err := f.q.DeleteUserSecret(f.ctx, store.DeleteUserSecretParams{ID: notSignedIn.ID, WorkspaceID: f.ws, UserID: f.user}); err != nil {
		t.Fatal(err)
	}
	if b, err = f.svc.Get(f.ctx, f.ws); err != nil || b.SecretID != nil || b.FolderID != "folder1" {
		t.Fatalf("after deleting the secret: %+v, %v", b, err)
	}
}

func TestGetDefaults(t *testing.T) {
	f := newFixture(t)
	b, err := f.svc.Get(f.ctx, f.ws)
	if err != nil || b.Enabled || b.Revision != 0 || b.AtTime != "03:00" || b.Timezone != "UTC" || b.Retention != 7 {
		t.Fatalf("defaults = %+v, %v", b, err)
	}
	// The defaults are saveable as they are.
	if _, err := f.svc.Save(f.ctx, f.ws, f.user, Config{AtTime: b.AtTime, Timezone: b.Timezone, Retention: int(b.Retention)}); err != nil {
		t.Fatal(err)
	}
}

func TestDueAndLock(t *testing.T) {
	f := newFixture(t)
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	f.svc.Now = func() time.Time { return time.Now().Add(-48 * time.Hour) } // so the next run is already due
	if _, err := f.svc.Save(f.ctx, f.ws, f.user, Config{Enabled: true, SecretID: &sec.ID, FolderID: "f", AtTime: "03:00", Timezone: "UTC"}); err != nil {
		t.Fatal(err)
	}
	if due, err := f.q.NextDueDriveBackup(f.ctx); err != nil || due.WorkspaceID != f.ws {
		t.Fatalf("due = %v, %v", due.WorkspaceID, err)
	}
	if _, err := f.q.AcquireDriveBackupLock(f.ctx, store.AcquireDriveBackupLockParams{WorkspaceID: f.ws, Holder: "a", ExpiresAt: time.Now().Add(time.Hour)}); err != nil {
		t.Fatal(err)
	}
	// While a backup runs, it isn't due again and a second run can't start.
	if _, err := f.q.NextDueDriveBackup(f.ctx); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("due while locked: %v", err)
	}
	if _, err := f.q.AcquireDriveBackupLock(f.ctx, store.AcquireDriveBackupLockParams{WorkspaceID: f.ws, Holder: "b", ExpiresAt: time.Now().Add(time.Hour)}); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("second lock: %v", err)
	}
	if n, _ := f.q.ExtendDriveBackupLock(f.ctx, store.ExtendDriveBackupLockParams{WorkspaceID: f.ws, Holder: "b", ExpiresAt: time.Now()}); n != 0 {
		t.Fatal("another holder extended the lease")
	}
	// An expired lease is taken over.
	if n, _ := f.q.ExtendDriveBackupLock(f.ctx, store.ExtendDriveBackupLockParams{WorkspaceID: f.ws, Holder: "a", ExpiresAt: time.Now().Add(-time.Second)}); n != 1 {
		t.Fatal("holder couldn't extend its lease")
	}
	if _, err := f.q.GetDriveBackupLock(f.ctx, f.ws); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("expired lease reported live: %v", err)
	}
	if l, err := f.q.AcquireDriveBackupLock(f.ctx, store.AcquireDriveBackupLockParams{WorkspaceID: f.ws, Holder: "b", ExpiresAt: time.Now().Add(time.Hour)}); err != nil || l.Holder != "b" {
		t.Fatalf("take over expired lease: %v", err)
	}
	if err := f.q.FinishDriveBackup(f.ctx, store.FinishDriveBackupParams{WorkspaceID: f.ws, LastStatus: "failed", LastError: "boom"}); err != nil {
		t.Fatal(err)
	}
	if err := f.q.ReleaseDriveBackupLock(f.ctx, store.ReleaseDriveBackupLockParams{WorkspaceID: f.ws, Holder: "b"}); err != nil {
		t.Fatal(err)
	}
	b, _ := f.q.GetDriveBackup(f.ctx, f.ws)
	if b.LastStatus != "failed" || b.LastError != "boom" || b.LastRunAt == nil {
		t.Fatalf("finished = %+v", b)
	}
	if _, err := f.q.GetDriveBackupLock(f.ctx, f.ws); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("released lease still live: %v", err)
	}
}

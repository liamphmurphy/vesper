// Package drivebackup keeps the settings for the scheduled export to Google
// Drive: which OAuth secret uploads, into which folder, when, and how many
// backups to keep.
package drivebackup

import (
	"context"
	"errors"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

// Google Drive scopes that let Vesper create files. drive.file is enough: it
// covers files the app created, which is all a backup touches, including
// pruning old ones.
const (
	ScopeFile = "https://www.googleapis.com/auth/drive.file"
	ScopeFull = "https://www.googleapis.com/auth/drive"
)

// WriteScopes are the scopes an upload needs one of.
var WriteScopes = []string{ScopeFile, ScopeFull}

const (
	defaultAtTime    = "03:00"
	defaultTimezone  = "UTC"
	defaultRetention = 7
	maxRetention     = 1000
)

// folderID matches Drive file IDs. They end up in Drive search queries
// ('<id>' in parents), so nothing else is let through.
var folderID = regexp.MustCompile(`^[A-Za-z0-9_-]{1,200}$`)

// Config is what a person sets in Settings › Backup & move.
type Config struct {
	Enabled    bool
	SecretID   *uuid.UUID
	FolderID   string
	FolderName string
	AtTime     string // HH:MM, 24-hour
	Timezone   string // IANA, e.g. Europe/London
	Retention  int    // backups to keep in the folder; 0 keeps all
	// Revision is the one the person read; 0 when there was none yet.
	Revision int32
}

// Normalize trims the config and checks everything that doesn't need the
// database. A disabled config may be incomplete, so a person can save a
// folder before signing in.
func (c Config) Normalize() (Config, error) {
	c.FolderID = strings.TrimSpace(c.FolderID)
	c.FolderName = strings.TrimSpace(c.FolderName)
	c.AtTime = strings.TrimSpace(c.AtTime)
	c.Timezone = strings.TrimSpace(c.Timezone)
	if c.FolderID != "" && !folderID.MatchString(c.FolderID) {
		return c, apperr.Invalid("folder_id", "isn't a Google Drive folder ID")
	}
	if utf8.RuneCountInString(c.FolderName) > 500 {
		return c, apperr.Invalid("folder_name", "at most 500 characters")
	}
	if _, err := NextRun(c.AtTime, c.Timezone, time.Now()); err != nil {
		return c, err
	}
	if c.Retention < 0 || c.Retention > maxRetention {
		return c, apperr.Invalid("retention", "must be 0–1000 (0 keeps every backup)")
	}
	if c.Enabled {
		if c.SecretID == nil {
			return c, apperr.Invalid("secret_id", "choose a Google Drive OAuth secret")
		}
		if c.FolderID == "" {
			return c, apperr.Invalid("folder_id", "choose a Drive folder")
		}
	}
	return c, nil
}

// NextRun is the first daily run strictly after after: atTime (HH:MM) in tz,
// so 03:00 stays 03:00 across daylight saving changes. On a day the clock
// skips atTime, it runs within the hour the clock jumps over.
func NextRun(atTime, tz string, after time.Time) (time.Time, error) {
	if tz == "" {
		return time.Time{}, apperr.Invalid("timezone", "choose a time zone")
	}
	loc, err := time.LoadLocation(tz)
	if err != nil || tz == "Local" {
		return time.Time{}, apperr.Invalid("timezone", "unknown time zone")
	}
	clock, err := time.Parse("15:04", atTime)
	if err != nil || len(atTime) != 5 {
		return time.Time{}, apperr.Invalid("at_time", "use a 24-hour time like 03:00")
	}
	local := after.In(loc)
	for i := range 3 {
		at := time.Date(local.Year(), local.Month(), local.Day()+i, clock.Hour(), clock.Minute(), 0, 0, loc)
		if at.After(after) {
			return at, nil
		}
	}
	return time.Time{}, apperr.Invalid("at_time", "never comes round")
}

// Service saves and checks the Drive backup settings.
type Service struct {
	Q       *store.Queries
	Secrets *usersecrets.Service
	Now     func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// Defaults is a workspace's config before anyone saved one.
func Defaults(ws uuid.UUID) store.DriveBackup {
	return store.DriveBackup{WorkspaceID: ws, AtTime: defaultAtTime, Timezone: defaultTimezone, Retention: defaultRetention}
}

// Get returns the workspace's config, or Defaults (revision 0) when there is none.
func (s *Service) Get(ctx context.Context, ws uuid.UUID) (store.DriveBackup, error) {
	b, err := s.Q.GetDriveBackup(ctx, ws)
	if errors.Is(err, pgx.ErrNoRows) {
		return Defaults(ws), nil
	}
	return b, err
}

// CheckSecret loads one of the person's secrets and reports why it can't
// upload to Drive: it doesn't exist or isn't theirs, isn't OAuth, isn't
// signed in, its grant lapsed, or it lacks drive.file and drive. The errors
// name secret_id and say what to do.
func (s *Service) CheckSecret(ctx context.Context, ws, user, id uuid.UUID) (store.UserSecret, error) {
	sec, err := s.Q.GetUserSecret(ctx, store.GetUserSecretParams{ID: id, WorkspaceID: ws, UserID: user})
	if errors.Is(err, pgx.ErrNoRows) {
		return sec, apperr.Invalid("secret_id", "choose one of your secrets")
	}
	if err != nil {
		return sec, err
	}
	if err := s.Secrets.RequireScope(sec, WriteScopes...); err != nil {
		var ce *apperr.ConflictError
		if errors.As(err, &ce) {
			return sec, apperr.ConflictField("secret_id", "%s", ce.Msg)
		}
		return sec, err
	}
	return sec, nil
}

// Save validates and stores the workspace's config as user. The secret must be
// one of user's own OAuth secrets; while the backup is enabled it must also be
// signed in with Drive write access. Saving reschedules the next run.
func (s *Service) Save(ctx context.Context, ws, user uuid.UUID, in Config) (store.DriveBackup, error) {
	in, err := in.Normalize()
	if err != nil {
		return store.DriveBackup{}, err
	}
	if in.SecretID != nil {
		sec, err := s.CheckSecret(ctx, ws, user, *in.SecretID)
		var ce *apperr.ConflictError
		if err != nil && (in.Enabled || !errors.As(err, &ce) || sec.Kind != usersecrets.KindOAuth) {
			// A disabled backup may keep an OAuth secret that isn't ready
			// yet; anything else must be fixed before saving.
			return store.DriveBackup{}, err
		}
	}
	var next *time.Time
	if in.Enabled {
		n, err := NextRun(in.AtTime, in.Timezone, s.now())
		if err != nil {
			return store.DriveBackup{}, err
		}
		next = &n
	}
	b, err := s.Q.SaveDriveBackup(ctx, store.SaveDriveBackupParams{WorkspaceID: ws, UserID: &user, Enabled: in.Enabled, SecretID: in.SecretID,
		FolderID: in.FolderID, FolderName: in.FolderName, AtTime: in.AtTime, Timezone: in.Timezone, Retention: int32(in.Retention),
		NextRunAt: next, Revision: in.Revision})
	if errors.Is(err, pgx.ErrNoRows) {
		return b, apperr.Conflict("the backup settings changed since you opened them; reload and try again")
	}
	return b, err
}

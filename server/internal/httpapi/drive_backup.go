package httpapi

import (
	"context"
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/drivebackup"
)

func (s *Server) driveBackups() *drivebackup.Service {
	return &drivebackup.Service{Q: s.Q, Secrets: s.userSecrets()}
}

// driveBackup is the workspace's settings with the live lease, if a backup
// is running.
func (s *Server) driveBackup(ctx context.Context, ws uuid.UUID) (api.DriveBackup, error) {
	b, err := s.driveBackups().Get(ctx, ws)
	if err != nil {
		return api.DriveBackup{}, err
	}
	out := api.DriveBackup{Enabled: b.Enabled, SecretId: nullableOf(b.SecretID), FolderId: b.FolderID, FolderName: &b.FolderName,
		AtTime: b.AtTime, Timezone: b.Timezone, Retention: int(b.Retention), Revision: int(b.Revision),
		NextRunAt: nullableOf(b.NextRunAt), LastRunAt: nullableOf(b.LastRunAt), LastStatus: b.LastStatus, LastError: b.LastError}
	lock, err := s.Q.GetDriveBackupLock(ctx, ws)
	switch {
	case err == nil:
		out.Running, out.RunningSince = true, nullableOf(&lock.StartedAt)
	case !errors.Is(err, pgx.ErrNoRows):
		return out, err
	}
	return out, nil
}

func (s *Server) GetDriveBackup(ctx context.Context, _ api.GetDriveBackupRequestObject) (api.GetDriveBackupResponseObject, error) {
	_, _, ws := me(ctx)
	b, err := s.driveBackup(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.GetDriveBackup200JSONResponse(b), nil
}

func (s *Server) UpdateDriveBackup(ctx context.Context, req api.UpdateDriveBackupRequestObject) (api.UpdateDriveBackupResponseObject, error) {
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	u, _, ws := me(ctx)
	in := drivebackup.Config{Enabled: req.Body.Enabled, FolderID: req.Body.FolderId, FolderName: deref(req.Body.FolderName),
		AtTime: req.Body.AtTime, Timezone: req.Body.Timezone, Retention: req.Body.Retention, Revision: int32(req.Body.Revision)}
	if req.Body.SecretId.IsSpecified() && !req.Body.SecretId.IsNull() {
		id := req.Body.SecretId.MustGet()
		in.SecretID = &id
	}
	if _, err := s.driveBackups().Save(ctx, ws, u.ID, in); err != nil {
		return nil, err
	}
	b, err := s.driveBackup(ctx, ws)
	if err != nil {
		return nil, err
	}
	return api.UpdateDriveBackup200JSONResponse(b), nil
}

func (s *Server) RunDriveBackup(ctx context.Context, _ api.RunDriveBackupRequestObject) (api.RunDriveBackupResponseObject, error) {
	if s.DriveBackups == nil {
		return nil, apperr.Conflict("this server isn't set up to export")
	}
	_, _, ws := me(ctx)
	if err := s.DriveBackups.Start(ctx, ws); err != nil {
		return nil, err
	}
	b, err := s.driveBackup(ctx, ws)
	if err != nil {
		return nil, err
	}
	// The run may already have finished; it started either way.
	b.Running = true
	return api.RunDriveBackup202JSONResponse(b), nil
}

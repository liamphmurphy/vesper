package httpapi

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

func (s *Server) GetBackupEncryption(ctx context.Context, _ api.GetBackupEncryptionRequestObject) (api.GetBackupEncryptionResponseObject, error) {
	_, _, ws := me(ctx)
	keyConfigured := s.Secrets != nil && s.Secrets.Box != nil
	row, err := s.Q.GetBackupEncryption(ctx, ws)
	if errors.Is(err, pgx.ErrNoRows) {
		return api.GetBackupEncryption200JSONResponse{
			Enabled:       false,
			KeyConfigured: keyConfigured,
		}, nil
	}
	if err != nil {
		return nil, err
	}
	updatedAt := row.UpdatedAt
	return api.GetBackupEncryption200JSONResponse{
		Enabled:       true,
		KeyConfigured: keyConfigured,
		UpdatedAt:     &updatedAt,
	}, nil
}

func (s *Server) SetBackupEncryption(ctx context.Context, req api.SetBackupEncryptionRequestObject) (api.SetBackupEncryptionResponseObject, error) {
	_, _, ws := me(ctx)
	if s.Secrets == nil || s.Secrets.Box == nil {
		return nil, secrets.ErrNoKey
	}
	if req.Body == nil || !utf8.ValidString(req.Body.Password) {
		return nil, apperr.Invalid("password", "use %d to %d characters", minPasswordLen, maxPasswordLen)
	}
	n := utf8.RuneCountInString(req.Body.Password)
	if n < minPasswordLen || n > maxPasswordLen {
		return nil, apperr.Invalid("password", "use %d to %d characters", minPasswordLen, maxPasswordLen)
	}
	nonce, ct, err := s.Secrets.Box.Seal(ws, transfer.BackupPasswordScope, []byte(req.Body.Password))
	if err != nil {
		return nil, err
	}
	row, err := s.Q.UpsertBackupEncryption(ctx, store.UpsertBackupEncryptionParams{
		WorkspaceID: ws,
		Nonce:       nonce,
		Ciphertext:  ct,
	})
	if err != nil {
		return nil, err
	}
	updatedAt := row.UpdatedAt
	return api.SetBackupEncryption200JSONResponse{
		Enabled:       true,
		KeyConfigured: true,
		UpdatedAt:     &updatedAt,
	}, nil
}

func (s *Server) ClearBackupEncryption(ctx context.Context, _ api.ClearBackupEncryptionRequestObject) (api.ClearBackupEncryptionResponseObject, error) {
	_, _, ws := me(ctx)
	if err := s.Q.DeleteBackupEncryption(ctx, ws); err != nil {
		return nil, err
	}
	return api.ClearBackupEncryption204Response{}, nil
}

// ExportInstance streams the whole-instance archive (see internal/transfer).
// The archive is built as it is sent: tables are copied straight out of
// Postgres and objects straight out of S3, so memory stays flat however much
// is stored. Once the response has started, a failure can only end it early;
// the download then fails in the browser, and the cause is in the server log.
func (s *Server) ExportInstance(ctx context.Context, _ api.ExportInstanceRequestObject) (api.ExportInstanceResponseObject, error) {
	if s.Exporter == nil {
		return nil, apperr.Conflict("this server isn't set up to export")
	}
	_, _, ws := me(ctx)
	password := ""
	row, err := s.Q.GetBackupEncryption(ctx, ws)
	switch {
	case err == nil:
		if s.Secrets == nil || s.Secrets.Box == nil {
			return nil, apperr.Conflict("backup encryption is enabled, but SECRETS_KEY isn't configured")
		}
		pt, oerr := s.Secrets.Box.Open(ws, transfer.BackupPasswordScope, row.Nonce, row.Ciphertext)
		if oerr != nil {
			return nil, apperr.Conflict("stored backup encryption password couldn't be decrypted; check SECRETS_KEY or reset the backup password")
		}
		password = string(pt)
		clear(pt)
	case !errors.Is(err, pgx.ErrNoRows):
		return nil, err
	}

	pr, pw := io.Pipe()
	go func() {
		// ctx is the request's: a closed tab cancels the export.
		_, err := s.Exporter.ExportWithPassword(ctx, pw, password)
		if err != nil {
			s.Log.Error("instance export", "err", err)
		}
		pw.CloseWithError(err)
	}()
	if password != "" {
		return encryptedInstanceArchive{api.ExportInstance200ApplicationoctetStreamResponse{Body: pr}}, nil
	}
	return instanceArchive{api.ExportInstance200ApplicationzipResponse{Body: pr}}, nil
}

// instanceArchive adds a download filename to the generated response.
type instanceArchive struct {
	api.ExportInstance200ApplicationzipResponse
}

func (e instanceArchive) VisitExportInstanceResponse(w http.ResponseWriter) error {
	name := fmt.Sprintf("vesper-export-%s.zip", time.Now().UTC().Format("2006-01-02"))
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", name))
	// An archive of everything must never be cached by a proxy or the browser.
	w.Header().Set("Cache-Control", "no-store")
	return e.ExportInstance200ApplicationzipResponse.VisitExportInstanceResponse(w)
}

type encryptedInstanceArchive struct {
	api.ExportInstance200ApplicationoctetStreamResponse
}

func (e encryptedInstanceArchive) VisitExportInstanceResponse(w http.ResponseWriter) error {
	name := fmt.Sprintf("vesper-export-%s%s", time.Now().UTC().Format("2006-01-02"), transfer.EncryptedExtension)
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", name))
	w.Header().Set("X-Vesper-Backup-Encrypted", "true")
	// An archive of everything must never be cached by a proxy or the browser.
	w.Header().Set("Cache-Control", "no-store")
	return e.ExportInstance200ApplicationoctetStreamResponse.VisitExportInstanceResponse(w)
}

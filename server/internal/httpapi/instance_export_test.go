package httpapi

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

// noBlobs is an object store with nothing in it.
type noBlobs struct{}

func (noBlobs) ListBuckets(context.Context) ([]string, error)             { return nil, nil }
func (noBlobs) List(context.Context, string, func(blob.Info) error) error { return nil }
func (noBlobs) Get(context.Context, string, string) (blob.Object, error) {
	return blob.Object{}, blob.ErrNotFound
}
func (noBlobs) Put(context.Context, string, string, io.Reader, int64, string) error { return nil }
func (noBlobs) EnsureBucket(context.Context, string) error                          { return nil }

func TestExportInstanceDownloadsAnArchive(t *testing.T) {
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Exporter = &transfer.Exporter{Pool: s.Pool, Blobs: noBlobs{}, AppVersion: "test"}
	})
	res, err := http.Get(e.srv.URL + "/api/v1/instance/export")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status = %d: %s", res.StatusCode, body)
	}
	if got := res.Header.Get("Content-Type"); got != "application/zip" {
		t.Errorf("Content-Type = %q, want application/zip", got)
	}
	if cd := res.Header.Get("Content-Disposition"); !strings.HasPrefix(cd, `attachment; filename="vesper-export-`) {
		t.Errorf("Content-Disposition = %q, want an attachment named vesper-export-DATE.zip", cd)
	}
	if got := res.Header.Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q: an archive of everything mustn't be cached", got)
	}
	zr, err := zip.NewReader(bytes.NewReader(body), int64(len(body)))
	if err != nil {
		t.Fatalf("the download isn't a zip: %v", err)
	}
	have := map[string]bool{}
	for _, f := range zr.File {
		have[f.Name] = true
	}
	for _, want := range []string{"manifest.json", "db/tickets.csv", "db/users.csv"} {
		if !have[want] {
			t.Errorf("archive has no %s", want)
		}
	}
	// The seeded demo has a user and tickets, so the tables aren't empty files.
	for _, f := range zr.File {
		if f.Name == "db/tickets.csv" && f.UncompressedSize64 == 0 {
			t.Error("db/tickets.csv is empty")
		}
	}
}

func TestExportInstanceNeedsSetup(t *testing.T) {
	e := newChatEnvServer(t, nil, nil) // no Exporter
	e.want("GET", "/instance/export", nil, http.StatusConflict)
}

// The archive holds every secret and table, so a signed-out request gets nothing.
func TestExportInstanceRequiresSignIn(t *testing.T) {
	_, h := newSignedInServer(t)
	if rec := getWithCookie(h, "/api/v1/instance/export", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("signed out: GET /instance/export = %d, want 401", rec.Code)
	}
}

func TestBackupEncryptionLifecycleAndEncryptedExport(t *testing.T) {
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: testBox(t)}
		s.Exporter = &transfer.Exporter{Pool: s.Pool, Blobs: noBlobs{}, AppVersion: "test"}
	})

	// 1. Initially disabled with key configured.
	code, status := e.do("GET", "/instance/backup-encryption", nil)
	if code != http.StatusOK || status["enabled"] != false || status["key_configured"] != true {
		t.Fatalf("initial GET = (%d, %v)", code, status)
	}

	// 2. Too-short password is rejected with 422 on field "password".
	code, bad := e.do("PUT", "/instance/backup-encryption", map[string]string{"password": "short"})
	if code != http.StatusUnprocessableEntity || bad["field"] != "password" {
		t.Fatalf("short PUT = (%d, %v), want 422 field=password", code, bad)
	}

	// 3. Valid password enables encryption and never echoes the password.
	const pw = "my-strong-backup-password"
	req, _ := http.NewRequest(http.MethodPut, e.srv.URL+"/api/v1/instance/backup-encryption", strings.NewReader(`{"password":"`+pw+`"}`))
	req.Header.Set("Content-Type", "application/json")
	putRes, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	putBody, _ := io.ReadAll(putRes.Body)
	_ = putRes.Body.Close()
	if putRes.StatusCode != http.StatusOK {
		t.Fatalf("valid PUT status = %d: %s", putRes.StatusCode, putBody)
	}
	if strings.Contains(string(putBody), pw) {
		t.Fatalf("PUT response leaked password: %s", putBody)
	}
	var putJSON map[string]any
	if err := json.Unmarshal(putBody, &putJSON); err != nil {
		t.Fatal(err)
	}
	if putJSON["enabled"] != true || putJSON["updated_at"] == "" {
		t.Fatalf("unexpected PUT JSON: %v", putJSON)
	}

	// 4. GET /instance/export now streams an encrypted .vesper.enc archive.
	res, err := http.Get(e.srv.URL + "/api/v1/instance/export")
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	encBody, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("encrypted export status = %d: %s", res.StatusCode, encBody)
	}
	if got := res.Header.Get("Content-Type"); got != "application/octet-stream" {
		t.Errorf("Content-Type = %q, want application/octet-stream", got)
	}
	if got := res.Header.Get("X-Vesper-Backup-Encrypted"); got != "true" {
		t.Errorf("X-Vesper-Backup-Encrypted = %q, want true", got)
	}
	if cd := res.Header.Get("Content-Disposition"); !strings.Contains(cd, transfer.EncryptedExtension+`"`) {
		t.Errorf("Content-Disposition = %q, want filename ending with %s", cd, transfer.EncryptedExtension)
	}
	if got := res.Header.Get("Cache-Control"); got != "no-store" {
		t.Errorf("Cache-Control = %q, want no-store", got)
	}
	if !transfer.HasEncryptedMagic(encBody) {
		t.Fatalf("export body does not start with encrypted magic")
	}

	// Wrong password fails.
	var badDec bytes.Buffer
	if err := transfer.DecryptStream(bytes.NewReader(encBody), &badDec, "wrong-password"); !errors.Is(err, transfer.ErrWrongPassword) {
		t.Fatalf("wrong password decrypt err = %v, want ErrWrongPassword", err)
	}

	// Right password decrypts to a valid zip without backup_encryption table.
	var decZip bytes.Buffer
	if err := transfer.DecryptStream(bytes.NewReader(encBody), &decZip, pw); err != nil {
		t.Fatalf("DecryptStream: %v", err)
	}
	zr, err := zip.NewReader(bytes.NewReader(decZip.Bytes()), int64(decZip.Len()))
	if err != nil {
		t.Fatalf("decrypted body is not a zip: %v", err)
	}
	have := map[string]bool{}
	for _, f := range zr.File {
		have[f.Name] = true
	}
	for _, want := range []string{"manifest.json", "db/tickets.csv", "db/users.csv"} {
		if !have[want] {
			t.Errorf("decrypted archive missing %s", want)
		}
	}
	if have["db/backup_encryption.csv"] {
		t.Errorf("archive must never contain db/backup_encryption.csv")
	}

	// 5. DELETE turns encryption back off and subsequent export returns plain zip.
	code, _ = e.do("DELETE", "/instance/backup-encryption", nil)
	if code != http.StatusNoContent {
		t.Fatalf("DELETE status = %d, want 204", code)
	}
	code, status = e.do("GET", "/instance/backup-encryption", nil)
	if code != http.StatusOK || status["enabled"] != false {
		t.Fatalf("after DELETE GET = (%d, %v)", code, status)
	}
	plainRes, err := http.Get(e.srv.URL + "/api/v1/instance/export")
	if err != nil {
		t.Fatal(err)
	}
	defer plainRes.Body.Close()
	if got := plainRes.Header.Get("Content-Type"); got != "application/zip" {
		t.Errorf("after DELETE Content-Type = %q, want application/zip", got)
	}
}

func TestBackupEncryptionRequiresSecretsKeyAndFailsClosed(t *testing.T) {
	box := testBox(t)
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: nil}
		s.Exporter = &transfer.Exporter{Pool: s.Pool, Blobs: noBlobs{}, AppVersion: "test"}
	})

	code, status := e.do("GET", "/instance/backup-encryption", nil)
	if code != http.StatusOK || status["enabled"] != false || status["key_configured"] != false {
		t.Fatalf("no-key GET = (%d, %v)", code, status)
	}
	code, _ = e.do("PUT", "/instance/backup-encryption", map[string]string{"password": "valid-password-123"})
	if code != http.StatusConflict {
		t.Fatalf("no-key PUT status = %d, want 409", code)
	}

	// Simulate backup_encryption row present while SECRETS_KEY is missing: export must fail closed (409), never plaintext.
	nonce, ct, err := box.Seal(e.me.WorkspaceID, transfer.BackupPasswordScope, []byte("secret-backup-pw"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(t.Context(), `INSERT INTO backup_encryption (workspace_id, nonce, ciphertext) VALUES ($1, $2, $3)`, e.me.WorkspaceID, nonce, ct); err != nil {
		t.Fatal(err)
	}
	e.want("GET", "/instance/export", nil, http.StatusConflict)
}

func TestBackupEncryptionRequiresSignIn(t *testing.T) {
	_, h := newSignedInServer(t)
	for _, method := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		var body io.Reader
		if method == http.MethodPut {
			body = strings.NewReader(`{"password":"valid-password-123"}`)
		}
		req := httptest.NewRequest(method, "/api/v1/instance/backup-encryption", body)
		if body != nil {
			req.Header.Set("Content-Type", "application/json")
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusUnauthorized {
			t.Fatalf("signed out %s /instance/backup-encryption = %d, want 401", method, rec.Code)
		}
	}
}

package httpapi

import (
	"context"
	"encoding/base64"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/drivebackup"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

// googleToken answers OAuth token requests, granting drive.file.
type googleToken struct{}

func (googleToken) RoundTrip(r *http.Request) (*http.Response, error) {
	body := `{"access_token":"a","refresh_token":"r","expires_in":3600,"scope":"` + drivebackup.ScopeFile + `"}`
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": {"application/json"}}, Body: io.NopCloser(strings.NewReader(body)), Request: r}, nil
}

// tinyDrive takes one-chunk resumable uploads, or refuses them with status.
type tinyDrive struct {
	mu     sync.Mutex
	status int
	got    []string // uploaded bodies
}

func (d *tinyDrive) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/upload/drive/v3/files":
		if d.status != 0 {
			w.WriteHeader(d.status)
			_, _ = io.WriteString(w, `{"error":{"message":"The user has not granted the app write access"}}`)
			return
		}
		w.Header().Set("Location", "http://"+r.Host+"/session")
	case r.Method == http.MethodPut && r.URL.Path == "/session":
		b, _ := io.ReadAll(r.Body)
		d.got = append(d.got, string(b))
		_, _ = io.WriteString(w, `{"id":"file1"}`)
	default:
		http.Error(w, "unexpected", 400)
	}
}

type archiveText string

func (a archiveText) Export(_ context.Context, w io.Writer) (*transfer.Manifest, error) {
	_, err := io.WriteString(w, string(a))
	return &transfer.Manifest{}, err
}

func TestDriveBackupAPI(t *testing.T) {
	drive := &tinyDrive{}
	ds := httptest.NewServer(drive)
	t.Cleanup(ds.Close)
	box, _ := secrets.NewBox(base64.StdEncoding.EncodeToString([]byte(strings.Repeat("k", 32))))
	var runner *drivebackup.Runner
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		runner = &drivebackup.Runner{Pool: s.Pool, Secrets: &usersecrets.Service{Q: s.Q, Box: box}, Exporter: archiveText("zip!"), Holder: "api",
			Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
			Uploader: func(u *drivebackup.Uploader) {
				u.HTTP, u.BaseURL = ds.Client(), ds.URL
				u.Sleep = func(context.Context, time.Duration) error { return nil }
			}}
		s.DriveBackups = runner
	})
	ctx := context.Background()

	// A signed-in Google OAuth secret, and a static one.
	us := &usersecrets.Service{Q: e.q, Box: box, HTTP: googleToken{}}
	sec, err := us.Create(ctx, e.me.WorkspaceID, e.me.ID, usersecrets.Input{Name: "Drive", AllowedHosts: []string{"www.googleapis.com"}, ReadPolicy: usersecrets.PolicyAllow,
		OAuth: &usersecrets.OAuthInput{AuthorizeURL: "https://accounts.google.com/o/oauth2/auth", TokenURL: "https://oauth2.googleapis.com/token",
			ClientID: "client", ClientSecret: "shh", Scopes: []string{drivebackup.ScopeFile}}})
	if err != nil {
		t.Fatal(err)
	}
	link, err := us.BeginOAuth(ctx, sec, "https://vesper.example.com/cb")
	if err != nil {
		t.Fatal(err)
	}
	u, _ := url.Parse(link)
	if sec, err = us.FinishOAuth(ctx, u.Query().Get("state"), "code"); err != nil {
		t.Fatal(err)
	}
	static, err := us.Create(ctx, e.me.WorkspaceID, e.me.ID, usersecrets.Input{Name: "Static", Value: "tok", Placement: usersecrets.PlacementBearer,
		AllowedHosts: []string{"www.googleapis.com"}, ReadPolicy: usersecrets.PolicyAllow})
	if err != nil {
		t.Fatal(err)
	}

	// Defaults before anything is saved; a manual run needs settings.
	got := e.want("GET", "/backups/drive", nil, http.StatusOK)
	if got["revision"] != 0.0 || got["enabled"] != false || got["at_time"] != "03:00" || got["timezone"] != "UTC" || got["running"] != false || got["secret_id"] != nil {
		t.Fatalf("defaults = %v", got)
	}
	e.want("POST", "/backups/drive/run", nil, http.StatusConflict)

	valid := map[string]any{"enabled": true, "secret_id": sec.ID, "folder_id": "folder1", "folder_name": "Backups",
		"at_time": "02:30", "timezone": "America/New_York", "retention": 0, "revision": 0}
	with := func(k string, v any) map[string]any {
		out := map[string]any{}
		for kk, vv := range valid {
			out[kk] = vv
		}
		out[k] = v
		return out
	}
	e.invalid("PUT", "/backups/drive", with("at_time", "2:30pm"), "at_time", "24-hour")
	e.invalid("PUT", "/backups/drive", with("timezone", "Mars/Olympus"), "timezone", "unknown")
	e.invalid("PUT", "/backups/drive", with("retention", -1), "retention", "0–1000")
	e.invalid("PUT", "/backups/drive", with("folder_id", "x' or '1'='1"), "folder_id", "folder")
	e.invalid("PUT", "/backups/drive", with("secret_id", nil), "secret_id", "secret")
	if out := e.want("PUT", "/backups/drive", with("secret_id", static.ID), http.StatusConflict); out["field"] != "secret_id" || !strings.Contains(out["message"].(string), "isn't an OAuth secret") {
		t.Fatalf("static secret: %v", out)
	}

	saved := e.want("PUT", "/backups/drive", valid, http.StatusOK)
	if saved["revision"] != 1.0 || saved["secret_id"] != sec.ID.String() || saved["folder_name"] != "Backups" || saved["next_run_at"] == nil || saved["last_status"] != "" {
		t.Fatalf("saved = %v", saved)
	}
	// Stale revision.
	if out := e.want("PUT", "/backups/drive", valid, http.StatusConflict); !strings.Contains(out["message"].(string), "changed since") {
		t.Fatalf("stale save: %v", out)
	}

	// Export now.
	started := e.want("POST", "/backups/drive/run", nil, http.StatusAccepted)
	if started["running"] != true {
		t.Fatalf("started = %v", started)
	}
	runner.Wait()
	done := e.want("GET", "/backups/drive", nil, http.StatusOK)
	if done["last_status"] != "succeeded" || done["last_run_at"] == nil || done["running"] != false || len(drive.got) != 1 || drive.got[0] != "zip!" {
		t.Fatalf("after the run: %v (Drive got %q)", done, drive.got)
	}

	// While a run holds the lease, another is refused and GET says so.
	if _, err := e.q.AcquireDriveBackupLock(ctx, store.AcquireDriveBackupLockParams{WorkspaceID: e.me.WorkspaceID, Holder: "elsewhere", TtlSeconds: 3600}); err != nil {
		t.Fatal(err)
	}
	if out := e.want("POST", "/backups/drive/run", nil, http.StatusConflict); !strings.Contains(out["message"].(string), "already running") {
		t.Fatalf("second run: %v", out)
	}
	if out := e.want("GET", "/backups/drive", nil, http.StatusOK); out["running"] != true || out["running_since"] == nil {
		t.Fatalf("while running: %v", out)
	}
	_ = e.q.ReleaseDriveBackupLock(ctx, store.ReleaseDriveBackupLockParams{WorkspaceID: e.me.WorkspaceID, Holder: "elsewhere"})

	// A failure is recorded and shows in Needs you, linking to Settings.
	drive.mu.Lock()
	drive.status = http.StatusForbidden
	drive.mu.Unlock()
	e.want("POST", "/backups/drive/run", nil, http.StatusAccepted)
	runner.Wait()
	failed := e.want("GET", "/backups/drive", nil, http.StatusOK)
	if failed["last_status"] != "failed" || !strings.Contains(failed["last_error"].(string), "write access") {
		t.Fatalf("after Drive refused: %v", failed)
	}
	inbox := e.want("GET", "/inbox", nil, http.StatusOK)
	var item map[string]any
	for _, it := range inbox["items"].([]any) {
		if m := it.(map[string]any); m["kind"] == "drive_backup" {
			item = m
		}
	}
	if item == nil || item["needs_you"] != true || item["href"] != "/settings#backup" || !strings.Contains(item["summary"].(string), "write access") {
		t.Fatalf("Needs you item = %v", item)
	}
}

func TestRunDriveBackupNeedsSetup(t *testing.T) {
	e := newChatEnvServer(t, nil, nil) // no DriveBackups
	e.want("POST", "/backups/drive/run", nil, http.StatusConflict)
}

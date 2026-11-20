package customapps

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// memBlobs is an in-memory MediaBlobs. (This package's tests can't import
// internal/blob: blob -> config -> harness -> runs -> customapps is a cycle.)
// Put enforces the exact size the way blob.Store does.
type memBlobs struct {
	mu   sync.Mutex
	objs map[string][]byte
}

func (m *memBlobs) Put(ctx context.Context, bucket, key string, body io.Reader, size int64, _ string) error {
	b, err := io.ReadAll(io.LimitReader(body, size+1))
	if err != nil {
		return err
	}
	if int64(len(b)) != size {
		return fmt.Errorf("put %s: got %d bytes, want %d", key, len(b), size)
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.objs == nil {
		m.objs = map[string][]byte{}
	}
	m.objs[bucket+"/"+key] = b
	return nil
}

func (m *memBlobs) Delete(_ context.Context, bucket, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.objs, bucket+"/"+key)
	return nil
}

func (m *memBlobs) get(bucket, key string) ([]byte, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.objs[bucket+"/"+key]
	return b, ok
}

type mediaEnv struct {
	svc   *Service
	media *Media
	blobs *memBlobs
	appID uuid.UUID
	ws    uuid.UUID
	user  uuid.UUID
	site  *httptest.Server
	clip  []byte
}

func newMediaEnv(t *testing.T) *mediaEnv {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	u, err := store.New(pool).GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	clip := bytes.Repeat([]byte("frame"), 40_000) // 200 KB
	release := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("/clip.mp4", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		_, _ = w.Write(clip)
	})
	mux.HandleFunc("/files/clip.webm", func(w http.ResponseWriter, r *http.Request) {
		// No Content-Length and a generic type: the downloader must spool it
		// and trust the .webm extension.
		w.Header().Set("Content-Type", "application/octet-stream")
		w.(http.Flusher).Flush()
		_, _ = w.Write(clip)
	})
	mux.HandleFunc("/watch", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = io.WriteString(w, "<html></html>")
	})
	mux.HandleFunc("/live.m3u8", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(w, "#EXTM3U\n")
	})
	mux.HandleFunc("/huge.mp4", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Content-Length", "999999999")
		w.WriteHeader(http.StatusOK)
	})
	mux.HandleFunc("/slow.mp4", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Content-Length", "1000")
		w.WriteHeader(http.StatusOK)
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-r.Context().Done():
		}
	})
	site := httptest.NewServer(mux)
	t.Cleanup(site.Close)
	t.Cleanup(func() { close(release) })

	blobs := &memBlobs{}
	media := &Media{Pool: pool, Blobs: blobs, Bucket: "artifacts", Transport: http.DefaultTransport, MaxBytes: 1 << 20}
	t.Cleanup(media.Close)
	svc := &Service{Pool: pool, Media: media}
	app, err := svc.Create(ctx, u.WorkspaceID, u.ID, CreateInput{Slug: "feed", Name: "Feed", Template: "blank"})
	if err != nil {
		t.Fatal(err)
	}
	return &mediaEnv{svc: svc, media: media, blobs: blobs, appID: app.ID, ws: u.WorkspaceID, user: u.ID, site: site, clip: clip}
}

func (e *mediaEnv) waitDone(t *testing.T, id uuid.UUID) MediaItem {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		item, err := e.media.Status(context.Background(), e.appID, id)
		if err != nil {
			t.Fatalf("Status: %v", err)
		}
		if item.State != "downloading" {
			return item
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("download did not finish")
	return MediaItem{}
}

func (e *mediaEnv) stored(t *testing.T, key string) []byte {
	t.Helper()
	b, ok := e.blobs.get("artifacts", key)
	if !ok {
		t.Fatalf("blob %s missing", key)
	}
	return b
}

func TestMediaDownloadsDirectVideoFiles(t *testing.T) {
	e := newMediaEnv(t)
	ctx := context.Background()

	for _, tc := range []struct{ path, wantType string }{
		{"/clip.mp4", "video/mp4"},
		{"/files/clip.webm", "video/webm"}, // no length, generic type, known extension
	} {
		started, err := e.media.Start(ctx, e.appID, e.site.URL+tc.path)
		if err != nil {
			t.Fatalf("Start(%s): %v", tc.path, err)
		}
		if started.State != "downloading" || started.PlayURL != "vesper-media:"+started.ID.String() {
			t.Fatalf("Start(%s) = %+v", tc.path, started)
		}
		done := e.waitDone(t, started.ID)
		if done.State != "done" || done.ContentType != tc.wantType || done.BytesDone != int64(len(e.clip)) {
			t.Fatalf("%s finished as %+v", tc.path, done)
		}
		_, key, size, err := e.media.Playable(ctx, e.appID, started.ID)
		if err != nil || size != int64(len(e.clip)) || !bytes.Equal(e.stored(t, key), e.clip) {
			t.Fatalf("%s stored file mismatch: size=%d err=%v", tc.path, size, err)
		}
	}
}

func TestMediaRejectsAnythingButADirectVideo(t *testing.T) {
	e := newMediaEnv(t)
	for path, want := range map[string]string{
		"/watch":     "not a direct video file",
		"/live.m3u8": "streaming playlists",
		"/huge.mp4":  "over the 1 MB limit",
		"/missing":   "HTTP 404",
	} {
		_, err := e.media.Start(context.Background(), e.appID, e.site.URL+path)
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("Start(%s) err = %v, want it to mention %q", path, err, want)
		}
	}
	if _, err := e.media.Start(context.Background(), e.appID, "file:///etc/passwd"); !errors.As(err, new(*apperr.ValidationError)) {
		t.Errorf("file URL err = %v, want validation error", err)
	}

	// Without a test transport the SSRF guard refuses loopback addresses.
	guarded := &Media{Pool: e.media.Pool, Blobs: e.blobs, Bucket: "artifacts"}
	if _, err := guarded.Start(context.Background(), e.appID, e.site.URL+"/clip.mp4"); !errors.As(err, new(*apperr.ValidationError)) {
		t.Errorf("loopback download err = %v, want it blocked", err)
	}
}

func TestMediaDeleteStopsDownloadAndRemovesFile(t *testing.T) {
	e := newMediaEnv(t)
	ctx := context.Background()

	slow, err := e.media.Start(ctx, e.appID, e.site.URL+"/slow.mp4")
	if err != nil {
		t.Fatalf("Start slow: %v", err)
	}
	if err := e.media.Delete(ctx, e.appID, slow.ID); err != nil {
		t.Fatalf("Delete running download: %v", err)
	}
	if _, err := e.media.Status(ctx, e.appID, slow.ID); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("Status after delete err = %v, want not found", err)
	}

	clip, err := e.media.Start(ctx, e.appID, e.site.URL+"/clip.mp4")
	if err != nil {
		t.Fatal(err)
	}
	e.waitDone(t, clip.ID)
	_, key, _, _ := e.media.Playable(ctx, e.appID, clip.ID)
	if err := e.svc.Delete(ctx, e.ws, e.user, "feed"); err != nil {
		t.Fatalf("delete app: %v", err)
	}
	if _, ok := e.blobs.get("artifacts", key); ok {
		t.Fatal("file still stored after app delete")
	}
}

// A row still marked downloading after a restart has no download behind it.
func TestMediaStatusMarksInterruptedDownloadsFailed(t *testing.T) {
	e := newMediaEnv(t)
	ctx := context.Background()
	row, err := store.New(e.media.Pool).InsertCustomAppMedia(ctx, store.InsertCustomAppMediaParams{
		AppID: e.appID, SourceUrl: "https://example.com/a.mp4", BlobKey: "custom-app-media/x/y", ContentType: "video/mp4",
	})
	if err != nil {
		t.Fatal(err)
	}
	item, err := e.media.Status(ctx, e.appID, row.ID)
	if err != nil || item.State != "failed" || !strings.Contains(item.Error, "interrupted") {
		t.Fatalf("Status = %+v, %v; want failed as interrupted", item, err)
	}
	if _, _, _, err := e.media.Playable(ctx, e.appID, row.ID); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("Playable(failed) err = %v, want not found", err)
	}
	if _, err := e.media.Status(ctx, uuid.New(), row.ID); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("Status from another app err = %v, want not found", err)
	}
}

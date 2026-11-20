package customapps

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

// DefaultMaxMediaBytes caps one downloaded file.
const DefaultMaxMediaBytes int64 = 8 << 30

const (
	mediaHeaderTimeout   = 30 * time.Second
	mediaMaxRedirects    = 5
	mediaProgressEvery   = time.Second
	mediaBlobPrefix      = "custom-app-media"
	mediaInterruptedText = "download was interrupted (Vesper restarted); start it again"
)

// MediaBlobs is the blob store the downloader writes to (blob.Store).
type MediaBlobs interface {
	Put(ctx context.Context, bucket, key string, body io.Reader, size int64, contentType string) error
	Delete(ctx context.Context, bucket, key string) error
}

// Media downloads video files for custom apps into the blob store, so they play
// locally rather than streaming from the site they came from. Only direct video
// files are supported: a URL whose response is a video, not a page or a streaming
// playlist. Downloads run in the background and outlive the request that started
// them; one Media is shared for the life of the API process.
type Media struct {
	Pool   *pgxpool.Pool
	Blobs  MediaBlobs
	Bucket string
	// Transport overrides the SSRF-checked transport, for tests.
	Transport http.RoundTripper
	// MaxBytes caps one file; zero means DefaultMaxMediaBytes.
	MaxBytes int64

	mu     sync.Mutex
	active map[uuid.UUID]context.CancelFunc
	wg     sync.WaitGroup
}

// MediaItem is one download as apps see it.
type MediaItem struct {
	ID          uuid.UUID `json:"id"`
	SourceURL   string    `json:"source_url"`
	State       string    `json:"state"`
	ContentType string    `json:"content_type"`
	BytesDone   int64     `json:"bytes_done"`
	BytesTotal  *int64    `json:"bytes_total"`
	Error       string    `json:"error,omitempty"`
	// PlayURL is what the app passes to playVideo once State is "done".
	PlayURL string `json:"play_url"`

	blobKey string
}

func mediaItemFrom(r store.CustomAppMedium) MediaItem {
	return MediaItem{
		ID:          r.ID,
		SourceURL:   r.SourceUrl,
		State:       r.State,
		ContentType: r.ContentType,
		BytesDone:   r.BytesDone,
		BytesTotal:  r.BytesTotal,
		Error:       r.Error,
		PlayURL:     MediaPlayURL(r.ID),
		blobKey:     r.BlobKey,
	}
}

// MediaPlayURL is the playVideo URL for a downloaded file; the web player maps
// it to the app's media content endpoint.
func MediaPlayURL(id uuid.UUID) string { return "vesper-media:" + id.String() }

// directVideoTypes are the content types accepted as a playable file.
var directVideoTypes = map[string]bool{
	"video/mp4": true, "video/webm": true, "video/quicktime": true, "video/x-m4v": true,
	"video/ogg": true, "video/x-matroska": true, "video/mpeg": true,
}

var directVideoExts = map[string]string{
	".mp4": "video/mp4", ".m4v": "video/x-m4v", ".webm": "video/webm", ".mov": "video/quicktime",
	".ogv": "video/ogg", ".mkv": "video/x-matroska", ".mpg": "video/mpeg", ".mpeg": "video/mpeg",
}

// videoContentType decides whether a response is a direct video file. A generic
// binary type is accepted when the URL names a video file, since many file hosts
// serve video as application/octet-stream.
func videoContentType(header string, u *url.URL) (string, error) {
	mt, _, _ := mime.ParseMediaType(header)
	mt = strings.ToLower(mt)
	switch {
	case directVideoTypes[mt]:
		return mt, nil
	case strings.Contains(mt, "mpegurl") || mt == "application/dash+xml":
		return "", apperr.Invalid("url", "streaming playlists (.m3u8/.mpd) aren't supported yet; only direct video files can be downloaded")
	case mt == "" || mt == "application/octet-stream" || mt == "binary/octet-stream":
		if ct, ok := directVideoExts[strings.ToLower(path.Ext(u.Path))]; ok {
			return ct, nil
		}
	}
	if mt == "" {
		mt = "no content type"
	}
	return "", apperr.Invalid("url", "not a direct video file (%s); only links straight to a video file can be downloaded", mt)
}

func (m *Media) maxBytes() int64 {
	if m.MaxBytes > 0 {
		return m.MaxBytes
	}
	return DefaultMaxMediaBytes
}

func (m *Media) client() (*http.Client, func()) {
	rt := m.Transport
	done := func() {}
	if rt == nil {
		t := usersecrets.SafeTransport(false, nil)
		rt, done = t, t.CloseIdleConnections
	}
	return &http.Client{
		Transport: rt,
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if len(via) >= mediaMaxRedirects {
				return errors.New("too many redirects")
			}
			if err := checkMediaURL(next.URL); err != nil {
				return err
			}
			return nil
		},
	}, done
}

func checkMediaURL(u *url.URL) error {
	if u == nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" || u.User != nil || len(u.String()) > 2048 {
		return apperr.Invalid("url", "media url must be an http(s) URL without credentials")
	}
	return nil
}

// Start checks that rawURL serves a direct video file and begins downloading it
// in the background. It returns once the response headers are in, so a page,
// playlist or oversized file fails here rather than in the background.
func (m *Media) Start(ctx context.Context, appID uuid.UUID, rawURL string) (MediaItem, error) {
	if m == nil || m.Pool == nil || m.Blobs == nil {
		return MediaItem{}, errors.New("media downloads are unavailable")
	}
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil {
		return MediaItem{}, apperr.Invalid("url", "invalid media url")
	}
	if err := checkMediaURL(u); err != nil {
		return MediaItem{}, err
	}

	// The download outlives the caller's request, so it gets its own context;
	// the header timer bounds only the wait for the server to answer.
	dlCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	headerTimer := time.AfterFunc(mediaHeaderTimeout, cancel)
	client, closeClient := m.client()
	req, err := http.NewRequestWithContext(dlCtx, http.MethodGet, u.String(), nil)
	if err != nil {
		headerTimer.Stop()
		cancel()
		closeClient()
		return MediaItem{}, apperr.Invalid("url", "invalid media url: %v", err)
	}
	req.Header.Set("User-Agent", "Vesper")
	res, err := client.Do(req)
	headerTimer.Stop()
	fail := func(e error) (MediaItem, error) {
		if res != nil {
			_ = res.Body.Close()
		}
		cancel()
		closeClient()
		return MediaItem{}, e
	}
	if err != nil {
		var b *usersecrets.Blocked
		if errors.As(err, &b) {
			return fail(apperr.Invalid("url", "%s", b.Reason))
		}
		return fail(apperr.Conflict("couldn't fetch media: %v", err))
	}
	if res.StatusCode != http.StatusOK {
		return fail(apperr.Conflict("media server returned HTTP %d", res.StatusCode))
	}
	contentType, err := videoContentType(res.Header.Get("Content-Type"), res.Request.URL)
	if err != nil {
		return fail(err)
	}
	var total *int64
	if res.ContentLength >= 0 {
		if res.ContentLength > m.maxBytes() {
			return fail(apperr.Invalid("url", "video is %d MB, over the %d MB limit", res.ContentLength>>20, m.maxBytes()>>20))
		}
		n := res.ContentLength
		total = &n
	}

	id := uuid.New()
	key := fmt.Sprintf("%s/%s/%s", mediaBlobPrefix, appID, id)
	row, err := store.New(m.Pool).InsertCustomAppMedia(ctx, store.InsertCustomAppMediaParams{
		AppID:       appID,
		SourceUrl:   u.String(),
		BlobKey:     key,
		ContentType: contentType,
		BytesTotal:  total,
	})
	if err != nil {
		return fail(err)
	}

	m.mu.Lock()
	if m.active == nil {
		m.active = map[uuid.UUID]context.CancelFunc{}
	}
	m.active[row.ID] = cancel
	m.mu.Unlock()
	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		defer closeClient()
		defer cancel()
		defer func() {
			m.mu.Lock()
			delete(m.active, row.ID)
			m.mu.Unlock()
		}()
		m.download(dlCtx, row, res)
	}()
	return mediaItemFrom(row), nil
}

// download streams the response into the blob store and records the outcome.
func (m *Media) download(ctx context.Context, row store.CustomAppMedium, res *http.Response) {
	defer res.Body.Close()
	q := store.New(m.Pool)
	counter := &countingReader{r: res.Body}
	stopProgress := m.reportProgress(ctx, q, row.ID, counter)

	err := m.store(ctx, row, counter)
	stopProgress()
	// Record the outcome even if the download was canceled.
	finishCtx := context.WithoutCancel(ctx)
	if err != nil {
		_ = m.Blobs.Delete(finishCtx, m.Bucket, row.BlobKey)
		_, _ = q.FinishCustomAppMedia(finishCtx, store.FinishCustomAppMediaParams{
			ID: row.ID, State: "failed", BytesDone: counter.n.Load(), Error: truncate(err.Error(), 400),
		})
		return
	}
	n, err := q.FinishCustomAppMedia(finishCtx, store.FinishCustomAppMediaParams{
		ID: row.ID, State: "done", BytesDone: counter.n.Load(),
	})
	if err != nil || n == 0 {
		// The row was deleted (or the app was) while downloading: drop the file.
		_ = m.Blobs.Delete(finishCtx, m.Bucket, row.BlobKey)
	}
}

// store writes the body to the blob store. Put needs the exact size, so a
// response without Content-Length is spooled to a temporary file first.
func (m *Media) store(ctx context.Context, row store.CustomAppMedium, body io.Reader) error {
	limit := m.maxBytes()
	if row.BytesTotal != nil {
		return m.Blobs.Put(ctx, m.Bucket, row.BlobKey, body, *row.BytesTotal, row.ContentType)
	}
	tmp, err := os.CreateTemp("", "vesper-media-*")
	if err != nil {
		return err
	}
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmp.Name())
	}()
	n, err := io.Copy(tmp, io.LimitReader(body, limit+1))
	if err != nil {
		return err
	}
	if n > limit {
		return fmt.Errorf("video is over the %d MB limit", limit>>20)
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return err
	}
	return m.Blobs.Put(ctx, m.Bucket, row.BlobKey, tmp, n, row.ContentType)
}

func (m *Media) reportProgress(ctx context.Context, q *store.Queries, id uuid.UUID, c *countingReader) (stop func()) {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(mediaProgressEvery)
		defer t.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				return
			case <-t.C:
				_ = q.SetCustomAppMediaProgress(ctx, store.SetCustomAppMediaProgressParams{ID: id, BytesDone: c.n.Load()})
			}
		}
	}()
	return func() {
		close(done)
		wg.Wait()
	}
}

// Status reports one download. A row left "downloading" with no download
// running in this process was interrupted by a restart, and is marked failed.
func (m *Media) Status(ctx context.Context, appID, id uuid.UUID) (MediaItem, error) {
	if m == nil || m.Pool == nil {
		return MediaItem{}, errors.New("media downloads are unavailable")
	}
	q := store.New(m.Pool)
	row, err := q.GetCustomAppMedia(ctx, store.GetCustomAppMediaParams{ID: id, AppID: appID})
	if errors.Is(err, pgx.ErrNoRows) {
		return MediaItem{}, apperr.ErrNotFound
	}
	if err != nil {
		return MediaItem{}, err
	}
	if row.State == "downloading" && !m.isActive(id) {
		if _, err := q.FinishCustomAppMedia(ctx, store.FinishCustomAppMediaParams{
			ID: id, State: "failed", BytesDone: row.BytesDone, Error: mediaInterruptedText,
		}); err != nil {
			return MediaItem{}, err
		}
		_ = m.Blobs.Delete(ctx, m.Bucket, row.BlobKey)
		row.State, row.Error = "failed", mediaInterruptedText
	}
	return mediaItemFrom(row), nil
}

// Playable returns a finished download for serving.
func (m *Media) Playable(ctx context.Context, appID, id uuid.UUID) (item MediaItem, blobKey string, size int64, err error) {
	item, err = m.Status(ctx, appID, id)
	if err != nil {
		return MediaItem{}, "", 0, err
	}
	if item.State != "done" {
		return MediaItem{}, "", 0, apperr.ErrNotFound
	}
	return item, item.blobKey, item.BytesDone, nil
}

// Delete stops a download if it's running and removes the row and file.
func (m *Media) Delete(ctx context.Context, appID, id uuid.UUID) error {
	if m == nil || m.Pool == nil {
		return errors.New("media downloads are unavailable")
	}
	m.cancel(id)
	key, err := store.New(m.Pool).DeleteCustomAppMedia(ctx, store.DeleteCustomAppMediaParams{ID: id, AppID: appID})
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound
	}
	if err != nil {
		return err
	}
	return m.Blobs.Delete(ctx, m.Bucket, key)
}

// forget stops downloads whose rows are gone (their app was deleted) and removes
// their files, best effort.
func (m *Media) forget(ctx context.Context, rows []store.ListCustomAppMediaBlobKeysRow) {
	if m == nil {
		return
	}
	for _, r := range rows {
		m.cancel(r.ID)
		if m.Blobs != nil {
			_ = m.Blobs.Delete(ctx, m.Bucket, r.BlobKey)
		}
	}
}

// Close cancels running downloads and waits for them to record their outcome.
func (m *Media) Close() {
	m.mu.Lock()
	for _, cancel := range m.active {
		cancel()
	}
	m.mu.Unlock()
	m.wg.Wait()
}

func (m *Media) isActive(id uuid.UUID) bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	_, ok := m.active[id]
	return ok
}

func (m *Media) cancel(id uuid.UUID) {
	m.mu.Lock()
	cancel := m.active[id]
	m.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

type countingReader struct {
	r io.Reader
	n atomic.Int64
}

func (c *countingReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	c.n.Add(int64(n))
	return n, err
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}

// handleMediaRPC serves server.ts's media.download/status/delete. Only starting
// a download needs app.media:download; status and delete touch only this app's
// own downloads, so cleanup still works after the permission is revoked.
func handleMediaRPC(ctx context.Context, mc *MCPCallContext, method string, raw json.RawMessage) (any, error) {
	var in struct {
		URL string `json:"url"`
		ID  string `json:"id"`
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return nil, err
	}
	if mc.Media == nil || mc.AppID == uuid.Nil {
		return nil, errors.New("media downloads are unavailable")
	}
	if method == "media_download" {
		if err := checkWorkerCapability(ctx, mc, "app.media:download", fmt.Sprintf("Download video %s into Vesper", strings.TrimSpace(in.URL))); err != nil {
			return nil, err
		}
		return mc.Media.Start(ctx, mc.AppID, in.URL)
	}
	id, err := uuid.Parse(strings.TrimSpace(in.ID))
	if err != nil {
		return nil, apperr.Invalid("id", "invalid media id")
	}
	if method == "media_status" {
		return mc.Media.Status(ctx, mc.AppID, id)
	}
	if err := mc.Media.Delete(ctx, mc.AppID, id); err != nil {
		return nil, err
	}
	return map[string]any{"deleted": id}, nil
}

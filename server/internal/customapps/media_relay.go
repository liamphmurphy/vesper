package customapps

import (
	"context"
	"errors"
	"fmt"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

const (
	maxMediaRelaysPerApp = 4
	maxMediaRelaysTotal  = 16
	defaultMediaRelayTTL = 30 * time.Minute
)

// MediaRangeOpener opens a whole media file (partial=false) or inclusive byte
// range [start, end] (partial=true), returning apperr.ErrNotFound when missing.
type MediaRangeOpener func(ctx context.Context, start, end int64, partial bool) (io.ReadCloser, error)

// RelayedMedia is the public metadata for an active LAN relay of a downloaded
// custom-app media file, enabling AirPlay and remote playback without exposing
// Vesper's authenticated loopback API on the local network.
type RelayedMedia struct {
	ID          uuid.UUID `json:"id"`
	MediaID     uuid.UUID `json:"media_id"`
	LANURL      string    `json:"lan_url"`
	LoopbackURL string    `json:"loopback_url"`
	ContentType string    `json:"content_type"`
	CreatedAt   time.Time `json:"created_at"`
}

type relayMedia struct {
	id          uuid.UUID
	token       string
	appID       uuid.UUID
	mediaID     uuid.UUID
	open        MediaRangeOpener
	contentType string
	size        int64
	ext         string
	createdAt   time.Time
	lastAccess  atomic.Int64
}

func (r *HLSRelay) mediaRelayTTL() time.Duration {
	if r.StreamTTL > 0 {
		return r.StreamTTL
	}
	return defaultMediaRelayTTL
}

// StartMedia registers a downloaded media file on the ephemeral LAN listener so
// AirPlay receivers (which fetch directly over the LAN without cookies) can
// play it with byte-range seeking.
func (r *HLSRelay) StartMedia(
	_ context.Context,
	appID, mediaID uuid.UUID,
	contentType string,
	size int64,
	open MediaRangeOpener,
) (RelayedMedia, error) {
	if r == nil {
		return RelayedMedia{}, errors.New("media relay is unavailable")
	}
	if open == nil || size < 0 {
		return RelayedMedia{}, apperr.Invalid("media", "media content is unavailable")
	}
	token, err := randomHex(16)
	if err != nil {
		return RelayedMedia{}, fmt.Errorf("generate media relay token: %w", err)
	}
	ct := strings.TrimSpace(contentType)
	if ct == "" {
		ct = "video/mp4"
	}
	now := time.Now().UTC()
	entry := &relayMedia{
		id:          uuid.New(),
		token:       token,
		appID:       appID,
		mediaID:     mediaID,
		open:        open,
		contentType: ct,
		size:        size,
		ext:         mediaExtensionForContentType(ct),
		createdAt:   now,
	}
	entry.lastAccess.Store(now.UnixNano())

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return RelayedMedia{}, errors.New("media relay is closed")
	}
	if r.media == nil {
		r.media = make(map[uuid.UUID]*relayMedia)
		r.mediaByToken = make(map[string]*relayMedia)
	}
	r.evictMediaOverflowLocked(appID)
	if err := r.ensureListenerLocked(); err != nil {
		r.mu.Unlock()
		return RelayedMedia{}, err
	}
	r.media[entry.id] = entry
	r.mediaByToken[entry.token] = entry
	port := r.port
	r.mu.Unlock()

	return r.mediaSnapshot(entry, port), nil
}

// StopMedia removes one active local media relay owned by appID and shuts down
// the LAN listener if no HLS streams or media relays remain.
func (r *HLSRelay) StopMedia(appID, id uuid.UUID) error {
	if r == nil {
		return apperr.ErrNotFound
	}
	r.mu.Lock()
	entry := r.media[id]
	if entry == nil || entry.appID != appID {
		r.mu.Unlock()
		return apperr.ErrNotFound
	}
	delete(r.media, id)
	delete(r.mediaByToken, entry.token)
	oldSrv, oldStop := r.detachIdleListenerLocked()
	r.mu.Unlock()

	shutdownRelayListener(oldSrv, oldStop)
	return nil
}

func (r *HLSRelay) mediaSnapshot(entry *relayMedia, port int) RelayedMedia {
	lanIP := r.lanIP()
	path := fmt.Sprintf("/media/%s/video%s", entry.token, entry.ext)
	return RelayedMedia{
		ID:          entry.id,
		MediaID:     entry.mediaID,
		LANURL:      fmt.Sprintf("http://%s:%d%s", lanIP, port, path),
		LoopbackURL: fmt.Sprintf("http://127.0.0.1:%d%s", port, path),
		ContentType: entry.contentType,
		CreatedAt:   entry.createdAt,
	}
}

func (r *HLSRelay) evictMediaOverflowLocked(appID uuid.UUID) {
	for {
		var appCount int
		var oldestApp *relayMedia
		for _, m := range r.media {
			if m.appID == appID {
				appCount++
				if oldestApp == nil || m.lastAccess.Load() < oldestApp.lastAccess.Load() {
					oldestApp = m
				}
			}
		}
		if appCount < maxMediaRelaysPerApp || oldestApp == nil {
			break
		}
		delete(r.media, oldestApp.id)
		delete(r.mediaByToken, oldestApp.token)
	}
	for len(r.media) >= maxMediaRelaysTotal {
		var oldest *relayMedia
		for _, m := range r.media {
			if oldest == nil || m.lastAccess.Load() < oldest.lastAccess.Load() {
				oldest = m
			}
		}
		if oldest == nil {
			break
		}
		delete(r.media, oldest.id)
		delete(r.mediaByToken, oldest.token)
	}
}

func (r *HLSRelay) lookupMediaByToken(token string) *relayMedia {
	if token == "" {
		return nil
	}
	r.mu.Lock()
	entry := r.mediaByToken[token]
	r.mu.Unlock()
	if entry != nil {
		entry.lastAccess.Store(time.Now().UnixNano())
	}
	return entry
}

func (r *HLSRelay) serveMediaHTTP(w http.ResponseWriter, req *http.Request) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Range")
	w.Header().Set("Access-Control-Expose-Headers", "Content-Length, Content-Range, Accept-Ranges")
	w.Header().Set("Cache-Control", "no-store")
	if req.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if req.Method != http.MethodGet && req.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	rest := strings.TrimPrefix(req.URL.Path, "/media/")
	parts := strings.Split(rest, "/")
	if len(parts) != 2 {
		http.NotFound(w, req)
		return
	}
	entry := r.lookupMediaByToken(parts[0])
	if entry == nil || parts[1] != "video"+entry.ext {
		http.NotFound(w, req)
		return
	}

	start, end, partial, ok := parseRelayByteRange(req.Header.Get("Range"), entry.size)
	if !ok {
		w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", entry.size))
		http.Error(w, "range not satisfiable", http.StatusRequestedRangeNotSatisfiable)
		return
	}

	// Open the requested range (or a 1-byte probe on HEAD) so deleted media returns 404.
	var body io.ReadCloser
	var err error
	switch {
	case req.Method == http.MethodHead && entry.size > 0:
		body, err = entry.open(req.Context(), 0, 0, true)
	case partial:
		body, err = entry.open(req.Context(), start, end, true)
	default:
		body, err = entry.open(req.Context(), 0, entry.size-1, false)
	}
	if errors.Is(err, apperr.ErrNotFound) {
		http.NotFound(w, req)
		return
	}
	if err != nil {
		http.Error(w, "failed to read media", http.StatusInternalServerError)
		return
	}
	defer body.Close()

	w.Header().Set("Content-Type", entry.contentType)
	w.Header().Set("Accept-Ranges", "bytes")
	if partial {
		length := end - start + 1
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, entry.size))
		w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
		w.WriteHeader(http.StatusPartialContent)
	} else {
		w.Header().Set("Content-Length", strconv.FormatInt(entry.size, 10))
		w.WriteHeader(http.StatusOK)
	}
	if req.Method == http.MethodHead {
		return
	}
	_, _ = io.Copy(w, body)
}

func parseRelayByteRange(h string, size int64) (start, end int64, partial, ok bool) {
	spec, found := strings.CutPrefix(strings.TrimSpace(h), "bytes=")
	if !found || strings.Contains(spec, ",") {
		return 0, size - 1, false, true
	}
	if size <= 0 {
		return 0, 0, false, false
	}
	first, last, found := strings.Cut(strings.TrimSpace(spec), "-")
	if !found {
		return 0, size - 1, false, true
	}
	if first == "" {
		n, err := strconv.ParseInt(last, 10, 64)
		if err != nil || n <= 0 {
			return 0, 0, false, false
		}
		if n > size {
			n = size
		}
		return size - n, size - 1, true, true
	}
	a, err := strconv.ParseInt(first, 10, 64)
	if err != nil || a < 0 || a >= size {
		return 0, 0, false, false
	}
	b := size - 1
	if last != "" {
		b, err = strconv.ParseInt(last, 10, 64)
		if err != nil || b < a {
			return 0, 0, false, false
		}
		if b >= size {
			b = size - 1
		}
	}
	return a, b, true, true
}

func mediaExtensionForContentType(contentType string) string {
	mediaType, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		mediaType = strings.TrimSpace(contentType)
	}
	switch strings.ToLower(mediaType) {
	case "video/mp4":
		return ".mp4"
	case "video/quicktime":
		return ".mov"
	case "video/x-m4v":
		return ".m4v"
	case "video/webm":
		return ".webm"
	case "video/ogg":
		return ".ogv"
	case "video/mp2t":
		return ".ts"
	case "video/x-matroska":
		return ".mkv"
	default:
		return ".mp4"
	}
}

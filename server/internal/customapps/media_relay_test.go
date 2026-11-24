package customapps

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

func memMediaOpener(mu *sync.Mutex, data *[]byte) MediaRangeOpener {
	return func(_ context.Context, start, end int64, partial bool) (io.ReadCloser, error) {
		mu.Lock()
		b := *data
		mu.Unlock()
		if b == nil {
			return nil, apperr.ErrNotFound
		}
		if !partial {
			return io.NopCloser(bytes.NewReader(b)), nil
		}
		if start < 0 || start >= int64(len(b)) {
			return nil, apperr.ErrNotFound
		}
		if end >= int64(len(b)) {
			end = int64(len(b)) - 1
		}
		return io.NopCloser(bytes.NewReader(b[start : end+1])), nil
	}
}

func TestMediaRelayRangeHeadAndLifecycle(t *testing.T) {
	var mu sync.Mutex
	payload := []byte("0123456789abcdef")

	relay := &HLSRelay{
		ListenAddr: "127.0.0.1:0",
		LANIPFunc:  func() string { return "192.168.1.42" },
	}
	t.Cleanup(relay.Close)

	appID := uuid.New()
	mediaID := uuid.New()
	got, err := relay.StartMedia(context.Background(), appID, mediaID, "video/mp4", int64(len(payload)), memMediaOpener(&mu, &payload))
	if err != nil {
		t.Fatalf("StartMedia: %v", err)
	}
	if got.MediaID != mediaID || got.ContentType != "video/mp4" {
		t.Fatalf("unexpected metadata: %+v", got)
	}
	if !strings.HasPrefix(got.LANURL, "http://192.168.1.42:") || !strings.HasSuffix(got.LANURL, "/video.mp4") {
		t.Fatalf("unexpected LANURL = %q", got.LANURL)
	}
	if !strings.HasPrefix(got.LoopbackURL, "http://127.0.0.1:") || !strings.HasSuffix(got.LoopbackURL, "/video.mp4") {
		t.Fatalf("unexpected LoopbackURL = %q", got.LoopbackURL)
	}

	// Full GET.
	res, err := http.Get(got.LoopbackURL)
	if err != nil {
		t.Fatalf("GET full: %v", err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || string(body) != string(payload) {
		t.Fatalf("GET full = %d %q, want 200 %q", res.StatusCode, body, payload)
	}
	if res.Header.Get("Accept-Ranges") != "bytes" || res.Header.Get("Content-Type") != "video/mp4" {
		t.Fatalf("headers: Accept-Ranges=%q Content-Type=%q", res.Header.Get("Accept-Ranges"), res.Header.Get("Content-Type"))
	}

	// HEAD request (used by AirPlay/AVPlayer probes).
	headReq, _ := http.NewRequest(http.MethodHead, got.LoopbackURL, nil)
	res, err = http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD: %v", err)
	}
	headBody, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || len(headBody) != 0 || res.Header.Get("Content-Length") != "16" || res.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("HEAD = %d len=%d CL=%q AR=%q", res.StatusCode, len(headBody), res.Header.Get("Content-Length"), res.Header.Get("Accept-Ranges"))
	}

	// Byte-range requests: explicit, open-ended, suffix.
	for _, tc := range []struct {
		hdr  string
		want string
		cr   string
	}{
		{"bytes=0-1", "01", "bytes 0-1/16"},
		{"bytes=4-7", "4567", "bytes 4-7/16"},
		{"bytes=12-", "cdef", "bytes 12-15/16"},
		{"bytes=-4", "cdef", "bytes 12-15/16"},
	} {
		req, _ := http.NewRequest(http.MethodGet, got.LoopbackURL, nil)
		req.Header.Set("Range", tc.hdr)
		res, err = http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("GET %s: %v", tc.hdr, err)
		}
		b, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != http.StatusPartialContent || string(b) != tc.want || res.Header.Get("Content-Range") != tc.cr {
			t.Fatalf("Range %s: got %d %q CR=%q, want 206 %q CR=%q", tc.hdr, res.StatusCode, b, res.Header.Get("Content-Range"), tc.want, tc.cr)
		}
	}

	// Unsatisfiable range returns 416.
	badRangeReq, _ := http.NewRequest(http.MethodGet, got.LoopbackURL, nil)
	badRangeReq.Header.Set("Range", "bytes=99-120")
	res, err = http.DefaultClient.Do(badRangeReq)
	if err != nil {
		t.Fatalf("GET 416: %v", err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusRequestedRangeNotSatisfiable || res.Header.Get("Content-Range") != "bytes */16" {
		t.Fatalf("unsatisfiable range = %d CR=%q", res.StatusCode, res.Header.Get("Content-Range"))
	}

	// Unknown token or wrong filename returns 404.
	for _, u := range []string{
		strings.Replace(got.LoopbackURL, "/video.mp4", "/other.mp4", 1),
		got.LoopbackURL[:strings.Index(got.LoopbackURL, "/media/")] + "/media/deadbeef/video.mp4",
	} {
		res, err = http.Get(u)
		if err != nil {
			t.Fatalf("GET %s: %v", u, err)
		}
		res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Fatalf("GET %s = %d, want 404", u, res.StatusCode)
		}
	}

	// Deleted underlying blob returns 404 on HEAD.
	mu.Lock()
	payload = nil
	mu.Unlock()
	res, err = http.DefaultClient.Do(headReq)
	if err != nil {
		t.Fatalf("HEAD deleted: %v", err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusNotFound {
		t.Fatalf("HEAD deleted = %d, want 404", res.StatusCode)
	}

	// Another app cannot stop this relay.
	if err := relay.StopMedia(uuid.New(), got.ID); err == nil {
		t.Fatal("StopMedia by wrong app succeeded, want error")
	}

	// Stopping the last relay shuts down the ephemeral listener.
	if err := relay.StopMedia(appID, got.ID); err != nil {
		t.Fatalf("StopMedia: %v", err)
	}
	relay.mu.Lock()
	srvNil := relay.srv == nil
	relay.mu.Unlock()
	if !srvNil {
		t.Fatal("expected LAN listener to shut down after stopping the last media relay")
	}
}

func TestMediaRelayIdleExpiry(t *testing.T) {
	var mu sync.Mutex
	payload := []byte("abcd")
	relay := &HLSRelay{
		ListenAddr: "127.0.0.1:0",
		StreamTTL:  80 * time.Millisecond,
	}
	t.Cleanup(relay.Close)

	got, err := relay.StartMedia(context.Background(), uuid.New(), uuid.New(), "video/quicktime", 4, memMediaOpener(&mu, &payload))
	if err != nil {
		t.Fatalf("StartMedia: %v", err)
	}
	if !strings.HasSuffix(got.LoopbackURL, "/video.mov") {
		t.Fatalf("expected .mov extension, got %q", got.LoopbackURL)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		relay.mu.Lock()
		empty := len(relay.media) == 0 && relay.srv == nil
		relay.mu.Unlock()
		if empty {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("media relay did not expire and close its listener")
}

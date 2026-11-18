package blob_test

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
)

func TestLocalDirRoundTripAndEdgeCases(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "blobs")
	s := blob.New(config.Blob{Dir: dir, Buckets: []string{"artifacts", "run-logs"}})
	ctx := context.Background()

	if err := s.EnsureBuckets(ctx); err != nil {
		t.Fatal(err)
	}
	if err := s.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}

	buckets, err := s.ListBuckets(ctx)
	if err != nil || !slices.Equal(buckets, []string{"artifacts", "run-logs"}) {
		t.Fatalf("ListBuckets = %v, %v", buckets, err)
	}

	cases := map[string]struct {
		ct   string
		body []byte
	}{
		"a":                             {ct: "text/plain", body: []byte("file-a")},
		"a/b":                           {ct: "text/plain", body: []byte("file-a-b")},
		"Foo":                           {ct: "text/plain", body: []byte("upper")},
		"foo":                           {ct: "text/plain", body: []byte("lower")},
		"weird/../key with spaces?.txt": {ct: "text/plain", body: []byte("weird")},
		"with space/ü.txt":              {ct: "application/octet-stream", body: []byte("unicode")},
		"empty.bin":                     {ct: "application/octet-stream", body: []byte{}},
		strings.Repeat("long-", 80):     {ct: "text/plain", body: []byte("long-key")},
	}
	for k, tc := range cases {
		if err := s.Put(ctx, "artifacts", k, bytes.NewReader(tc.body), int64(len(tc.body)), tc.ct); err != nil {
			t.Fatalf("put %q: %v", k, err)
		}
	}

	// Verify exact key, size, content type, and content for every case.
	for k, tc := range cases {
		o, err := s.Get(ctx, "artifacts", k)
		if err != nil {
			t.Fatalf("get %q: %v", k, err)
		}
		got, err := io.ReadAll(o.Body)
		o.Body.Close()
		if err != nil || !bytes.Equal(got, tc.body) || o.ContentType != tc.ct || o.ContentLength != int64(len(tc.body)) {
			t.Fatalf("get %q = (%q, %q, %d, %v)", k, got, o.ContentType, o.ContentLength, err)
		}
	}

	// List must return all keys in sorted order with exact lengths.
	var listed []blob.Info
	if err := s.List(ctx, "artifacts", func(i blob.Info) error {
		listed = append(listed, i)
		return nil
	}); err != nil {
		t.Fatalf("list: %v", err)
	}
	if len(listed) != len(cases) {
		t.Fatalf("listed %d items, want %d: %+v", len(listed), len(cases), listed)
	}
	for i, info := range listed {
		if i > 0 && listed[i-1].Key >= info.Key {
			t.Fatalf("list not sorted: %+v", listed)
		}
		tc, ok := cases[info.Key]
		if !ok || info.Size != int64(len(tc.body)) {
			t.Fatalf("listed entry %+v unexpected", info)
		}
	}

	// GetRange inclusive slicing.
	payload := []byte("0123456789")
	if err := s.Put(ctx, "artifacts", "range.bin", bytes.NewReader(payload), int64(len(payload)), "application/octet-stream"); err != nil {
		t.Fatal(err)
	}
	r, err := s.GetRange(ctx, "artifacts", "range.bin", 2, 5)
	if err != nil {
		t.Fatal(err)
	}
	gotRange, _ := io.ReadAll(r.Body)
	r.Body.Close()
	if string(gotRange) != "2345" || r.ContentLength != 4 {
		t.Fatalf("range = %q len=%d", gotRange, r.ContentLength)
	}
	// Clamped end past EOF matches HTTP/S3 inclusive range behavior.
	r2, err := s.GetRange(ctx, "artifacts", "range.bin", 8, 999)
	if err != nil {
		t.Fatal(err)
	}
	gotRange2, _ := io.ReadAll(r2.Body)
	r2.Body.Close()
	if string(gotRange2) != "89" || r2.ContentLength != 2 {
		t.Fatalf("clamped range = %q len=%d", gotRange2, r2.ContentLength)
	}

	// Delete missing key is a no-op; delete existing removes it.
	if err := s.Delete(ctx, "artifacts", "never-existed"); err != nil {
		t.Fatalf("delete missing: %v", err)
	}
	if err := s.Delete(ctx, "artifacts", "range.bin"); err != nil {
		t.Fatalf("delete existing: %v", err)
	}
	if _, err := s.Get(ctx, "artifacts", "range.bin"); !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("after delete: %v", err)
	}

	// Listing a nonexistent bucket returns ErrNotFound.
	if err := s.List(ctx, "no-such-bucket", func(blob.Info) error { return nil }); !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("missing bucket list = %v, want ErrNotFound", err)
	}

	// Size mismatch must fail without storing partial data.
	if err := s.Put(ctx, "artifacts", "short", strings.NewReader("abc"), 10, "text/plain"); err == nil {
		t.Fatal("expected size mismatch error on short body")
	}
	if _, err := s.Get(ctx, "artifacts", "short"); !errors.Is(err, blob.ErrNotFound) {
		t.Fatalf("short body left object behind: %v", err)
	}

	// Invalid bucket traversal is rejected.
	for _, bad := range []string{"", ".", "..", ".tmp", "a/b", `a\b`} {
		if err := s.EnsureBucket(ctx, bad); err == nil {
			t.Errorf("accepted bad bucket %q", bad)
		}
	}

	// No temp files leaked in .tmp.
	tmpEntries, err := os.ReadDir(filepath.Join(dir, ".tmp"))
	if err != nil || len(tmpEntries) != 0 {
		t.Fatalf(".tmp entries = %v, err = %v", tmpEntries, err)
	}
}

func TestLocalDirConcurrentPutGet(t *testing.T) {
	s := blob.NewDir(t.TempDir(), []string{"concurrent"})
	ctx := context.Background()
	if err := s.EnsureBuckets(ctx); err != nil {
		t.Fatal(err)
	}
	var wg sync.WaitGroup
	errs := make(chan error, 32)
	for i := range 32 {
		wg.Go(func() {
			key := fmt.Sprintf("item/%d", i%8)
			body := fmt.Sprintf("payload-%02d", i)
			if err := s.Put(ctx, "concurrent", key, strings.NewReader(body), int64(len(body)), "text/plain"); err != nil {
				errs <- err
				return
			}
			o, err := s.Get(ctx, "concurrent", key)
			if err != nil {
				errs <- err
				return
			}
			b, err := io.ReadAll(o.Body)
			o.Body.Close()
			if err != nil || !strings.HasPrefix(string(b), "payload-") {
				errs <- fmt.Errorf("bad body %q err=%v", b, err)
			}
		})
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		t.Fatal(err)
	}
}

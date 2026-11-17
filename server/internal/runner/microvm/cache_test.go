package microvm

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

func TestCacheStorePullThroughIsStrictlyDownward(t *testing.T) {
	var goHits, npmHits, nixHits, ociHits atomic.Int32
	blobData := []byte("oci-layer-bytes")
	blobSum := sha256.Sum256(blobData)
	blobDigest := "sha256:" + hex.EncodeToString(blobSum[:])

	var upstreamURL string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/goproxy/example.com/mod/@v/v1.0.0.info":
			goHits.Add(1)
			_, _ = io.WriteString(w, `{"Version":"v1.0.0"}`)
		case r.URL.Path == "/npm/is-odd":
			npmHits.Add(1)
			_, _ = io.WriteString(w, `{"tarball":"`+upstreamURL+`/npm/is-odd/-/is-odd-3.0.1.tgz"}`)
		case r.URL.Path == "/nix/abc.narinfo":
			nixHits.Add(1)
			_, _ = io.WriteString(w, "StorePath: /nix/store/abc-hello\nNarHash: sha256:0000\nNarSize: 12\n")
		case r.URL.Path == "/v2/library/alpine/blobs/"+blobDigest:
			ociHits.Add(1)
			_, _ = w.Write(blobData)
		default:
			http.NotFound(w, r)
		}
	}))
	defer upstream.Close()
	upstreamURL = upstream.URL

	cs, err := NewCacheStore(CacheStoreConfig{
		Dir:         t.TempDir(),
		GoUpstream:  upstream.URL + "/goproxy",
		NPMUpstream: upstream.URL + "/npm",
		NixUpstream: upstream.URL + "/nix",
		OCIUpstream: upstream.URL,
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(cs.NixPublicKey(), "vesper-cache-1:") {
		t.Fatalf("unexpected nix pub key: %s", cs.NixPublicKey())
	}

	eg := NewEgress(EgressConfig{CacheHandler: cs})
	defer eg.Close()

	// Helper invoking CacheStore directly.
	get := func(method, p string) (int, string, http.Header) {
		req := httptest.NewRequest(method, "http://"+InternalCacheHost+p, nil)
		rec := httptest.NewRecorder()
		cs.ServeHTTP(rec, req)
		return rec.Code, rec.Body.String(), rec.Header()
	}

	// Write methods rejected (strictly downward).
	for _, m := range []string{http.MethodPut, http.MethodPost, http.MethodDelete} {
		code, _, _ := get(m, "/goproxy/evil")
		if code != http.StatusMethodNotAllowed {
			t.Fatalf("%s status=%d, want 405", m, code)
		}
	}

	// Go proxy miss then cache hit.
	if code, body, h := get("GET", "/goproxy/example.com/mod/@v/v1.0.0.info"); code != 200 || h.Get("X-Vesper-Cache") != "MISS" || body == "" {
		t.Fatalf("goproxy first: %d %s %v", code, body, h)
	}
	if code, _, h := get("GET", "/goproxy/example.com/mod/@v/v1.0.0.info"); code != 200 || h.Get("X-Vesper-Cache") != "HIT" {
		t.Fatalf("goproxy second: %d %v", code, h)
	}
	if goHits.Load() != 1 {
		t.Fatalf("expected 1 upstream go hit, got %d", goHits.Load())
	}

	// npm metadata rewrites tarball URLs to http://cache.vesper.internal/npm/...
	if code, body, _ := get("GET", "/npm/is-odd"); code != 200 || !strings.Contains(body, "http://"+InternalCacheHost+"/npm/is-odd/-/is-odd-3.0.1.tgz") {
		t.Fatalf("npm rewrite failed: %d %s", code, body)
	}
	if npmHits.Load() != 1 {
		t.Fatalf("npm hits = %d", npmHits.Load())
	}

	// Nix narinfo gets signed by host ed25519 cache key.
	if code, body, _ := get("GET", "/nix/abc.narinfo"); code != 200 || !strings.Contains(body, "Sig: vesper-cache-1:") {
		t.Fatalf("nix narinfo signature missing: %d %s", code, body)
	}
	if nixHits.Load() != 1 {
		t.Fatalf("nix hits = %d", nixHits.Load())
	}

	// OCI blob caches cleanly after sha256 verification.
	if code, body, h := get("GET", "/v2/library/alpine/blobs/"+blobDigest); code != 200 || !bytes.Equal([]byte(body), blobData) || h.Get("X-Vesper-Cache") != "MISS" {
		t.Fatalf("oci miss: %d %q %v", code, body, h)
	}
	if code, _, h := get("GET", "/v2/library/alpine/blobs/"+blobDigest); code != 200 || h.Get("X-Vesper-Cache") != "HIT" {
		t.Fatalf("oci hit: %d %v", code, h)
	}
	if ociHits.Load() != 1 {
		t.Fatalf("oci hits = %d", ociHits.Load())
	}

	// Bad path traversal rejected cleanly.
	if code, _, _ := get("GET", "/goproxy/../../etc/passwd"); code != http.StatusBadRequest && code != http.StatusNotFound {
		t.Fatalf("expected bad traversal status, got %d", code)
	}
	_ = context.Background()
}

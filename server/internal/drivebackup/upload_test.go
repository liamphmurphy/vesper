package drivebackup

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

// fakeDrive is enough of Drive v3 for resumable uploads, listing and deleting.
type fakeDrive struct {
	t   *testing.T
	srv *httptest.Server

	mu        sync.Mutex
	stored    []byte // the session's bytes so far
	total     int64  // -1 until a chunk says the size
	meta      map[string]any
	puts      []int // body size of every PUT
	maxPut    int
	tokens    []string
	cancelled bool
	// halfCommit makes the PUT with this index keep only half its bytes (on
	// a 256 KiB boundary), as Drive may.
	halfCommit int
	// failPut makes the PUT with this index fail with this status, keeping
	// nothing.
	failPut, failStatus int
	failBody            string
	startStatus         int
	files               []driveFile
	deleted             []string
	pageSize            int
	created             string // the uploaded file's ID
	// intercept answers a request itself when it returns true.
	intercept func(w http.ResponseWriter, r *http.Request) bool
}

func newFakeDrive(t *testing.T) *fakeDrive {
	d := &fakeDrive{t: t, total: -1, halfCommit: -1, failPut: -1, pageSize: 2}
	d.srv = httptest.NewServer(d)
	t.Cleanup(d.srv.Close)
	return d
}

func (d *fakeDrive) uploader() *Uploader {
	return &Uploader{
		Token:     func(context.Context) (string, error) { return "tok", nil },
		HTTP:      d.srv.Client(),
		BaseURL:   d.srv.URL,
		ChunkSize: chunkUnit,
		Sleep:     func(context.Context, time.Duration) error { return nil },
		Now:       func() time.Time { return time.Date(2026, 11, 15, 3, 0, 0, 0, time.UTC) },
	}
}

func (d *fakeDrive) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.tokens = append(d.tokens, r.Header.Get("Authorization"))
	if d.intercept != nil && d.intercept(w, r) {
		return
	}
	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/upload/drive/v3/files":
		if r.URL.Query().Get("uploadType") != "resumable" {
			http.Error(w, "not resumable", 400)
			return
		}
		if d.startStatus != 0 {
			w.WriteHeader(d.startStatus)
			_, _ = io.WriteString(w, `{"error":{"code":403,"message":"Insufficient Permission","errors":[{"reason":"insufficientPermissions"}]}}`)
			return
		}
		_ = json.NewDecoder(r.Body).Decode(&d.meta)
		w.Header().Set("Location", d.srv.URL+"/session/1")
	case r.URL.Path == "/session/1" && r.Method == http.MethodDelete:
		d.cancelled = true
		w.WriteHeader(499)
	case r.URL.Path == "/session/1" && r.Method == http.MethodPut:
		d.put(w, r)
	case r.Method == http.MethodGet && r.URL.Path == "/drive/v3/files":
		d.list(w, r)
	case r.Method == http.MethodDelete && strings.HasPrefix(r.URL.Path, "/drive/v3/files/"):
		id := strings.TrimPrefix(r.URL.Path, "/drive/v3/files/")
		d.deleted = append(d.deleted, id)
		d.files = slices.DeleteFunc(d.files, func(f driveFile) bool { return f.ID == id })
		w.WriteHeader(http.StatusNoContent)
	default:
		http.Error(w, "unexpected "+r.Method+" "+r.URL.Path, 400)
	}
}

func (d *fakeDrive) put(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)
	n := len(d.puts)
	d.puts = append(d.puts, len(body))
	d.maxPut = max(d.maxPut, len(body))
	cr := strings.TrimPrefix(r.Header.Get("Content-Range"), "bytes ")
	span, total, _ := strings.Cut(cr, "/")
	if total != "*" {
		d.total, _ = strconv.ParseInt(total, 10, 64)
	}
	if n == d.failPut {
		w.WriteHeader(d.failStatus)
		_, _ = io.WriteString(w, d.failBody)
		return
	}
	if span != "*" {
		a, b, _ := strings.Cut(span, "-")
		start, _ := strconv.ParseInt(a, 10, 64)
		end, _ := strconv.ParseInt(b, 10, 64)
		if start != int64(len(d.stored)) || end-start+1 != int64(len(body)) {
			d.t.Errorf("PUT %d: range %s, have %d bytes, body %d", n, cr, len(d.stored), len(body))
			http.Error(w, "bad range", 400)
			return
		}
		if total == "*" && len(body)%chunkUnit != 0 {
			d.t.Errorf("PUT %d: non-final chunk of %d bytes", n, len(body))
		}
		keep := body
		if n == d.halfCommit {
			keep = body[:len(body)/2/chunkUnit*chunkUnit]
		}
		d.stored = append(d.stored, keep...)
	}
	if d.total >= 0 && int64(len(d.stored)) == d.total {
		d.created = "new-file"
		d.files = append(d.files, driveFile{ID: d.created, Name: d.meta["name"].(string), CreatedTime: time.Date(2026, 11, 15, 3, 0, 1, 0, time.UTC)})
		w.WriteHeader(http.StatusCreated)
		_, _ = fmt.Fprintf(w, `{"id":%q}`, d.created)
		return
	}
	if len(d.stored) > 0 {
		w.Header().Set("Range", fmt.Sprintf("bytes=0-%d", len(d.stored)-1))
	}
	w.WriteHeader(http.StatusPermanentRedirect)
}

func (d *fakeDrive) list(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if want := "'folder1' in parents and name contains 'vesper-export-' and trashed = false"; q.Get("q") != want {
		d.t.Errorf("list q = %q", q.Get("q"))
	}
	from, _ := strconv.Atoi(q.Get("pageToken"))
	to := min(from+d.pageSize, len(d.files))
	out := map[string]any{"files": d.files[from:to]}
	if to < len(d.files) {
		out["nextPageToken"] = strconv.Itoa(to)
	}
	_ = json.NewEncoder(w).Encode(out)
}

// archive is an Exporter writing size random bytes in small writes.
type archive struct {
	data []byte
	err  error // returned after writing failAt bytes
	at   int
	// sentBy is how many bytes Drive had when the exporter was 3 chunks in.
	drive  *fakeDrive
	sentBy int
}

func newArchive(size int) *archive {
	b := make([]byte, size)
	r := rand.New(rand.NewPCG(1, 2))
	for i := range b {
		b[i] = byte(r.Uint32())
	}
	return &archive{data: b, at: -1}
}

func (a *archive) Export(ctx context.Context, w io.Writer) (*transfer.Manifest, error) {
	for off := 0; off < len(a.data); off += 4096 {
		if off == a.at {
			return nil, a.err
		}
		if off == 3*chunkUnit && a.drive != nil {
			a.drive.mu.Lock()
			a.sentBy = len(a.drive.stored)
			a.drive.mu.Unlock()
		}
		if _, err := w.Write(a.data[off:min(off+4096, len(a.data))]); err != nil {
			return nil, err
		}
	}
	return &transfer.Manifest{Format: transfer.FormatVersion}, nil
}

func TestUploadStreamsInChunks(t *testing.T) {
	d := newFakeDrive(t)
	d.halfCommit = 1                     // Drive keeps half of the second chunk
	d.failPut, d.failStatus = 3, 503     // and the fourth PUT fails once
	exp := newArchive(4*chunkUnit + 123) // five chunks, the last short
	exp.drive = d
	res, err := d.uploader().Upload(context.Background(), exp, "folder1", 0)
	if err != nil {
		t.Fatal(err)
	}
	if res.FileID != "new-file" || res.Name != "vesper-export-20261115T030000Z.zip" || res.Bytes != int64(len(exp.data)) || res.Manifest == nil {
		t.Fatalf("result = %+v", res)
	}
	if !bytes.Equal(d.stored, exp.data) {
		t.Fatal("Drive's bytes differ from the archive")
	}
	if d.meta["name"] != res.Name || d.meta["mimeType"] != "application/zip" || fmt.Sprint(d.meta["parents"]) != "[folder1]" {
		t.Fatalf("metadata = %v", d.meta)
	}
	if d.maxPut > chunkUnit {
		t.Fatalf("a PUT carried %d bytes, more than one chunk", d.maxPut)
	}
	if exp.sentBy == 0 {
		t.Fatal("nothing reached Drive before the export was three chunks in: the archive was buffered")
	}
	// 5 chunks + the resent half + the failed PUT, its status query and resend.
	if len(d.puts) < 8 {
		t.Fatalf("PUTs = %v", d.puts)
	}
	for _, tok := range d.tokens {
		if tok != "Bearer tok" {
			t.Fatalf("Authorization = %q", tok)
		}
	}
}

func TestUploadExactChunkMultiple(t *testing.T) {
	d := newFakeDrive(t)
	exp := newArchive(2 * chunkUnit)
	res, err := d.uploader().Upload(context.Background(), exp, "folder1", 0)
	if err != nil || res.Bytes != int64(len(exp.data)) || !bytes.Equal(d.stored, exp.data) {
		t.Fatalf("Upload = %+v, %v", res, err)
	}
	// Two full chunks, then an empty one that only states the size.
	if !slices.Equal(d.puts, []int{chunkUnit, chunkUnit, 0}) {
		t.Fatalf("PUTs = %v", d.puts)
	}
}

func TestUploadExportFails(t *testing.T) {
	d := newFakeDrive(t)
	d.files = []driveFile{{ID: "old", Name: "vesper-export-20200101T000000Z.zip"}}
	exp := newArchive(4 * chunkUnit)
	exp.at, exp.err = 2*chunkUnit+4096, errors.New("database went away")
	_, err := d.uploader().Upload(context.Background(), exp, "folder1", 1)
	if err == nil || !errors.Is(err, exp.err) || !strings.Contains(err.Error(), "export failed") {
		t.Fatalf("err = %v", err)
	}
	if !d.cancelled || d.created != "" {
		t.Fatalf("cancelled = %v, created = %q", d.cancelled, d.created)
	}
	if len(d.deleted) != 0 {
		t.Fatalf("pruned after a failed upload: %v", d.deleted)
	}
}

func TestUploadDriveFails(t *testing.T) {
	t.Run("chunk refused", func(t *testing.T) {
		d := newFakeDrive(t)
		d.files = []driveFile{{ID: "old", Name: "vesper-export-20200101T000000Z.zip"}}
		d.failPut, d.failStatus = 1, 403
		d.failBody = `{"error":{"code":403,"message":"The user's Drive storage quota has been exceeded.","errors":[{"reason":"storageQuotaExceeded"}]}}`
		_, err := d.uploader().Upload(context.Background(), newArchive(3*chunkUnit), "folder1", 1)
		var de *DriveError
		if !errors.As(err, &de) || de.Reason != "storageQuotaExceeded" || !strings.Contains(err.Error(), "quota") {
			t.Fatalf("err = %v", err)
		}
		if !d.cancelled || len(d.deleted) != 0 {
			t.Fatalf("cancelled = %v, deleted = %v", d.cancelled, d.deleted)
		}
	})
	t.Run("keeps failing", func(t *testing.T) {
		d := newFakeDrive(t)
		u := d.uploader()
		u.Retries = 2
		// Every PUT after the first is a status query or resend; make the
		// server fail them all.
		d.intercept = func(w http.ResponseWriter, r *http.Request) bool {
			if r.Method == http.MethodPut {
				w.WriteHeader(503)
				return true
			}
			return false
		}
		_, err := u.Upload(context.Background(), newArchive(chunkUnit+1), "folder1", 0)
		if err == nil || !strings.Contains(err.Error(), "503") || !d.cancelled {
			t.Fatalf("err = %v, cancelled = %v", err, d.cancelled)
		}
	})
	t.Run("no progress", func(t *testing.T) {
		d := newFakeDrive(t)
		puts := 0
		d.intercept = func(w http.ResponseWriter, r *http.Request) bool {
			if r.Method == http.MethodPut {
				puts++
				_, _ = io.Copy(io.Discard, r.Body)
				w.WriteHeader(http.StatusPermanentRedirect) // keeps nothing
				return true
			}
			return false
		}
		u := d.uploader()
		u.Retries = 3
		_, err := u.Upload(context.Background(), newArchive(chunkUnit+1), "folder1", 0)
		if err == nil || !strings.Contains(err.Error(), "refusing") || puts != 4 {
			t.Fatalf("err = %v after %d PUTs", err, puts)
		}
	})
	t.Run("session not started", func(t *testing.T) {
		d := newFakeDrive(t)
		d.startStatus = 403
		exp := newArchive(10)
		_, err := d.uploader().Upload(context.Background(), exp, "folder1", 0)
		if err == nil || !strings.Contains(err.Error(), "Insufficient Permission") {
			t.Fatalf("err = %v", err)
		}
	})
	t.Run("token fails", func(t *testing.T) {
		d := newFakeDrive(t)
		u := d.uploader()
		calls := 0
		u.Token = func(context.Context) (string, error) { calls++; return "", errors.New("needs signing in again") }
		if _, err := u.Upload(context.Background(), newArchive(10), "folder1", 0); err == nil || !strings.Contains(err.Error(), "signing in") || calls != 1 {
			t.Fatalf("err = %v after %d token calls (a token error isn't retried)", err, calls)
		}
	})
	t.Run("session on another host", func(t *testing.T) {
		d := newFakeDrive(t)
		requests := 0
		d.intercept = func(w http.ResponseWriter, r *http.Request) bool {
			requests++
			w.Header().Set("Location", "https://evil.example.com/session")
			return true
		}
		if _, err := d.uploader().Upload(context.Background(), newArchive(10), "folder1", 0); err == nil || requests != 1 {
			t.Fatalf("err = %v after %d requests: followed a session URI on another host", err, requests)
		}
	})
	t.Run("bad folder", func(t *testing.T) {
		d := newFakeDrive(t)
		if _, err := d.uploader().Upload(context.Background(), newArchive(10), "x' or '1'='1", 0); err == nil {
			t.Fatal("accepted a folder ID that would change the search query")
		}
	})
}

func TestUploadPrunes(t *testing.T) {
	d := newFakeDrive(t)
	day := func(n int) time.Time { return time.Date(2026, 11, n, 3, 0, 0, 0, time.UTC) }
	d.files = []driveFile{
		{ID: "d10", Name: "vesper-export-20261110T030000Z.zip", CreatedTime: day(10)},
		{ID: "notes", Name: "notes.txt", CreatedTime: day(1)},
		{ID: "d14", Name: "vesper-export-20261114T030000Z.zip", CreatedTime: day(14)},
		{ID: "mine", Name: "vesper-export-mine.zip", CreatedTime: day(2)},
		{ID: "download", Name: "vesper-export-2026-11-11.zip", CreatedTime: day(11)}, // from Settings › Backup & move
		{ID: "copy", Name: "vesper-export-20261111T030000Z (1).zip", CreatedTime: day(11)},
		{ID: "d12", Name: "vesper-export-20261112T030000Z.zip", CreatedTime: day(12)},
		{ID: "d13", Name: "vesper-export-20261113T030000Z.zip", CreatedTime: day(13)},
	}
	res, err := d.uploader().Upload(context.Background(), newArchive(100), "folder1", 3)
	if err != nil {
		t.Fatal(err)
	}
	// Keeps the new backup and the two newest; leaves files it didn't name.
	if !slices.Equal(res.Pruned, []string{"d12", "d10"}) || !slices.Equal(d.deleted, res.Pruned) {
		t.Fatalf("pruned %v, deleted %v", res.Pruned, d.deleted)
	}

	// Retention 0 keeps everything.
	d2 := newFakeDrive(t)
	d2.files = slices.Clone(d.files)
	if res, err := d2.uploader().Upload(context.Background(), newArchive(100), "folder1", 0); err != nil || len(res.Pruned) != 0 || len(d2.deleted) != 0 {
		t.Fatalf("retention 0: %+v, %v, deleted %v", res, err, d2.deleted)
	}
}

func TestUploadPruneFails(t *testing.T) {
	d := newFakeDrive(t)
	d.files = []driveFile{{ID: "old", Name: "vesper-export-20200101T000000Z.zip"}}
	d.intercept = func(w http.ResponseWriter, r *http.Request) bool {
		if r.Method == http.MethodGet {
			w.WriteHeader(500)
			return true
		}
		return false
	}
	res, err := d.uploader().Upload(context.Background(), newArchive(100), "folder1", 1)
	if !errors.Is(err, ErrPrune) || res.FileID != "new-file" {
		t.Fatalf("Upload = %+v, %v", res, err)
	}
}

func TestDefaultClientIsShared(t *testing.T) {
	if a, b := (&Uploader{}).client(), (&Uploader{}).client(); a != b {
		t.Fatal("each request would open its own connections")
	}
}

func TestParseRange(t *testing.T) {
	for h, want := range map[string]int64{"": 0, "bytes=0-0": 1, "bytes=0-262143": 262144} {
		if got, err := parseRange(h); err != nil || got != want {
			t.Errorf("parseRange(%q) = %d, %v", h, got, err)
		}
	}
	for _, h := range []string{"bytes=5-9", "bytes=0-x", "0-9"} {
		if _, err := parseRange(h); err == nil {
			t.Errorf("parseRange(%q) accepted", h)
		}
	}
}

// The upload authenticates with the secret's token from usersecrets.
func TestUploadWithSecretToken(t *testing.T) {
	f := newFixture(t)
	sec := f.oauthSecret(t, "Drive", true, ScopeFile)
	d := newFakeDrive(t)
	u := d.uploader()
	u.Token = SecretToken(f.secrets, sec)
	if _, err := u.Upload(f.ctx, newArchive(100), "folder1", 0); err != nil {
		t.Fatal(err)
	}
	for _, tok := range d.tokens {
		if tok != "Bearer a" {
			t.Fatalf("Authorization = %q", tok)
		}
	}
}

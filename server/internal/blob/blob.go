// Package blob stores binary artifacts and run logs as files under a local
// directory, one subdirectory per bucket (see local.go for the layout).
package blob

import (
	"context"
	"errors"
	"io"
	"sync"

	"github.com/liamphmurphy/vesper/server/internal/config"
)

type Store struct {
	dir     string
	buckets []string

	faultMu sync.RWMutex
	fault   func(op, bucket, key string) error
}

func New(cfg config.Blob) *Store {
	return NewDir(cfg.Dir, cfg.Buckets)
}

// NewDir returns a Store rooted at dir.
func NewDir(dir string, buckets []string) *Store {
	return &Store{dir: dir, buckets: append([]string{}, buckets...)}
}

// SetFault makes Put ("put") and Delete ("delete") return fn's error when it
// returns one, so tests can cover partial-failure paths. nil turns it off.
func (s *Store) SetFault(fn func(op, bucket, key string) error) {
	s.faultMu.Lock()
	defer s.faultMu.Unlock()
	s.fault = fn
}

func (s *Store) faulted(op, bucket, key string) error {
	s.faultMu.RLock()
	defer s.faultMu.RUnlock()
	if s.fault == nil {
		return nil
	}
	return s.fault(op, bucket, key)
}

// EnsureBuckets creates the configured bucket directories (and the store's
// root) if they don't exist yet.
func (s *Store) EnsureBuckets(ctx context.Context) error {
	return s.localEnsureBuckets()
}

// Object is a stored blob being read.
type Object struct {
	Body          io.ReadCloser
	ContentType   string
	ContentLength int64
}

// ErrNotFound means the key doesn't exist.
var ErrNotFound = errors.New("blob: not found")

// Put stores a blob. size must be exact.
func (s *Store) Put(ctx context.Context, bucket, key string, body io.Reader, size int64, contentType string) error {
	if err := s.faulted("put", bucket, key); err != nil {
		return err
	}
	return s.localPut(ctx, bucket, key, body, size, contentType)
}

// Get opens a blob for reading. The caller closes Body.
func (s *Store) Get(ctx context.Context, bucket, key string) (Object, error) {
	return s.localGet(ctx, bucket, key)
}

// GetRange opens bytes start through end (inclusive) of a blob. The caller
// closes Body.
func (s *Store) GetRange(ctx context.Context, bucket, key string, start, end int64) (Object, error) {
	return s.localGetRange(ctx, bucket, key, start, end)
}

// Delete removes a blob; a missing key is not an error.
func (s *Store) Delete(ctx context.Context, bucket, key string) error {
	if err := s.faulted("delete", bucket, key); err != nil {
		return err
	}
	return s.localDelete(ctx, bucket, key)
}

// Ping checks the store's directory exists.
func (s *Store) Ping(ctx context.Context) error {
	return s.localPing(ctx)
}

// Info is one stored object as a listing reports it.
type Info struct {
	Key  string
	Size int64
}

// ListBuckets returns the name of every bucket in the store.
func (s *Store) ListBuckets(ctx context.Context) ([]string, error) {
	return s.localListBuckets(ctx)
}

// List calls fn for every object in a bucket and stops at the first error fn
// returns.
func (s *Store) List(ctx context.Context, bucket string, fn func(Info) error) error {
	return s.localList(ctx, bucket, fn)
}

// EnsureBucket creates one bucket if it doesn't exist.
func (s *Store) EnsureBucket(ctx context.Context, bucket string) error {
	return s.localEnsureBucket(bucket)
}

// Open streams an object to services which need only the content.
func (s *Store) Open(ctx context.Context, bucket, key string) (io.ReadCloser, error) {
	o, err := s.Get(ctx, bucket, key)
	if err != nil {
		return nil, err
	}
	return o.Body, nil
}

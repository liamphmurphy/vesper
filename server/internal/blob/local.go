package blob

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

type localMeta struct {
	Key         string `json:"key"`
	ContentType string `json:"content_type"`
	Size        int64  `json:"size"`
}

func validateBucket(bucket string) error {
	if bucket == "" || len(bucket) > 63 || bucket == "." || bucket == ".." || strings.HasPrefix(bucket, ".") {
		return fmt.Errorf("blob: invalid bucket name %q", bucket)
	}
	if strings.ContainsAny(bucket, "/\\\x00") {
		return fmt.Errorf("blob: invalid bucket name %q", bucket)
	}
	return nil
}

func localObjectNames(key string) (shard, blobName, metaName string) {
	sum := sha256.Sum256([]byte(key))
	h := hex.EncodeToString(sum[:])
	return h[:2], h + ".blob", h + ".meta"
}

func (s *Store) localBucketDir(bucket string) (string, error) {
	if err := validateBucket(bucket); err != nil {
		return "", err
	}
	return filepath.Join(s.dir, bucket), nil
}

func (s *Store) localObjectPaths(bucket, key string) (dir, blobPath, metaPath string, err error) {
	bdir, err := s.localBucketDir(bucket)
	if err != nil {
		return "", "", "", err
	}
	shard, blobName, metaName := localObjectNames(key)
	dir = filepath.Join(bdir, shard)
	return dir, filepath.Join(dir, blobName), filepath.Join(dir, metaName), nil
}

func (s *Store) localEnsureBuckets() error {
	if err := os.MkdirAll(filepath.Join(s.dir, ".tmp"), 0o755); err != nil {
		return fmt.Errorf("blob: init dir %q: %w", s.dir, err)
	}
	for _, b := range s.buckets {
		if err := s.localEnsureBucket(b); err != nil {
			return err
		}
	}
	return nil
}

func (s *Store) localEnsureBucket(bucket string) error {
	bdir, err := s.localBucketDir(bucket)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Join(s.dir, ".tmp"), 0o755); err != nil {
		return fmt.Errorf("blob: tmp dir: %w", err)
	}
	if err := os.MkdirAll(bdir, 0o755); err != nil {
		return fmt.Errorf("blob: bucket %q: %w", bucket, err)
	}
	return nil
}

func (s *Store) localPut(ctx context.Context, bucket, key string, body io.Reader, size int64, contentType string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	if size < 0 {
		return fmt.Errorf("blob: put %s/%s: negative size %d", bucket, key, size)
	}
	if err := s.localEnsureBucket(bucket); err != nil {
		return err
	}
	objDir, blobPath, metaPath, err := s.localObjectPaths(bucket, key)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(objDir, 0o755); err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	tmpDir := filepath.Join(s.dir, ".tmp")
	bf, err := os.CreateTemp(tmpDir, "blob-*")
	if err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	bfPath := bf.Name()
	cleanupBlob := true
	defer func() {
		if cleanupBlob {
			_ = bf.Close()
			_ = os.Remove(bfPath)
		}
	}()
	n, err := io.Copy(bf, io.LimitReader(body, size+1))
	if err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	if n != size {
		return fmt.Errorf("blob: put %s/%s: read %d bytes, expected %d", bucket, key, n, size)
	}
	if err := bf.Close(); err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}

	metaBytes, err := json.Marshal(localMeta{Key: key, ContentType: contentType, Size: size})
	if err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	mf, err := os.CreateTemp(tmpDir, "meta-*")
	if err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	mfPath := mf.Name()
	cleanupMeta := true
	defer func() {
		if cleanupMeta {
			_ = mf.Close()
			_ = os.Remove(mfPath)
		}
	}()
	if _, err := mf.Write(metaBytes); err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	if err := mf.Close(); err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	// Rename blob first, meta last so readers/listers only observe committed pairs.
	if err := os.Rename(bfPath, blobPath); err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	cleanupBlob = false
	if err := os.Rename(mfPath, metaPath); err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	cleanupMeta = false
	return nil
}

func readLocalMeta(metaPath string) (localMeta, error) {
	b, err := os.ReadFile(metaPath)
	if err != nil {
		return localMeta{}, err
	}
	var m localMeta
	if err := json.Unmarshal(b, &m); err != nil {
		return localMeta{}, err
	}
	return m, nil
}

func (s *Store) localGet(ctx context.Context, bucket, key string) (Object, error) {
	if err := ctx.Err(); err != nil {
		return Object{}, err
	}
	_, blobPath, metaPath, err := s.localObjectPaths(bucket, key)
	if err != nil {
		return Object{}, err
	}
	m, err := readLocalMeta(metaPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Object{}, ErrNotFound
		}
		return Object{}, fmt.Errorf("blob: get %s/%s: %w", bucket, key, err)
	}
	f, err := os.Open(blobPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Object{}, ErrNotFound
		}
		return Object{}, fmt.Errorf("blob: get %s/%s: %w", bucket, key, err)
	}
	return Object{Body: f, ContentType: m.ContentType, ContentLength: m.Size}, nil
}

type rangedReadCloser struct {
	r io.Reader
	c io.Closer
}

func (rc *rangedReadCloser) Read(p []byte) (int, error) { return rc.r.Read(p) }
func (rc *rangedReadCloser) Close() error               { return rc.c.Close() }

func (s *Store) localGetRange(ctx context.Context, bucket, key string, start, end int64) (Object, error) {
	if err := ctx.Err(); err != nil {
		return Object{}, err
	}
	if start < 0 || end < start {
		return Object{}, fmt.Errorf("blob: get %s/%s bytes=%d-%d: invalid range", bucket, key, start, end)
	}
	_, blobPath, metaPath, err := s.localObjectPaths(bucket, key)
	if err != nil {
		return Object{}, err
	}
	m, err := readLocalMeta(metaPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Object{}, ErrNotFound
		}
		return Object{}, fmt.Errorf("blob: get %s/%s bytes=%d-%d: %w", bucket, key, start, end, err)
	}
	if start >= m.Size {
		return Object{}, fmt.Errorf("blob: get %s/%s bytes=%d-%d: start past end (%d)", bucket, key, start, end, m.Size)
	}
	if end >= m.Size {
		end = m.Size - 1
	}
	n := end - start + 1
	f, err := os.Open(blobPath)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return Object{}, ErrNotFound
		}
		return Object{}, fmt.Errorf("blob: get %s/%s bytes=%d-%d: %w", bucket, key, start, end, err)
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		_ = f.Close()
		return Object{}, fmt.Errorf("blob: get %s/%s bytes=%d-%d: %w", bucket, key, start, end, err)
	}
	return Object{
		Body:          &rangedReadCloser{r: io.LimitReader(f, n), c: f},
		ContentType:   m.ContentType,
		ContentLength: n,
	}, nil
}

func (s *Store) localDelete(ctx context.Context, bucket, key string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	_, blobPath, metaPath, err := s.localObjectPaths(bucket, key)
	if err != nil {
		return err
	}
	// Remove meta first, then blob.
	if err := os.Remove(metaPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	if err := os.Remove(blobPath); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	return nil
}

func (s *Store) localPing(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	fi, err := os.Stat(s.dir)
	if err != nil {
		return err
	}
	if !fi.IsDir() {
		return fmt.Errorf("blob: %q is not a directory", s.dir)
	}
	return nil
}

func (s *Store) localListBuckets(ctx context.Context) ([]string, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(s.dir)
	if errors.Is(err, fs.ErrNotExist) {
		return []string{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("blob: list buckets: %w", err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") {
			continue
		}
		names = append(names, e.Name())
	}
	sort.Strings(names)
	return names, nil
}

func (s *Store) localList(ctx context.Context, bucket string, fn func(Info) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	bdir, err := s.localBucketDir(bucket)
	if err != nil {
		return err
	}
	fi, err := os.Stat(bdir)
	if errors.Is(err, fs.ErrNotExist) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("blob: list %s: %w", bucket, err)
	}
	if !fi.IsDir() {
		return fmt.Errorf("blob: list %s: not a directory", bucket)
	}
	var infos []Info
	err = filepath.WalkDir(bdir, func(p string, d fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if d.IsDir() {
			if p != bdir && strings.HasPrefix(d.Name(), ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(d.Name(), ".meta") {
			return nil
		}
		m, err := readLocalMeta(p)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		infos = append(infos, Info{Key: m.Key, Size: m.Size})
		return nil
	})
	if err != nil {
		return fmt.Errorf("blob: list %s: %w", bucket, err)
	}
	sort.Slice(infos, func(i, j int) bool { return infos[i].Key < infos[j].Key })
	for _, info := range infos {
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := fn(info); err != nil {
			return err
		}
	}
	return nil
}

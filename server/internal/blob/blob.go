// Package blob wraps the S3 API used for binary artifacts and run logs.
// Only the S3 protocol is used, so SeaweedFS can be swapped for MinIO,
// Garage or AWS S3 by changing configuration.
package blob

import (
	"context"
	"errors"
	"fmt"
	"io"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"

	"github.com/liamphmurphy/vesper/server/internal/config"
)

type Store struct {
	client  *s3.Client
	dir     string
	buckets []string
}

func New(cfg config.S3) *Store {
	if cfg.Dir != "" {
		return NewDir(cfg.Dir, cfg.Buckets)
	}
	client := s3.New(s3.Options{
		Region:       cfg.Region,
		BaseEndpoint: aws.String(cfg.Endpoint),
		UsePathStyle: cfg.UsePathStyle,
		Credentials:  credentials.NewStaticCredentialsProvider(cfg.AccessKey, cfg.SecretKey, ""),
	})
	return &Store{client: client, buckets: cfg.Buckets}
}

// NewDir returns a Store backed by a local filesystem directory rather than an
// S3 server (used by standalone Vesper.app when BLOB_DIR is set).
func NewDir(dir string, buckets []string) *Store {
	return &Store{dir: dir, buckets: append([]string{}, buckets...)}
}

// EnsureBuckets creates any configured bucket that doesn't exist yet,
// retrying until ctx is done so the API can start before the S3 gateway is up.
func (s *Store) EnsureBuckets(ctx context.Context) error {
	if s.dir != "" {
		return s.localEnsureBuckets()
	}
	for _, b := range s.buckets {
		for {
			err := s.ensure(ctx, b)
			if err == nil {
				break
			}
			select {
			case <-ctx.Done():
				return fmt.Errorf("blob: bucket %q: %w", b, err)
			case <-time.After(time.Second):
			}
		}
	}
	return nil
}

func (s *Store) ensure(ctx context.Context, bucket string) error {
	if _, err := s.client.HeadBucket(ctx, &s3.HeadBucketInput{Bucket: &bucket}); err == nil {
		return nil
	}
	_, err := s.client.CreateBucket(ctx, &s3.CreateBucketInput{Bucket: &bucket})
	var owned *types.BucketAlreadyOwnedByYou
	var exists *types.BucketAlreadyExists
	if errors.As(err, &owned) || errors.As(err, &exists) {
		return nil
	}
	return err
}

// Object is a stored blob being read.
type Object struct {
	Body          io.ReadCloser
	ContentType   string
	ContentLength int64
}

// ErrNotFound means the key doesn't exist.
var ErrNotFound = errors.New("blob: not found")

// Put stores a blob. size must be exact; the S3 API needs it up front.
func (s *Store) Put(ctx context.Context, bucket, key string, body io.Reader, size int64, contentType string) error {
	if s.dir != "" {
		return s.localPut(ctx, bucket, key, body, size, contentType)
	}
	_, err := s.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:        &bucket,
		Key:           &key,
		Body:          body,
		ContentLength: &size,
		ContentType:   &contentType,
	})
	if err != nil {
		return fmt.Errorf("blob: put %s/%s: %w", bucket, key, err)
	}
	return nil
}

// Get opens a blob for reading. The caller closes Body.
func (s *Store) Get(ctx context.Context, bucket, key string) (Object, error) {
	if s.dir != "" {
		return s.localGet(ctx, bucket, key)
	}
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &bucket, Key: &key})
	if err != nil {
		var nsk *types.NoSuchKey
		if errors.As(err, &nsk) {
			return Object{}, ErrNotFound
		}
		return Object{}, fmt.Errorf("blob: get %s/%s: %w", bucket, key, err)
	}
	o := Object{Body: out.Body, ContentType: aws.ToString(out.ContentType)}
	if out.ContentLength != nil {
		o.ContentLength = *out.ContentLength
	}
	return o, nil
}

// GetRange opens bytes start through end (inclusive) of a blob. The caller
// closes Body.
func (s *Store) GetRange(ctx context.Context, bucket, key string, start, end int64) (Object, error) {
	if s.dir != "" {
		return s.localGetRange(ctx, bucket, key, start, end)
	}
	rng := fmt.Sprintf("bytes=%d-%d", start, end)
	out, err := s.client.GetObject(ctx, &s3.GetObjectInput{Bucket: &bucket, Key: &key, Range: &rng})
	if err != nil {
		var nsk *types.NoSuchKey
		if errors.As(err, &nsk) {
			return Object{}, ErrNotFound
		}
		return Object{}, fmt.Errorf("blob: get %s/%s %s: %w", bucket, key, rng, err)
	}
	o := Object{Body: out.Body, ContentType: aws.ToString(out.ContentType)}
	if out.ContentLength != nil {
		o.ContentLength = *out.ContentLength
	}
	return o, nil
}

// Delete removes a blob; a missing key is not an error.
func (s *Store) Delete(ctx context.Context, bucket, key string) error {
	if s.dir != "" {
		return s.localDelete(ctx, bucket, key)
	}
	_, err := s.client.DeleteObject(ctx, &s3.DeleteObjectInput{Bucket: &bucket, Key: &key})
	return err
}

// Ping checks the gateway is reachable by listing buckets.
func (s *Store) Ping(ctx context.Context) error {
	if s.dir != "" {
		return s.localPing(ctx)
	}
	_, err := s.client.ListBuckets(ctx, &s3.ListBucketsInput{})
	return err
}

// Info is one stored object as a listing reports it.
type Info struct {
	Key  string
	Size int64
}

// ListBuckets returns the name of every bucket the credential can see.
func (s *Store) ListBuckets(ctx context.Context) ([]string, error) {
	if s.dir != "" {
		return s.localListBuckets(ctx)
	}
	out, err := s.client.ListBuckets(ctx, &s3.ListBucketsInput{})
	if err != nil {
		return nil, fmt.Errorf("blob: list buckets: %w", err)
	}
	names := make([]string, 0, len(out.Buckets))
	for _, b := range out.Buckets {
		names = append(names, aws.ToString(b.Name))
	}
	return names, nil
}

// List calls fn for every object in a bucket, page by page, and stops at the
// first error fn returns.
func (s *Store) List(ctx context.Context, bucket string, fn func(Info) error) error {
	if s.dir != "" {
		return s.localList(ctx, bucket, fn)
	}
	pages := s3.NewListObjectsV2Paginator(s.client, &s3.ListObjectsV2Input{Bucket: &bucket})
	for pages.HasMorePages() {
		page, err := pages.NextPage(ctx)
		if err != nil {
			var nsb *types.NoSuchBucket
			if errors.As(err, &nsb) {
				return ErrNotFound
			}
			return fmt.Errorf("blob: list %s: %w", bucket, err)
		}
		for _, o := range page.Contents {
			if err := fn(Info{Key: aws.ToString(o.Key), Size: aws.ToInt64(o.Size)}); err != nil {
				return err
			}
		}
	}
	return nil
}

// EnsureBucket creates one bucket if it doesn't exist. Unlike EnsureBuckets it
// doesn't retry: the caller already has a working connection.
func (s *Store) EnsureBucket(ctx context.Context, bucket string) error {
	if s.dir != "" {
		return s.localEnsureBucket(bucket)
	}
	if err := s.ensure(ctx, bucket); err != nil {
		return fmt.Errorf("blob: bucket %q: %w", bucket, err)
	}
	return nil
}

// Open streams an object to services which need only the content. Keeping
// this interface in terms of io avoids coupling domain packages to S3 config.
func (s *Store) Open(ctx context.Context, bucket, key string) (io.ReadCloser, error) {
	o, err := s.Get(ctx, bucket, key)
	if err != nil {
		return nil, err
	}
	return o.Body, nil
}

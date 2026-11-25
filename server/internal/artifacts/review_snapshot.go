package artifacts

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"image/png"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

// A review snapshot is the PNG a person saw when they reviewed a mockup
// version. Runs get it beside the SVG, so an agent builds from exactly the
// picture that was approved rather than its own reading of the source.

const (
	// Large enough for a 2x render of a big screen, small enough for a JSON body.
	MaxReviewSnapshotBytes = 12 << 20
	maxReviewSnapshotSide  = 8192
)

// ReviewSnapshot is a decoded, checked snapshot ready to store.
type ReviewSnapshot struct {
	PNG          []byte
	Renderer     string
	SourceSHA256 string
}

// DecodeReviewSnapshot checks a snapshot sent with a review: a PNG of sane
// size, a renderer name and the hash of the SVG it was drawn from.
func DecodeReviewSnapshot(pngBase64, renderer, sourceSHA256 string) (*ReviewSnapshot, error) {
	renderer = strings.TrimSpace(renderer)
	if renderer == "" || len(renderer) > 64 {
		return nil, apperr.Invalid("snapshot.renderer", "must name the renderer in 1 to 64 characters")
	}
	sum := strings.ToLower(strings.TrimSpace(sourceSHA256))
	if b, err := hex.DecodeString(sum); err != nil || len(b) != sha256.Size {
		return nil, apperr.Invalid("snapshot.source_sha256", "must be the hex SHA-256 of the version's SVG")
	}
	if base64.StdEncoding.DecodedLen(len(pngBase64)) > MaxReviewSnapshotBytes+3 {
		return nil, apperr.Invalid("snapshot.png_base64", "is limited to %d MB", MaxReviewSnapshotBytes>>20)
	}
	data, err := base64.StdEncoding.DecodeString(pngBase64)
	if err != nil {
		return nil, apperr.Invalid("snapshot.png_base64", "isn't base64")
	}
	if len(data) > MaxReviewSnapshotBytes {
		return nil, apperr.Invalid("snapshot.png_base64", "is limited to %d MB", MaxReviewSnapshotBytes>>20)
	}
	cfg, err := png.DecodeConfig(bytes.NewReader(data))
	if err != nil {
		return nil, apperr.Invalid("snapshot.png_base64", "isn't a PNG image")
	}
	if cfg.Width < 1 || cfg.Height < 1 || cfg.Width > maxReviewSnapshotSide || cfg.Height > maxReviewSnapshotSide {
		return nil, apperr.Invalid("snapshot.png_base64", "must be 1 to %d pixels on each side", maxReviewSnapshotSide)
	}
	return &ReviewSnapshot{PNG: data, Renderer: renderer, SourceSHA256: sum}, nil
}

// SourceSHA256 is the hex SHA-256 a snapshot names its source by.
func SourceSHA256(body string) string {
	sum := sha256.Sum256([]byte(body))
	return hex.EncodeToString(sum[:])
}

// PutReviewSnapshot stores a snapshot's PNG under a new key. The caller
// records the key in the same transaction as the review, and calls the
// returned cleanup if that transaction fails.
func (s *Service) PutReviewSnapshot(ctx context.Context, ws, versionID uuid.UUID, snap *ReviewSnapshot) (string, func(), error) {
	if s.Blobs == nil {
		return "", func() {}, fmt.Errorf("artifacts: no blob store configured")
	}
	key := fmt.Sprintf("%s/review-snapshots/%s-%s.png", ws, versionID, uuid.New())
	if err := s.Blobs.Put(ctx, s.Bucket, key, bytes.NewReader(snap.PNG), int64(len(snap.PNG)), "image/png"); err != nil {
		return "", func() {}, err
	}
	return key, func() { _ = s.Blobs.Delete(context.Background(), s.Bucket, key) }, nil
}

// DeleteReviewSnapshot removes a replaced snapshot. It runs after the review
// commits, so a failure leaves only an unreferenced blob behind.
func (s *Service) DeleteReviewSnapshot(ctx context.Context, key string) {
	if s.Blobs == nil || key == "" {
		return
	}
	_ = s.Blobs.Delete(ctx, s.Bucket, key)
}

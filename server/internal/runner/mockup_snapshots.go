package runner

import (
	"context"
	"io"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// SnapshotReader reads review snapshots from the artifact bucket (blob.Store).
type SnapshotReader interface {
	Get(ctx context.Context, bucket, key string) (blob.Object, error)
}

// MockupSnapshotFiles adds, for each delivered mockup SVG whose version was
// reviewed with a snapshot, the PNG the reviewer saw, named like the SVG with
// .png. An agent then builds from the approved picture, not only its reading
// of the source. A snapshot that can't be read is skipped: the SVG is enough
// to work from.
func MockupSnapshotFiles(ctx context.Context, q *store.Queries, blobs SnapshotReader, bucket string, t store.Ticket, files []ContextFile) []ContextFile {
	if blobs == nil {
		return nil
	}
	ctx = pageview.Run(ctx)
	var out []ContextFile
	for _, f := range files {
		if !strings.HasSuffix(f.Path, ".svg") || !strings.HasPrefix(f.Path, ".lazyagents/context/mockup-") {
			continue
		}
		a, err := q.GetArtifact(ctx, store.GetArtifactParams{ID: f.ArtifactID, WorkspaceID: t.WorkspaceID, Viewer: pageview.From(ctx).UserID})
		if err != nil || a.Type != "mockup" || a.CurrentVersionID == nil {
			continue
		}
		v, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: t.WorkspaceID, Viewer: pageview.From(ctx).UserID})
		// The hash check keeps a snapshot from standing in for different source.
		if err != nil || v.ReviewSnapshotKey == nil || v.BodyMd == nil || string(f.Body) != *v.BodyMd ||
			v.ReviewSnapshotSha256 == nil || artifacts.SourceSHA256(*v.BodyMd) != *v.ReviewSnapshotSha256 {
			continue
		}
		o, err := blobs.Get(ctx, bucket, *v.ReviewSnapshotKey)
		if err != nil {
			continue
		}
		png, err := io.ReadAll(io.LimitReader(o.Body, artifacts.MaxReviewSnapshotBytes+1))
		o.Body.Close()
		if err != nil || len(png) > artifacts.MaxReviewSnapshotBytes {
			continue
		}
		out = append(out, ContextFile{Path: strings.TrimSuffix(f.Path, ".svg") + ".png", Body: png, ArtifactID: a.ID})
	}
	return out
}

package runs_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"image"
	"image/color"
	"image/png"
	"io"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func testPNG(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	img.Set(0, 0, color.RGBA{R: 255, A: 255})
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestDecodeReviewSnapshot(t *testing.T) {
	good := base64.StdEncoding.EncodeToString(testPNG(t, 4, 3))
	sum := artifacts.SourceSHA256(testSVG)
	if s, err := artifacts.DecodeReviewSnapshot(good, "vesper-native/1", sum); err != nil || s.Renderer != "vesper-native/1" || len(s.PNG) == 0 {
		t.Fatalf("good snapshot: %v %v", s, err)
	}
	for name, c := range map[string][3]string{
		"not base64":  {"%%%", "webkit", sum},
		"not a PNG":   {base64.StdEncoding.EncodeToString([]byte("GIF89a....")), "webkit", sum},
		"bad hash":    {good, "webkit", "abc"},
		"no renderer": {good, " ", sum},
	} {
		var verr *apperr.ValidationError
		if _, err := artifacts.DecodeReviewSnapshot(c[0], c[1], c[2]); !errors.As(err, &verr) {
			t.Errorf("%s: want a validation error, got %v", name, err)
		}
	}
	huge := base64.StdEncoding.EncodeToString(testPNG(t, 8193, 1))
	if _, err := artifacts.DecodeReviewSnapshot(huge, "webkit", sum); err == nil {
		t.Error("a PNG wider than 8192 pixels was accepted")
	}
}

// A review's snapshot is stored with the decision, replaced by the next one,
// cleared by a review without one, and delivered to runs beside the SVG.
func TestReviewSnapshotLifecycle(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	blobs := blob.New(config.Blob{Dir: t.TempDir(), Buckets: []string{"artifacts"}})
	if err := blobs.EnsureBuckets(ctx); err != nil {
		t.Fatal(err)
	}
	arts := &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: "artifacts"}
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: arts}
	a, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	tok, _, err := agents.IssueToken(ctx, q, a.ID, "unmanaged", "", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	atlas, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Claim(ctx, atlas, "PAY-214"); err != nil {
		t.Fatal(err)
	}
	out, err := svc.CreateMockup(ctx, atlas, "", "Checkout", testSVG, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	mockup, version := out.Artifact.ID, out.Version.ID
	snapshot := func(w int) *artifacts.ReviewSnapshot {
		s, err := artifacts.DecodeReviewSnapshot(base64.StdEncoding.EncodeToString(testPNG(t, w, 2)), "vesper-native/1", artifacts.SourceSHA256(testSVG))
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	stored := func() store.ArtifactVersion {
		v, err := q.GetArtifactVersion(pageview.Run(ctx), store.GetArtifactVersionParams{ID: version, ArtifactID: mockup, WorkspaceID: ws})
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	exists := func(key string) bool {
		o, err := blobs.Get(ctx, "artifacts", key)
		if err == nil {
			o.Body.Close()
		}
		return err == nil
	}

	// A snapshot of other source is refused, and leaves no blob behind.
	other := snapshot(2)
	other.SourceSHA256 = artifacts.SourceSHA256(testSVG + " ")
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup, version, "changes_requested", "bigger", nil, other); err == nil {
		t.Fatal("a snapshot of different source was accepted")
	}
	if v := stored(); v.ReviewSnapshotKey != nil || v.ReviewState == nil || *v.ReviewState != artifacts.ReviewPending {
		t.Fatalf("refused review changed the version: %+v", v)
	}

	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup, version, "changes_requested", "bigger", nil, snapshot(3)); err != nil {
		t.Fatal(err)
	}
	first := stored()
	if first.ReviewSnapshotKey == nil || *first.ReviewSnapshotRenderer != "vesper-native/1" || !exists(*first.ReviewSnapshotKey) {
		t.Fatalf("snapshot not stored: %+v", first)
	}

	// The next decision's snapshot replaces it, and the old blob goes.
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup, version, "approved", "", nil, snapshot(5)); err != nil {
		t.Fatal(err)
	}
	second := stored()
	if second.ReviewSnapshotKey == nil || *second.ReviewSnapshotKey == *first.ReviewSnapshotKey || exists(*first.ReviewSnapshotKey) || !exists(*second.ReviewSnapshotKey) {
		t.Fatalf("snapshot not replaced: first %v second %v", first.ReviewSnapshotKey, second.ReviewSnapshotKey)
	}

	// Runs get the PNG beside the SVG.
	ticket, err := q.GetTicketByKey(ctx, store.GetTicketByKeyParams{WorkspaceID: ws, Key: "PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	svgFile := runner.ContextFile{Path: ".lazyagents/context/mockup-checkout.svg", Body: []byte(testSVG), ArtifactID: mockup}
	files := runner.MockupSnapshotFiles(ctx, q, blobs, "artifacts", ticket, []runner.ContextFile{svgFile})
	if len(files) != 1 || files[0].Path != ".lazyagents/context/mockup-checkout.png" {
		t.Fatalf("snapshot files = %+v", files)
	}
	o, _ := blobs.Get(ctx, "artifacts", *second.ReviewSnapshotKey)
	want, _ := io.ReadAll(o.Body)
	o.Body.Close()
	if !bytes.Equal(files[0].Body, want) {
		t.Error("delivered PNG differs from the stored snapshot")
	}
	// A file that isn't the version's current source gets no snapshot.
	stale := svgFile
	stale.Body = []byte(testSVG + "\n")
	if files := runner.MockupSnapshotFiles(ctx, q, blobs, "artifacts", ticket, []runner.ContextFile{stale}); len(files) != 0 {
		t.Errorf("snapshot delivered for different source: %+v", files)
	}

	// A review without a snapshot clears it.
	if _, err := svc.ReviewMockup(ctx, ws, me.ID, mockup, version, "approved", "", nil, nil); err != nil {
		t.Fatal(err)
	}
	if v := stored(); v.ReviewSnapshotKey != nil || exists(*second.ReviewSnapshotKey) {
		t.Fatalf("snapshot not cleared: %v", v.ReviewSnapshotKey)
	}
}

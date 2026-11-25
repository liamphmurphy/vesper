package artifacts_test

import (
	"context"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

type fakeBlobs struct {
	mu   sync.Mutex
	objs map[string]string
}

func (f *fakeBlobs) Put(_ context.Context, _, key string, body io.Reader, _ int64, _ string) error {
	b, _ := io.ReadAll(body)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.objs[key] = string(b)
	return nil
}

func (f *fakeBlobs) Delete(_ context.Context, _, key string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.objs, key)
	return nil
}

type fixture struct {
	svc   *artifacts.Service
	blobs *fakeBlobs
	q     *store.Queries
	tr    *tracker.Service
	ws    uuid.UUID
	maya  artifacts.Actor
	atlas store.Agent
}

func setup(t *testing.T) fixture {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	blobs := &fakeBlobs{objs: map[string]string{}}
	svc := &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: "artifacts"}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: svc}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	q := store.New(pool)
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	agents, _ := q.ListAgents(ctx, u.WorkspaceID)
	f := fixture{svc: svc, blobs: blobs, q: q, tr: &tracker.Service{Pool: pool}, ws: u.WorkspaceID, maya: artifacts.Actor{Type: "user", ID: u.ID}}
	for _, a := range agents {
		if a.Handle == "atlas" {
			f.atlas = a
		}
	}
	blobs.objs = map[string]string{} // ignore the seeded design file
	return f
}

func md(s string) artifacts.Content { return artifacts.Content{BodyMD: &s} }

func outline(t *testing.T, f fixture, a store.Artifact) []store.ListSectionsWithCitationsRow {
	t.Helper()
	a, err := f.q.GetArtifact(context.Background(), store.GetArtifactParams{ID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(context.Background()).UserID})
	if err != nil {
		t.Fatal(err)
	}
	rows, err := f.q.ListSectionsWithCitations(context.Background(), store.ListSectionsWithCitationsParams{ArtifactID: a.ID, VersionID: *a.CurrentVersionID, Viewer: pageview.From(context.Background()).UserID})
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

func TestCreateMarkdownExtractsOutlineAndDefaults(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{
		ProjectKey: "PAY", Type: "spec",
		Content: md("# Payout batching spec\n\nBatch payouts per merchant via the zephyr scheduler.\n\n## Scheduling\n\n## Failure handling\n"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if a.Title != "Payout batching spec" {
		t.Errorf("title from first heading = %q", a.Title)
	}
	got := outline(t, f, a)
	if len(got) != 3 || got[1].Anchor != "scheduling" || got[2].Level != 2 {
		t.Fatalf("outline = %+v", got)
	}
	a, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	if a.Summary != "Batch payouts per merchant via the zephyr scheduler." {
		t.Errorf("summary = %q", a.Summary)
	}
	list, err := f.q.ListArtifacts(ctx, store.ListArtifactsParams{WorkspaceID: f.ws, Q: ptr("zephyr"), Viewer: pageview.From(ctx).UserID, IncludeAgent: pageview.From(ctx).IncludeAgent})
	if err != nil || len(list) != 1 || list[0].ID != a.ID {
		t.Fatalf("full-text search over contents: %v %v", len(list), err)
	}
}

func TestADRsAreNumberedInOrder(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	var nums []int32
	for _, title := range []string{"Use River for jobs", "Use SSE for realtime"} {
		a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "adr", Title: title, Content: md("Decision.")})
		if err != nil {
			t.Fatal(err)
		}
		nums = append(nums, *a.Number)
	}
	// The demo seeds ADR-012, so numbering continues from there.
	if nums[0] != 13 || nums[1] != 14 {
		t.Fatalf("ADR numbers = %v", nums)
	}
	if got := *artifacts.DisplayID("adr", &nums[0]); got != "ADR-013" {
		t.Fatalf("display id = %s", got)
	}
	// Imports keep their number, and a taken number is rejected.
	seven := int32(7)
	a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "adr", Title: "Imported", Number: &seven, Content: md("x")})
	if err != nil || *a.Number != 7 {
		t.Fatalf("explicit number: %v", err)
	}
	if _, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "adr", Title: "Dup", Number: &seven, Content: md("x")}); err == nil {
		t.Fatal("duplicate ADR number accepted")
	}
}

func TestCitationsSurviveNewVersions(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "prd", Title: "Payouts PRD", Content: md("## Goals\n\n## Risks\n")})
	if err != nil {
		t.Fatal(err)
	}
	a, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	for range 3 {
		if err := artifacts.RecordRead(ctx, f.q, a, f.atlas.ID, nil, "risks", nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := artifacts.RecordRead(ctx, f.q, a, f.atlas.ID, nil, "missing", nil); err == nil {
		t.Fatal("reading an unknown section should fail")
	}
	if _, err := f.svc.AddVersion(ctx, f.ws, f.maya, a.ID, artifacts.NewVersion{Content: md("## Goals\n\n## Scope\n\n## Risks\n")}); err != nil {
		t.Fatal(err)
	}
	got := outline(t, f, a)
	if len(got) != 3 || got[2].Anchor != "risks" || got[2].Citations != 3 || got[0].Citations != 0 {
		t.Fatalf("citations after new version = %+v", got)
	}
	versions, _ := f.q.ListArtifactVersions(ctx, store.ListArtifactVersionsParams{ArtifactID: a.ID, Viewer: pageview.From(ctx).UserID})
	if len(versions) != 2 || versions[0].Label != "v2" {
		t.Fatalf("versions = %+v", versions)
	}
}

func TestFilesGoToObjectStorage(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	pdf := "%PDF-1.7 fake"
	a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "MOB", Type: "design",
		Content: artifacts.Content{File: &artifacts.File{Name: "../Checkout flow v2.pdf", ContentType: "application/pdf", Size: int64(len(pdf)), Body: strings.NewReader(pdf)}}})
	if err != nil {
		t.Fatal(err)
	}
	if a.Title != "Checkout flow v2" {
		t.Errorf("title from filename = %q", a.Title)
	}
	a, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	v, err := f.q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		t.Fatal(err)
	}
	if v.BodyMd != nil || v.BlobKey == nil || *v.Filename != "Checkout-flow-v2.pdf" {
		t.Fatalf("version = %+v", v)
	}
	if f.blobs.objs[*v.BlobKey] != pdf {
		t.Fatal("blob not stored")
	}

	// A markdown upload is stored as text, not as a blob.
	note := "# Upload notes\n\n## Steps\n"
	m, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "spec",
		Content: artifacts.Content{File: &artifacts.File{Name: "notes.md", ContentType: "application/octet-stream", Size: int64(len(note)), Body: strings.NewReader(note)}}})
	if err != nil {
		t.Fatal(err)
	}
	if len(outline(t, f, m)) != 2 || len(f.blobs.objs) != 1 {
		t.Fatalf("markdown upload should be outlined text, blobs=%d", len(f.blobs.objs))
	}
}

func TestFailedCreateRemovesUploadedBlob(t *testing.T) {
	f := setup(t)
	_, err := f.svc.Create(context.Background(), f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "NOPE", Type: "design",
		Content: artifacts.Content{File: &artifacts.File{Name: "x.png", ContentType: "image/png", Size: 3, Body: strings.NewReader("png")}}})
	var ve *apperr.ValidationError
	if !errors.As(err, &ve) || ve.Field != "project_key" {
		t.Fatalf("err = %v", err)
	}
	if len(f.blobs.objs) != 0 {
		t.Fatal("orphaned blob left behind")
	}
}

func TestContentValidation(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	body := "x"
	for name, in := range map[string]artifacts.NewArtifact{
		"neither": {ProjectKey: "PAY", Type: "spec", Title: "t"},
		"both":    {ProjectKey: "PAY", Type: "spec", Title: "t", Content: artifacts.Content{BodyMD: &body, File: &artifacts.File{Name: "a.png", Size: 1, Body: strings.NewReader("a")}}},
		"blank":   {ProjectKey: "PAY", Type: "spec", Title: "t", Content: md("   \n")},
		"type":    {ProjectKey: "PAY", Type: "memo", Title: "t", Content: md("x")},
		"title":   {ProjectKey: "PAY", Type: "spec", Content: md("no heading here")},
	} {
		var ve *apperr.ValidationError
		if _, err := f.svc.Create(ctx, f.ws, f.maya, in); !errors.As(err, &ve) {
			t.Errorf("%s: want validation error, got %v", name, err)
		}
	}
}

func TestAttachToTicketsRecordsActivity(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "spec", Title: "Attach me", Content: md("x")})
	if err != nil {
		t.Fatal(err)
	}
	maya := tracker.UserActor(f.maya.ID)
	if _, err := f.tr.Bulk(ctx, f.ws, maya, []string{"PAY-219", "PAY-226"}, tracker.Patch{}, &a.ID); err != nil {
		t.Fatal(err)
	}
	// Attaching again is a no-op, with no duplicate event.
	if err := f.tr.AttachArtifact(ctx, f.ws, maya, "PAY-219", a.ID, "context"); err != nil {
		t.Fatal(err)
	}
	if err := f.tr.DetachArtifact(ctx, f.ws, maya, "PAY-226", a.ID); err != nil {
		t.Fatal(err)
	}
	linked, _ := f.q.ListArtifactTickets(ctx, a.ID)
	if len(linked) != 1 || linked[0].Key != "PAY-219" {
		t.Fatalf("linked = %+v", linked)
	}
	tk, _ := tracker.Get(ctx, f.q, f.ws, "PAY-219")
	evs, _ := f.q.ListTicketActivity(ctx, &tk.ID)
	n := 0
	for _, e := range evs {
		if e.Verb == tracker.VerbArtifactAttached {
			n++
		}
	}
	if n != 2 { // the seeded Refunds PRD, plus this one
		t.Fatalf("attach events = %d", n)
	}
	if err := f.tr.AttachArtifact(ctx, f.ws, maya, "PAY-219", uuid.New(), "context"); err == nil {
		t.Fatal("unknown artifact should be rejected")
	}
}

func ptr[T any](v T) *T { return &v }

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// A chat has no project to file under, so what it saves (reports, notes,
// mockups, designs) needs none; the types that are project documents still do.
func TestProjectOptionalByType(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	svg := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>`
	for _, typ := range []string{"report", "mockup", "design"} {
		body := "Body."
		if typ == "mockup" {
			body = svg
		}
		a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{Type: typ, Title: "Loose " + typ, Content: artifacts.Content{BodyMD: &body}})
		if err != nil {
			t.Fatalf("%s without a project: %v", typ, err)
		}
		if a.ProjectID != nil {
			t.Errorf("%s got project %v", typ, a.ProjectID)
		}
	}
	for _, typ := range []string{"prd", "spec", "adr"} {
		body := "Body."
		_, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{Type: typ, Title: "Loose " + typ, Content: artifacts.Content{BodyMD: &body}})
		var ve *apperr.ValidationError
		if !errors.As(err, &ve) || ve.Field != "project_key" {
			t.Errorf("%s without a project: err = %v, want a project_key error", typ, err)
		}
	}
}

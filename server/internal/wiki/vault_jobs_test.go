package wiki_test

import (
	"archive/zip"
	"bytes"
	"context"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

type vaultMemory struct {
	mu   sync.Mutex
	data map[string][]byte
}

func (m *vaultMemory) Put(_ context.Context, bucket, key string, r io.Reader, n int64, _ string) error {
	b, err := io.ReadAll(r)
	if err != nil {
		return err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.data == nil {
		m.data = map[string][]byte{}
	}
	m.data[bucket+"/"+key] = b
	return nil
}
func (m *vaultMemory) Open(_ context.Context, bucket, key string) (io.ReadCloser, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	b, ok := m.data[bucket+"/"+key]
	if !ok {
		return nil, os.ErrNotExist
	}
	return io.NopCloser(bytes.NewReader(b)), nil
}
func (m *vaultMemory) Delete(_ context.Context, bucket, key string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	delete(m.data, bucket+"/"+key)
	return nil
}
func vaultZip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	z := zip.NewWriter(&buf)
	for name, body := range files {
		f, err := z.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = f.Write([]byte(body)); err != nil {
			t.Fatal(err)
		}
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}
func fixtureZip(t *testing.T) []byte {
	t.Helper()
	root := "../../../docs/knowledge/fixtures/obsidian-vault"
	files := map[string]string{}
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			return nil
		}
		b, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		files["My vault/"+filepath.ToSlash(rel)] = string(b)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return vaultZip(t, files)
}
func TestVaultJobPreviewCommitReimportAndUndo(t *testing.T) {
	e := setup(t)
	e.svc.Objects = &vaultMemory{}
	ctx := pageview.Person(e.ctx, e.me.ID)
	data := fixtureZip(t)
	before, err := wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Limit: 200})
	if err != nil {
		t.Fatal(err)
	}
	job, err := e.svc.QueueVault(ctx, e.ws, e.me.ID, "Imported", bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if worked, err := e.svc.ProcessNextVault(ctx); err != nil || !worked {
		t.Fatalf("scan %v %v", worked, err)
	}
	job, err = e.q.GetKnowledgeImport(ctx, store.GetKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID})
	if err != nil || job.State != "preview" {
		t.Fatalf("preview %+v %v", job, err)
	}
	after, err := wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Limit: 200})
	if err != nil || len(after.Rows) != len(before.Rows) {
		t.Fatal("dry run wrote pages", err)
	}
	if !strings.Contains(string(job.Plan), `"renamed": true`) && !strings.Contains(string(job.Plan), `"renamed":true`) {
		t.Fatalf("missing rename report %s", job.Plan)
	}
	if _, err = e.q.ConfirmKnowledgeImport(ctx, store.ConfirmKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID, Policy: "replace"}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(ctx); err != nil {
		t.Fatal(err)
	}
	job, err = e.q.GetKnowledgeImport(ctx, store.GetKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID})
	if err != nil || job.State != "done" {
		t.Fatalf("commit %+v %v", job, err)
	}
	if strings.Contains(string(job.Report), `"status": "failed"`) || strings.Contains(string(job.Report), `"status":"failed"`) {
		t.Fatalf("file failures: %s", job.Report)
	}
	imported, err := wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Folder: "Imported", Limit: 200})
	if err != nil || len(imported.Rows) < 6 {
		t.Fatalf("imported %d %v report=%s", len(imported.Rows), err, job.Report)
	}
	for _, row := range imported.Rows {
		if row.Audience != "private" {
			t.Fatal("import published nonprivate page")
		}
	}
	hidden, err := wiki.QueryPages(pageview.Run(ctx), e.q, e.ws, wiki.PageQuery{Folder: "Imported"})
	if err != nil || len(hidden.Rows) != 0 {
		t.Fatal("private imports reached a run", err)
	}
	welcome, version, err := wiki.OpenPage(ctx, e.q, e.ws, "Imported/Welcome")
	if err != nil {
		t.Fatal(err)
	}
	embeds, err := wiki.ResolveEmbeds(ctx, e.q, e.ws, *version.BodyMd)
	if err != nil {
		t.Fatal(err)
	}
	for _, em := range embeds {
		if !em.Available {
			t.Fatalf("unresolved embed %+v", em)
		}
	}
	again, err := e.svc.QueueVault(ctx, e.ws, e.me.ID, "Imported", bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err = e.q.ConfirmKnowledgeImport(ctx, store.ConfirmKnowledgeImportParams{ID: again.ID, WorkspaceID: e.ws, UserID: e.me.ID, Policy: "replace"}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(ctx); err != nil {
		t.Fatal(err)
	}
	_, current, err := wiki.OpenPage(ctx, e.q, e.ws, welcome.ID.String())
	if err != nil || current.ID != version.ID {
		t.Fatal("unchanged re-import created version", err)
	}
	var exported bytes.Buffer
	if err = e.svc.ExportVault(ctx, e.ws, &exported); err != nil {
		t.Fatal(err)
	}
	var versionsBefore int
	if err = e.svc.Pool.QueryRow(ctx, "SELECT count(*) FROM artifact_versions").Scan(&versionsBefore); err != nil {
		t.Fatal(err)
	}
	roundtrip, err := e.svc.QueueVault(ctx, e.ws, e.me.ID, "", bytes.NewReader(exported.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err = e.q.ConfirmKnowledgeImport(ctx, store.ConfirmKnowledgeImportParams{ID: roundtrip.ID, WorkspaceID: e.ws, UserID: e.me.ID, Policy: "replace"}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(ctx); err != nil {
		t.Fatal(err)
	}
	var versionsAfter int
	if err = e.svc.Pool.QueryRow(ctx, "SELECT count(*) FROM artifact_versions").Scan(&versionsAfter); err != nil {
		t.Fatal(err)
	}
	if versionsAfter != versionsBefore {
		j, _ := e.q.GetKnowledgeImport(ctx, store.GetKnowledgeImportParams{ID: roundtrip.ID, WorkspaceID: e.ws, UserID: e.me.ID})
		t.Fatalf("roundtrip changed %d -> %d versions; report %s", versionsBefore, versionsAfter, j.Report)
	}
	daily, err := e.svc.DailyPage(ctx, e.ws, e.me.ID, "2026-11-13", "", "")
	if err != nil || daily.Note.Path == nil || *daily.Note.Path != "Imported/Daily/2026-11-13" {
		t.Fatalf("imported daily not mapped: %+v %v", daily, err)
	}
	if err = e.svc.UndoVault(ctx, e.ws, e.me.ID, job.ID); err != nil {
		t.Fatal(err)
	}
	imported, err = wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Folder: "Imported", Limit: 200})
	if err != nil || len(imported.Rows) != 0 {
		t.Fatal("undo left imported pages", err)
	}
}
func TestVaultArchiveSafety(t *testing.T) {
	for name, files := range map[string]map[string]string{"parent": {"../bad.md": "bad"}, "absolute": {"/bad.md": "bad"}, "windows": {"C:/bad.md": "bad"}, "ratio": {"bomb.md": strings.Repeat("x", 3<<20)}} {
		t.Run(name, func(t *testing.T) {
			data := vaultZip(t, files)
			z, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
			if err != nil {
				t.Fatal(err)
			}
			if _, err = wiki.PlanVault(z, ""); err == nil {
				t.Fatal("unsafe archive accepted")
			}
		})
	}
}

func TestVaultUploadLargerThanLegacyLimit(t *testing.T) {
	e := setup(t)
	e.svc.Objects = &vaultMemory{}
	var archive bytes.Buffer
	z := zip.NewWriter(&archive)
	file, err := z.CreateHeader(&zip.FileHeader{Name: "large.bin", Method: zip.Store})
	if err != nil {
		t.Fatal(err)
	}
	block := bytes.Repeat([]byte{0x9a, 0x42, 0x17, 0xff}, 256<<10)
	for range 51 {
		if _, err = file.Write(block); err != nil {
			t.Fatal(err)
		}
	}
	if err = z.Close(); err != nil {
		t.Fatal(err)
	}
	job, err := e.svc.QueueVault(e.ctx, e.ws, e.me.ID, "", bytes.NewReader(archive.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(e.ctx); err != nil {
		t.Fatal(err)
	}
	job, err = e.q.GetKnowledgeImport(e.ctx, store.GetKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID})
	if err != nil || job.State != "preview" {
		t.Fatalf("large archive state %s %v", job.State, err)
	}
}

func TestKeepBothPreservesImportedGraphAndThenIsIdempotent(t *testing.T) {
	e := setup(t)
	e.svc.Objects = &vaultMemory{}
	ctx := pageview.Person(e.ctx, e.me.ID)
	original := e.save(t, "Copy/Target", "Human text")
	// The importer refuses replacements of shared pages, but keep-both may
	// import private copies without changing the original audience or body.
	files := map[string]string{"Target.md": "---\naliases: [Destination]\n---\nImported target\n", "Index.md": "[[Target]] and [[Destination]]\n"}
	data := vaultZip(t, files)
	run := func() store.KnowledgeImport {
		t.Helper()
		job, err := e.svc.QueueVault(ctx, e.ws, e.me.ID, "Copy", bytes.NewReader(data))
		if err != nil {
			t.Fatal(err)
		}
		if _, err = e.svc.ProcessNextVault(ctx); err != nil {
			t.Fatal(err)
		}
		if _, err = e.q.ConfirmKnowledgeImport(ctx, store.ConfirmKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID, Policy: "keep_both"}); err != nil {
			t.Fatal(err)
		}
		if _, err = e.svc.ProcessNextVault(ctx); err != nil {
			t.Fatal(err)
		}
		job, err = e.q.GetKnowledgeImport(ctx, store.GetKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(string(job.Report), `"status": "failed"`) || strings.Contains(string(job.Report), `"status":"failed"`) {
			t.Fatal(string(job.Report))
		}
		return job
	}
	run()
	_, current, err := wiki.OpenPage(ctx, e.q, e.ws, original.Note.ID.String())
	if err != nil || *current.BodyMd != "Human text" {
		t.Fatal("original changed", err)
	}
	rows, err := wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Folder: "Copy", Audience: "private", Limit: 200})
	if err != nil || len(rows.Rows) != 2 {
		t.Fatalf("copies %v %v", rows, err)
	}
	index, body, err := wiki.OpenPage(ctx, e.q, e.ws, "Copy/Index")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(*body.BodyMd, "[[Copy/Target]]") {
		t.Fatal("imported index points to original", *body.BodyMd)
	}
	for _, link := range e.linksFrom(t, index.ID) {
		if link.TargetID == nil || *link.TargetID == original.Note.ID {
			t.Fatalf("wrong imported target %+v", link)
		}
	}
	before := len(rows.Rows)
	run()
	rows, err = wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Folder: "Copy", Audience: "private", Limit: 200})
	if err != nil || len(rows.Rows) != before {
		t.Fatalf("keep-both duplicated unchanged import: %d -> %d %v", before, len(rows.Rows), err)
	}
}

func TestAssetSweepDoesNotDeleteReuploadedContent(t *testing.T) {
	e := setup(t)
	objects := &vaultMemory{}
	e.svc.Objects = objects
	asset, err := e.svc.StoreKnowledgeAsset(e.ctx, e.ws, e.me.ID, "hash", "file.txt", "text/plain", 5, strings.NewReader("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.Pool.Exec(e.ctx, `UPDATE knowledge_assets SET created_at=now()-interval '2 days' WHERE id=$1`, asset.ID); err != nil {
		t.Fatal(err)
	}
	if err = e.q.StageOrphanKnowledgeAssets(e.ctx); err != nil {
		t.Fatal(err)
	}
	again, err := e.svc.StoreKnowledgeAsset(e.ctx, e.ws, e.me.ID, "hash", "file.txt", "text/plain", 5, strings.NewReader("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if err = e.svc.SweepKnowledgeAssets(e.ctx); err != nil {
		t.Fatal(err)
	}
	reader, err := objects.Open(e.ctx, e.svc.Artifacts.Bucket, again.BlobKey)
	if err != nil {
		t.Fatal("sweep deleted reused blob", err)
	}
	defer reader.Close()
	b, _ := io.ReadAll(reader)
	if string(b) != "hello" {
		t.Fatal(string(b))
	}
}

func TestVaultAgentNamespacesRemainPrivate(t *testing.T) {
	e := setup(t)
	e.svc.Objects = &vaultMemory{}
	ctx := pageview.Person(e.ctx, e.me.ID)
	data := vaultZip(t, map[string]string{"agents/atlas/Secret.md": "Personal secret", "Patterns/Proposed/Private.md": "Personal pattern"})
	job, err := e.svc.QueueVault(ctx, e.ws, e.me.ID, "", bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err = e.q.ConfirmKnowledgeImport(ctx, store.ConfirmKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID, Policy: "replace"}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.svc.ProcessNextVault(ctx); err != nil {
		t.Fatal(err)
	}
	rows, err := wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Folder: "Imported", Limit: 200})
	if err != nil || len(rows.Rows) != 2 {
		t.Fatalf("reserved paths %+v %v", rows, err)
	}
	for _, row := range rows.Rows {
		if row.Audience != "private" {
			t.Fatal("vault namespace exposed to runs", row)
		}
	}
	visible, err := wiki.QueryPages(pageview.Run(ctx), e.q, e.ws, wiki.PageQuery{Folder: "Imported", Limit: 200})
	if err != nil || len(visible.Rows) != 0 {
		t.Fatal("run saw imported private content", err)
	}
}

func TestVaultWorkerWakesImmediatelyViaNotify(t *testing.T) {
	e := setup(t)
	e.svc.Objects = &vaultMemory{}
	ctx := pageview.Person(e.ctx, e.me.ID)

	wctx, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		e.svc.RunVaultWorker(wctx, slog.New(slog.NewTextHandler(io.Discard, nil)))
	}()
	defer func() {
		cancel()
		<-done
	}()

	// Give the LISTEN connection a moment to attach before queueing a job so
	// wake-up relies on NOTIFY rather than the 60s fallback timer.
	time.Sleep(100 * time.Millisecond)

	data := vaultZip(t, map[string]string{"Hello.md": "# Hello\nBody"})
	job, err := e.svc.QueueVault(ctx, e.ws, e.me.ID, "", bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		got, err := e.q.GetKnowledgeImport(ctx, store.GetKnowledgeImportParams{ID: job.ID, WorkspaceID: e.ws, UserID: e.me.ID})
		if err != nil {
			t.Fatal(err)
		}
		if got.State == "preview" {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("RunVaultWorker did not wake via NOTIFY to scan queued vault import")
}

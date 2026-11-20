package transfer_test

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

// memBlobs is an in-memory object store.
type memBlobs struct {
	mu      sync.Mutex
	buckets map[string]map[string]memObject
}

type memObject struct {
	body []byte
	ct   string
}

func newMemBlobs() *memBlobs { return &memBlobs{buckets: map[string]map[string]memObject{}} }

func (m *memBlobs) put(bucket, key, ct string, body []byte) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.buckets[bucket] == nil {
		m.buckets[bucket] = map[string]memObject{}
	}
	m.buckets[bucket][key] = memObject{body: body, ct: ct}
}

func (m *memBlobs) ListBuckets(context.Context) ([]string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []string
	for b := range m.buckets {
		out = append(out, b)
	}
	return out, nil
}

func (m *memBlobs) List(_ context.Context, bucket string, fn func(blob.Info) error) error {
	m.mu.Lock()
	if _, ok := m.buckets[bucket]; !ok {
		m.mu.Unlock()
		return blob.ErrNotFound
	}
	var infos []blob.Info
	for k, o := range m.buckets[bucket] {
		infos = append(infos, blob.Info{Key: k, Size: int64(len(o.body))})
	}
	m.mu.Unlock()
	sort.Slice(infos, func(i, j int) bool { return infos[i].Key < infos[j].Key })
	for _, i := range infos {
		if err := fn(i); err != nil {
			return err
		}
	}
	return nil
}

func (m *memBlobs) Get(_ context.Context, bucket, key string) (blob.Object, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	o, ok := m.buckets[bucket][key]
	if !ok {
		return blob.Object{}, blob.ErrNotFound
	}
	return blob.Object{Body: io.NopCloser(bytes.NewReader(o.body)), ContentType: o.ct, ContentLength: int64(len(o.body))}, nil
}

func (m *memBlobs) Put(_ context.Context, bucket, key string, body io.Reader, size int64, ct string) error {
	b, err := io.ReadAll(body)
	if err != nil {
		return err
	}
	if int64(len(b)) != size {
		return fmt.Errorf("put %s/%s: %d bytes, declared %d", bucket, key, len(b), size)
	}
	m.put(bucket, key, ct, b)
	return nil
}

func (m *memBlobs) EnsureBucket(_ context.Context, bucket string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.buckets[bucket] == nil {
		m.buckets[bucket] = map[string]memObject{}
	}
	return nil
}

// seed fills the source with rows that exercise what import has to get right:
// a foreign-key cycle (agents <-> agent_definition_versions), a sequence
// (run_events.seq), jsonb, arrays, NULL against empty strings, awkward CSV text,
// and rows under tables with updated_at and change-event triggers.
func seed(t *testing.T, pool *pgxpool.Pool) {
	t.Helper()
	ctx := t.Context()
	var ws, project, user, agent, version, ticket, run string
	q := func(dst any, sql string, args ...any) {
		t.Helper()
		if err := pool.QueryRow(ctx, sql, args...).Scan(dst); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	x := func(sql string, args ...any) {
		t.Helper()
		if _, err := pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	q(&ws, `INSERT INTO workspaces(name,slug) VALUES('Acme','acme') RETURNING id`)
	q(&user, `INSERT INTO users(workspace_id,name,email,initials,password_hash) VALUES($1,'Ann','ann@example.com','A','x') RETURNING id`, ws)
	q(&project, `INSERT INTO projects(workspace_id,key,name,color) VALUES($1,'PRJ','Project, "quoted"','#123456') RETURNING id`, ws)
	q(&agent, `INSERT INTO agents(workspace_id,name,handle) VALUES($1,'A','atlas') RETURNING id`, ws)
	q(&version, `INSERT INTO agent_definition_versions(agent_id,version,spec) VALUES($1,1,'{"model":"m","tools":["a","b"]}') RETURNING id`, agent)
	x(`UPDATE agents SET current_definition_version_id=$2 WHERE id=$1`, agent, version)
	for n := 1; n <= 3; n++ {
		desc := "Ticket " + fmt.Sprint(n) + "\nwith a newline, a comma, a \"quote\" and unicode: héllo ✓"
		q(&ticket, `INSERT INTO tickets(workspace_id,project_id,number,key,title,status,description_md,assignee_agent_id) VALUES($1,$2,$3,$4,'T','todo',$5,$6) RETURNING id`,
			ws, project, n, fmt.Sprintf("PRJ-%d", n), desc, agent)
	}
	// NULL and an empty string must stay different through CSV.
	x(`UPDATE tickets SET branch = '' WHERE number = 2`)
	x(`UPDATE tickets SET branch = NULL WHERE number = 3`)
	x(`INSERT INTO comments(workspace_id,ticket_id,author_type,author_id,body_md) VALUES($1,$2,'user',$3,'looks good')`, ws, ticket, user)
	x(`INSERT INTO memories(workspace_id,user_id,title,tags) VALUES($1,$2,'Prefers metric','{a,"b c",""}')`, ws, user)
	q(&run, `INSERT INTO runs(workspace_id,ticket_id,agent_id,mode,state,resolved_spec,harness,model,purpose,definition_version_id)
		VALUES($1,$2,$3,'managed','completed','{"k":[1,2,{"x":null}]}','claude-code','m','ticket',$4) RETURNING id`, ws, ticket, agent, version)
	for range 3 {
		x(`INSERT INTO run_events(run_id,type,payload) VALUES($1,'message','{"n":1}')`, run)
	}
}

// dump returns every row of every exported table as sorted text, keyed by
// table, so two databases can be compared.
func dump(t *testing.T, pool *pgxpool.Pool) map[string][]string {
	t.Helper()
	ctx := t.Context()
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	schema, err := transfer.Discover(ctx, tx)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string][]string{}
	for _, tb := range schema.Tables {
		cols := make([]string, len(tb.Columns))
		for i, c := range tb.Columns {
			cols[i] = fmt.Sprintf("%s::text", pgx.Identifier{c.Name}.Sanitize())
		}
		rows, err := tx.Query(ctx, fmt.Sprintf("SELECT row(%s)::text FROM %s", strings.Join(cols, ","), pgx.Identifier{tb.Name}.Sanitize()))
		if err != nil {
			t.Fatalf("dump %s: %v", tb.Name, err)
		}
		var lines []string
		for rows.Next() {
			var s string
			if err := rows.Scan(&s); err != nil {
				t.Fatal(err)
			}
			lines = append(lines, s)
		}
		rows.Close()
		sort.Strings(lines)
		out[tb.Name] = lines
	}
	return out
}

// listenForChanges counts the realtime change notifications the database
// publishes from now on. It listens as soon as the channel's table exists,
// which for an unmigrated database is after the first migration step, so it
// retries LISTEN on its own connection.
func listenForChanges(t *testing.T, pool *pgxpool.Pool) *atomic.Int64 {
	t.Helper()
	var n atomic.Int64
	conn, err := pool.Acquire(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := conn.Exec(t.Context(), "LISTEN lazyagents_changes"); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(t.Context())
	done := make(chan struct{})
	go func() {
		defer close(done)
		for {
			_, err := conn.Conn().WaitForNotification(ctx)
			if err != nil {
				return
			}
			n.Add(1)
		}
	}()
	t.Cleanup(func() { cancel(); <-done; conn.Release() })
	return &n
}

func exportToZip(t *testing.T, pool *pgxpool.Pool, blobs transfer.Blobs, key string) (*zip.Reader, *transfer.Manifest) {
	t.Helper()
	var buf bytes.Buffer
	m, err := (&transfer.Exporter{Pool: pool, Blobs: blobs, AppVersion: "test", SecretsKey: key}).Export(t.Context(), &buf)
	if err != nil {
		t.Fatalf("export: %v", err)
	}
	zr, err := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
	if err != nil {
		t.Fatal(err)
	}
	return zr, m
}

func TestRoundTrip(t *testing.T) {
	src := testdb.New(t)
	seed(t, src)
	srcBlobs := newMemBlobs()
	srcBlobs.put("artifacts", "a/one.png", "image/png", []byte{0x89, 'P', 'N', 'G', 0, 1, 2})
	srcBlobs.put("artifacts", "weird/../key with spaces?.txt", "text/plain", []byte("hello"))
	srcBlobs.put("run-logs", "run/1.log", "text/plain", bytes.Repeat([]byte("log line\n"), 1000))
	// A bucket the server doesn't know about by name: export finds it anyway.
	srcBlobs.put("added-next-year", "k", "application/octet-stream", []byte("new feature"))
	srcBlobs.put("empty-bucket", "", "", nil)
	delete(srcBlobs.buckets["empty-bucket"], "")

	zr, m := exportToZip(t, src, srcBlobs, "")
	if !slices.ContainsFunc(m.Buckets, func(b transfer.BucketEntry) bool { return b.Name == "artifacts" }) {
		t.Fatal("artifacts bucket missing")
	}

	dst := testdb.New(t)
	dstBlobs := newMemBlobs()
	notified := listenForChanges(t, dst)
	if err := (&transfer.Importer{Pool: dst, Blobs: dstBlobs}).Import(t.Context(), zr); err != nil {
		t.Fatalf("import: %v", err)
	}

	time.Sleep(200 * time.Millisecond) // let any notification arrive
	want, got := dump(t, src), dump(t, dst)
	for table, rows := range want {
		if !slices.Equal(rows, got[table]) {
			t.Errorf("table %s differs:\n source: %q\n target: %q", table, rows, got[table])
		}
	}
	for _, table := range []string{"tickets", "agents", "agent_definition_versions", "runs", "run_events", "memories", "comments"} {
		if len(want[table]) == 0 {
			t.Errorf("seed left %s empty, so the round trip proves nothing about it", table)
		}
	}
	if n := notified.Load(); n != 0 {
		t.Errorf("import published %d change notifications: realtime clients would refetch for every restored row", n)
	}
	var next int64
	if err := dst.QueryRow(t.Context(), `SELECT nextval('run_events_seq_seq')`).Scan(&next); err != nil {
		t.Fatal(err)
	}
	var maxSeq int64
	if err := dst.QueryRow(t.Context(), `SELECT max(seq) FROM run_events`).Scan(&maxSeq); err != nil {
		t.Fatal(err)
	}
	if next <= maxSeq {
		t.Errorf("sequence not reset: next value %d, but rows reach %d", next, maxSeq)
	}
	for _, b := range m.Buckets {
		for _, o := range b.Objects {
			g, err := dstBlobs.Get(t.Context(), b.Name, o.Key)
			if err != nil {
				t.Fatalf("object %s/%s missing after import: %v", b.Name, o.Key, err)
			}
			body, _ := io.ReadAll(g.Body)
			sum := sha256.Sum256(body)
			if hex.EncodeToString(sum[:]) != o.SHA256 || g.ContentType != srcBlobs.buckets[b.Name][o.Key].ct {
				t.Errorf("object %s/%s changed in transit", b.Name, o.Key)
			}
		}
	}
	if _, ok := dstBlobs.buckets["empty-bucket"]; !ok {
		t.Error("an empty bucket wasn't recreated")
	}
	if _, ok := dstBlobs.buckets["added-next-year"]; !ok {
		t.Error("a bucket nobody listed wasn't exported")
	}
}

// A fresh machine has no schema yet: import migrates it to the export's version,
// loads the rows, then runs whatever migrations are newer.
func TestImportIntoUnmigratedDatabase(t *testing.T) {
	src := testdb.New(t)
	seed(t, src)
	zr, m := exportToZip(t, src, newMemBlobs(), "")

	dst := testdb.NewUnmigrated(t)
	if err := (&transfer.Importer{Pool: dst, Blobs: newMemBlobs()}).Import(t.Context(), zr); err != nil {
		t.Fatalf("import: %v", err)
	}
	v, err := db.Version(t.Context(), dst)
	if err != nil {
		t.Fatal(err)
	}
	if v < m.SchemaVersion {
		t.Errorf("target is at schema %d, below the export's %d", v, m.SchemaVersion)
	}
	if want, got := dump(t, src), dump(t, dst); !slices.Equal(want["tickets"], got["tickets"]) || len(got["tickets"]) != 3 {
		t.Errorf("tickets differ after import: %q vs %q", want["tickets"], got["tickets"])
	}
}

func TestEveryTableIsExportedOrExcluded(t *testing.T) {
	pool := testdb.New(t)
	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(t.Context())
	schema, err := transfer.Discover(t.Context(), tx)
	if err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(t.Context(), `SELECT tablename FROM pg_tables WHERE schemaname='public'`)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	exported := map[string]bool{}
	for _, tb := range schema.Tables {
		exported[tb.Name] = true
	}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			t.Fatal(err)
		}
		_, skipped := schema.Excluded[name]
		if !exported[name] && !skipped {
			t.Errorf("table %q is neither exported nor excluded", name)
		}
		if skipped && strings.TrimSpace(schema.Excluded[name]) == "" {
			t.Errorf("table %q is excluded without a reason", name)
		}
	}
	// New tables export by default: the only way out is a listed reason.
	for name := range schema.Excluded {
		if strings.HasPrefix(name, "river_") || name == "goose_db_version" {
			continue
		}
		t.Logf("excluded: %s: %s", name, schema.Excluded[name])
	}
}

func TestLoadOrderPutsParentsFirstAndBreaksCycles(t *testing.T) {
	pool := testdb.New(t)
	tx, err := pool.Begin(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(t.Context())
	schema, err := transfer.Discover(t.Context(), tx)
	if err != nil {
		t.Fatal(err)
	}
	pos := map[string]int{}
	for i, tb := range schema.Tables {
		pos[tb.Name] = i
	}
	if pos["workspaces"] > pos["tickets"] || pos["projects"] > pos["tickets"] || pos["tickets"] > pos["comments"] {
		t.Errorf("parents must load before children: workspaces=%d projects=%d tickets=%d comments=%d",
			pos["workspaces"], pos["projects"], pos["tickets"], pos["comments"])
	}
	// agents <-> agent_definition_versions is a real cycle: it breaks at one side only.
	var agentKeys int
	for _, d := range schema.Deferred {
		if (d.Table == "agents" && d.Constraint == "agents_current_definition_version_id_fkey") ||
			(d.Table == "agent_definition_versions" && d.Constraint == "agent_definition_versions_agent_id_fkey") {
			agentKeys++
		}
	}
	if agentKeys != 1 {
		t.Errorf("the agents/definition-versions cycle should defer exactly one key, got %d (all: %v)", agentKeys, schema.Deferred)
	}
}

func TestImportRefusals(t *testing.T) {
	src := testdb.New(t)
	seed(t, src)
	const key = "a2V5LWtleS1rZXkta2V5LWtleS1rZXkta2V5LWtleQ=="
	zr, m := exportToZip(t, src, newMemBlobs(), key)
	if m.SecretsKeyFingerprint == "" || strings.Contains(m.SecretsKeyFingerprint, key) {
		t.Fatalf("fingerprint %q should exist and not contain the key", m.SecretsKeyFingerprint)
	}

	t.Run("wrong secrets key", func(t *testing.T) {
		dst := testdb.NewUnmigrated(t)
		err := (&transfer.Importer{Pool: dst, Blobs: newMemBlobs(), SecretsKey: "other"}).Import(t.Context(), zr)
		if err == nil || !strings.Contains(err.Error(), "SECRETS_KEY") {
			t.Fatalf("got %v, want a SECRETS_KEY error", err)
		}
		if v, _ := db.Version(t.Context(), dst); v != 0 {
			t.Errorf("a refused import migrated the target to %d", v)
		}
	})

	t.Run("target has data", func(t *testing.T) {
		dst := testdb.New(t)
		if _, err := dst.Exec(t.Context(), `INSERT INTO workspaces(name,slug) VALUES('Existing','existing')`); err != nil {
			t.Fatal(err)
		}
		err := (&transfer.Importer{Pool: dst, Blobs: newMemBlobs(), SecretsKey: key}).Import(t.Context(), zr)
		if err == nil || !strings.Contains(err.Error(), "--replace") {
			t.Fatalf("got %v, want a refusal that mentions --replace", err)
		}
		// With Replace, the target's rows are discarded and the archive's win.
		if err := (&transfer.Importer{Pool: dst, Blobs: newMemBlobs(), SecretsKey: key, Replace: true}).Import(t.Context(), zr); err != nil {
			t.Fatalf("replace: %v", err)
		}
		var n int
		if err := dst.QueryRow(t.Context(), `SELECT count(*) FROM workspaces WHERE slug='existing'`).Scan(&n); err != nil || n != 0 {
			t.Errorf("replace left the old workspace behind (n=%d, err=%v)", n, err)
		}
	})

	t.Run("corrupt table", func(t *testing.T) {
		var buf bytes.Buffer
		if _, err := (&transfer.Exporter{Pool: src, Blobs: newMemBlobs(), SecretsKey: key}).Export(t.Context(), &buf); err != nil {
			t.Fatal(err)
		}
		bad := corruptEntry(t, buf.Bytes(), "db/tickets.csv")
		dst := testdb.NewUnmigrated(t)
		err := (&transfer.Importer{Pool: dst, Blobs: newMemBlobs(), SecretsKey: key}).Import(t.Context(), bad)
		if err == nil {
			t.Fatal("a corrupt table imported")
		}
		var n int
		if err := dst.QueryRow(t.Context(), `SELECT count(*) FROM workspaces`).Scan(&n); err != nil || n != 0 {
			t.Errorf("a failed import left %d workspaces (err=%v): tables must load all-or-nothing", n, err)
		}
	})

	t.Run("not an export", func(t *testing.T) {
		var buf bytes.Buffer
		zw := zip.NewWriter(&buf)
		_, _ = zw.Create("hello.txt")
		_ = zw.Close()
		zr, _ := zip.NewReader(bytes.NewReader(buf.Bytes()), int64(buf.Len()))
		err := (&transfer.Importer{Pool: testdb.NewUnmigrated(t), Blobs: newMemBlobs()}).Import(t.Context(), zr)
		if err == nil || !strings.Contains(err.Error(), "manifest") {
			t.Fatalf("got %v, want a missing-manifest error", err)
		}
	})
}

// corruptEntry returns the archive with one entry's text changed, keeping the
// manifest (and so its checksums) as it was.
func corruptEntry(t *testing.T, archive []byte, name string) *zip.Reader {
	t.Helper()
	zr, err := zip.NewReader(bytes.NewReader(archive), int64(len(archive)))
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	zw := zip.NewWriter(&out)
	for _, f := range zr.File {
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(rc)
		rc.Close()
		if f.Name == name {
			body = bytes.Replace(body, []byte("Ticket"), []byte("Ticket!"), 1)
		}
		w, _ := zw.Create(f.Name)
		_, _ = w.Write(body)
	}
	_ = zw.Close()
	bad, err := zip.NewReader(bytes.NewReader(out.Bytes()), int64(out.Len()))
	if err != nil {
		t.Fatal(err)
	}
	return bad
}

// hidingBlobs is a store whose ListBuckets returns nothing, as a store that
// won't list buckets does.
type hidingBlobs struct{ *memBlobs }

func (hidingBlobs) ListBuckets(context.Context) ([]string, error) { return nil, nil }

func TestExportIncludesConfiguredBucketsTheStoreWontList(t *testing.T) {
	src := testdb.New(t)
	blobs := newMemBlobs()
	blobs.put("artifacts", "k", "text/plain", []byte("v"))
	var buf bytes.Buffer
	m, err := (&transfer.Exporter{Pool: src, Blobs: hidingBlobs{blobs}, KnownBuckets: []string{"artifacts", "run-logs"}}).Export(t.Context(), &buf)
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Buckets) != 1 || m.Buckets[0].Name != "artifacts" || len(m.Buckets[0].Objects) != 1 {
		t.Errorf("buckets = %+v, want the artifacts object (run-logs doesn't exist, so it is skipped)", m.Buckets)
	}
}

func TestRoundTripLocalBlobStore(t *testing.T) {
	src := testdb.New(t)
	seed(t, src)
	srcDir := t.TempDir()
	srcBlobs := blob.New(config.Blob{Dir: srcDir, Buckets: []string{"artifacts", "run-logs"}})
	ctx := t.Context()
	if err := srcBlobs.EnsureBuckets(ctx); err != nil {
		t.Fatal(err)
	}
	if err := srcBlobs.EnsureBucket(ctx, "empty-bucket"); err != nil {
		t.Fatal(err)
	}
	if err := srcBlobs.EnsureBucket(ctx, "added-next-year"); err != nil {
		t.Fatal(err)
	}
	objects := map[string]map[string]struct {
		ct   string
		body []byte
	}{
		"artifacts": {
			"a/one.png":                     {ct: "image/png", body: []byte{0x89, 'P', 'N', 'G', 0, 1, 2}},
			"weird/../key with spaces?.txt": {ct: "text/plain", body: []byte("hello")},
			"with space/ü.txt":              {ct: "application/octet-stream", body: []byte("unicode")},
		},
		"run-logs": {
			"run/1.log": {ct: "text/plain", body: bytes.Repeat([]byte("log line\n"), 200)},
		},
		"added-next-year": {
			"k": {ct: "application/octet-stream", body: []byte("new feature")},
		},
	}
	for bucket, entries := range objects {
		for k, obj := range entries {
			if err := srcBlobs.Put(ctx, bucket, k, bytes.NewReader(obj.body), int64(len(obj.body)), obj.ct); err != nil {
				t.Fatal(err)
			}
		}
	}

	zr, m := exportToZip(t, src, srcBlobs, "")
	dst := testdb.NewUnmigrated(t)
	dstDir := t.TempDir()
	dstBlobs := blob.NewDir(dstDir, []string{"artifacts", "run-logs"})
	if err := (&transfer.Importer{Pool: dst, Blobs: dstBlobs}).Import(ctx, zr); err != nil {
		t.Fatalf("import into local blob store: %v", err)
	}

	gotBuckets, err := dstBlobs.ListBuckets(ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, wantB := range []string{"added-next-year", "artifacts", "empty-bucket", "run-logs"} {
		if !slices.Contains(gotBuckets, wantB) {
			t.Errorf("bucket %q missing after import: %v", wantB, gotBuckets)
		}
	}
	for _, b := range m.Buckets {
		for _, o := range b.Objects {
			g, err := dstBlobs.Get(ctx, b.Name, o.Key)
			if err != nil {
				t.Fatalf("get %s/%s: %v", b.Name, o.Key, err)
			}
			body, _ := io.ReadAll(g.Body)
			g.Body.Close()
			sum := sha256.Sum256(body)
			if hex.EncodeToString(sum[:]) != o.SHA256 || g.ContentType != o.ContentType {
				t.Errorf("object %s/%s changed across local export/import", b.Name, o.Key)
			}
		}
	}
}

func seedCustomApp(t *testing.T, pool *pgxpool.Pool) (appID string) {
	t.Helper()
	ctx := t.Context()
	var ws, user string
	if err := pool.QueryRow(ctx, `SELECT workspace_id, id FROM users LIMIT 1`).Scan(&ws, &user); err != nil {
		t.Fatalf("lookup user: %v", err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO custom_apps(workspace_id, user_id, slug, name) VALUES($1, $2, 'feed', 'Watch Feed') RETURNING id`, ws, user).Scan(&appID); err != nil {
		t.Fatalf("insert custom app: %v", err)
	}
	return appID
}

func TestExportExcludesCustomAppMedia(t *testing.T) {
	ctx := t.Context()
	src := testdb.New(t)
	seed(t, src)
	appID := seedCustomApp(t, src)

	mediaKey := customapps.MediaBlobPrefix + "/" + appID + "/clip1"
	otherPrefixKey := customapps.MediaBlobPrefix + "-other/keep.txt"
	if _, err := src.Exec(ctx,
		`INSERT INTO custom_app_media(app_id, source_url, state, blob_key, content_type, bytes_done) VALUES($1, 'https://example.com/v.mp4', 'done', $2, 'video/mp4', 4)`,
		appID, mediaKey,
	); err != nil {
		t.Fatalf("insert custom_app_media: %v", err)
	}

	srcBlobs := newMemBlobs()
	srcBlobs.put("artifacts", mediaKey, "video/mp4", []byte("mp4!"))
	srcBlobs.put("artifacts", "a/one.png", "image/png", []byte("png"))
	srcBlobs.put("artifacts", otherPrefixKey, "text/plain", []byte("keep"))

	zr, m := exportToZip(t, src, srcBlobs, "")

	if slices.ContainsFunc(m.Tables, func(te transfer.TableEntry) bool { return te.Name == "custom_app_media" }) {
		t.Error("manifest.Tables unexpectedly includes custom_app_media")
	}
	if !slices.ContainsFunc(m.Tables, func(te transfer.TableEntry) bool { return te.Name == "custom_apps" }) {
		t.Error("manifest.Tables missing custom_apps")
	}
	if slices.ContainsFunc(zr.File, func(f *zip.File) bool { return f.Name == "db/custom_app_media.csv" }) {
		t.Error("archive unexpectedly contains db/custom_app_media.csv")
	}
	artIdx := slices.IndexFunc(m.Buckets, func(b transfer.BucketEntry) bool { return b.Name == "artifacts" })
	if artIdx < 0 {
		t.Fatal("artifacts bucket missing from manifest")
	}
	artKeys := map[string]bool{}
	for _, o := range m.Buckets[artIdx].Objects {
		artKeys[o.Key] = true
	}
	if artKeys[mediaKey] {
		t.Errorf("exported artifacts bucket unexpectedly includes %q", mediaKey)
	}
	if !artKeys["a/one.png"] || !artKeys[otherPrefixKey] {
		t.Errorf("exported artifacts keys = %v, want a/one.png and %s", artKeys, otherPrefixKey)
	}

	dst := testdb.New(t)
	dstBlobs := newMemBlobs()
	if err := (&transfer.Importer{Pool: dst, Blobs: dstBlobs}).Import(ctx, zr); err != nil {
		t.Fatalf("import: %v", err)
	}
	var appsCount, mediaCount int
	if err := dst.QueryRow(ctx, `SELECT count(*) FROM custom_apps WHERE id = $1`, appID).Scan(&appsCount); err != nil || appsCount != 1 {
		t.Errorf("dst custom_apps count = %d (%v), want 1", appsCount, err)
	}
	if err := dst.QueryRow(ctx, `SELECT count(*) FROM custom_app_media`).Scan(&mediaCount); err != nil || mediaCount != 0 {
		t.Errorf("dst custom_app_media count = %d (%v), want 0", mediaCount, err)
	}
	if _, err := dstBlobs.Get(ctx, "artifacts", "a/one.png"); err != nil {
		t.Errorf("dst missing a/one.png: %v", err)
	}
	if _, err := dstBlobs.Get(ctx, "artifacts", otherPrefixKey); err != nil {
		t.Errorf("dst missing %s: %v", otherPrefixKey, err)
	}
	if _, err := dstBlobs.Get(ctx, "artifacts", mediaKey); err != blob.ErrNotFound {
		t.Errorf("dst Get(%q) err = %v, want blob.ErrNotFound", mediaKey, err)
	}
}

func TestImportSkipsLegacyExcludedCustomAppMedia(t *testing.T) {
	ctx := t.Context()
	src := testdb.New(t)
	seed(t, src)
	appID := seedCustomApp(t, src)

	srcBlobs := newMemBlobs()
	srcBlobs.put("artifacts", "a/one.png", "image/png", []byte("png"))
	baseZR, _ := exportToZip(t, src, srcBlobs, "")

	// Build a legacy archive that still includes db/custom_app_media.csv and a custom-app-media/ blob.
	legacyMediaKey := customapps.MediaBlobPrefix + "/legacy/clip"
	mediaBytes := []byte("legacy-mp4")
	mediaSum := sha256.Sum256(mediaBytes)
	csvBody := []byte(fmt.Sprintf(
		"01950000-0000-7000-8000-000000000001,%s,https://example.com/legacy.mp4,done,%s,video/mp4,%d,%d,\"\",2026-11-01T00:00:00Z,2026-11-01T00:00:00Z\n",
		appID, legacyMediaKey, len(mediaBytes), len(mediaBytes),
	))
	csvSum := sha256.Sum256(csvBody)

	var out bytes.Buffer
	zw := zip.NewWriter(&out)
	var manifest transfer.Manifest
	for _, f := range baseZR.File {
		rc, err := f.Open()
		if err != nil {
			t.Fatal(err)
		}
		raw, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			t.Fatal(err)
		}
		if f.Name == "manifest.json" {
			if err := json.Unmarshal(raw, &manifest); err != nil {
				t.Fatal(err)
			}
			continue
		}
		w, err := zw.Create(f.Name)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := w.Write(raw); err != nil {
			t.Fatal(err)
		}
	}

	csvEntry := "db/custom_app_media.csv"
	w, err := zw.Create(csvEntry)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := w.Write(csvBody); err != nil {
		t.Fatal(err)
	}
	manifest.Tables = append(manifest.Tables, transfer.TableEntry{
		Name: "custom_app_media",
		Columns: []transfer.Column{
			{Name: "id", Type: "uuid"},
			{Name: "app_id", Type: "uuid"},
			{Name: "source_url", Type: "text"},
			{Name: "state", Type: "text"},
			{Name: "blob_key", Type: "text"},
			{Name: "content_type", Type: "text"},
			{Name: "bytes_done", Type: "bigint"},
			{Name: "bytes_total", Type: "bigint"},
			{Name: "error", Type: "text"},
			{Name: "created_at", Type: "timestamp with time zone"},
			{Name: "updated_at", Type: "timestamp with time zone"},
		},
		Rows:   1,
		SHA256: hex.EncodeToString(csvSum[:]),
		Entry:  csvEntry,
	})

	blobEntry := "blobs/9999999"
	bw, err := zw.Create(blobEntry)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := bw.Write(mediaBytes); err != nil {
		t.Fatal(err)
	}
	artIdx := slices.IndexFunc(manifest.Buckets, func(b transfer.BucketEntry) bool { return b.Name == "artifacts" })
	if artIdx < 0 {
		t.Fatal("artifacts bucket missing from base manifest")
	}
	manifest.Buckets[artIdx].Objects = append(manifest.Buckets[artIdx].Objects, transfer.ObjectEntry{
		Key:         legacyMediaKey,
		Size:        int64(len(mediaBytes)),
		SHA256:      hex.EncodeToString(mediaSum[:]),
		ContentType: "video/mp4",
		Entry:       blobEntry,
	})

	mw, err := zw.Create("manifest.json")
	if err != nil {
		t.Fatal(err)
	}
	if err := json.NewEncoder(mw).Encode(&manifest); err != nil {
		t.Fatal(err)
	}
	if err := zw.Close(); err != nil {
		t.Fatal(err)
	}
	legacyZR, err := zip.NewReader(bytes.NewReader(out.Bytes()), int64(out.Len()))
	if err != nil {
		t.Fatal(err)
	}

	dst := testdb.New(t)
	dstBlobs := newMemBlobs()
	if err := (&transfer.Importer{Pool: dst, Blobs: dstBlobs}).Import(ctx, legacyZR); err != nil {
		t.Fatalf("import legacy archive: %v", err)
	}
	var appsCount, mediaCount, ticketsCount int
	if err := dst.QueryRow(ctx, `SELECT count(*) FROM custom_apps WHERE id = $1`, appID).Scan(&appsCount); err != nil || appsCount != 1 {
		t.Errorf("dst custom_apps count = %d (%v), want 1", appsCount, err)
	}
	if err := dst.QueryRow(ctx, `SELECT count(*) FROM custom_app_media`).Scan(&mediaCount); err != nil || mediaCount != 0 {
		t.Errorf("dst custom_app_media count = %d (%v), want 0", mediaCount, err)
	}
	if err := dst.QueryRow(ctx, `SELECT count(*) FROM tickets`).Scan(&ticketsCount); err != nil || ticketsCount != 3 {
		t.Errorf("dst tickets count = %d (%v), want 3", ticketsCount, err)
	}
	if _, err := dstBlobs.Get(ctx, "artifacts", "a/one.png"); err != nil {
		t.Errorf("dst missing a/one.png: %v", err)
	}
	if _, err := dstBlobs.Get(ctx, "artifacts", legacyMediaKey); err != blob.ErrNotFound {
		t.Errorf("dst Get(%q) err = %v, want blob.ErrNotFound", legacyMediaKey, err)
	}
}

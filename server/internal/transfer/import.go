package transfer

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path"
	"path/filepath"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/db"
)

// Importer loads an archive into another instance.
type Importer struct {
	Pool  *pgxpool.Pool
	Blobs Blobs
	// SecretsKey is this instance's SECRETS_KEY. Exported secrets are sealed
	// with the source's key, so it must match.
	SecretsKey string
	// Replace wipes any rows the exported tables already hold. Without it,
	// import refuses a target that has data.
	Replace bool
	// DropSecrets skips the SECRETS_KEY fingerprint check and clears imported
	// secret ciphertexts after migration.
	DropSecrets bool
	Log         *slog.Logger
}

// Import checks the archive, uploads its objects, loads its tables in one
// transaction, then runs any migrations newer than the archive.
//
// Objects go first so a failed import leaves the database untouched and can be
// run again as it was. The tables are all-or-nothing.
func (i *Importer) Import(ctx context.Context, zr *zip.Reader) error {
	files, err := indexZipEntries(zr)
	if err != nil {
		return err
	}
	return i.importFromEntries(ctx, files)
}

// ImportDir loads an unpacked Vesper export directory (e.g. a Safari-unpacked
// download folder containing manifest.json, db/, and blobs/).
func (i *Importer) ImportDir(ctx context.Context, dir string) error {
	resolved, err := resolveExportDir(dir)
	if err != nil {
		return err
	}
	root, err := os.OpenRoot(resolved)
	if err != nil {
		return fmt.Errorf("transfer: open export dir: %w", err)
	}
	defer root.Close()

	st, err := root.Stat(manifestName)
	if err != nil || st.IsDir() {
		return errors.New("transfer: not a Vesper export (no manifest.json)")
	}
	m, err := readManifest(map[string]archiveEntry{
		manifestName: rootFileEntry{root: root, name: manifestName, size: st.Size()},
	})
	if err != nil {
		return err
	}
	files := indexDirEntries(root, m, st.Size())
	return i.importFromEntries(ctx, files)
}

// InspectArchivePath reads manifest.json from either a Vesper .zip archive
// (flat or nested under a single top-level directory) or an unpacked export folder.
func InspectArchivePath(archivePath string) (*Manifest, error) {
	st, err := os.Stat(archivePath)
	if err != nil {
		return nil, fmt.Errorf("transfer: inspect %s: %w", archivePath, err)
	}
	if st.IsDir() {
		resolved, err := resolveExportDir(archivePath)
		if err != nil {
			return nil, err
		}
		root, err := os.OpenRoot(resolved)
		if err != nil {
			return nil, fmt.Errorf("transfer: open export dir: %w", err)
		}
		defer root.Close()
		mst, err := root.Stat(manifestName)
		if err != nil || mst.IsDir() {
			return nil, errors.New("transfer: not a Vesper export (no manifest.json)")
		}
		return readManifest(map[string]archiveEntry{
			manifestName: rootFileEntry{root: root, name: manifestName, size: mst.Size()},
		})
	}
	zr, err := zip.OpenReader(archivePath)
	if err != nil {
		return nil, fmt.Errorf("transfer: open archive: %w", err)
	}
	defer zr.Close()
	files, err := indexZipEntries(&zr.Reader)
	if err != nil {
		return nil, err
	}
	return readManifest(files)
}

func (i *Importer) importFromEntries(ctx context.Context, files map[string]archiveEntry) error {
	log := i.Log
	if log == nil {
		log = slog.Default()
	}
	m, err := readManifest(files)
	if err != nil {
		return err
	}
	if err := i.preflight(ctx, m, files, log); err != nil {
		return err
	}
	if err := i.importBlobs(ctx, m, files, log); err != nil {
		return err
	}
	if err := i.importTables(ctx, m, files, log); err != nil {
		return err
	}
	// Rows are in the schema they were exported from; bring it up to date.
	if err := db.Migrate(ctx, i.Pool); err != nil {
		return fmt.Errorf("transfer: rows loaded, but upgrading the schema failed: %w", err)
	}
	if i.DropSecrets {
		if err := dropEncryptedSecrets(ctx, i.Pool); err != nil {
			return fmt.Errorf("transfer: rows loaded, but clearing undecryptable secrets failed: %w", err)
		}
	}
	return nil
}

type archiveEntry interface {
	Open() (io.ReadCloser, error)
	Size() int64
}

type zipEntry struct{ f *zip.File }

func (z zipEntry) Open() (io.ReadCloser, error) { return z.f.Open() }
func (z zipEntry) Size() int64                  { return int64(z.f.UncompressedSize64) }

type rootFileEntry struct {
	root *os.Root
	name string
	size int64
}

func (r rootFileEntry) Open() (io.ReadCloser, error) { return r.root.Open(r.name) }
func (r rootFileEntry) Size() int64                  { return r.size }

func isIgnoredArchivePath(name string) bool {
	if name == "" || name == "." {
		return true
	}
	for _, seg := range strings.Split(name, "/") {
		if seg == "__MACOSX" {
			return true
		}
	}
	base := path.Base(name)
	return base == ".DS_Store" || strings.HasPrefix(base, "._")
}

func indexZipEntries(zr *zip.Reader) (map[string]archiveEntry, error) {
	raw := make(map[string]archiveEntry, len(zr.File))
	var manifestCandidates []string
	for _, f := range zr.File {
		if f.FileInfo().IsDir() {
			continue
		}
		norm := strings.TrimPrefix(path.Clean(strings.ReplaceAll(f.Name, "\\", "/")), "./")
		if isIgnoredArchivePath(norm) {
			continue
		}
		raw[norm] = zipEntry{f: f}
		if norm == manifestName || strings.HasSuffix(norm, "/"+manifestName) {
			manifestCandidates = append(manifestCandidates, norm)
		}
	}
	if _, ok := raw[manifestName]; ok {
		return raw, nil
	}
	if len(manifestCandidates) != 1 {
		return raw, nil
	}
	prefix := strings.TrimSuffix(manifestCandidates[0], manifestName)
	out := make(map[string]archiveEntry, len(raw))
	for name, entry := range raw {
		if strings.HasPrefix(name, prefix) {
			out[strings.TrimPrefix(name, prefix)] = entry
		}
	}
	return out, nil
}

func resolveExportDir(dir string) (string, error) {
	resolved, err := filepath.EvalSymlinks(dir)
	if err != nil {
		resolved = dir
	}
	if st, err := os.Stat(filepath.Join(resolved, manifestName)); err == nil && !st.IsDir() {
		return resolved, nil
	}
	entries, err := os.ReadDir(resolved)
	if err != nil {
		return "", fmt.Errorf("transfer: read export dir: %w", err)
	}
	var match string
	for _, e := range entries {
		if !e.IsDir() || strings.HasPrefix(e.Name(), ".") || e.Name() == "__MACOSX" {
			continue
		}
		cand := filepath.Join(resolved, e.Name())
		if st, serr := os.Stat(filepath.Join(cand, manifestName)); serr == nil && !st.IsDir() {
			if match != "" {
				return "", errors.New("transfer: multiple export subdirectories contain manifest.json; choose one directly")
			}
			match = cand
		}
	}
	if match == "" {
		return "", errors.New("transfer: not a Vesper export (no manifest.json)")
	}
	if subResolved, err := filepath.EvalSymlinks(match); err == nil {
		return subResolved, nil
	}
	return match, nil
}

func indexDirEntries(root *os.Root, m *Manifest, manifestSize int64) map[string]archiveEntry {
	files := map[string]archiveEntry{
		manifestName: rootFileEntry{root: root, name: manifestName, size: manifestSize},
	}
	add := func(entryName string) {
		rel := filepath.FromSlash(entryName)
		if st, err := root.Stat(rel); err == nil && !st.IsDir() {
			files[entryName] = rootFileEntry{root: root, name: rel, size: st.Size()}
		}
	}
	for _, t := range m.Tables {
		add(t.Entry)
	}
	for _, b := range m.Buckets {
		for _, o := range b.Objects {
			add(o.Entry)
		}
	}
	return files
}

func dropEncryptedSecrets(ctx context.Context, pool *pgxpool.Pool) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	for _, stmt := range []string{
		`DELETE FROM secrets`,
		`DELETE FROM user_secrets`,
		`UPDATE connectors SET cred_nonce = NULL, cred_ciphertext = NULL`,
	} {
		if _, err := tx.Exec(ctx, stmt); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func readManifest(files map[string]archiveEntry) (*Manifest, error) {
	f, ok := files[manifestName]
	if !ok {
		return nil, errors.New("transfer: not a Vesper export (no manifest.json)")
	}
	rc, err := f.Open()
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	var m Manifest
	if err := json.NewDecoder(rc).Decode(&m); err != nil {
		return nil, fmt.Errorf("transfer: read manifest: %w", err)
	}
	if m.Format != FormatVersion {
		return nil, fmt.Errorf("transfer: archive format %d isn't supported (this build reads %d)", m.Format, FormatVersion)
	}
	return &m, nil
}

// preflight refuses anything that would fail or do damage before it changes
// the target: a mismatched key, a newer export, a target with data.
func (i *Importer) preflight(ctx context.Context, m *Manifest, files map[string]archiveEntry, log *slog.Logger) error {
	if !i.DropSecrets && m.SecretsKeyFingerprint != "" && KeyFingerprint(i.SecretsKey) != m.SecretsKeyFingerprint {
		return errors.New("transfer: this export holds secrets sealed with a different SECRETS_KEY; " +
			"set SECRETS_KEY to the source instance's value, or the secrets can't be read")
	}
	latest, err := db.LatestVersion()
	if err != nil {
		return err
	}
	if m.SchemaVersion > latest {
		return fmt.Errorf("transfer: the export is from a newer Vesper (schema %d, this build knows %d); upgrade this instance first", m.SchemaVersion, latest)
	}
	cur, err := db.Version(ctx, i.Pool)
	if err != nil {
		return err
	}
	switch {
	case cur > m.SchemaVersion:
		return fmt.Errorf("transfer: the target's schema (%d) is newer than the export's (%d); "+
			"import into an empty database that hasn't been migrated, or re-export from an up-to-date source", cur, m.SchemaVersion)
	case cur < m.SchemaVersion:
		log.Info("migrating target to the export's schema", "from", cur, "to", m.SchemaVersion)
		if err := db.MigrateTo(ctx, i.Pool, m.SchemaVersion); err != nil {
			return err
		}
	}
	for _, t := range m.Tables {
		if _, ok := files[t.Entry]; !ok {
			return fmt.Errorf("transfer: archive is missing %s", t.Entry)
		}
	}
	for _, b := range m.Buckets {
		for _, o := range b.Objects {
			if _, ok := files[o.Entry]; !ok {
				return fmt.Errorf("transfer: archive is missing %s (%s/%s)", o.Entry, b.Name, o.Key)
			}
		}
	}
	return i.checkTarget(ctx, m)
}

// checkTarget confirms the target has the exported tables and columns, and no
// data unless Replace says to discard it.
func (i *Importer) checkTarget(ctx context.Context, m *Manifest) error {
	tx, err := i.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	schema, err := Discover(ctx, tx)
	if err != nil {
		return err
	}
	have := map[string]Table{}
	for _, t := range schema.Tables {
		have[t.Name] = t
	}
	var withRows []string
	for _, te := range m.Tables {
		t, ok := have[te.Name]
		if !ok {
			return fmt.Errorf("transfer: the target has no table %q", te.Name)
		}
		if !sameColumns(t.Columns, te.Columns) {
			return fmt.Errorf("transfer: table %q has different columns on the target than in the export", te.Name)
		}
		var has bool
		if err := tx.QueryRow(ctx, fmt.Sprintf("SELECT EXISTS (SELECT 1 FROM %s)", pgx.Identifier{te.Name}.Sanitize())).Scan(&has); err != nil {
			return err
		}
		if has {
			withRows = append(withRows, te.Name)
		}
	}
	if len(withRows) > 0 && !i.Replace {
		if len(withRows) > 5 {
			withRows = append(withRows[:5], "...")
		}
		return fmt.Errorf("transfer: the target already has data (%s); import into a fresh instance, or pass --replace to discard it", strings.Join(withRows, ", "))
	}
	return nil
}

func sameColumns(a, b []Column) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if a[k].Name != b[k].Name {
			return false
		}
	}
	return true
}

func (i *Importer) importBlobs(ctx context.Context, m *Manifest, files map[string]archiveEntry, log *slog.Logger) error {
	for _, b := range m.Buckets {
		if err := i.Blobs.EnsureBucket(ctx, b.Name); err != nil {
			return err
		}
		for _, o := range b.Objects {
			if err := i.importObject(ctx, b.Name, o, files[o.Entry]); err != nil {
				return err
			}
		}
		log.Info("imported bucket", "bucket", b.Name, "objects", len(b.Objects))
	}
	return nil
}

// spoolLimit is the largest object held in memory while it is checked and
// uploaded; bigger ones go through a temp file.
const spoolLimit = 8 << 20

func (i *Importer) importObject(ctx context.Context, bucket string, o ObjectEntry, f archiveEntry) error {
	if f.Size() != o.Size {
		return fmt.Errorf("transfer: %s/%s is %d bytes in the archive, the manifest says %d", bucket, o.Key, f.Size(), o.Size)
	}
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	// The object is read through once here, spooled so it can be re-read. That also checks it before anything is stored.
	body, cleanup, err := spool(rc, o.Size)
	if err != nil {
		return fmt.Errorf("transfer: read %s/%s from the archive: %w", bucket, o.Key, err)
	}
	defer cleanup()
	sum := sha256.New()
	if _, err := io.Copy(sum, body); err != nil {
		return err
	}
	if got := hex.EncodeToString(sum.Sum(nil)); got != o.SHA256 {
		return fmt.Errorf("transfer: %s/%s is corrupt in the archive (checksum mismatch)", bucket, o.Key)
	}
	if _, err := body.Seek(0, io.SeekStart); err != nil {
		return err
	}
	return i.Blobs.Put(ctx, bucket, o.Key, body, o.Size, o.ContentType)
}

type seekReader interface {
	io.Reader
	io.Seeker
}

// spool copies r into something seekable, in memory when small. The returned
// cleanup must be called.
func spool(r io.Reader, size int64) (seekReader, func(), error) {
	if size <= spoolLimit {
		b, err := io.ReadAll(r)
		if err != nil {
			return nil, func() {}, err
		}
		return bytes.NewReader(b), func() {}, nil
	}
	tmp, err := os.CreateTemp("", "vesper-import-*")
	if err != nil {
		return nil, func() {}, err
	}
	cleanup := func() { tmp.Close(); os.Remove(tmp.Name()) }
	if _, err := io.Copy(tmp, r); err != nil {
		cleanup()
		return nil, func() {}, err
	}
	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		cleanup()
		return nil, func() {}, err
	}
	return tmp, cleanup, nil
}

func (i *Importer) importTables(ctx context.Context, m *Manifest, files map[string]archiveEntry, log *slog.Logger) error {
	tx, err := i.Pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	schema, err := Discover(ctx, tx)
	if err != nil {
		return err
	}
	byName := map[string]TableEntry{}
	for _, te := range m.Tables {
		byName[te.Name] = te
	}
	id := func(s string) string { return pgx.Identifier{s}.Sanitize() }

	// Load in dependency order. Tables the archive doesn't have (excluded ones
	// are never in it) are left alone.
	var load []Table
	for _, t := range schema.Tables {
		if _, ok := byName[t.Name]; ok {
			load = append(load, t)
		}
	}
	if i.Replace {
		names := make([]string, len(load))
		for k, t := range load {
			names[k] = id(t.Name)
		}
		if len(names) > 0 {
			if _, err := tx.Exec(ctx, "TRUNCATE "+strings.Join(names, ", ")+" CASCADE"); err != nil {
				return fmt.Errorf("transfer: clear target: %w", err)
			}
		}
	}
	// Triggers that stamp updated_at or publish change events would rewrite
	// the rows being restored.
	for _, t := range load {
		if _, err := tx.Exec(ctx, "ALTER TABLE "+id(t.Name)+" DISABLE TRIGGER USER"); err != nil {
			return fmt.Errorf("transfer: pause triggers on %s: %w", t.Name, err)
		}
	}
	for _, d := range schema.Deferred {
		if _, ok := byName[d.Table]; !ok {
			continue
		}
		if _, err := tx.Exec(ctx, "ALTER TABLE "+id(d.Table)+" ALTER CONSTRAINT "+id(d.Constraint)+" DEFERRABLE INITIALLY DEFERRED"); err != nil {
			return fmt.Errorf("transfer: defer %s: %w", d.Constraint, err)
		}
	}
	for _, t := range load {
		te := byName[t.Name]
		if err := copyTable(ctx, tx, t, te, files[te.Entry]); err != nil {
			return err
		}
		log.Info("imported table", "table", t.Name, "rows", te.Rows)
	}
	// Check the deferred keys now, so a bad row fails the import here.
	if _, err := tx.Exec(ctx, "SET CONSTRAINTS ALL IMMEDIATE"); err != nil {
		return fmt.Errorf("transfer: rows break a foreign key: %w", err)
	}
	for _, d := range schema.Deferred {
		if _, ok := byName[d.Table]; !ok {
			continue
		}
		if _, err := tx.Exec(ctx, "ALTER TABLE "+id(d.Table)+" ALTER CONSTRAINT "+id(d.Constraint)+" NOT DEFERRABLE"); err != nil {
			return fmt.Errorf("transfer: restore %s: %w", d.Constraint, err)
		}
	}
	for _, t := range load {
		if _, err := tx.Exec(ctx, "ALTER TABLE "+id(t.Name)+" ENABLE TRIGGER USER"); err != nil {
			return fmt.Errorf("transfer: resume triggers on %s: %w", t.Name, err)
		}
	}
	for _, s := range schema.Sequences {
		if _, ok := byName[s.Table]; !ok {
			continue
		}
		q := fmt.Sprintf("SELECT setval($1::regclass, COALESCE(max(%[1]s), 1), max(%[1]s) IS NOT NULL) FROM %[2]s", id(s.Column), id(s.Table))
		if _, err := tx.Exec(ctx, q, s.Name); err != nil {
			return fmt.Errorf("transfer: reset sequence %s: %w", s.Name, err)
		}
	}
	return tx.Commit(ctx)
}

func copyTable(ctx context.Context, tx pgx.Tx, t Table, te TableEntry, f archiveEntry) error {
	rc, err := f.Open()
	if err != nil {
		return err
	}
	defer rc.Close()
	sum := sha256.New()
	tag, err := tx.Conn().PgConn().CopyFrom(ctx, io.TeeReader(rc, sum), copyInSQL(t))
	if err != nil {
		return fmt.Errorf("transfer: load %s: %w", t.Name, err)
	}
	if got := hex.EncodeToString(sum.Sum(nil)); got != te.SHA256 {
		return fmt.Errorf("transfer: %s is corrupt in the archive (checksum mismatch)", t.Name)
	}
	if tag.RowsAffected() != te.Rows {
		return fmt.Errorf("transfer: %s loaded %d rows, the export has %d", t.Name, tag.RowsAffected(), te.Rows)
	}
	return nil
}

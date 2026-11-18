package transfer

import (
	"archive/zip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"slices"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/blob"
)

// Exporter writes an archive of the database and the object store.
type Exporter struct {
	Pool       *pgxpool.Pool
	Blobs      Blobs
	AppVersion string
	// SecretsKey is the instance's SECRETS_KEY (may be empty). Only a
	// fingerprint of it goes in the archive.
	SecretsKey string
	// KnownBuckets are the buckets the server is configured to use. They are
	// exported even when the store doesn't list them.
	KnownBuckets []string
	Log          *slog.Logger
}

// Export streams the archive to w. The database is read in one repeatable-read
// snapshot, so tables agree with each other; objects are read afterwards, so a
// blob may be newer than the rows that point to it, and one deleted in between
// is skipped.
func (e *Exporter) Export(ctx context.Context, w io.Writer) (*Manifest, error) {
	log := e.Log
	if log == nil {
		log = slog.Default()
	}
	zw := zip.NewWriter(w)
	m := &Manifest{
		Format:                FormatVersion,
		ExportedAt:            time.Now().UTC(),
		AppVersion:            e.AppVersion,
		SecretsKeyFingerprint: KeyFingerprint(e.SecretsKey),
		Tables:                []TableEntry{},
		Buckets:               []BucketEntry{},
	}
	if err := e.exportTables(ctx, zw, m, log); err != nil {
		return nil, err
	}
	if err := e.exportBlobs(ctx, zw, m, log); err != nil {
		return nil, err
	}
	mw, err := zw.CreateHeader(&zip.FileHeader{Name: manifestName, Method: zip.Deflate, Modified: m.ExportedAt})
	if err != nil {
		return nil, err
	}
	enc := json.NewEncoder(mw)
	enc.SetIndent("", " ")
	if err := enc.Encode(m); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, fmt.Errorf("transfer: finish archive: %w", err)
	}
	return m, nil
}

func (e *Exporter) exportTables(ctx context.Context, zw *zip.Writer, m *Manifest, log *slog.Logger) error {
	conn, err := e.Pool.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("transfer: connect: %w", err)
	}
	defer conn.Release()
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return fmt.Errorf("transfer: begin snapshot: %w", err)
	}
	defer tx.Rollback(ctx)

	if err := tx.QueryRow(ctx, `SELECT COALESCE(max(version_id), 0) FROM goose_db_version WHERE is_applied`).Scan(&m.SchemaVersion); err != nil {
		return fmt.Errorf("transfer: read schema version: %w", err)
	}
	schema, err := Discover(ctx, tx)
	if err != nil {
		return err
	}
	for _, t := range schema.Tables {
		entry := "db/" + t.Name + ".csv"
		fw, err := zw.CreateHeader(&zip.FileHeader{Name: entry, Method: zip.Deflate, Modified: m.ExportedAt})
		if err != nil {
			return err
		}
		sum := sha256.New()
		tag, err := tx.Conn().PgConn().CopyTo(ctx, io.MultiWriter(fw, sum), copyOutSQL(t))
		if err != nil {
			return fmt.Errorf("transfer: export %s: %w", t.Name, err)
		}
		m.Tables = append(m.Tables, TableEntry{
			Name: t.Name, Columns: t.Columns, Rows: tag.RowsAffected(), SHA256: hex.EncodeToString(sum.Sum(nil)), Entry: entry,
		})
		log.Info("exported table", "table", t.Name, "rows", tag.RowsAffected())
	}
	return nil
}

func copyOutSQL(t Table) string {
	return fmt.Sprintf("COPY (SELECT %s FROM %s) TO STDOUT WITH (FORMAT csv)", columnList(t), pgx.Identifier{t.Name}.Sanitize())
}

func copyInSQL(t Table) string {
	return fmt.Sprintf("COPY %s (%s) FROM STDIN WITH (FORMAT csv)", pgx.Identifier{t.Name}.Sanitize(), columnList(t))
}

func columnList(t Table) string {
	names := make([]string, len(t.Columns))
	for i, c := range t.Columns {
		names[i] = pgx.Identifier{c.Name}.Sanitize()
	}
	return strings.Join(names, ", ")
}

func (e *Exporter) exportBlobs(ctx context.Context, zw *zip.Writer, m *Manifest, log *slog.Logger) error {
	buckets, err := e.Blobs.ListBuckets(ctx)
	if err != nil {
		return err
	}
	for _, b := range e.KnownBuckets {
		if !slices.Contains(buckets, b) {
			buckets = append(buckets, b)
		}
	}
	slices.Sort(buckets)
	n := 0
	for _, bucket := range buckets {
		var infos []blob.Info
		err := e.Blobs.List(ctx, bucket, func(i blob.Info) error { infos = append(infos, i); return nil })
		if errors.Is(err, blob.ErrNotFound) && slices.Contains(e.KnownBuckets, bucket) {
			log.Info("configured bucket doesn't exist yet, skipped", "bucket", bucket)
			continue
		}
		if err != nil {
			return err
		}
		be := BucketEntry{Name: bucket, Objects: []ObjectEntry{}}
		for _, info := range infos {
			oe, err := e.exportObject(ctx, zw, m.ExportedAt, bucket, info.Key, n)
			if errors.Is(err, blob.ErrNotFound) {
				log.Warn("object deleted during export, skipped", "bucket", bucket, "key", info.Key)
				continue
			}
			if err != nil {
				return err
			}
			n++
			be.Objects = append(be.Objects, oe)
		}
		m.Buckets = append(m.Buckets, be)
		log.Info("exported bucket", "bucket", bucket, "objects", len(be.Objects))
	}
	return nil
}

func (e *Exporter) exportObject(ctx context.Context, zw *zip.Writer, modified time.Time, bucket, key string, n int) (ObjectEntry, error) {
	obj, err := e.Blobs.Get(ctx, bucket, key)
	if err != nil {
		return ObjectEntry{}, err
	}
	defer obj.Body.Close()
	entry := fmt.Sprintf("blobs/%07d", n)
	// Images, video and the like are already compressed; deflating them only costs CPU.
	method := zip.Store
	if compressible(obj.ContentType) {
		method = zip.Deflate
	}
	fw, err := zw.CreateHeader(&zip.FileHeader{Name: entry, Method: method, Modified: modified})
	if err != nil {
		return ObjectEntry{}, err
	}
	sum := sha256.New()
	size, err := io.Copy(io.MultiWriter(fw, sum), obj.Body)
	if err != nil {
		return ObjectEntry{}, fmt.Errorf("transfer: read %s/%s: %w", bucket, key, err)
	}
	return ObjectEntry{Key: key, Size: size, SHA256: hex.EncodeToString(sum.Sum(nil)), ContentType: obj.ContentType, Entry: entry}, nil
}

func compressible(contentType string) bool {
	switch {
	case contentType == "":
		return true
	case strings.HasPrefix(contentType, "text/"), strings.Contains(contentType, "json"),
		strings.Contains(contentType, "xml"), strings.Contains(contentType, "yaml"), strings.Contains(contentType, "svg"):
		return true
	}
	return false
}

// Package transfer moves a whole Vesper instance between machines: every
// Postgres table and every object in the blob store, in one zip archive.
//
// Nothing here lists tables or buckets by hand. Export reads the catalog and
// the bucket listing, so a table or bucket added later travels automatically;
// schema.go holds the short list of things deliberately left out, and the tests
// fail when a table is neither exported nor on that list.
package transfer

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"strings"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/blob"
)

// FormatVersion is the archive layout. Bump it when an old importer could
// misread a new archive.
const FormatVersion = 1

// manifestName is the archive entry that describes the rest. It is written
// last, because it carries checksums computed while the others stream out.
const manifestName = "manifest.json"

// Manifest describes an archive.
type Manifest struct {
	Format     int       `json:"format"`
	ExportedAt time.Time `json:"exported_at"`
	AppVersion string    `json:"app_version"`
	// SchemaVersion is the newest migration applied on the source. Import
	// loads the rows into that schema, then runs any newer migrations.
	SchemaVersion int64 `json:"schema_version"`
	// SecretsKeyFingerprint identifies the SECRETS_KEY that sealed the exported
	// secrets, without revealing it. Empty when the source had no key.
	SecretsKeyFingerprint string        `json:"secrets_key_fingerprint,omitempty"`
	Tables                []TableEntry  `json:"tables"`
	Buckets               []BucketEntry `json:"buckets"`
}

// TableEntry is one table's rows, stored as CSV from COPY.
type TableEntry struct {
	Name    string   `json:"name"`
	Columns []Column `json:"columns"`
	Rows    int64    `json:"rows"`
	SHA256  string   `json:"sha256"`
	Entry   string   `json:"entry"`
}

// BucketEntry is one bucket and its objects.
type BucketEntry struct {
	Name    string        `json:"name"`
	Objects []ObjectEntry `json:"objects"`
}

// ObjectEntry is one stored object. Its bytes sit in an archive entry named by
// number, so odd keys never become file paths.
type ObjectEntry struct {
	Key         string `json:"key"`
	Size        int64  `json:"size"`
	SHA256      string `json:"sha256"`
	ContentType string `json:"content_type,omitempty"`
	Entry       string `json:"entry"`
}

// Blobs is the blob store the archive reads from and writes to (blob.Store).
type Blobs interface {
	ListBuckets(ctx context.Context) ([]string, error)
	List(ctx context.Context, bucket string, fn func(blob.Info) error) error
	Get(ctx context.Context, bucket, key string) (blob.Object, error)
	Put(ctx context.Context, bucket, key string, body io.Reader, size int64, contentType string) error
	EnsureBucket(ctx context.Context, bucket string) error
}

// KeyFingerprint identifies a SECRETS_KEY without revealing it: an HMAC keyed
// by the key itself, so it can't be used to guess the key or compared with
// another system's. Empty for no key.
func KeyFingerprint(secretsKey string) string {
	k := strings.TrimSpace(secretsKey)
	if k == "" {
		return ""
	}
	mac := hmac.New(sha256.New, []byte(k))
	mac.Write([]byte("vesper export key check v1"))
	return hex.EncodeToString(mac.Sum(nil))[:32]
}

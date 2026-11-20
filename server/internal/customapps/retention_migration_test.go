package customapps

import (
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// preRetentionSchema is the last migration before custom apps kept only their newest
// MaxStoredVersions versions (00163_custom_app_version_retention).
const preRetentionSchema = 162

// Apps saved before version retention are trimmed to their newest 10 versions,
// and apps with fewer keep everything.
func TestRetentionMigrationTrimsOldVersions(t *testing.T) {
	ctx := t.Context()
	pool := testdb.NewUnmigrated(t)
	if err := db.MigrateTo(ctx, pool, preRetentionSchema); err != nil {
		t.Fatal(err)
	}
	var ws, user string
	if err := pool.QueryRow(ctx, `INSERT INTO workspaces(name,slug) VALUES('Acme','acme') RETURNING id`).Scan(&ws); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO users(workspace_id,name,email,initials,password_hash) VALUES($1,'Ann','ann@example.com','A','x') RETURNING id`, ws).Scan(&user); err != nil {
		t.Fatal(err)
	}
	appWithVersions := func(slug string, n int) string {
		t.Helper()
		var id string
		if err := pool.QueryRow(ctx, `INSERT INTO custom_apps(workspace_id,user_id,slug,name,current_seq) VALUES($1,$2,$3,$3,$4) RETURNING id`, ws, user, slug, n).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `INSERT INTO custom_app_versions(app_id,seq,author_type,manifest,files,bundle_js)
			SELECT $1, s, 'user', '{}', '{}', '' FROM generate_series(1, $2::int) s`, id, n); err != nil {
			t.Fatal(err)
		}
		return id
	}
	big := appWithVersions("feed", 39)
	small := appWithVersions("notes", 4)

	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatal(err)
	}
	seqRange := func(app string) (n, lo, hi int) {
		t.Helper()
		if err := pool.QueryRow(ctx, `SELECT count(*), coalesce(min(seq),0), coalesce(max(seq),0) FROM custom_app_versions WHERE app_id=$1`, app).Scan(&n, &lo, &hi); err != nil {
			t.Fatal(err)
		}
		return n, lo, hi
	}
	if n, lo, hi := seqRange(big); n != MaxStoredVersions || lo != 30 || hi != 39 {
		t.Errorf("feed kept %d versions v%d..v%d, want 10 versions v30..v39", n, lo, hi)
	}
	if n, lo, hi := seqRange(small); n != 4 || lo != 1 || hi != 4 {
		t.Errorf("notes kept %d versions v%d..v%d, want all 4", n, lo, hi)
	}
}

package db_test

import (
	"testing"
	"time"

	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

// Helpers ("sub" agents) stop working: archived, their runs kept, and main
// records from then on, so the schema no longer allows "sub".
func TestRetireSubAgentsMigration(t *testing.T) {
	f := newConstraintFixture(t)
	ctx := t.Context()
	sqlDB := stdlib.OpenDBFromPool(f.pool)
	defer sqlDB.Close()
	if err := goose.DownToContext(ctx, sqlDB, ".", 164); err != nil {
		t.Fatal(err)
	}
	var live, gone string
	if err := f.pool.QueryRow(ctx, `INSERT INTO agents(workspace_id,name,handle,kind) VALUES($1,'Scribe','scribe','sub') RETURNING id`, f.ws).Scan(&live); err != nil {
		t.Fatal(err)
	}
	if err := f.pool.QueryRow(ctx, `INSERT INTO agents(workspace_id,name,handle,kind,archived_at) VALUES($1,'Old','old','sub','2026-01-02T00:00:00Z') RETURNING id`, f.ws).Scan(&gone); err != nil {
		t.Fatal(err)
	}
	if err := goose.UpContext(ctx, sqlDB, "."); err != nil {
		t.Fatal(err)
	}
	for id, wantArchivedAt := range map[string]*time.Time{live: nil, gone: new(time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC))} {
		var kind string
		var archivedAt *time.Time
		if err := f.pool.QueryRow(ctx, `SELECT kind, archived_at FROM agents WHERE id=$1`, id).Scan(&kind, &archivedAt); err != nil {
			t.Fatal(err)
		}
		if kind != "main" || archivedAt == nil || (wantArchivedAt != nil && !archivedAt.Equal(*wantArchivedAt)) {
			t.Errorf("agent %s: kind %q archived_at %v; want main, archived (keeping an earlier archive time)", id, kind, archivedAt)
		}
	}
	var mainKind string
	if err := f.pool.QueryRow(ctx, `SELECT kind FROM agents WHERE id=$1`, f.agent).Scan(&mainKind); err != nil || mainKind != "main" {
		t.Fatalf("the fixture's main agent: %q %v", mainKind, err)
	}
	rejects(t, f.pool, map[string]string{"sub kind": `INSERT INTO agents(workspace_id,name,handle,kind) VALUES($1,'S','s2','sub')`}, f.ws)

	if err := goose.DownToContext(ctx, sqlDB, ".", 164); err != nil {
		t.Fatal(err)
	}
	mustExec(t, f.pool, `INSERT INTO agents(workspace_id,name,handle,kind) VALUES($1,'S','s3','sub')`, f.ws)
	mustExec(t, f.pool, `DELETE FROM agents WHERE handle='s3'`)
	if err := goose.UpContext(ctx, sqlDB, "."); err != nil {
		t.Fatal(err)
	}
}

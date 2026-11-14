package transfer_test

import (
	"testing"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

// preCanvasPagesSchema is the last migration before decks and designs became Knowledge pages
// (00130_canvas_pages, LAZYAGENTS-212).
const preCanvasPagesSchema = 129

// deckIn makes a chat holding a deck and a design in pool, returning the deck's and design's ids.
func deckIn(t *testing.T, pool *pgxpool.Pool) (deck, design string) {
	t.Helper()
	ctx := t.Context()
	var ws, user, agent, chat string
	scan := func(dst *string, sql string, args ...any) {
		t.Helper()
		if err := pool.QueryRow(ctx, sql, args...).Scan(dst); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	scan(&user, `SELECT id FROM users LIMIT 1`)
	scan(&ws, `SELECT workspace_id FROM users WHERE id=$1`, user)
	scan(&agent, `SELECT id FROM agents WHERE workspace_id=$1 LIMIT 1`, ws)
	scan(&chat, `INSERT INTO chat_sessions(workspace_id,title,created_by,agent_id,harness,model,effort) VALUES($1,'Planning',$2,$3,'codex','m','high') RETURNING id`, ws, user, agent)
	scan(&deck, `INSERT INTO chat_canvases(session_id,kind,title) VALUES($1,'deck','Board update') RETURNING id`, chat)
	scan(&design, `INSERT INTO chat_canvases(session_id,kind,title) VALUES($1,'design','Checkout flow') RETURNING id`, chat)
	return deck, design
}

func pagesFor(t *testing.T, pool *pgxpool.Pool, canvas string) (count int, path string) {
	t.Helper()
	if err := pool.QueryRow(t.Context(), `SELECT count(*), coalesce(min(path),'') FROM artifacts WHERE canvas_id=$1`, canvas).Scan(&count, &path); err != nil {
		t.Fatal(err)
	}
	return count, path
}

// An export from before decks and designs were pages imports into the new schema, and the newer
// migration gives each its page.
func TestPreCanvasPagesExportImportsDecksAndDesignsAsPages(t *testing.T) {
	ctx := t.Context()
	src := testdb.NewUnmigrated(t)
	if err := db.MigrateTo(ctx, src, preCanvasPagesSchema); err != nil {
		t.Fatal(err)
	}
	seed(t, src)
	deck, design := deckIn(t, src)

	zr, m := exportToZip(t, src, newMemBlobs(), "")
	if m.SchemaVersion != preCanvasPagesSchema {
		t.Fatalf("export schema %d, want %d", m.SchemaVersion, preCanvasPagesSchema)
	}
	dst := testdb.NewUnmigrated(t)
	if err := (&transfer.Importer{Pool: dst, Blobs: newMemBlobs()}).Import(ctx, zr); err != nil {
		t.Fatalf("import: %v", err)
	}
	if n, path := pagesFor(t, dst, deck); n != 1 || path != "Slides/Board update" {
		t.Errorf("deck: %d pages at %q", n, path)
	}
	if n, path := pagesFor(t, dst, design); n != 1 || path != "Designs/Checkout flow" {
		t.Errorf("design: %d pages at %q", n, path)
	}
}

// Exported with their pages, decks and designs come back with exactly those pages: the insert
// trigger doesn't make a second one while the import loads the canvases.
func TestDeckPagesRoundTripWithoutDuplicates(t *testing.T) {
	ctx := t.Context()
	src := testdb.New(t)
	seed(t, src)
	deck, _ := deckIn(t, src)
	if _, err := src.Exec(ctx, `UPDATE artifacts SET path='Talks/Board update' WHERE canvas_id=$1`, deck); err != nil {
		t.Fatal(err)
	}

	zr, _ := exportToZip(t, src, newMemBlobs(), "")
	dst := testdb.NewUnmigrated(t)
	if err := (&transfer.Importer{Pool: dst, Blobs: newMemBlobs()}).Import(ctx, zr); err != nil {
		t.Fatalf("import: %v", err)
	}
	// One page, where the person moved it.
	if n, path := pagesFor(t, dst, deck); n != 1 || path != "Talks/Board update" {
		t.Errorf("deck after round trip: %d pages at %q", n, path)
	}
}

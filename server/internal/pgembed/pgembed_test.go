package pgembed

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/db"
)

func bundledPostgresBinDir(t *testing.T) string {
	t.Helper()
	if dir := os.Getenv("VESPER_POSTGRES_BIN_DIR"); dir != "" {
		return dir
	}
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	candidate := filepath.Join(repoRoot, "desktop", "resources", "postgres", "bin")
	if _, err := os.Stat(filepath.Join(candidate, "postgres")); err != nil {
		t.Skipf("bundled postgres not staged at %s (run scripts/bundle-postgres-darwin.sh)", candidate)
	}
	return candidate
}

func TestEmbeddedPostgresBootsOverUnixSocketAndMigratesSchema(t *testing.T) {
	binDir := bundledPostgresBinDir(t)
	ctx := context.Background()

	// Use a deep nested DataDir to verify macOS's 104-byte Unix socket limit is avoided automatically.
	deepData := filepath.Join(t.TempDir(), "very", "deep", "application", "support", "directory", "name", "for", "vesper", "postgres")
	logPath := filepath.Join(t.TempDir(), "logs", "postgres.log")

	cl, err := Start(ctx, Config{
		BinDir:   binDir,
		DataDir:  deepData,
		Database: "vesper",
		User:     "vesper",
		Port:     55432,
		LogPath:  logPath,
	})
	if err != nil {
		t.Fatalf("pgembed.Start: %v", err)
	}
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := cl.Stop(sctx); err != nil {
			t.Errorf("pgembed.Stop: %v", err)
		}
	}()

	if !strings.Contains(cl.DSN(), "host=%2Ftmp%2F") {
		t.Fatalf("expected Unix-socket DSN in /tmp, got %q", cl.DSN())
	}

	pool, err := db.Open(ctx, cl.DSN())
	if err != nil {
		t.Fatalf("db.Open: %v", err)
	}
	defer pool.Close()

	if err := db.Migrate(ctx, pool); err != nil {
		t.Fatalf("db.Migrate on embedded postgres: %v", err)
	}

	// Verify Vesper tables & pg_trgm extension work inside the Unix-socket cluster.
	var count int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'workspaces'`).Scan(&count); err != nil || count != 1 {
		t.Fatalf("expected workspaces table after migrations, count=%d err=%v", count, err)
	}
	var trgmCount int
	if err := pool.QueryRow(ctx, `SELECT array_length(show_trgm('vesper'), 1)`).Scan(&trgmCount); err != nil || trgmCount == 0 {
		t.Fatalf("expected pg_trgm to work, count=%d err=%v", trgmCount, err)
	}
	pool.Close()

	// Verify restart cleanly recovers even if a stale dead postmaster.pid is present.
	sctx, scancel := context.WithTimeout(ctx, 10*time.Second)
	if err := cl.Stop(sctx); err != nil {
		scancel()
		t.Fatalf("first Stop: %v", err)
	}
	scancel()
	if err := os.WriteFile(filepath.Join(deepData, "postmaster.pid"), []byte("999999\n"+deepData+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cl2, err := Start(ctx, Config{
		BinDir:   binDir,
		DataDir:  deepData,
		Database: "vesper",
		User:     "vesper",
		Port:     55432,
	})
	if err != nil {
		t.Fatalf("restart with stale postmaster.pid failed: %v", err)
	}
	sctx2, scancel2 := context.WithTimeout(ctx, 10*time.Second)
	_ = cl2.Stop(sctx2)
	scancel2()
}

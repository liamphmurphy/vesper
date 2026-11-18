// Package testdb gives integration tests a migrated, throwaway database.
//
// Tests are skipped unless TEST_DATABASE_URL points at a Postgres server the
// tests may create databases on (CI provides one; locally use dev compose).
// Inside a Vesper run or on CI they fail instead: a skip there reads as a
// pass, and agents reported "tests pass" without ever reaching a database.
package testdb

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/url"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/db"
)

// requiredBy names what requires database tests to run rather than skip, or
// "" when skipping is fine (a person running go test locally).
func requiredBy() string {
	switch {
	case os.Getenv("LAZYAGENTS_RUN_ID") != "":
		return "a Vesper run"
	case os.Getenv("CI") != "":
		return "CI"
	}
	return ""
}

// New creates a uniquely named, migrated database and drops it when the test
// ends. It is cloned from a template migrated once per test binary, which is
// several times faster than migrating every test's database.
func New(t testing.TB) *pgxpool.Pool { return create(t, true) }

// NewUnmigrated is New without the migrations: a database as a fresh machine
// has it, for tests of code that migrates it itself.
func NewUnmigrated(t testing.TB) *pgxpool.Pool { return create(t, false) }

func create(t testing.TB, migrate bool) *pgxpool.Pool {
	t.Helper()
	base := os.Getenv("TEST_DATABASE_URL")
	if base == "" {
		if reason := requiredBy(); reason != "" {
			t.Fatalf("testdb: TEST_DATABASE_URL is not set, and %s requires database tests to run. "+
				"Start Postgres 17 (e.g. `docker run -d --name pg -e POSTGRES_PASSWORD=pg -p 5432 postgres:17-alpine`) "+
				"and point TEST_DATABASE_URL at it", reason)
		}
		t.Skip("TEST_DATABASE_URL not set")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	admin, err := pgx.Connect(ctx, base)
	if err != nil {
		t.Fatalf("testdb: connect: %v", err)
	}
	defer admin.Close(ctx)

	name := randomName("test_")
	create := "CREATE DATABASE " + name
	if migrate {
		tmpl, err := migratedTemplate(base)
		if err != nil {
			t.Fatalf("testdb: template: %v", err)
		}
		create += " TEMPLATE " + tmpl
	}
	if _, err := admin.Exec(ctx, create); err != nil {
		t.Fatalf("testdb: create: %v", err)
	}

	pool, err := db.Open(ctx, dbURL(base, name))
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() {
		pool.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if c, err := pgx.Connect(ctx, base); err == nil {
			_, _ = c.Exec(ctx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
			_ = c.Close(ctx)
		}
	})
	return pool
}

const templatePrefix = "testdb_tmpl_"

var template struct {
	once sync.Once
	name string
	err  error
	// keeper is a connection held open for the life of the test binary, its
	// application_name the template's name: it marks the template as in use,
	// so another binary's sweep leaves it and drops it once this one exits.
	keeper *pgx.Conn
}

// migratedTemplate returns a database migrated once per test binary, for
// New to clone. Each binary migrates its own, so a template always has this
// binary's migrations and Go-side migration steps, and test binaries built
// from different code can share TEST_DATABASE_URL.
func migratedTemplate(base string) (string, error) {
	template.once.Do(func() { template.name, template.err = buildTemplate(base) })
	return template.name, template.err
}

func buildTemplate(base string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	name := randomName(templatePrefix)
	cfg, err := pgx.ParseConfig(base)
	if err != nil {
		return "", err
	}
	cfg.RuntimeParams["application_name"] = name
	// The keeper connects before the template exists, so no sweep can see
	// the template without its keeper.
	keeper, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return "", err
	}
	template.keeper = keeper
	sweepTemplates(ctx, keeper)
	if _, err := keeper.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		return "", err
	}
	pool, err := db.Open(ctx, dbURL(base, name))
	if err == nil {
		err = db.Migrate(ctx, pool)
		// Cloning needs the template to have no other connections.
		pool.Close()
	}
	if err != nil {
		_, _ = keeper.Exec(ctx, "DROP DATABASE IF EXISTS "+name+" WITH (FORCE)")
		return "", err
	}
	return name, nil
}

// sweepTemplates drops templates whose test binary has exited (their keeper
// connection is gone), including ones left by a binary that was killed.
func sweepTemplates(ctx context.Context, c *pgx.Conn) {
	rows, err := c.Query(ctx, `SELECT d.datname FROM pg_database d
		WHERE starts_with(d.datname, $1)
		AND NOT EXISTS (SELECT 1 FROM pg_stat_activity a WHERE a.application_name = d.datname)`, templatePrefix)
	if err != nil {
		return
	}
	stale, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return
	}
	for _, name := range stale {
		// Without FORCE: a template something is connected to is in use.
		_, _ = c.Exec(ctx, "DROP DATABASE IF EXISTS "+pgx.Identifier{name}.Sanitize())
	}
}

func randomName(prefix string) string {
	b := make([]byte, 6)
	_, _ = rand.Read(b)
	return prefix + hex.EncodeToString(b)
}

func dbURL(base, name string) string {
	u, err := url.Parse(base)
	if err != nil {
		return base
	}
	u.Path = "/" + name
	return u.String()
}

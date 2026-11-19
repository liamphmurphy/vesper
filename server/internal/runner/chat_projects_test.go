package runner

import (
	"context"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// A chat with no default project is told the workspace's only active project,
// so it doesn't spend a list_projects call finding the one choice there is.
func TestSoleProjectNote(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	var ws uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO workspaces (name, slug) VALUES ('w', 'w') RETURNING id`).Scan(&ws); err != nil {
		t.Fatal(err)
	}
	chat := store.ChatSession{WorkspaceID: ws}
	project := func(key string, archived bool) {
		t.Helper()
		if _, err := pool.Exec(ctx, `INSERT INTO projects (workspace_id, key, name, color, archived) VALUES ($1, $2, $2, 'blue', $3)`, ws, key, archived); err != nil {
			t.Fatal(err)
		}
	}
	note := func(defaultProject string) string {
		t.Helper()
		got, err := soleProjectNote(ctx, q, chat, defaultProject)
		if err != nil {
			t.Fatal(err)
		}
		return got
	}

	if got := note(""); got != "" {
		t.Fatalf("no projects: %q", got)
	}
	project("PAY", false)
	project("OLD", true)
	if got := note(""); !strings.Contains(got, "one active project, PAY") {
		t.Fatalf("one active project (one archived): %q", got)
	}
	if got := note("PAY"); got != "" {
		t.Fatalf("a chat with a default project already knows it: %q", got)
	}
	project("MOB", false)
	if got := note(""); got != "" {
		t.Fatalf("two active projects: %q", got)
	}
}

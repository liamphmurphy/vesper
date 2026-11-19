package runs

import (
	"context"
	"slices"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// Chats get custom apps scoped to chats, and a dock chat its own app. A chat
// working in a repository gets only its dock's app: every attached server's
// tools ride along in each prompt (LAZYAGENTS-254).
func TestCustomAppMCPsForChat(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: &artifacts.Service{Pool: pool}}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	app := func(slug, scope string) uuid.UUID {
		t.Helper()
		var id uuid.UUID
		if err := pool.QueryRow(ctx, `INSERT INTO custom_apps (workspace_id, user_id, slug, name, manifest) VALUES ($1, $2, $3, $3, jsonb_build_object('tool_scope', $4::text)) RETURNING id`,
			me.WorkspaceID, me.ID, slug, scope).Scan(&id); err != nil {
			t.Fatal(err)
		}
		if _, err := pool.Exec(ctx, `INSERT INTO custom_app_versions (app_id, seq, author_type, manifest, files, bundle_js, bundle_mcp_js) VALUES ($1, 1, 'user', '{}', '{}', 'x', 'export default {}')`, id); err != nil {
			t.Fatal(err)
		}
		return id
	}
	app("bestiary", "chats")
	app("ledger", "app_only")
	app("legacy", "")
	var dock uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO chat_spaces (workspace_id, user_id, name, color, app) VALUES ($1, $2, 'Ledger', 'teal', 'custom:ledger') RETURNING id`, me.WorkspaceID, me.ID).Scan(&dock); err != nil {
		t.Fatal(err)
	}

	for _, c := range []struct {
		name       string
		space      *uuid.UUID
		repoCoding bool
		want       []string
	}{
		{"chat", nil, false, []string{"bestiary", "legacy"}},
		{"dock chat", &dock, false, []string{"bestiary", "ledger", "legacy"}},
		{"repository chat", nil, true, nil},
		{"repository chat in a dock", &dock, true, []string{"ledger"}},
	} {
		got, err := customAppMCPsForChat(ctx, q, store.ChatSession{WorkspaceID: me.WorkspaceID, CreatedBy: me.ID, SpaceID: c.space}, c.repoCoding)
		if err != nil {
			t.Fatal(err)
		}
		slices.Sort(got)
		if !slices.Equal(got, c.want) {
			t.Errorf("%s: %v, want %v", c.name, got, c.want)
		}
	}
}

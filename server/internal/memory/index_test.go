package memory_test

import (
	"context"
	"fmt"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// Heavy project churn cannot evict personal entries (preferences, life, facts,
// work) from the always-loaded index: personal entries keep at least
// IndexSize-IndexProjectCap slots, while unused slots in either bucket spill
// over so the index still fills to IndexSize when enough live entries exist.
func TestIndexProtectsPersonalEntriesFromProjectChurn(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	me, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	svc := memory.New(q)
	person := memory.Owner{WorkspaceID: me.WorkspaceID, UserID: me.ID}
	src := memory.Source{Label: "manual"}

	// Create unique titles so Save's pg_trgm near-duplicate check doesn't merge them.
	saveUnique := func(prefix, typ string, n int) {
		t.Helper()
		for i := range n {
			title := fmt.Sprintf("%s %s", prefix, uuid.NewString())
			r, err := svc.Save(ctx, person, memory.Input{Title: title, Type: typ}, src)
			if err != nil {
				t.Fatalf("save %s %d: %v", typ, i, err)
			}
			if r.Updated {
				t.Fatalf("save %s %d merged unexpectedly into %s", typ, i, r.Memory.Title)
			}
		}
	}
	countBuckets := func(idx []memory.IndexEntry) (personal, project int) {
		for _, e := range idx {
			if e.Type == "project" {
				project++
			} else {
				personal++
			}
		}
		return personal, project
	}
	reset := func() {
		t.Helper()
		if _, err := svc.DeleteAll(ctx, person); err != nil {
			t.Fatal(err)
		}
	}

	// 1. Older personal entries survive 55 newer project entries; remaining
	//    slots spill over to project so all 50 index slots stay useful.
	saveUnique("pref", "preference", 5)
	saveUnique("life", "life", 3)
	saveUnique("work", "work", 2)
	saveUnique("proj", "project", 55)
	idx, total, err := svc.Index(ctx, person)
	if err != nil {
		t.Fatal(err)
	}
	personal, project := countBuckets(idx)
	if total != 65 || len(idx) != memory.IndexSize || personal != 10 || project != memory.IndexSize-10 {
		t.Fatalf("10 personal + 55 project: got len=%d total=%d personal=%d project=%d", len(idx), total, personal, project)
	}

	// 2. When both buckets exceed their quotas, personal keeps
	//    IndexSize-IndexProjectCap slots and project is capped at IndexProjectCap.
	reset()
	saveUnique("fact", "fact", 40)
	saveUnique("proj", "project", 40)
	idx, total, err = svc.Index(ctx, person)
	if err != nil {
		t.Fatal(err)
	}
	personal, project = countBuckets(idx)
	if total != 80 || len(idx) != memory.IndexSize || personal != memory.IndexSize-memory.IndexProjectCap || project != memory.IndexProjectCap {
		t.Fatalf("40 personal + 40 project: got len=%d total=%d personal=%d project=%d", len(idx), total, personal, project)
	}

	// 3. Unused project slots spill over to personal entries.
	reset()
	saveUnique("proj", "project", 5)
	saveUnique("pref", "preference", 60)
	idx, total, err = svc.Index(ctx, person)
	if err != nil {
		t.Fatal(err)
	}
	personal, project = countBuckets(idx)
	if total != 65 || len(idx) != memory.IndexSize || personal != memory.IndexSize-5 || project != 5 {
		t.Fatalf("60 personal + 5 project: got len=%d total=%d personal=%d project=%d", len(idx), total, personal, project)
	}

	// 4. With no personal entries, project entries still fill all IndexSize slots.
	reset()
	saveUnique("proj", "project", 60)
	idx, total, err = svc.Index(ctx, person)
	if err != nil {
		t.Fatal(err)
	}
	personal, project = countBuckets(idx)
	if total != 60 || len(idx) != memory.IndexSize || personal != 0 || project != memory.IndexSize {
		t.Fatalf("0 personal + 60 project: got len=%d total=%d personal=%d project=%d", len(idx), total, personal, project)
	}
}

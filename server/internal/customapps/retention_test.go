package customapps

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// Each save keeps only the newest MaxStoredVersions versions; restoring a pruned one fails.
func TestUpdateKeepsLastVersions(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	u, err := store.New(pool).GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	svc := &Service{Pool: pool}
	if _, err := svc.Create(ctx, u.WorkspaceID, u.ID, CreateInput{
		Slug:  "notes",
		Name:  "Notes",
		Files: map[string]string{"app.tsx": `export default function App() { return <div>v1</div>; }`},
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}

	var last AppDetail
	for i := 2; i <= 14; i++ {
		last, err = svc.Update(ctx, u.WorkspaceID, u.ID, "notes", UpdateInput{
			Files: map[string]string{"app.tsx": fmt.Sprintf(`export default function App() { return <div>v%d</div>; }`, i)},
		})
		if err != nil {
			t.Fatalf("Update v%d: %v", i, err)
		}
	}
	if last.CurrentSeq != 14 || len(last.Versions) != MaxStoredVersions {
		t.Fatalf("after 14 versions: current=%d stored=%d, want current=14 stored=%d", last.CurrentSeq, len(last.Versions), MaxStoredVersions)
	}
	if newest, oldest := last.Versions[0].Seq, last.Versions[len(last.Versions)-1].Seq; newest != 14 || oldest != 5 {
		t.Fatalf("kept versions v%d..v%d, want v5..v14", oldest, newest)
	}

	pruned := int32(4)
	if _, err := svc.Update(ctx, u.WorkspaceID, u.ID, "notes", UpdateInput{RestoreSeq: &pruned}); !errors.As(err, new(*apperr.ValidationError)) {
		t.Fatalf("restore pruned version err = %v, want validation error", err)
	}
	kept := int32(5)
	restored, err := svc.Update(ctx, u.WorkspaceID, u.ID, "notes", UpdateInput{RestoreSeq: &kept})
	if err != nil || restored.CurrentSeq != 15 || !strings.Contains(restored.Current.Files["app.tsx"], "v5") {
		t.Fatalf("restore v5 = seq %d, err %v", restored.CurrentSeq, err)
	}
	if len(restored.Versions) != MaxStoredVersions || restored.Versions[len(restored.Versions)-1].Seq != 6 {
		t.Fatalf("after restore kept %d versions starting at v%d", len(restored.Versions), restored.Versions[len(restored.Versions)-1].Seq)
	}
}

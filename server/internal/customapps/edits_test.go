package customapps

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestApplyEdits(t *testing.T) {
	files := map[string]string{
		"app.tsx":    "const a = 1;\nconst b = 2;\nconst a2 = 1;\n",
		"styles.css": ".x { color: red; }\n",
	}

	got, err := ApplyEdits(files, []FileEdit{
		{Path: "app.tsx", Find: "const b = 2;", Replace: "const b = 3;"},
		{Path: "/styles.css", Find: "red", Replace: "blue"},
	})
	if err != nil {
		t.Fatalf("ApplyEdits: %v", err)
	}
	if got["app.tsx"] != "const a = 1;\nconst b = 3;\nconst a2 = 1;\n" || got["styles.css"] != ".x { color: blue; }\n" {
		t.Fatalf("edited files = %#v", got)
	}
	if files["app.tsx"] != "const a = 1;\nconst b = 2;\nconst a2 = 1;\n" {
		t.Fatal("ApplyEdits mutated its input")
	}

	if got, err := ApplyEdits(files, []FileEdit{{Path: "app.tsx", Find: "= 1;", Replace: "= 9;", ReplaceAll: true}}); err != nil || strings.Count(got["app.tsx"], "= 9;") != 2 {
		t.Fatalf("replace_all = %q, %v", got["app.tsx"], err)
	}

	// Later edits see earlier ones, so a multi-step change can be sent in one call.
	if got, err := ApplyEdits(files, []FileEdit{
		{Path: "app.tsx", Find: "const b = 2;", Replace: "const b = 2; // two"},
		{Path: "app.tsx", Find: "// two", Replace: "// 2"},
	}); err != nil || !strings.Contains(got["app.tsx"], "const b = 2; // 2") {
		t.Fatalf("chained edits = %q, %v", got["app.tsx"], err)
	}

	for name, tc := range map[string]struct {
		edit FileEdit
		want string
	}{
		"missing file": {FileEdit{Path: "nope.tsx", Find: "a", Replace: "b"}, "nope.tsx"},
		"empty find":   {FileEdit{Path: "app.tsx", Find: "", Replace: "b"}, "find"},
		"not found":    {FileEdit{Path: "app.tsx", Find: "const z", Replace: "b"}, "not found"},
		"ambiguous":    {FileEdit{Path: "app.tsx", Find: "= 1;", Replace: "= 9;"}, "matches 2 times"},
	} {
		_, err := ApplyEdits(files, []FileEdit{tc.edit})
		if !errors.As(err, new(*apperr.ValidationError)) || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: err = %v, want validation error mentioning %q", name, err, tc.want)
		}
	}
}

func TestUpdateAppliesEdits(t *testing.T) {
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

	edited, err := svc.Update(ctx, u.WorkspaceID, u.ID, "notes", UpdateInput{
		Edits: []FileEdit{{Path: "app.tsx", Find: "<div>v1</div>", Replace: "<div>edited</div>"}},
		Note:  "edit",
	})
	if err != nil {
		t.Fatalf("Update with edits: %v", err)
	}
	if edited.CurrentSeq != 2 || !strings.Contains(edited.Current.Files["app.tsx"], "<div>edited</div>") || !strings.Contains(edited.Current.BundleJS, "edited") {
		t.Fatalf("edit not applied and rebuilt: seq=%d file=%q", edited.CurrentSeq, edited.Current.Files["app.tsx"])
	}

	if _, err := svc.Update(ctx, u.WorkspaceID, u.ID, "notes", UpdateInput{
		Edits: []FileEdit{{Path: "app.tsx", Find: "<div>v1</div>", Replace: "x"}},
	}); !errors.As(err, new(*apperr.ValidationError)) {
		t.Fatalf("stale edit err = %v, want validation error", err)
	}

	first := int32(1)
	if _, err := svc.Update(ctx, u.WorkspaceID, u.ID, "notes", UpdateInput{
		RestoreSeq: &first,
		Edits:      []FileEdit{{Path: "app.tsx", Find: "edited", Replace: "x"}},
	}); !errors.As(err, new(*apperr.ValidationError)) {
		t.Fatalf("edits with restore_seq err = %v, want validation error", err)
	}
}

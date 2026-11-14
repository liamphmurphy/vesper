package customapps

import (
	"context"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestSlugValidationAllowsFinanceRejectsReserved(t *testing.T) {
	for _, valid := range []string{"finance", "my-crm", "v2-notes"} {
		got, err := ValidSlug(valid)
		if err != nil || got != valid {
			t.Errorf("ValidSlug(%q) = %q, %v", valid, got, err)
		}
	}
	for _, bad := range []string{"docs", "slides", "designs", "new", "Bad_Slug", "-leading", ""} {
		if _, err := ValidSlug(bad); err == nil {
			t.Errorf("ValidSlug(%q) succeeded, want error", bad)
		}
	}
}

func TestModeForCapabilities(t *testing.T) {
	caps := Capabilities{
		"vesper.api:read":  agentdef.RequiresApproval,
		"mcp:github:*":     agentdef.RequiresApproval,
		"mcp:github:merge": agentdef.Denied,
	}
	cases := []struct {
		key  string
		want agentdef.Mode
	}{
		{"app.sql:read", agentdef.Allowed},
		{"app.sql:write", agentdef.Allowed},
		{"vesper.api:read", agentdef.RequiresApproval},
		{"vesper.api:write", agentdef.Denied},
		{"mcp:github:list_issues", agentdef.RequiresApproval},
		{"mcp:github:merge", agentdef.Denied},
		{"mcp:slack:post", agentdef.Denied},
	}
	for _, tc := range cases {
		if got := ModeFor(caps, tc.key); got != tc.want {
			t.Errorf("ModeFor(%q) = %q, want %q", tc.key, got, tc.want)
		}
	}
}

func TestBundleTSXAndErrors(t *testing.T) {
	js, css, err := Bundle("app.tsx", map[string]string{
		"styles.css": "body { color: red; }",
		"helper.ts":  "export const label = 'ok';",
		"app.tsx": `import { useState } from "react";
import { sql } from "@vesper/bridge";
import { label } from "./helper";
export default function App() {
  const [n, setN] = useState(0);
  return <button onClick={() => { setN(n + 1); void sql("SELECT 1"); }}>{label}:{n}</button>;
}`,
	})
	if err != nil {
		t.Fatalf("Bundle valid app: %v", err)
	}
	if !strings.Contains(js, "vesper:custom-app") || !strings.Contains(js, "SELECT 1") {
		t.Fatalf("bundle missing expected bridge runtime or code")
	}
	if !strings.Contains(css, "color: red") {
		t.Fatalf("css = %q", css)
	}

	if _, _, err := Bundle("app.tsx", map[string]string{"app.tsx": "export default function () { return <div }"}); err == nil || !strings.Contains(err.Error(), "compile error") {
		t.Fatalf("broken TSX err = %v, want compile error", err)
	}
	if _, _, err := Bundle("app.tsx", map[string]string{"app.tsx": `import x from "lodash"; export default () => <div>{String(x)}</div>;`}); err == nil || !strings.Contains(err.Error(), "external import") {
		t.Fatalf("external import err = %v", err)
	}
}

func TestClassifySQLAndServiceLifecycle(t *testing.T) {
	if ro, err := ClassifySQL("SELECT 1"); err != nil || !ro {
		t.Fatalf("SELECT classify = %v, %v", ro, err)
	}
	if ro, err := ClassifySQL("INSERT INTO x VALUES (1)"); err != nil || ro {
		t.Fatalf("INSERT classify = %v, %v", ro, err)
	}
	if _, err := ClassifySQL("ATTACH DATABASE '/tmp/pwn.db' AS pwn"); err == nil {
		t.Fatal("ATTACH was allowed")
	}
	if _, err := ClassifySQL("SELECT load_extension('evil')"); err == nil {
		t.Fatal("LOAD_EXTENSION was allowed")
	}
	if _, err := ClassifySQL("PRAGMA writable_schema = ON"); err == nil {
		t.Fatal("PRAGMA writable_schema was allowed")
	}

	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}

	svc := &Service{Pool: pool}
	app, err := svc.Create(ctx, u.WorkspaceID, u.ID, CreateInput{
		Slug:     "finance",
		Name:     "Personal Ledger",
		Template: "ledger",
	})
	if err != nil {
		t.Fatalf("Create(finance): %v", err)
	}
	if app.Slug != "finance" || app.CurrentSeq != 1 || app.SpaceID == nil || len(app.Schema) == 0 {
		t.Fatalf("unexpected app summary: %+v", app)
	}

	if _, err := svc.QuerySQL(ctx, u.WorkspaceID, u.ID, "finance", "INSERT INTO entries (label, category, amount) VALUES (?, ?, ?)", []any{"Coffee", "food", 4.5}); err != nil {
		t.Fatalf("QuerySQL write: %v", err)
	}
	res, err := svc.QuerySQL(ctx, u.WorkspaceID, u.ID, "finance", "SELECT label, amount FROM entries", nil)
	if err != nil || len(res.Rows) != 1 || res.Rows[0]["label"] != "Coffee" {
		t.Fatalf("QuerySQL read = %+v, err=%v", res, err)
	}

	updated, err := svc.Update(ctx, u.WorkspaceID, u.ID, "finance", UpdateInput{
		Files: map[string]string{"app.tsx": `export default function App() { return <div>v2</div>; }`},
		Note:  "v2 update",
	})
	if err != nil || updated.CurrentSeq != 2 || len(updated.Versions) != 2 {
		t.Fatalf("Update v2 = %+v, err=%v", updated, err)
	}

	seq1 := int32(1)
	restored, err := svc.Update(ctx, u.WorkspaceID, u.ID, "finance", UpdateInput{RestoreSeq: &seq1})
	if err != nil || restored.CurrentSeq != 3 {
		t.Fatalf("Restore v1 = %+v, err=%v", restored, err)
	}

	if err := svc.Delete(ctx, u.WorkspaceID, u.ID, "finance"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
}

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

func TestOSCapabilitiesValidationAndBundle(t *testing.T) {
	osCaps := []string{"os.notifications", "os.clipboard", "os.file_picker"}
	for _, capKey := range osCaps {
		if err := ValidCapabilityKey(capKey); err != nil {
			t.Errorf("ValidCapabilityKey(%q) = %v, want nil", capKey, err)
		}
		if got := ModeFor(Capabilities{}, capKey); got != agentdef.Denied {
			t.Errorf("ModeFor(empty, %q) = %q, want denied", capKey, got)
		}
		// Manifest requesting allowed must still be capped at requires_approval.
		caps := DefaultCapabilities(Capabilities{capKey: agentdef.Allowed})
		if caps[capKey] != agentdef.RequiresApproval {
			t.Errorf("DefaultCapabilities(%q=allowed) = %q, want requires_approval", capKey, caps[capKey])
		}
		normalized, err := NormalizeCapabilities(Capabilities{capKey: agentdef.Allowed})
		if err != nil || normalized[capKey] != agentdef.Allowed {
			t.Errorf("NormalizeCapabilities(%q=allowed) = %v, %v", capKey, normalized, err)
		}
	}
	for _, bad := range []string{"os.*", "os.shell", "os.fs", "os.notifications:send"} {
		if err := ValidCapabilityKey(bad); err == nil {
			t.Errorf("ValidCapabilityKey(%q) succeeded, want error", bad)
		}
	}

	js, _, err := Bundle("app.tsx", map[string]string{
		"app.tsx": `import { os } from "@vesper/bridge";
export default function App() {
  return <button onClick={async () => {
    await os.notify({ title: "Done", body: "Synced" });
    await os.clipboard.writeText("hello");
    await os.clipboard.readText();
    await os.pickFiles({ multiple: true, extensions: ["csv"] });
  }}>run</button>;
}`,
	})
	if err != nil {
		t.Fatalf("Bundle OS bridge app: %v", err)
	}
	for _, needle := range []string{"os-notify", "os-clipboard-read", "os-clipboard-write", "os-file-pick"} {
		if !strings.Contains(js, needle) {
			t.Errorf("bundle missing %q", needle)
		}
	}
}

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
import { sql, openUrl, playVideo, loadImage, useImageUrl } from "@vesper/bridge";
import { label } from "./helper";
export default function App() {
  const [n, setN] = useState(0);
  const img = useImageUrl("https://cdn.example.com/thumb.png");
  return <button onClick={() => { setN(n + 1); void sql("SELECT 1"); openUrl("https://example.com"); playVideo("https://youtu.be/dQw4w9WgXcQ", "Test"); void loadImage("https://cdn.example.com/thumb.png"); }}>{label}:{n}:{img.src || ""}</button>;
}`,
	})
	if err != nil {
		t.Fatalf("Bundle valid app: %v", err)
	}
	if !strings.Contains(js, "vesper:custom-app") || !strings.Contains(js, "SELECT 1") || !strings.Contains(js, "open-url") || !strings.Contains(js, "play-video") || !strings.Contains(js, "URL.createObjectURL") {
		t.Fatalf("bundle missing expected bridge runtime or code")
	}
	if !strings.Contains(css, "color: red") {
		t.Fatalf("css = %q", css)
	}

	// An app can ask for theater mode and hear the docked player's state.
	js, _, err = Bundle("app.tsx", map[string]string{
		"app.tsx": `import { useEffect } from "react";
import { onPlayer, playVideo } from "@vesper/bridge";
export default function App() {
  useEffect(() => onPlayer((p) => console.log(p.open, p.theater)), []);
  return <button onClick={() => playVideo("https://youtu.be/dQw4w9WgXcQ", { title: "Test", theater: true })}>play</button>;
}`,
	})
	if err != nil {
		t.Fatalf("Bundle onPlayer app: %v", err)
	}
	if !strings.Contains(js, "vesper:player") || !strings.Contains(js, "theater: options.theater") {
		t.Fatalf("bundle missing the player bridge (onPlayer, theater)")
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

func TestNixCapabilityAndMountValidation(t *testing.T) {
	for _, pkg := range []string{"yt-dlp", "ffmpeg", "python3.12", "g++", "node_24"} {
		if got, err := ValidNixPackage(pkg); err != nil || got != pkg {
			t.Errorf("ValidNixPackage(%q) = %q, %v", pkg, got, err)
		}
		if err := ValidCapabilityKey("nix:" + pkg); err != nil {
			t.Errorf("ValidCapabilityKey(nix:%s) failed: %v", pkg, err)
		}
	}
	for _, bad := range []string{"", "*", ".", "..", "-flag", "github:a/b", "a/b", "a b"} {
		if _, err := ValidNixPackage(bad); err == nil {
			t.Errorf("ValidNixPackage(%q) succeeded, want error", bad)
		}
		if err := ValidCapabilityKey("nix:" + bad); err == nil {
			t.Errorf("ValidCapabilityKey(nix:%s) succeeded, want error", bad)
		}
	}

	caps := DefaultCapabilities(Capabilities{
		"nix:yt-dlp":         agentdef.Allowed,
		"app.sql:read":       agentdef.Allowed,
		"app.media:download": agentdef.Allowed,
	})
	if caps["nix:yt-dlp"] != agentdef.RequiresApproval {
		t.Fatalf("DefaultCapabilities(nix:yt-dlp) = %q, want requires_approval", caps["nix:yt-dlp"])
	}
	if caps["app.media:download"] != agentdef.RequiresApproval {
		t.Fatalf("DefaultCapabilities(app.media:download) = %q, want requires_approval", caps["app.media:download"])
	}

	mounts, err := NormalizeMounts(Mounts{
		"cookies": "  ~/cookies.txt  ",
		"empty":   "   ",
		"media":   "/tmp/media",
	})
	if err != nil {
		t.Fatalf("NormalizeMounts valid: %v", err)
	}
	if mounts["cookies"] != "~/cookies.txt" || mounts["media"] != "/tmp/media" {
		t.Fatalf("NormalizeMounts = %#v", mounts)
	}
	if _, hasEmpty := mounts["empty"]; hasEmpty {
		t.Fatalf("NormalizeMounts kept empty value: %#v", mounts)
	}
	for name, path := range map[string]string{
		"BAD":     "/tmp/x",
		"cookies": "relative/path.txt",
		"tilde":   "~/",
		"nul":     "/tmp/a\x00b",
	} {
		if _, err := NormalizeMounts(Mounts{name: path}); err == nil {
			t.Errorf("NormalizeMounts(%q: %q) succeeded, want error", name, path)
		}
	}

	m, err := NormalizeManifest(Manifest{
		Entry: "app.tsx",
		RequestedMounts: []MountRequest{
			{Name: "cookies", Description: "  YouTube cookies.txt  "},
		},
	}, map[string]string{"app.tsx": "export default () => null;"})
	if err != nil || len(m.RequestedMounts) != 1 || m.RequestedMounts[0].Description != "YouTube cookies.txt" {
		t.Fatalf("NormalizeManifest valid requested_mounts = %+v, err=%v", m.RequestedMounts, err)
	}
	if _, err := NormalizeManifest(Manifest{
		Entry: "app.tsx",
		RequestedMounts: []MountRequest{
			{Name: "cookies"},
			{Name: "cookies"},
		},
	}, map[string]string{"app.tsx": "export default () => null;"}); err == nil {
		t.Fatal("duplicate requested mount succeeded, want error")
	}
}

func TestServiceUpdatePreservesMountsWhenNil(t *testing.T) {
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
	app, err := svc.Create(ctx, u.WorkspaceID, u.ID, CreateInput{
		Slug:     "mount-test",
		Name:     "Mount Test",
		Template: "blank",
		Mounts:   Mounts{"cookies": "~/cookies.txt"},
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if app.Mounts["cookies"] != "~/cookies.txt" {
		t.Fatalf("created Mounts = %#v", app.Mounts)
	}

	// Updating files/name with Mounts == nil leaves configured mounts intact.
	newName := "Mount Test 2"
	updated, err := svc.Update(ctx, u.WorkspaceID, u.ID, "mount-test", UpdateInput{
		Name: &newName,
	})
	if err != nil {
		t.Fatalf("Update name only: %v", err)
	}
	if updated.Mounts["cookies"] != "~/cookies.txt" {
		t.Fatalf("Update with Mounts==nil clobbered mounts: %#v", updated.Mounts)
	}

	// Clearing via empty value removes the mount.
	cleared := Mounts{"cookies": ""}
	updated, err = svc.Update(ctx, u.WorkspaceID, u.ID, "mount-test", UpdateInput{
		Mounts: &cleared,
	})
	if err != nil {
		t.Fatalf("Update clear mount: %v", err)
	}
	if len(updated.Mounts) != 0 {
		t.Fatalf("expected empty mounts after clearing, got %#v", updated.Mounts)
	}
}

func TestPersonaCodeEditDowngradesPrivilegedCapabilities(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	u, err := store.New(pool).GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}

	svc := &Service{Pool: pool}
	_, err = svc.Create(ctx, u.WorkspaceID, u.ID, CreateInput{
		Slug:     "cap-reset-test",
		Name:     "Cap Reset Test",
		Template: "blank",
	})
	if err != nil {
		t.Fatal(err)
	}
	granted := Capabilities{
		"app.sql:read":      agentdef.Allowed,
		"app.sql:write":     agentdef.Allowed,
		"vesper.api:write":  agentdef.Allowed,
		"secret:stripe":     agentdef.Allowed,
		"nix:ffmpeg":        agentdef.Allowed,
		"app.http:outbound": agentdef.Allowed,
	}
	if _, err := svc.SetCapabilities(ctx, u.WorkspaceID, u.ID, "cap-reset-test", granted); err != nil {
		t.Fatal(err)
	}

	// Metadata-only persona update preserves granted capabilities.
	newDesc := "Renamed description"
	metaUp, err := svc.Update(ctx, u.WorkspaceID, u.ID, "cap-reset-test", UpdateInput{
		Description: &newDesc,
		AuthorType:  "persona",
	})
	if err != nil {
		t.Fatal(err)
	}
	if metaUp.Capabilities["vesper.api:write"] != agentdef.Allowed || metaUp.Capabilities["secret:stripe"] != agentdef.Allowed {
		t.Fatalf("metadata-only persona update downgraded caps: %+v", metaUp.Capabilities)
	}

	// User-authored code update preserves granted capabilities.
	userUp, err := svc.Update(ctx, u.WorkspaceID, u.ID, "cap-reset-test", UpdateInput{
		Files:      map[string]string{"app.tsx": "export default function App() { return <div>user edit</div>; }"},
		AuthorType: "user",
	})
	if err != nil {
		t.Fatal(err)
	}
	if userUp.Capabilities["vesper.api:write"] != agentdef.Allowed || userUp.Capabilities["nix:ffmpeg"] != agentdef.Allowed {
		t.Fatalf("user code edit downgraded caps: %+v", userUp.Capabilities)
	}

	// Persona-authored code edit downgrades all privileged capabilities to requires_approval
	// while keeping local app.sql:read/write intact.
	personaUp, err := svc.Update(ctx, u.WorkspaceID, u.ID, "cap-reset-test", UpdateInput{
		Files:      map[string]string{"app.tsx": "export default function App() { return <div>persona edit</div>; }"},
		AuthorType: "persona",
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, priv := range []string{"vesper.api:write", "secret:stripe", "nix:ffmpeg", "app.http:outbound"} {
		if got := personaUp.Capabilities[priv]; got != agentdef.RequiresApproval {
			t.Errorf("capability %q after persona code edit = %q, want %q", priv, got, agentdef.RequiresApproval)
		}
	}
	for _, local := range []string{"app.sql:read", "app.sql:write"} {
		if got := personaUp.Capabilities[local]; got != agentdef.Allowed {
			t.Errorf("local capability %q after persona code edit = %q, want %q", local, got, agentdef.Allowed)
		}
	}
}

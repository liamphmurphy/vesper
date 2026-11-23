package customapps

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

type nixEnv struct {
	svc        *Service
	nix        *Nix
	media      *Media
	blobs      *memBlobs
	appID      uuid.UUID
	otherAppID uuid.UUID
	ws         uuid.UUID
	user       uuid.UUID
	pkgs       map[string]string
}

func makeMockPackage(t *testing.T, scripts map[string]string) string {
	t.Helper()
	pkgDir := t.TempDir()
	binDir := filepath.Join(pkgDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range scripts {
		p := filepath.Join(binDir, name)
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return pkgDir
}

func newNixEnv(t *testing.T) *nixEnv {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	u, err := store.New(pool).GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}

	pkgs := map[string]string{}
	pkgs["demo"] = makeMockPackage(t, map[string]string{
		"demo": `#!/bin/sh
set -eu
case "${1:-}" in
  echo-args)
    shift
    printf 'args=%s\n' "$*"
    printf 'env=%s\n' "${CUSTOM_VAR:-}"
    printf 'stderr line\n' >&2
    ;;
  stdin-cat)
    /bin/cat
    ;;
  write-files)
    /bin/mkdir -p out
    printf 'hello utf8' > out/note.txt
    printf '\000\001\002\377' > out/raw.bin
    printf '<html><body>not video</body></html>' > out/fake.mp4
    printf '\000\000\000\030ftypisom\000\000\002\000isomiso2avc1mp41payload' > out/clip.mp4
    ;;
  fail-code)
    printf 'failing stdout\n'
    printf 'failing stderr\n' >&2
    exit 7
    ;;
  sleep-bg)
    /bin/sleep 30 &
    wait
    ;;
  mount-check)
    printf 'file=%s\n' "$(/bin/cat .mounts/cookies)"
    printf 'env=%s\n' "$(/bin/cat "$VESPER_MOUNT_COOKIES")"
    printf 'dir=%s\n' "$(/bin/cat .mounts/profile/data.txt)"
    printf 'mutated-in-job\n' > .mounts/cookies
    ;;
  symlink-escape)
    /bin/ln -s /etc/passwd leak.txt
    /bin/mkdir -p sub
    /bin/ln -s /etc sublink
    ;;
  *)
    printf 'unknown op\n' >&2
    exit 2
    ;;
esac
`,
	})
	pkgs["extra"] = makeMockPackage(t, map[string]string{
		"helper": "#!/bin/sh\necho helper-ok\n",
	})

	blobs := &memBlobs{}
	media := &Media{Pool: pool, Blobs: blobs, Bucket: "artifacts", MaxBytes: 4 << 20}
	t.Cleanup(media.Close)
	nix := &Nix{
		Pool:       pool,
		ScratchDir: filepath.Join(t.TempDir(), "scratch"),
		Resolve: func(_ context.Context, pkg string) (string, error) {
			if p, ok := pkgs[pkg]; ok {
				return p, nil
			}
			return "", errors.New("unknown test package " + pkg)
		},
	}
	t.Cleanup(nix.Close)

	svc := &Service{Pool: pool, Media: media, Nix: nix}
	app, err := svc.Create(ctx, u.WorkspaceID, u.ID, CreateInput{Slug: "feed", Name: "Feed", Template: "blank"})
	if err != nil {
		t.Fatal(err)
	}
	other, err := svc.Create(ctx, u.WorkspaceID, u.ID, CreateInput{Slug: "other", Name: "Other", Template: "blank"})
	if err != nil {
		t.Fatal(err)
	}
	return &nixEnv{
		svc:        svc,
		nix:        nix,
		media:      media,
		blobs:      blobs,
		appID:      app.ID,
		otherAppID: other.ID,
		ws:         u.WorkspaceID,
		user:       u.ID,
		pkgs:       pkgs,
	}
}

func (e *nixEnv) waitDone(t *testing.T, id uuid.UUID) NixJob {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		job, err := e.nix.Status(context.Background(), e.appID, id)
		if err != nil {
			t.Fatalf("Status: %v", err)
		}
		if job.State != "resolving" && job.State != "running" {
			return job
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("nix job did not finish")
	return NixJob{}
}

func TestNixCapabilityEnforcementInWorker(t *testing.T) {
	e := newNixEnv(t)
	bundle, err := BundleMCPServer("server.ts", map[string]string{
		"app.tsx": "export default () => null;",
		"server.ts": `import { defineServer, nix } from "@vesper/server";
export default defineServer({
  tools: {
    run_demo: {
      description: "Run demo",
      inputSchema: { type: "object" },
      handler: async (a: any) => nix.run({ packages: a.packages || ["demo"], command: "demo", args: ["echo-args", "hi"] }),
    },
    start_demo: {
      description: "Start demo",
      inputSchema: { type: "object" },
      handler: async () => nix.start({ packages: ["demo", "extra"], command: "demo", args: ["echo-args", "hi"] }),
    },
  },
});`,
	})
	if err != nil {
		t.Fatalf("BundleMCPServer: %v", err)
	}

	// 1. Denied by default.
	_, err = CallMCPTool(context.Background(), MCPCallContext{
		AppID:    e.appID,
		Slug:     "feed",
		AppName:  "Feed",
		BundleJS: bundle,
		Nix:      e.nix,
	}, "run_demo", nil)
	if err == nil || !strings.Contains(err.Error(), "nix:demo") {
		t.Fatalf("expected nix:demo denial, got %v", err)
	}

	// 2. Requires approval triggers ApprovalRequiredError, including on secondary package.
	_, err = CallMCPTool(context.Background(), MCPCallContext{
		AppID:        e.appID,
		Slug:         "feed",
		AppName:      "Feed",
		BundleJS:     bundle,
		Nix:          e.nix,
		Capabilities: Capabilities{"nix:demo": agentdef.Allowed, "nix:extra": agentdef.RequiresApproval},
		Interactive:  true,
		Approved:     false,
	}, "start_demo", nil)
	var appReq *ApprovalRequiredError
	if !errors.As(err, &appReq) || appReq.Capability != "nix:extra" {
		t.Fatalf("expected ApprovalRequiredError for nix:extra, got %v", err)
	}

	// 3. Allowed executes successfully.
	res, err := CallMCPTool(context.Background(), MCPCallContext{
		AppID:        e.appID,
		Slug:         "feed",
		AppName:      "Feed",
		BundleJS:     bundle,
		Nix:          e.nix,
		Capabilities: Capabilities{"nix:demo": agentdef.Allowed},
	}, "run_demo", nil)
	if err != nil {
		t.Fatalf("run_demo allowed failed: %v", err)
	}
	m := res.(map[string]any)
	if m["state"] != "done" || !strings.Contains(m["stdout"].(string), "args=hi") {
		t.Fatalf("unexpected run_demo result = %#v", m)
	}
}

func TestNixLifecycleFilesReadAndMediaImport(t *testing.T) {
	e := newNixEnv(t)
	ctx := context.Background()

	// Start async job that writes utf8, binary, fake.mp4, and real clip.mp4.
	started, err := e.nix.Start(ctx, e.appID, "feed", nil, NixStartInput{
		Packages: []string{"demo"},
		Command:  "demo",
		Args:     []string{"write-files"},
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	done := e.waitDone(t, started.ID)
	if done.State != "done" || done.ExitCode == nil || *done.ExitCode != 0 {
		t.Fatalf("job failed: %+v", done)
	}

	paths := make([]string, len(done.Files))
	for i, f := range done.Files {
		paths[i] = f.Path
	}
	slices.Sort(paths)
	wantPaths := []string{"out/clip.mp4", "out/fake.mp4", "out/note.txt", "out/raw.bin"}
	if !slices.Equal(paths, wantPaths) {
		t.Fatalf("files = %v, want %v", paths, wantPaths)
	}

	// Read UTF-8 and base64 files.
	utf8Res, err := e.nix.ReadFile(ctx, e.appID, started.ID, "out/note.txt", "")
	if err != nil || utf8Res["content"] != "hello utf8" || utf8Res["encoding"] != "utf8" {
		t.Fatalf("ReadFile utf8 = %#v, err=%v", utf8Res, err)
	}
	if _, err := e.nix.ReadFile(ctx, e.appID, started.ID, "out/raw.bin", "utf8"); err == nil {
		t.Fatal("expected binary utf8 read to fail")
	}
	b64Res, err := e.nix.ReadFile(ctx, e.appID, started.ID, "out/raw.bin", "base64")
	if err != nil || b64Res["content"] != base64.StdEncoding.EncodeToString([]byte{0x00, 0x01, 0x02, 0xff}) {
		t.Fatalf("ReadFile base64 = %#v, err=%v", b64Res, err)
	}

	// media.import via worker rejects fake.mp4 (text/html) and imports valid clip.mp4.
	bundle, err := BundleMCPServer("server.ts", map[string]string{
		"app.tsx": "export default () => null;",
		"server.ts": `import { defineServer, media } from "@vesper/server";
export default defineServer({
  tools: {
    import_vid: {
      description: "Import video",
      inputSchema: { type: "object" },
      handler: async (a: any) => media.import(a.jobId, a.path),
    },
  },
});`,
	})
	if err != nil {
		t.Fatal(err)
	}
	mc := MCPCallContext{
		AppID:        e.appID,
		Slug:         "feed",
		AppName:      "Feed",
		BundleJS:     bundle,
		Media:        e.media,
		Nix:          e.nix,
		Capabilities: Capabilities{"app.media:download": agentdef.Allowed},
	}

	if _, err := CallMCPTool(ctx, mc, "import_vid", map[string]any{"jobId": started.ID.String(), "path": "out/fake.mp4"}); err == nil || !strings.Contains(err.Error(), "not a direct video file") {
		t.Fatalf("expected non-video rejection for fake.mp4, got %v", err)
	}

	importedRes, err := CallMCPTool(ctx, mc, "import_vid", map[string]any{"jobId": started.ID.String(), "path": "out/clip.mp4"})
	if err != nil {
		t.Fatalf("import_vid clip.mp4: %v", err)
	}
	impMap := importedRes.(map[string]any)
	mediaID := uuid.MustParse(impMap["id"].(string))
	if impMap["state"] != "done" || impMap["play_url"] != "vesper-media:"+mediaID.String() {
		t.Fatalf("unexpected imported media item: %#v", impMap)
	}
	item, blobKey, size, err := e.media.Playable(ctx, e.appID, mediaID)
	if err != nil || item.ContentType != "video/mp4" {
		t.Fatalf("Playable = %+v, err=%v", item, err)
	}
	gotBlob, ok := e.blobs.get("artifacts", blobKey)
	wantClip := append([]byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2avc1mp41"), []byte("payload")...)
	if !ok || size != int64(len(wantClip)) || !bytes.Equal(gotBlob, wantClip) {
		t.Fatalf("stored blob mismatch: ok=%v size=%d want=%d", ok, size, len(wantClip))
	}

	// Cross-app job access is refused.
	if _, err := e.nix.Status(ctx, e.otherAppID, started.ID); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("cross-app Status err = %v, want ErrNotFound", err)
	}
	if _, err := e.nix.ReadFile(ctx, e.otherAppID, started.ID, "out/note.txt", "utf8"); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("cross-app ReadFile err = %v, want ErrNotFound", err)
	}
	if err := e.nix.Delete(ctx, e.otherAppID, started.ID); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("cross-app Delete err = %v, want ErrNotFound", err)
	}

	// Delete removes job row and scratch directory.
	jobDir := filepath.Join(e.nix.scratchRoot(), e.appID.String(), started.ID.String())
	if _, err := os.Stat(jobDir); err != nil {
		t.Fatalf("expected job dir %s before delete: %v", jobDir, err)
	}
	if err := e.nix.Delete(ctx, e.appID, started.ID); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := os.Stat(jobDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected job dir %s removed after delete, stat err = %v", jobDir, err)
	}
}

func TestNixRunModesAndCleanup(t *testing.T) {
	e := newNixEnv(t)
	ctx := context.Background()

	// Run with keep_files=false auto-cleans row & dir.
	res, err := e.nix.Run(ctx, e.appID, "feed", nil, NixStartInput{
		Packages: []string{"demo"},
		Command:  "demo",
		Args:     []string{"stdin-cat"},
		Stdin:    "from-stdin",
	})
	if err != nil {
		t.Fatalf("Run stdin-cat: %v", err)
	}
	if res.State != "done" || res.Stdout != "from-stdin" {
		t.Fatalf("unexpected Run result: %+v", res)
	}
	if _, err := e.nix.Status(ctx, e.appID, res.ID); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("expected Run row cleaned up, Status err = %v", err)
	}

	// Run with keep_files=true preserves scratch files; non-zero exit records failed + exit_code.
	kept, err := e.nix.Run(ctx, e.appID, "feed", nil, NixStartInput{
		Packages:  []string{"demo"},
		Command:   "demo",
		Args:      []string{"write-files"},
		KeepFiles: true,
	})
	if err != nil || kept.State != "done" || len(kept.Files) != 4 {
		t.Fatalf("Run keep_files = %+v, err=%v", kept, err)
	}
	if rf, err := e.nix.ReadFile(ctx, e.appID, kept.ID, "out/note.txt", "utf8"); err != nil || rf["content"] != "hello utf8" {
		t.Fatalf("ReadFile after keep_files Run = %#v, err=%v", rf, err)
	}
	_ = e.nix.Delete(ctx, e.appID, kept.ID)

	failed, err := e.nix.Run(ctx, e.appID, "feed", nil, NixStartInput{
		Packages: []string{"demo"},
		Command:  "demo",
		Args:     []string{"fail-code"},
	})
	if err != nil {
		t.Fatalf("Run fail-code returned Go error: %v", err)
	}
	if failed.State != "failed" || failed.ExitCode == nil || *failed.ExitCode != 7 {
		t.Fatalf("expected failed exit 7, got %+v", failed)
	}
	if !strings.Contains(failed.Stdout, "failing stdout") || !strings.Contains(failed.Stderr, "failing stderr") {
		t.Fatalf("expected captured stdout/stderr, got %+v", failed)
	}
}

func TestNixCancelInterruptRecoveryAndAppDelete(t *testing.T) {
	e := newNixEnv(t)
	ctx := context.Background()

	// Cancel stops sleeping process group promptly.
	sleeping, err := e.nix.Start(ctx, e.appID, "feed", nil, NixStartInput{
		Packages: []string{"demo"},
		Command:  "demo",
		Args:     []string{"sleep-bg"},
	})
	if err != nil {
		t.Fatalf("Start sleep-bg: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	startCancel := time.Now()
	canceled, err := e.nix.Cancel(ctx, e.appID, sleeping.ID)
	if err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	if canceled.State != "canceled" {
		t.Fatalf("canceled.State = %q, want canceled", canceled.State)
	}
	if time.Since(startCancel) > 5*time.Second {
		t.Fatalf("Cancel took too long (%s)", time.Since(startCancel))
	}

	// Orphaned running row is marked failed on Status.
	orphan, err := store.New(e.nix.Pool).InsertCustomAppNixJob(ctx, store.InsertCustomAppNixJobParams{
		AppID: e.appID, Packages: []string{"demo"}, Command: "demo", WorkDir: "",
	})
	if err != nil {
		t.Fatal(err)
	}
	st, err := e.nix.Status(ctx, e.appID, orphan.ID)
	if err != nil || st.State != "failed" || !strings.Contains(st.Error, "interrupted") {
		t.Fatalf("orphan Status = %+v, err=%v", st, err)
	}

	// App delete cancels active Nix jobs and removes scratch dir.
	running, err := e.nix.Start(ctx, e.appID, "feed", nil, NixStartInput{
		Packages: []string{"demo"},
		Command:  "demo",
		Args:     []string{"sleep-bg"},
	})
	if err != nil {
		t.Fatalf("Start running before delete: %v", err)
	}
	jobDir := filepath.Join(e.nix.scratchRoot(), e.appID.String(), running.ID.String())
	if err := e.svc.Delete(ctx, e.ws, e.user, "feed"); err != nil {
		t.Fatalf("svc.Delete: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(jobDir); errors.Is(err, os.ErrNotExist) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(jobDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expected job dir %s removed on app delete, stat err=%v", jobDir, err)
	}
}

func TestNixMountsAndSecurityGuards(t *testing.T) {
	e := newNixEnv(t)
	ctx := context.Background()

	hostDir := t.TempDir()
	cookiesPath := filepath.Join(hostDir, "cookies.txt")
	if err := os.WriteFile(cookiesPath, []byte("SID=secret-cookie\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	profileDir := filepath.Join(hostDir, "firefox")
	if err := os.MkdirAll(profileDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(profileDir, "data.txt"), []byte("profile-ok\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	// Unconfigured mount returns actionable Permissions error without leaking host paths.
	_, err := e.nix.Run(ctx, e.appID, "feed", Mounts{}, NixStartInput{
		Packages: []string{"demo"},
		Command:  "demo",
		Args:     []string{"mount-check"},
		Mounts:   []string{"cookies"},
	})
	if err == nil || !strings.Contains(err.Error(), "/apps/feed Permissions") {
		t.Fatalf("expected Permissions error for missing mount, got %v", err)
	}

	// Configured mounts: file copied (host protected from writes), dir symlinked, .mounts excluded from files/readFile.
	mounts := Mounts{"cookies": cookiesPath, "profile": profileDir}
	res, err := e.nix.Run(ctx, e.appID, "feed", mounts, NixStartInput{
		Packages:  []string{"demo"},
		Command:   "demo",
		Args:      []string{"mount-check"},
		Mounts:    []string{"cookies", "profile"},
		KeepFiles: true,
	})
	if err != nil {
		t.Fatalf("Run mount-check: %v", err)
	}
	if res.State != "done" || !strings.Contains(res.Stdout, "file=SID=secret-cookie") ||
		!strings.Contains(res.Stdout, "env=SID=secret-cookie") ||
		!strings.Contains(res.Stdout, "dir=profile-ok") {
		t.Fatalf("unexpected mount-check output: %+v", res)
	}
	if len(res.Files) != 0 {
		t.Fatalf("expected .mounts hidden from job.Files, got %+v", res.Files)
	}
	hostBytes, err := os.ReadFile(cookiesPath)
	if err != nil || string(hostBytes) != "SID=secret-cookie\n" {
		t.Fatalf("host mount file was mutated! got %q err=%v", string(hostBytes), err)
	}
	for _, badPath := range []string{".mounts/cookies", ".mounts/profile/data.txt", "../home", "/etc/passwd"} {
		if _, err := e.nix.ReadFile(ctx, e.appID, res.ID, badPath, "utf8"); err == nil {
			t.Errorf("ReadFile(%q) succeeded, want error", badPath)
		}
		if _, _, _, err := e.nix.ResolveJobFile(ctx, e.appID, res.ID, badPath); err == nil {
			t.Errorf("ResolveJobFile(%q) succeeded, want error", badPath)
		}
	}
	_ = e.nix.Delete(ctx, e.appID, res.ID)

	// Symlink escape inside workDir is refused by ReadFile and ResolveJobFile.
	esc, err := e.nix.Run(ctx, e.appID, "feed", nil, NixStartInput{
		Packages:  []string{"demo"},
		Command:   "demo",
		Args:      []string{"symlink-escape"},
		KeepFiles: true,
	})
	if err != nil || esc.State != "done" {
		t.Fatalf("Run symlink-escape: %+v, err=%v", esc, err)
	}
	if len(esc.Files) != 0 {
		t.Fatalf("expected symlinks excluded from Files, got %+v", esc.Files)
	}
	for _, p := range []string{"leak.txt", "sublink/passwd"} {
		if _, err := e.nix.ReadFile(ctx, e.appID, esc.ID, p, "utf8"); err == nil {
			t.Errorf("ReadFile(%q) escaped symlink, want error", p)
		}
	}
	_ = e.nix.Delete(ctx, e.appID, esc.ID)

	// Blocked environment overrides are rejected.
	for _, envKey := range []string{"PATH", "HOME", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "VESPER_SECRET", "NIX_CONF_DIR"} {
		_, err := e.nix.Run(ctx, e.appID, "feed", nil, NixStartInput{
			Packages: []string{"demo"},
			Command:  "demo",
			Args:     []string{"echo-args"},
			Env:      map[string]string{envKey: "bad"},
		})
		if err == nil || !strings.Contains(err.Error(), "cannot be overridden") {
			t.Errorf("env %q was allowed, err=%v", envKey, err)
		}
	}
}

// Non-DB test that verifies Seatbelt sandboxing on macOS (and helper behavior everywhere).
func TestNixSeatbeltSandbox(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("macOS Seatbelt test")
	}
	jobRoot := t.TempDir()
	workDir := filepath.Join(jobRoot, "work")
	if err := os.MkdirAll(workDir, 0o700); err != nil {
		t.Fatal(err)
	}
	roDir := t.TempDir()
	roFile := filepath.Join(roDir, "mounted.txt")
	if err := os.WriteFile(roFile, []byte("mounted-ok"), 0o600); err != nil {
		t.Fatal(err)
	}
	secretDir := t.TempDir()
	secretFile := filepath.Join(secretDir, "private.txt")
	if err := os.WriteFile(secretFile, []byte("secret-no-read"), 0o600); err != nil {
		t.Fatal(err)
	}

	realRO, _ := filepath.EvalSymlinks(roDir)
	realWork, _ := filepath.EvalSymlinks(workDir)
	realSecret, _ := filepath.EvalSymlinks(secretFile)

	script := `set -eu
printf 'ok' > "$1/out.txt"
/bin/cat "$2/mounted.txt"
if /bin/cat "$3" 2>/dev/null; then
  echo "UNEXPECTED_SECRET_READ"
  exit 9
fi
if (printf 'bad' > "$2/write_attempt.txt") 2>/dev/null; then
  echo "UNEXPECTED_RO_WRITE"
  exit 10
fi
`
	bin, args, err := nixSandboxCommand(jobRoot, []string{realRO}, "/bin/sh", []string{"-c", script, "sh", realWork, realRO, realSecret})
	if err != nil {
		t.Fatalf("nixSandboxCommand: %v", err)
	}
	out, err := exec.Command(bin, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("sandboxed command failed: %v\noutput:\n%s", err, string(out))
	}
	if string(out) != "mounted-ok" {
		t.Fatalf("sandboxed output = %q, want mounted-ok", string(out))
	}
	if got, err := os.ReadFile(filepath.Join(realWork, "out.txt")); err != nil || string(got) != "ok" {
		t.Fatalf("expected out.txt written inside workDir, got %q err=%v", string(got), err)
	}
}

func TestNixMultiOutputPackages(t *testing.T) {
	e := newNixEnv(t)
	ctx := context.Background()

	// Case 1: yt-dlp prints multiple outputs where a non-bin output (dist) is listed first.
	ytDlpDist := t.TempDir()
	ytDlpOut := makeMockPackage(t, map[string]string{
		"yt-dlp": "#!/bin/sh\nset -eu\nprintf 'yt-dlp-ok ffmpeg=%s\\n' \"$(ffmpeg)\"\n",
	})

	// Case 2: ffmpeg's default output (out) has no bin/ directory; executables live in ^bin.
	ffmpegOut := t.TempDir()
	ffmpegBin := makeMockPackage(t, map[string]string{
		"ffmpeg": "#!/bin/sh\necho ffmpeg-ok\n",
	})

	// Case 3: data-only package with no bin/ and no ^bin output still resolves cleanly.
	dataOut := t.TempDir()
	if err := os.WriteFile(filepath.Join(dataOut, "README"), []byte("data"), 0o644); err != nil {
		t.Fatal(err)
	}

	fakeNixDir := t.TempDir()
	fakeNix := filepath.Join(fakeNixDir, "nix")
	script := `#!/bin/sh
set -eu
target=""
for arg in "$@"; do
  target="$arg"
done
case "$target" in
  "nixpkgs#yt-dlp")
    printf '%s\n%s\n' "` + ytDlpDist + `" "` + ytDlpOut + `"
    ;;
  "nixpkgs#ffmpeg")
    printf '%s\n' "` + ffmpegOut + `"
    ;;
  "nixpkgs#ffmpeg^bin")
    printf '%s\n' "` + ffmpegBin + `"
    ;;
  "nixpkgs#dataonly")
    printf '%s\n' "` + dataOut + `"
    ;;
  *)
    printf 'error: derivation has no such output: %s\n' "$target" >&2
    exit 1
    ;;
esac
`
	if err := os.WriteFile(fakeNix, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	// Use the real buildPackage path (Resolve == nil) backed by our fake nix CLI.
	e.nix.Resolve = nil
	e.nix.NixBinary = fakeNix

	res, err := e.nix.Run(ctx, e.appID, "feed", nil, NixStartInput{
		Packages: []string{"yt-dlp", "ffmpeg", "dataonly"},
		Command:  "yt-dlp",
	})
	if err != nil {
		t.Fatalf("Run multi-output packages: %v", err)
	}
	if res.State != "done" {
		t.Fatalf("expected state=done, got state=%s err=%q stderr=%q", res.State, res.Error, res.Stderr)
	}
	if strings.TrimSpace(res.Stdout) != "yt-dlp-ok ffmpeg=ffmpeg-ok" {
		t.Fatalf("unexpected stdout = %q", res.Stdout)
	}
}

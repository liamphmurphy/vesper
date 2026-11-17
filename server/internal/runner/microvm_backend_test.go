package runner

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

func TestMicroVMBackendContract(t *testing.T) {
	b := &MicroVM{
		Driver:             &microvm.MemDriver{},
		StateDir:           t.TempDir(),
		KernelPath:         "/k",
		RootfsPath:         "/r",
		TestWorkspaceBytes: 2 << 20,
		TestHomeBytes:      2 << 20,
		TestDockerBytes:    2 << 20,
	}
	if b.Name() != "microvm" || !b.Isolates() || b.WorkspaceDir("r1") != "/workspace" {
		t.Fatalf("unexpected backend identity: name=%s iso=%v dir=%s", b.Name(), b.Isolates(), b.WorkspaceDir("r1"))
	}
	ctx := context.Background()
	if has, err := b.HasWorkspace(ctx, "r1"); err != nil || has {
		t.Fatalf("HasWorkspace = %v, %v", has, err)
	}
	if err := b.EnsureWorkspace(ctx, "r1"); err != nil {
		t.Fatal(err)
	}
	if has, err := b.HasWorkspace(ctx, "r1"); err != nil || !has {
		t.Fatalf("HasWorkspace after Ensure = %v, %v", has, err)
	}
	if err := b.RemoveWorkspace(ctx, "r1"); err != nil {
		t.Fatal(err)
	}
	if has, err := b.HasWorkspace(ctx, "r1"); err != nil || has {
		t.Fatalf("HasWorkspace after Remove = %v, %v", has, err)
	}
	if err := b.EnsureWorkspace(ctx, "../bad"); err == nil {
		t.Fatal("expected invalid runID rejection")
	}
}

func TestVZMicroVMBackendEndToEnd(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)

	apiMux := http.NewServeMux()
	apiMux.HandleFunc("/mcp", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "backend-mcp-ok")
	})

	var savedCodex string
	stateDir := t.TempDir()
	b := &MicroVM{
		Driver:     microvm.NewVZDriver(),
		StateDir:   stateDir,
		KernelPath: kernel,
		RootfsPath: rootfs,
		CPUs:       2,
		MemoryMB:   512,
		PidsLimit:  256,
		APIHandler: apiMux,
		SaveCodexAuth: func(_ context.Context, scope, auth string) error {
			savedCodex = scope + ":" + auth
			return nil
		},
		TestWorkspaceBytes: 64 << 20,
		TestHomeBytes:      32 << 20,
		TestDockerBytes:    32 << 20,
	}
	ctx := context.Background()
	defer func() { _ = b.Cleanup(ctx) }()

	initialCodex := `{"auth_mode":"chatgpt","last_refresh":"2026-01-01T00:00:00Z","tokens":{"refresh_token":"old","account_id":"a"}}`
	refreshedCodex := `{"auth_mode":"chatgpt","last_refresh":"2026-11-16T00:00:00Z","tokens":{"refresh_token":"new","account_id":"a"}}`

	// 1. Run a turn injecting workspace file, OAuth bundle, reaching api.vesper.internal/mcp,
	// writing outbox file + refreshed codex auth + nix manifest.
	script := `
set -e
test -f /workspace/AGENTS.md
test -z "${` + CodexAuthEnv + `:-}"
test -z "${` + ClaudeAuthEnv + `:-}"
test -z "${` + AntigravityAuthEnv + `:-}"
test "$(curl -fsS http://api.vesper.internal/mcp)" = "backend-mcp-ok"
printf '%s' '` + refreshedCodex + `' > /home/node/.codex/auth.json
mkdir -p /home/node/.nix-profile /workspace/.lazyagents/outbox /workspace/video
printf '{"version":2}' > /home/node/.nix-profile/manifest.json
printf 'pngbytes' > /workspace/.lazyagents/outbox/shot.png
printf 'jpgbytes' > /workspace/video/preview.jpg
printf 'render()' > /workspace/render.py
echo "turn-ok"
`
	proc, err := b.Start(ctx, "run-e2e", ExecSpec{
		Name: "turn-1",
		Argv: []string{"/bin/sh", "-c", script},
		Env: map[string]string{
			CodexAuthEnv:      initialCodex,
			CodexAuthScopeEnv: "scope-1",
			ClaudeAuthEnv:     `{"claudeAiOauth":{"refreshToken":"r"}}`,
		},
		Files: map[string][]byte{
			"AGENTS.md": []byte("# Agent Rules\n"),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	var outB, errB bytes.Buffer
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(&outB, proc.Stdout()) }()
	go func() { defer wg.Done(); _, _ = io.Copy(&errB, proc.Stderr()) }()
	wg.Wait()
	code, err := proc.Wait()
	if err != nil || code != 0 || strings.TrimSpace(outB.String()) != "turn-ok" {
		t.Fatalf("turn-1 code=%d err=%v out=%q stderr=%q", code, err, outB.String(), errB.String())
	}

	// Verify Nix manifest readback and Codex token refresh callback.
	if np, ok := proc.(NixManifestProcess); !ok || string(np.NixManifest()) != `{"version":2}` {
		t.Fatalf("NixManifest = %q", np.NixManifest())
	}
	if savedCodex != "scope-1:"+refreshedCodex {
		t.Fatalf("savedCodex = %q", savedCodex)
	}

	// Verify credentials were unconditionally unlinked from /home/node before next turn.
	checkUnlinked, err := b.Start(ctx, "run-e2e", ExecSpec{
		Argv: []string{"/bin/sh", "-c", "test ! -e /home/node/.codex/auth.json && test ! -e /home/node/.claude/.credentials.json && test ! -e /home/node/.ssh"},
	})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _, _ = io.Copy(io.Discard, checkUnlinked.Stdout()) }()
	go func() { _, _ = io.Copy(io.Discard, checkUnlinked.Stderr()) }()
	if c, werr := checkUnlinked.Wait(); werr != nil || c != 0 {
		t.Fatalf("credentials survived turn exit! code=%d err=%v", c, werr)
	}

	// Outbox read/remove, video read, and workspace streaming.
	outbox, skipped, err := b.ReadOutbox(ctx, "run-e2e")
	if err != nil || len(skipped) != 0 || len(outbox) != 1 || outbox[0].Name != "shot.png" || string(outbox[0].Data) != "pngbytes" {
		t.Fatalf("ReadOutbox = %+v skipped=%v err=%v", outbox, skipped, err)
	}
	if err := b.RemoveOutbox(ctx, "run-e2e", []string{"shot.png"}); err != nil {
		t.Fatal(err)
	}
	outbox2, _, err := b.ReadOutbox(ctx, "run-e2e")
	if err != nil || len(outbox2) != 0 {
		t.Fatalf("ReadOutbox after remove = %+v err=%v", outbox2, err)
	}
	vfiles, err := b.ReadVideoFiles(ctx, "run-e2e", VideoFilesRequest{Dir: "video", Script: "render.py"})
	if err != nil || len(vfiles) != 2 {
		t.Fatalf("ReadVideoFiles = %+v err=%v", vfiles, err)
	}
	rc, sz, err := b.OpenWorkspaceFile(ctx, "run-e2e", "AGENTS.md", 1024)
	if err != nil || sz != 14 {
		t.Fatalf("OpenWorkspaceFile size=%d err=%v", sz, err)
	}
	data, _ := io.ReadAll(rc)
	_ = rc.Close()
	if string(data) != "# Agent Rules\n" {
		t.Fatalf("OpenWorkspaceFile data=%q", data)
	}

	// Verify cgroup memory.max OOM kill detection.
	b.MemoryMB = 48
	oomProc, err := b.Start(ctx, "run-e2e", ExecSpec{
		Argv: []string{"python3", "-c", "b = bytearray(128 * 1024 * 1024); b[-1] = 1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _, _ = io.Copy(io.Discard, oomProc.Stdout()) }()
	go func() { _, _ = io.Copy(io.Discard, oomProc.Stderr()) }()
	code, werr := oomProc.Wait()
	if code == 0 || werr == nil || !strings.Contains(werr.Error(), "out of memory") {
		t.Fatalf("expected OOM kill error, got code=%d err=%v", code, werr)
	}

	if err := b.RemoveWorkspace(ctx, "run-e2e"); err != nil {
		t.Fatal(err)
	}
	if has, err := b.HasWorkspace(ctx, "run-e2e"); err != nil || has {
		t.Fatalf("workspace still present after RemoveWorkspace: %v %v", has, err)
	}
}

func requireRunnerVZImages(t *testing.T) (kernel, rootfs string) {
	t.Helper()
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	imgDir := os.Getenv("VESPER_IMAGES_DIR")
	if imgDir == "" {
		imgDir = filepath.Join(home, ".cache", "vesper", "images")
	}
	kernel = filepath.Join(imgDir, "vmlinux")
	rootfs = filepath.Join(imgDir, "agent-base.erofs")
	req := os.Getenv("VESPER_REQUIRE_VZ_TESTS") == "1"
	exe, _ := os.Executable()
	hasEnt := false
	if exe != "" {
		if out, err := exec.Command("codesign", "-d", "--entitlements", "-", exe).CombinedOutput(); err == nil {
			hasEnt = strings.Contains(string(out), "com.apple.security.virtualization")
		}
	}
	if !req && !hasEnt {
		t.Skip("binary lacks com.apple.security.virtualization entitlement")
	}
	for _, p := range []string{kernel, rootfs} {
		if _, err := os.Stat(p); err != nil {
			if req {
				t.Fatalf("missing image %s: %v", p, err)
			}
			t.Skipf("missing image %s", p)
		}
	}
	// Ensure unused guestproto import check never complains if refactored later.
	_ = errors.New
	_ = guestproto.PortRPC
	return kernel, rootfs
}

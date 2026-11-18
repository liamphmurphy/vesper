package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

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

// A process without logins that exits while a turn runs (the code review's
// git batch in a coding chat) must not sweep the turn's Claude login.
func TestVZCredentialSweepSparesRunningTurn(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		CPUs:               2,
		MemoryMB:           512,
		PidsLimit:          256,
		TestWorkspaceBytes: 64 << 20,
		TestHomeBytes:      32 << 20,
		TestDockerBytes:    32 << 20,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	defer func() { _ = b.Cleanup(context.Background()) }()
	const runID = "cred-sweep"
	if err := b.EnsureWorkspace(ctx, runID); err != nil {
		t.Fatal(err)
	}
	auth := `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-test","refreshToken":"sk-ant-ort01-test","expiresAt":4070908800000,"scopes":["user:inference"]}}`

	turn, err := b.Start(ctx, runID, ExecSpec{
		Name: "lazyagents-turn-" + runID + "-1",
		Argv: []string{"sh", "-c", `exec 2>&1; while [ ! -e /tmp/swept ]; do sleep 0.1; done; cat /home/node/.claude/.credentials.json`},
		Env:  map[string]string{ClaudeAuthEnv: auth},
	})
	if err != nil {
		t.Fatal(err)
	}
	turnOut := make(chan []byte, 1)
	go func() { b, _ := io.ReadAll(turn.Stdout()); turnOut <- b }()

	other, err := b.Start(ctx, runID, ExecSpec{Name: "lazyagents-git-" + runID, Argv: []string{"true"}})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, other.Stdout())
	if code, err := other.Wait(); err != nil || code != 0 {
		t.Fatalf("other process: code=%d err=%v", code, err)
	}
	// Its sweep has run; let the turn read its login now.
	marker, err := b.Start(ctx, runID, ExecSpec{Name: "marker-" + runID, Argv: []string{"touch", "/tmp/swept"}})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, marker.Stdout())
	_, _ = marker.Wait()

	out := <-turnOut
	if code, err := turn.Wait(); err != nil || code != 0 || !strings.Contains(string(out), "sk-ant-oat01-test") {
		t.Fatalf("turn lost its Claude login to another process's sweep: code=%d err=%v out=%q", code, err, out)
	}

	after, err := b.Start(ctx, runID, ExecSpec{Name: "after-" + runID, Argv: []string{"sh", "-c", "test ! -e /home/node/.claude/.credentials.json"}})
	if err != nil {
		t.Fatal(err)
	}
	_, _ = io.Copy(io.Discard, after.Stdout())
	if code, err := after.Wait(); err != nil || code != 0 {
		t.Fatalf("Claude login left in /home/node after its last holder exited: code=%d err=%v", code, err)
	}
}

// An agy turn's conversation outlives the turn, so the next one can resume it
// with --conversation, while its login and the MCP token in its config don't.
func TestVZAgySweepKeepsConversation(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		CPUs:               2,
		MemoryMB:           512,
		PidsLimit:          256,
		TestWorkspaceBytes: 64 << 20,
		TestHomeBytes:      32 << 20,
		TestDockerBytes:    32 << 20,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	defer func() { _ = b.Cleanup(context.Background()) }()
	const runID = "agy-sweep"
	if err := b.EnsureWorkspace(ctx, runID); err != nil {
		t.Fatal(err)
	}
	run := func(name string, env map[string]string, script string) {
		t.Helper()
		p, err := b.Start(ctx, runID, ExecSpec{Name: name + "-" + runID, Argv: []string{"sh", "-c", "exec 2>&1; " + script}, Env: env})
		if err != nil {
			t.Fatal(err)
		}
		out, _ := io.ReadAll(p.Stdout())
		if code, err := p.Wait(); err != nil || code != 0 {
			t.Fatalf("%s: code=%d err=%v out=%q", name, code, err, out)
		}
	}
	const cli = "/home/node/.gemini/antigravity-cli"
	run("lazyagents-turn", map[string]string{AntigravityAuthEnv: `{"v":1,"files":{".gemini/antigravity-cli/oauth_creds.json":"login"}}`},
		`test -s `+cli+`/oauth_creds.json && mkdir -p `+cli+`/conversations `+cli+`/brain/c1 /home/node/.gemini/config && `+
			`echo turn1 > `+cli+`/conversations/c1.pb && echo plan > `+cli+`/brain/c1/task.md && echo db > `+cli+`/conversation_summaries.db && `+
			`echo token > /home/node/.gemini/config/mcp_config.json && echo unknown > `+cli+`/new_login.bin`)
	run("after", nil, `grep -q turn1 `+cli+`/conversations/c1.pb && test -f `+cli+`/brain/c1/task.md && test -f `+cli+`/conversation_summaries.db && `+
		`test ! -e `+cli+`/oauth_creds.json && test ! -e `+cli+`/new_login.bin && test ! -e /home/node/.gemini/config`)
}

// After a process exits, the guest is asked to remove agy's login and config
// but not its conversations; if it can't list them, all of agy's home goes.
func TestMicroVMSweepKeepsAgyConversation(t *testing.T) {
	for _, tc := range []struct {
		name       string
		listFails  bool
		mustRemove []string
		mustKeep   []string
	}{
		{name: "listed",
			mustRemove: []string{agyHome + "/config", agyHome + "/antigravity-cli/oauth_creds.bin", homePath + "/" + claudeAuthPath},
			mustKeep:   []string{agyHome, agyHome + "/antigravity-cli/conversations", agyHome + "/antigravity-cli/brain"}},
		{name: "listing fails", listFails: true, mustRemove: []string{agyHome}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var mu sync.Mutex
			var removed []string
			drv := &microvm.MemDriver{Handler: func(_ context.Context, conn net.Conn) {
				f, err := guestproto.ReadFrame(conn)
				if err != nil {
					return
				}
				var req guestproto.Request
				_ = json.Unmarshal(f.Data, &req)
				resp := guestproto.Response{ID: f.ID}
				switch req.Op {
				case guestproto.OpWalkDir:
					var in guestproto.WalkDirReq
					_ = json.Unmarshal(req.V, &in)
					if tc.listFails || in.Root != agyHome {
						resp.Err = "walk failed"
						break
					}
					resp.V, _ = json.Marshal(guestproto.WalkDirResp{Entries: []guestproto.DirEntry{
						{Rel: "config", IsDir: true}, {Rel: "config/mcp_config.json"},
						{Rel: "antigravity-cli", IsDir: true}, {Rel: "antigravity-cli/oauth_creds.bin"},
						{Rel: "antigravity-cli/conversations", IsDir: true}, {Rel: "antigravity-cli/brain", IsDir: true},
					}})
				case guestproto.OpUnlinkPaths:
					var in guestproto.UnlinkPathsReq
					_ = json.Unmarshal(req.V, &in)
					mu.Lock()
					removed = append(removed, in.Paths...)
					mu.Unlock()
				}
				raw, _ := json.Marshal(resp)
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: raw})
				if req.Op == guestproto.OpExecStart {
					ex, _ := json.Marshal(guestproto.ExecExit{Code: 0})
					_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, ID: f.ID, Data: ex})
				}
			}}
			b := &MicroVM{Driver: drv, StateDir: t.TempDir(), KernelPath: "/k", RootfsPath: "/r", MemoryMB: 512,
				TestWorkspaceBytes: 2 << 20, TestHomeBytes: 2 << 20, TestDockerBytes: 2 << 20}
			t.Cleanup(func() { _ = b.Close() })

			runTrue(t, b, "agy-turn")

			mu.Lock()
			defer mu.Unlock()
			for _, p := range tc.mustRemove {
				if !slices.Contains(removed, p) {
					t.Errorf("%s not removed; removed %v", p, removed)
				}
			}
			for _, p := range tc.mustKeep {
				if slices.Contains(removed, p) {
					t.Errorf("%s removed; removed %v", p, removed)
				}
			}
		})
	}
}

func TestAgySweepPaths(t *testing.T) {
	// ~/.gemini after an agy 1.5.9 turn, walked two deep.
	home := []guestproto.DirEntry{
		{Rel: "config", IsDir: true},
		{Rel: "config/config.json"},
		{Rel: "config/mcp_config.json"},
		{Rel: "config/hooks.json"},
		{Rel: "config/projects", IsDir: true},
		{Rel: "oauth_creds.json"},
		{Rel: "antigravity-cli", IsDir: true},
		{Rel: "antigravity-cli/oauth_creds.bin"},
		{Rel: "antigravity-cli/settings.json"},
		{Rel: "antigravity-cli/jetski_state.pbtxt"},
		{Rel: "antigravity-cli/builtin", IsDir: true},
		{Rel: "antigravity-cli/conversations", IsDir: true},
		{Rel: "antigravity-cli/brain", IsDir: true},
		{Rel: "antigravity-cli/implicit", IsDir: true},
		{Rel: "antigravity-cli/conversation_summaries.db"},
		{Rel: "antigravity-cli/conversation_summaries.db-wal"},
	}
	want := []string{
		agyHome + "/config",
		agyHome + "/oauth_creds.json",
		agyHome + "/antigravity-cli/oauth_creds.bin",
		agyHome + "/antigravity-cli/settings.json",
		agyHome + "/antigravity-cli/jetski_state.pbtxt",
		agyHome + "/antigravity-cli/builtin",
	}
	if got := agySweepPaths(home); !slices.Equal(got, want) {
		t.Fatalf("sweep = %v\nwant    %v", got, want)
	}

	// Nothing to keep (no conversation yet, no listing, or ~/.gemini isn't a
	// directory, which a walk reports as no entries): all of it goes.
	for _, entries := range [][]guestproto.DirEntry{
		nil,
		{{Rel: "config", IsDir: true}, {Rel: "config/mcp_config.json"}},
		// A link where the state would be isn't walked into.
		{{Rel: "antigravity-cli"}},
	} {
		if got := agySweepPaths(entries); !slices.Equal(got, []string{agyHome}) {
			t.Fatalf("sweep of %v = %v, want all of %s", entries, got, agyHome)
		}
	}
}

func TestCredentialHolds(t *testing.T) {
	const claude = "/home/node/.claude/.credentials.json"
	const agy = "/home/node/.gemini/oauth_creds.json"
	sweep := []string{claude, "/home/node/.codex/auth.json", "/home/node/.gemini", "/home/node/.ssh"}
	var rvm runVM

	rvm.holdCredentials([]string{claude})
	rvm.holdCredentials([]string{claude, agy})
	// A process with no logins exits: nothing held may go.
	if got := rvm.releaseHolds(nil, sweep); strings.Join(got, ",") != "/home/node/.codex/auth.json,/home/node/.ssh" {
		t.Fatalf("sweep while held = %v", got)
	}
	// One of two Claude holders exits: the login and the held file's directory stay.
	if got := rvm.releaseHolds([]string{claude, agy}, append(sweep, agy)); strings.Join(got, ",") != "/home/node/.codex/auth.json,/home/node/.gemini,/home/node/.ssh,"+agy {
		t.Fatalf("sweep with one holder left = %v", got)
	}
	// The last holder exits: everything goes.
	if got := rvm.releaseHolds([]string{claude}, sweep); len(got) != len(sweep) {
		t.Fatalf("sweep after last holder = %v", got)
	}
	if len(rvm.credHolds) != 0 {
		t.Fatalf("holds left: %v", rvm.credHolds)
	}
}

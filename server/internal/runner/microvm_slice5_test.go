package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/playground"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

func TestMicroVMPlaygroundURLRewriteUnit(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "pg-gw:"+r.URL.Path+"?"+r.URL.RawQuery)
	}))
	defer srv.Close()
	port := strings.TrimPrefix(srv.URL, "http://127.0.0.1:")

	b := &MicroVM{}
	eg := microvm.NewEgress(microvm.EgressConfig{})
	defer eg.Close()

	pgID := uuid.New()
	env := map[string]string{
		"PLAYGROUND_URL":       "http://" + PlaygroundHost + ":" + port + "/app",
		"PLAYGROUND_ENTER_URL": "http://" + PlaygroundHost + ":" + port + playground.ReservedPrefix + "/enter?token=abc",
	}
	ok := b.attachPlaygroundProxy(ExecSpec{Networks: []string{b.PlaygroundNetwork(pgID)}}, env, eg)
	if !ok {
		t.Fatal("expected attachPlaygroundProxy=true")
	}
	if env["PLAYGROUND_URL"] != "http://"+microvm.InternalPlaygroundHost+"/app" {
		t.Fatalf("PLAYGROUND_URL = %q", env["PLAYGROUND_URL"])
	}
	if !strings.HasPrefix(env["PLAYGROUND_ENTER_URL"], "http://"+microvm.InternalPlaygroundHost+"/__vesper/enter") {
		t.Fatalf("PLAYGROUND_ENTER_URL = %q", env["PLAYGROUND_ENTER_URL"])
	}
}

func TestVZPlaygroundNoHomeAndHTTP(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		CPUs:               2,
		MemoryMB:           1024,
		PidsLimit:          512,
		TestWorkspaceBytes: 128 << 20,
		TestHomeBytes:      128 << 20,
		TestDockerBytes:    64 << 20,
	}
	defer func() { _ = b.Cleanup(ctx) }()

	const parentRun = "pg-parent"
	if err := b.EnsureWorkspace(ctx, parentRun); err != nil {
		t.Fatal(err)
	}

	appSrc := `package main
import (
	"fmt"
	"io"
	"net/http"
	"os"
)
func main() {
	fmt.Println("playground-server-booting")
	http.HandleFunc("/hello", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "pg-http-ok")
	})
	http.HandleFunc("/has-home-secret", func(w http.ResponseWriter, r *http.Request) {
		if _, err := os.Stat("/home/node/.super-secret-oauth"); err == nil {
			_, _ = io.WriteString(w, "LEAKED")
			return
		}
		_, _ = io.WriteString(w, "no-secret")
	})
	_ = http.ListenAndServe("0.0.0.0:8080", nil)
}
`
	// Write a secret inside the parent run's persistent home.ext4 and stage the app in workspace.ext4.
	code, out, stderr := runVMTurn(t, b, parentRun, ExecSpec{
		Argv: []string{"/bin/sh", "-c", "printf 'top-secret' > /home/node/.super-secret-oauth"},
		Files: map[string][]byte{
			"srv.go": []byte(appSrc),
		},
	})
	if code != 0 {
		t.Fatalf("seed parent run failed code=%d out=%q err=%q", code, out, stderr)
	}

	pgID := uuid.New()
	var steps []string
	addrs, err := b.StartPlayground(ctx, PlaygroundRun{
		ID:    pgID,
		RunID: parentRun,
		Spec: playground.Spec{
			Setup: []string{"GOCACHE=/tmp/pg-gocache CGO_ENABLED=0 go build -o /tmp/pgsrv /workspace/srv.go"},
			Processes: []playground.Process{
				{Name: "web", Command: "/tmp/pgsrv", Port: 8080},
			},
		},
	}, func(s string) { steps = append(steps, s) })
	if err != nil {
		t.Fatalf("StartPlayground: %v", err)
	}
	if len(steps) == 0 || addrs["web"] == "" {
		t.Fatalf("unexpected StartPlayground result steps=%v addrs=%v", steps, addrs)
	}

	res, err := http.Get("http://" + addrs["web"] + "/hello")
	if err != nil {
		t.Fatalf("GET /hello: %v", err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if string(body) != "pg-http-ok" {
		t.Fatalf("/hello = %q", body)
	}

	// Security invariant: parent run's home.ext4 secret MUST NOT be visible in playground VM.
	res2, err := http.Get("http://" + addrs["web"] + "/has-home-secret")
	if err != nil {
		t.Fatalf("GET /has-home-secret: %v", err)
	}
	secBody, _ := io.ReadAll(res2.Body)
	res2.Body.Close()
	if string(secBody) != "no-secret" {
		t.Fatalf("home.ext4 leaked into playground VM: %q", secBody)
	}

	// Verify ReadFile, Logs, RunningPlaygrounds, and $PLAYGROUND_URL from parent run turn.
	rawFile, err := b.ReadFile(ctx, pgID, "srv.go")
	if err != nil || !strings.Contains(string(rawFile), "playground-server-booting") {
		t.Fatalf("ReadFile(srv.go) = %q err=%v", rawFile, err)
	}
	var logLines []playground.LogLine
	if err := b.Logs(ctx, pgID, 50, false, func(l playground.LogLine) error {
		logLines = append(logLines, l)
		return nil
	}); err != nil || len(logLines) == 0 {
		t.Fatalf("Logs err=%v count=%d", err, len(logLines))
	}
	running, err := b.RunningPlaygrounds(ctx)
	if err != nil || len(running) != 1 || running[0] != pgID {
		t.Fatalf("RunningPlaygrounds = %v err=%v", running, err)
	}

	code, out, stderr = runVMTurn(t, b, parentRun, ExecSpec{
		Argv:     []string{"/bin/sh", "-c", `test "$(curl -fsS "$PLAYGROUND_URL/hello")" = "pg-http-ok"`},
		Networks: []string{b.PlaygroundNetwork(pgID)},
	})
	if code != 0 {
		t.Fatalf("parent turn PLAYGROUND_URL check failed code=%d out=%q err=%q", code, out, stderr)
	}

	if err := b.StopPlayground(ctx, pgID); err != nil {
		t.Fatalf("StopPlayground: %v", err)
	}
	running, _ = b.RunningPlaygrounds(ctx)
	if len(running) != 0 {
		t.Fatalf("expected 0 running playgrounds after stop, got %v", running)
	}
}

func TestVZDevWorkspacePTYResize(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		CPUs:               2,
		MemoryMB:           512,
		PidsLimit:          256,
		TestWorkspaceBytes: 64 << 20,
		TestHomeBytes:      64 << 20,
		TestDockerBytes:    32 << 20,
	}
	defer func() { _ = b.Cleanup(ctx) }()

	wsID := uuid.New()
	cid, err := b.EnsureDevWorkspaceContainer(ctx, wsID)
	if err != nil {
		t.Fatalf("EnsureDevWorkspaceContainer: %v", err)
	}

	out, code, err := b.ExecDevWorkspaceScript(ctx, cid, `echo "hello-$FOO" > /workspace/dev.txt && cat /workspace/dev.txt`, []string{"FOO=devok"})
	if err != nil || code != 0 || !strings.Contains(out, "hello-devok") {
		t.Fatalf("ExecDevWorkspaceScript code=%d out=%q err=%v", code, out, err)
	}

	pty, err := b.OpenDevWorkspacePTY(ctx, wsID, 80, 24)
	if err != nil {
		t.Fatalf("OpenDevWorkspacePTY: %v", err)
	}
	defer pty.Close()

	var mu sync.Mutex
	var ptyBuf bytes.Buffer
	go func() {
		buf := make([]byte, 4096)
		for {
			n, rerr := pty.Read(buf)
			if n > 0 {
				mu.Lock()
				ptyBuf.Write(buf[:n])
				mu.Unlock()
			}
			if rerr != nil {
				return
			}
		}
	}()

	time.Sleep(400 * time.Millisecond)
	if err := pty.Resize(ctx, 132, 43); err != nil {
		t.Fatalf("Resize: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	if _, err := io.WriteString(pty, "printf 'SZ='; stty size\r"); err != nil {
		t.Fatalf("Write to PTY: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	var seen string
	for time.Now().Before(deadline) {
		mu.Lock()
		seen = ptyBuf.String()
		mu.Unlock()
		if strings.Contains(seen, "43 132") {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !strings.Contains(seen, "43 132") {
		t.Fatalf("expected resized TTY size '43 132', got %q", seen)
	}

	if err := b.StopDevWorkspaceContainer(ctx, wsID); err != nil {
		t.Fatalf("StopDevWorkspaceContainer: %v", err)
	}
}

func TestVZUtilityVMLoginAndModels(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	var savedScope, savedCodex string
	b := &MicroVM{
		Driver:     microvm.NewVZDriver(),
		StateDir:   t.TempDir(),
		KernelPath: kernel,
		RootfsPath: rootfs,
		SaveCodexAuth: func(_ context.Context, scope, auth string) error {
			savedScope = scope
			savedCodex = auth
			return nil
		},
	}
	defer func() { _ = b.Cleanup(ctx) }()

	// 1. Interactive TTY StartLogin + ReadFile + ReadHomeFiles before Close().
	lp, err := b.StartLogin(ctx, LoginSpec{
		Name:  "test-login",
		Label: "login",
		Argv: []string{"/bin/sh", "-c", `
printf "Enter code:\n"
IFS= read -r code
mkdir -p "$HOME/.claude" "$HOME/.config/antigravity"
printf '{"code":"%s"}\n' "$code" > "$HOME/.claude/.credentials.json"
printf '{"ag":"ok"}\n' > "$HOME/.config/antigravity/creds.json"
`},
		TTY: true,
	})
	if err != nil {
		t.Fatalf("StartLogin: %v", err)
	}

	var outBuf bytes.Buffer
	outDone := make(chan struct{})
	go func() {
		defer close(outDone)
		_, _ = io.Copy(&outBuf, lp.Output())
	}()

	time.Sleep(200 * time.Millisecond)
	if _, err := io.WriteString(lp.Input(), "code-99\r"); err != nil {
		t.Fatalf("write code: %v", err)
	}
	code, err := lp.Wait()
	<-outDone
	if err != nil || code != 0 {
		t.Fatalf("login Wait code=%d err=%v out=%q", code, err, outBuf.String())
	}

	cred, err := lp.ReadFile(ctx, ".claude/.credentials.json")
	if err != nil || !strings.Contains(string(cred), "code-99") {
		t.Fatalf("ReadFile cred=%q err=%v", cred, err)
	}
	hr, ok := lp.(interface {
		ReadHomeFiles(context.Context, func(string, int64) bool) (map[string][]byte, error)
	})
	if !ok {
		t.Fatal("expected microvmLoginProc to implement ReadHomeFiles")
	}
	files, err := hr.ReadHomeFiles(ctx, func(rel string, _ int64) bool {
		return strings.HasPrefix(filepath.ToSlash(rel), ".config/antigravity/")
	})
	if err != nil || !strings.Contains(string(files[".config/antigravity/creds.json"]), `"ag":"ok"`) {
		t.Fatalf("ReadHomeFiles = %v err=%v", files, err)
	}
	lp.Close()

	// 2. Verify a subsequent utility VM sees a clean tmpfs /home/node (no leakage from VM 1).
	lp2, err := b.StartLogin(ctx, LoginSpec{
		Name:  "test-clean",
		Label: "clean",
		Argv:  []string{"/bin/sh", "-c", `test ! -e "$HOME/.claude/.credentials.json" && echo TMPFS_WIPED`},
		TTY:   false,
	})
	if err != nil {
		t.Fatalf("StartLogin 2: %v", err)
	}
	raw2, _ := io.ReadAll(lp2.Output())
	code2, err := lp2.Wait()
	lp2.Close()
	if err != nil || code2 != 0 || !strings.Contains(string(raw2), "TMPFS_WIPED") {
		t.Fatalf("second utility VM saw state or failed code=%d err=%v out=%q", code2, err, string(raw2))
	}

	// 3. Exercise converseUtilityCLI with Codex login staging + refreshed auth capture.
	t1 := time.Now().UTC().Add(-10 * time.Minute).Format(time.RFC3339)
	t2 := time.Now().UTC().Format(time.RFC3339)
	initialCodex, _ := json.Marshal(map[string]any{
		"auth_mode":    "chatgpt",
		"last_refresh": t1,
		"tokens": map[string]any{
			"access_token":  "old-acc",
			"refresh_token": "old-ref",
			"account_id":    "acc-1",
		},
	})
	refreshedCodex, _ := json.Marshal(map[string]any{
		"auth_mode":    "chatgpt",
		"last_refresh": t2,
		"tokens": map[string]any{
			"access_token":  "new-acc",
			"refresh_token": "new-ref",
			"account_id":    "acc-1",
		},
	})
	var convGot string
	err = b.converseUtilityCLI(ctx, agentdef.HarnessCodex, string(initialCodex), "ws-scope-1",
		[]string{"/bin/sh", "-c", `
grep -q "old-ref" "$HOME/.codex/auth.json"
IFS= read -r req
printf '{"reply":%s}\n' "$req"
printf '%s\n' '` + string(refreshedCodex) + `' > "$HOME/.codex/auth.json"
`},
		func(in io.Writer, out io.Reader) error {
			if _, err := io.WriteString(in, "\"hello-models\"\n"); err != nil {
				return err
			}
			b, rerr := io.ReadAll(out)
			convGot = strings.TrimSpace(string(b))
			return rerr
		},
	)
	if err != nil {
		t.Fatalf("converseUtilityCLI: %v", err)
	}
	if !strings.Contains(convGot, "hello-models") {
		t.Fatalf("converse output = %q", convGot)
	}
	if savedScope != "ws-scope-1" || !strings.Contains(savedCodex, "new-ref") {
		t.Fatalf("expected refreshed Codex auth saved, got scope=%q auth=%q", savedScope, savedCodex)
	}
}

func TestVZDevWorkspaceNixPersists(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		CPUs:               2,
		MemoryMB:           1024,
		PidsLimit:          256,
		TestWorkspaceBytes: 64 << 20,
		TestHomeBytes:      64 << 20,
		TestDockerBytes:    32 << 20,
		TestNixBytes:       2 << 30,
	}
	defer func() { _ = b.Cleanup(ctx) }()

	wsID := uuid.New()
	cid, err := b.EnsureDevWorkspaceContainer(ctx, wsID)
	if err != nil {
		t.Fatalf("EnsureDevWorkspaceContainer: %v", err)
	}
	out, code, err := b.ExecDevWorkspaceScript(ctx, cid,
		`echo persist-me > /tmp/f && nix-store --add /tmp/f > /home/node/nixpath && nix-env -p /home/node/prof -i "$(cat /home/node/nixpath)"`, nil)
	if err != nil || code != 0 {
		t.Fatalf("nix add code=%d out=%q err=%v", code, out, err)
	}
	// A daemon build whose builder uses process substitution, as nixpkgs'
	// patchelf setup hook does (it failed without /dev/fd in the guest).
	out, code, err = b.ExecDevWorkspaceScript(ctx, cid,
		`p=$(nix-build --no-out-link -E 'derivation { name = "procsub"; system = builtins.currentSystem; builder = "/bin/bash"; args = [ "-c" "read -r x < <(echo built-ok); echo $x > $out" ]; }') && cat "$p"`, nil)
	if err != nil || code != 0 || !strings.Contains(out, "built-ok") {
		t.Fatalf("nix build with process substitution: code=%d out=%q err=%v", code, out, err)
	}
	out, code, err = b.ExecDevWorkspaceScript(ctx, cid, `touch /nix/store/x`, nil)
	if err != nil || code == 0 {
		t.Fatalf("uid 1000 wrote /nix/store directly: code=%d out=%q err=%v", code, out, err)
	}

	if err := b.StopDevWorkspaceContainer(ctx, wsID); err != nil {
		t.Fatalf("StopDevWorkspaceContainer: %v", err)
	}
	cid, err = b.EnsureDevWorkspaceContainer(ctx, wsID)
	if err != nil {
		t.Fatalf("second EnsureDevWorkspaceContainer: %v", err)
	}
	out, code, err = b.ExecDevWorkspaceScript(ctx, cid,
		`p=$(cat /home/node/nixpath); nix-store --check-validity "$p" && cat "$p" && test -e /home/node/prof && test -e /nix/var/nix/profiles/default/bin/nix`, nil)
	if err != nil || code != 0 || !strings.Contains(out, "persist-me") {
		t.Fatalf("after restart code=%d out=%q err=%v", code, out, err)
	}
}

package runner

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

func TestMicroVMGitUploadProxyUnit(t *testing.T) {
	var seenAuth string
	var seenPath string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenAuth = r.Header.Get("Authorization")
		seenPath = r.URL.Path + "?" + r.URL.RawQuery
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "git-ok")
	}))
	defer up.Close()

	h := newGitUploadProxy(up.URL, "pat-123")

	// Read-only info/refs allowed + token injected.
	req := httptest.NewRequest(http.MethodGet, "http://"+microvm.InternalGitHost+"/github/org/repo.git/info/refs?service=git-upload-pack", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != 200 || rec.Body.String() != "git-ok" {
		t.Fatalf("info/refs status=%d body=%q", rec.Code, rec.Body.String())
	}
	wantAuth := "Basic " + base64.StdEncoding.EncodeToString([]byte("x-access-token:pat-123"))
	if seenAuth != wantAuth || !strings.HasPrefix(seenPath, "/org/repo.git/info/refs") {
		t.Fatalf("auth=%q path=%q", seenAuth, seenPath)
	}

	// Push (git-receive-pack) rejected.
	for _, r := range []*http.Request{
		httptest.NewRequest(http.MethodGet, "http://"+microvm.InternalGitHost+"/github/org/repo.git/info/refs?service=git-receive-pack", nil),
		httptest.NewRequest(http.MethodPost, "http://"+microvm.InternalGitHost+"/github/org/repo.git/git-receive-pack", nil),
		httptest.NewRequest(http.MethodGet, "http://"+microvm.InternalGitHost+"/user", nil),
	} {
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		if w.Code != http.StatusForbidden {
			t.Errorf("%s expected 403, got %d", r.URL.Path, w.Code)
		}
	}
}

func runVMTurn(t *testing.T, b *MicroVM, runID string, spec ExecSpec) (int, string, string) {
	t.Helper()
	p, err := b.Start(context.Background(), runID, spec)
	if err != nil {
		t.Fatalf("Start(%s): %v", runID, err)
	}
	var outB, errB bytes.Buffer
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); _, _ = io.Copy(&outB, p.Stdout()) }()
	go func() { defer wg.Done(); _, _ = io.Copy(&errB, p.Stderr()) }()
	wg.Wait()
	code, err := p.Wait()
	if err != nil {
		t.Fatalf("Wait(%s): %v (out=%q err=%q)", runID, err, outB.String(), errB.String())
	}
	return code, outB.String(), errB.String()
}

func TestVZDockerdRootfsGuardAndServices(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	cs, err := microvm.NewCacheStore(microvm.CacheStoreConfig{Dir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		CPUs:               2,
		MemoryMB:           1024,
		PidsLimit:          512,
		CacheStore:         cs,
		TestWorkspaceBytes: 128 << 20,
		TestHomeBytes:      256 << 20,
		TestDockerBytes:    256 << 20,
	}
	defer func() { _ = b.Cleanup(ctx) }()

	// 1. StartDockerProxy starts in-guest dockerd and the turn's own guard socket.
	td, err := b.StartDockerProxy(ctx, "dkr-run", "dkr-run", "turn-1")
	if err != nil {
		t.Fatalf("StartDockerProxy: %v", err)
	}
	defer td.Stop()
	if td.Env["DOCKER_HOST"] != "unix:///run/vesper-docker/turn-1.sock" {
		t.Fatalf("DOCKER_HOST = %q", td.Env["DOCKER_HOST"])
	}

	// Build a tiny static Linux arm64 test binary & OCI image completely offline inside the VM
	// implementing both a short echo command and an HTTP service listening on :8080.
	buildAndTestScript := `set -eu
cat > /tmp/tiny.go <<'EOF'
package main
import (
	"fmt"
	"io"
	"net/http"
	"os"
)
func main() {
	if len(os.Args) > 1 && os.Args[1] == "srv" {
		http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, "service-bridge-ok")
		})
		_ = http.ListenAndServe(":8080", nil)
		return
	}
	fmt.Println("container-ok")
}
EOF
mkdir -p /tmp/rootfs/bin
CGO_ENABLED=0 go build -o /tmp/rootfs/bin/tiny /tmp/tiny.go
printf 'hi\n' > /workspace/hello.txt
tar -C /tmp/rootfs -cf - . | docker import - vesper-tiny:test >/dev/null
out=$(docker run --rm -v /workspace:/ws vesper-tiny:test /bin/tiny)
test "$out" = "container-ok"

# Verify rootfs/host escape protections on /var/run/docker.sock.
if docker run --rm --privileged vesper-tiny:test /bin/tiny 2>/tmp/priv.err; then
  echo "ERROR: privileged container unexpectedly succeeded" >&2; exit 1
fi
grep -qi "vesper guard" /tmp/priv.err

if docker run --rm -v /etc:/hostetc vesper-tiny:test /bin/tiny 2>/tmp/bind.err; then
  echo "ERROR: /etc bind unexpectedly succeeded" >&2; exit 1
fi
grep -qi "vesper guard" /tmp/bind.err

if docker run --rm --security-opt seccomp=unconfined vesper-tiny:test /bin/tiny 2>/tmp/seccomp.err; then
  echo "ERROR: seccomp=unconfined unexpectedly succeeded" >&2; exit 1
fi
grep -qi "vesper guard" /tmp/seccomp.err

# Left running on purpose: closing the turn must remove it.
docker run -d --name leftover vesper-tiny:test /bin/tiny srv >/dev/null
echo "DOCKERD_AND_GUARD_OK"
`
	code, out, stderr := runVMTurn(t, b, "dkr-run", ExecSpec{
		Argv: []string{"/bin/sh", "-c", buildAndTestScript},
		Env:  td.Env,
	})
	if code != 0 || !strings.Contains(out, "DOCKERD_AND_GUARD_OK") {
		t.Fatalf("dockerd/guard turn failed code=%d out=%q err=%q", code, out, stderr)
	}

	// Closing the turn removes the containers it started: they run outside
	// the turn's cgroup and would otherwise see the next turn's files.
	held, err := b.acquireVM(ctx, "dkr-run")
	if err != nil {
		t.Fatal(err)
	}
	td.Stop()
	filters := url.QueryEscape(`{"name":["leftover"]}`)
	var left []struct {
		ID string `json:"Id"`
	}
	if _, _, err := b.dockerDo(ctx, b.vmDockerHTTP(held), http.MethodGet, "/containers/json?all=1&filters="+filters, nil, &left); err != nil {
		t.Fatal(err)
	}
	b.releaseVM(held)
	if len(left) != 0 {
		t.Fatalf("turn container outlived its turn: %+v", left)
	}

	// 2. StartServices runs a container and registers bridge IP in guest DNS (10.255.255.1:53)
	// so root-netns turns can reach the service by name without NAT interception.
	netName, stopSvc, err := b.StartServices(ctx, "dkr-run", "svc-1", []agentdef.Service{
		{Name: "myapi", Image: "vesper-tiny:test", Command: []string{"/bin/tiny", "srv"}},
	})
	if err != nil {
		t.Fatalf("StartServices: %v", err)
	}
	defer stopSvc()

	code, out, stderr = runVMTurn(t, b, "dkr-run", ExecSpec{
		Argv:     []string{"/bin/sh", "-c", `test "$(curl -fsS http://myapi:8080/)" = "service-bridge-ok"`},
		Networks: []string{netName},
	})
	if code != 0 {
		t.Fatalf("service reachability failed code=%d out=%q err=%q", code, out, stderr)
	}
}

func TestVZDownwardCachesAndVirtioFSHostFolders(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	var hits int
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hits++
		_, _ = io.WriteString(w, `{"Version":"v1.2.3"}`)
	}))
	defer up.Close()

	cs, err := microvm.NewCacheStore(microvm.CacheStoreConfig{
		Dir:        filepath.Join(t.TempDir(), "caches"),
		GoUpstream: up.URL,
	})
	if err != nil {
		t.Fatal(err)
	}

	hostWS := t.TempDir()
	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		HostWorkspaces:     hostWS,
		CPUs:               2,
		MemoryMB:           512,
		PidsLimit:          256,
		CacheStore:         cs,
		TestWorkspaceBytes: 64 << 20,
		TestHomeBytes:      32 << 20,
		TestDockerBytes:    32 << 20,
	}
	defer func() { _ = b.Cleanup(ctx) }()

	// HostFolders setup via virtiofs + malicious local hook file test.
	dir, err := b.EnsureHostWorkspace(ctx, "hf-1")
	if err != nil {
		t.Fatal(err)
	}
	// Initialize a valid git repository on host and ensure host git config gets core.hooksPath=/dev/null.
	if out, gerr := exec.Command("git", "-C", dir, "init", "-q").CombinedOutput(); gerr != nil {
		t.Fatalf("git init %s: %v\n%s", dir, gerr, out)
	}
	if _, err := b.EnsureHostWorkspace(ctx, "hf-1"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "from-host.txt"), []byte("host-data\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	script := `set -eu
test "$(cat /workspace/from-host.txt)" = "host-data"
echo "vm-data" > /workspace/from-vm.txt
grep -q "extra-trusted-public-keys" /etc/nix/nix.conf
# Downward cache works (miss -> hit) and rejects PUT poisoning (405).
test "$(curl -fsS http://cache.vesper.internal/goproxy/example.com/mod/@v/v1.2.3.info)" = '{"Version":"v1.2.3"}'
test "$(curl -fsS http://cache.vesper.internal/goproxy/example.com/mod/@v/v1.2.3.info)" = '{"Version":"v1.2.3"}'
put_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT -d 'poison' http://cache.vesper.internal/goproxy/example.com/mod/@v/evil.info)
test "$put_code" = "405"
echo "CACHES_AND_VIRTIOFS_OK"
`
	code, out, stderr := runVMTurn(t, b, "hf-1", ExecSpec{
		Argv: []string{"/bin/sh", "-c", script},
	})
	if code != 0 || !strings.Contains(out, "CACHES_AND_VIRTIOFS_OK") {
		t.Fatalf("cache/virtiofs turn failed code=%d out=%q err=%q", code, out, stderr)
	}
	if hits != 1 {
		t.Fatalf("expected 1 upstream hit across 2 VM fetches, got %d", hits)
	}
	gotVMFile, err := os.ReadFile(filepath.Join(dir, "from-vm.txt"))
	if err != nil || string(gotVMFile) != "vm-data\n" {
		t.Fatalf("virtiofs write missing on host: %q %v", gotVMFile, err)
	}
	cfgOut, err := exec.Command("git", "-C", dir, "config", "--local", "core.hooksPath").CombinedOutput()
	if err != nil || strings.TrimSpace(string(cfgOut)) != "/dev/null" {
		t.Fatalf("expected core.hooksPath=/dev/null on host repo, got %q %v", cfgOut, err)
	}
}

func TestVZHostGitCloneAndBundlePushNoTokenInVM(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	// Build a real bare remote git repository on the host served over Basic-auth HTTP.
	bareRepo := filepath.Join(t.TempDir(), "remote.git")
	seedRepo := filepath.Join(t.TempDir(), "seed")
	runGit := func(dir string, args ...string) {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = []string{
			"PATH=" + os.Getenv("PATH"),
			"GIT_AUTHOR_NAME=Test", "GIT_AUTHOR_EMAIL=t@example.com",
			"GIT_COMMITTER_NAME=Test", "GIT_COMMITTER_EMAIL=t@example.com",
		}
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	if err := os.MkdirAll(bareRepo, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(seedRepo, 0o755); err != nil {
		t.Fatal(err)
	}
	runGit(bareRepo, "init", "--bare", "-b", "main")
	runGit(seedRepo, "init", "-b", "main")
	if err := os.WriteFile(filepath.Join(seedRepo, "README.md"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	runGit(seedRepo, "add", "README.md")
	runGit(seedRepo, "commit", "-m", "initial")
	runGit(seedRepo, "push", bareRepo, "main:main")

	const wantToken = "ghp_host_secret_never_in_vm"
	gitSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, pass, ok := r.BasicAuth()
		if !ok || pass != wantToken {
			w.Header().Set("WWW-Authenticate", `Basic realm="git"`)
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		rel := strings.TrimPrefix(r.URL.Path, "/org/repo.git")
		switch {
		case rel == "/info/refs" && (r.URL.Query().Get("service") == "git-upload-pack" || r.URL.Query().Get("service") == "git-receive-pack"):
			svc := r.URL.Query().Get("service")
			w.Header().Set("Content-Type", "application/x-"+svc+"-advertisement")
			pkt := "# service=" + svc + "\n"
			_, _ = io.WriteString(w, formatPktLine(pkt)+"0000")
			cmd := exec.Command("git", strings.TrimPrefix(svc, "git-"), "--stateless-rpc", "--advertise-refs", bareRepo)
			cmd.Stdout = w
			_ = cmd.Run()
		case rel == "/git-upload-pack" || rel == "/git-receive-pack":
			svc := strings.TrimPrefix(rel, "/")
			w.Header().Set("Content-Type", "application/x-"+svc+"-result")
			cmd := exec.Command("git", strings.TrimPrefix(svc, "git-"), "--stateless-rpc", bareRepo)
			cmd.Stdin = r.Body
			cmd.Stdout = w
			_ = cmd.Run()
		default:
			http.NotFound(w, r)
		}
	}))
	defer gitSrv.Close()

	b := &MicroVM{
		Driver:             microvm.NewVZDriver(),
		StateDir:           t.TempDir(),
		KernelPath:         kernel,
		RootfsPath:         rootfs,
		CPUs:               2,
		MemoryMB:           512,
		PidsLimit:          256,
		GitUpstreamBase:    gitSrv.URL,
		GitRewriteFrom:     gitSrv.URL + "/",
		TestWorkspaceBytes: 64 << 20,
		TestHomeBytes:      32 << 20,
		TestDockerBytes:    32 << 20,
	}
	defer func() { _ = b.Cleanup(ctx) }()

	// Allow TestUpstreams so host can dial gitSrv during http redirect on https or use plain URL;
	// newGitUploadProxy dials GitUpstreamBase directly from the host (outside synthetic DNS),
	// so rewriting https://fake-gh.test/ -> http://git.vesper.internal/github/ keeps guest traffic inside vsock!
	b.GitRewriteFrom = "https://github.com/"

	cloneAndCommit := `set -eu
test -z "${GH_TOKEN:-}"
test -z "${GITHUB_TOKEN:-}"
test -z "${LAZYAGENTS_SSH_KEY:-}"
! tr '\0' '\n' < /proc/self/environ | grep -q "` + wantToken + `"
# An SSH remote fetches through the host proxy too, with no key in the VM.
git clone -q git@github.com:org/repo.git /workspace/repo-ssh
git config --global user.name Agent
git config --global user.email agent@example.com
git clone https://github.com/org/repo.git /workspace/repo
cd /workspace/repo
git checkout -b feat/from-vm
echo "new work" > work.txt
git add work.txt
git commit -m "work inside vm"
# Direct push from inside VM through git.vesper.internal must fail (403)!
if git push origin feat/from-vm 2>/dev/null; then
  echo "ERROR: VM pushed directly!" >&2; exit 1
fi
`
	code, out, stderr := runVMTurn(t, b, "git-run", ExecSpec{
		Argv: []string{"/bin/sh", "-c", cloneAndCommit},
		Env:  map[string]string{"GH_TOKEN": wantToken, SSHKeyEnv: "not-a-real-ssh-key"},
	})
	if code != 0 {
		t.Fatalf("clone/commit turn failed code=%d out=%q err=%q", code, out, stderr)
	}

	// Create bundle inside VM without credentials, stream out to host, and push on host using wantToken.
	bundleCmd := BundleScript("/workspace/repo", "refs/heads/feat/from-vm", pushRoot+"/push.bundle")
	code, out, stderr = runVMTurn(t, b, "git-run", ExecSpec{
		Argv: []string{"/bin/sh", "-c", bundleCmd},
	})
	if code != 0 || !strings.Contains(out, bundleMarker) {
		t.Fatalf("bundle failed code=%d out=%q err=%q", code, out, stderr)
	}

	hostTmp := t.TempDir()
	hostBundle := filepath.Join(hostTmp, "push.bundle")
	if err := copyGuestFileToHost(ctx, b, "git-run", pushRoot+"/push.bundle", hostBundle, maxHostBundleBytes); err != nil {
		t.Fatal(err)
	}
	r := &Runner{Backend: b}
	pushOut, perr := r.runHostPushBundle(ctx, hostBundle, filepath.Join(hostTmp, "stage.git"), gitSrv.URL+"/org/repo.git", "feat/from-vm", wantToken, true)
	if perr != nil {
		t.Fatalf("host push failed: %v\n%s", perr, pushOut)
	}

	// Confirm remote bare repo received the commit pushed exclusively from the host.
	verifyCmd := exec.Command("git", "-C", bareRepo, "rev-parse", "--verify", "refs/heads/feat/from-vm")
	if vout, err := verifyCmd.CombinedOutput(); err != nil {
		t.Fatalf("pushed branch missing on remote: %v %s", err, vout)
	}
	_ = time.Second
}

func formatPktLine(s string) string {
	n := len(s) + 4
	const hex = "0123456789abcdef"
	return string([]byte{
		hex[(n>>12)&0xf], hex[(n>>8)&0xf], hex[(n>>4)&0xf], hex[n&0xf],
	}) + s
}

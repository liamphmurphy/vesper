package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/macclient"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// localGuest is a guest agent that runs exec requests on this machine, so the
// broker's real commands (sh, tar, rm) run against a temp "guest workspace".
func localGuest(_ context.Context, conn net.Conn) {
	f, err := guestproto.ReadFrame(conn)
	if err != nil {
		return
	}
	serveLocalGuest(conn, f)
}

func serveLocalGuest(conn net.Conn, f guestproto.Frame) {
	var req guestproto.Request
	_ = json.Unmarshal(f.Data, &req)
	ok := func() {
		resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
	}
	if req.Op != guestproto.OpExecStart {
		ok()
		return
	}
	var in guestproto.ExecReq
	_ = json.Unmarshal(req.V, &in)
	argv := append([]string(nil), in.Argv...)
	if _, err := os.Stat(argv[0]); err != nil {
		argv[0] = filepath.Base(argv[0]) // e.g. /usr/bin/tar lives in /bin here
	}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Dir = in.Dir
	cmd.Env = os.Environ()
	for k, v := range in.Env {
		if k != "PATH" && k != "HOME" {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
	}
	stdin, _ := cmd.StdinPipe()
	stdout, _ := cmd.StdoutPipe()
	stderr, _ := cmd.StderrPipe()
	if err := cmd.Start(); err != nil {
		resp, _ := json.Marshal(guestproto.Response{ID: f.ID, Err: err.Error()})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
		return
	}
	ok()
	sw := guestproto.NewSyncWriter(conn)
	go func() {
		for {
			fr, err := guestproto.ReadFrame(conn)
			if err != nil {
				_ = cmd.Process.Kill()
				return
			}
			switch fr.Type {
			case guestproto.FrameStdin:
				_, _ = stdin.Write(fr.Data)
			case guestproto.FrameStdinEOF:
				_ = stdin.Close()
			}
		}
	}()
	var wg sync.WaitGroup
	for typ, r := range map[uint8]io.Reader{guestproto.FrameStdout: stdout, guestproto.FrameStderr: stderr} {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 32<<10)
			for {
				n, err := r.Read(buf)
				if n > 0 {
					_ = sw.WriteFrame(guestproto.Frame{Type: typ, ID: f.ID, Data: append([]byte(nil), buf[:n]...)})
				}
				if err != nil {
					return
				}
			}
		}()
	}
	wg.Wait()
	code := 0
	if err := cmd.Wait(); err != nil {
		code = 1
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		}
	}
	_ = guestproto.WriteJSONFrame(sw, guestproto.FrameExecExit, f.ID, guestproto.ExecExit{Code: code})
}

func testMacImage(t *testing.T) *microvm.MacOSImage {
	t.Helper()
	dir := t.TempDir()
	for _, name := range []string{microvm.MacOSDiskFile, microvm.MacOSAuxFile} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, microvm.MacOSConfigFile), []byte(`{"os":"darwin","arch":"arm64","hardwareModel":"aHc="}`), 0o644); err != nil {
		t.Fatal(err)
	}
	img, err := microvm.LoadMacOSImage(dir)
	if err != nil {
		t.Fatal(err)
	}
	return img
}

func newTestMacGuests(t *testing.T, drv *microvm.MemDriver) *MacOSGuests {
	t.Helper()
	u, err := user.Current()
	if err != nil {
		t.Fatal(err)
	}
	g := &MacOSGuests{
		Driver:         drv,
		Image:          testMacImage(t),
		StateDir:       t.TempDir(),
		User:           u.Username,
		GuestWorkspace: t.TempDir(),
	}
	t.Cleanup(g.Close)
	return g
}

func macClient(t *testing.T, g *MacOSGuests, runID string) (*macclient.Client, *bytes.Buffer) {
	t.Helper()
	srv := httptest.NewServer(g.Handler(runID))
	t.Cleanup(srv.Close)
	status := &bytes.Buffer{}
	return &macclient.Client{BaseURL: srv.URL, Status: status}, status
}

func gitCheckout(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, body := range files {
		p := filepath.Join(dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := os.Stat(filepath.Join(dir, ".git")); err == nil {
		return
	}
	out, err := exec.Command("git", "-C", dir, "init", "-q").CombinedOutput()
	if err != nil {
		t.Fatalf("git init: %v: %s", err, out)
	}
}

func readGuest(t *testing.T, g *MacOSGuests, rel string) (string, bool) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(g.GuestWorkspace, filepath.FromSlash(rel)))
	if os.IsNotExist(err) {
		return "", false
	}
	if err != nil {
		t.Fatal(err)
	}
	return string(b), true
}

func TestMacOSGuestBootsOnlyOnFirstCall(t *testing.T) {
	drv := &microvm.MemDriver{Handler: localGuest}
	g := newTestMacGuests(t, drv)
	c, _ := macClient(t, g, "run-1")

	// Attaching the handler (what every turn does) boots nothing.
	if n := len(drv.Configs()); n != 0 || g.RunningVMs() != 0 {
		t.Fatalf("before any call: %d boots, %d running", n, g.RunningVMs())
	}
	ctx := context.Background()
	if err := c.Start(ctx); err != nil {
		t.Fatal(err)
	}
	if err := c.Start(ctx); err != nil {
		t.Fatal(err)
	}
	cfgs := drv.Configs()
	if len(cfgs) != 1 {
		t.Fatalf("two calls booted %d VMs, want 1", len(cfgs))
	}
	boot := cfgs[0].MacOS
	if boot == nil || string(boot.HardwareModel) != "hw" {
		t.Fatalf("boot config = %+v, want a macOS boot with the image's hardware model", boot)
	}
	runDir := filepath.Join(g.StateDir, "runs", "run-1", "macos")
	if cfgs[0].Drives[0].Path != filepath.Join(runDir, "disk.img") || boot.AuxStoragePath != filepath.Join(runDir, "nvram.bin") {
		t.Fatalf("VM uses %q / %q, want its own clones under %s", cfgs[0].Drives[0].Path, boot.AuxStoragePath, runDir)
	}
	if b, _ := os.ReadFile(boot.AuxStoragePath); string(b) != microvm.MacOSAuxFile {
		t.Fatalf("aux storage clone = %q", b)
	}
}

func TestMacOSGuestSyncsRunsAndPulls(t *testing.T) {
	drv := &microvm.MemDriver{Handler: localGuest}
	g := newTestMacGuests(t, drv)
	c, _ := macClient(t, g, "run-1")
	ctx := context.Background()

	ws := t.TempDir()
	repo := filepath.Join(ws, "vesper")
	gitCheckout(t, repo, map[string]string{
		".gitignore":                   ".build/\n",
		"macos/Package.swift":          "// swift-tools-version: 6.0\n",
		"macos/Sources/App/main.swift": "print(1)\n",
		"macos/.build/junk":            "ignored",
	})
	sync := func() int {
		t.Helper()
		m, err := macclient.ListFiles(ctx, ws, repo)
		if err != nil {
			t.Fatal(err)
		}
		n, err := c.Sync(ctx, ws, m)
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := sync(); n != 3 {
		t.Fatalf("first sync sent %d files, want 3", n)
	}
	if got, ok := readGuest(t, g, "vesper/macos/Sources/App/main.swift"); !ok || got != "print(1)\n" {
		t.Fatalf("guest main.swift = %q, %v", got, ok)
	}
	if _, ok := readGuest(t, g, "vesper/macos/.build/junk"); ok {
		t.Fatal("an ignored file was synced")
	}
	if n := sync(); n != 0 {
		t.Fatalf("an unchanged tree resent %d files", n)
	}

	// Build output in the guest survives syncs; a file deleted on Linux goes.
	if err := os.MkdirAll(filepath.Join(g.GuestWorkspace, "vesper/macos/.build"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(g.GuestWorkspace, "vesper/macos/.build/cache"), []byte("warm"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(repo, "macos/Sources/App/main.swift")); err != nil {
		t.Fatal(err)
	}
	gitCheckout(t, repo, map[string]string{"macos/Sources/App/App.swift": "@main struct App {}\n"})
	if n := sync(); n != 1 {
		t.Fatalf("sync after one add sent %d files, want 1", n)
	}
	if _, ok := readGuest(t, g, "vesper/macos/Sources/App/main.swift"); ok {
		t.Fatal("a file deleted on Linux is still in the guest")
	}
	if got, _ := readGuest(t, g, "vesper/macos/.build/cache"); got != "warm" {
		t.Fatal("sync deleted the guest's build output")
	}

	var out, errOut bytes.Buffer
	code, err := c.Exec(ctx, guestproto.MacExecReq{
		Argv: []string{"/bin/sh", "-c", `pwd; cat Sources/App/App.swift; echo "$GREETING" >&2; echo built > out.txt; exit 3`},
		Dir:  "vesper/macos",
		Env:  map[string]string{"GREETING": "hi"},
	}, &out, &errOut)
	if err != nil {
		t.Fatal(err)
	}
	if code != 3 {
		t.Errorf("exit code = %d, want 3", code)
	}
	wantDir := filepath.Join(g.GuestWorkspace, "vesper/macos")
	if !strings.HasPrefix(out.String(), wantDir+"\n") || !strings.Contains(out.String(), "@main struct App {}") {
		t.Errorf("stdout = %q", out.String())
	}
	if errOut.String() != "hi\n" {
		t.Errorf("stderr = %q", errOut.String())
	}

	if err := c.Pull(ctx, ws, []string{"vesper/macos/out.txt"}, io.Discard); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(filepath.Join(repo, "macos/out.txt")); string(b) != "built\n" {
		t.Fatalf("pulled out.txt = %q", b)
	}
}

func TestMacOSGuestSyncKeepsOtherCheckouts(t *testing.T) {
	drv := &microvm.MemDriver{Handler: localGuest}
	g := newTestMacGuests(t, drv)
	c, _ := macClient(t, g, "run-1")
	ctx := context.Background()

	ws := t.TempDir()
	a, b := filepath.Join(ws, "a"), filepath.Join(ws, "b")
	gitCheckout(t, a, map[string]string{"a.txt": "a"})
	gitCheckout(t, b, map[string]string{"b.txt": "b"})
	for _, repo := range []string{a, b} {
		m, err := macclient.ListFiles(ctx, ws, repo)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := c.Sync(ctx, ws, m); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok := readGuest(t, g, "a/a.txt"); !ok {
		t.Fatal("syncing checkout b deleted checkout a's files")
	}
}

func TestMacOSGuestRejectsPathsOutsideTheWorkspace(t *testing.T) {
	g := newTestMacGuests(t, &microvm.MemDriver{Handler: localGuest})
	srv := httptest.NewServer(g.Handler("run-1"))
	defer srv.Close()
	for p, body := range map[string]string{
		guestproto.MacPathPlan: `{"files":[{"p":"../etc/passwd"}]}`,
		guestproto.MacPathExec: `{"argv":["true"],"dir":"../.."}`,
		guestproto.MacPathPull: `{"paths":["/etc"]}`,
	} {
		res, err := http.Post(srv.URL+p, "application/json", strings.NewReader(body))
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: status %d, want 400", p, res.StatusCode)
		}
	}
	if g.RunningVMs() != 0 {
		t.Error("a rejected request booted a VM")
	}
}

func TestMacOSGuestSlotsWaitThenEvictIdle(t *testing.T) {
	drv := &microvm.MemDriver{Handler: localGuest}
	g := newTestMacGuests(t, drv)
	g.IdleTTL = time.Hour
	ctx := context.Background()

	// Two runs each hold their VM, filling both of Apple's slots.
	v1, err := g.acquire(ctx, "run-1", nil)
	if err != nil {
		t.Fatal(err)
	}
	v2, err := g.acquire(ctx, "run-2", nil)
	if err != nil {
		t.Fatal(err)
	}

	statuses := make(chan guestproto.MacStatus, 4)
	got := make(chan error, 1)
	go func() {
		v3, err := g.acquire(ctx, "run-3", func(s guestproto.MacStatus) { statuses <- s })
		if err == nil {
			g.release(v3)
		}
		got <- err
	}()
	select {
	case s := <-statuses:
		if s.Status != "waiting" {
			t.Fatalf("third run's first status = %+v, want waiting", s)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("third run didn't say it's waiting")
	}
	if g.RunningVMs() != 2 {
		t.Fatalf("running = %d while full, want 2", g.RunningVMs())
	}

	// run-1 finishes its call; its idle VM gives run-3 the slot.
	g.release(v1)
	select {
	case err := <-got:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("third run never got a slot")
	}
	if g.RunningVMs() != 2 {
		t.Fatalf("running = %d, want 2 (run-1 evicted)", g.RunningVMs())
	}
	g.mu.Lock()
	_, has1 := g.vms["run-1"]
	_, has3 := g.vms["run-3"]
	g.mu.Unlock()
	if has1 || !has3 {
		t.Fatalf("after eviction: run-1 present=%v, run-3 present=%v", has1, has3)
	}
	g.release(v2)
}

func TestMacOSGuestReplacesAVMThatStoppedAnswering(t *testing.T) {
	drv := &microvm.MemDriver{Handler: localGuest}
	g := newTestMacGuests(t, drv)
	g.IdleTTL = time.Hour
	c, _ := macClient(t, g, "run-1")
	ctx := context.Background()

	if err := c.Start(ctx); err != nil {
		t.Fatal(err)
	}
	// The guest goes away between calls without the host hearing of it.
	g.mu.Lock()
	dead := g.vms["run-1"].vm.(*microvm.MemVM)
	g.mu.Unlock()
	_ = dead.Stop(ctx)

	if err := c.Start(ctx); err != nil {
		t.Fatalf("call after the guest died: %v", err)
	}
	if n := len(drv.Configs()); n != 2 {
		t.Fatalf("boots = %d, want 2 (the dead VM replaced)", n)
	}
	if g.RunningVMs() != 1 {
		t.Fatalf("running = %d, want 1", g.RunningVMs())
	}
}

func TestMacOSGuestKeepsADeadVMAnotherCallIsUsing(t *testing.T) {
	drv := &microvm.MemDriver{Handler: localGuest}
	g := newTestMacGuests(t, drv)
	g.IdleTTL = time.Hour
	ctx := context.Background()

	held, err := g.acquire(ctx, "run-1", nil)
	if err != nil {
		t.Fatal(err)
	}
	_ = held.vm.Stop(ctx)

	if _, err := g.acquire(ctx, "run-1", nil); err == nil || !strings.Contains(err.Error(), "stopped answering") {
		t.Fatalf("acquire while another call holds the dead VM: err = %v, want stopped answering", err)
	}
	g.mu.Lock()
	active, still := held.active, g.vms["run-1"] == held
	g.mu.Unlock()
	if active != 1 || !still {
		t.Fatalf("after the failed acquire: active = %d, still registered = %v; want 1, true", active, still)
	}
	g.release(held)
	if len(drv.Configs()) != 1 {
		t.Fatalf("boots = %d, want 1", len(drv.Configs()))
	}
}

func TestMacOSGuestStopsWhenIdle(t *testing.T) {
	drv := &microvm.MemDriver{Handler: localGuest}
	g := newTestMacGuests(t, drv)
	g.IdleTTL = 50 * time.Millisecond
	c, _ := macClient(t, g, "run-1")
	ctx := context.Background()

	if err := c.Start(ctx); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "idle macOS VM to stop", func() bool { return g.RunningVMs() == 0 })
	// The next call boots it again, on the same disk.
	if err := c.Start(ctx); err != nil {
		t.Fatal(err)
	}
	cfgs := drv.Configs()
	if len(cfgs) != 2 || cfgs[0].Drives[0].Path != cfgs[1].Drives[0].Path {
		t.Fatalf("reboot configs = %d, want 2 on the same disk", len(cfgs))
	}
}

func TestMicroVMTurnsGetMacHandlerWithoutBooting(t *testing.T) {
	drv := &microvm.MemDriver{Handler: okGuest}
	b := spareBackend(t, drv)
	b.SpareVMs = 0
	macDrv := &microvm.MemDriver{Handler: localGuest}
	b.MacOS = newTestMacGuests(t, macDrv)

	var seen map[string]string
	drv.Handler = func(ctx context.Context, conn net.Conn) {
		f, err := guestproto.ReadFrame(conn)
		if err != nil {
			return
		}
		var req guestproto.Request
		_ = json.Unmarshal(f.Data, &req)
		if req.Op == guestproto.OpExecStart {
			var in guestproto.ExecReq
			_ = json.Unmarshal(req.V, &in)
			seen = in.Env
		}
		resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
		if req.Op == guestproto.OpExecStart {
			ex, _ := json.Marshal(guestproto.ExecExit{})
			_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, ID: f.ID, Data: ex})
		}
	}
	p, err := b.Start(context.Background(), "run-1", ExecSpec{Argv: []string{"true"}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := p.Wait(); err != nil {
		t.Fatal(err)
	}
	if seen[MacOSEnv] != "1" {
		t.Errorf("turn env %s = %q, want 1", MacOSEnv, seen[MacOSEnv])
	}
	if n := len(macDrv.Configs()); n != 0 {
		t.Fatalf("a turn without `mac` booted %d macOS VMs", n)
	}
	if err := b.RemoveWorkspace(context.Background(), "run-1"); err != nil {
		t.Fatal(err)
	}
}

// stuckStopDriver starts MemVMs whose Stop blocks until release closes, like
// a Virtualization.framework stop that never completes.
type stuckStopDriver struct {
	microvm.MemDriver
	release chan struct{}
}

type stuckStopVM struct {
	microvm.VM
	release chan struct{}
}

func (d *stuckStopDriver) Start(ctx context.Context, cfg microvm.VMConfig) (microvm.VM, error) {
	vm, err := d.MemDriver.Start(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return stuckStopVM{VM: vm, release: d.release}, nil
}

func (v stuckStopVM) Stop(ctx context.Context) error {
	<-v.release
	return v.VM.Stop(ctx)
}

// execGuest answers everything but exec like localGuest, and handles exec
// with onExec instead.
func execGuest(onExec func(net.Conn)) func(context.Context, net.Conn) {
	return func(ctx context.Context, conn net.Conn) {
		f, err := guestproto.ReadFrame(conn)
		if err != nil {
			return
		}
		var req guestproto.Request
		_ = json.Unmarshal(f.Data, &req)
		if req.Op == guestproto.OpExecStart {
			onExec(conn)
			return
		}
		resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
	}
}

func acquireWithin(t *testing.T, g *MacOSGuests, runID string, limit time.Duration) error {
	t.Helper()
	got := make(chan error, 1)
	go func() {
		v, err := g.acquire(context.Background(), runID, nil)
		if err == nil {
			g.release(v)
		}
		got <- err
	}()
	select {
	case err := <-got:
		return err
	case <-time.After(limit):
		t.Fatalf("acquire still waiting after %s", limit)
		return nil
	}
}

func TestMacOSGuestBootGivesUpWhenTheGuestNeverAnswers(t *testing.T) {
	never := make(chan struct{})
	t.Cleanup(func() { close(never) })
	drv := &microvm.MemDriver{Handler: execGuest(func(net.Conn) { <-never })}
	g := newTestMacGuests(t, drv)
	g.prepareTimeout = 100 * time.Millisecond

	err := acquireWithin(t, g, "run-1", 5*time.Second)
	if err == nil || !strings.Contains(err.Error(), "prepare workspace") {
		t.Fatalf("acquire = %v, want a prepare workspace error", err)
	}
	if g.RunningVMs() != 0 {
		t.Fatalf("running = %d after the failed boot, want 0", g.RunningVMs())
	}
}

func TestMacOSGuestFailedBootDoesntWaitOnAStuckStop(t *testing.T) {
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	drv := &stuckStopDriver{
		MemDriver: microvm.MemDriver{Handler: execGuest(func(conn net.Conn) { _ = conn.Close() })},
		release:   release,
	}
	g := &MacOSGuests{Driver: drv, Image: testMacImage(t), StateDir: t.TempDir(), GuestWorkspace: t.TempDir()}
	g.stopTimeout = 100 * time.Millisecond

	// Both calls fail fast; the second doesn't hang behind the first's stop.
	for i := 0; i < 2; i++ {
		if err := acquireWithin(t, g, "run-1", 5*time.Second); err == nil {
			t.Fatalf("call %d: acquire succeeded against a guest that drops exec", i+1)
		}
	}
}

// logGuest serves the guest agent's log (logText) through Stat and ReadFile,
// like the real agent, and hands everything else to exec (nil: localGuest).
func logGuest(logText string, exec func(net.Conn)) func(context.Context, net.Conn) {
	return func(_ context.Context, conn net.Conn) {
		f, err := guestproto.ReadFrame(conn)
		if err != nil {
			return
		}
		var req guestproto.Request
		_ = json.Unmarshal(f.Data, &req)
		reply := func(v any) {
			raw, _ := json.Marshal(v)
			resp, _ := json.Marshal(guestproto.Response{ID: f.ID, V: raw})
			_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
		}
		switch req.Op {
		case guestproto.OpStat:
			var in guestproto.StatReq
			_ = json.Unmarshal(req.V, &in)
			if in.Path != guestproto.MacAgentLogPath {
				reply(guestproto.StatResp{})
				return
			}
			reply(guestproto.StatResp{Exists: true, IsRegular: true, Size: int64(len(logText))})
		case guestproto.OpReadFile:
			var in guestproto.ReadFileReq
			_ = json.Unmarshal(req.V, &in)
			reply(nil)
			data := logText[min(int(in.Offset), len(logText)):]
			if in.Limit > 0 && int64(len(data)) > in.Limit {
				data = data[:in.Limit]
			}
			_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameFileChunk, ID: f.ID, Data: []byte(data)})
			_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameFileEOF, ID: f.ID})
		case guestproto.OpExecStart:
			if exec != nil {
				exec(conn)
				return
			}
			serveLocalGuest(conn, f)
		default:
			serveLocalGuest(conn, f)
		}
	}
}

func TestMacOSGuestFailedBootCarriesTheAgentLog(t *testing.T) {
	drv := &microvm.MemDriver{Handler: logGuest("boot\npanic: exec went wrong\n", func(conn net.Conn) { _ = conn.Close() })}
	g := newTestMacGuests(t, drv)
	c, _ := macClient(t, g, "run-1")

	err := c.Start(context.Background())
	if err == nil {
		t.Fatal("start succeeded against a guest that drops exec")
	}
	for _, want := range []string{"prepare workspace", "end of " + guestproto.MacAgentLogPath, "panic: exec went wrong"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("start error lacks %q:\n%v", want, err)
		}
	}
}

func TestMacOSGuestAgentLogReturnsItsTail(t *testing.T) {
	head := strings.Repeat("old line\n", 20000) // well past the tail limit
	drv := &microvm.MemDriver{Handler: logGuest(head+"newest line\n", nil)}
	g := newTestMacGuests(t, drv)
	c, _ := macClient(t, g, "run-1")

	log, err := c.AgentLog(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(log, "newest line\n") {
		t.Fatalf("log doesn't end with the newest line: ...%q", log[max(0, len(log)-40):])
	}
	if len(log) != macAgentLogTail {
		t.Fatalf("log is %d bytes, want the last %d", len(log), macAgentLogTail)
	}
}

func TestMacOSGuestFailedBootFallsBackToTheLogReadAtBoot(t *testing.T) {
	// The agent serves its log until the first exec, which takes it down for
	// good, so the log can't be read after the failure.
	var dead atomic.Bool
	serve := logGuest("earlier boot\npanic: crashed on exec\n", func(conn net.Conn) {
		dead.Store(true)
		_ = conn.Close()
	})
	drv := &microvm.MemDriver{Handler: func(ctx context.Context, conn net.Conn) {
		if dead.Load() {
			_ = conn.Close()
			return
		}
		serve(ctx, conn)
	}}
	g := newTestMacGuests(t, drv)
	c, _ := macClient(t, g, "run-1")

	err := c.Start(context.Background())
	if err == nil {
		t.Fatal("start succeeded against a guest that dies on exec")
	}
	for _, want := range []string{"prepare workspace", "stopped answering", "as of this boot", "panic: crashed on exec"} {
		if !strings.Contains(err.Error(), want) {
			t.Fatalf("start error lacks %q:\n%v", want, err)
		}
	}
}

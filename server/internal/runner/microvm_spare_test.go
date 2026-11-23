package runner

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// okGuest answers every guest call, and every exec with exit 0.
func okGuest(_ context.Context, conn net.Conn) {
	f, err := guestproto.ReadFrame(conn)
	if err != nil {
		return
	}
	var req guestproto.Request
	_ = json.Unmarshal(f.Data, &req)
	resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
	_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
	if req.Op == guestproto.OpExecStart {
		ex, _ := json.Marshal(guestproto.ExecExit{Code: 0})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, ID: f.ID, Data: ex})
	}
}

func spareBackend(t *testing.T, drv *microvm.MemDriver) *MicroVM {
	t.Helper()
	b := &MicroVM{
		Driver:             drv,
		StateDir:           t.TempDir(),
		KernelPath:         "/k",
		RootfsPath:         "/r",
		MemoryMB:           1024,
		IdleMemoryMB:       160,
		WarmTTL:            time.Minute,
		SpareVMs:           1,
		TestWorkspaceBytes: 2 << 20,
		TestHomeBytes:      2 << 20,
		TestDockerBytes:    2 << 20,
	}
	t.Cleanup(func() { _ = b.Close() })
	return b
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func runTrue(t *testing.T, b *MicroVM, runID string) {
	t.Helper()
	p, err := b.Start(context.Background(), runID, ExecSpec{Argv: []string{"true"}})
	if err != nil {
		t.Fatal(err)
	}
	go func() { _, _ = io.Copy(io.Discard, p.Stdout()) }()
	go func() { _, _ = io.Copy(io.Discard, p.Stderr()) }()
	if code, err := p.Wait(); err != nil || code != 0 {
		t.Fatalf("exit %d: %v", code, err)
	}
}

// bootedFor reports whether the driver booted a VM on runID's own disks.
func bootedFor(drv *microvm.MemDriver, runDir string) bool {
	for _, cfg := range drv.Configs() {
		for _, d := range cfg.Drives {
			if strings.HasPrefix(d.Path, runDir+string(filepath.Separator)) {
				return true
			}
		}
		if len(cfg.Shares) > 0 {
			return true
		}
	}
	return false
}

func (b *MicroVM) firstSpare() *microvm.MemVM {
	b.spareMu.Lock()
	defer b.spareMu.Unlock()
	return b.spares[0].vm.(*microvm.MemVM)
}

// A new run takes the spare instead of booting a VM, and a replacement
// spare boots, idling at IdleMemoryMB.
func TestNewRunClaimsSpareVM(t *testing.T) {
	drv := &microvm.MemDriver{Handler: okGuest}
	b := spareBackend(t, drv)
	b.WarmSpares()
	waitFor(t, "a spare", func() bool { return b.spareCount() == 1 })
	spare := b.firstSpare()
	if got := spare.MemoryTarget(); got != 160<<20 {
		t.Fatalf("spare balloon target = %d MiB, want 160", got>>20)
	}
	if !spare.Paused() {
		t.Fatal("idle spare VM should be paused until claimed")
	}

	runTrue(t, b, "r1")

	if spare.ResumeCount() < 1 {
		t.Fatalf("claimed spare resume count = %d, want >= 1", spare.ResumeCount())
	}

	runDir, _ := b.runDir("r1")
	if bootedFor(drv, runDir) {
		t.Fatal("the new run booted its own VM instead of taking the spare")
	}
	b.runsMu.Lock()
	got := b.vms["r1"].vm
	b.runsMu.Unlock()
	if got != spare {
		t.Fatal("the run isn't using the spare's VM")
	}
	for _, f := range []string{"workspace.ext4", "home.ext4", "docker.ext4", "meta.json"} {
		if _, err := os.Stat(filepath.Join(runDir, f)); err != nil {
			t.Fatalf("run dir: %v", err)
		}
	}
	waitFor(t, "a replacement spare", func() bool { return b.spareCount() == 1 && b.firstSpare() != spare })
	if n := b.ActiveVMCount(); n != 2 {
		t.Fatalf("ActiveVMCount = %d, want the run's VM and the spare", n)
	}
	if entries, _ := os.ReadDir(b.sparesDir()); len(entries) != 1 {
		t.Fatalf("spare dirs: %d, want only the replacement's", len(entries))
	}
}

// A run with a host-folder workspace needs its share at boot, so it leaves
// the spare alone and boots its own VM.
func TestHostFolderRunLeavesSpareVM(t *testing.T) {
	drv := &microvm.MemDriver{Handler: okGuest}
	b := spareBackend(t, drv)
	b.HostWorkspaces = t.TempDir()
	b.WarmSpares()
	waitFor(t, "a spare", func() bool { return b.spareCount() == 1 })
	spare := b.firstSpare()
	if _, err := b.EnsureHostWorkspace(context.Background(), "r2"); err != nil {
		t.Fatal(err)
	}

	runTrue(t, b, "r2")

	runDir, _ := b.runDir("r2")
	if !bootedFor(drv, runDir) {
		t.Fatal("the host-folder run didn't boot its own VM")
	}
	if b.spareCount() != 1 || b.firstSpare() != spare || spare.Stopped() {
		t.Fatal("the host-folder run took or stopped the spare")
	}
}

// A spare booted before the cache drives changed is discarded, and the run
// boots with the current drives.
func TestStaleSpareVMIsDiscarded(t *testing.T) {
	drv := &microvm.MemDriver{Handler: okGuest}
	b := spareBackend(t, drv)
	cacheDir := t.TempDir()
	cs, err := microvm.NewCacheStore(microvm.CacheStoreConfig{Dir: cacheDir})
	if err != nil {
		t.Fatal(err)
	}
	b.CacheStore = cs
	erofs := filepath.Join(cacheDir, "erofs")
	if err := os.WriteFile(filepath.Join(erofs, "cache-npm-1.erofs"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	b.WarmSpares()
	waitFor(t, "a spare", func() bool { return b.spareCount() == 1 })
	spare := b.firstSpare()
	if err := os.WriteFile(filepath.Join(erofs, "cache-npm-2.erofs"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	runTrue(t, b, "r3")

	waitFor(t, "the stale spare to stop", spare.Stopped)
	runDir, _ := b.runDir("r3")
	if !bootedFor(drv, runDir) {
		t.Fatal("the run didn't boot its own VM")
	}
	var cfg microvm.VMConfig
	for _, c := range drv.Configs() {
		for _, d := range c.Drives {
			if strings.HasPrefix(d.Path, runDir) {
				cfg = c
			}
		}
	}
	if len(cfg.Drives) == 0 || filepath.Base(cfg.Drives[len(cfg.Drives)-1].Path) != "cache-npm-2.erofs" {
		t.Fatalf("run booted with drives %+v", cfg.Drives)
	}
}

// Closing the backend stops the spare, removes its disks, and boots no more.
func TestCloseStopsSpareVMs(t *testing.T) {
	drv := &microvm.MemDriver{Handler: okGuest}
	b := spareBackend(t, drv)
	b.WarmSpares()
	waitFor(t, "a spare", func() bool { return b.spareCount() == 1 })
	spare := b.firstSpare()

	if err := b.Close(); err != nil {
		t.Fatal(err)
	}

	if !spare.Stopped() || b.ActiveVMCount() != 0 {
		t.Fatalf("after Close: spare stopped %v, %d VMs", spare.Stopped(), b.ActiveVMCount())
	}
	if _, err := os.Stat(b.sparesDir()); !os.IsNotExist(err) {
		t.Fatalf("spare disks left behind: %v", err)
	}
	b.WarmSpares()
	time.Sleep(20 * time.Millisecond)
	if b.spareCount() != 0 || len(drv.Configs()) != 1 {
		t.Fatal("a closed backend booted another spare")
	}
}

// Without SpareVMs nothing boots ahead of a run.
func TestNoSpareVMsByDefault(t *testing.T) {
	drv := &microvm.MemDriver{Handler: okGuest}
	b := spareBackend(t, drv)
	b.SpareVMs = 0
	b.WarmSpares()
	runTrue(t, b, "r4")
	if len(drv.Configs()) != 1 || b.spareCount() != 0 {
		t.Fatalf("%d VMs booted, %d spares", len(drv.Configs()), b.spareCount())
	}
}

// Idle warm VMs pause after cache drop + settle delay, resume on the next turn,
// and resync guest wall-clock time when resumed after ClockSyncAfter.
func TestWarmVMPausesAfterDeflateAndResumesOnNextTurn(t *testing.T) {
	synced := make(chan []string, 4)
	drv := &microvm.MemDriver{
		Handler: func(_ context.Context, conn net.Conn) {
			f, err := guestproto.ReadFrame(conn)
			if err != nil {
				return
			}
			var req guestproto.Request
			_ = json.Unmarshal(f.Data, &req)
			resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
			_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
			if req.Op == guestproto.OpExecStart {
				var execReq guestproto.ExecReq
				_ = json.Unmarshal(req.V, &execReq)
				if len(execReq.Argv) > 0 && execReq.Argv[0] == "/bin/date" {
					synced <- execReq.Argv
				}
				ex, _ := json.Marshal(guestproto.ExecExit{Code: 0})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, ID: f.ID, Data: ex})
			}
		},
	}
	b := spareBackend(t, drv)
	b.SpareVMs = 0
	b.CacheDropDelay = 25 * time.Millisecond
	b.PauseSettleDelay = 25 * time.Millisecond
	b.ClockSyncAfter = 20 * time.Millisecond

	runTrue(t, b, "r-pause")
	b.runsMu.Lock()
	mvm := b.vms["r-pause"].vm.(*microvm.MemVM)
	b.runsMu.Unlock()

	if mvm.Paused() {
		t.Fatal("warm VM paused immediately before CacheDropDelay + PauseSettleDelay")
	}
	waitFor(t, "warm VM to pause", mvm.Paused)
	time.Sleep(30 * time.Millisecond)

	// MemVM.DialVSock fails if paused, so succeeding proves acquireVM resumed it.
	runTrue(t, b, "r-pause")
	if mvm.ResumeCount() != 1 {
		t.Fatalf("resume count = %d, want 1", mvm.ResumeCount())
	}
	select {
	case argv := <-synced:
		if len(argv) < 4 || argv[0] != "/bin/date" || argv[1] != "-u" || argv[2] != "-s" {
			t.Fatalf("unexpected clock sync argv: %v", argv)
		}
	case <-time.After(time.Second):
		t.Fatal("expected guest clock sync after paused resume")
	}
}

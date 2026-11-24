package runner

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// fakeGuestAgent serves minimal guestproto RPCs for unit testing MicroVM
// Custom App lifecycle without booting a real Linux kernel.
type fakeGuestAgent struct {
	mu    sync.Mutex
	execs []guestproto.ExecReq
	files map[string][]byte
}

func newFakeGuestAgent() *fakeGuestAgent {
	return &fakeGuestAgent{files: make(map[string][]byte)}
}

func (a *fakeGuestAgent) handle(_ context.Context, conn net.Conn) {
	defer conn.Close()
	fr, err := guestproto.ReadFrame(conn)
	if err != nil || fr.Type != guestproto.FrameReq {
		return
	}
	var req guestproto.Request
	if err := json.Unmarshal(fr.Data, &req); err != nil {
		return
	}
	switch req.Op {
	case guestproto.OpPing, guestproto.OpSyncAndDropCaches, guestproto.OpStartNixDaemon, guestproto.OpWriteFiles, guestproto.OpUnlinkPaths:
		resp, _ := json.Marshal(guestproto.Response{ID: req.ID})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, Data: resp})
	case guestproto.OpReadFile:
		var r guestproto.ReadFileReq
		_ = json.Unmarshal(req.V, &r)
		a.mu.Lock()
		data, ok := a.files[r.Path]
		a.mu.Unlock()
		if !ok {
			resp, _ := json.Marshal(guestproto.Response{ID: req.ID, Err: "not found"})
			_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, Data: resp})
			return
		}
		if r.Limit > 0 && int64(len(data)) > r.Limit {
			data = data[:r.Limit]
		}
		resp, _ := json.Marshal(guestproto.Response{ID: req.ID})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, Data: resp})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameFileChunk, Data: data})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameFileEOF})
	case guestproto.OpExecStart:
		var er guestproto.ExecReq
		_ = json.Unmarshal(req.V, &er)
		a.mu.Lock()
		a.execs = append(a.execs, er)
		for _, f := range er.Files {
			a.files[f.Path] = append([]byte(nil), f.Data...)
		}
		a.mu.Unlock()

		resp, _ := json.Marshal(guestproto.Response{ID: req.ID})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, Data: resp})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameStdout, Data: []byte("ok:" + strings.Join(er.Argv, " "))})
		exitBytes, _ := json.Marshal(guestproto.ExecExit{Code: 0})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, Data: exitBytes})
	}
}

func (a *fakeGuestAgent) recordedExecs() []guestproto.ExecReq {
	a.mu.Lock()
	defer a.mu.Unlock()
	return append([]guestproto.ExecReq(nil), a.execs...)
}

func newTestCustomAppMicroVM(t *testing.T, agent *fakeGuestAgent) (*MicroVM, *microvm.MemDriver) {
	t.Helper()
	drv := &microvm.MemDriver{Handler: agent.handle}
	b := &MicroVM{
		Driver:                  drv,
		StateDir:                t.TempDir(),
		KernelPath:              "/k",
		RootfsPath:              "/r",
		TestCustomAppWorkBytes:  2 << 20,
		CustomAppCPUs:           2,
		CustomAppMemoryMB:       512,
		CustomAppMaxVMs:         2,
		CustomAppIdlePauseDelay: 40 * time.Millisecond,
		CustomAppIdleStopTTL:    120 * time.Millisecond,
		PauseSettleDelay:        5 * time.Millisecond,
	}
	t.Cleanup(func() { _ = b.Close() })
	return b, drv
}

func TestCustomAppVMBootIsolationMountsAndPolicy(t *testing.T) {
	agent := newFakeGuestAgent()
	b, drv := newTestCustomAppMicroVM(t, agent)
	ctx := context.Background()

	mountDirA := t.TempDir()
	mountDirB := t.TempDir()
	appID := uuid.New()

	spec := customapps.VMAppSpec{
		AppID:       appID,
		Slug:        "demo-app",
		Mounts:      customapps.Mounts{"docs": mountDirA},
		AllowPublic: false,
	}

	if st := b.AppVMStatus(appID); !st.Available || st.State != customapps.VMStateStopped {
		t.Fatalf("initial status = %+v, want available stopped", st)
	}

	proc, err := b.StartAppVMProcess(ctx, customapps.VMExecRequest{
		App:   spec,
		Argv:  []string{"echo", "hi"},
		Files: []customapps.VMFileWrite{{Path: "/workspace/hello.txt", Data: []byte("world"), Mode: 0o600}},
	})
	if err != nil {
		t.Fatalf("StartProcess: %v", err)
	}
	out, _ := io.ReadAll(proc.Stdout())
	code, err := proc.Wait()
	if err != nil || code != 0 || string(out) != "ok:echo hi" {
		t.Fatalf("exec = code %d err %v out %q", code, err, out)
	}
	if st := b.AppVMStatus(appID); st.State != customapps.VMStateRunning || st.ActiveCalls != 1 || st.MountCount != 1 || st.AllowPublic {
		t.Fatalf("active status = %+v", st)
	}
	if err := proc.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	// Verify VMConfig: NO home.ext4, only rootfs + work.ext4, and RO virtiofs mount.
	cfgs := drv.Configs()
	if len(cfgs) != 1 {
		t.Fatalf("started %d VMs, want 1", len(cfgs))
	}
	for _, d := range cfgs[0].Drives {
		if strings.Contains(d.Path, "home.ext4") {
			t.Fatalf("custom app VM must never attach home.ext4: %+v", cfgs[0].Drives)
		}
	}
	if len(cfgs[0].Shares) != 1 || cfgs[0].Shares[0].Tag != "mount-docs" || !cfgs[0].Shares[0].ReadOnly {
		t.Fatalf("unexpected shares: %+v", cfgs[0].Shares)
	}

	// Verify ReadAppVMFile works against guest.
	data, err := b.ReadAppVMFile(ctx, spec, "/workspace/hello.txt", 1024)
	if err != nil || string(data) != "world" {
		t.Fatalf("ReadAppVMFile = %q, %v", data, err)
	}

	// SyncAppVMPolicy toggling AllowPublic does NOT restart the VM.
	spec.AllowPublic = true
	if err := b.SyncAppVMPolicy(ctx, spec); err != nil {
		t.Fatalf("SyncAppVMPolicy AllowPublic: %v", err)
	}
	if st := b.AppVMStatus(appID); !st.AllowPublic {
		t.Fatalf("expected AllowPublic=true after SyncAppVMPolicy, got %+v", st)
	}
	if len(drv.Configs()) != 1 {
		t.Fatalf("AllowPublic toggle should not reboot VM; boots=%d", len(drv.Configs()))
	}

	// Changing mounts stops the idle VM and reboots with the new shares on next call.
	spec.Mounts = customapps.Mounts{"docs": mountDirA, "extra": mountDirB}
	proc2, err := b.StartAppVMProcess(ctx, customapps.VMExecRequest{
		App:  spec,
		Argv: []string{"true"},
	})
	if err != nil {
		t.Fatalf("StartProcess after mount change: %v", err)
	}
	_, _ = io.Copy(io.Discard, proc2.Stdout())
	_, _ = proc2.Wait()
	_ = proc2.Close()

	cfgs = drv.Configs()
	if len(cfgs) != 2 {
		t.Fatalf("expected reboot on mount change, got %d boots", len(cfgs))
	}
	if len(cfgs[1].Shares) != 2 {
		t.Fatalf("expected 2 shares after mount change, got %+v", cfgs[1].Shares)
	}

	// DeleteAppVM stops the VM and deletes its disk directory.
	dir, _ := b.customAppDir(appID)
	if err := b.DeleteAppVM(ctx, appID); err != nil {
		t.Fatalf("DeleteAppVM: %v", err)
	}
	if st := b.AppVMStatus(appID); st.State != customapps.VMStateStopped {
		t.Fatalf("status after delete = %+v, want stopped", st)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("expected app VM dir %s removed, stat err = %v", dir, err)
	}
}

func TestCustomAppVMIdlePauseResumeStopAndLRUEviction(t *testing.T) {
	agent := newFakeGuestAgent()
	b, _ := newTestCustomAppMicroVM(t, agent)
	ctx := context.Background()

	app1 := customapps.VMAppSpec{AppID: uuid.New(), Slug: "app-1"}
	app2 := customapps.VMAppSpec{AppID: uuid.New(), Slug: "app-2"}
	app3 := customapps.VMAppSpec{AppID: uuid.New(), Slug: "app-3"}

	runOne := func(spec customapps.VMAppSpec) {
		t.Helper()
		p, err := b.StartAppVMProcess(ctx, customapps.VMExecRequest{App: spec, Argv: []string{"true"}})
		if err != nil {
			t.Fatalf("StartProcess(%s): %v", spec.Slug, err)
		}
		_, _ = io.Copy(io.Discard, p.Stdout())
		_, _ = p.Wait()
		_ = p.Close()
	}

	runOne(app1)

	// Wait for idle pause.
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if b.AppVMStatus(app1.AppID).State == customapps.VMStatePaused {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if st := b.AppVMStatus(app1.AppID); st.State != customapps.VMStatePaused {
		t.Fatalf("expected app1 paused after idle delay, got %+v", st)
	}

	// Next call resumes it cleanly.
	runOne(app1)
	if st := b.AppVMStatus(app1.AppID); st.State != customapps.VMStateRunning {
		t.Fatalf("expected app1 running after resume, got %+v", st)
	}

	// Boot app2 (reaches CustomAppMaxVMs=2), then app3 evicts LRU idle app1.
	time.Sleep(5 * time.Millisecond)
	runOne(app2)
	runOne(app3)

	if st := b.AppVMStatus(app1.AppID); st.State != customapps.VMStateStopped {
		t.Fatalf("expected LRU app1 evicted to stopped, got %+v", st)
	}
	if st := b.AppVMStatus(app3.AppID); st.State != customapps.VMStateRunning {
		t.Fatalf("expected app3 running, got %+v", st)
	}

	// Wait for app3 to pause and then stop after IdleStopTTL.
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if b.AppVMStatus(app3.AppID).State == customapps.VMStateStopped {
			break
		}
		time.Sleep(15 * time.Millisecond)
	}
	if st := b.AppVMStatus(app3.AppID); st.State != customapps.VMStateStopped {
		t.Fatalf("expected app3 stopped after IdleStopTTL, got %+v", st)
	}

	// Workspace disk persists after idle stop so restarts stay warm.
	dir3, _ := b.customAppDir(app3.AppID)
	if _, err := os.Stat(filepath.Join(dir3, "work.ext4")); err != nil {
		t.Fatalf("expected work.ext4 preserved after idle stop: %v", err)
	}
}

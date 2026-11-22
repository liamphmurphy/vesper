package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

func TestMicroVMBalloonAndWarmTTL(t *testing.T) {
	drv := &microvm.MemDriver{
		Handler: func(_ context.Context, conn net.Conn) {
			f, err := guestproto.ReadFrame(conn)
			if err != nil {
				return
			}
			var req guestproto.Request
			_ = json.Unmarshal(f.Data, &req)
			switch req.Op {
			case guestproto.OpExecStart:
				resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
				ex, _ := json.Marshal(guestproto.ExecExit{Code: 0})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, ID: f.ID, Data: ex})
			default:
				resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
			}
		},
	}

	b := &MicroVM{
		Driver:             drv,
		StateDir:           t.TempDir(),
		KernelPath:         "/k",
		RootfsPath:         "/r",
		MemoryMB:           1024,
		IdleMemoryMB:       160,
		WarmTTL:            120 * time.Millisecond,
		TestWorkspaceBytes: 2 << 20,
		TestHomeBytes:      2 << 20,
		TestDockerBytes:    2 << 20,
	}
	defer func() { _ = b.Close() }()
	ctx := context.Background()

	runTurn := func() {
		t.Helper()
		p, err := b.Start(ctx, "r1", ExecSpec{Argv: []string{"true"}})
		if err != nil {
			t.Fatal(err)
		}
		go func() { _, _ = io.Copy(io.Discard, p.Stdout()) }()
		go func() { _, _ = io.Copy(io.Discard, p.Stderr()) }()
		if code, werr := p.Wait(); werr != nil || code != 0 {
			t.Fatalf("turn code=%d err=%v", code, werr)
		}
	}

	runTurn()
	if b.ActiveVMCount() != 1 {
		t.Fatalf("expected 1 active VM after first turn, got %d", b.ActiveVMCount())
	}
	b.runsMu.Lock()
	mvm := b.vms["r1"].vm.(*microvm.MemVM)
	b.runsMu.Unlock()
	if got := mvm.MemoryTarget(); got != 160<<20 {
		t.Fatalf("idle balloon target = %d MiB, want 160 MiB", got>>20)
	}

	// Second turn while still warm reuses same VM and restores MemoryMB.
	runTurn()
	if len(drv.Started) != 1 || mvm.MemoryTarget() != 160<<20 {
		t.Fatalf("expected warm reuse (starts=%d target=%d MiB)", len(drv.Started), mvm.MemoryTarget()>>20)
	}

	// Wait past WarmTTL -> VM stops cleanly and ActiveVMCount returns to 0.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && b.ActiveVMCount() != 0 {
		time.Sleep(15 * time.Millisecond)
	}
	if b.ActiveVMCount() != 0 || !mvm.Stopped() {
		t.Fatalf("expected WarmTTL shutdown (active=%d stopped=%v)", b.ActiveVMCount(), mvm.Stopped())
	}

	// Subsequent turn transparently cold-boots a new VM.
	runTurn()
	if len(drv.Started) != 2 || b.ActiveVMCount() != 1 {
		t.Fatalf("expected cold reboot after WarmTTL (starts=%d active=%d)", len(drv.Started), b.ActiveVMCount())
	}
}

func TestMicroVMDeferredCacheDrop(t *testing.T) {
	var drops atomic.Int32
	drv := &microvm.MemDriver{
		Handler: func(_ context.Context, conn net.Conn) {
			f, err := guestproto.ReadFrame(conn)
			if err != nil {
				return
			}
			var req guestproto.Request
			_ = json.Unmarshal(f.Data, &req)
			switch req.Op {
			case guestproto.OpSyncAndDropCaches:
				drops.Add(1)
				resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
			case guestproto.OpExecStart:
				resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
				ex, _ := json.Marshal(guestproto.ExecExit{Code: 0})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, ID: f.ID, Data: ex})
			default:
				resp, _ := json.Marshal(guestproto.Response{ID: f.ID})
				_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: resp})
			}
		},
	}

	b := &MicroVM{
		Driver:             drv,
		StateDir:           t.TempDir(),
		KernelPath:         "/k",
		RootfsPath:         "/r",
		MemoryMB:           1024,
		IdleMemoryMB:       160,
		WarmTTL:            2 * time.Second,
		CacheDropDelay:     120 * time.Millisecond,
		TestWorkspaceBytes: 2 << 20,
		TestHomeBytes:      2 << 20,
		TestDockerBytes:    2 << 20,
	}
	defer func() { _ = b.Close() }()
	ctx := context.Background()

	runTurn := func() {
		t.Helper()
		p, err := b.Start(ctx, "r1", ExecSpec{Argv: []string{"true"}})
		if err != nil {
			t.Fatal(err)
		}
		go func() { _, _ = io.Copy(io.Discard, p.Stdout()) }()
		go func() { _, _ = io.Copy(io.Discard, p.Stderr()) }()
		if code, werr := p.Wait(); werr != nil || code != 0 {
			t.Fatalf("turn code=%d err=%v", code, werr)
		}
	}

	runTurn()
	b.runsMu.Lock()
	mvm := b.vms["r1"].vm.(*microvm.MemVM)
	b.runsMu.Unlock()
	// Immediately after the turn, cache and full memory stay warm.
	if drops.Load() != 0 {
		t.Fatalf("cache dropped immediately (%d), want deferred", drops.Load())
	}
	if got := mvm.MemoryTarget(); got == 160<<20 {
		t.Fatalf("memory deflated immediately (%d MiB), want deferred", got>>20)
	}

	// A rapid follow-up turn cancels the pending drop timer.
	time.Sleep(40 * time.Millisecond)
	runTurn()
	if drops.Load() != 0 {
		t.Fatalf("cache dropped during rapid follow-up (%d), want 0", drops.Load())
	}

	// After staying idle past CacheDropDelay, cache drops and balloon deflates.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && (drops.Load() == 0 || mvm.MemoryTarget() != 160<<20) {
		time.Sleep(15 * time.Millisecond)
	}
	if drops.Load() != 1 || mvm.MemoryTarget() != 160<<20 {
		t.Fatalf("expected deferred drop+deflate (drops=%d target=%d MiB)", drops.Load(), mvm.MemoryTarget()>>20)
	}
}

func vzHelperRSSKiB() int64 {
	out, err := exec.Command("ps", "-axo", "rss,comm").Output()
	if err != nil {
		return 0
	}
	var sum int64
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		comm := strings.Join(fields[1:], " ")
		if strings.Contains(comm, "Virtualization.VirtualMachine") {
			v, _ := strconv.ParseInt(fields[0], 10, 64)
			sum += v
		}
	}
	return sum
}

func TestVZConcurrentRunsAndMemoryReclaim(t *testing.T) {
	kernel, rootfs := requireRunnerVZImages(t)
	ctx := context.Background()

	baseRSS := vzHelperRSSKiB()
	t.Logf("VZ_RSS_BASELINE helper_kib=%d", baseRSS)

	for _, count := range []int{1, 4, 8} {
		stateDir := t.TempDir()
		b := &MicroVM{
			Driver:             microvm.NewVZDriver(),
			StateDir:           stateDir,
			KernelPath:         kernel,
			RootfsPath:         rootfs,
			CPUs:               2,
			MemoryMB:           512,
			IdleMemoryMB:       128,
			PidsLimit:          256,
			WarmTTL:            400 * time.Millisecond,
			TestWorkspaceBytes: 64 << 20,
			TestHomeBytes:      32 << 20,
			TestDockerBytes:    32 << 20,
		}

		// Pre-create templates cleanly so template build doesn't skew concurrent boot timings.
		if err := b.EnsureWorkspace(ctx, "pre"); err != nil {
			t.Fatal(err)
		}
		_ = b.RemoveWorkspace(ctx, "pre")

		bootStart := time.Now()
		readyCh := make(chan int, count)
		var wg sync.WaitGroup
		errs := make(chan error, count)
		for i := 0; i < count; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				sentReady := false
				sendReady := func() {
					if !sentReady {
						sentReady = true
						readyCh <- idx
					}
				}
				defer sendReady()
				id := fmt.Sprintf("run-%d", idx)
				// Touch 48 MiB page cache inside guest, signal READY, and stay resident briefly
				// so peak simultaneous multi-VM RSS is measured while all N VMs hold memory.
				script := fmt.Sprintf(`set -e
dd if=/dev/zero of=/tmp/cachefill bs=1M count=48 status=none
echo "ws-%d" > /workspace/state.txt
mkdir -p /home/node/.cache
echo "home-%d" > /home/node/.cache/state.txt
echo READY
sleep 0.4
`, idx, idx)
				p, err := b.Start(ctx, id, ExecSpec{Argv: []string{"/bin/sh", "-c", script}})
				if err != nil {
					errs <- fmt.Errorf("%s start: %w", id, err)
					return
				}
				var outB, errB bytes.Buffer
				var swg sync.WaitGroup
				swg.Add(2)
				go func() {
					defer swg.Done()
					buf := make([]byte, 4096)
					for {
						nr, rerr := p.Stdout().Read(buf)
						if nr > 0 {
							outB.Write(buf[:nr])
							if strings.Contains(outB.String(), "READY") {
								sendReady()
							}
						}
						if rerr != nil {
							return
						}
					}
				}()
				go func() { defer swg.Done(); _, _ = io.Copy(&errB, p.Stderr()) }()
				swg.Wait()
				code, werr := p.Wait()
				if werr != nil || code != 0 {
					errs <- fmt.Errorf("%s wait code=%d err=%v out=%q stderr=%q", id, code, werr, outB.String(), errB.String())
				}
			}(i)
		}
		for i := 0; i < count; i++ {
			<-readyCh
		}
		peakRSS := vzHelperRSSKiB()
		wg.Wait()
		close(errs)
		for err := range errs {
			if err != nil {
				_ = b.Cleanup(ctx)
				t.Fatal(err)
			}
		}
		bootAllDur := time.Since(bootStart)
		time.Sleep(150 * time.Millisecond)
		balloonedRSS := vzHelperRSSKiB()

		// Wait for WarmTTL shutdown to tear down all idle VMs while retaining ext4 disks.
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) && b.ActiveVMCount() != 0 {
			time.Sleep(25 * time.Millisecond)
		}
		if b.ActiveVMCount() != 0 {
			_ = b.Cleanup(ctx)
			t.Fatalf("%d-VM WarmTTL left %d active VMs", count, b.ActiveVMCount())
		}
		time.Sleep(200 * time.Millisecond)
		stoppedRSS := vzHelperRSSKiB()

		// Cold-boot resume run-0 and confirm both /workspace and /home/node persisted across WarmTTL shutdown.
		p, err := b.Start(ctx, "run-0", ExecSpec{
			Argv: []string{"/bin/sh", "-c", "cat /workspace/state.txt && cat /home/node/.cache/state.txt"},
		})
		if err != nil {
			_ = b.Cleanup(ctx)
			t.Fatalf("resume run-0: %v", err)
		}
		var outB bytes.Buffer
		var rwg sync.WaitGroup
		rwg.Add(2)
		go func() { defer rwg.Done(); _, _ = io.Copy(&outB, p.Stdout()) }()
		go func() { defer rwg.Done(); _, _ = io.Copy(io.Discard, p.Stderr()) }()
		rwg.Wait()
		if code, werr := p.Wait(); werr != nil || code != 0 {
			_ = b.Cleanup(ctx)
			t.Fatalf("resume wait code=%d err=%v", code, werr)
		}
		if !strings.Contains(outB.String(), "ws-0") || !strings.Contains(outB.String(), "home-0") {
			_ = b.Cleanup(ctx)
			t.Fatalf("state lost across WarmTTL cold resume: %q", outB.String())
		}
		_ = b.Cleanup(ctx)

		t.Logf("VZ_CONCURRENCY n=%d elapsed=%v peak_kib=%d ballooned_kib=%d stopped_kib=%d",
			count, bootAllDur, peakRSS, balloonedRSS, stoppedRSS)
	}
}

package microvm

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

func TestMemDriverLifecycle(t *testing.T) {
	d := &MemDriver{}
	vm, err := d.Start(context.Background(), VMConfig{
		KernelPath:  "/tmp/k",
		MemoryBytes: 1024 << 20,
		Drives:      []DriveSpec{{Path: "/tmp/root.erofs", ReadOnly: true}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := vm.SetMemoryTarget(512 << 20); err != nil {
		t.Fatal(err)
	}
	if got := vm.(*MemVM).MemoryTarget(); got != 512<<20 {
		t.Fatalf("target = %d", got)
	}
	if err := vm.Stop(context.Background()); err != nil {
		t.Fatal(err)
	}
	if !vm.(*MemVM).Stopped() {
		t.Fatal("expected MemVM to be stopped")
	}
}

// TestVZBootAndExec boots a real Linux arm64 microVM under Apple
// Virtualization.framework (Code-Hex/vz) when kernel & rootfs images are built
// (or fails loudly when VESPER_REQUIRE_VZ_TESTS=1).
func TestVZBootAndExec(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Fatal(err)
	}
	imgDir := os.Getenv("VESPER_IMAGES_DIR")
	if imgDir == "" {
		imgDir = filepath.Join(home, ".cache", "vesper", "images")
	}
	kernel := filepath.Join(imgDir, "vmlinux")
	rootfs := filepath.Join(imgDir, "agent-base.erofs")
	req := os.Getenv("VESPER_REQUIRE_VZ_TESTS") == "1"
	if !req && !hasVZEntitlement() {
		t.Skip("binary lacks com.apple.security.virtualization entitlement (run with -exec ../scripts/vz-test-exec.sh or VESPER_REQUIRE_VZ_TESTS=1)")
	}
	for _, p := range []string{kernel, rootfs} {
		if _, err := os.Stat(p); err != nil {
			if req {
				t.Fatalf("required image missing: %s (%v)", p, err)
			}
			t.Skipf("microvm image missing (%s); set VESPER_REQUIRE_VZ_TESTS=1 after running deploy/microvm/build-images.sh", p)
		}
	}

	wsDisk := filepath.Join(t.TempDir(), "ws.ext4")
	makeExt4Image(t, wsDisk, "vesper-ws", 64<<20)

	drv := NewVZDriver()
	t0 := time.Now()
	vm, err := drv.Start(context.Background(), VMConfig{
		KernelPath:  kernel,
		CPUs:        2,
		MemoryBytes: 512 << 20,
		Drives: []DriveSpec{
			{Path: rootfs, ReadOnly: true},
			{Path: wsDisk, ReadOnly: false},
		},
	})
	if err != nil {
		t.Fatalf("boot failed: %v", err)
	}
	bootDur := time.Since(t0)
	defer func() { _ = vm.Stop(context.Background()) }()

	execOnce := func(cmd string) (int, string, string, time.Duration) {
		t.Helper()
		s0 := time.Now()
		proc, err := vm.Client().StartExec(context.Background(), guestproto.ExecReq{
			Argv: []string{"/bin/sh", "-c", cmd},
			Dir:  "/workspace",
		})
		if err != nil {
			t.Fatalf("StartExec %q: %v", cmd, err)
		}
		var outB, errB bytes.Buffer
		var wg sync.WaitGroup
		wg.Add(2)
		go func() { defer wg.Done(); _, _ = io.Copy(&outB, proc.Stdout()) }()
		go func() { defer wg.Done(); _, _ = io.Copy(&errB, proc.Stderr()) }()
		wg.Wait()
		ex, err := proc.Wait()
		if err != nil {
			t.Fatalf("Wait %q: %v", cmd, err)
		}
		return ex.Code, outB.String(), errB.String(), time.Since(s0)
	}

	code, out, stderr, execDur := execOnce("uname -srm && touch /root-ovl-ok && echo persisted > /workspace/proof && cat /sys/fs/cgroup/cgroup.controllers && ls /sys/class/net")
	if code != 0 {
		t.Fatalf("probe failed code=%d out=%q err=%q console=%q", code, out, stderr, vm.ConsoleOutput())
	}
	if !strings.Contains(out, "Linux") || !strings.Contains(out, "aarch64") {
		t.Fatalf("unexpected uname: %q", out)
	}
	if !strings.Contains(out, "memory") || !strings.Contains(out, "pids") {
		t.Fatalf("missing cgroup v2 controllers: %q", out)
	}
	// NIC-less VM: only loopback interface should exist in Slice 1.
	for _, line := range strings.Fields(out) {
		if strings.HasPrefix(line, "eth") || strings.HasPrefix(line, "en") {
			t.Fatalf("unexpected network interface %q in NIC-less VM: %q", line, out)
		}
	}

	// Builds (nix's patchelf hook, any bash script) use process substitution,
	// which needs the /dev/fd links udev would make on a normal system.
	code, out, stderr, _ = execOnce(`test -L /dev/fd && test -e /dev/stdin && test -e /dev/stdout && test -e /dev/stderr && bash -c 'cat <(echo procsub-ok)'`)
	if code != 0 || !strings.Contains(out, "procsub-ok") {
		t.Fatalf("/dev/fd links missing: code=%d out=%q err=%q", code, out, stderr)
	}

	var execDurs []time.Duration
	for i := 0; i < 5; i++ {
		c, _, _, d := execOnce("true")
		if c != 0 {
			t.Fatalf("warm exec exit %d", c)
		}
		execDurs = append(execDurs, d)
	}
	t.Logf("VZ_BENCHMARK boot=%v first_exec=%v warm_execs=%v", bootDur, execDur, execDurs)

	if err := vm.Stop(context.Background()); err != nil {
		t.Fatalf("stop: %v", err)
	}

	// Reboot onto same wsDisk to prove /workspace persistence across VM restarts.
	vm2, err := drv.Start(context.Background(), VMConfig{
		KernelPath:  kernel,
		CPUs:        2,
		MemoryBytes: 512 << 20,
		Drives: []DriveSpec{
			{Path: rootfs, ReadOnly: true},
			{Path: wsDisk, ReadOnly: false},
		},
	})
	if err != nil {
		t.Fatalf("second boot failed: %v", err)
	}
	defer func() { _ = vm2.Stop(context.Background()) }()

	b, err := vm2.Client().ReadFile(context.Background(), "/workspace/proof", 1024)
	if err != nil || strings.TrimSpace(string(b)) != "persisted" {
		t.Fatalf("workspace persistence check failed: data=%q err=%v", b, err)
	}
}

func makeExt4Image(t *testing.T, path, label string, size int64) {
	t.Helper()
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.Truncate(size); err != nil {
		f.Close()
		t.Fatal(err)
	}
	f.Close()

	for _, tool := range []string{"mke2fs", "mkfs.ext4"} {
		if bin, err := exec.LookPath(tool); err == nil {
			out, err := exec.Command(bin, "-t", "ext4", "-L", label, "-F", "-q", path).CombinedOutput()
			if err != nil {
				t.Fatalf("%s failed: %v\n%s", tool, err, out)
			}
			return
		}
	}
	// Try Android SDK mke2fs if not on PATH, else format inside tiny alpine container?
	// We know mke2fs on macOS is at ~/Library/Android/sdk/platform-tools/mke2fs or brew e2fsprogs.
	home, _ := os.UserHomeDir()
	androidMke2fs := filepath.Join(home, "Library/Android/sdk/platform-tools/mke2fs")
	if _, err := os.Stat(androidMke2fs); err == nil {
		out, err := exec.Command(androidMke2fs, "-t", "ext4", "-L", label, "-F", "-q", path).CombinedOutput()
		if err != nil {
			t.Fatalf("mke2fs failed: %v\n%s", err, out)
		}
		return
	}
	t.Fatalf("no mke2fs/mkfs.ext4 found on host for test %s", fmt.Sprintf("%s", path))
}

func hasVZEntitlement() bool {
	exe, err := os.Executable()
	if err != nil {
		return false
	}
	out, err := exec.Command("codesign", "-d", "--entitlements", "-", exe).CombinedOutput()
	if err != nil {
		return false
	}
	return strings.Contains(string(out), "com.apple.security.virtualization")
}

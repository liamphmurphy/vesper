package microvm

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

func requireVZImages(t *testing.T) (kernel, rootfs string) {
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
	if !req && !hasVZEntitlement() {
		t.Skip("binary lacks com.apple.security.virtualization entitlement (run with -exec ../scripts/vz-test-exec.sh or VESPER_REQUIRE_VZ_TESTS=1)")
	}
	for _, p := range []string{kernel, rootfs} {
		if _, err := os.Stat(p); err != nil {
			if req {
				t.Fatalf("required image missing: %s (%v)", p, err)
			}
			t.Skipf("microvm image missing (%s)", p)
		}
	}
	return kernel, rootfs
}

func TestVZEgressEndToEnd(t *testing.T) {
	kernel, rootfs := requireVZImages(t)
	wsDisk := filepath.Join(t.TempDir(), "ws.ext4")
	makeExt4Image(t, wsDisk, "vesper-ws", 64<<20)

	// Host-only secret HTTP server bound on 127.0.0.1; VM must NOT reach it.
	var hostHit atomic.Bool
	hostOnly := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hostHit.Store(true)
		_, _ = io.WriteString(w, "host-leaked")
	}))
	defer hostOnly.Close()

	// Internal API handler (api.vesper.internal)
	apiMux := http.NewServeMux()
	apiMux.HandleFunc("/mcp", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "mcp-ok")
	})
	apiMux.HandleFunc("/internal/admin", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "admin-leaked")
	})

	// Mock HTTPS server reached via synthetic DNS + NAT + TLS SNI verification.
	tlsSrv := newSelfSignedHTTPSServer(t, "allowed.example", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "tls-ok")
	}))
	defer tlsSrv.Close()

	// Mock HTTP server reached via synthetic DNS for 128 MiB throughput test.
	streamSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, "uploaded")
	}))
	defer streamSrv.Close()

	eg := NewEgress(EgressConfig{
		APIHandler: apiMux,
		Resolver: func(_ context.Context, host string) ([]net.IP, error) {
			if host == "blocked.internal" {
				return []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("169.254.169.254")}, nil
			}
			return nil, fmt.Errorf("unknown test host %q", host)
		},
		TestUpstreams: map[string]string{
			"allowed.example":    strings.TrimPrefix(tlsSrv.URL, "https://"),
			"throughput.example": strings.TrimPrefix(streamSrv.URL, "http://"),
		},
	})
	defer eg.Close()

	drv := NewVZDriver()
	vm, err := drv.Start(context.Background(), VMConfig{
		KernelPath:  kernel,
		CPUs:        2,
		MemoryBytes: 512 << 20,
		Drives: []DriveSpec{
			{Path: rootfs, ReadOnly: true},
			{Path: wsDisk, ReadOnly: false},
		},
		Listeners: eg.Listeners(),
	})
	if err != nil {
		t.Fatalf("boot failed: %v", err)
	}
	defer func() { _ = vm.Stop(context.Background()) }()

	runSh := func(script string) (int, string, string) {
		t.Helper()
		proc, err := vm.Client().StartExec(context.Background(), guestproto.ExecReq{
			Argv: []string{"/bin/sh", "-c", script},
			Dir:  "/workspace",
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
		ex, err := proc.Wait()
		if err != nil {
			t.Fatal(err)
		}
		return ex.Code, outB.String(), errB.String()
	}

	hostPort := strings.TrimPrefix(hostOnly.URL, "http://127.0.0.1:")
	probeScript := fmt.Sprintf(`
set -e
mcp=$(curl -fsS http://api.vesper.internal/mcp)
[ "$mcp" = "mcp-ok" ]
admin_code=$(curl -s -o /dev/null -w '%%{http_code}' http://api.vesper.internal/internal/admin)
[ "$admin_code" = "404" ]
tls=$(curl -fsSk https://allowed.example/)
[ "$tls" = "tls-ok" ]
! curl -fsS --max-time 2 http://127.0.0.1:%s/
! curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/
! curl -fsS --max-time 2 http://100.100.100.100/
! curl -fsS --max-time 2 http://blocked.internal/
echo "ALL_EGRESS_CHECKS_PASSED"
`, hostPort)

	code, out, stderr := runSh(probeScript)
	if code != 0 || !strings.Contains(out, "ALL_EGRESS_CHECKS_PASSED") {
		t.Fatalf("egress checks failed code=%d out=%q err=%q console=%q", code, out, stderr, vm.ConsoleOutput())
	}
	if hostHit.Load() {
		t.Fatal("VM reached host-only 127.0.0.1 HTTP server!")
	}

	// Measure 128 MiB guest -> host HTTP throughput through transparent NAT + vsock egress.
	t0 := time.Now()
	code, out, stderr = runSh(`head -c 134217728 /dev/zero | curl -fsS -T - http://throughput.example/upload`)
	dt := time.Since(t0)
	if code != 0 || strings.TrimSpace(out) != "uploaded" {
		t.Fatalf("throughput test failed code=%d out=%q err=%q", code, out, stderr)
	}
	mibPerSec := 128.0 / dt.Seconds()
	mbps := (128.0 * 8.0) / dt.Seconds()
	t.Logf("VZ_EGRESS_THROUGHPUT 128MiB duration=%v speed=%.1f MiB/s (%.1f Mbps)", dt, mibPerSec, mbps)
}

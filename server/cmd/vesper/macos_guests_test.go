package main

import (
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

func TestMacOSGuestsNeedAGoldenImage(t *testing.T) {
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	vmDir := t.TempDir()
	cfg := config.MacOSGuests{MaxVMs: 2, IdleTTL: time.Minute, CPUs: 4, MemoryMB: 8192, User: "admin"}

	if g := macOSGuests(log, cfg, vmDir, &microvm.MemDriver{}); g != nil {
		t.Fatal("on without a golden image")
	}

	golden := filepath.Join(vmDir, macOSGoldenDir)
	if err := os.MkdirAll(golden, 0o755); err != nil {
		t.Fatal(err)
	}
	for name, data := range map[string]string{
		microvm.MacOSDiskFile:   "disk",
		microvm.MacOSAuxFile:    "nvram",
		microvm.MacOSConfigFile: `{"os":"darwin","arch":"arm64","hardwareModel":"aHc="}`,
	} {
		if err := os.WriteFile(filepath.Join(golden, name), []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	g := macOSGuests(log, cfg, vmDir, &microvm.MemDriver{})
	if g == nil || g.StateDir != vmDir || g.Image.Dir != golden {
		t.Fatalf("with an image: %+v", g)
	}

	cfg.MaxVMs = 0
	if g := macOSGuests(log, cfg, vmDir, &microvm.MemDriver{}); g != nil {
		t.Fatal("on with RUNNER_MACOS_VMS=0")
	}
}

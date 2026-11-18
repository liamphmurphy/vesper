package main

import (
	"log/slog"
	"path/filepath"

	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// macOSGoldenDir is where the golden image lives in a VM directory unless
// RUNNER_MACOS_IMAGE_DIR says otherwise (deploy/microvm/macos-golden.sh).
const macOSGoldenDir = "macos-golden"

// macOSGuests returns the broker behind `mac`, or nil when macOS guests are
// off: RUNNER_MACOS_VMS=0, or no usable golden image.
func macOSGuests(log *slog.Logger, cfg config.MacOSGuests, vmDir string, drv microvm.Driver) *runner.MacOSGuests {
	if cfg.MaxVMs == 0 {
		return nil
	}
	dir := cfg.ImageDir
	if dir == "" {
		dir = filepath.Join(vmDir, macOSGoldenDir)
	}
	img, err := microvm.LoadMacOSImage(dir)
	if err != nil {
		if microvm.IsMacOSImageMissing(err) {
			log.Info("macOS guests off: no golden image", "dir", dir)
		} else {
			log.Warn("macOS guests off: golden image unusable", "err", err)
		}
		return nil
	}
	log.Info("macOS guests on", "image", dir, "max_vms", cfg.MaxVMs)
	return &runner.MacOSGuests{
		Driver:   drv,
		Image:    img,
		StateDir: vmDir,
		MaxVMs:   cfg.MaxVMs,
		IdleTTL:  cfg.IdleTTL,
		CPUs:     cfg.CPUs,
		MemoryMB: cfg.MemoryMB,
		User:     cfg.User,
		Log:      log,
	}
}

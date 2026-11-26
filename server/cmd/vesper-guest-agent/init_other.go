//go:build !linux && !darwin

package main

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
)

const openNoFollowFlag = 0

func openFileNoFollowUnderRoot(rootDir, rel string, mode os.FileMode, uid, gid int) (*os.File, error) {
	root, err := os.OpenRoot(rootDir)
	if err != nil {
		return nil, err
	}
	defer root.Close()
	if dir := filepath.Dir(rel); dir != "." && dir != "" {
		if err := root.MkdirAll(dir, 0o755); err != nil {
			return nil, err
		}
	}
	return root.OpenFile(rel, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, mode)
}

func bootstrapPID1() error { return nil }

func startOrphanReaper(context.Context, *execTracker) {}

func listenVSock(uint32) (net.Listener, error) {
	return nil, errors.New("AF_VSOCK listener is only supported on Linux")
}

func notifyHostReady(*slog.Logger) {}

func syncAndDropCaches() error { return nil }

func powerOffGuest() {}

func setupGuestNetworking(*slog.Logger, *dnsStubConfig) error { return nil }

func checkLocalTCPPort(uint16) bool { return false }

func applyCgroupLimits(string, int64, int64) (string, error) { return "", nil }

func addPidToCgroup(string, int) error { return nil }

func killAndCheckOOM(string) bool { return false }

func setupChildSysProcAttr(*exec.Cmd, int, int, bool) {}

func startPTY(*exec.Cmd, uint16, uint16) (*os.File, error) {
	return nil, errors.New("PTY is only implemented on Linux guest agent")
}

func resizePTY(*os.File, uint16, uint16) error { return nil }

func signalProcessGroup(*exec.Cmd, uint32) error { return nil }

func ensureDockerd(context.Context, *slog.Logger, *execTracker, string) error {
	return errors.New("dockerd is only supported inside Linux guest VM")
}

func openDockerGuard(string) (string, error) {
	return "", errors.New("dockerd is only supported inside Linux guest VM")
}

func closeDockerGuard(context.Context, string) error { return nil }

func ensureNixDaemon(context.Context, *execTracker) error {
	return errors.New("nix-daemon is only supported inside Linux guest VM")
}

// quiet unused import lint on non-linux builds
var _ = io.Discard

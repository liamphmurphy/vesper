//go:build linux

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"sync"
	"time"
)

const (
	nixDaemonSock = "/nix/var/nix/daemon-socket/socket"
	nixDaemonBin  = "/nix/var/nix/profiles/default/bin/nix-daemon"
)

var nixMu sync.Mutex

// ensureNixDaemon starts nix-daemon as root if its socket is not accepting
// connections. It reads /etc/nix/nix.conf at start.
func ensureNixDaemon(ctx context.Context, execs *execTracker) error {
	nixMu.Lock()
	defer nixMu.Unlock()

	if pingUnixSocketExists(nixDaemonSock) {
		return nil
	}
	cmd := exec.Command(nixDaemonBin)
	if out, _ := os.OpenFile("/var/log/nix-daemon.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); out != nil {
		cmd.Stdout = out
		cmd.Stderr = out
	}
	if err := startTrackedChild(execs, cmd); err != nil {
		return fmt.Errorf("start nix-daemon: %w", err)
	}
	if err := waitForFile(ctx, nixDaemonSock, 10*time.Second); err != nil {
		logTail, _ := os.ReadFile("/var/log/nix-daemon.log")
		return fmt.Errorf("nix-daemon socket: %w: %s", err, logTail)
	}
	return nil
}

//go:build darwin

package main

// The macOS guest agent runs as a LaunchDaemon in a macOS guest VM that only
// builds and tests (`mac` in the Linux run VM). launchd owns PID 1, so there
// is no init work, cgroups, guest networking (the VM has no NIC), Docker or
// Nix here: a process group is the unit of cleanup.

import (
	"context"
	"errors"
	"log/slog"
	"os"
	"os/exec"
	"syscall"

	"golang.org/x/sys/unix"
)

const openNoFollowFlag = syscall.O_NOFOLLOW

func bootstrapPID1() error { return nil }

func startOrphanReaper(context.Context, *execTracker) {}

func syncAndDropCaches() error {
	unix.Sync()
	return nil
}

func powerOffGuest() {
	unix.Sync()
	_ = exec.Command("/sbin/shutdown", "-h", "now").Run()
}

func setupGuestNetworking(*slog.Logger, *dnsStubConfig) error { return nil }

func checkLocalTCPPort(uint16) bool { return false }

func applyCgroupLimits(string, int64, int64) (string, error) { return "", nil }

func addPidToCgroup(string, int) error { return nil }

func killAndCheckOOM(string) bool { return false }

func setupChildSysProcAttr(cmd *exec.Cmd, uid, gid int, useTTY bool) {
	attr := &syscall.SysProcAttr{
		Setsid:  useTTY,
		Setpgid: !useTTY,
	}
	if uid > 0 || gid > 0 {
		attr.Credential = &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}
	}
	cmd.SysProcAttr = attr
}

func signalProcessGroup(cmd *exec.Cmd, sig uint32) error {
	if cmd == nil || cmd.Process == nil || sig == 0 {
		return nil
	}
	return unix.Kill(-cmd.Process.Pid, unix.Signal(sig))
}

func startPTY(*exec.Cmd, uint16, uint16) (*os.File, error) {
	return nil, errors.New("PTY is only implemented on the Linux guest agent")
}

func resizePTY(*os.File, uint16, uint16) error { return nil }

func ensureDockerd(context.Context, *slog.Logger, *execTracker, string) error {
	return errors.New("dockerd isn't available in the macOS guest")
}

func openDockerGuard(string) (string, error) {
	return "", errors.New("dockerd isn't available in the macOS guest")
}

func closeDockerGuard(context.Context, string) error { return nil }

func ensureNixDaemon(context.Context, *execTracker) error {
	return errors.New("nix-daemon isn't available in the macOS guest")
}

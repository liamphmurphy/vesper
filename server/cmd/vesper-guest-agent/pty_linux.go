//go:build linux

package main

import (
	"fmt"
	"os"
	"os/exec"

	"golang.org/x/sys/unix"
)

func startPTY(cmd *exec.Cmd, rows, cols uint16) (*os.File, error) {
	ptmx, err := unix.Open("/dev/ptmx", unix.O_RDWR|unix.O_NOCTTY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("open /dev/ptmx: %w", err)
	}
	master := os.NewFile(uintptr(ptmx), "ptmx")

	if err := unix.IoctlSetPointerInt(ptmx, unix.TIOCSPTLCK, 0); err != nil {
		_ = master.Close()
		return nil, fmt.Errorf("unlock ptmx: %w", err)
	}
	ptyNo, err := unix.IoctlGetInt(ptmx, unix.TIOCGPTN)
	if err != nil {
		_ = master.Close()
		return nil, fmt.Errorf("tiocgptn: %w", err)
	}
	ptsPath := fmt.Sprintf("/dev/pts/%d", ptyNo)
	slave, err := os.OpenFile(ptsPath, os.O_RDWR, 0)
	if err != nil {
		_ = master.Close()
		return nil, fmt.Errorf("open %s: %w", ptsPath, err)
	}
	defer slave.Close()

	if rows > 0 && cols > 0 {
		_ = resizePTY(master, rows, cols)
	}

	cmd.Stdin = slave
	cmd.Stdout = slave
	cmd.Stderr = slave
	if cmd.SysProcAttr != nil {
		cmd.SysProcAttr.Setctty = true
		cmd.SysProcAttr.Ctty = 0
	}
	if err := cmd.Start(); err != nil {
		_ = master.Close()
		return nil, err
	}
	return master, nil
}

func resizePTY(master *os.File, rows, cols uint16) error {
	if master == nil {
		return nil
	}
	ws := &unix.Winsize{Row: rows, Col: cols}
	return unix.IoctlSetWinsize(int(master.Fd()), unix.TIOCSWINSZ, ws)
}

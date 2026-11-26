//go:build linux

package main

import (
	"testing"

	"golang.org/x/sys/unix"
)

func TestDiskMountFlagsBlockSetuidOnTurnWritableDisks(t *testing.T) {
	for _, target := range []string{"/workspace", "/home/node", "/nix"} {
		if got := diskMountFlags(target); got&(unix.MS_NOSUID|unix.MS_NODEV) != unix.MS_NOSUID|unix.MS_NODEV {
			t.Errorf("diskMountFlags(%q) = %#x; want nosuid and nodev", target, got)
		}
	}
	// dockerd's data root holds image layers with setuid binaries containers need.
	if got := diskMountFlags("/var/lib/docker"); got&unix.MS_NOSUID != 0 {
		t.Errorf("diskMountFlags(/var/lib/docker) = %#x; want suid allowed", got)
	}
}

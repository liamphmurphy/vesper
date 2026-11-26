//go:build linux

package main

import (
	"errors"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// A turn runs as uid 1000 in the same guest as the root-run agent. Through
// vsock loopback it could otherwise connect to the agent's RPC port and run
// commands as root, so every guest listener must serve the host (CID 2) only.
func TestListenVSockRefusesGuestPeers(t *testing.T) {
	const port = 47_123
	ln, err := listenVSock(port)
	if err != nil {
		t.Skipf("no AF_VSOCK here: %v", err)
	}
	defer ln.Close()

	accepted := make(chan error, 1)
	go func() {
		c, err := ln.Accept()
		if err == nil {
			c.Close()
		}
		accepted <- err
	}()

	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Skipf("no AF_VSOCK here: %v", err)
	}
	defer unix.Close(fd)
	if err := unix.Connect(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_LOCAL, Port: port}); err != nil {
		if errors.Is(err, unix.ENODEV) || errors.Is(err, unix.EAFNOSUPPORT) || errors.Is(err, unix.ENETUNREACH) {
			t.Skipf("no vsock loopback here: %v", err)
		}
		// Refused before Accept: nothing in the guest reached the listener.
		return
	}

	select {
	case err := <-accepted:
		t.Fatalf("listener served a guest (CID %d) connection; want only the host's (accept err: %v)", unix.VMADDR_CID_LOCAL, err)
	case <-time.After(500 * time.Millisecond):
	}
}

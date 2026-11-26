//go:build linux

package main

import (
	"log/slog"
	"net"
	"syscall"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"golang.org/x/sys/unix"
)

func newVSockSocket() (int, error) {
	return unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK, 0)
}

func acceptVSock(fd int) (int, unix.Sockaddr, error) {
	return unix.Accept4(fd, unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK)
}

// listenVSock serves only the host: turns run in this guest as uid 1000 and
// must not reach the root-run agent (RPC, Docker, playground) through vsock
// loopback or the guest's own CID.
func listenVSock(port uint32) (net.Listener, error) {
	ln, err := bindVSock(port)
	if err != nil {
		return nil, err
	}
	ln.hostOnly = true
	return ln, nil
}

func notifyHostReady(log *slog.Logger) {
	for i := 0; i < 50; i++ {
		fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, 0)
		if err != nil {
			time.Sleep(10 * time.Millisecond)
			continue
		}
		err = unix.Connect(fd, &unix.SockaddrVM{CID: 2, Port: guestproto.PortReady})
		if err == nil {
			_, _ = unix.Write(fd, []byte("ready\n"))
			_ = unix.Close(fd)
			return
		}
		_ = unix.Close(fd)
		if err != syscall.ECONNRESET && err != syscall.ECONNREFUSED && err != syscall.ETIMEDOUT {
			log.Debug("vsock ready connect", "err", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

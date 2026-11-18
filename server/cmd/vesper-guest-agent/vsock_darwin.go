//go:build darwin

package main

import (
	"log/slog"
	"net"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"golang.org/x/sys/unix"
)

func newVSockSocket() (int, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
	if err != nil {
		return -1, err
	}
	unix.CloseOnExec(fd)
	if err := unix.SetNonblock(fd, true); err != nil {
		_ = unix.Close(fd)
		return -1, err
	}
	return fd, nil
}

// acceptVSock is accept(2) plus the flags Darwin has no accept4 for. A
// connection is set non-blocking so the runtime poller serves its reads.
func acceptVSock(fd int) (int, unix.Sockaddr, error) {
	nfd, sa, err := unix.Accept(fd)
	if err != nil {
		return -1, nil, err
	}
	unix.CloseOnExec(nfd)
	if err := unix.SetNonblock(nfd, true); err != nil {
		_ = unix.Close(nfd)
		return -1, nil, err
	}
	return nfd, sa, nil
}

// listenVSock serves only the host: the macOS guest runs a person's build
// commands, which must not reach the root-run agent through vsock loopback.
func listenVSock(port uint32) (net.Listener, error) {
	ln, err := bindVSock(port)
	if err != nil {
		return nil, err
	}
	ln.hostOnly = true
	return ln, nil
}

// notifyHostReady tells the host that PortRPC is listening. launchd may start
// the agent before the vsock device is up, so it retries for a while.
func notifyHostReady(log *slog.Logger) {
	for i := 0; i < 600; i++ {
		fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM, 0)
		if err == nil {
			err = unix.Connect(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_HOST, Port: guestproto.PortReady})
			if err == nil {
				_, _ = unix.Write(fd, []byte("ready\n"))
				_ = unix.Close(fd)
				return
			}
			_ = unix.Close(fd)
		}
		if i%100 == 0 {
			log.Debug("vsock ready connect", "err", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

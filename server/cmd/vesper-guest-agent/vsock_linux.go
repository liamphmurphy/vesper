//go:build linux

package main

import (
	"log/slog"
	"net"
	"os"
	"syscall"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"golang.org/x/sys/unix"
)

type vsockListener struct {
	fd   int
	file *os.File
	port uint32
}

type vsockAddr struct {
	cid  uint32
	port uint32
}

func (a vsockAddr) Network() string { return "vsock" }
func (a vsockAddr) String() string  { return "vsock" }

type vsockConn struct {
	*os.File
	local  vsockAddr
	remote vsockAddr
}

func (c *vsockConn) LocalAddr() net.Addr  { return c.local }
func (c *vsockConn) RemoteAddr() net.Addr { return c.remote }

func listenVSock(port uint32) (net.Listener, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	if err := unix.Bind(fd, &unix.SockaddrVM{CID: unix.VMADDR_CID_ANY, Port: port}); err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	if err := unix.Listen(fd, 128); err != nil {
		_ = unix.Close(fd)
		return nil, err
	}
	return &vsockListener{
		fd:   fd,
		file: os.NewFile(uintptr(fd), "vsock-listen"),
		port: port,
	}, nil
}

func (l *vsockListener) Accept() (net.Conn, error) {
	rawConn, err := l.file.SyscallConn()
	if err != nil {
		return nil, err
	}
	var nfd int
	var sa unix.Sockaddr
	var acceptErr error
	for {
		rerr := rawConn.Read(func(fd uintptr) bool {
			nfd, sa, acceptErr = unix.Accept4(int(fd), unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK)
			if acceptErr == unix.EAGAIN || acceptErr == unix.EWOULDBLOCK {
				return false
			}
			return true
		})
		if rerr != nil {
			return nil, rerr
		}
		if acceptErr == unix.EINTR {
			continue
		}
		if acceptErr != nil {
			return nil, acceptErr
		}
		break
	}
	var rcid, rport uint32
	if vm, ok := sa.(*unix.SockaddrVM); ok {
		rcid, rport = vm.CID, vm.Port
	}
	f := os.NewFile(uintptr(nfd), "vsock-conn")
	return &vsockConn{
		File:   f,
		local:  vsockAddr{cid: unix.VMADDR_CID_ANY, port: l.port},
		remote: vsockAddr{cid: rcid, port: rport},
	}, nil
}

func (l *vsockListener) Close() error   { return l.file.Close() }
func (l *vsockListener) Addr() net.Addr { return vsockAddr{cid: unix.VMADDR_CID_ANY, port: l.port} }

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

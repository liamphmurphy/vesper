//go:build linux || darwin

package main

import (
	"net"
	"os"

	"golang.org/x/sys/unix"
)

type vsockListener struct {
	fd   int
	file *os.File
	port uint32
	// hostOnly drops connections from any CID but the host's (2).
	hostOnly bool
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

func shutdownVSockWrite(vc *vsockConn) error {
	if vc == nil || vc.File == nil {
		return nil
	}
	return unix.Shutdown(int(vc.Fd()), unix.SHUT_WR)
}

// bindVSock returns a non-blocking AF_VSOCK socket listening on port.
func bindVSock(port uint32) (*vsockListener, error) {
	fd, err := newVSockSocket()
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
	for {
		var nfd int
		var sa unix.Sockaddr
		var acceptErr error
		rerr := rawConn.Read(func(fd uintptr) bool {
			nfd, sa, acceptErr = acceptVSock(int(fd))
			if acceptErr == unix.EAGAIN || acceptErr == unix.EWOULDBLOCK {
				return false
			}
			return true
		})
		if rerr != nil {
			return nil, rerr
		}
		if acceptErr == unix.EINTR || acceptErr == unix.ECONNABORTED {
			continue
		}
		if acceptErr != nil {
			return nil, acceptErr
		}
		var rcid, rport uint32
		if vm, ok := sa.(*unix.SockaddrVM); ok {
			rcid, rport = vm.CID, vm.Port
		}
		if l.hostOnly && rcid != unix.VMADDR_CID_HOST {
			_ = unix.Close(nfd)
			continue
		}
		f := os.NewFile(uintptr(nfd), "vsock-conn")
		return &vsockConn{
			File:   f,
			local:  vsockAddr{cid: unix.VMADDR_CID_ANY, port: l.port},
			remote: vsockAddr{cid: rcid, port: rport},
		}, nil
	}
}

func (l *vsockListener) Close() error   { return l.file.Close() }
func (l *vsockListener) Addr() net.Addr { return vsockAddr{cid: unix.VMADDR_CID_ANY, port: l.port} }

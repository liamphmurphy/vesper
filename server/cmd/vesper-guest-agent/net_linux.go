//go:build linux

package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"sync"
	"unsafe"

	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

const (
	guestDummyIP    = "10.255.255.1"
	guestDummyCIDR  = "10.255.255.1/30"
	guestDummyGW    = "10.255.255.2"
	egressProxyPort = 15001
	soOriginalDst   = 80
)

func setupGuestNetworking(log *slog.Logger, aliases *dnsStubConfig) error {
	if err := runCmd("ip", "link", "set", "lo", "up"); err != nil {
		return fmt.Errorf("ip link lo up: %w", err)
	}
	if runCmd("ip", "link", "show", "dummy0") != nil {
		if err := runCmd("ip", "link", "add", "dummy0", "type", "dummy"); err != nil {
			return fmt.Errorf("ip link add dummy0: %w", err)
		}
	}
	if err := runCmd("ip", "addr", "replace", guestDummyCIDR, "dev", "dummy0"); err != nil {
		return fmt.Errorf("ip addr dummy0: %w", err)
	}
	if err := runCmd("ip", "link", "set", "dummy0", "up"); err != nil {
		return fmt.Errorf("ip link dummy0 up: %w", err)
	}
	if err := runCmd("ip", "route", "replace", "default", "via", guestDummyGW, "dev", "dummy0", "onlink"); err != nil {
		return fmt.Errorf("ip route default: %w", err)
	}
	_ = os.WriteFile("/proc/sys/net/ipv4/ip_forward", []byte("1\n"), 0o644)

	_ = os.Remove("/etc/resolv.conf")
	if err := os.WriteFile("/etc/resolv.conf", []byte("nameserver "+guestDummyIP+"\noptions single-request timeout:1 attempts:3\n"), 0o644); err != nil {
		return fmt.Errorf("write resolv.conf: %w", err)
	}

	if err := configureNATRedirect(); err != nil {
		return fmt.Errorf("iptables nat: %w", err)
	}

	if err := startDNSStub(log, aliases); err != nil {
		return fmt.Errorf("dns stub: %w", err)
	}
	if err := startTransparentTCPProxy(log); err != nil {
		return fmt.Errorf("tcp proxy: %w", err)
	}
	return nil
}

func runCmd(name string, args ...string) error {
	cmd := exec.Command(name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s %v: %w (%s)", name, args, err, string(out))
	}
	return nil
}

func configureNATRedirect() error {
	ipt, err := exec.LookPath("iptables")
	if err != nil {
		return err
	}
	_ = runCmd(ipt, "-t", "nat", "-N", "VESPER_EGRESS")
	if err := runCmd(ipt, "-t", "nat", "-F", "VESPER_EGRESS"); err != nil {
		return err
	}
	for _, cidr := range []string{"127.0.0.0/8", "10.255.255.0/30", "172.16.0.0/12"} {
		if err := runCmd(ipt, "-t", "nat", "-A", "VESPER_EGRESS", "-d", cidr, "-j", "RETURN"); err != nil {
			return err
		}
	}
	if err := runCmd(ipt, "-t", "nat", "-A", "VESPER_EGRESS", "-p", "tcp", "-j", "REDIRECT", "--to-ports", fmt.Sprintf("%d", egressProxyPort)); err != nil {
		return err
	}
	ensureJump := func(chain string, extra ...string) error {
		checkArgs := append([]string{"-t", "nat", "-C", chain}, extra...)
		checkArgs = append(checkArgs, "-p", "tcp", "-j", "VESPER_EGRESS")
		if runCmd(ipt, checkArgs...) == nil {
			return nil
		}
		addArgs := append([]string{"-t", "nat", "-A", chain}, extra...)
		addArgs = append(addArgs, "-p", "tcp", "-j", "VESPER_EGRESS")
		return runCmd(ipt, addArgs...)
	}
	if err := ensureJump("OUTPUT"); err != nil {
		return err
	}
	if err := ensureJump("PREROUTING", "-i", "docker0"); err != nil {
		return err
	}
	if err := ensureJump("PREROUTING", "-i", "br-+"); err != nil {
		return err
	}
	return nil
}

func dialHostVSock(port uint32) (*vsockConn, error) {
	fd, err := unix.Socket(unix.AF_VSOCK, unix.SOCK_STREAM|unix.SOCK_CLOEXEC|unix.SOCK_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	sa := &unix.SockaddrVM{CID: 2, Port: port}
	for {
		err = unix.Connect(fd, sa)
		if err == nil || errors.Is(err, unix.EISCONN) {
			break
		}
		if errors.Is(err, unix.EINTR) {
			continue
		}
		if errors.Is(err, unix.EINPROGRESS) {
			pfd := []unix.PollFd{{Fd: int32(fd), Events: unix.POLLOUT}}
			_, perr := unix.Poll(pfd, 5000)
			if perr != nil {
				_ = unix.Close(fd)
				return nil, perr
			}
			soErr, gerr := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_ERROR)
			if gerr != nil {
				_ = unix.Close(fd)
				return nil, gerr
			}
			if soErr != 0 {
				_ = unix.Close(fd)
				return nil, unix.Errno(soErr)
			}
			break
		}
		_ = unix.Close(fd)
		return nil, err
	}
	return &vsockConn{
		File:   os.NewFile(uintptr(fd), "vsock-dial"),
		remote: vsockAddr{cid: 2, port: port},
	}, nil
}

func startDNSStub(log *slog.Logger, aliases *dnsStubConfig) error {
	addr := guestDummyIP + ":53"
	pc, err := net.ListenPacket("udp", addr)
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		_ = pc.Close()
		return err
	}

	var dnsFwdMu sync.Mutex
	resolvePacket := func(pkt []byte) ([]byte, error) {
		if resp, handled := maybeAnswerLocalAlias(pkt, aliases); handled {
			return resp, nil
		}
		dnsFwdMu.Lock()
		defer dnsFwdMu.Unlock()
		vs, err := dialHostVSock(guestproto.PortEgressDNS)
		if err != nil {
			return nil, err
		}
		defer vs.Close()
		if err := guestproto.WriteDNSFrame(vs, pkt); err != nil {
			return nil, err
		}
		return guestproto.ReadDNSFrame(vs)
	}

	go func() {
		buf := make([]byte, 4096)
		for {
			n, raddr, rerr := pc.ReadFrom(buf)
			if rerr != nil {
				return
			}
			pkt := append([]byte(nil), buf[:n]...)
			go func() {
				resp, perr := resolvePacket(pkt)
				if perr != nil {
					log.Debug("dns forward failed", "err", perr)
					return
				}
				if len(resp) > 0 {
					_, _ = pc.WriteTo(resp, raddr)
				}
			}()
		}
	}()

	go func() {
		for {
			c, aerr := ln.Accept()
			if aerr != nil {
				return
			}
			go func() {
				defer c.Close()
				for {
					pkt, rerr := guestproto.ReadDNSFrame(c)
					if rerr != nil || len(pkt) == 0 {
						return
					}
					resp, perr := resolvePacket(pkt)
					if perr != nil || len(resp) == 0 {
						return
					}
					if werr := guestproto.WriteDNSFrame(c, resp); werr != nil {
						return
					}
				}
			}()
		}
	}()
	return nil
}

func maybeAnswerLocalAlias(pkt []byte, aliases *dnsStubConfig) ([]byte, bool) {
	if aliases == nil {
		return nil, false
	}
	var p dnsmessage.Parser
	hdr, err := p.Start(pkt)
	if err != nil {
		return nil, false
	}
	q, err := p.Question()
	if err != nil {
		return nil, false
	}
	ipStr, ok := aliases.lookupAlias(q.Name.String())
	if !ok {
		return nil, false
	}
	ip4 := net.ParseIP(ipStr).To4()
	if ip4 == nil {
		return nil, false
	}
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{
		ID:                 hdr.ID,
		Response:           true,
		RecursionDesired:   hdr.RecursionDesired,
		RecursionAvailable: true,
		RCode:              dnsmessage.RCodeSuccess,
	})
	_ = b.StartQuestions()
	_ = b.Question(q)
	_ = b.StartAnswers()
	if q.Type == dnsmessage.TypeA {
		_ = b.AResource(
			dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 10},
			dnsmessage.AResource{A: [4]byte{ip4[0], ip4[1], ip4[2], ip4[3]}},
		)
	}
	out, err := b.Finish()
	if err != nil {
		return nil, false
	}
	return out, true
}

func startTransparentTCPProxy(log *slog.Logger) error {
	ln, err := net.Listen("tcp", fmt.Sprintf(":%d", egressProxyPort))
	if err != nil {
		return err
	}
	go func() {
		for {
			c, aerr := ln.Accept()
			if aerr != nil {
				return
			}
			go handleRedirectedTCP(log, c)
		}
	}()
	return nil
}

func handleRedirectedTCP(log *slog.Logger, client net.Conn) {
	defer client.Close()
	tcpConn, ok := client.(*net.TCPConn)
	if !ok {
		return
	}
	dstIP, dstPort, err := getOriginalDst(tcpConn)
	if err != nil {
		log.Debug("SO_ORIGINAL_DST failed", "err", err)
		return
	}
	ip4 := dstIP.To4()
	if ip4 == nil || ip4.IsLoopback() || (ip4[0] == 10 && ip4[1] == 255 && ip4[2] == 255) || dstPort == 0 {
		return
	}

	vs, err := dialHostVSock(guestproto.PortEgressTCP)
	if err != nil {
		log.Debug("egress vsock dial failed", "dst", ip4.String(), "port", dstPort, "err", err)
		return
	}
	defer vs.Close()

	if err := guestproto.WriteEgressTCPHeader(vs, ip4, dstPort); err != nil {
		return
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(vs, tcpConn)
		_ = unix.Shutdown(int(vs.Fd()), unix.SHUT_WR)
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(tcpConn, vs)
		_ = tcpConn.CloseWrite()
	}()
	wg.Wait()
}

func getOriginalDst(conn *net.TCPConn) (net.IP, uint16, error) {
	rc, err := conn.SyscallConn()
	if err != nil {
		return nil, 0, err
	}
	var raw [16]byte
	var sockErr error
	if err := rc.Control(func(fd uintptr) {
		sz := uint32(len(raw))
		_, _, errno := unix.Syscall6(
			unix.SYS_GETSOCKOPT,
			fd,
			unix.SOL_IP,
			soOriginalDst,
			uintptr(unsafe.Pointer(&raw[0])),
			uintptr(unsafe.Pointer(&sz)),
			0,
		)
		if errno != 0 {
			sockErr = errno
		}
	}); err != nil {
		return nil, 0, err
	}
	if sockErr != nil {
		return nil, 0, sockErr
	}
	fam := binary.NativeEndian.Uint16(raw[0:2])
	if fam != unix.AF_INET {
		return nil, 0, fmt.Errorf("unexpected SO_ORIGINAL_DST family %d", fam)
	}
	port := binary.BigEndian.Uint16(raw[2:4])
	ip := net.IPv4(raw[4], raw[5], raw[6], raw[7])
	return ip, port, nil
}

//go:build darwin && arm64

package microvm

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Code-Hex/vz/v3"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

const defaultKernelCmdLine = "console=hvc0 root=/dev/vda ro init=/sbin/init loglevel=4 panic=-1"

// VZDriver runs microVMs via Apple's Virtualization.framework (Code-Hex/vz/v3).
type VZDriver struct {
	BootTimeout time.Duration
}

// NewVZDriver returns a Driver backed by Apple Virtualization.framework.
func NewVZDriver() Driver {
	return &VZDriver{BootTimeout: 15 * time.Second}
}

func (d *VZDriver) Start(ctx context.Context, cfg VMConfig) (VM, error) {
	if cfg.KernelPath == "" {
		return nil, errors.New("microvm: KernelPath is required")
	}
	if len(cfg.Drives) == 0 {
		return nil, errors.New("microvm: at least one rootfs drive is required")
	}
	cpus := cfg.CPUs
	if cpus < 1 {
		cpus = 2
	}
	mem := cfg.MemoryBytes
	if mem < 256<<20 {
		mem = 256 << 20
	}
	cmdLine := cfg.CommandLine
	if cmdLine == "" {
		cmdLine = defaultKernelCmdLine
	}

	bootLoader, err := vz.NewLinuxBootLoader(cfg.KernelPath, vz.WithCommandLine(cmdLine))
	if err != nil {
		return nil, fmt.Errorf("vz linux boot loader: %w", err)
	}
	vmCfg, err := vz.NewVirtualMachineConfiguration(bootLoader, uint(cpus), mem)
	if err != nil {
		return nil, fmt.Errorf("vz vm config: %w", err)
	}
	platform, err := vz.NewGenericPlatformConfiguration()
	if err != nil {
		return nil, fmt.Errorf("vz platform: %w", err)
	}
	vmCfg.SetPlatformVirtualMachineConfiguration(platform)

	conInR, conInW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	conOutR, conOutW, err := os.Pipe()
	if err != nil {
		_ = conInR.Close()
		_ = conInW.Close()
		return nil, err
	}
	cleanupPipes := func() {
		_ = conInW.Close()
		_ = conInR.Close()
		_ = conOutW.Close()
		_ = conOutR.Close()
	}

	serialAtt, err := vz.NewFileHandleSerialPortAttachment(conInR, conOutW)
	if err != nil {
		cleanupPipes()
		return nil, fmt.Errorf("vz serial att: %w", err)
	}
	serialCfg, err := vz.NewVirtioConsoleDeviceSerialPortConfiguration(serialAtt)
	if err != nil {
		cleanupPipes()
		return nil, fmt.Errorf("vz serial cfg: %w", err)
	}
	vmCfg.SetSerialPortsVirtualMachineConfiguration([]*vz.VirtioConsoleDeviceSerialPortConfiguration{serialCfg})

	storage := make([]vz.StorageDeviceConfiguration, 0, len(cfg.Drives))
	for _, drv := range cfg.Drives {
		att, err := vz.NewDiskImageStorageDeviceAttachment(drv.Path, drv.ReadOnly)
		if err != nil {
			cleanupPipes()
			return nil, fmt.Errorf("vz attach %s: %w", drv.Path, err)
		}
		blk, err := vz.NewVirtioBlockDeviceConfiguration(att)
		if err != nil {
			cleanupPipes()
			return nil, fmt.Errorf("vz block %s: %w", drv.Path, err)
		}
		storage = append(storage, blk)
	}
	vmCfg.SetStorageDevicesVirtualMachineConfiguration(storage)

	if len(cfg.Shares) > 0 {
		shares := make([]vz.DirectorySharingDeviceConfiguration, 0, len(cfg.Shares))
		for _, s := range cfg.Shares {
			sd, err := vz.NewSharedDirectory(s.HostDir, s.ReadOnly)
			if err != nil {
				cleanupPipes()
				return nil, fmt.Errorf("vz shared dir %s: %w", s.HostDir, err)
			}
			single, err := vz.NewSingleDirectoryShare(sd)
			if err != nil {
				cleanupPipes()
				return nil, fmt.Errorf("vz single share %s: %w", s.Tag, err)
			}
			fsCfg, err := vz.NewVirtioFileSystemDeviceConfiguration(s.Tag)
			if err != nil {
				cleanupPipes()
				return nil, fmt.Errorf("vz virtiofs %s: %w", s.Tag, err)
			}
			fsCfg.SetDirectoryShare(single)
			shares = append(shares, fsCfg)
		}
		vmCfg.SetDirectorySharingDevicesVirtualMachineConfiguration(shares)
	}

	sockCfg, err := vz.NewVirtioSocketDeviceConfiguration()
	if err != nil {
		cleanupPipes()
		return nil, fmt.Errorf("vz vsock cfg: %w", err)
	}
	vmCfg.SetSocketDevicesVirtualMachineConfiguration([]vz.SocketDeviceConfiguration{sockCfg})

	balloonCfg, err := vz.NewVirtioTraditionalMemoryBalloonDeviceConfiguration()
	if err != nil {
		cleanupPipes()
		return nil, fmt.Errorf("vz balloon cfg: %w", err)
	}
	vmCfg.SetMemoryBalloonDevicesVirtualMachineConfiguration([]vz.MemoryBalloonDeviceConfiguration{balloonCfg})

	entropyCfg, err := vz.NewVirtioEntropyDeviceConfiguration()
	if err != nil {
		cleanupPipes()
		return nil, fmt.Errorf("vz entropy cfg: %w", err)
	}
	vmCfg.SetEntropyDevicesVirtualMachineConfiguration([]*vz.VirtioEntropyDeviceConfiguration{entropyCfg})

	if ok, err := vmCfg.Validate(); !ok || err != nil {
		cleanupPipes()
		return nil, fmt.Errorf("vz config invalid (ok=%v): %w", ok, err)
	}

	machine, err := vz.NewVirtualMachine(vmCfg)
	if err != nil {
		cleanupPipes()
		return nil, fmt.Errorf("vz new vm: %w", err)
	}
	sockDevs := machine.SocketDevices()
	if len(sockDevs) == 0 {
		cleanupPipes()
		return nil, errors.New("vz vm has no socket device")
	}
	sockDev := sockDevs[0]

	ring := newConsoleRing(64 << 10)
	go func() {
		buf := make([]byte, 4096)
		for {
			n, rerr := conOutR.Read(buf)
			if n > 0 {
				ring.write(buf[:n])
			}
			if rerr != nil {
				return
			}
		}
	}()

	vm := &vzVM{
		vm:      machine,
		sock:    sockDev,
		console: ring,
		closers: []io.Closer{conInW, conInR, conOutW, conOutR},
	}

	readyCh := make(chan struct{}, 1)
	readyLn, err := sockDev.Listen(guestproto.PortReady)
	if err != nil {
		vm.closeResources()
		return nil, fmt.Errorf("vz listen ready port: %w", err)
	}
	vm.listeners = append(vm.listeners, readyLn)
	go func() {
		conn, aerr := readyLn.Accept()
		if aerr == nil && conn != nil {
			_ = conn.Close()
		}
		select {
		case readyCh <- struct{}{}:
		default:
		}
	}()

	for port, handler := range cfg.Listeners {
		ln, lerr := sockDev.Listen(port)
		if lerr != nil {
			vm.closeResources()
			return nil, fmt.Errorf("vz listen port %d: %w", port, lerr)
		}
		vm.listeners = append(vm.listeners, ln)
		h := handler
		go acceptLoop(ln, h)
	}

	if err := machine.Start(); err != nil {
		vm.closeResources()
		return nil, fmt.Errorf("vz start (console=%q): %w", ring.string(), err)
	}

	timeout := d.BootTimeout
	if timeout <= 0 {
		timeout = 15 * time.Second
	}
	bootCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	if err := vm.waitReady(bootCtx, readyCh); err != nil {
		_ = vm.Stop(context.Background())
		return nil, fmt.Errorf("microvm boot ready: %w (console=%q)", err, ring.string())
	}
	return vm, nil
}

func acceptLoop(ln *vz.VirtioSocketListener, handler VSockHandler) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		if handler == nil {
			_ = conn.Close()
			continue
		}
		go handler(conn)
	}
}

type vzVM struct {
	vm        *vz.VirtualMachine
	sock      *vz.VirtioSocketDevice
	console   *consoleRing
	listeners []*vz.VirtioSocketListener
	closers   []io.Closer
	stopOnce  sync.Once
}

func (v *vzVM) waitReady(ctx context.Context, readyCh <-chan struct{}) error {
	// Wait briefly for guest PortReady signal, also verify Ping succeeds.
	select {
	case <-readyCh:
	case <-time.After(1500 * time.Millisecond):
	case <-ctx.Done():
		return ctx.Err()
	}
	client := v.Client()
	for {
		pingCtx, cancel := context.WithTimeout(ctx, 500*time.Millisecond)
		_, err := client.Ping(pingCtx)
		cancel()
		if err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("%w (last ping err: %v)", ctx.Err(), err)
		case <-time.After(25 * time.Millisecond):
		}
	}
}

func (v *vzVM) Client() *guestproto.Client {
	return &guestproto.Client{
		Dial: func(ctx context.Context) (net.Conn, error) {
			return v.DialVSock(ctx, guestproto.PortRPC)
		},
	}
}

func (v *vzVM) DialVSock(ctx context.Context, port uint32) (net.Conn, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	return v.sock.Connect(port)
}

func (v *vzVM) SetMemoryTarget(bytes uint64) error {
	devs := v.vm.MemoryBalloonDevices()
	if len(devs) == 0 {
		return errors.New("microvm: no memory balloon device")
	}
	b := vz.AsVirtioTraditionalMemoryBalloonDevice(devs[0])
	if b == nil {
		return errors.New("microvm: unsupported memory balloon device")
	}
	b.SetTargetVirtualMachineMemorySize(bytes)
	return nil
}

func (v *vzVM) ConsoleOutput() string { return v.console.string() }

func (v *vzVM) Stop(ctx context.Context) error {
	var stopErr error
	v.stopOnce.Do(func() {
		shutCtx, cancel := context.WithTimeout(ctx, 750*time.Millisecond)
		_ = v.Client().Shutdown(shutCtx)
		cancel()

		deadline := time.Now().Add(750 * time.Millisecond)
		for time.Now().Before(deadline) {
			if v.vm.State() == vz.VirtualMachineStateStopped {
				break
			}
			time.Sleep(15 * time.Millisecond)
		}
		if v.vm.CanStop() {
			if err := v.vm.Stop(); err != nil && !strings.Contains(err.Error(), "stopped") {
				stopErr = err
			}
		}
		v.closeResources()
	})
	return stopErr
}

func (v *vzVM) closeResources() {
	for _, ln := range v.listeners {
		_ = ln.Close()
	}
	for _, c := range v.closers {
		_ = c.Close()
	}
}

type consoleRing struct {
	mu  sync.Mutex
	max int
	buf bytes.Buffer
}

func newConsoleRing(max int) *consoleRing { return &consoleRing{max: max} }

func (r *consoleRing) write(p []byte) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(p) >= r.max {
		r.buf.Reset()
		r.buf.Write(p[len(p)-r.max:])
		return
	}
	if r.buf.Len()+len(p) > r.max {
		excess := r.buf.Len() + len(p) - r.max
		data := append([]byte(nil), r.buf.Bytes()[excess:]...)
		r.buf.Reset()
		r.buf.Write(data)
	}
	r.buf.Write(p)
}

func (r *consoleRing) string() string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.buf.String()
}

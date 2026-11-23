package microvm

import (
	"context"
	"errors"
	"net"
	"sync"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

// MemDriver is an in-memory Driver for unit tests that do not boot a real VM.
type MemDriver struct {
	mu      sync.Mutex
	Started []VMConfig
	Handler func(ctx context.Context, conn net.Conn)
}

func (d *MemDriver) Start(ctx context.Context, cfg VMConfig) (VM, error) {
	d.mu.Lock()
	d.Started = append(d.Started, cfg)
	d.mu.Unlock()
	return &MemVM{
		cfg:     cfg,
		target:  cfg.MemoryBytes,
		handler: d.Handler,
	}, nil
}

// Configs is a copy of the configs VMs were started with, safe to call while
// other goroutines start VMs.
func (d *MemDriver) Configs() []VMConfig {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]VMConfig(nil), d.Started...)
}

// MemVM is an in-memory VM implementing VM for fast host tests.
type MemVM struct {
	mu          sync.Mutex
	cfg         VMConfig
	target      uint64
	paused      bool
	pauseCount  int
	resumeCount int
	stopped     bool
	handler     func(ctx context.Context, conn net.Conn)
}

func (v *MemVM) Client() *guestproto.Client {
	return &guestproto.Client{
		Dial: func(ctx context.Context) (net.Conn, error) {
			return v.DialVSock(ctx, guestproto.PortRPC)
		},
	}
}

func (v *MemVM) DialVSock(ctx context.Context, port uint32) (net.Conn, error) {
	v.mu.Lock()
	stopped := v.stopped
	paused := v.paused
	h := v.handler
	v.mu.Unlock()
	if stopped {
		return nil, errors.New("microvm: vm stopped")
	}
	if paused {
		return nil, errors.New("microvm: vm paused")
	}
	if port == guestproto.PortRPC && h != nil {
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			h(ctx, b)
		}()
		return a, nil
	}
	if ln, ok := v.cfg.Listeners[port]; ok && ln != nil {
		a, b := net.Pipe()
		go ln(b)
		return a, nil
	}
	return nil, errors.New("microvm: vsock port not listening in MemVM")
}

func (v *MemVM) SetMemoryTarget(bytes uint64) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.target = bytes
	return nil
}

func (v *MemVM) MemoryTarget() uint64 {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.target
}

func (v *MemVM) Pause(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.stopped {
		return errors.New("microvm: vm stopped")
	}
	if !v.paused {
		v.paused = true
		v.pauseCount++
	}
	return nil
}

func (v *MemVM) Resume(ctx context.Context) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	v.mu.Lock()
	defer v.mu.Unlock()
	if v.stopped {
		return errors.New("microvm: vm stopped")
	}
	if v.paused {
		v.paused = false
		v.resumeCount++
	}
	return nil
}

func (v *MemVM) Paused() bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.paused
}

func (v *MemVM) PauseCount() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.pauseCount
}

func (v *MemVM) ResumeCount() int {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.resumeCount
}

func (v *MemVM) ConsoleOutput() string { return "" }

func (v *MemVM) Stop(context.Context) error {
	v.mu.Lock()
	defer v.mu.Unlock()
	v.paused = false
	v.stopped = true
	return nil
}

func (v *MemVM) Stopped() bool {
	v.mu.Lock()
	defer v.mu.Unlock()
	return v.stopped
}

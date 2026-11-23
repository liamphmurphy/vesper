// Package microvm manages hardware-virtualised Linux microVMs, their
// synthetic-DNS vsock egress proxy, and memory balloon lifecycle.
package microvm

import (
	"context"
	"net"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

// DriveSpec describes a virtio-blk image attached to a microVM.
type DriveSpec struct {
	Path     string
	ReadOnly bool
}

// VirtioFSSpec describes a host directory exposed to the guest over virtiofs.
type VirtioFSSpec struct {
	Tag      string
	HostDir  string
	ReadOnly bool
}

// VSockHandler handles an incoming guest-to-host connection on a listened vsock port.
// Ownership of conn passes to the handler, which must close it when done.
type VSockHandler func(conn net.Conn)

// MacOSBoot boots a macOS guest from an installed disk instead of a Linux
// kernel. Its first drive is the macOS disk.
type MacOSBoot struct {
	// HardwareModel is VZMacHardwareModel's data representation, from the
	// golden image the disk was installed with.
	HardwareModel []byte
	// AuxStoragePath is the VM's own copy of the golden image's auxiliary
	// storage (NVRAM). The VM writes to it.
	AuxStoragePath string
	// MachineIDPath holds VZMacMachineIdentifier's data representation; the
	// driver creates a new identifier there when the file doesn't exist. Two
	// VMs running at once must not share one.
	MachineIDPath string
}

// VMConfig defines the virtual hardware and boot configuration for a microVM.
// MicroVMs deliberately attach zero VirtioNetworkDeviceConfigurations; all
// external communication passes over AF_VSOCK.
type VMConfig struct {
	KernelPath  string
	CommandLine string
	// MacOS, when set, boots a macOS guest; KernelPath and CommandLine are
	// then unused.
	MacOS       *MacOSBoot
	CPUs        int
	MemoryBytes uint64
	Drives      []DriveSpec
	Shares      []VirtioFSSpec
	Listeners   map[uint32]VSockHandler
	// BootTimeout bounds the wait for the guest agent; 0 is the driver's
	// default.
	BootTimeout time.Duration
}

// VM represents a running microVM instance.
type VM interface {
	Client() *guestproto.Client
	DialVSock(ctx context.Context, port uint32) (net.Conn, error)
	SetMemoryTarget(bytes uint64) error
	ConsoleOutput() string
	Stop(ctx context.Context) error
}

// Pauser is an optional interface for VMs whose guest vCPUs can be paused
// while idle (e.g. Apple Virtualization.framework's VZVirtualMachine.pause)
// to eliminate guest timer wakeups without losing booted state.
type Pauser interface {
	Pause(ctx context.Context) error
	Resume(ctx context.Context) error
}

// Driver starts isolated microVM instances.
type Driver interface {
	Start(ctx context.Context, cfg VMConfig) (VM, error)
}

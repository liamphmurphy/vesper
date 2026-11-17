// Package microvm manages hardware-virtualised Linux microVMs, their
// synthetic-DNS vsock egress proxy, and memory balloon lifecycle.
package microvm

import (
	"context"
	"net"

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

// VMConfig defines the virtual hardware and boot configuration for a microVM.
// MicroVMs deliberately attach zero VirtioNetworkDeviceConfigurations; all
// external communication passes over AF_VSOCK.
type VMConfig struct {
	KernelPath  string
	CommandLine string
	CPUs        int
	MemoryBytes uint64
	Drives      []DriveSpec
	Shares      []VirtioFSSpec
	Listeners   map[uint32]VSockHandler
}

// VM represents a running microVM instance.
type VM interface {
	Client() *guestproto.Client
	DialVSock(ctx context.Context, port uint32) (net.Conn, error)
	SetMemoryTarget(bytes uint64) error
	ConsoleOutput() string
	Stop(ctx context.Context) error
}

// Driver starts isolated microVM instances.
type Driver interface {
	Start(ctx context.Context, cfg VMConfig) (VM, error)
}

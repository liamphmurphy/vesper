package customapps

import (
	"context"
	"io"
	"time"

	"github.com/google/uuid"
)

// VMState describes the runtime state of a Custom App's microVM.
type VMState string

const (
	VMStateStopped VMState = "stopped"
	VMStateRunning VMState = "running"
	VMStatePaused  VMState = "paused"
)

// VMStatus reports the current state and basic telemetry of a Custom App VM.
type VMStatus struct {
	Available   bool       `json:"available"`
	State       VMState    `json:"state"`
	ActiveCalls int        `json:"active_calls"`
	MountCount  int        `json:"mount_count"`
	AllowPublic bool       `json:"allow_public"`
	BootedAt    *time.Time `json:"booted_at,omitempty"`
	LastUsedAt  *time.Time `json:"last_used_at,omitempty"`
	PausedAt    *time.Time `json:"paused_at,omitempty"`
}

// VMAppSpec describes the isolation policy and host mounts for a Custom App VM.
type VMAppSpec struct {
	AppID       uuid.UUID
	Slug        string
	Mounts      Mounts
	AllowPublic bool
}

// VMFileWrite writes a file inside the Custom App's microVM before exec.
type VMFileWrite struct {
	Path string
	Data []byte
	Mode uint32
}

// VMExecRequest starts a process inside a Custom App's microVM.
type VMExecRequest struct {
	App   VMAppSpec
	Argv  []string
	Env   map[string]string
	Dir   string
	Files []VMFileWrite
}

// VMProcess represents a running process inside a Custom App's microVM.
// Callers must Close the process when done so the VM's active lease is released.
type VMProcess interface {
	Stdin() io.WriteCloser
	Stdout() io.Reader
	Stderr() io.Reader
	Kill(grace time.Duration) error
	Wait() (exitCode int, err error)
	Close() error
}

// VMBackend runs Custom App workloads (Nix jobs and server.ts MCP workers)
// inside per-app isolated Linux microVMs.
type VMBackend interface {
	// StartAppVMProcess ensures the app's microVM is running (resuming if paused,
	// restarting if approved mounts changed) and starts a process inside it.
	// The VM holds an active lease until the returned VMProcess is closed.
	StartAppVMProcess(ctx context.Context, req VMExecRequest) (VMProcess, error)

	// ReadAppVMFile reads a file from inside the app's microVM (up to limit bytes).
	ReadAppVMFile(ctx context.Context, app VMAppSpec, guestPath string, limit int64) ([]byte, error)

	// UnlinkAppVMPaths removes paths inside the app's microVM.
	UnlinkAppVMPaths(ctx context.Context, app VMAppSpec, paths []string, recursive bool) error

	// SyncAppVMPolicy updates dynamic runtime policy (such as public egress) for a
	// running or paused app VM immediately, and schedules a restart if mounts
	// changed while idle.
	SyncAppVMPolicy(ctx context.Context, app VMAppSpec) error

	// AppVMStatus returns the current status of the app's microVM.
	AppVMStatus(appID uuid.UUID) VMStatus

	// StopAppVM stops the app's microVM while keeping its workspace disk.
	StopAppVM(ctx context.Context, appID uuid.UUID) error

	// RestartAppVM stops any existing VM for the app and boots a fresh one.
	RestartAppVM(ctx context.Context, app VMAppSpec) error

	// DeleteAppVM stops the app's microVM and removes its on-disk state.
	DeleteAppVM(ctx context.Context, appID uuid.UUID) error

	// NotifyAppWindowClosed hints that the user closed the app's window,
	// accelerating idle pause once active calls complete.
	NotifyAppWindowClosed(appID uuid.UUID)
}

// Package runner executes managed runs (docs/dev/plan.md §6.4–6.6): it takes
// dispatched runs off the queue, prepares a workspace that persists between
// turns, runs each turn as one headless harness invocation, streams its
// events into run_events, and decides what happens when the process exits.
package runner

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
)

// ExecSpec is one process in a run's workspace.
type ExecSpec struct {
	Name string            // container/process name, for logs and cleanup
	Argv []string          // argv[0] is the program
	Env  map[string]string // only these are passed (the fake backend adds the runner's own)
	// Dir is the working directory, relative to the workspace root ("" = the
	// root). A delegated run's git worktree is one.
	Dir   string
	Files map[string][]byte // written relative to the working directory before start
	// Networks the process joins besides the backend's own: a turn's service
	// network (ServiceBackend). Only the microVM backend has networks.
	Networks []string
}

// Process is a running ExecSpec.
type Process interface {
	Stdin() io.WriteCloser
	Stdout() io.Reader // the harness event stream
	Stderr() io.Reader
	Interrupt() error // SIGINT: let the harness end its turn
	Kill() error
	Wait() (exitCode int, err error)
}

// Backend runs processes in a run's persistent workspace (§6.5).
type Backend interface {
	Name() string // docker | microvm | fake
	// Isolates reports whether turns run inside an isolated sandbox (container
	// or microVM) rather than unisolated host fake mode.
	Isolates() bool
	// WorkspaceDir is the checkout's path as processes see it.
	WorkspaceDir(runID string) string
	// EnsureWorkspace creates the run's workspace if it doesn't exist.
	EnsureWorkspace(ctx context.Context, runID string) error
	// HasWorkspace reports whether this backend holds the run's workspace. A
	// run started on the other backend has one there, not here.
	HasWorkspace(ctx context.Context, runID string) (bool, error)
	RemoveWorkspace(ctx context.Context, runID string) error
	Start(ctx context.Context, runID string, spec ExecSpec) (Process, error)
	// ReadOutbox and RemoveOutbox serve an image-generating chat's outbox
	// (see outbox.go).
	ReadOutbox(ctx context.Context, runID string) (files []OutboxFile, skipped []string, err error)
	RemoveOutbox(ctx context.Context, runID string, names []string) error
	// ReadVideoFiles and OpenWorkspaceFile serve a chat's video jobs: the
	// files a renderer reports through, and the finished video (see
	// videofiles.go).
	ReadVideoFiles(ctx context.Context, runID string, req VideoFilesRequest) ([]VideoFile, error)
	OpenWorkspaceFile(ctx context.Context, runID, rel string, limit int64) (io.ReadCloser, int64, error)
	// Cleanup removes processes a previous runner left behind.
	Cleanup(ctx context.Context) error
}

// HostFolders is a backend that can keep a run's checkout in a folder on the
// person's machine, so they can open it in their own editor while the agent
// works (the microVM backend with RUNNER_HOST_WORKSPACES_DIR set).
type HostFolders interface {
	// HostWorkspacesDir is where those folders go; "" when not configured.
	HostWorkspacesDir() string
	// EnsureHostWorkspace is EnsureWorkspace with the checkout in a host
	// folder, which it returns. A run that already has its workspace
	// elsewhere keeps it there, and gets "".
	EnsureHostWorkspace(ctx context.Context, runID string) (string, error)
}

// ------------------------------------------------------------ fake

// Fake runs turns as host processes in a directory per run, with every
// harness replaced by a stand-in binary (cmd/fake-harness). It's for tests
// and disposable instances (the e2e stack, playgrounds) that have no VM support:
// there is no isolation, so it refuses to start a harness it has no
// stand-in for rather than fall through to a real, logged-in CLI on PATH.
type Fake struct {
	Dir string // root for run workspaces
	// Bins maps a harness program to the binary to run instead, e.g.
	// {"claude": "/path/to/fake"}. It applies to the harness wherever it
	// appears in argv (turns are wrapped in `sh -c … "$@"`).
	Bins map[string]string
}

// harnessPrograms are the CLIs adapters invoke.
var harnessPrograms = map[string]bool{"claude": true, "codex": true, "agy": true}

func (l *Fake) Name() string   { return "fake" }
func (l *Fake) Isolates() bool { return false }

func (l *Fake) WorkspaceDir(runID string) string {
	p := filepath.Join(l.Dir, "runs", runID, "workspace")
	if abs, err := filepath.Abs(p); err == nil {
		return abs
	}
	return p
}

func (l *Fake) EnsureWorkspace(_ context.Context, runID string) error {
	return os.MkdirAll(l.WorkspaceDir(runID), 0o755)
}

func (l *Fake) HasWorkspace(_ context.Context, runID string) (bool, error) {
	_, err := os.Stat(l.WorkspaceDir(runID))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

func (l *Fake) RemoveWorkspace(_ context.Context, runID string) error {
	return os.RemoveAll(filepath.Join(l.Dir, "runs", runID))
}

func (l *Fake) Cleanup(context.Context) error { return nil } // processes die with the runner

// subDir joins a workspace-relative directory to root, refusing escapes.
func subDir(root, rel string) (string, error) {
	p := filepath.Join(root, filepath.FromSlash(rel))
	if p != filepath.Clean(root) && !strings.HasPrefix(p, filepath.Clean(root)+string(filepath.Separator)) {
		return "", fmt.Errorf("runner: directory %q escapes the workspace", rel)
	}
	return p, nil
}

func writeFiles(root string, files map[string][]byte) error {
	if len(files) == 0 {
		return nil
	}
	r, err := os.OpenRoot(root)
	if err != nil {
		return err
	}
	defer r.Close()
	for rel, data := range files {
		p := filepath.Join(root, filepath.FromSlash(rel))
		if !strings.HasPrefix(p, filepath.Clean(root)+string(filepath.Separator)) {
			return fmt.Errorf("runner: file %q escapes the workspace", rel)
		}
		if err := r.MkdirAll(filepath.Dir(rel), 0o755); err != nil {
			return err
		}
		if err := r.WriteFile(rel, data, 0o600); err != nil {
			return err
		}
	}
	return nil
}

func (l *Fake) Start(ctx context.Context, runID string, spec ExecSpec) (Process, error) {
	dir := l.WorkspaceDir(runID)
	if spec.Dir != "" {
		var err error
		if dir, err = subDir(dir, spec.Dir); err != nil {
			return nil, err
		}
	}
	if err := writeFiles(dir, spec.Files); err != nil {
		return nil, err
	}
	argv := append([]string{}, spec.Argv...)
	for i, a := range argv {
		if !harnessPrograms[a] {
			continue
		}
		b, ok := l.Bins[a]
		if !ok {
			return nil, fmt.Errorf("runner: %q has no fake binary configured", a)
		}
		argv[i] = b
		break // the first match is the program; later ones are arguments
	}
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	cmd.Dir = dir
	cmd.Env = os.Environ()
	cache := l.DependencyCacheDir()
	if err := os.MkdirAll(cache, 0o755); err != nil {
		return nil, err
	}
	for k, v := range dependencyEnv(cache, dir) {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	for k, v := range spec.Env {
		if k == ClaudeOAuthEnv || k == ClaudeAuthEnv || k == ClaudeAuthScopeEnv || k == CodexAuthEnv || k == CodexAuthScopeEnv || k == AntigravityAuthEnv {
			continue // a fake harness needs no login; keep real ones out of host processes
		}
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} // signal the whole tree
	// Our own pipes, not StdoutPipe: cmd.Wait closes those as soon as the
	// process exits, which can drop the stream's last lines (the result).
	inR, inW, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	outR, outW, err := os.Pipe()
	if err != nil {
		inR.Close()
		inW.Close()
		return nil, err
	}
	errR, errW, err := os.Pipe()
	if err != nil {
		inR.Close()
		inW.Close()
		outR.Close()
		outW.Close()
		return nil, err
	}
	cmd.Stdin, cmd.Stdout, cmd.Stderr = inR, outW, errW
	err = cmd.Start()
	inR.Close()  // the child holds its read end
	outW.Close() // the child holds its copies; EOF arrives when it exits
	errW.Close()
	if err != nil {
		inW.Close()
		outR.Close()
		errR.Close()
		return nil, err
	}
	return &fakeProc{cmd: cmd, in: &onceWriteCloser{f: inW}, out: outR, err: errR}, nil
}

type onceWriteCloser struct {
	f    *os.File
	once sync.Once
	err  error
}

func (w *onceWriteCloser) Write(p []byte) (int, error) { return w.f.Write(p) }
func (w *onceWriteCloser) Close() error {
	w.once.Do(func() { w.err = w.f.Close() })
	return w.err
}

type fakeProc struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *os.File
	err *os.File
}

// Close releases the read ends once the stream has been drained.
func (p *fakeProc) Close() error {
	_ = p.in.Close()
	p.out.Close()
	return p.err.Close()
}

func (p *fakeProc) Stdin() io.WriteCloser { return p.in }
func (p *fakeProc) Stdout() io.Reader     { return p.out }
func (p *fakeProc) Stderr() io.Reader     { return p.err }
func (p *fakeProc) Interrupt() error      { return syscall.Kill(-p.cmd.Process.Pid, syscall.SIGINT) }
func (p *fakeProc) Kill() error           { return syscall.Kill(-p.cmd.Process.Pid, syscall.SIGKILL) }

func (p *fakeProc) Wait() (int, error) {
	err := p.cmd.Wait()
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal()), nil
		}
		return ee.ExitCode(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}

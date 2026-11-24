package customapps

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

type fakeVMProcess struct {
	stdinW  *io.PipeWriter
	stdoutR *io.PipeReader
	stderrR *io.PipeReader
	done    chan int
	killed  chan struct{}
	once    sync.Once
}

func (p *fakeVMProcess) Stdin() io.WriteCloser { return p.stdinW }
func (p *fakeVMProcess) Stdout() io.Reader     { return p.stdoutR }
func (p *fakeVMProcess) Stderr() io.Reader     { return p.stderrR }
func (p *fakeVMProcess) Kill(time.Duration) error {
	p.once.Do(func() { close(p.killed) })
	return nil
}
func (p *fakeVMProcess) Wait() (int, error) {
	code := <-p.done
	return code, nil
}
func (p *fakeVMProcess) Close() error {
	_ = p.stdinW.Close()
	_ = p.stdoutR.Close()
	_ = p.stderrR.Close()
	return nil
}

type fakeVMBackend struct {
	mu          sync.Mutex
	execReqs    []VMExecRequest
	unlinked    [][]string
	synced      []VMAppSpec
	deleted     []uuid.UUID
	windowClose []uuid.UUID
	files       map[string][]byte
	onStart     func(req VMExecRequest, stdin *io.PipeReader, stdout, stderr *io.PipeWriter, killed <-chan struct{}) int
}

func newFakeVMBackend() *fakeVMBackend {
	return &fakeVMBackend{files: make(map[string][]byte)}
}

func (f *fakeVMBackend) StartAppVMProcess(_ context.Context, req VMExecRequest) (VMProcess, error) {
	f.mu.Lock()
	f.execReqs = append(f.execReqs, req)
	fn := f.onStart
	f.mu.Unlock()

	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	stderrR, stderrW := io.Pipe()
	done := make(chan int, 1)
	killed := make(chan struct{})

	go func() {
		defer stdoutW.Close()
		defer stderrW.Close()
		defer stdinR.Close()
		code := 0
		if fn != nil {
			code = fn(req, stdinR, stdoutW, stderrW, killed)
		}
		done <- code
	}()

	return &fakeVMProcess{
		stdinW:  stdinW,
		stdoutR: stdoutR,
		stderrR: stderrR,
		done:    done,
		killed:  killed,
	}, nil
}

func (f *fakeVMBackend) ReadAppVMFile(_ context.Context, _ VMAppSpec, guestPath string, limit int64) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	b, ok := f.files[guestPath]
	if !ok {
		return nil, errors.New("not found")
	}
	if limit > 0 && int64(len(b)) > limit {
		b = b[:limit]
	}
	return append([]byte(nil), b...), nil
}

func (f *fakeVMBackend) UnlinkAppVMPaths(_ context.Context, _ VMAppSpec, paths []string, _ bool) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.unlinked = append(f.unlinked, append([]string(nil), paths...))
	return nil
}

func (f *fakeVMBackend) SyncAppVMPolicy(_ context.Context, app VMAppSpec) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.synced = append(f.synced, app)
	return nil
}

func (f *fakeVMBackend) AppVMStatus(uuid.UUID) VMStatus {
	return VMStatus{Available: true, State: VMStateRunning}
}
func (f *fakeVMBackend) StopAppVM(context.Context, uuid.UUID) error          { return nil }
func (f *fakeVMBackend) RestartAppVM(context.Context, VMAppSpec) error       { return nil }
func (f *fakeVMBackend) NotifyAppWindowClosed(appID uuid.UUID) {
	f.mu.Lock()
	f.windowClose = append(f.windowClose, appID)
	f.mu.Unlock()
}
func (f *fakeVMBackend) DeleteAppVM(_ context.Context, appID uuid.UUID) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.deleted = append(f.deleted, appID)
	return nil
}

func TestCallMCPToolRoutesThroughVMBackend(t *testing.T) {
	vm := newFakeVMBackend()
	vm.onStart = func(req VMExecRequest, stdin *io.PipeReader, stdout, _ *io.PipeWriter, _ <-chan struct{}) int {
		sc := bufio.NewScanner(stdin)
		if !sc.Scan() {
			return 1
		}
		// Send a host SQL RPC from the guest worker and wait for the host reply.
		rpcReq := `{"type":"rpc","id":1,"method":"sql","params":{"query":"SELECT 42 AS n"}}` + "\n"
		_, _ = io.WriteString(stdout, rpcReq)
		if !sc.Scan() {
			return 1
		}
		var reply workerRPCResult
		if err := json.Unmarshal(sc.Bytes(), &reply); err != nil || !reply.OK {
			return 2
		}
		doneLine, _ := json.Marshal(map[string]any{
			"type":   "done",
			"ok":     true,
			"result": reply.Result,
		})
		_, _ = stdout.Write(append(doneLine, '\n'))
		return 0
	}

	appID := uuid.New()
	res, err := CallMCPTool(context.Background(), MCPCallContext{
		AppID:        appID,
		Slug:         "vm-app",
		BundleJS:     "console.log('bundle');",
		Capabilities: Capabilities{"app.sql:read": agentdef.Allowed, "app.http:outbound": agentdef.Allowed},
		VM:           vm,
		SQLQuery: func(_ context.Context, q string, _ []any) (SQLResult, error) {
			return SQLResult{Columns: []string{"n"}, Rows: []map[string]any{{"n": 42}}}, nil
		},
	}, "ping", map[string]any{"x": 1})
	if err != nil {
		t.Fatalf("CallMCPTool via VM: %v", err)
	}
	m, ok := res.(map[string]any)
	if !ok {
		t.Fatalf("unexpected result %#v", res)
	}
	if cols, _ := m["columns"].([]any); len(cols) != 1 || cols[0] != "n" {
		t.Fatalf("unexpected sql result: %#v", m)
	}

	vm.mu.Lock()
	defer vm.mu.Unlock()
	if len(vm.execReqs) != 1 {
		t.Fatalf("expected 1 VM exec, got %d", len(vm.execReqs))
	}
	req := vm.execReqs[0]
	if !req.App.AllowPublic || req.App.AppID != appID {
		t.Fatalf("unexpected VMAppSpec: %+v", req.App)
	}
	if len(req.Files) != 1 || !strings.HasSuffix(req.Files[0].Path, "/server.cjs") {
		t.Fatalf("expected server.cjs in VM files, got %+v", req.Files)
	}
	if len(vm.unlinked) != 1 || !strings.HasPrefix(vm.unlinked[0][0], "/tmp/vesper-app-mcp-") {
		t.Fatalf("expected callDir unlinked, got %+v", vm.unlinked)
	}
}

func TestNixRunsAndReadsFilesThroughVMBackend(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	u, err := store.New(pool).GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	wsID, userID := u.WorkspaceID, u.ID

	vm := newFakeVMBackend()
	svc := &Service{
		Pool: pool,
		Nix:  &Nix{Pool: pool},
	}
	svc.SetVM(vm)

	app, err := svc.Create(ctx, wsID, userID, CreateInput{
		Slug:  "nix-vm-app",
		Name:  "Nix VM App",
		Files: map[string]string{"app.tsx": "export default function App() { return null; }"},
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	vm.onStart = func(req VMExecRequest, stdin *io.PipeReader, stdout, _ *io.PipeWriter, _ <-chan struct{}) int {
		inBytes, _ := io.ReadAll(stdin)
		// Record an output file in the guest job working directory.
		cmd := req.Argv[len(req.Argv)-1]
		var workDir string
		for _, line := range strings.Split(cmd, "\n") {
			if strings.HasPrefix(line, "cd '") {
				workDir = strings.TrimSuffix(strings.TrimPrefix(line, "cd '"), "'")
			}
		}
		if workDir != "" {
			vm.mu.Lock()
			vm.files[workDir+"/out.txt"] = bytes.TrimSpace(inBytes)
			vm.mu.Unlock()
		}
		_, _ = io.WriteString(stdout, "hello-from-vm\n")
		return 0
	}

	job, err := svc.Nix.Run(ctx, app.ID, app.Slug, Mounts{"docs": t.TempDir()}, NixStartInput{
		Packages:    []string{"jq"},
		Command:     "jq",
		Args:        []string{"-r", "."},
		Stdin:       "payload-123",
		Mounts:      []string{"docs"},
		KeepFiles:   true,
		AllowPublic: false,
	})
	if err != nil {
		t.Fatalf("Nix.Run in VM: %v", err)
	}
	if job.State != "done" || strings.TrimSpace(job.Stdout) != "hello-from-vm" {
		t.Fatalf("unexpected job: %+v", job)
	}

	// ReadFile reads from guest VM and blocks .mounts/ traversal.
	got, err := svc.Nix.ReadFile(ctx, app.ID, job.ID, "out.txt", "utf8")
	if err != nil || got["content"] != "payload-123" {
		t.Fatalf("ReadFile = %#v, %v", got, err)
	}
	if _, err := svc.Nix.ReadFile(ctx, app.ID, job.ID, ".mounts/docs/secret.txt", "utf8"); err == nil {
		t.Fatal("expected .mounts readFile to be rejected")
	}

	// Delete unlinks the guest job dir.
	if err := svc.Nix.Delete(ctx, app.ID, job.ID); err != nil {
		t.Fatalf("Nix.Delete: %v", err)
	}

	// SetCapabilities syncs policy to VMBackend and Delete removes app VM.
	if _, err := svc.SetCapabilities(ctx, wsID, userID, app.Slug, Capabilities{"app.http:outbound": agentdef.Allowed}); err != nil {
		t.Fatalf("SetCapabilities: %v", err)
	}
	if err := svc.Delete(ctx, wsID, userID, app.Slug); err != nil {
		t.Fatalf("Delete: %v", err)
	}

	vm.mu.Lock()
	defer vm.mu.Unlock()
	if len(vm.synced) == 0 || !vm.synced[len(vm.synced)-1].AllowPublic {
		t.Fatalf("expected SyncAppVMPolicy with AllowPublic=true, got %+v", vm.synced)
	}
	if len(vm.deleted) != 1 || vm.deleted[0] != app.ID {
		t.Fatalf("expected DeleteAppVM(%s), got %+v", app.ID, vm.deleted)
	}
}

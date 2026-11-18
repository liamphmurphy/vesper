package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/devworkspace"
	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

var _ DevWorkspaceBackend = (*MicroVM)(nil)

type devWorkspaceVM struct {
	id     uuid.UUID
	vm     microvm.VM
	egress *microvm.Egress
}

func (b *MicroVM) devWorkspaceDir(id uuid.UUID) (string, error) {
	if b.StateDir == "" {
		return "", errors.New("microvm: StateDir is required")
	}
	return filepath.Join(b.StateDir, "dev-workspaces", id.String()), nil
}

func (b *MicroVM) devContainerID(id uuid.UUID) string {
	return "microvm-dev-" + id.String()
}

func (b *MicroVM) EnsureDevWorkspaceContainer(ctx context.Context, workspaceID uuid.UUID) (string, error) {
	b.devMu.Lock()
	if b.devVMs != nil {
		if dvm := b.devVMs[workspaceID]; dvm != nil && dvm.vm != nil {
			pctx, cancel := context.WithTimeout(ctx, 2*time.Second)
			_, perr := dvm.vm.Client().Ping(pctx)
			cancel()
			if perr == nil {
				b.devMu.Unlock()
				return b.devContainerID(workspaceID), nil
			}
			delete(b.devVMs, workspaceID)
			b.devMu.Unlock()
			_ = dvm.vm.Stop(context.Background())
			if dvm.egress != nil {
				_ = dvm.egress.Close()
			}
			b.devMu.Lock()
		}
	}
	b.devMu.Unlock()

	dir, err := b.devWorkspaceDir(workspaceID)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}

	wsSz := b.TestWorkspaceBytes
	if wsSz <= 0 {
		wsSz = wsTemplateSize
	}
	homeSz := b.TestHomeBytes
	if homeSz <= 0 {
		homeSz = homeTemplateSz
	}
	dkrSz := b.TestDockerBytes
	if dkrSz <= 0 {
		dkrSz = dkrTemplateSize
	}
	nixSz := b.TestNixBytes
	if nixSz <= 0 {
		nixSz = nixTemplateSize
	}
	for _, dspec := range []struct {
		file, tmpl, label string
		sz                int64
	}{
		{"workspace.ext4", "ws.ext4", wsDiskLabel, wsSz},
		{"home.ext4", "home.ext4", homeDiskLabel, homeSz},
		{"docker.ext4", "dkr.ext4", dkrDiskLabel, dkrSz},
		{"nix.ext4", "nix.ext4", nixDiskLabel, nixSz},
	} {
		dst := filepath.Join(dir, dspec.file)
		if _, serr := os.Stat(dst); serr == nil {
			continue
		}
		tmpl, terr := b.ensureExt4Template(ctx, dspec.tmpl, dspec.label, dspec.sz)
		if terr != nil {
			return "", terr
		}
		if cerr := cloneFile(tmpl, dst); cerr != nil {
			return "", cerr
		}
	}

	drives := []microvm.DriveSpec{
		{Path: b.RootfsPath, ReadOnly: true},
		{Path: filepath.Join(dir, "workspace.ext4"), ReadOnly: false},
		{Path: filepath.Join(dir, "home.ext4"), ReadOnly: false},
		{Path: filepath.Join(dir, "docker.ext4"), ReadOnly: false},
		{Path: filepath.Join(dir, "nix.ext4"), ReadOnly: false},
	}
	if b.CacheStore != nil {
		drives = append(drives, b.CacheStore.LatestEROFSDrives()...)
	}

	eg := microvm.NewEgress(microvm.EgressConfig{
		Log:           b.logger(),
		APIHandler:    b.apiHandler(),
		CacheHandler:  b.cacheHandler(),
		GitHandler:    b.GitHandler,
		Resolver:      b.Resolver,
		TestUpstreams: b.TestUpstreams,
	})
	cpus := b.CPUs
	if cpus <= 0 {
		cpus = 2
	}
	memMB := b.MemoryMB
	if memMB <= 0 {
		memMB = 2048
	}
	vm, err := b.Driver.Start(ctx, microvm.VMConfig{
		KernelPath:  b.KernelPath,
		CPUs:        cpus,
		MemoryBytes: uint64(memMB) << 20,
		Drives:      drives,
		Listeners:   eg.Listeners(),
	})
	if err != nil {
		_ = eg.Close()
		return "", err
	}
	if wf, ok := b.nixConfFileWrite(); ok {
		if werr := vm.Client().WriteFiles(ctx, []guestproto.FileWrite{wf}); werr != nil {
			_ = vm.Stop(context.Background())
			_ = eg.Close()
			return "", werr
		}
	}
	// nix-daemon reads nix.conf at start, so start it after the write above.
	if nerr := vm.Client().StartNixDaemon(ctx); nerr != nil {
		_ = vm.Stop(context.Background())
		_ = eg.Close()
		return "", nerr
	}

	b.devMu.Lock()
	if b.devVMs == nil {
		b.devVMs = make(map[uuid.UUID]*devWorkspaceVM)
	}
	b.devVMs[workspaceID] = &devWorkspaceVM{id: workspaceID, vm: vm, egress: eg}
	b.devMu.Unlock()
	return b.devContainerID(workspaceID), nil
}

func (b *MicroVM) findDevVM(containerID string) (*devWorkspaceVM, error) {
	idStr := strings.TrimPrefix(containerID, "microvm-dev-")
	wsID, err := uuid.Parse(idStr)
	if err != nil {
		return nil, fmt.Errorf("invalid dev workspace container id %q: %w", containerID, err)
	}
	b.devMu.Lock()
	dvm := b.devVMs[wsID]
	b.devMu.Unlock()
	if dvm == nil || dvm.vm == nil {
		return nil, fmt.Errorf("dev workspace VM %s is not running", wsID)
	}
	return dvm, nil
}

// devShellEnv is the environment shared by dev workspace scripts and PTYs.
func (b *MicroVM) devShellEnv() map[string]string {
	envMap := map[string]string{
		"HOME":       homePath,
		"USER":       "node",
		"LOGNAME":    "node",
		"TMPDIR":     "/tmp",
		"LANG":       devTerminalLang,
		"NIX_REMOTE": "daemon",
		"PATH":       devworkspace.ProfilePath + "/bin:" + homePath + "/.nix-profile/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin",
	}
	b.applyCacheEnv(envMap)
	return envMap
}

func (b *MicroVM) ExecDevWorkspaceScript(ctx context.Context, containerID, script string, env []string) (string, int, error) {
	dvm, err := b.findDevVM(containerID)
	if err != nil {
		return "", -1, err
	}
	sctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()

	envMap := b.devShellEnv()
	for _, kv := range env {
		if k, v, ok := strings.Cut(kv, "="); ok && k != "" {
			envMap[k] = v
		}
	}

	rp, err := dvm.vm.Client().StartExec(sctx, guestproto.ExecReq{
		Argv: []string{"sh", "-c", script},
		Env:  envMap,
		Dir:  workspacePath,
		UID:  1000,
		GID:  1000,
	})
	if err != nil {
		return "", -1, err
	}
	_ = rp.Stdin().Close()

	var mu sync.Mutex
	var combined bytes.Buffer
	appendLimited := func(r io.Reader) {
		buf := make([]byte, 16<<10)
		for {
			n, rerr := r.Read(buf)
			if n > 0 {
				mu.Lock()
				if combined.Len() < 4<<20 {
					combined.Write(buf[:n])
				}
				mu.Unlock()
			}
			if rerr != nil {
				return
			}
		}
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); appendLimited(rp.Stdout()) }()
	go func() { defer wg.Done(); appendLimited(rp.Stderr()) }()
	wg.Wait()

	ex, werr := rp.Wait()
	if werr != nil {
		return combined.String(), -1, werr
	}
	if ex.Error != "" && ex.Code == 0 {
		return combined.String(), 1, errors.New(ex.Error)
	}
	return combined.String(), ex.Code, nil
}

func (b *MicroVM) StopDevWorkspaceContainer(ctx context.Context, workspaceID uuid.UUID) error {
	b.devMu.Lock()
	dvm := b.devVMs[workspaceID]
	if dvm != nil {
		delete(b.devVMs, workspaceID)
	}
	b.devMu.Unlock()
	if dvm == nil {
		return nil
	}
	var err error
	if dvm.vm != nil {
		sctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err = dvm.vm.Stop(sctx)
		cancel()
	}
	if dvm.egress != nil {
		_ = dvm.egress.Close()
	}
	return err
}

func (b *MicroVM) OpenDevWorkspacePTY(ctx context.Context, workspaceID uuid.UUID, cols, rows int) (DevPTY, error) {
	if _, err := b.EnsureDevWorkspaceContainer(ctx, workspaceID); err != nil {
		return nil, err
	}
	b.devMu.Lock()
	dvm := b.devVMs[workspaceID]
	b.devMu.Unlock()
	if dvm == nil || dvm.vm == nil {
		return nil, fmt.Errorf("dev workspace VM %s is not running", workspaceID)
	}

	rCols, rRows := uint16(80), uint16(24)
	if cols > 0 {
		rCols = uint16(cols)
	}
	if rows > 0 {
		rRows = uint16(rows)
	}
	envMap := b.devShellEnv()
	envMap["TERM"] = "xterm-256color"

	cmd := "if command -v tmux >/dev/null 2>&1; then exec tmux -u new-session -A -s main; fi; exec bash -l"
	rp, err := dvm.vm.Client().StartExec(ctx, guestproto.ExecReq{
		Argv: []string{"sh", "-c", cmd},
		Env:  envMap,
		Dir:  workspacePath,
		UID:  1000,
		GID:  1000,
		TTY:  true,
		Rows: rRows,
		Cols: rCols,
	})
	if err != nil {
		return nil, err
	}
	return &microvmDevPTY{rp: rp, stdin: rp.Stdin()}, nil
}

type microvmDevPTY struct {
	rp    *guestproto.RemoteProcess
	stdin io.WriteCloser
}

func (p *microvmDevPTY) Read(buf []byte) (int, error)  { return p.rp.Stdout().Read(buf) }
func (p *microvmDevPTY) Write(buf []byte) (int, error) { return p.stdin.Write(buf) }
func (p *microvmDevPTY) Resize(_ context.Context, cols, rows int) error {
	if cols <= 0 || rows <= 0 {
		return nil
	}
	return p.rp.Resize(uint16(rows), uint16(cols))
}
func (p *microvmDevPTY) Close() error {
	_ = p.stdin.Close()
	_ = p.rp.Signal(1) // SIGHUP
	return nil
}

func (b *MicroVM) cleanupDevWorkspaces(ctx context.Context) {
	b.devMu.Lock()
	list := make([]*devWorkspaceVM, 0, len(b.devVMs))
	for id, dvm := range b.devVMs {
		list = append(list, dvm)
		delete(b.devVMs, id)
	}
	b.devMu.Unlock()
	for _, dvm := range list {
		if dvm.vm != nil {
			_ = dvm.vm.Stop(ctx)
		}
		if dvm.egress != nil {
			_ = dvm.egress.Close()
		}
	}
}

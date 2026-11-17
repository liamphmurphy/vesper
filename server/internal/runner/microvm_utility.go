package runner

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"path"
	"strings"
	"sync"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
	"github.com/liamphmurphy/vesper/server/internal/usage"
)

var (
	_ LoginStarter = (*MicroVM)(nil)
	_ ModelLister  = (*MicroVM)(nil)
	_ UsageProber  = (*MicroVM)(nil)
)

func (b *MicroVM) initSemaphores() {
	b.semOnce.Do(func() {
		b.listSem = make(chan struct{}, maxConcurrentListings)
		b.usageSem = make(chan struct{}, maxConcurrentUsageChecks)
	})
}

// bootUtilityVM starts a minimal ephemeral microVM with only agent-base.erofs
// (no workspace.ext4 or home.ext4), so /home/node lives solely on tmpfs and
// is wiped automatically when the VM stops.
func (b *MicroVM) bootUtilityVM(ctx context.Context) (microvm.VM, *microvm.Egress, error) {
	if b.Driver == nil {
		return nil, nil, errors.New("microvm: Driver is required")
	}
	eg := microvm.NewEgress(microvm.EgressConfig{
		Log:           b.logger(),
		CacheHandler:  b.cacheHandler(),
		Resolver:      b.Resolver,
		TestUpstreams: b.TestUpstreams,
	})
	vm, err := b.Driver.Start(ctx, microvm.VMConfig{
		KernelPath:  b.KernelPath,
		CPUs:        1,
		MemoryBytes: 512 << 20,
		Drives: []microvm.DriveSpec{
			{Path: b.RootfsPath, ReadOnly: true},
		},
		Listeners: eg.Listeners(),
	})
	if err != nil {
		_ = eg.Close()
		return nil, nil, err
	}
	return vm, eg, nil
}

func (b *MicroVM) utilityBaseEnv(extra map[string]string) map[string]string {
	env := map[string]string{
		"HOME":    homePath,
		"USER":    "node",
		"LOGNAME": "node",
		"TMPDIR":  "/tmp",
		"PATH":    homePath + "/.nix-profile/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin",
	}
	for k, v := range extra {
		env[k] = v
	}
	return env
}

func (b *MicroVM) StartLogin(ctx context.Context, spec LoginSpec) (LoginProcess, error) {
	vm, eg, err := b.bootUtilityVM(ctx)
	if err != nil {
		return nil, err
	}

	env := b.utilityBaseEnv(spec.Env)
	if spec.TTY {
		if _, ok := env["TERM"]; !ok {
			env["TERM"] = "xterm-256color"
		}
	}

	rp, err := vm.Client().StartExec(ctx, guestproto.ExecReq{
		Argv: spec.Argv,
		Env:  env,
		Dir:  homePath,
		UID:  1000,
		GID:  1000,
		TTY:  spec.TTY,
		Rows: 24,
		Cols: 120,
	})
	if err != nil {
		_ = vm.Stop(context.Background())
		_ = eg.Close()
		return nil, err
	}

	pr, pw := io.Pipe()
	var pipeWG sync.WaitGroup
	pipeWG.Add(2)
	go func() {
		defer pipeWG.Done()
		_, _ = io.Copy(pw, rp.Stdout())
	}()
	go func() {
		defer pipeWG.Done()
		_, _ = io.Copy(pw, rp.Stderr())
	}()
	go func() {
		pipeWG.Wait()
		_ = pw.Close()
	}()

	var in io.Writer
	if spec.TTY {
		in = rp.Stdin()
	} else {
		_ = rp.Stdin().Close()
	}

	return &microvmLoginProc{
		vm:     vm,
		egress: eg,
		rp:     rp,
		out:    pr,
		in:     in,
	}, nil
}

type microvmLoginProc struct {
	vm        microvm.VM
	egress    *microvm.Egress
	rp        *guestproto.RemoteProcess
	out       io.Reader
	in        io.Writer
	closeOnce sync.Once
}

func (p *microvmLoginProc) Output() io.Reader { return p.out }
func (p *microvmLoginProc) Input() io.Writer  { return p.in }
func (p *microvmLoginProc) Kill() error       { return p.rp.Signal(9) }

func (p *microvmLoginProc) Wait() (int, error) {
	ex, err := p.rp.Wait()
	if err != nil {
		return -1, err
	}
	if ex.Error != "" && ex.Code == 0 {
		return 1, errors.New(ex.Error)
	}
	return ex.Code, nil
}

func (p *microvmLoginProc) ReadFile(ctx context.Context, file string) ([]byte, error) {
	if p.vm == nil {
		return nil, errors.New("microvm login closed")
	}
	guestPath := file
	if !strings.HasPrefix(guestPath, "/") {
		guestPath = path.Join(homePath, guestPath)
	} else {
		guestPath = path.Clean(guestPath)
	}
	return p.vm.Client().ReadFile(ctx, guestPath, 2<<20)
}

// ReadHomeFiles captures matching files under /home/node (implements homeReader for Antigravity).
func (p *microvmLoginProc) ReadHomeFiles(ctx context.Context, keep func(rel string, size int64) bool) (map[string][]byte, error) {
	if p.vm == nil {
		return nil, errors.New("microvm login closed")
	}
	client := p.vm.Client()
	entries, err := client.WalkDir(ctx, homePath, 0)
	if err != nil {
		return nil, err
	}
	files := make(map[string][]byte)
	for _, ent := range entries {
		if ent.IsDir {
			continue
		}
		rel := strings.TrimPrefix(ent.Rel, "/")
		if rel == "" || rel == "." {
			continue
		}
		if keep != nil && !keep(rel, ent.Size) {
			continue
		}
		data, rerr := client.ReadFile(ctx, path.Join(homePath, rel), ent.Size+1)
		if rerr != nil {
			continue
		}
		files[rel] = data
	}
	return files, nil
}

func (p *microvmLoginProc) Close() {
	p.closeOnce.Do(func() {
		if p.rp != nil {
			_ = p.rp.Stdin().Close()
			_ = p.rp.Signal(9)
		}
		if p.vm != nil {
			sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_ = p.vm.Stop(sctx)
			cancel()
		}
		if p.egress != nil {
			_ = p.egress.Close()
		}
	})
}

func (b *MicroVM) ListModels(ctx context.Context, _ string, harness, login, codexScope string) ([]chatmodels.Model, error) {
	argv, err := chatmodels.DiscoveryArgv(harness)
	if err != nil {
		return nil, err
	}
	b.initSemaphores()
	select {
	case b.listSem <- struct{}{}:
		defer func() { <-b.listSem }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}

	timeout := b.ModelsTimeout
	if timeout <= 0 {
		timeout = listModelsTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var models []chatmodels.Model
	err = b.converseUtilityCLI(ctx, harness, login, codexScope, argv, func(in io.Writer, out io.Reader) error {
		var lerr error
		models, lerr = chatmodels.ListOverStdio(harness, in, out)
		return lerr
	})
	return models, err
}

func (b *MicroVM) ProbeUsage(ctx context.Context, _ string, harness, login, codexScope string) (usage.Snapshot, error) {
	argv, err := usage.Argv(harness)
	if err != nil {
		return usage.Snapshot{}, err
	}
	b.initSemaphores()
	select {
	case b.usageSem <- struct{}{}:
		defer func() { <-b.usageSem }()
	case <-ctx.Done():
		return usage.Snapshot{}, ctx.Err()
	}

	timeout := b.UsageTimeout
	if timeout <= 0 {
		timeout = probeUsageTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	var snap usage.Snapshot
	var answer error
	err = b.converseUtilityCLI(ctx, harness, login, codexScope, argv, func(in io.Writer, out io.Reader) error {
		snap, answer = usage.Converse(harness, in, out)
		return nil
	})
	if err != nil {
		return usage.Snapshot{}, err
	}
	return snap, answer
}

func (b *MicroVM) converseUtilityCLI(ctx context.Context, harness, login, codexScope string, argv []string, converse func(in io.Writer, out io.Reader) error) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	vm, eg, err := b.bootUtilityVM(ctx)
	if err != nil {
		return err
	}
	defer func() {
		sctx, scancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = vm.Stop(sctx)
		scancel()
		_ = eg.Close()
	}()

	env := b.utilityBaseEnv(nil)
	var writes []guestproto.FileWrite
	switch harness {
	case agentdef.HarnessClaudeCode:
		if chatmodels.ClaudeOAuthToken(login) {
			env[ClaudeOAuthEnv] = login
		} else if _, ok := chatmodels.ParseClaudeAuth(login); ok {
			writes = append(writes, guestproto.FileWrite{
				Path: path.Join(homePath, claudeAuthPath),
				Data: []byte(login),
				Mode: 0o600,
				UID:  1000,
				GID:  1000,
			})
		}
	case agentdef.HarnessCodex:
		if _, ok := chatmodels.ParseCodexAuth(login); ok {
			writes = append(writes, guestproto.FileWrite{
				Path: path.Join(homePath, codexAuthPath),
				Data: []byte(login),
				Mode: 0o600,
				UID:  1000,
				GID:  1000,
			})
		}
	case agentdef.HarnessAntigravity:
		auth, ok := chatmodels.ParseAntigravityAuth(login)
		if ok {
			for rel, content := range auth.Files {
				cleanRel, cleanOK := chatmodels.CleanAntigravityRelPath(rel)
				if !cleanOK {
					continue
				}
				writes = append(writes, guestproto.FileWrite{
					Path: path.Join(homePath, cleanRel),
					Data: []byte(content),
					Mode: 0o600,
					UID:  1000,
					GID:  1000,
				})
			}
		}
	}

	rp, err := vm.Client().StartExec(ctx, guestproto.ExecReq{
		Argv:  argv,
		Env:   env,
		Dir:   homePath,
		UID:   1000,
		GID:   1000,
		Files: writes,
	})
	if err != nil {
		return err
	}

	stderrBuf := cappedBuffer{limit: 64 << 10}
	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		_, _ = io.Copy(&stderrBuf, rp.Stderr())
	}()

	stdin := rp.Stdin()
	if harness == agentdef.HarnessAntigravity {
		_ = stdin.Close()
	}

	outR, outW := io.Pipe()
	go func() {
		_, _ = io.Copy(outW, rp.Stdout())
		_ = outW.Close()
	}()

	cerr := converse(stdin, outR)
	_ = outR.Close()
	_ = stdin.Close()

	waitCh := make(chan error, 1)
	go func() {
		ex, werr := rp.Wait()
		if werr != nil {
			waitCh <- werr
			return
		}
		if ex.Code != 0 {
			waitCh <- fmt.Errorf("cli exited %d", ex.Code)
			return
		}
		waitCh <- nil
	}()
	select {
	case <-waitCh:
	case <-time.After(listExitWait):
		_ = rp.Signal(9)
	}
	<-stderrDone

	// Read refreshed Claude/Codex credentials back after CLI exits, before VM destruction.
	rctx, rcancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer rcancel()
	if harness == agentdef.HarnessClaudeCode && b.SaveClaudeAuth != nil {
		if _, ok := chatmodels.ParseClaudeAuth(login); ok {
			if raw, rerr := vm.Client().ReadFile(rctx, path.Join(homePath, claudeAuthPath), maxAuthReadBytes+1); rerr == nil && len(raw) <= maxAuthReadBytes {
				if next := string(raw); chatmodels.ClaudeAuthRefreshed(login, next) {
					if serr := b.SaveClaudeAuth(rctx, codexScope, next); serr != nil {
						slog.Warn("save refreshed claude login", "err", serr)
					}
				}
			}
		}
	}
	if harness == agentdef.HarnessCodex && b.SaveCodexAuth != nil {
		if _, ok := chatmodels.ParseCodexAuth(login); ok {
			if raw, rerr := vm.Client().ReadFile(rctx, path.Join(homePath, codexAuthPath), maxAuthReadBytes+1); rerr == nil && len(raw) <= maxAuthReadBytes {
				if next := string(raw); chatmodels.CodexAuthRefreshed(login, next) {
					if serr := b.SaveCodexAuth(rctx, codexScope, next); serr != nil {
						slog.Warn("save refreshed codex login", "err", serr)
					}
				}
			}
		}
	}

	if cerr != nil {
		if msg := cleanCLIStderr(stderrBuf.buf.String()); msg != "" {
			return fmt.Errorf("%w: %s", cerr, msg)
		}
		return cerr
	}
	return nil
}

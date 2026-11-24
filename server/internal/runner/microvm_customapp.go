package runner

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

var _ customapps.VMBackend = (*MicroVM)(nil)

const (
	defaultCustomAppCPUs           = 2
	defaultCustomAppMemoryMB       = 1024
	defaultCustomAppMaxVMs         = 4
	defaultCustomAppIdlePauseDelay = 45 * time.Second
	defaultCustomAppIdleStopTTL    = 10 * time.Minute
	defaultCustomAppWindowCloseLag = 2 * time.Second
	customAppWorkTemplateSize      = 16 << 30 // 16 GiB sparse APFS ext4 image
)

type customAppVM struct {
	appID uuid.UUID
	slug  string

	mu              sync.Mutex
	vm              microvm.VM
	egress          *microvm.Egress
	vmGen           uint64
	activeCalls     int
	mountHash       string
	mountCount      int
	allowPublic     atomic.Bool
	bootedAt        time.Time
	lastUsedAt      time.Time
	pausedAt        time.Time
	idlePauseTimer  *time.Timer
	pauseSettleTmr  *time.Timer
	idleStopTimer   *time.Timer
}

func (b *MicroVM) customAppCPUs() int {
	if b.CustomAppCPUs > 0 {
		return b.CustomAppCPUs
	}
	return defaultCustomAppCPUs
}

func (b *MicroVM) customAppMemoryMB() int64 {
	if b.CustomAppMemoryMB > 0 {
		return b.CustomAppMemoryMB
	}
	return defaultCustomAppMemoryMB
}

func (b *MicroVM) customAppMaxVMs() int {
	if b.CustomAppMaxVMs > 0 {
		return b.CustomAppMaxVMs
	}
	return defaultCustomAppMaxVMs
}

func (b *MicroVM) customAppIdlePauseDelay() time.Duration {
	if b.CustomAppIdlePauseDelay > 0 {
		return b.CustomAppIdlePauseDelay
	}
	return defaultCustomAppIdlePauseDelay
}

func (b *MicroVM) customAppIdleStopTTL() time.Duration {
	if b.CustomAppIdleStopTTL > 0 {
		return b.CustomAppIdleStopTTL
	}
	return defaultCustomAppIdleStopTTL
}

func (b *MicroVM) customAppDir(appID uuid.UUID) (string, error) {
	if b.StateDir == "" {
		return "", errors.New("microvm: StateDir is required")
	}
	return filepath.Join(b.StateDir, "custom-apps", appID.String()), nil
}

func (b *MicroVM) getOrCreateCustomAppEntry(appID uuid.UUID, slug string) *customAppVM {
	b.customAppMu.Lock()
	defer b.customAppMu.Unlock()
	if b.customApps == nil {
		b.customApps = make(map[uuid.UUID]*customAppVM)
	}
	if avm := b.customApps[appID]; avm != nil {
		if slug != "" {
			avm.slug = slug
		}
		return avm
	}
	avm := &customAppVM{appID: appID, slug: slug}
	b.customApps[appID] = avm
	return avm
}

func (b *MicroVM) lookupCustomAppEntry(appID uuid.UUID) *customAppVM {
	b.customAppMu.Lock()
	defer b.customAppMu.Unlock()
	return b.customApps[appID]
}

// resolveCustomAppMounts expands ~/ paths, validates each directory exists,
// and returns sorted VirtioFSSpec shares plus a deterministic fingerprint.
func resolveCustomAppMounts(mounts customapps.Mounts) ([]microvm.VirtioFSSpec, string, error) {
	if len(mounts) == 0 {
		return nil, "", nil
	}
	names := make([]string, 0, len(mounts))
	for name := range mounts {
		names = append(names, name)
	}
	sort.Strings(names)

	homeDir, _ := os.UserHomeDir()
	h := sha256.New()
	shares := make([]microvm.VirtioFSSpec, 0, len(names))
	for _, name := range names {
		raw := strings.TrimSpace(mounts[name])
		if raw == "" {
			continue
		}
		expanded := raw
		if raw == "~" || strings.HasPrefix(raw, "~/") {
			if homeDir == "" {
				return nil, "", fmt.Errorf("custom app mount %q: cannot resolve home directory", name)
			}
			expanded = filepath.Join(homeDir, strings.TrimPrefix(raw, "~/"))
		}
		abs, err := filepath.Abs(expanded)
		if err != nil {
			return nil, "", fmt.Errorf("custom app mount %q: %w", name, err)
		}
		if eval, err := filepath.EvalSymlinks(abs); err == nil {
			abs = eval
		}
		info, err := os.Stat(abs)
		if err != nil {
			return nil, "", fmt.Errorf("custom app mount %q (%s): %w", name, abs, err)
		}
		if !info.IsDir() {
			return nil, "", fmt.Errorf("custom app mount %q (%s): not a directory", name, abs)
		}
		shares = append(shares, microvm.VirtioFSSpec{
			Tag:      "mount-" + name,
			HostDir:  abs,
			ReadOnly: true,
		})
		_, _ = io.WriteString(h, name+"="+abs+"\n")
	}
	return shares, hex.EncodeToString(h.Sum(nil)), nil
}

// acquireCustomAppVM ensures the app's microVM is booted and resumed, holding
// an active lease (activeCalls++) until releaseCustomAppVM is called.
func (b *MicroVM) acquireCustomAppVM(ctx context.Context, spec customapps.VMAppSpec) (*customAppVM, microvm.VM, error) {
	if b.Driver == nil {
		return nil, nil, errors.New("microvm: driver is not configured")
	}
	shares, mountHash, err := resolveCustomAppMounts(spec.Mounts)
	if err != nil {
		return nil, nil, err
	}

	avm := b.getOrCreateCustomAppEntry(spec.AppID, spec.Slug)
	avm.allowPublic.Store(spec.AllowPublic)

	avm.mu.Lock()
	avm.cancelTimersLocked()

	// If already running/paused with matching mounts, resume if needed and take lease.
	if avm.vm != nil {
		if avm.mountHash == mountHash {
			vm := avm.vm
			pausedAt := avm.pausedAt
			avm.activeCalls++
			avm.lastUsedAt = time.Now()
			if !pausedAt.IsZero() {
				avm.pausedAt = time.Time{}
				if p, ok := vm.(microvm.Pauser); ok {
					if rerr := p.Resume(ctx); rerr != nil {
						avm.activeCalls--
						avm.mu.Unlock()
						// Fall through to cold reboot below on broken resume.
						b.stopCustomAppVM(context.Background(), avm)
						return b.acquireCustomAppVM(ctx, spec)
					}
				}
				_ = vm.SetMemoryTarget(uint64(b.customAppMemoryMB()) << 20)
				if time.Since(pausedAt) >= b.clockSyncAfter() {
					go b.syncGuestClock(context.Background(), vm)
				}
			}
			avm.mu.Unlock()
			return avm, vm, nil
		}

		// Mounts changed: if idle, stop and reboot with new shares; if busy, fail clearly.
		if avm.activeCalls > 0 {
			avm.mu.Unlock()
			return nil, nil, errors.New("custom app mounts changed while another call is in flight; retry once idle or restart the app VM")
		}
		oldVM, oldEg := avm.detachLocked()
		avm.mu.Unlock()
		stopCustomAppResources(context.Background(), oldVM, oldEg)
	} else {
		avm.mu.Unlock()
	}

	// Enforce CustomAppMaxVMs by evicting the least-recently-used idle VM.
	if err := b.evictCustomAppVMIfNeeded(ctx, spec.AppID); err != nil {
		return nil, nil, err
	}

	vm, eg, err := b.bootCustomAppVM(ctx, avm, shares)
	if err != nil {
		return nil, nil, err
	}

	avm.mu.Lock()
	// Guard against a concurrent caller booting the same app VM simultaneously.
	if avm.vm != nil {
		existing := avm.vm
		avm.activeCalls++
		avm.lastUsedAt = time.Now()
		avm.mu.Unlock()
		stopCustomAppResources(context.Background(), vm, eg)
		return avm, existing, nil
	}
	now := time.Now()
	avm.vm = vm
	avm.egress = eg
	avm.vmGen++
	avm.mountHash = mountHash
	avm.mountCount = len(shares)
	avm.bootedAt = now
	avm.lastUsedAt = now
	avm.pausedAt = time.Time{}
	avm.activeCalls = 1
	avm.mu.Unlock()
	return avm, vm, nil
}

func (b *MicroVM) releaseCustomAppVM(avm *customAppVM) {
	avm.mu.Lock()
	if avm.activeCalls > 0 {
		avm.activeCalls--
	}
	avm.lastUsedAt = time.Now()
	if avm.activeCalls == 0 && avm.vm != nil {
		b.scheduleCustomAppIdlePauseLocked(avm, b.customAppIdlePauseDelay())
	}
	avm.mu.Unlock()
}

func (b *MicroVM) evictCustomAppVMIfNeeded(ctx context.Context, excludeAppID uuid.UUID) error {
	maxVMs := b.customAppMaxVMs()

	b.customAppMu.Lock()
	candidates := make([]*customAppVM, 0, len(b.customApps))
	for id, avm := range b.customApps {
		if id != excludeAppID {
			candidates = append(candidates, avm)
		}
	}
	b.customAppMu.Unlock()

	var runningCount int
	var lru *customAppVM
	var lruUsed time.Time
	for _, avm := range candidates {
		avm.mu.Lock()
		if avm.vm != nil {
			runningCount++
			if avm.activeCalls == 0 && (lru == nil || avm.lastUsedAt.Before(lruUsed)) {
				lru = avm
				lruUsed = avm.lastUsedAt
			}
		}
		avm.mu.Unlock()
	}

	if runningCount < maxVMs {
		return nil
	}
	if lru == nil {
		return fmt.Errorf("custom app VM limit reached (%d active apps); wait for an active call to finish or stop an app VM", maxVMs)
	}
	b.stopCustomAppVM(ctx, lru)
	return nil
}

func (b *MicroVM) bootCustomAppVM(ctx context.Context, avm *customAppVM, shares []microvm.VirtioFSSpec) (microvm.VM, *microvm.Egress, error) {
	dir, err := b.customAppDir(avm.appID)
	if err != nil {
		return nil, nil, err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, nil, err
	}

	workPath := filepath.Join(dir, "work.ext4")
	if _, serr := os.Stat(workPath); errors.Is(serr, os.ErrNotExist) {
		workSz := b.TestCustomAppWorkBytes
		if workSz <= 0 {
			workSz = customAppWorkTemplateSize
		}
		tmpl, terr := b.ensureExt4Template(ctx, "customapp-ws.ext4", wsDiskLabel, workSz)
		if terr != nil {
			return nil, nil, fmt.Errorf("prepare custom app work template: %w", terr)
		}
		if cerr := cloneFile(tmpl, workPath); cerr != nil {
			return nil, nil, fmt.Errorf("clone custom app work disk: %w", cerr)
		}
	}

	// Security invariant: never attach home.ext4 so /home/node stays an empty
	// tmpfs overlay isolated from harness OAuth credentials, and never expose
	// APIHandler/GitHandler/MacHandler to the guest egress proxy.
	drives := []microvm.DriveSpec{
		{Path: b.RootfsPath, ReadOnly: true},
		{Path: workPath, ReadOnly: false},
	}
	if b.CacheStore != nil {
		drives = append(drives, b.CacheStore.LatestEROFSDrives()...)
	}

	eg := microvm.NewEgress(microvm.EgressConfig{
		Log:           b.logger(),
		CacheHandler:  b.cacheHandler(),
		Resolver:      b.Resolver,
		TestUpstreams: b.TestUpstreams,
		AllowPublic:   avm.allowPublic.Load,
	})

	vm, err := b.Driver.Start(ctx, microvm.VMConfig{
		KernelPath:  b.KernelPath,
		CPUs:        b.customAppCPUs(),
		MemoryBytes: uint64(b.customAppMemoryMB()) << 20,
		Drives:      drives,
		Shares:      shares,
		Listeners:   eg.Listeners(),
	})
	if err != nil {
		_ = eg.Close()
		return nil, nil, fmt.Errorf("boot custom app VM: %w", err)
	}

	if client := vm.Client(); client != nil {
		b.trustNewVM(ctx, client)
		if wf, ok := b.nixConfFileWrite(); ok {
			_ = client.WriteFiles(ctx, []guestproto.FileWrite{wf})
		}
		if len(shares) > 0 {
			if merr := mountCustomAppVirtioShares(ctx, client, shares); merr != nil {
				stopCustomAppResources(context.Background(), vm, eg)
				return nil, nil, fmt.Errorf("mount custom app host shares: %w", merr)
			}
		}
		_ = client.StartNixDaemon(ctx)
	}

	return vm, eg, nil
}

func mountCustomAppVirtioShares(ctx context.Context, client *guestproto.Client, shares []microvm.VirtioFSSpec) error {
	var script strings.Builder
	script.WriteString("set -e\nmkdir -p /mounts\n")
	for _, s := range shares {
		name := strings.TrimPrefix(s.Tag, "mount-")
		if name == "" || strings.ContainsAny(name, "/'\"\\ \t\n") {
			return fmt.Errorf("invalid mount tag %q", s.Tag)
		}
		fmt.Fprintf(&script, "mkdir -p /mounts/%s && mount -t virtiofs -o ro,nosuid,nodev %s /mounts/%s\n", name, s.Tag, name)
	}
	rp, err := client.StartExec(ctx, guestproto.ExecReq{
		Argv: []string{"/bin/sh", "-c", script.String()},
		UID:  0,
		GID:  0,
	})
	if err != nil {
		return err
	}
	defer rp.Close()
	go func() { _, _ = io.Copy(io.Discard, rp.Stdout()) }()
	stderr, _ := io.ReadAll(io.LimitReader(rp.Stderr(), 4096))
	exit, werr := rp.Wait()
	if werr != nil {
		return werr
	}
	if exit.Code != 0 {
		return fmt.Errorf("mount exited %d: %s", exit.Code, strings.TrimSpace(string(stderr)))
	}
	return nil
}

func (avm *customAppVM) cancelTimersLocked() {
	if avm.idlePauseTimer != nil {
		avm.idlePauseTimer.Stop()
		avm.idlePauseTimer = nil
	}
	if avm.pauseSettleTmr != nil {
		avm.pauseSettleTmr.Stop()
		avm.pauseSettleTmr = nil
	}
	if avm.idleStopTimer != nil {
		avm.idleStopTimer.Stop()
		avm.idleStopTimer = nil
	}
}

func (avm *customAppVM) detachLocked() (microvm.VM, *microvm.Egress) {
	avm.cancelTimersLocked()
	vm, eg := avm.vm, avm.egress
	avm.vm = nil
	avm.egress = nil
	avm.vmGen++
	avm.pausedAt = time.Time{}
	avm.bootedAt = time.Time{}
	avm.mountHash = ""
	avm.mountCount = 0
	return vm, eg
}

func stopCustomAppResources(ctx context.Context, vm microvm.VM, eg *microvm.Egress) {
	if vm != nil {
		sctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		_ = vm.Stop(sctx)
		cancel()
	}
	if eg != nil {
		_ = eg.Close()
	}
}

func (b *MicroVM) stopCustomAppVM(ctx context.Context, avm *customAppVM) {
	avm.mu.Lock()
	vm, eg := avm.detachLocked()
	avm.mu.Unlock()
	stopCustomAppResources(ctx, vm, eg)
}

func (b *MicroVM) scheduleCustomAppIdlePauseLocked(avm *customAppVM, delay time.Duration) {
	avm.cancelTimersLocked()
	gen := avm.vmGen
	avm.idlePauseTimer = time.AfterFunc(delay, func() {
		b.balloonAndPauseCustomAppVM(avm, gen)
	})
}

func (b *MicroVM) balloonAndPauseCustomAppVM(avm *customAppVM, gen uint64) {
	avm.mu.Lock()
	if avm.activeCalls != 0 || avm.vm == nil || avm.vmGen != gen {
		avm.mu.Unlock()
		return
	}
	avm.idlePauseTimer = nil
	vm := avm.vm
	avm.mu.Unlock()

	if client := vm.Client(); client != nil {
		dctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = client.SyncAndDropCaches(dctx)
		cancel()
	}

	idleMB := b.idleMemoryMB()
	memMB := b.customAppMemoryMB()

	avm.mu.Lock()
	if avm.activeCalls != 0 || avm.vm == nil || avm.vmGen != gen {
		avm.mu.Unlock()
		return
	}
	if idleMB < memMB {
		_ = avm.vm.SetMemoryTarget(uint64(idleMB) << 20)
	}
	_, canPause := avm.vm.(microvm.Pauser)
	if canPause && b.PauseSettleDelay > 0 {
		avm.pauseSettleTmr = time.AfterFunc(b.PauseSettleDelay, func() {
			b.pauseCustomAppVM(avm, gen)
		})
		avm.mu.Unlock()
		return
	}
	avm.mu.Unlock()
	if canPause {
		b.pauseCustomAppVM(avm, gen)
	} else {
		avm.mu.Lock()
		if avm.activeCalls == 0 && avm.vm != nil && avm.vmGen == gen {
			avm.idleStopTimer = time.AfterFunc(b.customAppIdleStopTTL(), func() {
				b.stopCustomAppVMIfIdle(avm, gen)
			})
		}
		avm.mu.Unlock()
	}
}

func (b *MicroVM) pauseCustomAppVM(avm *customAppVM, gen uint64) {
	avm.mu.Lock()
	defer avm.mu.Unlock()
	if avm.activeCalls != 0 || avm.vm == nil || avm.vmGen != gen {
		return
	}
	avm.pauseSettleTmr = nil
	p, ok := avm.vm.(microvm.Pauser)
	if !ok {
		return
	}
	pctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := p.Pause(pctx); err != nil {
		b.logger().Warn("microvm: pause idle custom app vm", "app", avm.appID, "err", err)
		return
	}
	avm.pausedAt = time.Now()
	avm.idleStopTimer = time.AfterFunc(b.customAppIdleStopTTL(), func() {
		b.stopCustomAppVMIfIdle(avm, gen)
	})
}

func (b *MicroVM) stopCustomAppVMIfIdle(avm *customAppVM, gen uint64) {
	avm.mu.Lock()
	if avm.activeCalls != 0 || avm.vm == nil || avm.vmGen != gen {
		avm.mu.Unlock()
		return
	}
	vm, eg := avm.detachLocked()
	avm.mu.Unlock()
	stopCustomAppResources(context.Background(), vm, eg)
}

type customAppVMProcess struct {
	b         *MicroVM
	avm       *customAppVM
	rp        *guestproto.RemoteProcess
	closeOnce sync.Once
}

func (p *customAppVMProcess) Stdin() io.WriteCloser { return p.rp.Stdin() }
func (p *customAppVMProcess) Stdout() io.Reader     { return p.rp.Stdout() }
func (p *customAppVMProcess) Stderr() io.Reader     { return p.rp.Stderr() }

func (p *customAppVMProcess) Kill(grace time.Duration) error {
	return p.rp.Kill(grace)
}

func (p *customAppVMProcess) Wait() (int, error) {
	exit, err := p.rp.Wait()
	if err != nil {
		return exit.Code, err
	}
	if exit.OOMKilled {
		return exit.Code, errors.New("process killed by out-of-memory limit")
	}
	if exit.Error != "" {
		return exit.Code, errors.New(exit.Error)
	}
	return exit.Code, nil
}

func (p *customAppVMProcess) Close() error {
	var err error
	p.closeOnce.Do(func() {
		err = p.rp.Close()
		p.b.releaseCustomAppVM(p.avm)
	})
	return err
}

func (b *MicroVM) StartAppVMProcess(ctx context.Context, req customapps.VMExecRequest) (customapps.VMProcess, error) {
	avm, vm, err := b.acquireCustomAppVM(ctx, req.App)
	if err != nil {
		return nil, err
	}

	env := map[string]string{
		"HOME":    homePath,
		"USER":    "node",
		"LOGNAME": "node",
		"TMPDIR":  "/tmp",
		"PATH":    homePath + "/.nix-profile/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin",
	}
	b.applyCacheEnv(env)
	b.applyTrustEnv(env)
	for k, v := range req.Env {
		env[k] = v
	}

	var files []guestproto.FileWrite
	for _, f := range req.Files {
		mode := f.Mode
		if mode == 0 {
			mode = 0o600
		}
		files = append(files, guestproto.FileWrite{
			Path: f.Path,
			Data: f.Data,
			Mode: mode,
			UID:  1000,
			GID:  1000,
		})
	}

	dir := req.Dir
	if dir == "" {
		dir = workspacePath
	}
	rp, err := vm.Client().StartExec(ctx, guestproto.ExecReq{
		Argv:      req.Argv,
		Env:       env,
		Dir:       dir,
		UID:       1000,
		GID:       1000,
		Files:     files,
		PidsLimit: b.PidsLimit,
	})
	if err != nil {
		b.releaseCustomAppVM(avm)
		return nil, err
	}
	return &customAppVMProcess{b: b, avm: avm, rp: rp}, nil
}

func (b *MicroVM) ReadAppVMFile(ctx context.Context, app customapps.VMAppSpec, guestPath string, limit int64) ([]byte, error) {
	avm, vm, err := b.acquireCustomAppVM(ctx, app)
	if err != nil {
		return nil, err
	}
	defer b.releaseCustomAppVM(avm)
	return vm.Client().ReadFile(ctx, guestPath, limit)
}

func (b *MicroVM) UnlinkAppVMPaths(ctx context.Context, app customapps.VMAppSpec, paths []string, recursive bool) error {
	avm := b.lookupCustomAppEntry(app.AppID)
	if avm == nil {
		return nil
	}
	avm.mu.Lock()
	hasVM := avm.vm != nil
	avm.mu.Unlock()
	if !hasVM {
		return nil
	}
	avm, vm, err := b.acquireCustomAppVM(ctx, app)
	if err != nil {
		return err
	}
	defer b.releaseCustomAppVM(avm)
	return vm.Client().UnlinkPaths(ctx, paths, recursive)
}

func (b *MicroVM) SyncAppVMPolicy(ctx context.Context, app customapps.VMAppSpec) error {
	avm := b.lookupCustomAppEntry(app.AppID)
	if avm == nil {
		return nil
	}
	avm.allowPublic.Store(app.AllowPublic)

	_, mountHash, err := resolveCustomAppMounts(app.Mounts)
	if err != nil {
		return err
	}
	avm.mu.Lock()
	needsRestart := avm.vm != nil && avm.mountHash != mountHash && avm.activeCalls == 0
	var oldVM microvm.VM
	var oldEg *microvm.Egress
	if needsRestart {
		oldVM, oldEg = avm.detachLocked()
	}
	avm.mu.Unlock()
	if needsRestart {
		stopCustomAppResources(ctx, oldVM, oldEg)
	}
	return nil
}

func (b *MicroVM) AppVMStatus(appID uuid.UUID) customapps.VMStatus {
	st := customapps.VMStatus{
		Available: b.Driver != nil,
		State:     customapps.VMStateStopped,
	}
	avm := b.lookupCustomAppEntry(appID)
	if avm == nil {
		return st
	}
	avm.mu.Lock()
	defer avm.mu.Unlock()
	st.ActiveCalls = avm.activeCalls
	st.MountCount = avm.mountCount
	st.AllowPublic = avm.allowPublic.Load()
	if avm.vm == nil {
		return st
	}
	if !avm.pausedAt.IsZero() {
		st.State = customapps.VMStatePaused
		t := avm.pausedAt
		st.PausedAt = &t
	} else {
		st.State = customapps.VMStateRunning
	}
	if !avm.bootedAt.IsZero() {
		t := avm.bootedAt
		st.BootedAt = &t
	}
	if !avm.lastUsedAt.IsZero() {
		t := avm.lastUsedAt
		st.LastUsedAt = &t
	}
	return st
}

func (b *MicroVM) StopAppVM(ctx context.Context, appID uuid.UUID) error {
	avm := b.lookupCustomAppEntry(appID)
	if avm == nil {
		return nil
	}
	b.stopCustomAppVM(ctx, avm)
	return nil
}

func (b *MicroVM) RestartAppVM(ctx context.Context, app customapps.VMAppSpec) error {
	if err := b.StopAppVM(ctx, app.AppID); err != nil {
		return err
	}
	avm, _, err := b.acquireCustomAppVM(ctx, app)
	if err != nil {
		return err
	}
	b.releaseCustomAppVM(avm)
	return nil
}

func (b *MicroVM) DeleteAppVM(ctx context.Context, appID uuid.UUID) error {
	b.customAppMu.Lock()
	avm := b.customApps[appID]
	delete(b.customApps, appID)
	b.customAppMu.Unlock()

	if avm != nil {
		b.stopCustomAppVM(ctx, avm)
	}
	if dir, err := b.customAppDir(appID); err == nil {
		_ = os.RemoveAll(dir)
	}
	return nil
}

func (b *MicroVM) NotifyAppWindowClosed(appID uuid.UUID) {
	avm := b.lookupCustomAppEntry(appID)
	if avm == nil {
		return
	}
	avm.mu.Lock()
	defer avm.mu.Unlock()
	if avm.vm == nil || avm.activeCalls != 0 || !avm.pausedAt.IsZero() {
		return
	}
	delay := defaultCustomAppWindowCloseLag
	if d := b.customAppIdlePauseDelay(); d < delay {
		delay = d
	}
	b.scheduleCustomAppIdlePauseLocked(avm, delay)
}

func (b *MicroVM) cleanupCustomApps(ctx context.Context) {
	b.customAppMu.Lock()
	list := make([]*customAppVM, 0, len(b.customApps))
	for _, avm := range b.customApps {
		list = append(list, avm)
	}
	b.customApps = nil
	b.customAppMu.Unlock()

	for _, avm := range list {
		b.stopCustomAppVM(ctx, avm)
	}
}

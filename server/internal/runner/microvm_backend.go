package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

const (
	wsTemplateSize  int64 = 64 << 30 // 64 GiB sparse APFS image
	homeTemplateSz  int64 = 16 << 30 // 16 GiB sparse APFS image
	dkrTemplateSize int64 = 32 << 30 // 32 GiB sparse APFS image
	nixTemplateSize int64 = 32 << 30 // 32 GiB sparse APFS image (dev workspaces)

	wsDiskLabel   = "vesper-ws"
	homeDiskLabel = "vesper-home"
	dkrDiskLabel  = "vesper-dkr"
	nixDiskLabel  = "vesper-nix"

	maxAuthReadBytes    = 16 << 10
	maxNixManifestBytes = 4 << 20
)

// MicroVM runs each Vesper run in an isolated NIC-less Linux microVM driven via
// microvm.Driver (Apple Virtualization.framework on darwin/arm64).
type MicroVM struct {
	Driver         microvm.Driver
	StateDir       string
	KernelPath     string
	RootfsPath     string
	HostWorkspaces string
	CPUs           int
	MemoryMB       int64
	IdleMemoryMB   int64 // target balloon memory between turns when activeTurns == 0 (default 192 MiB)
	PidsLimit      int64
	WarmTTL        time.Duration
	MCPURL         string

	APIHandler      http.Handler
	APIUpstream     string // optional http(s)://host:port used when APIHandler == nil
	CacheStore      *microvm.CacheStore
	CacheHandler    http.Handler
	GitHandler      http.Handler
	GitUpstreamBase string // defaults to https://github.com
	GitRewriteFrom  string // defaults to https://github.com/
	Resolver        func(ctx context.Context, host string) ([]net.IP, error)
	TestUpstreams   map[string]string

	SaveClaudeAuth func(ctx context.Context, scope, auth string) error
	SaveCodexAuth  func(ctx context.Context, scope, auth string) error
	Log            *slog.Logger
	ModelsTimeout  time.Duration
	UsageTimeout   time.Duration

	// Optional disk template sizes (defaults to 64G/16G/32G sparse ext4 images).
	TestWorkspaceBytes int64
	TestHomeBytes      int64
	TestDockerBytes    int64
	TestNixBytes       int64

	tmplMu      sync.Mutex
	runsMu      sync.Mutex
	locks       map[string]*sync.Mutex
	vms         map[string]*runVM
	pgMu        sync.Mutex
	playgrounds map[uuid.UUID]*activePlaygroundVM
	devMu       sync.Mutex
	devVMs      map[uuid.UUID]*devWorkspaceVM
	semOnce     sync.Once
	listSem     chan struct{}
	usageSem    chan struct{}
}

type runVM struct {
	mu          sync.Mutex
	runID       string
	vm          microvm.VM
	egress      *microvm.Egress
	vmGen       uint64
	activeTurns int
	idleTimer   *time.Timer

	// credMu orders credential writes and sweeps in this VM: a process's
	// post-exit sweep must not delete a login another process just wrote.
	credMu sync.Mutex
	// credHolds counts running processes per home credential path they wrote.
	credHolds map[string]int
}

func (b *MicroVM) Name() string               { return "microvm" }
func (b *MicroVM) Isolates() bool             { return true }
func (b *MicroVM) WorkspaceDir(string) string { return workspacePath }
func (b *MicroVM) DependencyCacheDir() string { return "/cache" }

func (b *MicroVM) logger() *slog.Logger {
	if b.Log != nil {
		return b.Log
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func (b *MicroVM) runLock(runID string) *sync.Mutex {
	b.runsMu.Lock()
	defer b.runsMu.Unlock()
	if b.locks == nil {
		b.locks = make(map[string]*sync.Mutex)
	}
	l := b.locks[runID]
	if l == nil {
		l = &sync.Mutex{}
		b.locks[runID] = l
	}
	return l
}

func safeVMRunKey(runID string) (string, error) {
	if runID == "" || runID == "." || runID == ".." || strings.ContainsAny(runID, "/\\\x00 \t\n\r") || strings.Contains(runID, "..") {
		return "", fmt.Errorf("invalid run id %q", runID)
	}
	return runID, nil
}

func (b *MicroVM) runDir(runID string) (string, error) {
	key, err := safeVMRunKey(runID)
	if err != nil {
		return "", err
	}
	if b.StateDir == "" {
		return "", errors.New("microvm: StateDir is required")
	}
	return filepath.Join(b.StateDir, "runs", key), nil
}

func (b *MicroVM) EnsureWorkspace(ctx context.Context, runID string) error {
	dir, err := b.runDir(runID)
	if err != nil {
		return err
	}
	mu := b.runLock(runID)
	mu.Lock()
	defer mu.Unlock()

	if err := b.createDisks(ctx, dir); err != nil {
		return err
	}
	metaPath := filepath.Join(dir, "meta.json")
	if _, err := os.Stat(metaPath); os.IsNotExist(err) {
		meta, _ := json.Marshal(map[string]any{"run_id": runID, "created_at": time.Now().UTC()})
		if err := os.WriteFile(metaPath, meta, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// createDisks gives dir the disks a run's VM boots on, cloned from the
// formatted templates, keeping any it already has.
func (b *MicroVM) createDisks(ctx context.Context, dir string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
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

	specs := []struct {
		file  string
		tmpl  string
		label string
		size  int64
	}{
		{"workspace.ext4", "ws.ext4", wsDiskLabel, wsSz},
		{"home.ext4", "home.ext4", homeDiskLabel, homeSz},
		{"docker.ext4", "dkr.ext4", dkrDiskLabel, dkrSz},
	}
	for _, s := range specs {
		dst := filepath.Join(dir, s.file)
		if _, err := os.Stat(dst); err == nil {
			continue
		}
		tmpl, err := b.ensureExt4Template(ctx, s.tmpl, s.label, s.size)
		if err != nil {
			return fmt.Errorf("template %s: %w", s.file, err)
		}
		if err := cloneFile(tmpl, dst); err != nil {
			return fmt.Errorf("clone %s: %w", s.file, err)
		}
	}
	return nil
}

func (b *MicroVM) HasWorkspace(_ context.Context, runID string) (bool, error) {
	dir, err := b.runDir(runID)
	if err != nil {
		return false, err
	}
	_, err = os.Stat(filepath.Join(dir, "workspace.ext4"))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

func (b *MicroVM) RemoveWorkspace(ctx context.Context, runID string) error {
	dir, err := b.runDir(runID)
	if err != nil {
		return err
	}
	mu := b.runLock(runID)
	mu.Lock()
	defer mu.Unlock()

	b.stopRunVM(ctx, runID)
	return os.RemoveAll(dir)
}

func (b *MicroVM) ensureExt4Template(ctx context.Context, name, label string, size int64) (string, error) {
	b.tmplMu.Lock()
	defer b.tmplMu.Unlock()

	tmplDir := filepath.Join(b.StateDir, "templates")
	if err := os.MkdirAll(tmplDir, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(tmplDir, fmt.Sprintf("%s-%s-%d", name, label, size))
	if hasExt4Magic(dst) {
		return dst, nil
	}

	tmp := dst + ".tmp"
	_ = os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o644)
	if err != nil {
		return "", err
	}
	if err := f.Truncate(size); err != nil {
		_ = f.Close()
		_ = os.Remove(tmp)
		return "", err
	}
	_ = f.Close()

	if err := b.formatExt4(ctx, tmp, label); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	return dst, nil
}

func hasExt4Magic(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	var buf [2]byte
	if _, err := f.ReadAt(buf[:], 1024+0x38); err != nil {
		return false
	}
	return buf[0] == 0x53 && buf[1] == 0xEF
}

func (b *MicroVM) formatExt4(ctx context.Context, imgPath, label string) error {
	if mke2fs := findMke2fs(); mke2fs != "" {
		out, err := exec.CommandContext(ctx, mke2fs, "-t", "ext4", "-L", label, "-F", "-q", imgPath).CombinedOutput()
		if err != nil {
			return fmt.Errorf("%s: %w (%s)", mke2fs, err, string(out))
		}
		return nil
	}
	// If host lacks mke2fs (e.g., packaged macOS app), format the sparse image
	// inside an ephemeral microVM using the bundled mkfs.ext4 in agent-base.erofs.
	if b.Driver == nil {
		return errors.New("microvm: no mke2fs tool and no VM driver to format ext4 template")
	}
	if _, isMem := b.Driver.(*microvm.MemDriver); isMem {
		// MemDriver tests without host mke2fs write an ext4 superblock magic stub.
		f, err := os.OpenFile(imgPath, os.O_WRONLY, 0o644)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = f.WriteAt([]byte{0x53, 0xEF}, 1024+0x38)
		return err
	}
	vm, err := b.Driver.Start(ctx, microvm.VMConfig{
		KernelPath:  b.KernelPath,
		CPUs:        1,
		MemoryBytes: 512 << 20,
		Drives: []microvm.DriveSpec{
			{Path: b.RootfsPath, ReadOnly: true},
			{Path: imgPath, ReadOnly: false},
		},
	})
	if err != nil {
		return fmt.Errorf("boot formatter VM: %w", err)
	}
	defer func() { _ = vm.Stop(context.Background()) }()

	proc, err := vm.Client().StartExec(ctx, guestproto.ExecReq{
		Argv: []string{"/sbin/mkfs.ext4", "-L", label, "-F", "-q", "/dev/vdb"},
	})
	if err != nil {
		return err
	}
	go func() { _, _ = io.Copy(io.Discard, proc.Stdout()) }()
	var errBuf strings.Builder
	_, _ = io.Copy(&errBuf, io.LimitReader(proc.Stderr(), 64<<10))
	ex, err := proc.Wait()
	if err != nil {
		return err
	}
	if ex.Code != 0 {
		return fmt.Errorf("guest mkfs.ext4 exit %d: %s", ex.Code, errBuf.String())
	}
	return nil
}

func findMke2fs() string {
	for _, tool := range []string{"mkfs.ext4", "mke2fs"} {
		if p, err := exec.LookPath(tool); err == nil {
			return p
		}
	}
	if home, err := os.UserHomeDir(); err == nil {
		p := filepath.Join(home, "Library/Android/sdk/platform-tools/mke2fs")
		if _, serr := os.Stat(p); serr == nil {
			return p
		}
	}
	return ""
}

func (b *MicroVM) apiHandler() http.Handler {
	if b.APIHandler != nil {
		return b.APIHandler
	}
	if b.APIUpstream != "" {
		if u, err := url.Parse(b.APIUpstream); err == nil && u.Host != "" {
			return httputil.NewSingleHostReverseProxy(u)
		}
	}
	return nil
}

func (b *MicroVM) acquireVM(ctx context.Context, runID string) (*runVM, error) {
	if err := b.EnsureWorkspace(ctx, runID); err != nil {
		return nil, err
	}
	b.runsMu.Lock()
	if b.vms == nil {
		b.vms = make(map[string]*runVM)
	}
	rvm := b.vms[runID]
	if rvm == nil {
		rvm = &runVM{runID: runID}
		b.vms[runID] = rvm
	}
	b.runsMu.Unlock()

	rvm.mu.Lock()
	defer rvm.mu.Unlock()
	if rvm.idleTimer != nil {
		rvm.idleTimer.Stop()
		rvm.idleTimer = nil
	}
	memMB := b.MemoryMB
	if memMB <= 0 {
		memMB = 2048
	}
	if rvm.vm != nil {
		_ = rvm.vm.SetMemoryTarget(uint64(memMB) << 20)
		rvm.activeTurns++
		return rvm, nil
	}

	dir, err := b.runDir(runID)
	if err != nil {
		return nil, err
	}
	hostDir, _ := b.hostWorkspacePath(runID)
	vm, eg, _, err := b.bootVM(ctx, dir, hostDir)
	if err != nil {
		return nil, err
	}
	rvm.egress = eg
	rvm.vm = vm
	rvm.vmGen++
	rvm.activeTurns++
	return rvm, nil
}

// bootVM boots a VM on the disks in dir, with hostDir (when set) shared as
// its workspace instead of dir's workspace disk, and the cache drives that
// are current now, which it returns.
func (b *MicroVM) bootVM(ctx context.Context, dir, hostDir string) (microvm.VM, *microvm.Egress, []microvm.DriveSpec, error) {
	if b.Driver == nil {
		return nil, nil, nil, errors.New("microvm: Driver is required")
	}
	memMB := b.MemoryMB
	if memMB <= 0 {
		memMB = 2048
	}
	cpus := b.CPUs
	if cpus <= 0 {
		cpus = 2
	}

	cacheH := b.CacheHandler
	if cacheH == nil && b.CacheStore != nil {
		cacheH = b.CacheStore
	}
	eg := microvm.NewEgress(microvm.EgressConfig{
		Log:           b.logger(),
		APIHandler:    b.apiHandler(),
		CacheHandler:  cacheH,
		GitHandler:    b.GitHandler,
		Resolver:      b.Resolver,
		TestUpstreams: b.TestUpstreams,
	})
	drives := []microvm.DriveSpec{
		{Path: b.RootfsPath, ReadOnly: true},
	}
	var shares []microvm.VirtioFSSpec
	if hostDir != "" {
		shares = append(shares, microvm.VirtioFSSpec{Tag: "workspace", HostDir: hostDir, ReadOnly: false})
	} else {
		drives = append(drives, microvm.DriveSpec{Path: filepath.Join(dir, "workspace.ext4"), ReadOnly: false})
	}
	drives = append(drives,
		microvm.DriveSpec{Path: filepath.Join(dir, "home.ext4"), ReadOnly: false},
		microvm.DriveSpec{Path: filepath.Join(dir, "docker.ext4"), ReadOnly: false},
	)
	var cache []microvm.DriveSpec
	if b.CacheStore != nil {
		cache = b.CacheStore.LatestEROFSDrives()
		drives = append(drives, cache...)
	}
	vm, err := b.Driver.Start(ctx, microvm.VMConfig{
		KernelPath:  b.KernelPath,
		CPUs:        cpus,
		MemoryBytes: uint64(memMB) << 20,
		Drives:      drives,
		Shares:      shares,
		Listeners:   eg.Listeners(),
	})
	if err != nil {
		_ = eg.Close()
		return nil, nil, nil, err
	}
	return vm, eg, cache, nil
}

func (b *MicroVM) releaseVM(rvm *runVM) {
	rvm.mu.Lock()
	if rvm.activeTurns > 0 {
		rvm.activeTurns--
	}
	idleNow := rvm.activeTurns == 0 && rvm.vm != nil
	vm := rvm.vm
	gen := rvm.vmGen
	rvm.mu.Unlock()

	if !idleNow {
		return
	}

	// Free guest page cache first, then deflate guest memory toward IdleMemoryMB
	// via virtio_balloon so freed pages return promptly to macOS.
	dctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	_ = vm.Client().SyncAndDropCaches(dctx)
	cancel()

	idleMB := b.IdleMemoryMB
	if idleMB <= 0 {
		idleMB = 192
	}
	memMB := b.MemoryMB
	if memMB <= 0 {
		memMB = 2048
	}
	if idleMB > memMB {
		idleMB = memMB
	}

	rvm.mu.Lock()
	defer rvm.mu.Unlock()
	if rvm.activeTurns != 0 || rvm.vm == nil || rvm.vmGen != gen {
		return
	}
	if idleMB < memMB {
		_ = rvm.vm.SetMemoryTarget(uint64(idleMB) << 20)
	}
	b.armIdleTimer(rvm, gen)
}

// armIdleTimer stops rvm's VM (generation gen) once it has sat idle for
// WarmTTL. Call it with rvm.mu held.
func (b *MicroVM) armIdleTimer(rvm *runVM, gen uint64) {
	if b.WarmTTL <= 0 {
		return
	}
	if rvm.idleTimer != nil {
		rvm.idleTimer.Stop()
	}
	rvm.idleTimer = time.AfterFunc(b.WarmTTL, func() {
		rvm.mu.Lock()
		defer rvm.mu.Unlock()
		if rvm.activeTurns != 0 || rvm.vm == nil || rvm.vmGen != gen {
			return
		}
		sctx, scancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer scancel()
		_ = rvm.vm.Stop(sctx)
		if rvm.egress != nil {
			_ = rvm.egress.Close()
		}
		rvm.vm = nil
		rvm.egress = nil
		rvm.idleTimer = nil
	})
}

// ActiveVMCount reports how many microVMs currently have a booted hypervisor instance.
func (b *MicroVM) ActiveVMCount() int {
	b.runsMu.Lock()
	list := make([]*runVM, 0, len(b.vms))
	for _, rvm := range b.vms {
		list = append(list, rvm)
	}
	b.runsMu.Unlock()
	n := 0
	for _, rvm := range list {
		rvm.mu.Lock()
		if rvm.vm != nil {
			n++
		}
		rvm.mu.Unlock()
	}
	return n
}

func (b *MicroVM) stopRunVM(ctx context.Context, runID string) {
	b.runsMu.Lock()
	rvm := b.vms[runID]
	delete(b.vms, runID)
	b.runsMu.Unlock()
	if rvm == nil {
		return
	}
	rvm.mu.Lock()
	if rvm.idleTimer != nil {
		rvm.idleTimer.Stop()
		rvm.idleTimer = nil
	}
	vm := rvm.vm
	eg := rvm.egress
	rvm.vm = nil
	rvm.egress = nil
	rvm.mu.Unlock()
	if vm != nil {
		_ = vm.Stop(ctx)
	}
	if eg != nil {
		_ = eg.Close()
	}
}

func (b *MicroVM) Start(ctx context.Context, runID string, spec ExecSpec) (Process, error) {
	rvm, err := b.acquireVM(ctx, runID)
	if err != nil {
		return nil, err
	}
	ok := false
	defer func() {
		if !ok {
			b.releaseVM(rvm)
		}
	}()

	var writes []guestproto.FileWrite
	for rel, data := range spec.Files {
		clean := path.Clean("/" + rel)
		if rel == "" || clean == "/" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "..") {
			return nil, fmt.Errorf("microvm: invalid workspace file path %q", rel)
		}
		writes = append(writes, guestproto.FileWrite{
			Path: path.Join(workspacePath, strings.TrimPrefix(clean, "/")),
			Data: data,
			Mode: 0o644,
			UID:  1000,
			GID:  1000,
		})
	}

	// heldPaths are the credentials this process writes; sweepPaths are
	// removed after it exits unless a process still running holds them.
	var heldPaths []string
	claudeAuth := spec.Env[ClaudeAuthEnv]
	claudeScope := spec.Env[ClaudeAuthScopeEnv]
	codexAuth := spec.Env[CodexAuthEnv]
	codexScope := spec.Env[CodexAuthScopeEnv]
	agyAuthRaw := spec.Env[AntigravityAuthEnv]

	if claudeAuth != "" {
		p := path.Join(homePath, claudeAuthPath)
		writes = append(writes, guestproto.FileWrite{Path: p, Data: []byte(claudeAuth), Mode: 0o600, UID: 1000, GID: 1000})
		heldPaths = append(heldPaths, p)
	}
	if codexAuth != "" {
		p := path.Join(homePath, codexAuthPath)
		writes = append(writes, guestproto.FileWrite{Path: p, Data: []byte(codexAuth), Mode: 0o600, UID: 1000, GID: 1000})
		heldPaths = append(heldPaths, p)
	}
	if agyAuthRaw != "" {
		auth, valid := chatmodels.ParseAntigravityAuth(agyAuthRaw)
		if !valid {
			return nil, errors.New("microvm: invalid Antigravity login bundle")
		}
		for rel, content := range auth.Files {
			cleanRel, cleanOK := chatmodels.CleanAntigravityRelPath(rel)
			if !cleanOK {
				continue
			}
			p := path.Join(homePath, cleanRel)
			writes = append(writes, guestproto.FileWrite{Path: p, Data: []byte(content), Mode: 0o600, UID: 1000, GID: 1000})
			heldPaths = append(heldPaths, p)
		}
	}
	// Sweep the standard secret paths after every process too, except what a
	// process still running in this VM holds (see releaseCredentials).
	sweepPaths := append(append([]string(nil), heldPaths...),
		path.Join(homePath, claudeAuthPath),
		path.Join(homePath, codexAuthPath),
		path.Join(homePath, ".config/antigravity"),
		path.Join(homePath, ".gemini"),
		path.Join(homePath, ".ssh"),
	)

	if wf, ok := b.nixConfFileWrite(); ok {
		writes = append(writes, wf)
	}

	env := map[string]string{
		"HOME":    homePath,
		"USER":    "node",
		"LOGNAME": "node",
		"TMPDIR":  "/tmp",
		"GOCACHE": homePath + "/.cache/go-build",
		"PATH":    homePath + "/.nix-profile/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin",
	}
	b.applyCacheEnv(env)

	var gitPAT string
	for _, k := range []string{"GH_TOKEN", "GITHUB_TOKEN", envName("git:pat")} {
		if v := spec.Env[k]; v != "" && gitPAT == "" {
			gitPAT = v
		}
	}
	gitProxySet := false
	for k, v := range spec.Env {
		if hostOnlyEnv(k) {
			continue
		}
		env[k] = v
	}
	// An SSH-URL checkout fetches through the same host proxy as an HTTPS
	// one (rewriteGitInsteadOfEnv), so the deploy key never enters the VM.
	if gitPAT != "" || spec.Env[SSHKeyEnv] != "" || b.GitUpstreamBase != "" {
		if rvm.egress != nil {
			rvm.egress.SetGitHandler(newGitUploadProxy(b.GitUpstreamBase, gitPAT))
			gitProxySet = true
		}
		rewriteGitInsteadOfEnv(env, b.GitRewriteFrom)
	}
	pgProxySet := b.attachPlaygroundProxy(spec, env, rvm.egress)

	dir := spec.Dir
	if dir == "" {
		dir = workspacePath
	}
	// Hold the logins before writing them: a process exiting meanwhile either
	// finished its sweep before the hold (it sweeps under credMu) or skips them.
	if len(heldPaths) > 0 {
		rvm.credMu.Lock()
		rvm.holdCredentials(heldPaths)
		rvm.credMu.Unlock()
	}
	rp, err := rvm.vm.Client().StartExec(ctx, guestproto.ExecReq{
		Argv:             spec.Argv,
		Env:              env,
		Dir:              dir,
		UID:              1000,
		GID:              1000,
		Files:            writes,
		MemoryLimitBytes: b.MemoryMB << 20,
		PidsLimit:        b.PidsLimit,
		CgroupName:       spec.Name,
	})
	if err != nil {
		// The files may have been written before the exec failed.
		b.releaseCredentials(rvm, heldPaths, sweepPaths)
		if gitProxySet && rvm.egress != nil {
			rvm.egress.SetGitHandler(b.GitHandler)
		}
		if pgProxySet && rvm.egress != nil {
			rvm.egress.SetPlaygroundHandler(nil)
		}
		return nil, err
	}
	ok = true
	return &microvmProc{
		b:           b,
		rvm:         rvm,
		rp:          rp,
		claudeAuth:  claudeAuth,
		claudeScope: claudeScope,
		codexAuth:   codexAuth,
		codexScope:  codexScope,
		heldPaths:   heldPaths,
		sweepPaths:  sweepPaths,
		gitProxySet: gitProxySet,
		pgProxySet:  pgProxySet,
	}, nil
}

type microvmProc struct {
	b           *MicroVM
	rvm         *runVM
	rp          *guestproto.RemoteProcess
	claudeAuth  string
	claudeScope string
	codexAuth   string
	codexScope  string
	heldPaths   []string
	sweepPaths  []string
	nixManifest []byte
	gitProxySet bool
	pgProxySet  bool
}

var (
	_ Process            = (*microvmProc)(nil)
	_ NixManifestProcess = (*microvmProc)(nil)
)

func (p *microvmProc) Stdout() io.Reader   { return p.rp.Stdout() }
func (p *microvmProc) Stderr() io.Reader   { return p.rp.Stderr() }
func (p *microvmProc) Interrupt() error    { return p.rp.Signal(2) }
func (p *microvmProc) Kill() error         { return p.rp.Signal(9) }
func (p *microvmProc) NixManifest() []byte { return p.nixManifest }

func (p *microvmProc) Wait() (int, error) {
	defer func() {
		if p.gitProxySet && p.rvm.egress != nil {
			p.rvm.egress.SetGitHandler(p.b.GitHandler)
		}
		if p.pgProxySet && p.rvm.egress != nil {
			p.rvm.egress.SetPlaygroundHandler(nil)
		}
		if hostDir, ok := p.b.hostWorkspacePath(p.rvm.runID); ok {
			p.b.ensureSafeHostGitConfig(hostDir)
		}
		p.b.releaseVM(p.rvm)
	}()

	ex, err := p.rp.Wait()
	cctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	client := p.rvm.vm.Client()
	if b, rerr := client.ReadFile(cctx, path.Join(homePath, ".nix-profile/manifest.json"), maxNixManifestBytes); rerr == nil {
		p.nixManifest = b
	}
	p.keepRefreshed(cctx, client, path.Join(homePath, claudeAuthPath), p.claudeAuth, p.claudeScope, p.b.SaveClaudeAuth, chatmodels.ClaudeAuthRefreshed)
	p.keepRefreshed(cctx, client, path.Join(homePath, codexAuthPath), p.codexAuth, p.codexScope, p.b.SaveCodexAuth, chatmodels.CodexAuthRefreshed)

	// Unlink credentials from /home/node even on error/kill, unless another
	// running process in this VM still holds them.
	p.b.releaseCredentials(p.rvm, p.heldPaths, p.sweepPaths)

	if err != nil {
		return -1, err
	}
	if ex.OOMKilled {
		code := ex.Code
		if code <= 0 {
			code = 137
		}
		limit := p.b.MemoryMB
		if limit <= 0 {
			limit = 2048
		}
		return code, fmt.Errorf("out of memory: killed at the %s memory limit (exit %d)", formatMemLimit(limit), code)
	}
	if ex.Error != "" && ex.Code == 0 {
		return 1, errors.New(ex.Error)
	}
	return ex.Code, nil
}

// hostOnlyEnv reports whether an env var holds a credential that stays on
// the host: logins are written as files the run holds, and git credentials
// are used by the host's fetch proxy and pushes.
func hostOnlyEnv(k string) bool {
	switch k {
	case ClaudeAuthEnv, ClaudeAuthScopeEnv, CodexAuthEnv, CodexAuthScopeEnv, AntigravityAuthEnv,
		"GH_TOKEN", "GITHUB_TOKEN", envName("git:pat"), SSHKeyEnv:
		return true
	}
	return false
}

func formatMemLimit(mb int64) string {
	return strconv.FormatInt(mb, 10) + " MiB"
}

// holdCredentials records that a starting process writes paths. The caller
// holds credMu.
func (rvm *runVM) holdCredentials(paths []string) {
	if rvm.credHolds == nil {
		rvm.credHolds = make(map[string]int)
	}
	for _, p := range paths {
		rvm.credHolds[p]++
	}
}

// releaseCredentials drops a finished process's holds on held and unlinks
// the sweep paths no running process in rvm still holds. A swept directory is
// kept while a held file lies under it.
func (b *MicroVM) releaseCredentials(rvm *runVM, held, sweep []string) {
	rvm.credMu.Lock()
	defer rvm.credMu.Unlock()
	unlink := rvm.releaseHolds(held, sweep)
	rvm.mu.Lock()
	vm := rvm.vm
	rvm.mu.Unlock()
	if len(unlink) == 0 || vm == nil {
		return
	}
	// A fresh budget: the caller's may be spent on refresh saves or the lock.
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := vm.Client().UnlinkPaths(ctx, unlink, true); err != nil {
		b.logger().Warn("microvm: remove credentials", "run", rvm.runID, "err", err)
	}
}

// releaseHolds drops one hold per path in held and returns the sweep paths
// nothing holds any more. The caller holds credMu.
func (rvm *runVM) releaseHolds(held, sweep []string) []string {
	for _, p := range held {
		if rvm.credHolds[p] <= 1 {
			delete(rvm.credHolds, p)
		} else {
			rvm.credHolds[p]--
		}
	}
	unlink := make([]string, 0, len(sweep))
	for _, p := range sweep {
		if !rvm.credentialHeld(p) {
			unlink = append(unlink, p)
		}
	}
	return unlink
}

func (rvm *runVM) credentialHeld(p string) bool {
	for h := range rvm.credHolds {
		if h == p || strings.HasPrefix(h, p+"/") {
			return true
		}
	}
	return false
}

func (p *microvmProc) keepRefreshed(ctx context.Context, client *guestproto.Client, guestFile, current, scope string, save func(context.Context, string, string) error, valid func(string, string) bool) {
	if current == "" || save == nil {
		return
	}
	b, err := client.ReadFile(ctx, guestFile, maxAuthReadBytes+1)
	if err != nil || len(b) > maxAuthReadBytes {
		return
	}
	next := string(b)
	if !valid(current, next) {
		return
	}
	if err := save(ctx, scope, next); err != nil {
		p.b.logger().Warn("save refreshed oauth failed", "file", guestFile, "err", err)
	}
}

func (b *MicroVM) ReadOutbox(ctx context.Context, runID string) ([]OutboxFile, []string, error) {
	return readOutboxExec(ctx, b, runID)
}

func (b *MicroVM) RemoveOutbox(ctx context.Context, runID string, names []string) error {
	return removeOutboxExec(ctx, b, runID, names)
}

func (b *MicroVM) ReadVideoFiles(ctx context.Context, runID string, req VideoFilesRequest) ([]VideoFile, error) {
	return readVideoFilesExec(ctx, b, runID, req)
}

func (b *MicroVM) OpenWorkspaceFile(ctx context.Context, runID, rel string, limit int64) (io.ReadCloser, int64, error) {
	return openWorkspaceFileExec(ctx, b, runID, rel, limit)
}

func (b *MicroVM) Cleanup(ctx context.Context) error {
	b.runsMu.Lock()
	ids := make([]string, 0, len(b.vms))
	for id := range b.vms {
		ids = append(ids, id)
	}
	b.runsMu.Unlock()
	for _, id := range ids {
		b.stopRunVM(ctx, id)
	}
	b.cleanupPlaygrounds(ctx)
	b.cleanupDevWorkspaces(ctx)
	return nil
}

func (b *MicroVM) Close() error { return b.Cleanup(context.Background()) }

func (b *MicroVM) cacheHandler() http.Handler {
	if b.CacheHandler != nil {
		return b.CacheHandler
	}
	if b.CacheStore != nil {
		return b.CacheStore
	}
	return nil
}

func (b *MicroVM) nixConfFileWrite() (guestproto.FileWrite, bool) {
	if b.CacheStore == nil {
		return guestproto.FileWrite{}, false
	}
	nixConf := fmt.Sprintf("build-users-group = nixbld\nexperimental-features = nix-command flakes\nsandbox = false\nauto-optimise-store = true\nextra-substituters = http://%s/nix\nextra-trusted-public-keys = %s\n",
		microvm.InternalCacheHost, b.CacheStore.NixPublicKey())
	return guestproto.FileWrite{Path: "/etc/nix/nix.conf", Data: []byte(nixConf), Mode: 0o644}, true
}

func (b *MicroVM) applyCacheEnv(env map[string]string) {
	if b.cacheHandler() != nil {
		env["GOPROXY"] = "http://" + microvm.InternalCacheHost + "/goproxy,direct"
		env["npm_config_registry"] = "http://" + microvm.InternalCacheHost + "/npm"
	}
}

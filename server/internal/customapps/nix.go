package customapps

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	nixDefaultMaxTimeout          = 1 * time.Hour
	nixDefaultStartTimeout        = 30 * time.Minute
	nixDefaultRunTimeout          = 60 * time.Second
	nixDefaultMaxRunTimeout       = 110 * time.Second
	nixDefaultMaxStdoutBytes      = 1 << 20
	nixDefaultMaxStderrBytes      = 64 << 10
	nixDefaultMaxReadBytes        = 10 << 20
	nixDefaultMaxConcurrentPerApp = 4
	nixDefaultMaxMountCopyBytes   = 16 << 20
	nixMaxPackages                = 16
	nixMaxArgs                    = 256
	nixMaxArgsBytes               = 64 << 10
	nixMaxStdinBytes              = 1 << 20
	nixMaxEnvVars                 = 32
	nixMaxWorkFiles               = 200
	nixResolveTTL                 = 1 * time.Hour
	nixResolveTimeout             = 10 * time.Minute
	nixOutputFlushEvery           = time.Second
	nixInterruptedText            = "job was interrupted (Vesper restarted); start it again"
)

var (
	nixEnvKeyRE = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]{0,63}$`)
	nixBadEnv   = map[string]bool{
		"PATH": true, "HOME": true, "TMPDIR": true, "IFS": true, "ENV": true,
		"BASH_ENV": true, "NODE_OPTIONS": true, "PYTHONPATH": true, "PYTHONHOME": true,
	}
	nixBadEnvPrefixes = []string{"LD_", "DYLD_", "XDG_", "NIX_", "VESPER_"}
)

// Nix runs approved Nix packages in per-job scratch directories for custom app
// MCP tools, supporting synchronous short calls (Run) and background jobs (Start).
type Nix struct {
	Pool                *pgxpool.Pool
	ScratchDir          string
	NixBinary           string
	FlakeRef            string
	Resolve             func(ctx context.Context, pkg string) (string, error)
	DisableSandbox      bool
	MaxTimeout          time.Duration
	DefaultStartTimeout time.Duration
	DefaultRunTimeout   time.Duration
	MaxRunTimeout       time.Duration
	MaxStdoutBytes      int
	MaxStderrBytes      int
	MaxReadBytes        int64
	MaxConcurrentPerApp int
	MaxMountCopyBytes   int64

	mu       sync.Mutex
	vmBackend VMBackend
	active   map[uuid.UUID]*activeNixJob
	cache    map[string]cachedNixPkg
	inflight map[string]*resolveFlight
	wg       sync.WaitGroup
}

const vmWorkDirPrefix = "vm:"

// SetVM attaches or clears the Custom App microVM backend used to run Nix jobs.
func (n *Nix) SetVM(vm VMBackend) {
	if n == nil {
		return
	}
	n.mu.Lock()
	n.vmBackend = vm
	n.mu.Unlock()
}

func (n *Nix) vm() VMBackend {
	if n == nil {
		return nil
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.vmBackend
}

type cachedNixPkg struct {
	paths []string
	at    time.Time
}

type resolveFlight struct {
	done  chan struct{}
	paths []string
	err   error
}

type activeNixJob struct {
	appID    uuid.UUID
	jobRoot  string
	cancel   context.CancelFunc
	canceled atomic.Bool
	done     chan struct{}
}

// NixStartInput is the request to run a command from one or more Nix packages.
type NixStartInput struct {
	Packages    []string          `json:"packages"`
	Command     string            `json:"command"`
	Args        []string          `json:"args"`
	Stdin       string            `json:"stdin"`
	Env         map[string]string `json:"env"`
	Mounts      []string          `json:"mounts"`
	TimeoutSec  int               `json:"timeout_sec"`
	KeepFiles   bool              `json:"keep_files"`
	AllowPublic bool              `json:"-"`
}

// NixFile is one output file produced inside a job's working directory.
type NixFile struct {
	Path string `json:"path"`
	Size int64  `json:"size"`
}

// NixJob is the state and output of a Nix package job as custom apps see it.
type NixJob struct {
	ID        uuid.UUID `json:"id"`
	Packages  []string  `json:"packages"`
	Command   string    `json:"command"`
	State     string    `json:"state"`
	ExitCode  *int32    `json:"exit_code,omitempty"`
	Stdout    string    `json:"stdout"`
	Stderr    string    `json:"stderr"`
	Files     []NixFile `json:"files"`
	Error     string    `json:"error,omitempty"`
	CreatedAt time.Time `json:"created_at"`
	UpdatedAt time.Time `json:"updated_at"`
}

type validatedNixInput struct {
	Packages []string
	Command  string
	Args     []string
	Stdin    string
	Env      map[string]string
	Mounts   []resolvedMount
}

type resolvedMount struct {
	Name     string
	HostPath string
	Info     os.FileInfo
}

func (n *Nix) scratchRoot() string {
	if s := strings.TrimSpace(n.ScratchDir); s != "" {
		return s
	}
	return filepath.Join(os.TempDir(), "vesper-custom-app-nix")
}

func (n *Nix) flakeRef() string {
	if s := strings.TrimSpace(n.FlakeRef); s != "" {
		return s
	}
	if s := strings.TrimSpace(os.Getenv("VESPER_NIXPKGS_REF")); s != "" {
		return s
	}
	return "nixpkgs"
}

func (n *Nix) maxTimeout() time.Duration {
	if n.MaxTimeout > 0 {
		return n.MaxTimeout
	}
	return nixDefaultMaxTimeout
}

func (n *Nix) defaultStartTimeout() time.Duration {
	if n.DefaultStartTimeout > 0 {
		return n.DefaultStartTimeout
	}
	return nixDefaultStartTimeout
}

func (n *Nix) defaultRunTimeout() time.Duration {
	if n.DefaultRunTimeout > 0 {
		return n.DefaultRunTimeout
	}
	return nixDefaultRunTimeout
}

func (n *Nix) maxRunTimeout() time.Duration {
	if n.MaxRunTimeout > 0 {
		return n.MaxRunTimeout
	}
	return nixDefaultMaxRunTimeout
}

func (n *Nix) maxStdoutBytes() int {
	if n.MaxStdoutBytes > 0 {
		return n.MaxStdoutBytes
	}
	return nixDefaultMaxStdoutBytes
}

func (n *Nix) maxStderrBytes() int {
	if n.MaxStderrBytes > 0 {
		return n.MaxStderrBytes
	}
	return nixDefaultMaxStderrBytes
}

func (n *Nix) maxReadBytes() int64 {
	if n.MaxReadBytes > 0 {
		return n.MaxReadBytes
	}
	return nixDefaultMaxReadBytes
}

func (n *Nix) maxConcurrentPerApp() int {
	if n.MaxConcurrentPerApp > 0 {
		return n.MaxConcurrentPerApp
	}
	return nixDefaultMaxConcurrentPerApp
}

func (n *Nix) maxMountCopyBytes() int64 {
	if n.MaxMountCopyBytes > 0 {
		return n.MaxMountCopyBytes
	}
	return nixDefaultMaxMountCopyBytes
}

func (n *Nix) sandboxDisabled() bool {
	return n.DisableSandbox || strings.EqualFold(strings.TrimSpace(os.Getenv("VESPER_NIX_SANDBOX")), "off")
}

func validateNixPackagesAndCommand(packages []string, command string) ([]string, string, error) {
	if len(packages) == 0 || len(packages) > nixMaxPackages {
		return nil, "", apperr.Invalid("packages", "provide 1–%d Nix packages", nixMaxPackages)
	}
	seen := make(map[string]struct{}, len(packages))
	cleanPkgs := make([]string, 0, len(packages))
	for _, raw := range packages {
		p, err := ValidNixPackage(raw)
		if err != nil {
			return nil, "", err
		}
		if _, dup := seen[p]; dup {
			continue
		}
		seen[p] = struct{}{}
		cleanPkgs = append(cleanPkgs, p)
	}
	cmdName, err := ValidNixPackage(command)
	if err != nil {
		return nil, "", apperr.Invalid("command", "command must be a bare executable name")
	}
	return cleanPkgs, cmdName, nil
}

func isBlockedNixEnvKey(key string) bool {
	upper := strings.ToUpper(key)
	if nixBadEnv[upper] {
		return true
	}
	for _, p := range nixBadEnvPrefixes {
		if strings.HasPrefix(upper, p) {
			return true
		}
	}
	return false
}

func validateNixInput(slug string, appMounts Mounts, in NixStartInput) (validatedNixInput, error) {
	pkgs, cmdName, err := validateNixPackagesAndCommand(in.Packages, in.Command)
	if err != nil {
		return validatedNixInput{}, err
	}
	if len(in.Args) > nixMaxArgs {
		return validatedNixInput{}, apperr.Invalid("args", "at most %d arguments allowed", nixMaxArgs)
	}
	totalArgBytes := 0
	for _, a := range in.Args {
		if strings.ContainsRune(a, 0) {
			return validatedNixInput{}, apperr.Invalid("args", "arguments cannot contain NUL bytes")
		}
		totalArgBytes += len(a)
		if totalArgBytes > nixMaxArgsBytes {
			return validatedNixInput{}, apperr.Invalid("args", "arguments exceed %d KB limit", nixMaxArgsBytes>>10)
		}
	}
	if len(in.Stdin) > nixMaxStdinBytes {
		return validatedNixInput{}, apperr.Invalid("stdin", "stdin exceeds %d MB limit", nixMaxStdinBytes>>20)
	}
	if len(in.Env) > nixMaxEnvVars {
		return validatedNixInput{}, apperr.Invalid("env", "at most %d environment variables allowed", nixMaxEnvVars)
	}
	cleanEnv := make(map[string]string, len(in.Env))
	for k, v := range in.Env {
		if !nixEnvKeyRE.MatchString(k) {
			return validatedNixInput{}, apperr.Invalid("env", "invalid environment variable name %q", k)
		}
		if isBlockedNixEnvKey(k) {
			return validatedNixInput{}, apperr.Invalid("env", "environment variable %q cannot be overridden", k)
		}
		if strings.ContainsRune(v, 0) {
			return validatedNixInput{}, apperr.Invalid("env", "environment variable %q cannot contain NUL bytes", k)
		}
		cleanEnv[k] = v
	}

	seenMounts := make(map[string]struct{}, len(in.Mounts))
	var mounts []resolvedMount
	for _, rawName := range in.Mounts {
		name, err := ValidMountName(rawName)
		if err != nil {
			return validatedNixInput{}, err
		}
		if _, dup := seenMounts[name]; dup {
			continue
		}
		seenMounts[name] = struct{}{}
		rawHostPath := strings.TrimSpace(appMounts[name])
		if rawHostPath == "" {
			return validatedNixInput{}, apperr.Conflict("mount %q is not configured for custom app %q; set it in /apps/%s Permissions", name, slug, slug)
		}
		expanded := rawHostPath
		if strings.HasPrefix(expanded, "~/") {
			home, herr := os.UserHomeDir()
			if herr != nil {
				return validatedNixInput{}, apperr.Conflict("mount %q path could not expand home directory; check /apps/%s Permissions", name, slug)
			}
			expanded = filepath.Join(home, expanded[2:])
		}
		realPath, rerr := filepath.EvalSymlinks(expanded)
		if rerr != nil {
			return validatedNixInput{}, apperr.Conflict("mount %q is unavailable on the host; check /apps/%s Permissions", name, slug)
		}
		info, serr := os.Stat(realPath)
		if serr != nil {
			return validatedNixInput{}, apperr.Conflict("mount %q is unavailable on the host; check /apps/%s Permissions", name, slug)
		}
		mounts = append(mounts, resolvedMount{Name: name, HostPath: realPath, Info: info})
	}

	return validatedNixInput{
		Packages: pkgs,
		Command:  cmdName,
		Args:     append([]string(nil), in.Args...),
		Stdin:    in.Stdin,
		Env:      cleanEnv,
		Mounts:   mounts,
	}, nil
}

// Start launches a Nix command asynchronously in a per-job scratch directory.
func (n *Nix) Start(ctx context.Context, appID uuid.UUID, slug string, appMounts Mounts, in NixStartInput) (NixJob, error) {
	timeout := n.defaultStartTimeout()
	if in.TimeoutSec > 0 {
		timeout = min(time.Duration(in.TimeoutSec)*time.Second, n.maxTimeout())
	}
	job, _, err := n.start(ctx, appID, slug, appMounts, in, timeout)
	return job, err
}

// Run executes a short Nix command synchronously up to MaxRunTimeout and cleans
// up its scratch directory and job row unless KeepFiles is true.
func (n *Nix) Run(ctx context.Context, appID uuid.UUID, slug string, appMounts Mounts, in NixStartInput) (NixJob, error) {
	timeout := n.defaultRunTimeout()
	if in.TimeoutSec > 0 {
		timeout = time.Duration(in.TimeoutSec) * time.Second
	}
	timeout = min(timeout, n.maxRunTimeout())

	started, aj, err := n.start(ctx, appID, slug, appMounts, in, timeout)
	if err != nil {
		return NixJob{}, err
	}

	select {
	case <-aj.done:
	case <-ctx.Done():
		aj.canceled.Store(true)
		aj.cancel()
		<-aj.done
		if !in.KeepFiles {
			_ = n.Delete(context.WithoutCancel(ctx), appID, started.ID)
		}
		return NixJob{}, ctx.Err()
	}

	job, err := n.Status(ctx, appID, started.ID)
	if !in.KeepFiles {
		_ = n.Delete(context.WithoutCancel(ctx), appID, started.ID)
		job.Files = []NixFile{}
	}
	if err != nil {
		return NixJob{}, err
	}
	return job, nil
}

func (n *Nix) start(ctx context.Context, appID uuid.UUID, slug string, appMounts Mounts, in NixStartInput, timeout time.Duration) (NixJob, *activeNixJob, error) {
	if n == nil || n.Pool == nil {
		return NixJob{}, nil, errors.New("nix runner is unavailable")
	}
	if appID == uuid.Nil {
		return NixJob{}, nil, errors.New("custom app id is required")
	}
	v, err := validateNixInput(slug, appMounts, in)
	if err != nil {
		return NixJob{}, nil, err
	}

	n.mu.Lock()
	activeForApp := 0
	for _, aj := range n.active {
		if aj.appID == appID {
			activeForApp++
		}
	}
	if activeForApp >= n.maxConcurrentPerApp() {
		n.mu.Unlock()
		return NixJob{}, nil, apperr.Conflict("at most %d Nix jobs may run at once for this app", n.maxConcurrentPerApp())
	}
	n.mu.Unlock()

	q := store.New(n.Pool)
	row, err := q.InsertCustomAppNixJob(ctx, store.InsertCustomAppNixJobParams{
		AppID:    appID,
		Packages: v.Packages,
		Command:  v.Command,
		WorkDir:  "",
	})
	if err != nil {
		return NixJob{}, nil, err
	}

	if vm := n.vm(); vm != nil {
		guestJobRoot := "/workspace/nix/" + row.ID.String()
		guestWorkDir := guestJobRoot + "/work"
		jobCtx, cancel := context.WithTimeout(context.Background(), timeout)
		aj := &activeNixJob{
			appID:   appID,
			jobRoot: vmWorkDirPrefix + guestJobRoot,
			cancel:  cancel,
			done:    make(chan struct{}),
		}
		n.mu.Lock()
		if n.active == nil {
			n.active = map[uuid.UUID]*activeNixJob{}
		}
		n.active[row.ID] = aj
		n.mu.Unlock()

		spec := VMAppSpec{
			AppID:       appID,
			Slug:        slug,
			Mounts:      appMounts,
			AllowPublic: in.AllowPublic,
		}
		n.wg.Add(1)
		go func() {
			defer n.wg.Done()
			defer close(aj.done)
			defer cancel()
			defer func() {
				n.mu.Lock()
				delete(n.active, row.ID)
				n.mu.Unlock()
			}()
			n.runJobInVM(jobCtx, vm, aj, row, spec, guestJobRoot, guestWorkDir, v, timeout)
		}()
		return nixJobFromRow(row, []NixFile{}), aj, nil
	}

	jobRoot := filepath.Join(n.scratchRoot(), appID.String(), row.ID.String())
	workDir := filepath.Join(jobRoot, "work")
	cleanupOnErr := func() {
		_, _ = q.DeleteCustomAppNixJob(context.WithoutCancel(ctx), store.DeleteCustomAppNixJobParams{ID: row.ID, AppID: appID})
		_ = os.RemoveAll(jobRoot)
	}
	for _, dir := range []string{
		workDir,
		filepath.Join(jobRoot, "home"),
		filepath.Join(jobRoot, "home", ".cache"),
		filepath.Join(jobRoot, "home", ".config"),
		filepath.Join(jobRoot, "tmp"),
	} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			cleanupOnErr()
			return NixJob{}, nil, err
		}
	}
	if evalRoot, err := filepath.EvalSymlinks(jobRoot); err == nil {
		jobRoot = evalRoot
		workDir = filepath.Join(jobRoot, "work")
	}

	mountEnv, roMountPaths, err := n.prepareMounts(workDir, v.Mounts)
	if err != nil {
		cleanupOnErr()
		return NixJob{}, nil, err
	}

	jobCtx, cancel := context.WithTimeout(context.Background(), timeout)
	aj := &activeNixJob{
		appID:   appID,
		jobRoot: jobRoot,
		cancel:  cancel,
		done:    make(chan struct{}),
	}

	n.mu.Lock()
	if n.active == nil {
		n.active = map[uuid.UUID]*activeNixJob{}
	}
	n.active[row.ID] = aj
	n.mu.Unlock()

	n.wg.Add(1)
	go func() {
		defer n.wg.Done()
		defer close(aj.done)
		defer cancel()
		defer func() {
			n.mu.Lock()
			delete(n.active, row.ID)
			n.mu.Unlock()
		}()
		n.runJob(jobCtx, aj, row, jobRoot, workDir, v, mountEnv, roMountPaths, timeout)
	}()

	return nixJobFromRow(row, []NixFile{}), aj, nil
}

func (n *Nix) prepareMounts(workDir string, mounts []resolvedMount) (map[string]string, []string, error) {
	if len(mounts) == 0 {
		return nil, nil, nil
	}
	mountsDir := filepath.Join(workDir, ".mounts")
	if err := os.MkdirAll(mountsDir, 0o700); err != nil {
		return nil, nil, err
	}
	env := make(map[string]string, len(mounts))
	var roPaths []string
	for _, m := range mounts {
		dest := filepath.Join(mountsDir, m.Name)
		if m.Info.Mode().IsRegular() && m.Info.Size() <= n.maxMountCopyBytes() {
			if err := copyFile(m.HostPath, dest, 0o600); err != nil {
				return nil, nil, err
			}
		} else {
			if err := os.Symlink(m.HostPath, dest); err != nil {
				return nil, nil, err
			}
			roPaths = append(roPaths, m.HostPath)
		}
		envKey := "VESPER_MOUNT_" + strings.ToUpper(strings.ReplaceAll(m.Name, "-", "_"))
		env[envKey] = dest
	}
	return env, roPaths, nil
}

func copyFile(srcPath, dstPath string, mode os.FileMode) error {
	src, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer src.Close()
	dst, err := os.OpenFile(dstPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(dst, src); err != nil {
		_ = dst.Close()
		return err
	}
	return dst.Close()
}

func (n *Nix) runJob(
	ctx context.Context,
	aj *activeNixJob,
	row store.CustomAppNixJob,
	jobRoot, workDir string,
	v validatedNixInput,
	mountEnv map[string]string,
	roMountPaths []string,
	timeout time.Duration,
) {
	q := store.New(n.Pool)
	finish := func(state string, exitCode *int32, stdout, stderr, errMsg string) {
		fctx := context.WithoutCancel(ctx)
		_, _ = q.FinishCustomAppNixJob(fctx, store.FinishCustomAppNixJobParams{
			ID:       row.ID,
			State:    state,
			ExitCode: exitCode,
			Stdout:   sanitizeJobText(stdout),
			Stderr:   sanitizeJobText(stderr),
			Error:    truncate(sanitizeJobText(errMsg), 400),
		})
	}

	pkgPaths := make([]string, 0, len(v.Packages))
	seenPkgPaths := make(map[string]bool, len(v.Packages))
	for _, pkg := range v.Packages {
		paths, err := n.resolvePackage(ctx, pkg)
		if err != nil {
			if aj.canceled.Load() {
				finish("canceled", nil, "", "", "canceled")
				return
			}
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				finish("failed", nil, "", "", fmt.Sprintf("package resolution timed out after %s", timeout))
				return
			}
			finish("failed", nil, "", "", err.Error())
			return
		}
		for _, p := range paths {
			if !seenPkgPaths[p] {
				seenPkgPaths[p] = true
				pkgPaths = append(pkgPaths, p)
			}
		}
	}

	if aj.canceled.Load() {
		finish("canceled", nil, "", "", "canceled")
		return
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		finish("failed", nil, "", "", fmt.Sprintf("command timed out after %s", timeout))
		return
	}

	cmdPath, err := locatePackageCommand(pkgPaths, v.Command)
	if err != nil {
		finish("failed", nil, "", "", err.Error())
		return
	}

	if err := q.SetCustomAppNixJobRunning(ctx, store.SetCustomAppNixJobRunningParams{
		WorkDir: workDir,
		ID:      row.ID,
	}); err != nil {
		finish("failed", nil, "", "", err.Error())
		return
	}

	pathDirs := make([]string, 0, len(pkgPaths))
	for _, p := range pkgPaths {
		binDir := filepath.Join(p, "bin")
		if info, serr := os.Stat(binDir); serr == nil && info.IsDir() {
			pathDirs = append(pathDirs, binDir)
		}
	}

	envMap := map[string]string{
		"PATH":            strings.Join(pathDirs, string(os.PathListSeparator)),
		"HOME":            filepath.Join(jobRoot, "home"),
		"TMPDIR":          filepath.Join(jobRoot, "tmp"),
		"XDG_CACHE_HOME":  filepath.Join(jobRoot, "home", ".cache"),
		"XDG_CONFIG_HOME": filepath.Join(jobRoot, "home", ".config"),
		"TZ":              "UTC",
		"LANG":            "C.UTF-8",
	}
	for k, val := range v.Env {
		envMap[k] = val
	}
	for k, val := range mountEnv {
		envMap[k] = val
	}
	envSlice := make([]string, 0, len(envMap))
	for k, val := range envMap {
		envSlice = append(envSlice, k+"="+val)
	}
	sort.Strings(envSlice)

	execBin := cmdPath
	execArgs := v.Args
	if !n.sandboxDisabled() {
		roPaths := append(append([]string(nil), pkgPaths...), roMountPaths...)
		sBin, sArgs, serr := nixSandboxCommand(jobRoot, roPaths, cmdPath, v.Args)
		if serr != nil {
			finish("failed", nil, "", "", serr.Error())
			return
		}
		execBin, execArgs = sBin, sArgs
	}

	cmd := exec.Command(execBin, execArgs...)
	cmd.Dir = workDir
	cmd.Env = envSlice
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.WaitDelay = 2 * time.Second
	if v.Stdin != "" {
		cmd.Stdin = strings.NewReader(v.Stdin)
	}

	stdoutBuf := &tailBuffer{limit: n.maxStdoutBytes()}
	stderrBuf := &tailBuffer{limit: n.maxStderrBytes()}
	cmd.Stdout = stdoutBuf
	cmd.Stderr = stderrBuf

	if err := cmd.Start(); err != nil {
		finish("failed", nil, "", "", fmt.Sprintf("start %s: %v", v.Command, err))
		return
	}

	stopFlush := n.flushJobOutput(ctx, q, row.ID, stdoutBuf, stderrBuf)
	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
	}()

	var waitErr error
	select {
	case waitErr = <-waitCh:
	case <-ctx.Done():
		if cmd.Process != nil {
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
		}
		select {
		case waitErr = <-waitCh:
		case <-time.After(2 * time.Second):
			if cmd.Process != nil {
				_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
			}
			waitErr = <-waitCh
		}
	}
	stopFlush()

	outStr := stdoutBuf.String()
	errStr := stderrBuf.String()

	if aj.canceled.Load() {
		var codePtr *int32
		if code, ok := exitCodeFromErr(waitErr); ok {
			codePtr = &code
		}
		finish("canceled", codePtr, outStr, errStr, "canceled")
		return
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		var codePtr *int32
		if code, ok := exitCodeFromErr(waitErr); ok {
			codePtr = &code
		}
		finish("failed", codePtr, outStr, errStr, fmt.Sprintf("command timed out after %s", timeout))
		return
	}
	if waitErr != nil {
		code, ok := exitCodeFromErr(waitErr)
		if !ok {
			finish("failed", nil, outStr, errStr, waitErr.Error())
			return
		}
		finish("failed", &code, outStr, errStr, fmt.Sprintf("%s exited with status %d", v.Command, code))
		return
	}
	zero := int32(0)
	finish("done", &zero, outStr, errStr, "")
}

func (n *Nix) runJobInVM(
	ctx context.Context,
	vm VMBackend,
	aj *activeNixJob,
	row store.CustomAppNixJob,
	spec VMAppSpec,
	guestJobRoot, guestWorkDir string,
	v validatedNixInput,
	timeout time.Duration,
) {
	q := store.New(n.Pool)
	finish := func(state string, exitCode *int32, outStr, errStr, errMsg string) {
		fctx := context.WithoutCancel(ctx)
		_, _ = q.FinishCustomAppNixJob(fctx, store.FinishCustomAppNixJobParams{
			ID:       row.ID,
			State:    state,
			ExitCode: exitCode,
			Stdout:   sanitizeJobText(outStr),
			Stderr:   sanitizeJobText(errStr),
			Error:    truncate(sanitizeJobText(errMsg), 400),
		})
	}

	if err := q.SetCustomAppNixJobRunning(ctx, store.SetCustomAppNixJobRunningParams{
		WorkDir: vmWorkDirPrefix + guestWorkDir,
		ID:      row.ID,
	}); err != nil {
		finish("failed", nil, "", "", err.Error())
		return
	}

	flakeRef := strings.TrimSpace(n.FlakeRef)
	if flakeRef == "" {
		flakeRef = "nixpkgs"
	}

	envMap := map[string]string{
		"HOME":            guestJobRoot + "/home",
		"TMPDIR":          guestJobRoot + "/tmp",
		"XDG_CACHE_HOME":  guestJobRoot + "/home/.cache",
		"XDG_CONFIG_HOME": guestJobRoot + "/home/.config",
		"TZ":              "UTC",
		"LANG":            "C.UTF-8",
	}
	for k, val := range v.Env {
		envMap[k] = val
	}

	var script strings.Builder
	script.WriteString("set -e\n")
	fmt.Fprintf(&script, "mkdir -p %s %s %s %s\n",
		shellQuote(guestWorkDir),
		shellQuote(guestJobRoot+"/home/.cache"),
		shellQuote(guestJobRoot+"/home/.config"),
		shellQuote(guestJobRoot+"/tmp"),
	)
	if len(v.Mounts) > 0 {
		fmt.Fprintf(&script, "mkdir -p %s\n", shellQuote(guestWorkDir+"/.mounts"))
		for _, m := range v.Mounts {
			guestMount := "/mounts/" + m.Name
			envKey := "VESPER_MOUNT_" + strings.ToUpper(strings.ReplaceAll(m.Name, "-", "_"))
			envMap[envKey] = guestMount
			fmt.Fprintf(&script, "ln -sfn %s %s\n", shellQuote(guestMount), shellQuote(guestWorkDir+"/.mounts/"+m.Name))
		}
	}
	fmt.Fprintf(&script, "cd %s\n", shellQuote(guestWorkDir))
	script.WriteString("exec nix --extra-experimental-features 'nix-command flakes' shell")
	for _, pkg := range v.Packages {
		script.WriteByte(' ')
		script.WriteString(shellQuote(flakeRef + "#" + pkg))
	}
	script.WriteString(" --command ")
	script.WriteString(shellQuote(v.Command))
	for _, arg := range v.Args {
		script.WriteByte(' ')
		script.WriteString(shellQuote(arg))
	}
	script.WriteByte('\n')

	proc, err := vm.StartAppVMProcess(ctx, VMExecRequest{
		App:  spec,
		Argv: []string{"/bin/sh", "-c", script.String()},
		Dir:  "/workspace",
		Env:  envMap,
	})
	if err != nil {
		if aj.canceled.Load() {
			finish("canceled", nil, "", "", "canceled")
			return
		}
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			finish("failed", nil, "", "", fmt.Sprintf("command timed out after %s", timeout))
			return
		}
		finish("failed", nil, "", "", fmt.Sprintf("start %s in VM: %v", v.Command, err))
		return
	}
	defer proc.Close()

	if v.Stdin != "" {
		go func() {
			_, _ = io.WriteString(proc.Stdin(), v.Stdin)
			_ = proc.Stdin().Close()
		}()
	} else {
		_ = proc.Stdin().Close()
	}

	stdoutBuf := &tailBuffer{limit: n.maxStdoutBytes()}
	stderrBuf := &tailBuffer{limit: n.maxStderrBytes()}
	var copyWG sync.WaitGroup
	copyWG.Add(2)
	go func() {
		defer copyWG.Done()
		_, _ = io.Copy(stdoutBuf, proc.Stdout())
	}()
	go func() {
		defer copyWG.Done()
		_, _ = io.Copy(stderrBuf, proc.Stderr())
	}()

	stopFlush := n.flushJobOutput(ctx, q, row.ID, stdoutBuf, stderrBuf)

	type waitRes struct {
		code int
		err  error
	}
	waitCh := make(chan waitRes, 1)
	go func() {
		code, werr := proc.Wait()
		copyWG.Wait()
		waitCh <- waitRes{code: code, err: werr}
	}()

	var res waitRes
	select {
	case res = <-waitCh:
	case <-ctx.Done():
		_ = proc.Kill(2 * time.Second)
		res = <-waitCh
	}
	stopFlush()

	outStr := stdoutBuf.String()
	errStr := stderrBuf.String()
	code32 := int32(res.code)

	if aj.canceled.Load() {
		finish("canceled", &code32, outStr, errStr, "canceled")
		return
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		finish("failed", &code32, outStr, errStr, fmt.Sprintf("command timed out after %s", timeout))
		return
	}
	if res.err != nil {
		finish("failed", &code32, outStr, errStr, res.err.Error())
		return
	}
	if res.code != 0 {
		finish("failed", &code32, outStr, errStr, fmt.Sprintf("%s exited with status %d", v.Command, res.code))
		return
	}
	finish("done", &code32, outStr, errStr, "")
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func (n *Nix) flushJobOutput(ctx context.Context, q *store.Queries, id uuid.UUID, outBuf, errBuf *tailBuffer) func() {
	done := make(chan struct{})
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(nixOutputFlushEvery)
		defer t.Stop()
		var lastOut, lastErr string
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				return
			case <-t.C:
				curOut := sanitizeJobText(outBuf.String())
				curErr := sanitizeJobText(errBuf.String())
				if curOut == lastOut && curErr == lastErr {
					continue
				}
				if err := q.UpdateCustomAppNixJobOutput(ctx, store.UpdateCustomAppNixJobOutputParams{
					ID: id, Stdout: curOut, Stderr: curErr,
				}); err == nil {
					lastOut, lastErr = curOut, curErr
				}
			}
		}
	}()
	return func() {
		close(done)
		wg.Wait()
	}
}

func exitCodeFromErr(err error) (int32, bool) {
	if err == nil {
		return 0, true
	}
	var exitErr *exec.ExitError
	if errors.As(err, &exitErr) {
		return int32(exitErr.ExitCode()), true
	}
	return 0, false
}

func locatePackageCommand(pkgPaths []string, command string) (string, error) {
	for _, p := range pkgPaths {
		cand := filepath.Join(p, "bin", command)
		info, err := os.Stat(cand)
		if err != nil || info.IsDir() {
			continue
		}
		if runtime.GOOS != "windows" && info.Mode()&0o111 == 0 {
			continue
		}
		return cand, nil
	}
	return "", fmt.Errorf("command %q was not found in bin/ of the requested packages", command)
}

func hasBinDir(p string) bool {
	info, err := os.Stat(filepath.Join(p, "bin"))
	return err == nil && info.IsDir()
}

func anyHasBinDir(paths []string) bool {
	for _, p := range paths {
		if hasBinDir(p) {
			return true
		}
	}
	return false
}

func allDirsExist(paths []string) bool {
	if len(paths) == 0 {
		return false
	}
	for _, p := range paths {
		info, err := os.Stat(p)
		if err != nil || !info.IsDir() {
			return false
		}
	}
	return true
}

func (n *Nix) resolvePackage(ctx context.Context, pkg string) ([]string, error) {
	ref := n.flakeRef()
	key := ref + "#" + pkg

	for {
		n.mu.Lock()
		if c, ok := n.cache[key]; ok && time.Since(c.at) < nixResolveTTL {
			cachedPaths := append([]string(nil), c.paths...)
			n.mu.Unlock()
			if allDirsExist(cachedPaths) {
				return cachedPaths, nil
			}
			n.mu.Lock()
			if cur, ok := n.cache[key]; ok && slices.Equal(cur.paths, cachedPaths) {
				delete(n.cache, key)
			}
		}
		if fl, ok := n.inflight[key]; ok {
			n.mu.Unlock()
			select {
			case <-fl.done:
				if fl.err == nil {
					return append([]string(nil), fl.paths...), nil
				}
				if errors.Is(fl.err, context.Canceled) && ctx.Err() == nil {
					continue
				}
				return nil, fl.err
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
		if n.inflight == nil {
			n.inflight = map[string]*resolveFlight{}
		}
		fl := &resolveFlight{done: make(chan struct{})}
		n.inflight[key] = fl
		n.mu.Unlock()

		var rawPaths []string
		var rerr error
		if n.Resolve != nil {
			var p string
			p, rerr = n.Resolve(ctx, pkg)
			if rerr == nil && strings.TrimSpace(p) != "" {
				rawPaths = []string{p}
			}
		} else {
			rawPaths, rerr = n.buildPackage(ctx, ref, pkg)
		}

		var resolved []string
		if rerr == nil {
			seen := make(map[string]bool, len(rawPaths))
			for _, p := range rawPaths {
				if abs, aerr := filepath.Abs(p); aerr == nil {
					p = abs
				}
				if eval, eerr := filepath.EvalSymlinks(p); eerr == nil {
					p = eval
				}
				info, serr := os.Stat(p)
				if serr != nil || !info.IsDir() {
					rerr = fmt.Errorf("resolved Nix package %q is not a directory", pkg)
					resolved = nil
					break
				}
				if !seen[p] {
					seen[p] = true
					resolved = append(resolved, p)
				}
			}
			if rerr == nil && len(resolved) == 0 {
				rerr = fmt.Errorf("resolved Nix package %q produced no store paths", pkg)
			}
		}

		n.mu.Lock()
		delete(n.inflight, key)
		if rerr == nil {
			if n.cache == nil {
				n.cache = map[string]cachedNixPkg{}
			}
			n.cache[key] = cachedNixPkg{paths: append([]string(nil), resolved...), at: time.Now()}
		}
		n.mu.Unlock()

		fl.paths = resolved
		fl.err = rerr
		close(fl.done)
		return append([]string(nil), resolved...), rerr
	}
}

func (n *Nix) findNixBinary() (string, error) {
	if b := strings.TrimSpace(n.NixBinary); b != "" {
		return b, nil
	}
	if b := strings.TrimSpace(os.Getenv("VESPER_NIX_BIN")); b != "" {
		return b, nil
	}
	if p, err := exec.LookPath("nix"); err == nil {
		return p, nil
	}
	candidates := []string{
		"/nix/var/nix/profiles/default/bin/nix",
		"/run/current-system/sw/bin/nix",
		"/opt/homebrew/bin/nix",
		"/usr/local/bin/nix",
	}
	if home, err := os.UserHomeDir(); err == nil && home != "" {
		candidates = append(candidates, filepath.Join(home, ".nix-profile", "bin", "nix"))
	}
	for _, c := range candidates {
		if info, err := os.Stat(c); err == nil && !info.IsDir() {
			return c, nil
		}
	}
	return "", errors.New("nix binary not found on host; install Nix (or set VESPER_NIX_BIN)")
}

func (n *Nix) buildPackage(ctx context.Context, flakeRef, pkg string) ([]string, error) {
	bin, err := n.findNixBinary()
	if err != nil {
		return nil, err
	}
	paths, err := n.buildInstallablePaths(ctx, bin, flakeRef+"#"+pkg)
	if err != nil {
		return nil, err
	}
	// Multi-output Nixpkgs derivations (e.g. ffmpeg, curl) can default to an empty
	// "out" output while placing executables in "^bin" (or vice versa when a non-bin
	// output like "dist" is built first). Only fetch ^bin/^out when no built output
	// already exposes a bin/ directory.
	if !anyHasBinDir(paths) && !strings.ContainsAny(pkg, ".^") {
		for _, outName := range []string{"bin", "out"} {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			extra, berr := n.buildInstallablePaths(ctx, bin, flakeRef+"#"+pkg+"^"+outName)
			if berr != nil {
				if ctx.Err() != nil {
					return nil, ctx.Err()
				}
				continue
			}
			paths = appendUniqueStrings(paths, extra...)
			if anyHasBinDir(paths) {
				break
			}
		}
	}
	// Put outputs with bin/ first so command lookup and PATH prefer executable outputs.
	var withBin, withoutBin []string
	for _, p := range paths {
		if hasBinDir(p) {
			withBin = append(withBin, p)
		} else {
			withoutBin = append(withoutBin, p)
		}
	}
	return append(withBin, withoutBin...), nil
}

func appendUniqueStrings(dst []string, items ...string) []string {
	seen := make(map[string]bool, len(dst)+len(items))
	for _, s := range dst {
		seen[s] = true
	}
	for _, s := range items {
		if s != "" && !seen[s] {
			seen[s] = true
			dst = append(dst, s)
		}
	}
	return dst
}

func (n *Nix) buildInstallablePaths(ctx context.Context, bin, installable string) ([]string, error) {
	rctx, cancel := context.WithTimeout(ctx, nixResolveTimeout)
	defer cancel()

	cmd := exec.CommandContext(rctx, bin,
		"--extra-experimental-features", "nix-command flakes",
		"build", "--no-link", "--print-out-paths",
		installable,
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process != nil {
			return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		}
		return nil
	}
	cmd.WaitDelay = 2 * time.Second

	var stdout, stderr tailBuffer
	stdout.limit = 64 << 10
	stderr.limit = 32 << 10
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if rctx.Err() != nil {
			return nil, rctx.Err()
		}
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("nix build %s failed: %s", installable, truncate(msg, 300))
	}
	var paths []string
	for _, line := range strings.Split(stdout.String(), "\n") {
		p := strings.TrimSpace(line)
		if p != "" {
			paths = appendUniqueStrings(paths, p)
		}
	}
	if len(paths) == 0 {
		return nil, fmt.Errorf("nix build %s produced no store path", installable)
	}
	return paths, nil
}

// Status reports one job and its output files. A job left resolving/running
// with no active worker in this process was interrupted by a restart and is marked failed.
func (n *Nix) Status(ctx context.Context, appID, id uuid.UUID) (NixJob, error) {
	if n == nil || n.Pool == nil {
		return NixJob{}, errors.New("nix runner is unavailable")
	}
	q := store.New(n.Pool)
	row, err := q.GetCustomAppNixJob(ctx, store.GetCustomAppNixJobParams{ID: id, AppID: appID})
	if errors.Is(err, pgx.ErrNoRows) {
		return NixJob{}, apperr.ErrNotFound
	}
	if err != nil {
		return NixJob{}, err
	}
	if (row.State == "resolving" || row.State == "running") && !n.isActive(id) {
		if _, err := q.FinishCustomAppNixJob(ctx, store.FinishCustomAppNixJobParams{
			ID: id, State: "failed", ExitCode: row.ExitCode, Stdout: row.Stdout, Stderr: row.Stderr, Error: nixInterruptedText,
		}); err != nil {
			return NixJob{}, err
		}
		row.State = "failed"
		row.Error = nixInterruptedText
	}
	if strings.HasPrefix(row.WorkDir, vmWorkDirPrefix) {
		return nixJobFromRow(row, []NixFile{}), nil
	}
	return nixJobFromRow(row, listWorkFiles(row.WorkDir)), nil
}

// Cancel stops a running Nix job if active and returns its updated status.
func (n *Nix) Cancel(ctx context.Context, appID, id uuid.UUID) (NixJob, error) {
	if n == nil || n.Pool == nil {
		return NixJob{}, errors.New("nix runner is unavailable")
	}
	if _, err := store.New(n.Pool).GetCustomAppNixJob(ctx, store.GetCustomAppNixJobParams{ID: id, AppID: appID}); errors.Is(err, pgx.ErrNoRows) {
		return NixJob{}, apperr.ErrNotFound
	} else if err != nil {
		return NixJob{}, err
	}
	if aj := n.getActive(id); aj != nil {
		aj.canceled.Store(true)
		aj.cancel()
		select {
		case <-aj.done:
		case <-ctx.Done():
			return NixJob{}, ctx.Err()
		}
	}
	return n.Status(ctx, appID, id)
}

// Delete stops a running Nix job if active and removes its DB row and scratch files.
func (n *Nix) Delete(ctx context.Context, appID, id uuid.UUID) error {
	if n == nil || n.Pool == nil {
		return errors.New("nix runner is unavailable")
	}
	if _, err := store.New(n.Pool).GetCustomAppNixJob(ctx, store.GetCustomAppNixJobParams{ID: id, AppID: appID}); errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound
	} else if err != nil {
		return err
	}
	if aj := n.getActive(id); aj != nil {
		aj.canceled.Store(true)
		aj.cancel()
		select {
		case <-aj.done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	workDir, err := store.New(n.Pool).DeleteCustomAppNixJob(ctx, store.DeleteCustomAppNixJobParams{ID: id, AppID: appID})
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound
	}
	if err != nil {
		return err
	}
	if strings.HasPrefix(workDir, vmWorkDirPrefix) {
		if vm := n.vm(); vm != nil {
			guestJobRoot := path.Dir(strings.TrimPrefix(workDir, vmWorkDirPrefix))
			_ = vm.UnlinkAppVMPaths(ctx, VMAppSpec{AppID: appID}, []string{guestJobRoot}, true)
		}
		return nil
	}
	if workDir != "" {
		_ = os.RemoveAll(filepath.Dir(workDir))
	}
	_ = os.RemoveAll(filepath.Join(n.scratchRoot(), appID.String(), id.String()))
	return nil
}

// ResolveJobFile validates that relPath points to an existing regular file
// inside the job's working directory (never symlinks or .mounts/).
func (n *Nix) ResolveJobFile(ctx context.Context, appID, jobID uuid.UUID, relPath string) (absPath string, cleanRel string, info os.FileInfo, err error) {
	if n == nil || n.Pool == nil {
		return "", "", nil, errors.New("nix runner is unavailable")
	}
	row, err := store.New(n.Pool).GetCustomAppNixJob(ctx, store.GetCustomAppNixJobParams{ID: jobID, AppID: appID})
	if errors.Is(err, pgx.ErrNoRows) {
		return "", "", nil, apperr.ErrNotFound
	}
	if err != nil {
		return "", "", nil, err
	}
	if strings.TrimSpace(row.WorkDir) == "" {
		return "", "", nil, apperr.Conflict("job has no working directory")
	}
	raw := strings.TrimSpace(relPath)
	if raw == "" || strings.ContainsRune(raw, 0) || strings.ContainsRune(raw, '\\') || strings.HasPrefix(raw, "/") || filepath.IsAbs(raw) {
		return "", "", nil, apperr.Invalid("path", "path must be a relative file inside the job working directory")
	}
	cleanRel = path.Clean(raw)
	if cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") || strings.Contains(cleanRel, "/../") {
		return "", "", nil, apperr.Invalid("path", "path escapes the job working directory")
	}
	if cleanRel == ".mounts" || strings.HasPrefix(cleanRel, ".mounts/") {
		return "", "", nil, apperr.Invalid("path", "mounted host files cannot be read or imported")
	}

	realWork, err := filepath.EvalSymlinks(row.WorkDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return "", "", nil, apperr.ErrNotFound
		}
		return "", "", nil, err
	}

	cur := row.WorkDir
	for _, part := range strings.Split(cleanRel, "/") {
		cur = filepath.Join(cur, part)
		linfo, lerr := os.Lstat(cur)
		if lerr != nil {
			if errors.Is(lerr, os.ErrNotExist) {
				return "", "", nil, apperr.ErrNotFound
			}
			return "", "", nil, lerr
		}
		if linfo.Mode()&os.ModeSymlink != 0 {
			return "", "", nil, apperr.Invalid("path", "symlinks inside the job working directory cannot be read or imported")
		}
		info = linfo
	}
	if info == nil || !info.Mode().IsRegular() {
		return "", "", nil, apperr.Invalid("path", "path must refer to a regular file")
	}
	realTarget, err := filepath.EvalSymlinks(cur)
	if err != nil {
		return "", "", nil, err
	}
	relCheck, err := filepath.Rel(realWork, realTarget)
	if err != nil || relCheck == "." || relCheck == ".." || strings.HasPrefix(relCheck, ".."+string(filepath.Separator)) {
		return "", "", nil, apperr.Invalid("path", "path escapes the job working directory")
	}
	return realTarget, cleanRel, info, nil
}

// ReadFile reads one output file from a job's working directory up to MaxReadBytes.
func (n *Nix) ReadFile(ctx context.Context, appID, jobID uuid.UUID, relPath, encoding string) (map[string]any, error) {
	if n == nil || n.Pool == nil {
		return nil, errors.New("nix runner is unavailable")
	}
	enc := strings.ToLower(strings.TrimSpace(encoding))
	if enc == "" {
		enc = "utf8"
	}
	if enc != "utf8" && enc != "base64" {
		return nil, apperr.Invalid("encoding", "encoding must be utf8 or base64")
	}
	row, err := store.New(n.Pool).GetCustomAppNixJob(ctx, store.GetCustomAppNixJobParams{ID: jobID, AppID: appID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	if strings.HasPrefix(row.WorkDir, vmWorkDirPrefix) {
		return n.readVMJobFile(ctx, appID, strings.TrimPrefix(row.WorkDir, vmWorkDirPrefix), relPath, enc)
	}
	absPath, cleanRel, info, err := n.ResolveJobFile(ctx, appID, jobID, relPath)
	if err != nil {
		return nil, err
	}
	limit := n.maxReadBytes()
	if info.Size() > limit {
		return nil, apperr.Invalid("path", "file is %d MB, over the %d MB limit (use media.import for video files)", info.Size()>>20, limit>>20)
	}
	f, err := os.Open(absPath)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(raw)) > limit {
		return nil, apperr.Invalid("path", "file exceeds the %d MB limit", limit>>20)
	}
	return encodeNixReadFileResult(cleanRel, enc, raw)
}

func (n *Nix) readVMJobFile(ctx context.Context, appID uuid.UUID, guestWorkDir, relPath, enc string) (map[string]any, error) {
	vm := n.vm()
	if vm == nil {
		return nil, errors.New("custom app VM backend is unavailable")
	}
	rawPath := strings.TrimSpace(relPath)
	if rawPath == "" || strings.ContainsRune(rawPath, 0) || strings.ContainsRune(rawPath, '\\') || strings.HasPrefix(rawPath, "/") {
		return nil, apperr.Invalid("path", "path must be a relative file inside the job working directory")
	}
	cleanRel := path.Clean(rawPath)
	if cleanRel == "." || cleanRel == ".." || strings.HasPrefix(cleanRel, "../") || strings.Contains(cleanRel, "/../") {
		return nil, apperr.Invalid("path", "path must stay inside the job working directory")
	}
	if cleanRel == ".mounts" || strings.HasPrefix(cleanRel, ".mounts/") {
		return nil, apperr.Invalid("path", "mounted host directories cannot be read back through nix.readFile")
	}
	limit := n.maxReadBytes()
	raw, err := vm.ReadAppVMFile(ctx, VMAppSpec{AppID: appID}, path.Join(guestWorkDir, cleanRel), limit+1)
	if err != nil {
		return nil, err
	}
	if int64(len(raw)) > limit {
		return nil, apperr.Invalid("path", "file exceeds the %d MB limit", limit>>20)
	}
	return encodeNixReadFileResult(cleanRel, enc, raw)
}

func encodeNixReadFileResult(cleanRel, enc string, raw []byte) (map[string]any, error) {
	var content string
	if enc == "utf8" {
		if !utf8.Valid(raw) {
			return nil, apperr.Invalid("encoding", "file is binary; pass encoding: \"base64\"")
		}
		content = string(raw)
	} else {
		content = base64.StdEncoding.EncodeToString(raw)
	}
	return map[string]any{
		"path":     cleanRel,
		"size":     int64(len(raw)),
		"encoding": enc,
		"content":  content,
	}, nil
}

// forget stops active jobs whose app was deleted and cleans up scratch dirs, best effort.
func (n *Nix) forget(_ context.Context, rows []store.ListCustomAppNixJobWorkDirsRow) {
	if n == nil {
		return
	}
	for _, r := range rows {
		var jobRoot string
		if aj := n.getActive(r.ID); aj != nil {
			jobRoot = aj.jobRoot
			aj.canceled.Store(true)
			aj.cancel()
			<-aj.done
		}
		if r.WorkDir != "" && !strings.HasPrefix(r.WorkDir, vmWorkDirPrefix) {
			_ = os.RemoveAll(filepath.Dir(r.WorkDir))
		}
		if jobRoot != "" && !strings.HasPrefix(jobRoot, vmWorkDirPrefix) {
			_ = os.RemoveAll(jobRoot)
		}
	}
}

// Close cancels running Nix jobs and waits for them to clean up.
func (n *Nix) Close() {
	if n == nil {
		return
	}
	n.mu.Lock()
	for _, aj := range n.active {
		aj.canceled.Store(true)
		aj.cancel()
	}
	n.mu.Unlock()
	n.wg.Wait()
}

func (n *Nix) isActive(id uuid.UUID) bool {
	return n.getActive(id) != nil
}

func (n *Nix) getActive(id uuid.UUID) *activeNixJob {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.active[id]
}

func nixJobFromRow(r store.CustomAppNixJob, files []NixFile) NixJob {
	pkgs := r.Packages
	if pkgs == nil {
		pkgs = []string{}
	}
	if files == nil {
		files = []NixFile{}
	}
	return NixJob{
		ID:        r.ID,
		Packages:  pkgs,
		Command:   r.Command,
		State:     r.State,
		ExitCode:  r.ExitCode,
		Stdout:    r.Stdout,
		Stderr:    r.Stderr,
		Files:     files,
		Error:     r.Error,
		CreatedAt: r.CreatedAt,
		UpdatedAt: r.UpdatedAt,
	}
}

func listWorkFiles(workDir string) []NixFile {
	out := []NixFile{}
	if strings.TrimSpace(workDir) == "" {
		return out
	}
	_ = filepath.WalkDir(workDir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if p == workDir {
			return nil
		}
		rel, rerr := filepath.Rel(workDir, p)
		if rerr != nil {
			return nil
		}
		slashed := filepath.ToSlash(rel)
		if slashed == ".mounts" || strings.HasPrefix(slashed, ".mounts/") {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.Type()&os.ModeSymlink != 0 {
			if d.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, ierr := d.Info()
		if ierr != nil || !info.Mode().IsRegular() {
			return nil
		}
		out = append(out, NixFile{Path: slashed, Size: info.Size()})
		if len(out) >= nixMaxWorkFiles {
			return filepath.SkipAll
		}
		return nil
	})
	return out
}

func sanitizeJobText(s string) string {
	if !strings.ContainsRune(s, 0) && utf8.ValidString(s) {
		return s
	}
	return strings.ReplaceAll(strings.ToValidUTF8(s, ""), "\x00", "")
}

type tailBuffer struct {
	mu        sync.Mutex
	limit     int
	buf       []byte
	truncated bool
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.limit <= 0 {
		return len(p), nil
	}
	if len(p) >= b.limit {
		b.buf = append(b.buf[:0], p[len(p)-b.limit:]...)
		b.truncated = true
		return len(p), nil
	}
	total := len(b.buf) + len(p)
	if total > b.limit {
		drop := total - b.limit
		copy(b.buf, b.buf[drop:])
		b.buf = b.buf[:len(b.buf)-drop]
		b.truncated = true
	}
	b.buf = append(b.buf, p...)
	return len(p), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	s := strings.ToValidUTF8(string(b.buf), "")
	if b.truncated {
		return "...(truncated)\n" + s
	}
	return s
}

// handleNixRPC serves server.ts's nix.start/run/status/cancel/delete/readFile.
// Starting or running packages checks nix:<pkg> for every requested package;
// status, cancel, delete, and readFile touch only this app's own jobs.
func handleNixRPC(ctx context.Context, mc *MCPCallContext, method string, raw json.RawMessage) (any, error) {
	if mc.Nix == nil || mc.AppID == uuid.Nil {
		return nil, errors.New("nix package runner is unavailable")
	}
	switch method {
	case "nix_start", "nix_run":
		var in NixStartInput
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		pkgs, cmdName, err := validateNixPackagesAndCommand(in.Packages, in.Command)
		if err != nil {
			return nil, err
		}
		for _, pkg := range pkgs {
			if err := checkWorkerCapability(ctx, mc, "nix:"+pkg, fmt.Sprintf("Run Nix package nixpkgs#%s (%s)", pkg, cmdName)); err != nil {
				return nil, err
			}
		}
		in.AllowPublic = ModeFor(mc.Capabilities, "app.http:outbound") == agentdef.Allowed
		if method == "nix_start" {
			return mc.Nix.Start(ctx, mc.AppID, mc.Slug, mc.Mounts, in)
		}
		return mc.Nix.Run(ctx, mc.AppID, mc.Slug, mc.Mounts, in)

	case "nix_status", "nix_cancel", "nix_delete":
		var in struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		id, err := uuid.Parse(strings.TrimSpace(in.ID))
		if err != nil {
			return nil, apperr.Invalid("id", "invalid job id")
		}
		switch method {
		case "nix_status":
			return mc.Nix.Status(ctx, mc.AppID, id)
		case "nix_cancel":
			return mc.Nix.Cancel(ctx, mc.AppID, id)
		default:
			if err := mc.Nix.Delete(ctx, mc.AppID, id); err != nil {
				return nil, err
			}
			return map[string]any{"deleted": id}, nil
		}

	case "nix_read_file":
		var in struct {
			ID       string `json:"id"`
			Path     string `json:"path"`
			Encoding string `json:"encoding"`
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		id, err := uuid.Parse(strings.TrimSpace(in.ID))
		if err != nil {
			return nil, apperr.Invalid("id", "invalid job id")
		}
		return mc.Nix.ReadFile(ctx, mc.AppID, id, in.Path, in.Encoding)

	default:
		return nil, fmt.Errorf("unknown nix RPC method %q", method)
	}
}

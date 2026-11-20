package runner

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// MacOSEnv is set to "1" in a run's processes when `mac` can reach a macOS
// guest, so personas (and their instructions) know it's there.
const MacOSEnv = "VESPER_MACOS"

const (
	// macOSVMLimit is Apple's cap on macOS VMs running at once on one Mac
	// (VZErrorVirtualMachineLimitExceeded beyond it).
	macOSVMLimit = 2

	defaultMacGuestWorkspace = "/opt/vesper/workspace"
	defaultMacUser           = "admin"
	defaultMacIdleTTL        = 10 * time.Minute
	defaultMacBootTimeout    = 3 * time.Minute
	macGuestPath             = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

	macSyncedFile    = "synced.json"
	macMachineIDFile = "machine-id.bin"
	macRmBatch       = 500
	macStderrKeep    = 8 << 10
)

// defaultMacPrepareTimeout bounds the root command that readies a freshly
// booted guest. It takes a second or two; a guest that accepts it and never
// answers would otherwise hold the boot, and every call waiting on it, forever.
const defaultMacPrepareTimeout = time.Minute

// defaultMacStopTimeout bounds stopping a macOS VM. Virtualization.framework's
// stop can block indefinitely; past this the stop is left to finish in the
// background so callers and the slot count move on.
const defaultMacStopTimeout = 30 * time.Second

// macPingTimeout bounds the liveness check before a call reuses a VM. A
// healthy agent answers over vsock in milliseconds.
const macPingTimeout = 5 * time.Second

var errMacClosed = errors.New("mac: macOS guests are shutting down")

// MacOSGuests runs the macOS guest VMs that `mac` in a run's Linux VM builds
// and tests in. Nothing boots until a run's first `mac` call: the VM then
// stays up for that run's later calls and stops after IdleTTL without one.
// At most MaxVMs (never more than Apple's 2) run at once; a call that finds
// them all busy waits, and one that finds an idle VM of another run stops it
// to take its slot. A run's disk outlives its VM, so builds stay incremental
// until the run's workspace is removed.
//
// The macOS guest gets no network, no harness and no credentials: it only
// receives the run's files and the commands `mac` runs.
type MacOSGuests struct {
	Driver microvm.Driver
	Image  *microvm.MacOSImage
	// StateDir is the MicroVM backend's; a run's macOS disk lives in
	// StateDir/runs/<run>/macos and goes with the run's workspace.
	StateDir string
	MaxVMs   int
	IdleTTL  time.Duration
	CPUs     int
	MemoryMB int64
	// User is the image's account that commands run as (Tart's images use
	// "admin").
	User        string
	BootTimeout time.Duration
	// GuestWorkspace is where the synced files live in the guest.
	GuestWorkspace string
	Log            *slog.Logger

	// prepareTimeout and stopTimeout default to defaultMacPrepareTimeout and
	// defaultMacStopTimeout; tests shorten them.
	prepareTimeout time.Duration
	stopTimeout    time.Duration

	mu       sync.Mutex
	changed  chan struct{}
	vms      map[string]*macVM
	stopping int
	closed   bool
}

type macVM struct {
	runID string
	dir   string
	// vm is nil while booting; ready closes when the boot ends either way.
	vm       microvm.VM
	ready    chan struct{}
	bootErr  error
	uid, gid int
	active   int
	lastUsed time.Time
	idle     *time.Timer
	// syncMu orders uploads: each reads and rewrites the synced record.
	syncMu sync.Mutex
}

func (g *MacOSGuests) logger() *slog.Logger {
	if g.Log != nil {
		return g.Log
	}
	return slog.New(slog.NewTextHandler(io.Discard, nil))
}

func (g *MacOSGuests) maxVMs() int {
	if g.MaxVMs <= 0 || g.MaxVMs > macOSVMLimit {
		return macOSVMLimit
	}
	return g.MaxVMs
}

func (g *MacOSGuests) idleTTL() time.Duration {
	if g.IdleTTL > 0 {
		return g.IdleTTL
	}
	return defaultMacIdleTTL
}

func (g *MacOSGuests) guestWorkspace() string {
	if g.GuestWorkspace != "" {
		return g.GuestWorkspace
	}
	return defaultMacGuestWorkspace
}

func (g *MacOSGuests) user() string {
	if g.User != "" {
		return g.User
	}
	return defaultMacUser
}

func (g *MacOSGuests) runDir(runID string) (string, error) {
	key, err := safeVMRunKey(runID)
	if err != nil {
		return "", err
	}
	if g.StateDir == "" {
		return "", errors.New("mac: StateDir is required")
	}
	return filepath.Join(g.StateDir, "runs", key, "macos"), nil
}

// notifyLocked wakes every call waiting for a slot. The caller holds g.mu.
func (g *MacOSGuests) notifyLocked() {
	if g.changed != nil {
		close(g.changed)
	}
	g.changed = make(chan struct{})
}

func (g *MacOSGuests) waitChanLocked() <-chan struct{} {
	if g.changed == nil {
		g.changed = make(chan struct{})
	}
	return g.changed
}

// acquire returns runID's running macOS VM, booting it first when needed, and
// counts the caller as using it until release. status hears about waiting
// for a slot and booting.
func (g *MacOSGuests) acquire(ctx context.Context, runID string, status func(guestproto.MacStatus)) (*macVM, error) {
	if status == nil {
		status = func(guestproto.MacStatus) {}
	}
	dir, err := g.runDir(runID)
	if err != nil {
		return nil, err
	}
	waited := false
	g.mu.Lock()
	for {
		if g.closed {
			g.mu.Unlock()
			return nil, errMacClosed
		}
		if g.vms == nil {
			g.vms = make(map[string]*macVM)
		}
		if v := g.vms[runID]; v != nil {
			if v.vm == nil {
				ready := v.ready
				g.mu.Unlock()
				select {
				case <-ready:
				case <-ctx.Done():
					return nil, ctx.Err()
				}
				if v.bootErr != nil {
					return nil, v.bootErr
				}
				g.mu.Lock()
				continue
			}
			v.active++
			if v.idle != nil {
				v.idle.Stop()
				v.idle = nil
			}
			g.mu.Unlock()
			pingErr := g.ping(ctx, v)
			if pingErr == nil {
				return v, nil
			}
			if ctx.Err() != nil {
				g.release(v)
				return nil, ctx.Err()
			}
			// The guest went away (shut down, crashed, or its agent stopped
			// listening) after an earlier call. Replace it rather than fail
			// every call until the idle timer reaps it.
			g.mu.Lock()
			if g.vms[runID] != v || v.active > 1 {
				// Another call is still using it (or already replaced it);
				// don't stop a VM out from under that call.
				g.mu.Unlock()
				g.release(v)
				return nil, fmt.Errorf("mac: this run's macOS VM stopped answering: %w", pingErr)
			}
			v.active--
			g.logger().Warn("mac: macOS VM stopped answering; booting a new one", "run", runID, "err", pingErr, "console", v.vm.ConsoleOutput())
			g.evictLocked(v)
			g.mu.Unlock()
			g.stopEvicted(v)
			g.mu.Lock()
			continue
		}
		if len(g.vms)+g.stopping < g.maxVMs() {
			v := &macVM{runID: runID, dir: dir, ready: make(chan struct{})}
			g.vms[runID] = v
			g.mu.Unlock()
			return g.bootInto(ctx, v, status)
		}
		if victim := g.lruIdleLocked(); victim != nil {
			g.logger().Info("mac: stopping an idle macOS VM for another run", "idle_run", victim.runID, "run", runID)
			g.evictLocked(victim)
			g.mu.Unlock()
			g.stopEvicted(victim)
			g.mu.Lock()
			continue
		}
		if !waited {
			waited = true
			status(guestproto.MacStatus{Status: "waiting", Message: fmt.Sprintf("all %d macOS VMs are busy with other runs; waiting for one to free up", g.maxVMs())})
		}
		ch := g.waitChanLocked()
		g.mu.Unlock()
		select {
		case <-ch:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
		g.mu.Lock()
	}
}

// bootInto boots v, which acquire put in g.vms. The boot doesn't stop when
// the caller gives up, so a call cut short (a persona's Ctrl-C, a tool
// timeout) still leaves the VM warm for the next one.
func (g *MacOSGuests) bootInto(ctx context.Context, v *macVM, status func(guestproto.MacStatus)) (*macVM, error) {
	status(guestproto.MacStatus{Status: "booting", Message: "starting this run's macOS VM"})
	start := time.Now()
	vm, uid, gid, err := g.boot(context.WithoutCancel(ctx), v.dir)

	g.mu.Lock()
	defer g.mu.Unlock()
	if err == nil && g.closed {
		err = errMacClosed
		go func() { _ = vm.Stop(context.Background()) }()
	}
	if err != nil {
		if g.vms[v.runID] == v {
			delete(g.vms, v.runID)
		}
		v.bootErr = err
		close(v.ready)
		g.notifyLocked()
		g.logger().Warn("mac: macOS VM boot failed", "run", v.runID, "err", err)
		return nil, err
	}
	g.logger().Info("mac: macOS VM booted", "run", v.runID, "took", time.Since(start).Round(time.Millisecond))
	v.vm, v.uid, v.gid = vm, uid, gid
	v.lastUsed = time.Now()
	close(v.ready)
	g.notifyLocked()
	if ctx.Err() != nil {
		g.armIdleLocked(v)
		return nil, ctx.Err()
	}
	v.active = 1
	return v, nil
}

// boot clones the golden image into dir (once per run), starts the VM and
// prepares the workspace, returning the build user's uid and gid.
func (g *MacOSGuests) boot(ctx context.Context, dir string) (microvm.VM, int, int, error) {
	if g.Driver == nil || g.Image == nil {
		return nil, 0, 0, errors.New("mac: macOS guests aren't configured")
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, 0, 0, err
	}
	disk := filepath.Join(dir, microvm.MacOSDiskFile)
	aux := filepath.Join(dir, microvm.MacOSAuxFile)
	for src, dst := range map[string]string{g.Image.DiskPath: disk, g.Image.AuxPath: aux} {
		if err := cloneOnce(src, dst); err != nil {
			return nil, 0, 0, fmt.Errorf("mac: copy golden image: %w", err)
		}
	}
	timeout := g.BootTimeout
	if timeout <= 0 {
		timeout = defaultMacBootTimeout
	}
	cpus := g.CPUs
	if cpus <= 0 {
		cpus = 4
	}
	memMB := g.MemoryMB
	if memMB <= 0 {
		memMB = 8192
	}
	vm, err := g.Driver.Start(ctx, microvm.VMConfig{
		MacOS: &microvm.MacOSBoot{
			HardwareModel:  g.Image.HardwareModel,
			AuxStoragePath: aux,
			MachineIDPath:  filepath.Join(dir, macMachineIDFile),
		},
		CPUs:        cpus,
		MemoryBytes: uint64(memMB) << 20,
		Drives:      []microvm.DriveSpec{{Path: disk}},
		BootTimeout: timeout,
	})
	if err != nil {
		return nil, 0, 0, fmt.Errorf("mac: boot macOS VM: %w", err)
	}
	pctx, cancel := context.WithTimeout(ctx, durationOr(g.prepareTimeout, defaultMacPrepareTimeout))
	uid, gid, err := g.prepareWorkspace(pctx, vm)
	cancel()
	if err != nil {
		g.stopVM(vm, dir)
		return nil, 0, 0, err
	}
	return vm, uid, gid, nil
}

// ping checks that v's guest agent still answers. A booted VM can stop
// answering between calls, and the host isn't told when a guest shuts itself
// down or its agent stops listening.
func (g *MacOSGuests) ping(ctx context.Context, v *macVM) error {
	pctx, cancel := context.WithTimeout(ctx, macPingTimeout)
	defer cancel()
	_, err := v.vm.Client().Ping(pctx)
	return err
}

// stopVM stops vm, giving up after stopTimeout. A stop that's still blocked
// then finishes in the background; until it does, the VM may still count
// against Apple's limit, so a boot meanwhile can fail with a limit error
// rather than hang. who names the VM (its run or directory) in the logs.
func (g *MacOSGuests) stopVM(vm microvm.VM, who string) {
	timeout := durationOr(g.stopTimeout, defaultMacStopTimeout)
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	done := make(chan error, 1)
	go func() {
		defer cancel()
		done <- vm.Stop(ctx)
	}()
	select {
	case err := <-done:
		if err != nil {
			g.logger().Warn("mac: stop macOS VM", "vm", who, "err", err)
		}
	case <-time.After(timeout):
		g.logger().Warn("mac: stopping a macOS VM is taking too long; leaving it to finish in the background", "vm", who, "after", timeout)
	}
}

func durationOr(d, def time.Duration) time.Duration {
	if d > 0 {
		return d
	}
	return def
}

// cloneOnce copies src to dst unless dst exists, never leaving half a copy.
func cloneOnce(src, dst string) error {
	if _, err := os.Stat(dst); err == nil {
		return nil
	}
	tmp := dst + ".tmp"
	if err := cloneFile(src, tmp); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	return os.Rename(tmp, dst)
}

// prepareWorkspace makes the guest workspace, owned by the build user, and
// looks that user's ids up in the guest. It runs as root: the only root
// command, with fixed arguments.
func (g *MacOSGuests) prepareWorkspace(ctx context.Context, vm microvm.VM) (int, int, error) {
	script := `set -e; mkdir -p "$1"; chown "$2" "$1"; id -u "$2"; id -g "$2"`
	out, errOut, code, err := runGuest(ctx, vm, guestproto.ExecReq{
		Argv: []string{"/bin/sh", "-c", script, "sh", g.guestWorkspace(), g.user()},
		Env:  map[string]string{"PATH": macGuestPath},
	}, nil)
	if err != nil {
		return 0, 0, fmt.Errorf("mac: prepare workspace: %w", err)
	}
	if code != 0 {
		return 0, 0, fmt.Errorf("mac: prepare workspace for user %q: exit %d: %s", g.user(), code, strings.TrimSpace(errOut))
	}
	fields := strings.Fields(out)
	if len(fields) != 2 {
		return 0, 0, fmt.Errorf("mac: unexpected id output %q", out)
	}
	uid, err1 := strconv.Atoi(fields[0])
	gid, err2 := strconv.Atoi(fields[1])
	if err1 != nil || err2 != nil || uid <= 0 {
		return 0, 0, fmt.Errorf("mac: user %q has no usable uid (%q)", g.user(), out)
	}
	return uid, gid, nil
}

// runGuest runs req to the end, feeding it stdin, and returns its stdout, the
// last of its stderr, and its exit code.
func runGuest(ctx context.Context, vm microvm.VM, req guestproto.ExecReq, stdin io.Reader) (string, string, int, error) {
	rp, err := vm.Client().StartExec(ctx, req)
	if err != nil {
		return "", "", -1, err
	}
	defer rp.Close()
	stop := context.AfterFunc(ctx, func() { _ = rp.Close() })
	defer stop()

	var out bytes.Buffer
	errOut := &tailBuffer{max: macStderrKeep}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(&out, io.LimitReader(rp.Stdout(), 1<<20))
		_, _ = io.Copy(io.Discard, rp.Stdout())
	}()
	go func() { defer wg.Done(); _, _ = io.Copy(errOut, rp.Stderr()) }()
	stdinErr := make(chan error, 1)
	go func() {
		in := rp.Stdin()
		var err error
		if stdin != nil {
			_, err = io.Copy(in, stdin)
		}
		if cerr := in.Close(); err == nil {
			err = cerr
		}
		stdinErr <- err
	}()
	ex, err := rp.Wait()
	wg.Wait()
	if err != nil {
		return out.String(), errOut.String(), -1, err
	}
	if serr := <-stdinErr; serr != nil && ex.Code == 0 {
		return out.String(), errOut.String(), -1, fmt.Errorf("send input: %w", serr)
	}
	if ex.Error != "" && ex.Code == 0 {
		return out.String(), errOut.String(), -1, errors.New(ex.Error)
	}
	return out.String(), errOut.String(), ex.Code, nil
}

// tailBuffer keeps the last max bytes written to it.
type tailBuffer struct {
	max int
	buf []byte
}

func (t *tailBuffer) Write(p []byte) (int, error) {
	t.buf = append(t.buf, p...)
	if len(t.buf) > t.max {
		t.buf = append([]byte(nil), t.buf[len(t.buf)-t.max:]...)
	}
	return len(p), nil
}

func (t *tailBuffer) String() string { return string(t.buf) }

func (g *MacOSGuests) release(v *macVM) {
	g.mu.Lock()
	defer g.mu.Unlock()
	if v.active > 0 {
		v.active--
	}
	v.lastUsed = time.Now()
	if v.active == 0 && g.vms[v.runID] == v {
		g.armIdleLocked(v)
	}
	// An idle VM is a slot a waiting call may take.
	g.notifyLocked()
}

// armIdleLocked stops v after IdleTTL unless a call uses it first. The
// caller holds g.mu.
func (g *MacOSGuests) armIdleLocked(v *macVM) {
	if v.idle != nil {
		v.idle.Stop()
	}
	v.idle = time.AfterFunc(g.idleTTL(), func() {
		g.mu.Lock()
		if g.vms[v.runID] != v || v.active > 0 || v.vm == nil {
			g.mu.Unlock()
			return
		}
		g.logger().Info("mac: stopping idle macOS VM", "run", v.runID)
		g.evictLocked(v)
		g.mu.Unlock()
		g.stopEvicted(v)
	})
}

// lruIdleLocked is the booted VM no call is using that was used longest ago.
func (g *MacOSGuests) lruIdleLocked() *macVM {
	var best *macVM
	for _, v := range g.vms {
		if v.vm == nil || v.active > 0 {
			continue
		}
		if best == nil || v.lastUsed.Before(best.lastUsed) {
			best = v
		}
	}
	return best
}

// evictLocked takes v out of g.vms, keeping its slot counted until
// stopEvicted has stopped it.
func (g *MacOSGuests) evictLocked(v *macVM) {
	delete(g.vms, v.runID)
	if v.idle != nil {
		v.idle.Stop()
		v.idle = nil
	}
	g.stopping++
}

func (g *MacOSGuests) stopEvicted(v *macVM) {
	g.stopVM(v.vm, v.runID)
	g.mu.Lock()
	g.stopping--
	g.notifyLocked()
	g.mu.Unlock()
}

// Stop stops runID's macOS VM, if it has one, waiting out a boot. Calls in
// flight fail. The run's disk stays until its workspace is removed.
func (g *MacOSGuests) Stop(runID string) {
	for {
		g.mu.Lock()
		v := g.vms[runID]
		if v == nil {
			g.mu.Unlock()
			return
		}
		if v.vm == nil {
			ready := v.ready
			g.mu.Unlock()
			<-ready
			continue
		}
		g.evictLocked(v)
		g.mu.Unlock()
		g.stopEvicted(v)
		return
	}
}

// StopAll stops every macOS VM.
func (g *MacOSGuests) StopAll() {
	g.mu.Lock()
	ids := make([]string, 0, len(g.vms))
	for id := range g.vms {
		ids = append(ids, id)
	}
	g.mu.Unlock()
	for _, id := range ids {
		g.Stop(id)
	}
}

// Close stops every macOS VM and refuses new calls.
func (g *MacOSGuests) Close() {
	g.mu.Lock()
	g.closed = true
	g.notifyLocked()
	g.mu.Unlock()
	g.StopAll()
}

// RunningVMs reports how many macOS VMs are booted or booting.
func (g *MacOSGuests) RunningVMs() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.vms) + g.stopping
}

// Handler serves runID's mac API at mac.vesper.internal.
func (g *MacOSGuests) Handler(runID string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST "+guestproto.MacPathStart, func(w http.ResponseWriter, r *http.Request) { g.serveStart(w, r, runID) })
	mux.HandleFunc("POST "+guestproto.MacPathPlan, func(w http.ResponseWriter, r *http.Request) { g.servePlan(w, r, runID) })
	mux.HandleFunc("POST "+guestproto.MacPathUpload, func(w http.ResponseWriter, r *http.Request) { g.serveUpload(w, r, runID) })
	mux.HandleFunc("POST "+guestproto.MacPathExec, func(w http.ResponseWriter, r *http.Request) { g.serveExec(w, r, runID) })
	mux.HandleFunc("POST "+guestproto.MacPathPull, func(w http.ResponseWriter, r *http.Request) { g.servePull(w, r, runID) })
	return mux
}

func (g *MacOSGuests) serveStart(w http.ResponseWriter, r *http.Request, runID string) {
	w.Header().Set("Content-Type", "application/x-ndjson")
	fw := newFlushWriter(w)
	send := func(st guestproto.MacStatus) {
		b, _ := json.Marshal(st)
		_, _ = fw.Write(append(b, '\n'))
	}
	v, err := g.acquire(r.Context(), runID, send)
	if err != nil {
		send(guestproto.MacStatus{Status: "error", Message: err.Error()})
		return
	}
	g.release(v)
	send(guestproto.MacStatus{Status: "ready"})
}

// servePlan answers which files differ from what was last synced. It reads
// only the host's record, so it needs no VM.
func (g *MacOSGuests) servePlan(w http.ResponseWriter, r *http.Request, runID string) {
	dir, err := g.runDir(runID)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	var req guestproto.MacPlanReq
	if err := json.NewDecoder(io.LimitReader(r.Body, guestproto.MacMaxManifestBytes)).Decode(&req); err != nil {
		http.Error(w, "mac: bad plan: "+err.Error(), http.StatusBadRequest)
		return
	}
	_, files, err := cleanManifest(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	synced, err := loadSynced(dir)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	need := []string{}
	for _, f := range files {
		if old, ok := synced[f.Path]; !ok || old != f {
			need = append(need, f.Path)
		}
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(guestproto.MacPlanResp{Need: need})
}

// serveUpload deletes the files the last sync had that this manifest drops,
// extracts the tar after the manifest, and records the manifest as synced.
func (g *MacOSGuests) serveUpload(w http.ResponseWriter, r *http.Request, runID string) {
	body := bufio.NewReaderSize(r.Body, 64<<10)
	m, err := guestproto.ReadMacManifest(body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	root, files, err := cleanManifest(m)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	v, err := g.acquire(r.Context(), runID, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer g.release(v)
	v.syncMu.Lock()
	defer v.syncMu.Unlock()

	synced, err := loadSynced(v.dir)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	next := make(map[string]guestproto.MacFile, len(files))
	for _, f := range files {
		next[f.Path] = f
	}
	var stale []string
	for p := range synced {
		if _, keep := next[p]; !keep && underMacRoot(p, root) {
			stale = append(stale, p)
		}
	}
	sort.Strings(stale)
	// Delete first: a path that turned from a file into a directory must be
	// gone before tar extracts under it.
	if err := g.removeGuestFiles(r.Context(), v, stale); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	for _, p := range stale {
		delete(synced, p)
	}
	_, errOut, code, err := runGuest(r.Context(), v.vm, g.userExec(v, []string{"/usr/bin/tar", "-xpf", "-"}, ""), body)
	if err == nil && code != 0 {
		err = fmt.Errorf("tar exit %d: %s", code, strings.TrimSpace(errOut))
	}
	if err != nil {
		// Keep what's known: the deletions happened, the extraction may have
		// partly. The next plan sends every file not recorded.
		_ = saveSynced(v.dir, synced)
		http.Error(w, "mac: extract files in the macOS VM: "+err.Error(), http.StatusInternalServerError)
		return
	}
	for p, f := range next {
		synced[p] = f
	}
	if err := saveSynced(v.dir, synced); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// removeGuestFiles deletes paths (relative to the guest workspace) as the
// build user, so a symlink the build planted can't aim a root delete.
func (g *MacOSGuests) removeGuestFiles(ctx context.Context, v *macVM, paths []string) error {
	for len(paths) > 0 {
		n := min(len(paths), macRmBatch)
		argv := []string{"/bin/rm", "-f", "--"}
		for _, p := range paths[:n] {
			argv = append(argv, "./"+p)
		}
		paths = paths[n:]
		_, errOut, code, err := runGuest(ctx, v.vm, g.userExec(v, argv, ""), nil)
		if err == nil && code != 0 {
			err = fmt.Errorf("rm exit %d: %s", code, strings.TrimSpace(errOut))
		}
		if err != nil {
			return fmt.Errorf("mac: delete removed files in the macOS VM: %w", err)
		}
	}
	return nil
}

func (g *MacOSGuests) serveExec(w http.ResponseWriter, r *http.Request, runID string) {
	var req guestproto.MacExecReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		http.Error(w, "mac: bad exec request: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(req.Argv) == 0 || req.Argv[0] == "" {
		http.Error(w, "mac: no command", http.StatusBadRequest)
		return
	}
	dir, err := guestproto.CleanMacPath(req.Dir, true)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	for k := range req.Env {
		if k == "" || strings.ContainsAny(k, "=\x00") {
			http.Error(w, fmt.Sprintf("mac: invalid env name %q", k), http.StatusBadRequest)
			return
		}
	}
	v, err := g.acquire(r.Context(), runID, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer g.release(v)
	exec := g.userExec(v, req.Argv, dir)
	for k, val := range req.Env {
		exec.Env[k] = val
	}
	g.streamGuest(w, r, v, exec)
}

func (g *MacOSGuests) servePull(w http.ResponseWriter, r *http.Request, runID string) {
	var req guestproto.MacPullReq
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&req); err != nil {
		http.Error(w, "mac: bad pull request: "+err.Error(), http.StatusBadRequest)
		return
	}
	if len(req.Paths) == 0 {
		http.Error(w, "mac: nothing to pull", http.StatusBadRequest)
		return
	}
	argv := []string{"/usr/bin/tar", "-cf", "-"}
	for _, p := range req.Paths {
		c, err := guestproto.CleanMacPath(p, false)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		argv = append(argv, "./"+c)
	}
	v, err := g.acquire(r.Context(), runID, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusServiceUnavailable)
		return
	}
	defer g.release(v)
	g.streamGuest(w, r, v, g.userExec(v, argv, ""))
}

// userExec runs argv as the build user in dir, relative to the guest
// workspace.
func (g *MacOSGuests) userExec(v *macVM, argv []string, dir string) guestproto.ExecReq {
	home := path.Join("/Users", g.user())
	return guestproto.ExecReq{
		Argv: argv,
		Dir:  path.Join(g.guestWorkspace(), dir),
		UID:  v.uid,
		GID:  v.gid,
		Env: map[string]string{
			"HOME":    home,
			"USER":    g.user(),
			"LOGNAME": g.user(),
			"PATH":    macGuestPath,
			"LANG":    "en_US.UTF-8",
			"TMPDIR":  "/tmp",
		},
	}
}

// streamGuest runs req and streams its output to w as guestproto frames,
// ending with FrameExecExit. A caller that hangs up kills the command: the
// guest agent kills its process group when the exec connection closes.
func (g *MacOSGuests) streamGuest(w http.ResponseWriter, r *http.Request, v *macVM, req guestproto.ExecReq) {
	rp, err := v.vm.Client().StartExec(r.Context(), req)
	if err != nil {
		http.Error(w, "mac: start in the macOS VM: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer rp.Close()
	stop := context.AfterFunc(r.Context(), func() { _ = rp.Close() })
	defer stop()
	_ = rp.Stdin().Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	w.WriteHeader(http.StatusOK)
	sw := guestproto.NewSyncWriter(newFlushWriter(w))
	pump := func(typ uint8, src io.Reader, wg *sync.WaitGroup) {
		defer wg.Done()
		buf := make([]byte, 32<<10)
		for {
			n, rerr := src.Read(buf)
			if n > 0 {
				if werr := sw.WriteFrame(guestproto.Frame{Type: typ, Data: buf[:n]}); werr != nil {
					_ = rp.Close()
					_, _ = io.Copy(io.Discard, src)
					return
				}
			}
			if rerr != nil {
				return
			}
		}
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go pump(guestproto.FrameStdout, rp.Stdout(), &wg)
	go pump(guestproto.FrameStderr, rp.Stderr(), &wg)
	ex, err := rp.Wait()
	wg.Wait()
	if err != nil {
		ex = guestproto.ExecExit{Code: -1, Error: "mac: lost the macOS VM command: " + err.Error()}
	}
	_ = guestproto.WriteJSONFrame(sw, guestproto.FrameExecExit, 0, ex)
}

// flushWriter flushes after every write, so output streams as it comes.
type flushWriter struct {
	w http.ResponseWriter
	f http.Flusher
}

func newFlushWriter(w http.ResponseWriter) *flushWriter {
	f, _ := w.(http.Flusher)
	return &flushWriter{w: w, f: f}
}

func (fw *flushWriter) Write(p []byte) (int, error) {
	n, err := fw.w.Write(p)
	if fw.f != nil {
		fw.f.Flush()
	}
	return n, err
}

// cleanManifest validates the root and every path, which must lie under it,
// and drops duplicates.
func cleanManifest(m guestproto.MacManifest) (string, []guestproto.MacFile, error) {
	root, err := guestproto.CleanMacPath(m.Root, true)
	if err != nil {
		return "", nil, err
	}
	seen := make(map[string]bool, len(m.Files))
	out := make([]guestproto.MacFile, 0, len(m.Files))
	for _, f := range m.Files {
		p, err := guestproto.CleanMacPath(f.Path, false)
		if err != nil {
			return "", nil, err
		}
		if !underMacRoot(p, root) {
			return "", nil, fmt.Errorf("mac: %q is outside the synced directory %q", p, root)
		}
		if seen[p] {
			continue
		}
		seen[p] = true
		f.Path = p
		out = append(out, f)
	}
	return root, out, nil
}

func underMacRoot(p, root string) bool {
	return root == "" || p == root || strings.HasPrefix(p, root+"/")
}

func loadSynced(dir string) (map[string]guestproto.MacFile, error) {
	raw, err := os.ReadFile(filepath.Join(dir, macSyncedFile))
	if errors.Is(err, os.ErrNotExist) {
		return map[string]guestproto.MacFile{}, nil
	}
	if err != nil {
		return nil, err
	}
	var files []guestproto.MacFile
	if err := json.Unmarshal(raw, &files); err != nil {
		// A torn record only costs a full resend.
		return map[string]guestproto.MacFile{}, nil
	}
	out := make(map[string]guestproto.MacFile, len(files))
	for _, f := range files {
		out[f.Path] = f
	}
	return out, nil
}

func saveSynced(dir string, files map[string]guestproto.MacFile) error {
	list := make([]guestproto.MacFile, 0, len(files))
	for _, f := range files {
		list = append(list, f)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Path < list[j].Path })
	raw, err := json.Marshal(list)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	tmp := filepath.Join(dir, macSyncedFile+".tmp")
	if err := os.WriteFile(tmp, raw, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(dir, macSyncedFile))
}

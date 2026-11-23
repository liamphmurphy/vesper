package runner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"time"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// SpareWarmer is a backend that keeps VMs booted ahead of the runs that will
// use them, so a new chat's first turn doesn't wait for one to boot.
type SpareWarmer interface {
	// WarmSpares starts booting spares up to the configured number. It
	// doesn't wait for them.
	WarmSpares()
}

var _ SpareWarmer = (*MicroVM)(nil)

// spareVM is a VM booted on fresh disks that no run owns yet. It idles
// ballooned to IdleMemoryMB and paused until a new run claims it (claimSpare).
type spareVM struct {
	dir      string
	vm       microvm.VM
	egress   *microvm.Egress
	cache    []microvm.DriveSpec // the cache drives it booted with
	pausedAt time.Time
}

// spareBootTimeout bounds one spare's disks and boot; a first boot may also
// format the disk templates.
const spareBootTimeout = 2 * time.Minute

func (b *MicroVM) sparesDir() string { return filepath.Join(b.StateDir, "spares") }

func (b *MicroVM) WarmSpares() {
	b.spareMu.Lock()
	defer b.spareMu.Unlock()
	if b.sparesClosed || b.Driver == nil || b.StateDir == "" {
		return
	}
	if b.spareCtx == nil {
		b.spareCtx, b.spareCancel = context.WithCancel(context.Background())
	}
	for n := len(b.spares) + b.sparesBooting; n < b.SpareVMs; n++ {
		b.sparesBooting++
		b.spareWG.Add(1)
		go b.bootSpare(b.spareCtx)
	}
}

func (b *MicroVM) bootSpare(ctx context.Context) {
	defer b.spareWG.Done()
	ctx, cancel := context.WithTimeout(ctx, spareBootTimeout)
	defer cancel()
	sp, err := b.newSpare(ctx)

	b.spareMu.Lock()
	b.sparesBooting--
	closed := b.sparesClosed
	if err == nil && !closed {
		b.spares = append(b.spares, sp)
	}
	b.spareMu.Unlock()

	switch {
	case err != nil:
		// Not retried here: the next new run tries again (EnsureWorkspace).
		if !closed {
			b.logger().Warn("boot spare VM", "err", err)
		}
	case closed:
		b.discardSpare(sp)
	}
}

func (b *MicroVM) newSpare(ctx context.Context) (*spareVM, error) {
	dir := filepath.Join(b.sparesDir(), uuid.NewString())
	if err := b.createDisks(ctx, dir); err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	vm, eg, cache, err := b.bootVM(ctx, dir, "")
	if err != nil {
		_ = os.RemoveAll(dir)
		return nil, err
	}
	dctx, dcancel := context.WithTimeout(ctx, 2*time.Second)
	_ = vm.Client().SyncAndDropCaches(dctx)
	dcancel()
	_ = vm.SetMemoryTarget(uint64(b.idleMemoryMB()) << 20)
	var pausedAt time.Time
	if p, ok := vm.(microvm.Pauser); ok {
		if b.PauseSettleDelay > 0 {
			timer := time.NewTimer(b.PauseSettleDelay)
			select {
			case <-ctx.Done():
				timer.Stop()
				_ = vm.Stop(context.Background())
				_ = eg.Close()
				_ = os.RemoveAll(dir)
				return nil, ctx.Err()
			case <-timer.C:
			}
		}
		if err := p.Pause(ctx); err != nil {
			b.logger().Warn("pause spare VM", "err", err)
		} else {
			pausedAt = time.Now()
		}
	}
	return &spareVM{dir: dir, vm: vm, egress: eg, cache: cache, pausedAt: pausedAt}, nil
}

// takeSpare pops a ready spare booted with today's cache drives, discarding
// any booted with older ones: a VM's drives are fixed at boot.
func (b *MicroVM) takeSpare() *spareVM {
	var current []microvm.DriveSpec
	if b.CacheStore != nil {
		current = b.CacheStore.LatestEROFSDrives()
	}
	b.spareMu.Lock()
	defer b.spareMu.Unlock()
	for len(b.spares) > 0 {
		sp := b.spares[0]
		b.spares = b.spares[1:]
		if slices.Equal(sp.cache, current) {
			return sp
		}
		go b.discardSpare(sp)
	}
	return nil
}

// claimSpare makes a ready spare runID's VM, its disks moved into dir (which
// must not exist yet), and reports whether there was one. Without one the
// run boots its own VM on first use, as before.
func (b *MicroVM) claimSpare(runID, dir string) bool {
	sp := b.takeSpare()
	if sp == nil {
		return false
	}
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		b.logger().Warn("claim spare VM", "run", runID, "err", err)
		b.discardSpare(sp)
		return false
	}
	// The VM keeps its open disk files across the rename.
	if err := os.Rename(sp.dir, dir); err != nil {
		b.logger().Warn("claim spare VM", "run", runID, "err", err)
		b.discardSpare(sp)
		return false
	}
	sp.dir = dir

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
	if rvm.vm != nil {
		// A new run can't have a VM yet; keep the disks, not a second VM.
		sp.dir = ""
		b.discardSpare(sp)
		return true
	}
	rvm.vm, rvm.egress, rvm.pausedAt = sp.vm, sp.egress, sp.pausedAt
	rvm.vmGen++
	// Idle until the run's first process, like a VM after a turn.
	b.armIdleTimer(rvm, rvm.vmGen)
	return true
}

// discardSpare stops a spare's VM and removes its disks (unless its dir was
// cleared because they now belong to a run).
func (b *MicroVM) discardSpare(sp *spareVM) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = sp.vm.Stop(ctx)
	if sp.egress != nil {
		_ = sp.egress.Close()
	}
	if sp.dir != "" {
		_ = os.RemoveAll(sp.dir)
	}
}

// stopSpares stops the ready spares and, with no boot in flight, removes
// spare disks a previous runner left behind. Boots in flight still join
// the pool: Cleanup also runs when a runner starts.
func (b *MicroVM) stopSpares() {
	b.spareMu.Lock()
	list := b.spares
	b.spares = nil
	booting := b.sparesBooting
	b.spareMu.Unlock()
	for _, sp := range list {
		b.discardSpare(sp)
	}
	if booting == 0 && b.StateDir != "" {
		if err := os.RemoveAll(b.sparesDir()); err != nil && !errors.Is(err, os.ErrNotExist) {
			b.logger().Warn("remove spare VM disks", "err", err)
		}
	}
}

// closeSpares stops warming spares for good, abandoning boots in flight.
func (b *MicroVM) closeSpares() {
	b.spareMu.Lock()
	b.sparesClosed = true
	cancel := b.spareCancel
	b.spareMu.Unlock()
	if cancel != nil {
		cancel()
	}
	b.spareWG.Wait()
	b.stopSpares()
}

func (b *MicroVM) spareCount() int {
	b.spareMu.Lock()
	defer b.spareMu.Unlock()
	return len(b.spares)
}

// idleMemoryMB is the balloon target of a VM nothing is running in.
func (b *MicroVM) idleMemoryMB() int64 {
	idleMB := b.IdleMemoryMB
	if idleMB <= 0 {
		idleMB = 192
	}
	memMB := b.MemoryMB
	if memMB <= 0 {
		memMB = 2048
	}
	return min(idleMB, memMB)
}

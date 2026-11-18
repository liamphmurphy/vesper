package runner

import (
	"context"
	"errors"
	"path"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

var _ TurnGateBackend = (*MicroVM)(nil)

// guestGateDir holds a turn's gate in the guest: root-owned and on tmpfs, so
// the turn can read its markers but not forge them.
func guestGateDir(key string) string { return path.Join("/run/vesper-turn", key) }

func (b *MicroVM) OpenTurnGate(ctx context.Context, runID, key string) (map[string]string, error) {
	rvm, err := b.acquireVM(ctx, runID)
	if err != nil {
		return nil, err
	}
	defer b.releaseVM(rvm)
	dir := guestGateDir(key)
	script := path.Join(dir, gateScriptFile)
	if err := rvm.vm.Client().WriteFiles(ctx, []guestproto.FileWrite{{Path: script, Data: turnGateScript(dir), Mode: 0o644}}); err != nil {
		return nil, err
	}
	return map[string]string{"BASH_ENV": script}, nil
}

func (b *MicroVM) ReleaseTurnGate(ctx context.Context, runID, key string, env map[string]string, failure string) error {
	client, err := b.runningClient(runID)
	if err != nil {
		return err
	}
	dir := guestGateDir(key)
	if failure != "" {
		return client.WriteFiles(ctx, []guestproto.FileWrite{{Path: path.Join(dir, gateFailedFile), Data: turnGateFailure(failure), Mode: 0o644}})
	}
	// Two writes: the env is complete before ready appears.
	if err := client.WriteFiles(ctx, []guestproto.FileWrite{{Path: path.Join(dir, gateEnvFile), Data: turnGateEnv(env), Mode: 0o644}}); err != nil {
		return err
	}
	return client.WriteFiles(ctx, []guestproto.FileWrite{{Path: path.Join(dir, gateReadyFile), Mode: 0o644}})
}

func (b *MicroVM) CloseTurnGate(ctx context.Context, runID, key string) {
	client, err := b.runningClient(runID)
	if err != nil {
		return // the VM is gone, and its tmpfs with it
	}
	if err := client.UnlinkPaths(ctx, []string{guestGateDir(key)}, true); err != nil {
		b.logger().Warn("remove turn gate", "run", runID, "key", key, "err", err)
	}
}

// runningClient is the guest client of the run's VM if it is up. Unlike
// acquireVM it never boots one: a gate outliving its VM has nothing to do.
func (b *MicroVM) runningClient(runID string) (*guestproto.Client, error) {
	b.runsMu.Lock()
	rvm := b.vms[runID]
	b.runsMu.Unlock()
	if rvm == nil {
		return nil, errors.New("microvm: the run's VM isn't running")
	}
	rvm.mu.Lock()
	defer rvm.mu.Unlock()
	if rvm.vm == nil {
		return nil, errors.New("microvm: the run's VM isn't running")
	}
	return rvm.vm.Client(), nil
}

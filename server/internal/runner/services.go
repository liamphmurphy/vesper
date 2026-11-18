package runner

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// ServiceBackend starts the services a run's spec declares (agentdef.Service)
// next to one turn. The fake backend has no isolation to offer and doesn't
// implement it.
type ServiceBackend interface {
	// StartServices starts services on a new network named for key and waits
	// until each is ready. The turn joins network (ExecSpec.Networks); stop
	// removes the services and the network, and is safe to call once.
	StartServices(ctx context.Context, runID, key string, services []agentdef.Service) (network string, stop func(), err error)
}

// startServices starts the services the run's spec declares for this turn and
// puts what they expose into env. It returns the networks the turn joins and
// a stop to call when the turn ends, or a failure for the run's outcome.
func (r *Runner) startServices(ctx context.Context, c runCtx, turn store.RunTurn, env map[string]string) ([]string, func(), string) {
	services := r.testEnvServices(ctx, c)
	if len(services) == 0 {
		return nil, func() {}, ""
	}
	names := make([]string, len(services))
	for i, s := range services {
		names[i] = s.Name
	}
	sb, ok := r.Backend.(ServiceBackend)
	if !ok {
		// The fake runner shares the host and has no services to start.
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "services_skipped", "services": names,
			"reason": "the " + r.Backend.Name() + " runner can't start services"})
		return nil, func() {}, ""
	}
	started := time.Now()
	network, stop, err := sb.StartServices(ctx, c.run.ID.String(), fmt.Sprintf("%s-%d", c.run.ID, turn.Seq), services)
	if err != nil {
		return nil, nil, "Couldn't start the run's services: " + err.Error()
	}
	for _, s := range services {
		for k, v := range s.Expose {
			env[k] = v
		}
	}
	r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "services_ready", "services": names, "ms": time.Since(started).Milliseconds()})
	return []string{network}, stop, ""
}

// startDockerProxy gives the turn its own sandboxed Docker API (see
// microvm_docker.go) and puts how to reach it into env. A runner without one,
// or one that fails to start, leaves the turn without Docker rather than
// failing it: most turns never need it, and tests that do say so.
func (r *Runner) startDockerProxy(ctx context.Context, c runCtx, turn store.RunTurn, env map[string]string) ([]string, func()) {
	pb, ok := r.Backend.(ProxyBackend)
	if !ok {
		return nil, func() {}
	}
	td, err := pb.StartDockerProxy(ctx, c.run.ID.String(), wsID(c.run), fmt.Sprintf("%s-%d", c.run.ID, turn.Seq))
	if errors.Is(err, errProxyOff) {
		return nil, func() {}
	}
	if err != nil {
		r.Log.Warn("docker proxy", "run", c.run.ID, "err", err)
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "docker_unavailable", "reason": err.Error()})
		return nil, func() {}
	}
	for k, v := range td.Env {
		env[k] = v
	}
	return []string{td.Network}, td.Stop
}

// turnEnvironment is a turn's services and Docker API, started in the
// background so a coding chat's checkout is prepared meanwhile: on a cold VM
// each takes seconds (dockerd and a database becoming healthy; a clone and
// package installs), and neither needs the other.
type turnEnvironment struct {
	cancel   context.CancelFunc
	done     chan struct{}
	exposed  map[string]string // written only before done closes
	networks []string
	stops    []func()
	failure  string
}

func (r *Runner) startTurnEnvironment(ctx context.Context, c runCtx, turn store.RunTurn) *turnEnvironment {
	ctx, cancel := context.WithCancel(ctx)
	te := &turnEnvironment{cancel: cancel, done: make(chan struct{}), exposed: map[string]string{}}
	go func() {
		defer close(te.done)
		networks, stopServices, failure := r.startServices(ctx, c, turn, te.exposed)
		if failure != "" {
			te.failure = failure
			return
		}
		dockerNetworks, stopDocker := r.startDockerProxy(ctx, c, turn, te.exposed)
		// Stopped in reverse: the Docker API before the services.
		te.stops = []func(){stopDocker, stopServices}
		te.networks = append(networks, dockerNetworks...)
	}()
	return te
}

// wait blocks until the environment is up, then adds what it exposes to env
// and returns the networks the turn joins, or a failure for the run.
func (te *turnEnvironment) wait(env map[string]string) ([]string, string) {
	<-te.done
	maps.Copy(env, te.exposed)
	return te.networks, te.failure
}

// stop removes what started, first abandoning a start still in progress
// (when the turn ends before waiting, e.g. its setup failed).
func (te *turnEnvironment) stop() {
	select {
	case <-te.done:
	default:
		te.cancel()
		<-te.done
	}
	for _, stop := range te.stops {
		stop()
	}
	te.cancel()
}

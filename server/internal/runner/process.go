package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	controlTimeout = 3 * time.Second
	drainTimeout   = 2 * time.Second
)

// captureWriter bounds retained output without ever stopping pipe consumption.
type captureWriter struct{ bytes.Buffer }

func (w *captureWriter) Write(p []byte) (int, error) {
	n := len(p)
	if left := (1 << 20) - w.Len(); left > 0 {
		_, _ = w.Buffer.Write(p[:min(left, n)])
	}
	return n, nil
}

// drainProcess allows trailing output to arrive after exit, but closes streams
// if a detached child or a lost attach connection keeps them open.
func drainProcess(proc Process, readers *sync.WaitGroup, cancelReads context.CancelFunc) error {
	done := make(chan struct{})
	go func() { readers.Wait(); close(done) }()
	timer := time.NewTimer(drainTimeout)
	defer timer.Stop()
	var err error
	select {
	case <-done:
	case <-timer.C:
		err = errors.New("process output did not close after exit")
		if cancelReads != nil {
			cancelReads()
		}
		_ = proc.Kill()
		if c, ok := proc.(io.Closer); ok {
			_ = c.Close()
		}
		<-done
	}
	if c, ok := proc.(io.Closer); ok {
		_ = c.Close()
	}
	return err
}

func captureProcess(ctx context.Context, proc Process) (string, int, error) {
	done := make(chan struct{})
	stopped := make(chan struct{})
	go func() {
		defer close(stopped)
		select {
		case <-ctx.Done():
			_ = proc.Kill()
		case <-done:
		}
	}()
	var out [2]captureWriter
	var readErr [2]error
	var readers sync.WaitGroup
	for i, rd := range []io.Reader{proc.Stdout(), proc.Stderr()} {
		readers.Add(1)
		go func() {
			defer readers.Done()
			_, readErr[i] = io.Copy(&out[i], rd)
		}()
	}
	code, err := proc.Wait()
	drainErr := drainProcess(proc, &readers, nil)
	close(done)
	<-stopped
	return out[0].String() + out[1].String(), code, errors.Join(err, drainErr, readErr[0], readErr[1])
}

// supervise polls state separately from timers: database backpressure must
// never prevent the runtime deadline or runner shutdown from killing a process.
// The returned function joins both goroutines and reports runtime expiry.
func (r *Runner) supervise(ctx context.Context, c runCtx, proc Process, runtime time.Duration, streamErrors <-chan error, control func() harness.SessionControl) func() (bool, error) {
	ctx, cancel := context.WithCancel(ctx)
	states := make(chan string, 1)
	steers := make(chan store.ChatSteer, 1)
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		interval := time.Second
		if c.run.Purpose == "chat" {
			interval = 300 * time.Millisecond
		}
		t := time.NewTicker(interval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				if r.Pool == nil {
					continue
				}
				qctx, stop := context.WithTimeout(ctx, controlTimeout)
				run, err := r.q().GetRun(qctx, store.GetRunParams{ID: c.run.ID, WorkspaceID: c.run.WorkspaceID})
				stop()
				if err != nil {
					continue
				}
				select {
				case states <- run.State:
				case <-ctx.Done():
					return
				}
				if c.run.Purpose == "chat" && run.State == "running" && control != nil && control() != nil {
					sctx, sstop := context.WithTimeout(ctx, controlTimeout)
					steer, serr := r.q().ClaimNextChatSteer(sctx, c.run.ID)
					sstop()
					if serr == nil {
						select {
						case steers <- steer:
						case <-ctx.Done():
							return
						}
					}
				}
			}
		}
	}()
	done := make(chan struct{})
	var expired bool
	var streamErr error
	go func() {
		defer workers.Done()
		defer cancel()
		var deadline <-chan time.Time
		if runtime > 0 {
			timer := time.NewTimer(runtime)
			defer timer.Stop()
			deadline = timer.C
		}
		var grace <-chan time.Time
		var graceTimer *time.Timer
		defer func() {
			if graceTimer != nil {
				graceTimer.Stop()
			}
		}()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				_ = proc.Kill()
				return
			case streamErr = <-streamErrors:
				_ = proc.Kill()
				return
			case <-deadline:
				expired = true
				_ = proc.Kill()
				return
			case <-grace:
				_ = proc.Kill()
				return
			case steer := <-steers:
				if r.deliverChatSteer(ctx, c, steer, control) {
					_ = proc.Kill()
					return
				}
			case state := <-states:
				switch {
				case state == "failed" || state == "cancelled" || (state == "paused" && c.run.Purpose == "chat"):
					_ = proc.Kill()
					return
				case state == "paused" && graceTimer == nil:
					var interrupted bool
					if control != nil {
						if ctrl := control(); ctrl != nil {
							_ = ctrl.Interrupt()
							interrupted = true
						}
					}
					if !interrupted {
						_ = proc.Interrupt()
					}
					graceTimer = time.NewTimer(max(r.Cfg.Grace, time.Millisecond))
					grace = graceTimer.C
				}
			}
		}
	}()
	return func() (bool, error) {
		close(done)
		workers.Wait()
		return expired, streamErr
	}
}

// deliverChatSteer injects a claimed mid-turn steer into the live harness
// session, falling back to an interrupt/next-turn handoff if the session cannot
// accept steering input. It reports whether the process should be killed to
// complete an interrupt fallback.
func (r *Runner) deliverChatSteer(ctx context.Context, c runCtx, steer store.ChatSteer, control func() harness.SessionControl) bool {
	var ctrl harness.SessionControl
	if control != nil {
		ctrl = control()
	}
	if ctrl == nil {
		return r.fallbackChatSteer(ctx, c, steer)
	}
	if err := ctrl.Steer(steer.Body); err == nil {
		r.event(context.WithoutCancel(ctx), c.run.ID, "lifecycle", map[string]any{
			"state":    "chat_steered",
			"steer_id": steer.ID,
			"body":     steer.Body,
		})
		return false
	} else if errors.Is(err, harness.ErrSteerUnsupported) {
		return r.fallbackChatSteer(ctx, c, steer)
	} else {
		r.Log.Warn("steer chat session", "run", c.run.ID, "steer", steer.ID, "err", err)
		return r.fallbackChatSteer(ctx, c, steer)
	}
}

func (r *Runner) fallbackChatSteer(ctx context.Context, c runCtx, steer store.ChatSteer) bool {
	fctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
	defer cancel()
	var killProc bool
	err := pgx.BeginFunc(fctx, r.Pool, func(tx pgx.Tx) error {
		var ferr error
		killProc, ferr = runs.FallbackChatSteerToInterrupt(fctx, store.New(tx), steer.SessionID, steer.RunID, steer.ID, steer.MessageID, 0)
		return ferr
	})
	if err != nil {
		r.Log.Warn("fallback chat steer", "run", c.run.ID, "steer", steer.ID, "err", err)
		_ = r.q().MarkChatSteerState(fctx, store.MarkChatSteerStateParams{ID: steer.ID, State: "pending"})
		return false
	}
	return killProc
}

func streamError(stream string, err error) error { return fmt.Errorf("harness %s: %w", stream, err) }

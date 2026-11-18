package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

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
func (r *Runner) supervise(ctx context.Context, c runCtx, proc Process, runtime time.Duration, streamErrors <-chan error) func() (bool, error) {
	ctx, cancel := context.WithCancel(ctx)
	states := make(chan string, 1)
	var workers sync.WaitGroup
	workers.Add(2)
	go func() {
		defer workers.Done()
		t := time.NewTicker(time.Second)
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
				if err == nil {
					select {
					case states <- run.State:
					case <-ctx.Done():
						return
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
			case state := <-states:
				switch {
				case state == "failed" || state == "cancelled" || (state == "paused" && c.run.Purpose == "chat"):
					_ = proc.Kill()
					return
				case state == "paused" && graceTimer == nil:
					_ = proc.Interrupt()
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

func streamError(stream string, err error) error { return fmt.Errorf("harness %s: %w", stream, err) }

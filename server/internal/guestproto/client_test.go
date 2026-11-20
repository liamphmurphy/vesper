package guestproto

import (
	"context"
	"errors"
	"net"
	"testing"
	"time"
)

// A guest that accepts an exec request and never answers must not hold
// StartExec past its context.
func TestStartExecHonoursContextWhileWaitingToStart(t *testing.T) {
	c := &Client{Dial: func(context.Context) (net.Conn, error) {
		host, guest := net.Pipe()
		go func() {
			defer guest.Close()
			if _, err := ReadFrame(guest); err != nil {
				return
			}
			_, _ = ReadFrame(guest) // never answers; returns once the host hangs up
		}()
		return host, nil
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()

	done := make(chan error, 1)
	go func() {
		_, err := c.StartExec(ctx, ExecReq{Argv: []string{"true"}})
		done <- err
	}()
	select {
	case err := <-done:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("StartExec = %v, want context.DeadlineExceeded", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("StartExec still waiting 5s after its context ended")
	}
}

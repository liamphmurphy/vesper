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

// A guest whose stderr nobody reads backs up the whole exec stream, so the
// exit it reports after SIGKILL never arrives. Kill must still end Wait.
func TestKillEndsWaitWhenStreamIsBackedUp(t *testing.T) {
	c := &Client{Dial: func(context.Context) (net.Conn, error) {
		host, guest := net.Pipe()
		go func() {
			defer guest.Close()
			if _, err := ReadFrame(guest); err != nil {
				return
			}
			if err := WriteJSONFrame(NewSyncWriter(guest), FrameResp, 1, Response{ID: 1}); err != nil {
				return
			}
			// Unread stderr, then the signal is read but the exit is never sent:
			// the host is still blocked delivering stderr.
			go func() {
				for {
					if _, err := ReadFrame(guest); err != nil {
						return
					}
				}
			}()
			for {
				if err := WriteFrame(guest, Frame{Type: FrameStderr, ID: 1, Data: []byte("noise\n")}); err != nil {
					return
				}
			}
		}()
		return host, nil
	}}
	rp, err := c.StartExec(context.Background(), ExecReq{Argv: []string{"claude"}})
	if err != nil {
		t.Fatal(err)
	}
	if err := rp.Kill(50 * time.Millisecond); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { _, err := rp.Wait(); done <- err }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("Wait = nil, want the hang-up error")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Wait still blocked 5s after Kill")
	}
}

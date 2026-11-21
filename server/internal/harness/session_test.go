package harness

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"
)

type spyWriteCloser struct {
	sb     strings.Builder
	closed int
}

func (s *spyWriteCloser) Write(p []byte) (int, error) { return s.sb.Write(p) }
func (s *spyWriteCloser) Close() error                { s.closed++; return nil }

func TestCheckPolicyFailsClosed(t *testing.T) {
	ctx := context.Background()
	if allow, _ := checkPolicy(ctx, nil, false, "Read", map[string]any{"file_path": "a"}); allow {
		t.Fatal("nil PolicyFunc must deny")
	}
	called := false
	fn := func(context.Context, string, map[string]any) (bool, string) {
		called = true
		return true, ""
	}
	if allow, _ := checkPolicy(ctx, fn, true, "Read", nil); allow || called {
		t.Fatalf("noTools must deny without calling PolicyFunc (allow=%v called=%v)", allow, called)
	}
	if allow, reason := checkPolicy(ctx, func(context.Context, string, map[string]any) (bool, string) {
		return false, ""
	}, false, "Bash", nil); allow || reason == "" {
		t.Fatalf("empty deny reason must default (allow=%v reason=%q)", allow, reason)
	}
}

func TestLineWriterCloseIdempotent(t *testing.T) {
	s := &spyWriteCloser{}
	lw := newLineWriter(s)
	if err := lw.writeJSON(map[string]string{"ok": "1"}); err != nil {
		t.Fatal(err)
	}
	if err := lw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := lw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := lw.writeJSON(map[string]string{"ok": "2"}); err != io.ErrClosedPipe {
		t.Fatalf("write after close = %v, want io.ErrClosedPipe", err)
	}
	if s.closed != 1 || s.sb.String() != "{\"ok\":\"1\"}\n" {
		t.Fatalf("closed=%d body=%q", s.closed, s.sb.String())
	}
}

func TestSessionControlSteer(t *testing.T) {
	t.Run("claude", func(t *testing.T) {
		spy := &spyWriteCloser{}
		c := &claudeControl{w: newLineWriter(spy)}
		if err := c.Steer("   "); err == nil {
			t.Fatal("expected error for blank steer")
		}
		if err := c.Steer("pivot to tests"); err != nil {
			t.Fatalf("Steer: %v", err)
		}
		got := spy.sb.String()
		if !strings.Contains(got, `"type":"user"`) || !strings.Contains(got, `"pivot to tests"`) {
			t.Fatalf("unexpected claude steer frame: %q", got)
		}
	})

	t.Run("codex_ack_error_and_close", func(t *testing.T) {
		spy := &spyWriteCloser{}
		c := &codexControl{w: newLineWriter(spy), thread: "thr-1", turn: "turn-1"}
		errCh := make(chan error, 1)
		go func() { errCh <- c.Steer("focus on api") }()

		// Wait until the request is registered in c.pending.
		for {
			c.mu.Lock()
			var id int64
			for k := range c.pending {
				id = k
			}
			c.mu.Unlock()
			if id != 0 {
				c.resolve(id, nil)
				break
			}
		}
		if err := <-errCh; err != nil {
			t.Fatalf("expected ack nil err, got %v", err)
		}
		if !strings.Contains(spy.sb.String(), `"method":"turn/steer"`) || !strings.Contains(spy.sb.String(), `"expectedTurnId":"turn-1"`) {
			t.Fatalf("unexpected codex steer RPC: %q", spy.sb.String())
		}

		go func() { errCh <- c.Steer("unsupported turn") }()
		for {
			c.mu.Lock()
			var id int64
			for k := range c.pending {
				id = k
			}
			c.mu.Unlock()
			if id != 0 {
				c.resolve(id, &codexRPCError{Code: -32601, Message: "method not found"})
				break
			}
		}
		if err := <-errCh; !errors.Is(err, ErrSteerUnsupported) {
			t.Fatalf("got %v, want ErrSteerUnsupported", err)
		}

		go func() { errCh <- c.Steer("closed stream") }()
		for {
			c.mu.Lock()
			n := len(c.pending)
			c.mu.Unlock()
			if n > 0 {
				c.closeAll()
				break
			}
		}
		if err := <-errCh; !errors.Is(err, ErrSteerUnsupported) {
			t.Fatalf("closeAll got %v, want ErrSteerUnsupported", err)
		}
	})

	t.Run("antigravity_unsupported", func(t *testing.T) {
		if err := (&agyControl{}).Steer("anything"); !errors.Is(err, ErrSteerUnsupported) {
			t.Fatalf("got %v, want ErrSteerUnsupported", err)
		}
	})
}

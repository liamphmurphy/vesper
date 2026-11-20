package harness

import (
	"context"
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

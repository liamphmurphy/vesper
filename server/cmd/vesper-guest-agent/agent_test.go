package main

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

func newTestAgentClient(t *testing.T) (*guestproto.Client, *agentServer) {
	t.Helper()
	srv := newAgentServer(slog.New(slog.NewTextHandler(io.Discard, nil)))
	client := &guestproto.Client{
		Dial: func(ctx context.Context) (net.Conn, error) {
			a, b := net.Pipe()
			go func() {
				defer b.Close()
				srv.handleConn(ctx, b)
			}()
			return a, nil
		},
	}
	return client, srv
}

func TestAgentPingAndFileOps(t *testing.T) {
	ctx := context.Background()
	c, _ := newTestAgentClient(t)

	ping, err := c.Ping(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if ping.Version != agentVersion || ping.BootTimeNS <= 0 {
		t.Fatalf("unexpected ping: %+v", ping)
	}

	dir := t.TempDir()
	f1 := filepath.Join(dir, "sub", "hello.txt")
	if err := c.WriteFiles(ctx, []guestproto.FileWrite{{Path: f1, Data: []byte("hello world"), Mode: 0o640}}); err != nil {
		t.Fatal(err)
	}
	st, err := c.Stat(ctx, f1)
	if err != nil || !st.Exists || st.Size != 11 {
		t.Fatalf("stat = %+v, err=%v", st, err)
	}
	got, err := c.ReadFile(ctx, f1, 5)
	if err != nil || string(got) != "hello" {
		t.Fatalf("read = %q, err=%v", got, err)
	}
	entries, err := c.WalkDir(ctx, dir, 0)
	if err != nil || len(entries) != 2 {
		t.Fatalf("walk = %+v, err=%v", entries, err)
	}
	if err := c.UnlinkPaths(ctx, []string{f1}, false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(f1); !os.IsNotExist(err) {
		t.Fatalf("expected unlinked, stat err=%v", err)
	}
}

func TestAgentExecPipes(t *testing.T) {
	ctx := context.Background()
	c, _ := newTestAgentClient(t)

	proc, err := c.StartExec(ctx, guestproto.ExecReq{
		Argv: []string{"/bin/sh", "-c", "cat; echo err >&2; exit 7"},
		Env:  map[string]string{"FOO": "bar"},
	})
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		_, _ = io.WriteString(proc.Stdin(), "from-stdin\n")
		_ = proc.Stdin().Close()
	}()

	var outBuf, errBuf bytes.Buffer
	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(&outBuf, proc.Stdout())
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(&errBuf, proc.Stderr())
	}()

	wg.Wait()
	exit, err := proc.Wait()
	if err != nil {
		t.Fatal(err)
	}
	if exit.Code != 7 {
		t.Fatalf("exit code = %d, want 7", exit.Code)
	}
	if outBuf.String() != "from-stdin\n" || errBuf.String() != "err\n" {
		t.Fatalf("stdout=%q stderr=%q", outBuf.String(), errBuf.String())
	}
}

// brokenListener fails every Accept, like a listening socket that went bad.
type brokenListener struct {
	mu    sync.Mutex
	calls int
}

func (l *brokenListener) Accept() (net.Conn, error) {
	l.mu.Lock()
	l.calls++
	l.mu.Unlock()
	return nil, errors.New("accept: bad file descriptor")
}
func (l *brokenListener) Close() error   { return nil }
func (l *brokenListener) Addr() net.Addr { return vsockAddr{} }

func (l *brokenListener) count() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.calls
}

func TestServeGivesUpOnABrokenListener(t *testing.T) {
	srv := newAgentServer(slog.New(slog.NewTextHandler(io.Discard, nil)))
	srv.maxAcceptFailures = 3
	ln := &brokenListener{}

	done := make(chan error, 1)
	go func() { done <- srv.serve(context.Background(), ln) }()
	select {
	case err := <-done:
		if err == nil {
			t.Fatal("serve returned nil, want an error so the supervisor restarts the agent")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("serve kept retrying a broken listener")
	}
	if n := ln.count(); n != 3 {
		t.Fatalf("Accept called %d times, want 3", n)
	}
}

func TestServeKeepsRetryingWithoutALimit(t *testing.T) {
	srv := newAgentServer(slog.New(slog.NewTextHandler(io.Discard, nil)))
	ln := &brokenListener{}
	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan error, 1)
	go func() { done <- srv.serve(ctx, ln) }()
	deadline := time.Now().Add(5 * time.Second)
	for ln.count() < 3 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("serve = %v, want nil once ctx ends", err)
	}
	// Backed off rather than spinning: ~10 tries a second, not millions.
	if n := ln.count(); n < 3 || n > 100 {
		t.Fatalf("Accept called %d times, want a few with backoff between", n)
	}
}

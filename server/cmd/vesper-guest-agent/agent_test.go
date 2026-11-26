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
	"strings"
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

// syncBuffer is a bytes.Buffer safe to write from the agent's goroutines and
// read from the test.
type syncBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *syncBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *syncBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func runTracedExec(t *testing.T, trace bool) string {
	t.Helper()
	logs := &syncBuffer{}
	srv := newAgentServer(slog.New(slog.NewTextHandler(logs, nil)))
	srv.trace = trace
	c := &guestproto.Client{Dial: func(ctx context.Context) (net.Conn, error) {
		a, b := net.Pipe()
		go func() {
			defer b.Close()
			srv.handleConn(ctx, b)
		}()
		return a, nil
	}}
	proc, err := c.StartExec(context.Background(), guestproto.ExecReq{Argv: []string{"/bin/sh", "-c", "exit 3"}})
	if err != nil {
		t.Fatal(err)
	}
	_ = proc.Stdin().Close()
	_, _ = io.Copy(io.Discard, proc.Stdout())
	if exit, err := proc.Wait(); err != nil || exit.Code != 3 {
		t.Fatalf("exit = %+v, %v; want code 3", exit, err)
	}
	_ = proc.Close()
	if !trace {
		time.Sleep(100 * time.Millisecond) // give a stray log line time to land
		return logs.String()
	}
	// The finish line is written just after the exit frame the client waited for.
	deadline := time.Now().Add(5 * time.Second)
	for !strings.Contains(logs.String(), "exec finished") && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	return logs.String()
}

func TestAgentTraceLogsExecLifecycle(t *testing.T) {
	out := runTracedExec(t, true)
	for _, want := range []string{"msg=request op=" + guestproto.OpExecStart, `msg="exec started"`, "argv0=/bin/sh", `msg="exec finished"`, "code=3"} {
		if !strings.Contains(out, want) {
			t.Fatalf("trace lacks %q:\n%s", want, out)
		}
	}
}

func TestAgentWithoutTraceLogsNoExecLifecycle(t *testing.T) {
	out := runTracedExec(t, false)
	for _, unwanted := range []string{"msg=request", "exec started", "exec finished", "exec connection read ended"} {
		if strings.Contains(out, unwanted) {
			t.Fatalf("untraced agent logged %q:\n%s", unwanted, out)
		}
	}
}

func TestGuestFileOpsRefuseSymlinkEscapes(t *testing.T) {
	ctx := context.Background()
	c, _ := newTestAgentClient(t)

	guestRoot := t.TempDir()
	outsideDir := t.TempDir()
	outsideFile := filepath.Join(outsideDir, "passwd")
	if err := os.WriteFile(outsideFile, []byte("root:x:0:0\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	origRoots := guestWritableRoots
	guestWritableRoots = []string{guestRoot}
	t.Cleanup(func() { guestWritableRoots = origRoots })

	// 1. Leaf symlink pointing outside guestRoot must be refused on WriteFiles and ReadFile.
	leafLink := filepath.Join(guestRoot, "creds.json")
	if err := os.Symlink(outsideFile, leafLink); err != nil {
		t.Fatal(err)
	}
	if err := c.WriteFiles(ctx, []guestproto.FileWrite{{Path: leafLink, Data: []byte("pwned"), Mode: 0o600}}); err == nil {
		t.Fatal("WriteFiles followed leaf symlink outside guest root")
	}
	if got, _ := os.ReadFile(outsideFile); string(got) != "root:x:0:0\n" {
		t.Fatalf("outside target modified via leaf symlink: %q", got)
	}
	if _, err := c.ReadFile(ctx, leafLink, 1024); err == nil {
		t.Fatal("ReadFile followed leaf symlink outside guest root")
	}

	// 2. Intermediate directory symlink pointing outside guestRoot must be refused on WriteFiles, ReadFile, and UnlinkPaths.
	dirLink := filepath.Join(guestRoot, ".claude")
	if err := os.Symlink(outsideDir, dirLink); err != nil {
		t.Fatal(err)
	}
	escapedTarget := filepath.Join(dirLink, "passwd")
	if err := c.WriteFiles(ctx, []guestproto.FileWrite{{Path: escapedTarget, Data: []byte("pwned"), Mode: 0o600}}); err == nil {
		t.Fatal("WriteFiles followed intermediate directory symlink outside guest root")
	}
	if _, err := c.ReadFile(ctx, escapedTarget, 1024); err == nil {
		t.Fatal("ReadFile followed intermediate directory symlink outside guest root")
	}
	if err := c.UnlinkPaths(ctx, []string{escapedTarget}, false); err == nil {
		t.Fatal("UnlinkPaths followed intermediate directory symlink outside guest root")
	}
	if got, err := os.ReadFile(outsideFile); err != nil || string(got) != "root:x:0:0\n" {
		t.Fatalf("outside file altered or deleted: err=%v got=%q", err, got)
	}

	// 3. Recursive unlink on the symlink itself removes the symlink without deleting outsideDir.
	if err := c.UnlinkPaths(ctx, []string{dirLink}, true); err != nil {
		t.Fatalf("UnlinkPaths on symlink itself failed: %v", err)
	}
	if _, err := os.Lstat(dirLink); !os.IsNotExist(err) {
		t.Fatalf("expected symlink removed, lstat err=%v", err)
	}
	if _, err := os.Stat(outsideFile); err != nil {
		t.Fatalf("outside target was deleted by recursive unlink of symlink: %v", err)
	}

	// 4. Relative symlink even inside guestRoot must be refused on WriteFiles (O_NOFOLLOW).
	realInside := filepath.Join(guestRoot, "real.txt")
	if err := os.WriteFile(realInside, []byte("orig"), 0o644); err != nil {
		t.Fatal(err)
	}
	relLink := filepath.Join(guestRoot, "rel.txt")
	if err := os.Symlink("real.txt", relLink); err != nil {
		t.Fatal(err)
	}
	if err := c.WriteFiles(ctx, []guestproto.FileWrite{{Path: relLink, Data: []byte("overwrite"), Mode: 0o644}}); err == nil {
		t.Fatal("WriteFiles followed relative symlink inside guest root")
	}
	if got, _ := os.ReadFile(realInside); string(got) != "orig" {
		t.Fatalf("real.txt modified via relative symlink: %q", got)
	}
}

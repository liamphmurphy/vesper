package main

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"

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

func TestDockerContainerCreateGuard(t *testing.T) {
	allowed := []string{
		`{"HostConfig":{"Binds":["/workspace/src:/app","/tmp/scratch:/work"]}}`,
		`{"HostConfig":{"Binds":["/var/run/docker.sock:/var/run/docker.sock"]}}`,
		`{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/workspace"},{"Type":"volume","Source":"pgdata"}]}}`,
	}
	for _, body := range allowed {
		if msg := validateDockerContainerCreate([]byte(body)); msg != "" {
			t.Errorf("unexpected block on %s: %s", body, msg)
		}
	}
	blocked := []string{
		`{"HostConfig":{"Privileged":true}}`,
		`{"HostConfig":{"NetworkMode":"host"}}`,
		`{"HostConfig":{"PidMode":"host"}}`,
		`{"HostConfig":{"CapAdd":["SYS_ADMIN"]}}`,
		`{"HostConfig":{"Binds":["/etc/passwd:/etc/passwd"]}}`,
		`{"HostConfig":{"Binds":["/home/node/.ssh:/root/.ssh"]}}`,
		`{"HostConfig":{"Binds":["/workspace/../etc:/etc"]}}`,
		`{"HostConfig":{"Mounts":[{"Type":"bind","Source":"/var/run/docker-raw.sock"}]}}`,
	}
	for _, body := range blocked {
		if msg := validateDockerContainerCreate([]byte(body)); msg == "" {
			t.Errorf("expected block on %s", body)
		}
	}
}

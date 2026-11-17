package runner

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeEngine is just enough of the Docker Engine API for a sign-in container:
// create, attach (upgraded to a raw terminal stream with a TTY, multiplexed
// without), start, wait, inspect, archive, kill and delete.
type fakeEngine struct {
	mu      sync.Mutex
	created map[string]any
	calls   []string
	exited  chan struct{}
	// dropWaits makes the first N /wait long-polls lose their connection;
	// waitCode is the exit /wait reports, and oom what inspect reports.
	dropWaits int
	waitCode  int
	oom       bool
	// listFilters is the filters query of the last container list.
	listFilters string
	// volumes are the named volumes that exist.
	volumes map[string]bool
	// deletes are the query of each DELETE, by path.
	deletes map[string]string
}

func (f *fakeEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := strings.TrimPrefix(r.URL.Path, "/v1.43")
	f.mu.Lock()
	f.calls = append(f.calls, r.Method+" "+p)
	if r.Method == "DELETE" {
		if f.deletes == nil {
			f.deletes = map[string]string{}
		}
		f.deletes[p] = r.URL.RawQuery
	}
	drop := p == "/containers/c1/wait" && f.dropWaits > 0
	if drop {
		f.dropWaits--
	}
	f.mu.Unlock()
	switch {
	case drop:
		if conn, _, err := w.(http.Hijacker).Hijack(); err == nil {
			_ = conn.Close()
		}
	case p == "/containers/create":
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.created = body
		f.mu.Unlock()
		_, _ = io.WriteString(w, `{"Id":"c1"}`)
	case p == "/containers/c1/attach" && r.Header.Get("Upgrade") == "tcp":
		conn, buf, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			_, _ = io.WriteString(conn, "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
			_, _ = io.WriteString(conn, "Paste code here if prompted > ")
			line, _ := buf.ReadString('\r')
			_, _ = io.WriteString(conn, "\r\ngot:"+strings.TrimSpace(line)+"\r\n")
			close(f.exited)
		}()
	case p == "/containers/c1/attach":
		frame := func(stream byte, s string) []byte {
			h := make([]byte, 8)
			h[0] = stream
			binary.BigEndian.PutUint32(h[4:], uint32(len(s)))
			return append(h, s...)
		}
		_, _ = w.Write(frame(1, "to stdout\n"))
		_, _ = w.Write(frame(2, "to stderr\n"))
		close(f.exited)
	case p == "/containers/c1/start", p == "/containers/c1/kill":
		w.WriteHeader(204)
	case p == "/containers/c1/wait":
		<-f.exited
		_, _ = fmt.Fprintf(w, `{"StatusCode":%d}`, f.waitCode)
	case p == "/networks":
		_, _ = io.WriteString(w, `[]`)
	case p == "/volumes":
		_, _ = io.WriteString(w, `{"Volumes":[]}`)
	case strings.HasPrefix(p, "/networks/"):
		w.WriteHeader(200)
	case p == "/containers/json":
		f.mu.Lock()
		f.listFilters = r.URL.Query().Get("filters")
		f.mu.Unlock()
		_, _ = io.WriteString(w, `[{"Id":"c1"}]`)
	case p == "/containers/c1/json":
		_, _ = fmt.Fprintf(w, `{"State":{"OOMKilled":%t}}`, f.oom)
	case p == "/containers/c1/archive":
		var b bytes.Buffer
		tw := tar.NewWriter(&b)
		_ = tw.WriteHeader(&tar.Header{Name: "auth.json", Mode: 0o600, Size: 2})
		_, _ = io.WriteString(tw, "{}")
		_ = tw.Close()
		_, _ = w.Write(b.Bytes())
	case r.Method == "DELETE" && p == "/containers/c1":
		w.WriteHeader(204)
	case p == "/volumes/create":
		var body struct{ Name string }
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		if f.volumes == nil {
			f.volumes = map[string]bool{}
		}
		f.volumes[body.Name] = true
		f.mu.Unlock()
		w.WriteHeader(201)
	case strings.HasPrefix(p, "/volumes/"):
		name := strings.TrimPrefix(p, "/volumes/")
		f.mu.Lock()
		exists := f.volumes[name]
		if r.Method == "DELETE" {
			delete(f.volumes, name)
		}
		f.mu.Unlock()
		if !exists {
			http.NotFound(w, r)
		} else if r.Method == "DELETE" {
			w.WriteHeader(204)
		} else {
			_, _ = io.WriteString(w, `{}`)
		}
	default:
		http.NotFound(w, r)
	}
}

func startFakeEngine(t *testing.T) (*fakeEngine, *Docker) {
	t.Helper()
	sock := filepath.Join(shortTempDir(t), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeEngine{exited: make(chan struct{})}
	srv := &http.Server{Handler: f}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return f, &Docker{Socket: sock, Image: "img"}
}

func readUntil(t *testing.T, r io.Reader, want string) string {
	t.Helper()
	var got strings.Builder
	done := make(chan struct{})
	go func() {
		defer close(done)
		br := bufio.NewReader(r)
		for !strings.Contains(got.String(), want) {
			b, err := br.ReadByte()
			if err != nil {
				return
			}
			got.WriteByte(b)
		}
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatalf("timed out waiting for %q, got %q", want, got.String())
	}
	return got.String()
}

func TestDockerLoginTerminalRoundTrip(t *testing.T) {
	f, d := startFakeEngine(t)
	p, err := d.StartLogin(context.Background(), LoginSpec{Name: "n", Label: "signin-1", Argv: []string{"claude"}, TTY: true})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	readUntil(t, p.Output(), "prompted > ")
	if _, err := io.WriteString(p.Input(), "abc#123\r"); err != nil {
		t.Fatal(err)
	}
	if out := readUntil(t, p.Output(), "got:abc#123"); !strings.Contains(out, "got:abc#123") {
		t.Fatalf("out %q", out)
	}
	if code, err := p.Wait(); err != nil || code != 0 {
		t.Fatalf("wait %d %v", code, err)
	}
	if b, err := p.ReadFile(context.Background(), "/home/node/.codex/auth.json"); err != nil || string(b) != "{}" {
		t.Fatalf("read %q %v", b, err)
	}
	p.Close()
	f.mu.Lock()
	defer f.mu.Unlock()
	host, _ := f.created["HostConfig"].(map[string]any)
	if f.created["Tty"] != true || f.created["OpenStdin"] != true || host["CapDrop"] == nil || host["SecurityOpt"] == nil {
		t.Fatalf("created %v", f.created)
	}
	if labels, _ := f.created["Labels"].(map[string]any); labels[labelKey] != "signin-1" {
		t.Fatalf("labels %v", f.created["Labels"])
	}
	if mounts, _ := host["Mounts"].([]any); len(mounts) != 0 {
		t.Fatalf("a sign-in container mounts %v", mounts)
	}
	if last := f.calls[len(f.calls)-1]; last != "DELETE /containers/c1" {
		t.Fatalf("calls %v", f.calls)
	}
}

func TestDockerLoginMergesOutput(t *testing.T) {
	f, d := startFakeEngine(t)
	p, err := d.StartLogin(context.Background(), LoginSpec{Name: "n", Label: "signin-2", Argv: []string{"gh"}})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if p.Input() != nil {
		t.Fatal("a login without a terminal takes no input")
	}
	b, _ := io.ReadAll(p.Output())
	if string(b) != "to stdout\nto stderr\n" {
		t.Fatalf("out %q", b)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.created["Tty"] != false || f.created["OpenStdin"] != false {
		t.Fatalf("created %v", f.created)
	}
}

// A real container, when Docker and the agent image are around:
//
//	RUNNER_DOCKER_TEST=1 go test ./internal/runner -run DockerLoginReal
func TestDockerLoginReal(t *testing.T) {
	if os.Getenv("RUNNER_DOCKER_TEST") == "" {
		t.Skip("set RUNNER_DOCKER_TEST=1 (needs Docker and vesper/agent-base)")
	}
	if _, err := exec.LookPath("docker"); err != nil {
		t.Skip("docker not installed")
	}
	sock := "/var/run/docker.sock"
	if h := os.Getenv("DOCKER_HOST"); strings.HasPrefix(h, "unix://") {
		sock = strings.TrimPrefix(h, "unix://")
	} else if home, _ := os.UserHomeDir(); home != "" {
		for _, s := range []string{home + "/.orbstack/run/docker.sock", home + "/.docker/run/docker.sock"} {
			if _, err := os.Stat(s); err == nil {
				sock = s
				break
			}
		}
	}
	d := &Docker{Socket: sock, Image: "vesper/agent-base:latest"}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	p, err := d.StartLogin(ctx, LoginSpec{Name: "vesper-signin-test", Label: "signin-test", TTY: true,
		Argv: []string{"sh", "-c", `stty cols 2000; printf 'ready> '; read x; echo "got:$x"; echo hi > /home/node/f`}})
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	readUntil(t, p.Output(), "ready> ")
	if _, err := io.WriteString(p.Input(), "abc\r"); err != nil {
		t.Fatal(err)
	}
	readUntil(t, p.Output(), "got:abc")
	if code, err := p.Wait(); err != nil || code != 0 {
		t.Fatalf("wait %d %v", code, err)
	}
	if b, err := p.ReadFile(ctx, "/home/node/f"); err != nil || string(b) != "hi\n" {
		t.Fatalf("read %q %v", b, err)
	}
}

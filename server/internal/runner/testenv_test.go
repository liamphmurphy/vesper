package runner

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The setup snippet runs in the checkout and reports the files inference
// reads, which the runner strips from the log.
func TestTestFilesScriptReportsCandidates(t *testing.T) {
	dir := t.TempDir()
	write := func(p, body string) {
		if err := os.MkdirAll(filepath.Dir(filepath.Join(dir, p)), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, p), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write(".github/workflows/ci.yml", "jobs: {}\n")
	write("docker-compose.yml", "services: {}\n")
	write("README.md", "not read")
	cmd := exec.Command("sh", "-c", "echo before; "+testFilesScript()+"echo after")
	cmd.Dir = dir
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	log, files := takeTestFiles(string(out))
	if strings.Contains(log, testFilesPrefix) || !strings.Contains(log, "before") || !strings.Contains(log, "after") {
		t.Fatalf("log = %q", log)
	}
	if len(files) != 2 || string(files[".github/workflows/ci.yml"]) != "jobs: {}\n" || files["docker-compose.yml"] == nil {
		t.Fatalf("files = %v", files)
	}
}

// After a turn the runner reads the run's Nix profile out of the stopped
// container, as it does the Codex login.
func TestDockerWaitReadsNixManifest(t *testing.T) {
	manifest := `{"version":2,"elements":[]}`
	var tb bytes.Buffer
	tw := tar.NewWriter(&tb)
	_ = tw.WriteHeader(&tar.Header{Name: "manifest.json", Mode: 0o644, Size: int64(len(manifest))})
	_, _ = tw.Write([]byte(manifest))
	_ = tw.Close()
	var asked string
	mux := http.NewServeMux()
	mux.HandleFunc("/v1.43/containers/c1/wait", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(`{"StatusCode":0}`)) })
	mux.HandleFunc("/v1.43/containers/c1/archive", func(w http.ResponseWriter, r *http.Request) {
		asked = r.URL.Query().Get("path")
		_, _ = w.Write(tb.Bytes())
	})
	mux.HandleFunc("/v1.43/containers/c1", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	sock := filepath.Join(shortTempDir(t), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	d := &Docker{Socket: sock, NixVolume: "lazyagents-nix"}
	p := &dockerProc{d: d, id: "c1"}
	if _, err := p.Wait(); err != nil {
		t.Fatal(err)
	}
	if asked != "/home/node/.nix-profile/manifest.json" || string(p.NixManifest()) != manifest {
		t.Fatalf("asked %q, got %q", asked, p.NixManifest())
	}
	var _ NixManifestProcess = p
}

// nixEngine fakes the exec calls CheckNixDaemon makes; probe decides the
// exit code of each store probe, in order.
type nixEngine struct {
	probe     []int
	restarted int
	execs     []string // "user: script" per exec
}

func (f *nixEngine) serve(t *testing.T) *Docker {
	t.Helper()
	mux := http.NewServeMux()
	cmds := map[string]map[string]any{}
	n := 0
	mux.HandleFunc("/v1.43/containers/lazyagents-nix-daemon-test/exec", func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		n++
		id := fmt.Sprintf("e%d", n)
		cmds[id] = body
		f.execs = append(f.execs, fmt.Sprint(body["User"])+": "+fmt.Sprint(asList(body["Cmd"])[2]))
		_, _ = fmt.Fprintf(w, `{"Id":%q}`, id)
	})
	mux.HandleFunc("/v1.43/containers/lazyagents-nix-daemon-test/restart", func(w http.ResponseWriter, r *http.Request) {
		f.restarted++
		w.WriteHeader(204)
	})
	mux.HandleFunc("/v1.43/containers/lazyagents-nix-daemon-test/logs", func(w http.ResponseWriter, r *http.Request) {
		msg := "waiting for the big Nix store lock...\n"
		h := make([]byte, 8)
		h[0] = 2
		binary.BigEndian.PutUint32(h[4:], uint32(len(msg)))
		_, _ = w.Write(append(h, msg...))
	})
	mux.HandleFunc("/v1.43/exec/", func(w http.ResponseWriter, r *http.Request) {
		id := strings.Split(strings.TrimPrefix(r.URL.Path, "/v1.43/exec/"), "/")[0]
		if strings.HasSuffix(r.URL.Path, "/start") {
			msg := "out of " + id + "\n"
			h := make([]byte, 8)
			h[0] = 1
			binary.BigEndian.PutUint32(h[4:], uint32(len(msg)))
			_, _ = w.Write(append(h, msg...))
			return
		}
		code := 0
		if strings.Contains(fmt.Sprint(asList(cmds[id]["Cmd"])[2]), "path-info") && len(f.probe) > 0 {
			code, f.probe = f.probe[0], f.probe[1:]
		}
		_, _ = fmt.Fprintf(w, `{"ExitCode":%d,"Running":false}`, code)
	})
	sock := filepath.Join(shortTempDir(t), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return &Docker{Socket: sock, Stack: "test", NixVolume: "lazyagents-nix", ProxyDir: shortTempDir(t), ProxyVolume: "p"}
}

// A daemon that never answers store queries is restarted once, then kept
// away from turns, and why is written where a turn can read it.
func TestCheckNixDaemonReportsAndFencesAStuckDaemon(t *testing.T) {
	old := nixRestartSettle
	nixRestartSettle = 0
	t.Cleanup(func() { nixRestartSettle = old })
	f := &nixEngine{probe: []int{124, 124}}
	d := f.serve(t)
	st, err := d.CheckNixDaemon(context.Background())
	if err == nil || st.Healthy || !st.Restarted || f.restarted != 1 {
		t.Fatalf("status %+v err %v restarts %d", st, err, f.restarted)
	}
	if !strings.Contains(st.DaemonLog, "big Nix store lock") || !strings.Contains(st.Diagnostics, "out of") || !strings.Contains(st.Probe, "exit 124") {
		t.Fatalf("status lacks the evidence: %+v", st)
	}
	if !strings.HasPrefix(f.execs[0], "1000: ") || !strings.HasPrefix(f.execs[len(f.execs)-1], "0: ") {
		t.Fatalf("probe must run as the turn user, diagnostics as root: %v", f.execs)
	}
	b, err := os.ReadFile(filepath.Join(d.ProxyDir, NixStatusFile))
	if err != nil || !strings.Contains(string(b), `"healthy": false`) {
		t.Fatalf("status file: %v %s", err, b)
	}
	if d.nixMount() != nil {
		t.Fatal("turns still mount the store of a stuck daemon")
	}
}

func TestCheckNixDaemonHealthy(t *testing.T) {
	f := &nixEngine{probe: []int{0}}
	d := f.serve(t)
	st, err := d.CheckNixDaemon(context.Background())
	if err != nil || !st.Healthy || st.Restarted || f.restarted != 0 || st.DaemonLog != "" {
		t.Fatalf("status %+v err %v", st, err)
	}
	if d.nixMount() == nil {
		t.Fatal("a healthy daemon's store isn't mounted")
	}
}

package runner

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/devworkspace"
	"github.com/liamphmurphy/vesper/server/internal/playground"
)

func TestParseArch(t *testing.T) {
	cases := map[string]string{
		"nix done\nx86_64\n":  "x86_64-linux",
		"nix done\naarch64\n": "aarch64-linux",
		"arm64\n":             "aarch64-linux",
		"mips\n":              "",
		"":                    "",
	}
	for in, want := range cases {
		if got := parseArch(in); got != want {
			t.Fatalf("parseArch(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDevWorkspaceHandlerRejectsUnauthenticated(t *testing.T) {
	r := &Runner{Cfg: Config{Playgrounds: PlaygroundConfig{Origins: []string{"http://localhost:8080"}}}}
	h := r.devWorkspaceHandler(uuid.New())
	req := httptest.NewRequest(http.MethodGet, "/ws", nil)
	req.Header.Set("Origin", "http://localhost:8080")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", rec.Code)
	}
}

// The session cookie is SameSite=Strict, so a playground on a neighbouring
// port of the same host still sends it: only Vesper's pages may connect.
func TestDevWorkspaceHandlerRejectsOtherOrigins(t *testing.T) {
	r := &Runner{Cfg: Config{Playgrounds: PlaygroundConfig{Origins: []string{"http://localhost:8080"}}}}
	h := r.devWorkspaceHandler(uuid.New())
	for _, origin := range []string{"", "http://localhost:8091", "https://evil.example"} {
		req := httptest.NewRequest(http.MethodGet, "/ws", nil)
		if origin != "" {
			req.Header.Set("Origin", origin)
		}
		req.AddCookie(&http.Cookie{Name: auth.SessionCookie, Value: "stolen"})
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusForbidden {
			t.Fatalf("Origin %q: status = %d, want 403", origin, rec.Code)
		}
	}
}

func TestGatewayCustomHandlerLifecycle(t *testing.T) {
	gw := &playground.Gateway{}
	const port = 8090
	gw.RegisterCustomHandler(port, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))
	rec := httptest.NewRecorder()
	gw.Handler(port).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/ws", nil))
	if rec.Code != http.StatusTeapot {
		t.Fatalf("custom handler status = %d, want 418", rec.Code)
	}

	gw.UnregisterCustomHandler(port)
	rec2 := httptest.NewRecorder()
	gw.Handler(port).ServeHTTP(rec2, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec2.Code != http.StatusServiceUnavailable {
		t.Fatalf("after unregister status = %d, want 503", rec2.Code)
	}
}

func TestExecDevWorkspaceScriptStreamsLargeScriptViaStdin(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "docker.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer ln.Close()

	var (
		mu          sync.Mutex
		execPayload map[string]any
		gotScript   string
	)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := strings.TrimPrefix(r.URL.Path, "/v1.43")
		switch {
		case r.Method == "POST" && p == "/containers/c1/exec":
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			mu.Lock()
			execPayload = body
			mu.Unlock()
			_, _ = io.WriteString(w, `{"Id":"e1"}`)
		case r.Method == "POST" && p == "/exec/e1/start":
			_, _ = io.Copy(io.Discard, r.Body)
			if r.Header.Get("Upgrade") != "tcp" {
				http.Error(w, "expected tcp upgrade", 400)
				return
			}
			conn, buf, err := w.(http.Hijacker).Hijack()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				_, _ = io.WriteString(conn, "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
				scriptBytes, _ := io.ReadAll(buf)
				mu.Lock()
				gotScript = string(scriptBytes)
				mu.Unlock()
				msg := "synced ok\n"
				hdr := make([]byte, 8)
				hdr[0] = 1
				binary.BigEndian.PutUint32(hdr[4:], uint32(len(msg)))
				_, _ = conn.Write(append(hdr, msg...))
			}()
		case r.Method == "GET" && p == "/exec/e1/json":
			_, _ = io.WriteString(w, `{"ExitCode":0,"Running":false}`)
		default:
			http.NotFound(w, r)
		}
	})}
	go func() { _ = srv.Serve(ln) }()
	defer srv.Close()

	largeScript := strings.Repeat("echo ok\n", 30000) // > 200 KiB, past Linux 128 KiB MAX_ARG_STRLEN
	d := &Docker{Socket: sock}
	out, code, err := d.ExecDevWorkspaceScript(context.Background(), "c1", largeScript, []string{"GH_TOKEN=tok"})
	if err != nil {
		t.Fatalf("ExecDevWorkspaceScript err = %v", err)
	}
	if code != 0 {
		t.Fatalf("code = %d, want 0", code)
	}
	if out != "synced ok\n" {
		t.Fatalf("out = %q, want %q", out, "synced ok\n")
	}

	mu.Lock()
	defer mu.Unlock()
	if cmd, _ := execPayload["Cmd"].([]any); !slices.Equal(cmd, []any{"sh", "-s"}) {
		t.Fatalf("Cmd = %v, want [sh -s]", execPayload["Cmd"])
	}
	if execPayload["AttachStdin"] != true {
		t.Fatalf("AttachStdin = %v, want true", execPayload["AttachStdin"])
	}
	if gotScript != largeScript {
		t.Fatalf("received script len = %d, want %d", len(gotScript), len(largeScript))
	}
}

type stubDevWorkspaceBackend struct {
	scripts []string
	failAt  int
	failOut string
}

func (s *stubDevWorkspaceBackend) EnsureDevWorkspaceContainer(context.Context, uuid.UUID) (string, error) {
	return "c1", nil
}
func (s *stubDevWorkspaceBackend) StopDevWorkspaceContainer(context.Context, uuid.UUID) error {
	return nil
}
func (s *stubDevWorkspaceBackend) OpenDevWorkspacePTY(context.Context, uuid.UUID, int, int) (DevPTY, error) {
	return nil, nil
}
func (s *stubDevWorkspaceBackend) ExecDevWorkspaceScript(_ context.Context, _ string, script string, _ []string) (string, int, error) {
	s.scripts = append(s.scripts, script)
	if s.failAt > 0 && len(s.scripts) == s.failAt {
		return s.failOut, 1, nil
	}
	return "", 0, nil
}

func TestSyncDevWorkspaceReposBatchesAndReportsProgress(t *testing.T) {
	repos := make([]devworkspace.RepoSpec, 560)
	for i := range repos {
		repos[i] = devworkspace.RepoSpec{
			RepoURL:   fmt.Sprintf("https://github.com/org/repo-%03d", i),
			Directory: fmt.Sprintf("repo-%03d", i),
		}
	}
	backend := &stubDevWorkspaceBackend{}
	var steps []string
	err := syncDevWorkspaceRepos(context.Background(), backend, "c1", repos, "Liam", "liam@example.com", nil, func(step string) {
		steps = append(steps, step)
	})
	if err != nil {
		t.Fatalf("syncDevWorkspaceRepos err = %v", err)
	}
	wantBatches := (560 + devWorkspaceRepoSyncBatchSize - 1) / devWorkspaceRepoSyncBatchSize
	if len(backend.scripts) != wantBatches {
		t.Fatalf("batches = %d, want %d", len(backend.scripts), wantBatches)
	}
	if steps[0] != "Syncing repositories (0/560)" || steps[len(steps)-1] != "Syncing repositories (500/560)" {
		t.Fatalf("unexpected progress steps: first=%q last=%q", steps[0], steps[len(steps)-1])
	}
	for i, r := range repos {
		b := backend.scripts[i/devWorkspaceRepoSyncBatchSize]
		if !strings.Contains(b, r.RepoURL) {
			t.Fatalf("batch %d missing repo %s", i/devWorkspaceRepoSyncBatchSize, r.RepoURL)
		}
	}

	failing := &stubDevWorkspaceBackend{failAt: 2, failOut: "/workspace/repo-031 (https://github.com/org/repo-031): not found\n"}
	err = syncDevWorkspaceRepos(context.Background(), failing, "c1", repos, "Liam", "liam@example.com", nil, func(string) {})
	if err == nil || !strings.Contains(err.Error(), "repo sync failed (exit 1)") || !strings.Contains(err.Error(), "repo-031") {
		t.Fatalf("unexpected failure err = %v", err)
	}
}

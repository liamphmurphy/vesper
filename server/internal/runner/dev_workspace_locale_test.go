package runner

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
)

// tmux draws every non-ASCII character as "_" when the client's locale isn't
// UTF-8, which mangled Claude Code's logo and the shell prompt in the Dev
// workspace terminal. These pin the terminal to a UTF-8 locale on both
// backends.

// devPTYEngine is just enough of the Docker API for OpenDevWorkspacePTY: the
// dev container is already running, and it records the exec it is asked to
// create.
type devPTYEngine struct {
	mu   sync.Mutex
	exec map[string]any
}

func (e *devPTYEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path
	switch {
	case r.Method == "GET" && strings.HasSuffix(path, "/json") && strings.Contains(path, "/containers/"):
		_, _ = w.Write([]byte(`{"Id":"dev1","State":{"Running":true}}`))
	case r.Method == "POST" && strings.HasSuffix(path, "/exec") && strings.Contains(path, "/containers/"):
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		e.mu.Lock()
		e.exec = body
		e.mu.Unlock()
		_, _ = w.Write([]byte(`{"Id":"exec1"}`))
	case r.Method == "POST" && strings.HasSuffix(path, "/start"):
		conn, brw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		_, _ = brw.WriteString("HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
		_ = brw.Flush()
		_ = conn.Close()
	default:
		w.WriteHeader(http.StatusOK)
	}
}

func TestDockerDevWorkspacePTYUsesUTF8Locale(t *testing.T) {
	sock := filepath.Join(shortTempDir(t), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	engine := &devPTYEngine{}
	srv := &http.Server{Handler: engine}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })

	d := &Docker{Socket: sock, Image: "img"}
	pty, err := d.OpenDevWorkspacePTY(context.Background(), uuid.New(), 0, 0)
	if err != nil {
		t.Fatalf("OpenDevWorkspacePTY: %v", err)
	}
	_ = pty.Close()

	engine.mu.Lock()
	defer engine.mu.Unlock()
	var env []string
	for _, v := range engine.exec["Env"].([]any) {
		env = append(env, v.(string))
	}
	if !slices.Contains(env, "LANG=C.UTF-8") {
		t.Errorf("exec Env %v lacks LANG=C.UTF-8", env)
	}
	cmd := engine.exec["Cmd"].([]any)
	if script := cmd[len(cmd)-1].(string); !strings.Contains(script, "tmux -u ") {
		t.Errorf("exec Cmd %q doesn't start tmux with -u", script)
	}
}

func TestMicroVMDevShellEnvUsesUTF8Locale(t *testing.T) {
	env := (&MicroVM{}).devShellEnv()
	if env["LANG"] != "C.UTF-8" {
		t.Fatalf("devShellEnv LANG = %q, want C.UTF-8", env["LANG"])
	}
}

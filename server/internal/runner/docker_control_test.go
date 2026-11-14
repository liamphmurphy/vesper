package runner

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestDockerControlAPIAddress(t *testing.T) {
	for _, mode := range []string{"pin", "missing", "ambiguous", "unavailable"} {
		t.Run(mode, func(t *testing.T) {
			var ip atomic.Value
			ip.Store("10.0.0.2")
			f := &fakeEngine{exited: make(chan struct{})}
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch strings.TrimPrefix(r.URL.Path, "/v1.43") {
				case "/networks/control":
					if mode == "unavailable" {
						http.Error(w, "engine unavailable", 503)
						return
					}
					endpoints := map[string]any{"api-container": map[string]string{"Name": "compose-api-1", "IPv4Address": ip.Load().(string) + "/24"}}
					if mode == "ambiguous" {
						endpoints["other-api"] = map[string]string{"IPv4Address": "10.0.0.3/24"}
					}
					_ = json.NewEncoder(w).Encode(map[string]any{"Name": "control", "Containers": endpoints})
				case "/containers/api-container/json", "/containers/other-api/json":
					alias := "api"
					if mode == "missing" {
						alias = "unrelated"
					}
					_, _ = fmt.Fprintf(w, `{"NetworkSettings":{"Networks":{"control":{"Aliases":[%q]}}}}`, alias)
				default:
					f.ServeHTTP(w, r)
				}
			}))
			defer srv.Close()
			d := &Docker{Network: "control", client: &http.Client{Transport: &http.Transport{
				DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
					return (&net.Dialer{}).DialContext(ctx, "tcp", srv.Listener.Addr().String())
				},
			}}}
			ctx := context.Background()
			p, err := d.Start(ctx, "test", ExecSpec{Name: "turn", ControlURL: "http://api:8000/mcp", Networks: []string{"preview"}})
			if mode != "pin" {
				if err == nil || f.created != nil {
					t.Fatalf("unsafe control routing started a container: %v", err)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if _, _, err := captureProcess(ctx, p); err != nil {
				t.Fatal(err)
			}
			got := fmt.Sprint(f.created["HostConfig"].(map[string]any)["ExtraHosts"])
			if got != "[host.docker.internal:host-gateway api:10.0.0.2]" {
				t.Fatalf("control mapping was not delivered to Docker: %s", got)
			}
			ip.Store("10.0.0.9") // A new launch must resolve an API that was replaced.
			if got, err := d.controlAPIHost(ctx, "http://api:8000/mcp"); err != nil || got != "api:10.0.0.9" {
				t.Fatalf("stale control address: %q %v", got, err)
			}
		})
	}
	for _, rawURL := range []string{"", "http://127.0.0.1:8000/mcp", "http://[::1]:8000/mcp", "http://host.docker.internal:8000/mcp"} {
		if got, err := (&Docker{Network: "control"}).controlAPIHost(context.Background(), rawURL); err != nil || got != "" {
			t.Fatalf("explicit control route %q: %q %v", rawURL, got, err)
		}
	}
}

// Exercises Docker's DNS and /etc/hosts precedence with the actual policy
// hook. Stub APIs and fake tokens keep the test independent of any login.
func TestDockerControlAPIWithPlayground(t *testing.T) {
	if os.Getenv("RUNNER_DOCKER_TEST") == "" {
		t.Skip("set RUNNER_DOCKER_TEST=1 (needs Docker and vesper/agent-base)")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	docker := func(args ...string) string {
		t.Helper()
		out, err := exec.CommandContext(ctx, "docker", args...).CombinedOutput()
		if err != nil {
			t.Fatalf("docker %v: %v\n%s", args[:1], err, out)
		}
		return strings.TrimSpace(string(out))
	}
	key := uuid.NewString()[:8]
	control, preview := "lazyagents_agents-test-"+key, "lazyagents-play-test-"+key
	for _, network := range []string{control, preview} {
		docker("network", "create", network)
		t.Cleanup(func() { _ = exec.Command("docker", "network", "rm", network).Run() })
	}
	server := `import http.server,json,sys
role=sys.argv[1]
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*args): pass
 def do_POST(self):
  self.send_response(200 if role=='control' else 401)
  self.end_headers()
  self.wfile.write(json.dumps({'decision':'allow','instance':role}).encode())
http.server.HTTPServer(('0.0.0.0',8000),Handler).serve_forever()
`
	previewID := ""
	for _, fixture := range []struct{ name, network string }{{"control", control}, {"preview", preview}} {
		id := docker("run", "-d", "--network", fixture.network, "--network-alias", "api", "vesper/agent-base:latest", "python3", "-c", server, fixture.name)
		if fixture.name == "preview" {
			previewID = id
		}
		t.Cleanup(func() { _ = exec.Command("docker", "rm", "-f", id).Run() })
		docker("exec", id, "python3", "-c", `import socket,time
for i in range(100):
 try:
  socket.create_connection(('127.0.0.1',8000),.1).close();break
 except OSError: time.sleep(.05)
else: raise RuntimeError('API did not start')`)
	}
	socket := strings.TrimPrefix(os.Getenv("DOCKER_HOST"), "unix://")
	if socket == "" {
		socket = "/var/run/docker.sock"
	}
	d := &Docker{Socket: socket, Network: control}
	hook, err := os.ReadFile("../harness/tool_hook.py")
	if err != nil {
		t.Fatal(err)
	}
	probe := fmt.Sprintf(`import json,os,subprocess,tempfile,urllib.request
for path in ['/mcp','/mcp/connectors/github']:
 r=urllib.request.urlopen(urllib.request.Request('http://api:8000'+path,data=b'{}',headers={'Authorization':'Bearer fake-turn-token'}),timeout=5)
 assert json.load(r)['instance']=='control'
with tempfile.NamedTemporaryFile(mode='w',suffix='.py') as f:
 f.write(%q);f.flush()
 r=subprocess.run(['python3',f.name],input='{"tool_name":"Bash","tool_input":{"command":"git status"}}',capture_output=True,text=True,check=True)
 assert json.loads(r.stdout)=={},r.stdout
print('control API and hook reachable')`, string(hook))
	// A turn that starts a playground has no preview network yet. Subsequent
	// turns join it; a stopped/restarted playground must not poison routing.
	for turn, joined := range []bool{false, true, false, true} {
		if turn == 2 {
			docker("stop", previewID)
		}
		if turn == 3 {
			docker("start", previewID)
			docker("exec", previewID, "python3", "-c", `import socket,time
for i in range(100):
 try:
  socket.create_connection(('127.0.0.1',8000),.1).close();break
 except OSError: time.sleep(.05)
else: raise RuntimeError('API did not restart')`)
		}
		host, err := d.controlAPIHost(ctx, "http://api:8000/mcp")
		if err != nil {
			t.Fatal(err)
		}
		args := []string{"create", "--network", control}
		if host != "" {
			args = append(args, "--add-host", host)
		}
		args = append(args, "-e", "LAZYAGENTS_POLICY_URL=http://api:8000/api/v1/agent/tool-policy", "-e", "LAZYAGENTS_POLICY_TOKEN=fake-turn-token", "vesper/agent-base:latest", "python3", "-c", probe)
		id := docker(args...)
		t.Cleanup(func() { _ = exec.Command("docker", "rm", "-f", id).Run() })
		if joined {
			docker("network", "connect", preview, id)
		}
		if out := docker("start", "-a", id); out != "control API and hook reachable" {
			t.Fatalf("turn %d (playground joined=%v): %s", turn+1, joined, out)
		}
		docker("rm", id)
	}
}

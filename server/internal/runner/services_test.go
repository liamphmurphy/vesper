package runner

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// svcEngine fakes the Engine API calls StartServices makes. Created
// containers get ids s1, s2, ...; each reports state from the status func.
type svcEngine struct {
	mu       sync.Mutex
	calls    []string
	bodies   map[string]map[string]any // container name → create body
	ids      map[string]string         // id → name
	images   map[string]bool           // images present (others 404 until pulled)
	pullFail bool
	status   func(name string) string // "healthy", "running", "exited", "starting"
	// deletes are the query of each DELETE, by path; stale names are
	// containers that already exist (create answers 409 once).
	deletes map[string]string
	stale   map[string]bool
}

func (f *svcEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := strings.TrimPrefix(r.URL.Path, "/v1.43")
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, r.Method+" "+p)
	if r.Method == "DELETE" {
		if f.deletes == nil {
			f.deletes = map[string]string{}
		}
		f.deletes[p] = r.URL.RawQuery
	}
	switch {
	case p == "/networks/create":
		w.WriteHeader(201)
		_, _ = io.WriteString(w, `{"Id":"n1"}`)
	case p == "/containers/create":
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		name := r.URL.Query().Get("name")
		if f.stale[name] {
			delete(f.stale, name)
			http.Error(w, `{"message":"Conflict"}`, 409)
			return
		}
		if !f.images[body["Image"].(string)] {
			http.Error(w, `{"message":"No such image"}`, 404)
			return
		}
		id := fmt.Sprintf("s%d", len(f.ids)+1)
		f.bodies[name], f.ids[id] = body, name
		w.WriteHeader(201)
		_, _ = fmt.Fprintf(w, `{"Id":%q}`, id)
	case p == "/images/create":
		if f.pullFail {
			_, _ = io.WriteString(w, `{"status":"Pulling"}`+"\n"+`{"error":"manifest unknown"}`+"\n")
			return
		}
		f.images[r.URL.Query().Get("fromImage")+":"+r.URL.Query().Get("tag")] = true
		_, _ = io.WriteString(w, `{"status":"Downloaded"}`+"\n")
	case strings.HasSuffix(p, "/start"):
		w.WriteHeader(204)
	case strings.HasSuffix(p, "/json") && strings.HasPrefix(p, "/containers/"):
		id := strings.TrimSuffix(strings.TrimPrefix(p, "/containers/"), "/json")
		st := f.status(f.ids[id])
		state := map[string]any{"Status": "running"}
		switch st {
		case "exited":
			state = map[string]any{"Status": "exited", "ExitCode": 1}
		case "healthy", "starting":
			state["Health"] = map[string]any{"Status": st}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"State": state})
	case strings.HasSuffix(p, "/logs"):
		h := make([]byte, 8)
		h[0] = 2
		msg := "FATAL: data directory has wrong ownership\n"
		binary.BigEndian.PutUint32(h[4:], uint32(len(msg)))
		_, _ = w.Write(append(h, msg...))
	case r.Method == "DELETE":
		w.WriteHeader(204)
	default:
		http.NotFound(w, r)
	}
}

func (f *svcEngine) called(call string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Contains(f.calls, call)
}

func startSvcEngine(t *testing.T, f *svcEngine) *Docker {
	t.Helper()
	f.bodies, f.ids = map[string]map[string]any{}, map[string]string{}
	if f.images == nil {
		f.images = map[string]bool{}
	}
	sock := filepath.Join(shortTempDir(t), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: f}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return &Docker{Socket: sock, Stack: "lazyagents-dev", MemoryMB: 512, PidsLimit: 256}
}

func pgService() agentdef.Service {
	return agentdef.Service{
		Name: "postgres", Image: "postgres:17-alpine", User: "postgres",
		Env:         map[string]string{"POSTGRES_PASSWORD": "pw"},
		Tmpfs:       []string{"/var/lib/postgresql/data"},
		Healthcheck: []string{"CMD", "pg_isready"},
	}
}

func TestStartServicesIsSandboxedAndCleansUp(t *testing.T) {
	f := &svcEngine{status: func(string) string { return "healthy" }}
	d := startSvcEngine(t, f)
	network, stop, err := d.StartServices(context.Background(), "run-1", "run-1-3", []agentdef.Service{pgService()})
	if err != nil {
		t.Fatal(err)
	}
	if network != "lazyagents-svc-run-1-3" {
		t.Fatalf("network %q", network)
	}
	// Pulled because it was missing, then created.
	if !f.called("POST /images/create") {
		t.Fatal("missing image wasn't pulled")
	}
	body := f.bodies["lazyagents-svc-run-1-3-postgres"]
	if body == nil {
		t.Fatalf("service not created: %v", f.calls)
	}
	host := body["HostConfig"].(map[string]any)
	if host["CapDrop"] != nil || host["CapAdd"] != nil || fmt.Sprint(host["SecurityOpt"]) != "[no-new-privileges]" ||
		host["Memory"] == nil || host["PidsLimit"] == nil || host["Privileged"] != nil || host["ExtraHosts"] != nil {
		t.Fatalf("service sandbox %v", host)
	}
	if host["NetworkMode"] != network || body["User"] != "postgres" {
		t.Fatalf("network %v user %v", host["NetworkMode"], body["User"])
	}
	for _, m := range host["Mounts"].([]any) {
		if m.(map[string]any)["Type"] != "tmpfs" {
			t.Fatalf("a service got a non-tmpfs mount: %v", m)
		}
	}
	aliases := body["NetworkingConfig"].(map[string]any)["EndpointsConfig"].(map[string]any)[network].(map[string]any)["Aliases"]
	if fmt.Sprint(aliases) != "[postgres]" {
		t.Fatalf("aliases %v", aliases)
	}
	if labels := body["Labels"].(map[string]any); labels[labelKey] != "run-1" || labels[stackLabelKey] != "lazyagents-dev" {
		t.Fatalf("labels %v", labels)
	}
	stop()
	stop() // safe twice
	if !f.called("DELETE /containers/s1") || !f.called("DELETE /networks/lazyagents-svc-run-1-3") {
		t.Fatalf("stop left the service behind: %v", f.calls)
	}
}

// A service that dies fails the turn with its own logs, and nothing is left.
func TestStartServicesReportsAServiceThatExits(t *testing.T) {
	f := &svcEngine{images: map[string]bool{"postgres:17-alpine": true}, status: func(string) string { return "exited" }}
	d := startSvcEngine(t, f)
	_, _, err := d.StartServices(context.Background(), "run-1", "k", []agentdef.Service{pgService()})
	if err == nil || !strings.Contains(err.Error(), "service postgres") || !strings.Contains(err.Error(), "wrong ownership") {
		t.Fatalf("err = %v, want the service's log tail", err)
	}
	if !f.called("DELETE /containers/s1") || !f.called("DELETE /networks/lazyagents-svc-k") {
		t.Fatalf("a failed start left containers behind: %v", f.calls)
	}
}

func TestStartServicesReportsAFailedPull(t *testing.T) {
	f := &svcEngine{pullFail: true, status: func(string) string { return "healthy" }}
	d := startSvcEngine(t, f)
	_, _, err := d.StartServices(context.Background(), "run-1", "k", []agentdef.Service{pgService()})
	if err == nil || !strings.Contains(err.Error(), "manifest unknown") {
		t.Fatalf("err = %v, want the pull error", err)
	}
}

func TestStartServicesTimesOutWaitingForHealth(t *testing.T) {
	old, oldPoll := ServiceReadyTimeout, servicePoll
	ServiceReadyTimeout, servicePoll = 300*time.Millisecond, 20*time.Millisecond
	t.Cleanup(func() { ServiceReadyTimeout, servicePoll = old, oldPoll })
	f := &svcEngine{images: map[string]bool{"postgres:17-alpine": true}, status: func(string) string { return "starting" }}
	d := startSvcEngine(t, f)
	_, _, err := d.StartServices(context.Background(), "run-1", "k", []agentdef.Service{pgService()})
	if err == nil || !strings.Contains(err.Error(), "not ready") {
		t.Fatalf("err = %v, want a readiness timeout", err)
	}
}

// A turn joins its service network before it starts.
func TestDockerStartJoinsServiceNetworks(t *testing.T) {
	f, d := startFakeEngine(t)
	if _, err := d.Start(context.Background(), "run-1", ExecSpec{Name: "t", Argv: []string{"true"}, Networks: []string{"lazyagents-svc-k"}}); err != nil {
		t.Fatal(err)
	}
	connect := slices.Index(f.calls, "POST /networks/lazyagents-svc-k/connect")
	start := slices.Index(f.calls, "POST /containers/c1/start")
	if connect < 0 || start < 0 || connect > start {
		t.Fatalf("calls %v: want the network joined before start", f.calls)
	}
}

// A Docker turn keeps its SSH key in the run's home volume, not the checkout.
func TestDockerStartPutsSSHDirInHome(t *testing.T) {
	f, d := startFakeEngine(t)
	if _, err := d.Start(context.Background(), "run-1", ExecSpec{Name: "t", Argv: []string{"true"}}); err != nil {
		t.Fatal(err)
	}
	env, _ := f.created["Env"].([]any)
	if !slices.Contains(env, any(SSHDirEnv+"=/home/node/.lazyagents/ssh")) {
		t.Fatalf("env %v", env)
	}
}

// A database image declares an anonymous data volume. Removing a service's
// container without v=1 left one behind per turn; with it, the volume goes
// with the container, at the turn's end and when a stale one is replaced.
func TestServiceContainersTakeTheirVolumesWithThem(t *testing.T) {
	f := &svcEngine{status: func(string) string { return "healthy" }, stale: map[string]bool{"lazyagents-svc-k-postgres": true}}
	d := startSvcEngine(t, f)
	_, stop, err := d.StartServices(context.Background(), "run-1", "k", []agentdef.Service{pgService()})
	if err != nil {
		t.Fatal(err)
	}
	stop()
	for _, path := range []string{"/containers/lazyagents-svc-k-postgres", "/containers/s1"} {
		if q, ok := f.deletes[path]; !ok || !strings.Contains(q, "v=1") {
			t.Errorf("DELETE %s?%s: want v=1 so the data volume goes too (deletes %v)", path, q, f.deletes)
		}
	}
}

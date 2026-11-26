package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

// fakeEngine is just enough of the Docker Engine API for the guard: it keeps
// labelled containers, networks and volumes, and records what reached it.
type fakeEngine struct {
	mu         sync.Mutex
	next       int
	containers map[string]map[string]any // id -> create body
	networks   map[string]map[string]any // name -> create body
	volumes    map[string]map[string]any // name -> create body
	execs      map[string]string         // exec id -> container id
	images     map[string]map[string]any // ref -> inspect body
	seen       []string                  // "METHOD path?query" that reached the engine
}

func newFakeEngine() *fakeEngine {
	return &fakeEngine{
		containers: map[string]map[string]any{},
		networks:   map[string]map[string]any{},
		volumes:    map[string]map[string]any{},
		execs:      map[string]string{},
		images:     map[string]map[string]any{},
	}
}

// RoundTrip serves requests in process, so the guard's transport is the engine.
func (e *fakeEngine) RoundTrip(r *http.Request) (*http.Response, error) {
	rec := httptest.NewRecorder()
	e.ServeHTTP(rec, r)
	return rec.Result(), nil
}

func labelsOf(body map[string]any) map[string]any {
	if l, ok := body["Labels"].(map[string]any); ok {
		return l
	}
	return map[string]any{}
}

// matches applies a label=key=value filter the way the Engine does.
func matches(r *http.Request, labels map[string]any) bool {
	raw := r.URL.Query().Get("filters")
	if raw == "" {
		return true
	}
	var f map[string][]string
	_ = json.Unmarshal([]byte(raw), &f)
	for _, want := range f["label"] {
		k, v, hasV := strings.Cut(want, "=")
		got, ok := labels[k]
		if !ok || (hasV && got != v) {
			return false
		}
	}
	return true
}

func (e *fakeEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	e.mu.Lock()
	defer e.mu.Unlock()
	p := apiVersionRe.ReplaceAllString(r.URL.Path, "")
	e.seen = append(e.seen, strings.TrimSuffix(r.Method+" "+p+"?"+r.URL.RawQuery, "?"))
	parts := strings.Split(strings.Trim(p, "/"), "/")
	var body map[string]any
	if r.Body != nil {
		b, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(b, &body)
	}
	reply := func(v any) { _ = json.NewEncoder(w).Encode(v) }
	notFound := func() { w.WriteHeader(http.StatusNotFound); reply(map[string]string{"message": "not found"}) }
	switch {
	case r.Method == http.MethodPost && p == "/containers/create":
		e.next++
		id := fmt.Sprintf("c%d", e.next)
		e.containers[id] = body
		w.WriteHeader(http.StatusCreated)
		reply(map[string]string{"Id": id})
	case r.Method == http.MethodGet && p == "/containers/json":
		var out []map[string]string
		for id, c := range e.containers {
			if matches(r, labelsOf(c)) {
				out = append(out, map[string]string{"Id": id})
			}
		}
		reply(out)
	case len(parts) >= 2 && parts[0] == "containers":
		c, ok := e.containers[parts[1]]
		switch {
		case !ok:
			notFound()
		case r.Method == http.MethodDelete:
			delete(e.containers, parts[1])
			w.WriteHeader(http.StatusNoContent)
		case len(parts) == 3 && parts[2] == "json":
			reply(map[string]any{"Id": parts[1], "Config": map[string]any{"Labels": labelsOf(c)}})
		case len(parts) == 3 && parts[2] == "exec":
			e.next++
			id := fmt.Sprintf("e%d", e.next)
			e.execs[id] = parts[1]
			w.WriteHeader(http.StatusCreated)
			reply(map[string]string{"Id": id})
		default:
			w.WriteHeader(http.StatusNoContent)
		}
	case r.Method == http.MethodGet && len(parts) >= 3 && parts[0] == "images" && parts[len(parts)-1] == "json":
		img, ok := e.images[strings.Join(parts[1:len(parts)-1], "/")]
		if !ok {
			notFound()
			return
		}
		reply(img)
	case len(parts) == 3 && parts[0] == "exec":
		cid, ok := e.execs[parts[1]]
		if !ok {
			notFound()
			return
		}
		reply(map[string]string{"ContainerID": cid})
	case r.Method == http.MethodPost && (p == "/networks/create" || p == "/volumes/create"):
		name, _ := body["Name"].(string)
		if p == "/networks/create" {
			e.networks[name] = body
		} else {
			e.volumes[name] = body
		}
		w.WriteHeader(http.StatusCreated)
		reply(map[string]string{"Id": name, "Name": name})
	case r.Method == http.MethodGet && p == "/networks":
		var out []map[string]string
		for name, n := range e.networks {
			if matches(r, labelsOf(n)) {
				out = append(out, map[string]string{"Id": name})
			}
		}
		reply(out)
	case r.Method == http.MethodGet && p == "/volumes":
		var out []map[string]string
		for name, v := range e.volumes {
			if matches(r, labelsOf(v)) {
				out = append(out, map[string]string{"Name": name})
			}
		}
		reply(map[string]any{"Volumes": out})
	case len(parts) >= 2 && (parts[0] == "networks" || parts[0] == "volumes"):
		set := e.networks
		if parts[0] == "volumes" {
			set = e.volumes
		}
		n, ok := set[parts[1]]
		switch {
		case !ok:
			notFound()
		case r.Method == http.MethodDelete:
			delete(set, parts[1])
			w.WriteHeader(http.StatusNoContent)
		default:
			reply(map[string]any{"Name": parts[1], "Labels": labelsOf(n)})
		}
	default:
		reply(map[string]any{})
	}
}

func (e *fakeEngine) reached(prefix string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	for _, s := range e.seen {
		if strings.HasPrefix(s, prefix) {
			return true
		}
	}
	return false
}

type guardClient struct {
	t   *testing.T
	srv *httptest.Server
}

func newGuardClient(t *testing.T, key string, engine *fakeEngine) *guardClient {
	t.Helper()
	srv := httptest.NewServer(newDockerGuard(key, engine))
	t.Cleanup(srv.Close)
	return &guardClient{t: t, srv: srv}
}

// do sends one Engine call through the guard and returns the status and the
// decoded body.
func (c *guardClient) do(method, path string, body any) (int, map[string]any) {
	c.t.Helper()
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			c.t.Fatal(err)
		}
		rd = strings.NewReader(string(b))
	}
	req, err := http.NewRequest(method, c.srv.URL+"/v1.47"+path, rd)
	if err != nil {
		c.t.Fatal(err)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

func TestDockerGuardLabelsWhatTheTurnCreates(t *testing.T) {
	engine := newFakeEngine()
	c := newGuardClient(t, "run-1", engine)

	code, out := c.do(http.MethodPost, "/containers/create", map[string]any{
		"Image": "postgres", "Labels": map[string]any{"com.docker.compose.project": "app"},
	})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	labels := labelsOf(engine.containers[out["Id"].(string)])
	if labels[guestproto.DockerGuardLabel] != "run-1" || labels["com.docker.compose.project"] != "app" {
		t.Fatalf("container labels = %v, want the turn's label added to the caller's", labels)
	}
	if code, _ := c.do(http.MethodPost, "/networks/create", map[string]any{"Name": "appnet"}); code != http.StatusCreated {
		t.Fatalf("network create: %d", code)
	}
	if code, _ := c.do(http.MethodPost, "/volumes/create", map[string]any{"Name": "pgdata"}); code != http.StatusCreated {
		t.Fatalf("volume create: %d", code)
	}
	if labelsOf(engine.networks["appnet"])[guestproto.DockerGuardLabel] != "run-1" ||
		labelsOf(engine.volumes["pgdata"])[guestproto.DockerGuardLabel] != "run-1" {
		t.Fatal("network and volume must carry the turn's label")
	}
}

func TestCleanupDockerTurnRemovesOnlyThatTurnsObjects(t *testing.T) {
	engine := newFakeEngine()
	mine := newGuardClient(t, "run-1", engine)
	other := newGuardClient(t, "run-2", engine)
	_, a := mine.do(http.MethodPost, "/containers/create", map[string]any{"Image": "x"})
	_, b := other.do(http.MethodPost, "/containers/create", map[string]any{"Image": "x"})
	mine.do(http.MethodPost, "/networks/create", map[string]any{"Name": "n1"})
	mine.do(http.MethodPost, "/volumes/create", map[string]any{"Name": "v1"})
	// Started by the host on the raw socket (a run service): never the turn's.
	engine.containers["svc"] = map[string]any{"Image": "postgres"}

	if err := cleanupDockerTurn(context.Background(), engine, "run-1"); err != nil {
		t.Fatal(err)
	}
	if _, ok := engine.containers[a["Id"].(string)]; ok {
		t.Error("the turn's container survived cleanup")
	}
	if _, ok := engine.containers[b["Id"].(string)]; !ok {
		t.Error("cleanup removed another turn's container")
	}
	if _, ok := engine.containers["svc"]; !ok {
		t.Error("cleanup removed a service container")
	}
	if len(engine.networks) != 0 || len(engine.volumes) != 0 {
		t.Errorf("networks %v / volumes %v survived cleanup", engine.networks, engine.volumes)
	}
	if !engine.reached("DELETE /containers/" + a["Id"].(string) + "?force=1&v=1") {
		t.Error("containers must be removed with force and their anonymous volumes")
	}
}

func TestDockerGuardKeys(t *testing.T) {
	for _, ok := range []string{"0a1b2c3d-4e5f-6789-abcd-ef0123456789-3", "turn-1"} {
		if !guardKeyRe.MatchString(ok) {
			t.Errorf("%q should be a valid key", ok)
		}
	}
	for _, bad := range []string{"", "../raw", "a/b", ".hidden", strings.Repeat("a", 200)} {
		if guardKeyRe.MatchString(bad) {
			t.Errorf("%q should be refused as a key", bad)
		}
	}
}

// sandboxGuard is a guard whose bind roots are temp dirs: workspace and
// scratch, with scratch/mine owned by the test's user and scratch/root by
// "someone else" (the guard is told the turn runs as another uid there).
func sandboxGuard(t *testing.T, engine *fakeEngine) (*guardClient, string, string) {
	t.Helper()
	// Resolved, so expectations match on macOS too (/var -> /private/var).
	ws, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	scratch, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range []string{filepath.Join(ws, "src"), filepath.Join(scratch, "mine")} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// A symlink in the checkout must not lead a bind out of it.
	if err := os.Symlink("/etc", filepath.Join(ws, "etc-link")); err != nil {
		t.Fatal(err)
	}
	g := newDockerGuard("run-1", engine)
	g.binds = bindPolicy{workspace: ws, scratch: scratch, uid: os.Getuid()}
	srv := httptest.NewServer(g)
	t.Cleanup(srv.Close)
	return &guardClient{t: t, srv: srv}, ws, scratch
}

func TestDockerGuardRefusesEscapesFromTheVM(t *testing.T) {
	engine := newFakeEngine()
	c, ws, scratch := sandboxGuard(t, engine)
	otherUser := newDockerGuard("run-1", engine)
	otherUser.binds = bindPolicy{workspace: ws, scratch: scratch, uid: os.Getuid() + 1}

	for name, hc := range map[string]map[string]any{
		// The three my 2026-11-17 probe got past the old denylist:
		"local-driver bind volume": {"Mounts": []any{map[string]any{"Type": "volume", "Target": "/h",
			"VolumeOptions": map[string]any{"DriverConfig": map[string]any{"Name": "local",
				"Options": map[string]any{"type": "none", "o": "bind", "device": "/home/node"}}}}}},
		"seccomp unconfined":  {"SecurityOpt": []any{"seccomp=unconfined"}},
		"apparmor unconfined": {"SecurityOpt": []any{"apparmor=unconfined"}},
		"cgroupns host":       {"CgroupnsMode": "host"},

		"privileged":            {"Privileged": true},
		"host network":          {"NetworkMode": "host"},
		"another's network":     {"NetworkMode": "container:abc"},
		"service network":       {"NetworkMode": "lazyagents-svc-run-1"},
		"host pid":              {"PidMode": "host"},
		"cap add":               {"CapAdd": []any{"SYS_ADMIN"}},
		"devices":               {"Devices": []any{map[string]any{"PathOnHost": "/dev/vda"}}},
		"runtime":               {"Runtime": "runc-unsafe"},
		"cgroup parent":         {"CgroupParent": "/"},
		"volume driver":         {"VolumeDriver": "local"},
		"volumes from":          {"VolumesFrom": []any{"svc"}},
		"bind /etc":             {"Binds": []any{"/etc:/hostetc"}},
		"bind dotdot":           {"Binds": []any{ws + "/../../etc:/e"}},
		"bind via symlink":      {"Binds": []any{ws + "/etc-link:/e"}},
		"bind docker socket":    {"Binds": []any{"/var/run/docker.sock:/var/run/docker.sock"}},
		"bind all of scratch":   {"Binds": []any{scratch + ":/s"}},
		"unowned named volume":  {"Binds": []any{"pgdata:/var/lib/postgresql"}},
		"mount bind /":          {"Mounts": []any{map[string]any{"Type": "bind", "Source": "/", "Target": "/r"}}},
		"mount npipe":           {"Mounts": []any{map[string]any{"Type": "npipe", "Source": "x", "Target": "/r"}}},
		"mount unowned volume":  {"Mounts": []any{map[string]any{"Type": "volume", "Source": "pgdata", "Target": "/r"}}},
		"endpoint off the turn": nil, // checked below with NetworkingConfig
	} {
		if hc == nil {
			continue
		}
		code, out := c.do(http.MethodPost, "/containers/create", map[string]any{"Image": "alpine", "HostConfig": hc})
		if code != http.StatusForbidden {
			t.Errorf("%s: create answered %d %v, want 403", name, code, out)
		}
	}
	code, _ := c.do(http.MethodPost, "/containers/create", map[string]any{"Image": "alpine",
		"NetworkingConfig": map[string]any{"EndpointsConfig": map[string]any{"lazyagents-svc-run-1": map[string]any{}}}})
	if code != http.StatusForbidden {
		t.Errorf("endpoint on a network the turn didn't create: %d, want 403", code)
	}
	if len(engine.containers) != 0 {
		t.Fatalf("refused creates reached dockerd: %v", engine.containers)
	}

	// Under /tmp, only what the turn's user owns: root keeps the writable
	// layers of the /nix overlay there.
	srv := httptest.NewServer(otherUser)
	defer srv.Close()
	foreign := &guardClient{t: t, srv: srv}
	if code, out := foreign.do(http.MethodPost, "/containers/create", map[string]any{"Image": "alpine",
		"HostConfig": map[string]any{"Binds": []any{scratch + "/mine:/s"}}}); code != http.StatusForbidden {
		t.Errorf("bind of a /tmp path the turn doesn't own: %d %v, want 403", code, out)
	}

	// Volumes can't carry driver options either (the same local-driver bind).
	if code, _ := c.do(http.MethodPost, "/volumes/create", map[string]any{"Name": "v",
		"DriverOpts": map[string]any{"type": "none", "o": "bind", "device": "/"}}); code != http.StatusForbidden {
		t.Errorf("volume with driver options: %d, want 403", code)
	}
	if code, _ := c.do(http.MethodPost, "/networks/create", map[string]any{"Name": "n", "Driver": "macvlan"}); code != http.StatusForbidden {
		t.Errorf("non-bridge network: %d, want 403", code)
	}
}

func TestDockerGuardRebuildsAllowedCreates(t *testing.T) {
	engine := newFakeEngine()
	c, ws, scratch := sandboxGuard(t, engine)
	c.do(http.MethodPost, "/volumes/create", map[string]any{"Name": "pgdata"})
	c.do(http.MethodPost, "/networks/create", map[string]any{"Name": "appnet"})

	code, out := c.do(http.MethodPost, "/containers/create", map[string]any{
		"Image": "postgres",
		"HostConfig": map[string]any{
			"Binds":         []any{ws + "/src:/app:ro,rshared", scratch + "/mine:/scratch", "pgdata:/var/lib/postgresql"},
			"NetworkMode":   "appnet",
			"PortBindings":  map[string]any{"5432/tcp": []any{map[string]any{"HostPort": ""}}},
			"RestartPolicy": map[string]any{"Name": "always"},
			"LogConfig":     map[string]any{"Type": "syslog"},
		},
	})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	hc := asMap(engine.containers[out["Id"].(string)]["HostConfig"])
	mounts := asList(hc["Mounts"])
	if len(mounts) != 2 {
		t.Fatalf("path binds should become 2 mounts, got %v", hc)
	}
	app := asMap(mounts[0])
	if app["Source"] != ws+"/src" || app["Target"] != "/app" || app["ReadOnly"] != true || app["BindOptions"] != nil {
		t.Errorf("checkout bind = %v, want a read-only mount without propagation", app)
	}
	if binds := asList(hc["Binds"]); len(binds) != 1 || binds[0] != "pgdata:/var/lib/postgresql" {
		t.Errorf("owned volume bind = %v", hc["Binds"])
	}
	if hc["NetworkMode"] != "appnet" || hc["PortBindings"] == nil {
		t.Errorf("network/ports not kept: %v", hc)
	}
	if asMap(hc["RestartPolicy"])["Name"] != "no" || hc["LogConfig"] != nil {
		t.Errorf("restart/log config not rebuilt: %v", hc)
	}
	if opts := asList(hc["SecurityOpt"]); len(opts) != 1 || opts[0] != "no-new-privileges" {
		t.Errorf("SecurityOpt = %v, want no-new-privileges", hc["SecurityOpt"])
	}

	// A plain docker run with the old test's binds still works.
	if code, out := c.do(http.MethodPost, "/containers/create", map[string]any{"Image": "x",
		"HostConfig": map[string]any{"Binds": []any{ws + ":/ws"}}}); code != http.StatusCreated {
		t.Errorf("checkout bind: %d %v", code, out)
	}
}

func TestDockerGuardScopesCallsToTheTurnsObjects(t *testing.T) {
	engine := newFakeEngine()
	c := newGuardClient(t, "run-1", engine)
	other := newGuardClient(t, "run-2", engine)
	_, mine := c.do(http.MethodPost, "/containers/create", map[string]any{"Image": "x"})
	_, theirs := other.do(http.MethodPost, "/containers/create", map[string]any{"Image": "x"})
	engine.containers["svc"] = map[string]any{"Image": "postgres"} // a run service, started by the host
	id, theirID := mine["Id"].(string), theirs["Id"].(string)

	for _, target := range []string{theirID, "svc"} {
		if code, _ := c.do(http.MethodPost, "/containers/"+target+"/exec", map[string]any{"Cmd": []any{"sh"}}); code != http.StatusNotFound {
			t.Errorf("exec into %s: %d, want 404", target, code)
		}
		if code, _ := c.do(http.MethodDelete, "/containers/"+target, nil); code != http.StatusNotFound {
			t.Errorf("delete %s: %d, want 404", target, code)
		}
	}
	if code, _ := c.do(http.MethodPost, "/containers/"+id+"/exec", map[string]any{"Cmd": []any{"sh"}, "Privileged": true}); code != http.StatusForbidden {
		t.Errorf("privileged exec: %d, want 403", code)
	}
	code, ex := c.do(http.MethodPost, "/containers/"+id+"/exec", map[string]any{"Cmd": []any{"sh"}})
	if code != http.StatusCreated {
		t.Fatalf("exec in own container: %d", code)
	}
	if code, _ := c.do(http.MethodPost, "/exec/"+ex["Id"].(string)+"/start", map[string]any{}); code >= 300 {
		t.Errorf("start own exec: %d", code)
	}
	_, theirEx := other.do(http.MethodPost, "/containers/"+theirID+"/exec", map[string]any{"Cmd": []any{"sh"}})
	if code, _ := c.do(http.MethodPost, "/exec/"+theirEx["Id"].(string)+"/start", map[string]any{}); code != http.StatusNotFound {
		t.Errorf("start another turn's exec: %d, want 404", code)
	}
	if code, _ := c.do(http.MethodPost, "/containers/"+id+"/update", map[string]any{"Memory": 0}); code != http.StatusForbidden {
		t.Errorf("update: %d, want 403", code)
	}

	c.do(http.MethodGet, "/containers/json?all=1", nil)
	if !engine.reached("GET /containers/json?all=1&filters=") {
		t.Error("container listing must be filtered to the turn's label")
	}
}

func TestDockerGuardRefusesOtherEndpoints(t *testing.T) {
	engine := newFakeEngine()
	c := newGuardClient(t, "run-1", engine)
	for _, call := range []struct{ method, path string }{
		{http.MethodPost, "/session"},
		{http.MethodPost, "/grpc"},
		{http.MethodPost, "/build?version=2"},
		{http.MethodPost, "/build?networkmode=host"},
		{http.MethodGet, "/plugins"},
		{http.MethodPost, "/swarm/init"},
		{http.MethodPost, "/containers/prune"},
		{http.MethodPost, "/volumes/prune"},
		{http.MethodPost, "/images/postgres/tag?repo=x"},
		{http.MethodPost, "/images/create?fromSrc=http://example.com/rootfs.tar"},
		{http.MethodGet, "/events"},
	} {
		if code, out := c.do(call.method, call.path, nil); code < 400 {
			t.Errorf("%s %s answered %d %v, want refused", call.method, call.path, code, out)
		}
		if engine.reached(call.method + " " + strings.Split(call.path, "?")[0]) {
			t.Errorf("%s %s reached dockerd", call.method, call.path)
		}
	}
	for _, call := range []struct{ method, path string }{
		{http.MethodGet, "/_ping"}, {http.MethodHead, "/_ping"}, {http.MethodGet, "/version"},
		{http.MethodPost, "/images/create?fromImage=postgres&tag=17"},
		{http.MethodGet, "/images/postgres:17/json"},
	} {
		c.do(call.method, call.path, nil)
		if !engine.reached(call.method + " " + strings.Split(call.path, "?")[0]) {
			t.Errorf("%s %s wasn't forwarded", call.method, call.path)
		}
	}
}

func TestDockerGuardLabelsBuildsAndImports(t *testing.T) {
	engine := newFakeEngine()
	c := newGuardClient(t, "run-1", engine)
	if code, _ := c.do(http.MethodPost, "/build?t=app:dev", nil); code >= 400 {
		t.Fatalf("classic build refused: %d", code)
	}
	if !engine.reached("POST /build?labels=%7B%22dev.lazyagents.proxy%22%3A%22run-1%22%7D") {
		t.Errorf("build must carry the turn's label; engine saw %v", engine.seen)
	}
	if code, _ := c.do(http.MethodPost, "/images/create?fromSrc=-&repo=tiny&tag=test", nil); code >= 400 {
		t.Fatalf("docker import refused: %d", code)
	}
	if !engine.reached("POST /images/create?changes=LABEL+dev.lazyagents.proxy%3Drun-1") {
		t.Errorf("import must carry the turn's label; engine saw %v", engine.seen)
	}

	// The host pulled this for the run's services: a turn can't put its own
	// image under that name for the next turn's services to run.
	engine.images["postgres:17-alpine"] = map[string]any{"RepoDigests": []any{"postgres@sha256:abc"}}
	for _, p := range []string{"/images/create?fromSrc=-&repo=postgres&tag=17-alpine", "/build?t=postgres:17-alpine"} {
		if code, _ := c.do(http.MethodPost, p, nil); code != http.StatusForbidden {
			t.Errorf("POST %s over a service image: %d, want 403", p, code)
		}
	}
	if code, _ := c.do(http.MethodDelete, "/images/postgres:17-alpine", nil); code != http.StatusForbidden {
		t.Errorf("removing a service image: %d, want 403", code)
	}
	// Re-pulling it from the registry is fine.
	if code, _ := c.do(http.MethodPost, "/images/create?fromImage=postgres&tag=17-alpine", nil); code >= 400 {
		t.Errorf("re-pull of a registry image: %d", code)
	}
}

func (c *guardClient) doRaw(method, path, rawBody string) (int, map[string]any) {
	c.t.Helper()
	req, err := http.NewRequest(method, c.srv.URL+"/v1.47"+path, strings.NewReader(rawBody))
	if err != nil {
		c.t.Fatal(err)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

func TestDockerGuardBlocksCaseInsensitiveJSONSmuggling(t *testing.T) {
	engine := newFakeEngine()
	c, _, _ := sandboxGuard(t, engine)
	_, mine := c.do(http.MethodPost, "/containers/create", map[string]any{"Image": "alpine"})
	myID := mine["Id"].(string)
	c.do(http.MethodPost, "/networks/create", map[string]any{"Name": "appnet"})
	engine.containers["svc"] = map[string]any{"Image": "postgres"}

	// Duplicate keys differing only in case must be rejected with 400.
	for name, raw := range map[string]string{
		"dup HostConfig/hostconfig": `{"Image":"alpine","HostConfig":{},"hostconfig":{"Privileged":true}}`,
		"dup Labels/labels":         `{"Image":"alpine","Labels":{"a":"1"},"labels":{"b":"2"}}`,
		"dup nested Privileged":     `{"Image":"alpine","HostConfig":{"Privileged":false,"privileged":true}}`,
	} {
		if code, out := c.doRaw(http.MethodPost, "/containers/create", raw); code != http.StatusBadRequest {
			t.Errorf("%s: got %d %v, want 400", name, code, out)
		}
	}

	// Single differently-cased keys must still be enforced (403), never smuggled past the guard.
	for name, raw := range map[string]string{
		"lowercase hostconfig privileged": `{"Image":"alpine","hostconfig":{"privileged":true}}`,
		"lowercase hostconfig binds":      `{"Image":"alpine","hostconfig":{"binds":["/:/host"]}}`,
		"lowercase networkingconfig":      `{"Image":"alpine","networkingconfig":{"endpointsconfig":{"lazyagents-svc-run-1":{}}}}`,
		"lowercase mount volumeoptions":   `{"Image":"alpine","hostconfig":{"mounts":[{"type":"volume","target":"/h","volumeoptions":{"driverconfig":{"name":"local","options":{"type":"none","o":"bind","device":"/"}}}}]}}`,
	} {
		if code, out := c.doRaw(http.MethodPost, "/containers/create", raw); code != http.StatusForbidden {
			t.Errorf("%s: got %d %v, want 403", name, code, out)
		}
	}

	// Lowercase exec privileged, network connect container, and volume driveropts.
	if code, out := c.doRaw(http.MethodPost, "/containers/"+myID+"/exec", `{"Cmd":["sh"],"privileged":true}`); code != http.StatusForbidden {
		t.Errorf("lowercase exec privileged: got %d %v, want 403", code, out)
	}
	if code, out := c.doRaw(http.MethodPost, "/networks/appnet/connect", `{"container":"svc"}`); code != http.StatusNotFound {
		t.Errorf("lowercase network connect to unowned container: got %d %v, want 404", code, out)
	}
	if code, out := c.doRaw(http.MethodPost, "/volumes/create", `{"Name":"v","driveropts":{"type":"none","o":"bind","device":"/"}}`); code != http.StatusForbidden {
		t.Errorf("lowercase volume driveropts: got %d %v, want 403", code, out)
	}

	// Unknown top-level keys must never be copied into the forwarded request.
	code, created := c.doRaw(http.MethodPost, "/containers/create", `{"Image":"alpine","UnknownTopLevel":{"Privileged":true}}`)
	if code != http.StatusCreated {
		t.Fatalf("create with benign unknown key: %d %v", code, created)
	}
	if _, leaked := engine.containers[created["Id"].(string)]["UnknownTopLevel"]; leaked {
		t.Fatalf("unknown top-level key was forwarded to dockerd: %v", engine.containers[created["Id"].(string)])
	}
}

func TestDockerGuardRejectsDuplicateQueryParamsAndUnsafeHostConfig(t *testing.T) {
	engine := newFakeEngine()
	c, _, _ := sandboxGuard(t, engine)

	for _, p := range []string{
		"/build?networkmode=bridge&networkmode=host",
		"/build?version=1&version=2",
		"/images/create?fromSrc=-&fromSrc=http://evil.example/a.tar",
		"/containers/json?filters=%7B%7D&filters=%7B%7D",
	} {
		if code, out := c.do(http.MethodPost, p, nil); strings.HasPrefix(p, "/containers/json") {
			if code, out = c.do(http.MethodGet, p, nil); code != http.StatusBadRequest {
				t.Errorf("GET %s: got %d %v, want 400", p, code, out)
			}
		} else if code != http.StatusBadRequest {
			t.Errorf("POST %s: got %d %v, want 400", p, code, out)
		}
	}

	// Negative OomScoreAdj and non-allowlisted Sysctls must be refused.
	for name, hc := range map[string]map[string]any{
		"negative OomScoreAdj": {"OomScoreAdj": -500},
		"huge OomScoreAdj":     {"OomScoreAdj": 2000},
		"unsafe sysctl":        {"Sysctls": map[string]any{"kernel.core_pattern": "|/bin/sh"}},
	} {
		if code, out := c.do(http.MethodPost, "/containers/create", map[string]any{"Image": "alpine", "HostConfig": hc}); code != http.StatusForbidden {
			t.Errorf("%s: got %d %v, want 403", name, code, out)
		}
	}

	// Safe OomScoreAdj and allowlisted Sysctl succeed.
	if code, out := c.do(http.MethodPost, "/containers/create", map[string]any{
		"Image": "alpine",
		"HostConfig": map[string]any{
			"OomScoreAdj": 200,
			"Sysctls":     map[string]any{"net.core.somaxconn": "1024"},
		},
	}); code != http.StatusCreated {
		t.Fatalf("safe OomScoreAdj + Sysctl: got %d %v, want 201", code, out)
	}
}

func TestDockerGuardPinsBindMountsViaFD(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("openat2/fd bind pinning is Linux-only")
	}
	engine := newFakeEngine()
	ws, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	srcDir := filepath.Join(ws, "app")
	if err := os.MkdirAll(srcDir, 0o755); err != nil {
		t.Fatal(err)
	}
	g := newDockerGuard("run-pin", engine)
	g.binds = bindPolicy{workspace: ws, scratch: t.TempDir(), uid: os.Getuid()}
	var pinnedCalls int
	g.pinBindFD = func(fd int, isDir bool) (string, error) {
		pinnedCalls++
		if fd < 0 || !isDir {
			return "", fmt.Errorf("unexpected fd=%d isDir=%v", fd, isDir)
		}
		return "/run/vesper-binds/run-pin/1", nil
	}
	srv := httptest.NewServer(g)
	defer srv.Close()
	c := &guardClient{t: t, srv: srv}

	code, out := c.do(http.MethodPost, "/containers/create", map[string]any{
		"Image":      "alpine",
		"HostConfig": map[string]any{"Binds": []any{srcDir + ":/work:ro"}},
	})
	if code != http.StatusCreated {
		t.Fatalf("create with pinned bind: %d %v", code, out)
	}
	if pinnedCalls != 1 {
		t.Fatalf("pinBindFD calls = %d, want 1", pinnedCalls)
	}
	hc := asMap(engine.containers[out["Id"].(string)]["HostConfig"])
	mounts := asList(hc["Mounts"])
	if len(mounts) != 1 || asMap(mounts[0])["Source"] != "/run/vesper-binds/run-pin/1" {
		t.Fatalf("expected pinned mount source, got %v", mounts)
	}
}

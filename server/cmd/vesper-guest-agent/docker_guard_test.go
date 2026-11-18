package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
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
	seen       []string                  // "METHOD path?query" that reached the engine
}

func newFakeEngine() *fakeEngine {
	return &fakeEngine{
		containers: map[string]map[string]any{},
		networks:   map[string]map[string]any{},
		volumes:    map[string]map[string]any{},
		execs:      map[string]string{},
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

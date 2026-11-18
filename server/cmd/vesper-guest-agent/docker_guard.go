package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"regexp"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

// maxGuardBody bounds a request body the guard reads to inspect.
const maxGuardBody = 4 << 20

// guardKeyRe is what a turn key may look like: it names the guard's socket.
var guardKeyRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// dockerGuard is one turn's Docker API. It forwards to the in-guest dockerd
// and stamps everything the turn creates with the turn's key, so closing the
// turn removes it: containers run outside the turn's cgroup and would
// otherwise outlive it, watching the next turn's files.
type dockerGuard struct {
	key    string
	engine http.RoundTripper
	fwd    *httputil.ReverseProxy
}

func newDockerGuard(key string, engine http.RoundTripper) *dockerGuard {
	return &dockerGuard{
		key:    key,
		engine: engine,
		fwd: &httputil.ReverseProxy{
			Rewrite: func(pr *httputil.ProxyRequest) {
				pr.Out.URL.Scheme, pr.Out.URL.Host = "http", "docker"
				pr.Out.Host = "docker"
			},
			Transport:     engine,
			FlushInterval: -1, // logs, pulls and attaches stream
		},
	}
}

var apiVersionRe = regexp.MustCompile(`^/v[0-9]+(\.[0-9]+)?`)

func (g *dockerGuard) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := apiVersionRe.ReplaceAllString(r.URL.Path, "")
	if r.Method == http.MethodPost {
		switch p {
		case "/containers/create":
			g.createContainer(w, r)
			return
		case "/networks/create", "/volumes/create":
			g.createLabelled(w, r)
			return
		case "/build":
			g.build(w, r)
			return
		}
	}
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) createContainer(w http.ResponseWriter, r *http.Request) {
	raw, ok := readGuardBody(w, r)
	if !ok {
		return
	}
	if reason := validateDockerContainerCreate(raw); reason != "" {
		guardError(w, http.StatusForbidden, "%s", strings.TrimPrefix(reason, "vesper guard: "))
		return
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		guardError(w, http.StatusBadRequest, "request body: %v", err)
		return
	}
	body["Labels"] = g.labels(body["Labels"])
	setGuardBody(r, body)
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) createLabelled(w http.ResponseWriter, r *http.Request) {
	raw, ok := readGuardBody(w, r)
	if !ok {
		return
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		guardError(w, http.StatusBadRequest, "request body: %v", err)
		return
	}
	body["Labels"] = g.labels(body["Labels"])
	setGuardBody(r, body)
	g.fwd.ServeHTTP(w, r)
}

// build labels the image and the build's intermediate containers.
func (g *dockerGuard) build(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	var own map[string]any
	if raw := q.Get("labels"); raw != "" {
		_ = json.Unmarshal([]byte(raw), &own)
	}
	b, _ := json.Marshal(g.labels(own))
	q.Set("labels", string(b))
	r.URL.RawQuery = q.Encode()
	g.fwd.ServeHTTP(w, r)
}

// labels adds the turn's label to the caller's own.
func (g *dockerGuard) labels(own any) map[string]any {
	out := map[string]any{}
	if m, ok := own.(map[string]any); ok {
		for k, v := range m {
			out[k] = v
		}
	}
	out[guestproto.DockerGuardLabel] = g.key
	return out
}

// cleanupDockerTurn removes what a turn created: containers (with their
// anonymous volumes), then the networks and volumes they used.
func cleanupDockerTurn(ctx context.Context, engine http.RoundTripper, key string) error {
	hc := &http.Client{Transport: engine}
	filters, _ := json.Marshal(map[string][]string{"label": {guestproto.DockerGuardLabel + "=" + key}})
	q := "filters=" + url.QueryEscape(string(filters))
	var errs []string
	call := func(method, p string, out any) {
		req, err := http.NewRequestWithContext(ctx, method, "http://docker"+p, nil)
		if err != nil {
			errs = append(errs, err.Error())
			return
		}
		res, err := hc.Do(req)
		if err != nil {
			errs = append(errs, err.Error())
			return
		}
		defer res.Body.Close()
		b, _ := io.ReadAll(io.LimitReader(res.Body, maxGuardBody))
		if res.StatusCode >= 300 && res.StatusCode != http.StatusNotFound {
			errs = append(errs, fmt.Sprintf("%s %s: %d %s", method, p, res.StatusCode, strings.TrimSpace(string(b))))
			return
		}
		if out != nil {
			_ = json.Unmarshal(b, out)
		}
	}
	var containers []struct{ ID string }
	call(http.MethodGet, "/containers/json?all=1&"+q, &containers)
	for _, c := range containers {
		call(http.MethodDelete, "/containers/"+url.PathEscape(c.ID)+"?force=1&v=1", nil)
	}
	var networks []struct{ ID string }
	call(http.MethodGet, "/networks?"+q, &networks)
	for _, n := range networks {
		call(http.MethodDelete, "/networks/"+url.PathEscape(n.ID), nil)
	}
	var volumes struct{ Volumes []struct{ Name string } }
	call(http.MethodGet, "/volumes?"+q, &volumes)
	for _, v := range volumes.Volumes {
		call(http.MethodDelete, "/volumes/"+url.PathEscape(v.Name)+"?force=1", nil)
	}
	if len(errs) > 0 {
		return fmt.Errorf("clean up turn %s: %s", key, strings.Join(errs, "; "))
	}
	return nil
}

// guardError answers the way the Engine does, so clients show the message.
func guardError(w http.ResponseWriter, code int, format string, args ...any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "vesper guard: " + fmt.Sprintf(format, args...)})
}

func readGuardBody(w http.ResponseWriter, r *http.Request) ([]byte, bool) {
	b, err := io.ReadAll(io.LimitReader(r.Body, maxGuardBody+1))
	if err != nil {
		guardError(w, http.StatusBadRequest, "read request: %v", err)
		return nil, false
	}
	if len(b) > maxGuardBody {
		guardError(w, http.StatusRequestEntityTooLarge, "request body over %d bytes", maxGuardBody)
		return nil, false
	}
	if len(bytes.TrimSpace(b)) == 0 {
		b = []byte("{}")
	}
	return b, true
}

func setGuardBody(r *http.Request, v any) {
	b, _ := json.Marshal(v)
	r.Body = io.NopCloser(bytes.NewReader(b))
	r.ContentLength = int64(len(b))
	r.Header.Set("Content-Length", fmt.Sprint(len(b)))
	r.Header.Set("Content-Type", "application/json")
}

// validateDockerContainerCreate rejects host escapes and bind mounts outside
// /workspace and /tmp so in-guest dockerd cannot alter host or rootfs state.
func validateDockerContainerCreate(body []byte) string {
	var spec struct {
		HostConfig struct {
			Privileged  bool     `json:"Privileged"`
			NetworkMode string   `json:"NetworkMode"`
			PidMode     string   `json:"PidMode"`
			IpcMode     string   `json:"IpcMode"`
			UTSMode     string   `json:"UTSMode"`
			UsernsMode  string   `json:"UsernsMode"`
			CapAdd      []string `json:"CapAdd"`
			Devices     []any    `json:"Devices"`
			Binds       []string `json:"Binds"`
			Mounts      []struct {
				Type   string `json:"Type"`
				Source string `json:"Source"`
			} `json:"Mounts"`
		} `json:"HostConfig"`
	}
	if err := json.Unmarshal(body, &spec); err != nil {
		return ""
	}
	hc := spec.HostConfig
	if hc.Privileged {
		return "vesper guard: privileged containers are disabled"
	}
	for name, mode := range map[string]string{
		"NetworkMode": hc.NetworkMode,
		"PidMode":     hc.PidMode,
		"IpcMode":     hc.IpcMode,
		"UTSMode":     hc.UTSMode,
		"UsernsMode":  hc.UsernsMode,
	} {
		if strings.EqualFold(strings.TrimSpace(mode), "host") {
			return fmt.Sprintf("vesper guard: %s=host is disabled", name)
		}
	}
	if len(hc.CapAdd) > 0 {
		return "vesper guard: adding Linux capabilities is disabled"
	}
	if len(hc.Devices) > 0 {
		return "vesper guard: device passthrough is disabled"
	}
	for _, b := range hc.Binds {
		src, _, hasColon := strings.Cut(b, ":")
		if !hasColon {
			continue
		}
		if strings.HasPrefix(src, "/") && !allowedBindSource(src) {
			return fmt.Sprintf("vesper guard: bind mount %q outside /workspace and /tmp is denied", src)
		}
	}
	for _, m := range hc.Mounts {
		if (strings.EqualFold(m.Type, "bind") || strings.HasPrefix(m.Source, "/")) && !allowedBindSource(m.Source) {
			return fmt.Sprintf("vesper guard: bind mount %q outside /workspace and /tmp is denied", m.Source)
		}
	}
	return ""
}

func allowedBindSource(src string) bool {
	if !strings.HasPrefix(src, "/") {
		return false
	}
	clean := path.Clean(src)
	return clean == "/workspace" || strings.HasPrefix(clean, "/workspace/") ||
		clean == "/tmp" || strings.HasPrefix(clean, "/tmp/") ||
		clean == "/var/run/docker.sock"
}

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"syscall"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

const (
	// maxGuardBody bounds a request body the guard reads to inspect.
	maxGuardBody = 4 << 20
	// maxTurnContainers bounds how many containers one turn may have.
	maxTurnContainers = 20
	// turnUID is the user turns run as.
	turnUID = 1000
)

// guardKeyRe is what a turn key may look like: it names the guard's socket.
var guardKeyRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)

// bindPolicy says which guest paths a turn's containers may bind-mount.
type bindPolicy struct {
	// workspace may be bound anywhere inside: it is the turn's own checkout.
	workspace string
	// scratch (/tmp) may be bound below, but only paths the turn's user
	// owns: root keeps things there, such as the writable layers of the
	// /nix and cache overlays.
	scratch string
	uid     int
}

// dockerGuard is one turn's Docker API, modelled on the Docker backend's
// turn proxy (internal/runner/docker_proxy.go). It forwards an allowlist of
// Engine calls to the in-guest dockerd, rebuilds every container create into
// a sandbox (no privileges, host namespaces, devices or mounts beyond the
// turn's own paths and volumes), lets the turn touch only objects it created,
// and stamps those with the turn's key so closing the turn removes them:
// containers run outside the turn's cgroup and would otherwise outlive it,
// watching the next turn's files.
//
// What it protects is the VM itself: turns run as uid 1000, and root inside
// the VM would let a turn tamper with what later turns in the same run see.
type dockerGuard struct {
	key    string
	engine http.RoundTripper
	binds  bindPolicy
	fwd    *httputil.ReverseProxy
	// created serializes container creation so the per-turn cap holds.
	created sync.Mutex
}

func newDockerGuard(key string, engine http.RoundTripper) *dockerGuard {
	return &dockerGuard{
		key:    key,
		engine: engine,
		binds:  bindPolicy{workspace: "/workspace", scratch: "/tmp", uid: turnUID},
		fwd: &httputil.ReverseProxy{
			Rewrite: func(pr *httputil.ProxyRequest) {
				pr.Out.URL.Scheme, pr.Out.URL.Host = "http", "docker"
				pr.Out.Host = "docker"
			},
			Transport:     engine,
			FlushInterval: -1, // logs, pulls and attaches stream
			ModifyResponse: func(res *http.Response) error {
				// Clients pick BuildKit when the daemon offers it; the guard
				// only accepts classic builds (see build).
				if res.Header.Get("Builder-Version") != "" {
					res.Header.Set("Builder-Version", "1")
				}
				return nil
			},
		},
	}
}

var apiVersionRe = regexp.MustCompile(`^/v[0-9]+(\.[0-9]+)?`)

func (g *dockerGuard) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := apiVersionRe.ReplaceAllString(r.URL.Path, "")
	parts := strings.Split(strings.Trim(p, "/"), "/")
	get := r.Method == http.MethodGet || r.Method == http.MethodHead
	post := r.Method == http.MethodPost
	switch {
	case get && slices.Contains([]string{"/_ping", "/version", "/info", "/images/json"}, p):
		g.fwd.ServeHTTP(w, r)
	case post && p == "/images/create":
		g.createImage(w, r)
	case post && p == "/auth":
		g.fwd.ServeHTTP(w, r)
	case post && p == "/build":
		g.build(w, r)
	case r.Method == http.MethodDelete && len(parts) >= 2 && parts[0] == "images":
		g.removeImage(w, r, strings.Join(parts[1:], "/")) // names may contain slashes
	case get && len(parts) >= 3 && parts[0] == "images" && (parts[len(parts)-1] == "json" || parts[len(parts)-1] == "history"):
		g.fwd.ServeHTTP(w, r)
	case get && len(parts) >= 3 && parts[0] == "distribution" && parts[len(parts)-1] == "json":
		g.fwd.ServeHTTP(w, r)

	case post && p == "/containers/create":
		g.createContainer(w, r)
	case get && p == "/containers/json":
		g.forwardFiltered(w, r)
	case len(parts) >= 2 && parts[0] == "containers":
		g.container(w, r, parts[1], strings.Join(parts[2:], "/"))
	case len(parts) == 3 && parts[0] == "exec":
		g.exec(w, r, parts[1], parts[2])

	case post && p == "/networks/create":
		g.createNetwork(w, r)
	case get && p == "/networks":
		g.forwardFiltered(w, r)
	case len(parts) >= 2 && parts[0] == "networks":
		g.network(w, r, parts[1], strings.Join(parts[2:], "/"))

	case post && p == "/volumes/create":
		g.createVolume(w, r)
	case get && p == "/volumes":
		g.forwardFiltered(w, r)
	case len(parts) == 2 && parts[0] == "volumes" && (get || r.Method == http.MethodDelete):
		if !g.ownsVolume(r.Context(), parts[1]) {
			guardError(w, http.StatusNotFound, "no such volume in this turn: %s", parts[1])
			return
		}
		g.fwd.ServeHTTP(w, r)

	default:
		guardError(w, http.StatusForbidden, "%s %s isn't available to agents (BuildKit sessions, swarm, plugins and system calls reach past the turn)", r.Method, p)
	}
}

// engineDo makes one Engine call of the guard's own.
func (g *dockerGuard) engineDo(ctx context.Context, method, p string, out any) (int, error) {
	req, err := http.NewRequestWithContext(ctx, method, "http://docker"+p, nil)
	if err != nil {
		return 0, err
	}
	res, err := (&http.Client{Transport: g.engine}).Do(req)
	if err != nil {
		return 0, err
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(res.Body, maxGuardBody))
	if res.StatusCode >= 300 {
		return res.StatusCode, fmt.Errorf("%s %s: %d %s", method, p, res.StatusCode, strings.TrimSpace(string(b)))
	}
	if out != nil {
		if err := json.Unmarshal(b, out); err != nil {
			return res.StatusCode, err
		}
	}
	return res.StatusCode, nil
}

func (g *dockerGuard) filter() string { return guestproto.DockerGuardLabel + "=" + g.key }

// forwardFiltered lists only what this turn created.
func (g *dockerGuard) forwardFiltered(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filters, err := withLabel(q.Get("filters"), g.filter())
	if err != nil {
		guardError(w, http.StatusBadRequest, "filters: %v", err)
		return
	}
	q.Set("filters", filters)
	r.URL.RawQuery = q.Encode()
	g.fwd.ServeHTTP(w, r)
}

// withLabel adds a label filter to an Engine filters argument, in either of
// the two shapes clients send.
func withLabel(raw, label string) (string, error) {
	filters := map[string][]string{}
	if raw != "" {
		if err := json.Unmarshal([]byte(raw), &filters); err != nil {
			legacy := map[string]map[string]bool{}
			if json.Unmarshal([]byte(raw), &legacy) != nil {
				return "", err
			}
			for k, set := range legacy {
				for v, on := range set {
					if on {
						filters[k] = append(filters[k], v)
					}
				}
			}
		}
	}
	filters["label"] = append(filters["label"], label)
	b, _ := json.Marshal(filters)
	return string(b), nil
}

// owns reports whether the object at p carries this turn's label; labels
// picks the label map out of the inspect response.
func (g *dockerGuard) owns(ctx context.Context, p string, labels func(map[string]any) map[string]any) bool {
	var info map[string]any
	if _, err := g.engineDo(ctx, http.MethodGet, p, &info); err != nil {
		return false
	}
	v, _ := labels(info)[guestproto.DockerGuardLabel].(string)
	return v == g.key
}

func (g *dockerGuard) ownsContainer(ctx context.Context, id string) bool {
	return id != "" && g.owns(ctx, "/containers/"+url.PathEscape(id)+"/json", func(c map[string]any) map[string]any {
		return asMap(asMap(c["Config"])["Labels"])
	})
}

func (g *dockerGuard) ownsNetwork(ctx context.Context, id string) bool {
	return id != "" && g.owns(ctx, "/networks/"+url.PathEscape(id), func(n map[string]any) map[string]any { return asMap(n["Labels"]) })
}

func (g *dockerGuard) ownsVolume(ctx context.Context, name string) bool {
	return name != "" && g.owns(ctx, "/volumes/"+url.PathEscape(name), func(v map[string]any) map[string]any { return asMap(v["Labels"]) })
}

// containerActions are the calls a turn may make on its own containers.
// update is missing on purpose: it would change what create allowed.
var containerActions = map[string][]string{
	"json": {"GET"}, "top": {"GET"}, "logs": {"GET"}, "stats": {"GET"}, "changes": {"GET"},
	"start": {"POST"}, "stop": {"POST"}, "restart": {"POST"}, "kill": {"POST"}, "wait": {"POST"},
	"pause": {"POST"}, "unpause": {"POST"}, "resize": {"POST"}, "attach": {"POST"}, "rename": {"POST"},
	"exec": {"POST"}, "archive": {"GET", "HEAD", "PUT"}, "": {"DELETE"},
}

func (g *dockerGuard) container(w http.ResponseWriter, r *http.Request, id, action string) {
	if !slices.Contains(containerActions[action], r.Method) {
		guardError(w, http.StatusForbidden, "%s on a container isn't available to agents", strings.TrimSpace(r.Method+" "+action))
		return
	}
	if !g.ownsContainer(r.Context(), id) {
		guardError(w, http.StatusNotFound, "no such container in this turn: %s", id)
		return
	}
	if action == "exec" {
		var body map[string]any
		if !readGuardJSON(w, r, &body) {
			return
		}
		if on, _ := body["Privileged"].(bool); on {
			guardError(w, http.StatusForbidden, "privileged exec isn't allowed")
			return
		}
		setGuardBody(r, body)
	}
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) exec(w http.ResponseWriter, r *http.Request, id, action string) {
	allowed := (action == "json" && r.Method == http.MethodGet) || (r.Method == http.MethodPost && (action == "start" || action == "resize"))
	if !allowed {
		guardError(w, http.StatusForbidden, "%s %s on an exec isn't available to agents", r.Method, action)
		return
	}
	var info struct{ ContainerID string }
	if _, err := g.engineDo(r.Context(), http.MethodGet, "/exec/"+url.PathEscape(id)+"/json", &info); err != nil || !g.ownsContainer(r.Context(), info.ContainerID) {
		guardError(w, http.StatusNotFound, "no such exec in this turn: %s", id)
		return
	}
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) createContainer(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if !readGuardJSON(w, r, &body) {
		return
	}
	g.created.Lock()
	defer g.created.Unlock()
	ctx := r.Context()
	filters, _ := json.Marshal(map[string][]string{"label": {g.filter()}})
	var existing []struct{ ID string }
	if _, err := g.engineDo(ctx, http.MethodGet, "/containers/json?all=1&filters="+url.QueryEscape(string(filters)), &existing); err != nil {
		guardError(w, http.StatusBadGateway, "count this turn's containers: %v", err)
		return
	}
	if len(existing) >= maxTurnContainers {
		guardError(w, http.StatusTooManyRequests, "a turn may have at most %d containers; remove some first", maxTurnContainers)
		return
	}
	sandboxed, err := g.sandbox(body, func(name string) bool { return g.ownsVolume(ctx, name) }, func(name string) bool { return g.ownsNetwork(ctx, name) })
	if err != nil {
		guardError(w, http.StatusForbidden, "%v", err)
		return
	}
	setGuardBody(r, sandboxed)
	g.fwd.ServeHTTP(w, r)
}

// sandbox rebuilds a container create request from fields that only shape
// the container. Anything that would reach past it is refused with a reason
// rather than dropped, so a test fails with a message instead of oddly.
func (g *dockerGuard) sandbox(body map[string]any, ownVolume, ownNetwork func(string) bool) (map[string]any, error) {
	in := asMap(body["HostConfig"])
	refuse := func(field, why string) error { return fmt.Errorf("HostConfig.%s isn't allowed: %s", field, why) }
	if on, _ := in["Privileged"].(bool); on {
		return nil, refuse("Privileged", "a privileged container controls the VM")
	}
	for _, field := range []string{"CapAdd", "Devices", "DeviceRequests", "DeviceCgroupRules", "VolumesFrom", "Links"} {
		if list, _ := in[field].([]any); len(list) > 0 {
			return nil, refuse(field, "it reaches past the container")
		}
	}
	for _, field := range []string{"CgroupParent", "Runtime", "Cgroup", "VolumeDriver"} {
		if s, _ := in[field].(string); s != "" {
			return nil, refuse(field, "it changes how the VM runs the container")
		}
	}
	for _, field := range []string{"PidMode", "IpcMode", "UTSMode", "UsernsMode", "CgroupnsMode"} {
		if s, _ := in[field].(string); s == "host" || strings.HasPrefix(s, "container:") {
			return nil, refuse(field, "it shares another namespace")
		}
	}
	for _, opt := range asList(in["SecurityOpt"]) {
		if s, _ := opt.(string); s != "no-new-privileges" && s != "no-new-privileges:true" {
			return nil, refuse("SecurityOpt", "only no-new-privileges is accepted")
		}
	}

	host := map[string]any{}
	for _, field := range []string{"Tmpfs", "ShmSize", "Init", "AutoRemove", "Ulimits", "ExtraHosts", "ReadonlyRootfs",
		"Dns", "DnsOptions", "DnsSearch", "Sysctls", "NanoCpus", "CpuShares", "CpuQuota", "CpuPeriod", "OomScoreAdj",
		"Memory", "MemoryReservation", "PidsLimit", "CapDrop", "PortBindings", "PublishAllPorts"} {
		if v, ok := in[field]; ok && v != nil {
			host[field] = v
		}
	}
	host["SecurityOpt"] = []string{"no-new-privileges"}
	restart := asMap(in["RestartPolicy"])
	if name, _ := restart["Name"].(string); name == "on-failure" {
		host["RestartPolicy"] = restart
	} else {
		host["RestartPolicy"] = map[string]any{"Name": "no"}
	}

	var binds []string
	var mounts []any
	for _, b := range asList(in["Binds"]) {
		spec, _ := b.(string)
		parts := strings.Split(spec, ":")
		src := parts[0]
		if strings.HasPrefix(src, "/") && len(parts) >= 2 {
			// A path bind becomes a mount, which drops propagation and other
			// options the short form can carry.
			real, err := g.bindSource(src)
			if err != nil {
				return nil, refuse("Binds", fmt.Sprintf("%q: %v", spec, err))
			}
			readOnly := len(parts) > 2 && slices.Contains(strings.Split(parts[2], ","), "ro")
			mounts = append(mounts, map[string]any{"Type": "bind", "Source": real, "Target": parts[1], "ReadOnly": readOnly})
			continue
		}
		if src == "" || strings.HasPrefix(src, ".") || !ownVolume(src) {
			return nil, refuse("Binds", fmt.Sprintf("%q: only paths in the checkout (under /workspace), your own files under /tmp and volumes this turn created can be mounted", spec))
		}
		binds = append(binds, spec)
	}
	if len(binds) > 0 {
		host["Binds"] = binds
	}
	for _, m := range asList(in["Mounts"]) {
		mount := asMap(m)
		switch t, _ := mount["Type"].(string); t {
		case "tmpfs":
		case "volume":
			src, _ := mount["Source"].(string)
			if src != "" && !ownVolume(src) {
				return nil, refuse("Mounts", fmt.Sprintf("volume %q wasn't created by this turn", src))
			}
			// The local driver's options are a mount(2) call: type=none,o=bind
			// binds any path.
			if opts := asMap(mount["VolumeOptions"]); len(asMap(opts["DriverConfig"])) > 0 {
				return nil, refuse("Mounts", "volume driver options can mount any path")
			}
		case "bind":
			src, _ := mount["Source"].(string)
			dst, _ := mount["Target"].(string)
			ro, _ := mount["ReadOnly"].(bool)
			real, err := g.bindSource(src)
			if err != nil {
				return nil, refuse("Mounts", fmt.Sprintf("bind %q: %v", src, err))
			}
			mount = map[string]any{"Type": "bind", "Source": real, "Target": dst, "ReadOnly": ro}
		default:
			return nil, refuse("Mounts", fmt.Sprintf("%q mounts reach past the container; use a volume, a tmpfs or a bind from the checkout", t))
		}
		mounts = append(mounts, mount)
	}
	if len(mounts) > 0 {
		host["Mounts"] = mounts
	}

	// Networking: the VM's default bridge, none, or a network this turn
	// created; never the VM's own, another container's, or the run's services'.
	network, _ := in["NetworkMode"].(string)
	switch {
	case network == "" || network == "default" || network == "bridge" || network == "none":
	case network == "host" || strings.HasPrefix(network, "container:"):
		return nil, refuse("NetworkMode", "it shares the VM's or another container's network")
	case ownNetwork(network):
	default:
		return nil, refuse("NetworkMode", fmt.Sprintf("network %q wasn't created by this turn", network))
	}
	if network != "" {
		host["NetworkMode"] = network
	}

	out := map[string]any{}
	for k, v := range body {
		out[k] = v
	}
	if nc := asMap(body["NetworkingConfig"]); nc != nil {
		endpoints := map[string]any{}
		for name, cfg := range asMap(nc["EndpointsConfig"]) {
			switch {
			case name == "" || name == "default" || name == "bridge" || name == network || ownNetwork(name):
			default:
				return nil, refuse("NetworkingConfig", fmt.Sprintf("network %q wasn't created by this turn", name))
			}
			endpoints[name] = cfg
		}
		out["NetworkingConfig"] = map[string]any{"EndpointsConfig": endpoints}
	}
	out["HostConfig"] = host
	out["Labels"] = g.labels(body["Labels"])
	return out, nil
}

// bindSource resolves a bind's source and keeps it inside the checkout, or
// inside /tmp and owned by the turn's user. dockerd follows symlinks when it
// mounts, so the resolved path is what it is given.
//
// Known gap: a turn that swaps a directory it owns for a symlink between
// this check and dockerd's mount still gets the symlink's target mounted.
// Closing it means handing dockerd a path the turn can't change (an
// fd-pinned bind under /run), which this guard doesn't do yet.
func (g *dockerGuard) bindSource(src string) (string, error) {
	if !filepath.IsAbs(src) {
		return "", errors.New("the source must be an absolute path")
	}
	real, err := filepath.EvalSymlinks(src)
	if err != nil {
		return "", fmt.Errorf("resolve it: %w", err)
	}
	workspace, scratch := resolvedRoot(g.binds.workspace), resolvedRoot(g.binds.scratch)
	if within(real, workspace) {
		return real, nil
	}
	if real != scratch && within(real, scratch) {
		fi, err := os.Stat(real)
		if err != nil {
			return "", err
		}
		if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) == g.binds.uid {
			return real, nil
		}
		return "", fmt.Errorf("only files and folders you created under %s can be mounted", g.binds.scratch)
	}
	return "", fmt.Errorf("only paths in the checkout (under %s) or your own under %s can be mounted", g.binds.workspace, g.binds.scratch)
}

// resolvedRoot compares roots the way sources are compared: through symlinks.
func resolvedRoot(root string) string {
	if real, err := filepath.EvalSymlinks(root); err == nil {
		return real
	}
	return root
}

func within(p, root string) bool {
	return p == root || strings.HasPrefix(p, strings.TrimSuffix(root, "/")+"/")
}

// imageReplaceable reports whether a pull, import or build may (re)write ref:
// a new name; an image this VM's turns built or imported; or, for a pull, one
// that came from a registry (re-pulling it changes nothing a registry
// couldn't). Images the host pulled for the run's services are never
// replaced by something a turn made.
func (g *dockerGuard) imageReplaceable(ctx context.Context, ref string, pull bool) bool {
	var info struct {
		RepoDigests []string
		Config      struct{ Labels map[string]string }
	}
	code, err := g.engineDo(ctx, http.MethodGet, "/images/"+url.PathEscape(ref)+"/json", &info)
	switch {
	case code == http.StatusNotFound:
		return true
	case err != nil:
		return false
	case info.Config.Labels[guestproto.DockerGuardLabel] != "":
		return true
	}
	return pull && len(info.RepoDigests) > 0
}

// createImage pulls, or imports a tarball the client uploads (docker import).
// An import is labelled like a build, so it counts as made by a turn.
func (g *dockerGuard) createImage(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	src := q.Get("fromSrc")
	ref := q.Get("fromImage")
	if src != "" {
		ref = q.Get("repo")
	}
	if tag := q.Get("tag"); tag != "" && ref != "" && !strings.Contains(ref, "@") {
		ref += ":" + tag
	}
	switch {
	case src != "" && src != "-":
		guardError(w, http.StatusForbidden, "import from a URL isn't available to agents; upload the tarball (docker import -)")
		return
	case ref != "" && !g.imageReplaceable(r.Context(), ref, src == ""):
		guardError(w, http.StatusForbidden, "%s already exists and wasn't made by a turn; pick another name", ref)
		return
	}
	if src != "" {
		q.Add("changes", "LABEL "+guestproto.DockerGuardLabel+"="+g.key)
		r.URL.RawQuery = q.Encode()
	}
	g.fwd.ServeHTTP(w, r)
}

// removeImage lets a turn clean up images turns built or imported, and nothing
// else: the run's service images are shared by every turn in the VM.
func (g *dockerGuard) removeImage(w http.ResponseWriter, r *http.Request, ref string) {
	var info struct {
		Config struct{ Labels map[string]string }
	}
	if _, err := g.engineDo(r.Context(), http.MethodGet, "/images/"+url.PathEscape(ref)+"/json", &info); err != nil {
		guardError(w, http.StatusNotFound, "no such image made by this run: %s", ref)
		return
	}
	if info.Config.Labels[guestproto.DockerGuardLabel] == "" {
		guardError(w, http.StatusForbidden, "%s wasn't made by a turn; only images turns build or import can be removed", ref)
		return
	}
	g.fwd.ServeHTTP(w, r)
}

// build runs a classic (non-BuildKit) build: its RUN steps are containers
// with the daemon's defaults (no privileges, no mounts). BuildKit is refused
// because its session and gRPC streams carry requests the guard can't read.
func (g *dockerGuard) build(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if v := q.Get("version"); v != "" && v != "1" {
		guardError(w, http.StatusForbidden, "BuildKit isn't available to agents; build with DOCKER_BUILDKIT=0")
		return
	}
	switch mode := q.Get("networkmode"); mode {
	case "", "default", "bridge", "none":
	default:
		guardError(w, http.StatusForbidden, "builds run on the default bridge, not %q", mode)
		return
	}
	for _, tag := range q["t"] {
		if !g.imageReplaceable(r.Context(), tag, false) {
			guardError(w, http.StatusForbidden, "tag %s names an image a turn didn't make; pick another tag", tag)
			return
		}
	}
	var own map[string]any
	if raw := q.Get("labels"); raw != "" {
		_ = json.Unmarshal([]byte(raw), &own)
	}
	b, _ := json.Marshal(g.labels(own))
	q.Set("labels", string(b))
	q.Set("version", "1")
	r.URL.RawQuery = q.Encode()
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) createNetwork(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if !readGuardJSON(w, r, &body) {
		return
	}
	if driver, _ := body["Driver"].(string); driver != "" && driver != "bridge" {
		guardError(w, http.StatusForbidden, "only bridge networks are available to agents")
		return
	}
	// Driver options and custom address ranges could claim interface names
	// or routes the VM relies on; Docker picks both.
	out := map[string]any{"Name": body["Name"], "Driver": "bridge", "Labels": g.labels(body["Labels"])}
	for _, field := range []string{"Internal", "Attachable", "CheckDuplicate", "EnableIPv6"} {
		if v, ok := body[field]; ok {
			out[field] = v
		}
	}
	setGuardBody(r, out)
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) network(w http.ResponseWriter, r *http.Request, id, action string) {
	ctx := r.Context()
	ok := (action == "" && (r.Method == http.MethodGet || r.Method == http.MethodDelete)) ||
		(r.Method == http.MethodPost && (action == "connect" || action == "disconnect"))
	if !ok {
		guardError(w, http.StatusForbidden, "%s %s on a network isn't available to agents", r.Method, action)
		return
	}
	if !g.ownsNetwork(ctx, id) {
		guardError(w, http.StatusNotFound, "no such network in this turn: %s", id)
		return
	}
	if action == "connect" || action == "disconnect" {
		var body map[string]any
		if !readGuardJSON(w, r, &body) {
			return
		}
		container, _ := body["Container"].(string)
		if !g.ownsContainer(ctx, container) {
			guardError(w, http.StatusNotFound, "no such container in this turn: %s", container)
			return
		}
		setGuardBody(r, body)
	}
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) createVolume(w http.ResponseWriter, r *http.Request) {
	var body map[string]any
	if !readGuardJSON(w, r, &body) {
		return
	}
	if driver, _ := body["Driver"].(string); driver != "" && driver != "local" {
		guardError(w, http.StatusForbidden, "only local volumes are available to agents")
		return
	}
	if len(asMap(body["DriverOpts"])) > 0 {
		guardError(w, http.StatusForbidden, "volume driver options can mount any path")
		return
	}
	setGuardBody(r, map[string]any{"Name": body["Name"], "Driver": "local", "Labels": g.labels(body["Labels"])})
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
	g := &dockerGuard{key: key, engine: engine}
	filters, _ := json.Marshal(map[string][]string{"label": {g.filter()}})
	q := "filters=" + url.QueryEscape(string(filters))
	var errs []error
	call := func(method, p string, out any) {
		if code, err := g.engineDo(ctx, method, p, out); err != nil && code != http.StatusNotFound {
			errs = append(errs, err)
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
	if err := errors.Join(errs...); err != nil {
		return fmt.Errorf("clean up turn %s: %w", key, err)
	}
	return nil
}

// guardError answers the way the Engine does, so clients show the message.
func guardError(w http.ResponseWriter, code int, format string, args ...any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"message": "vesper guard: " + fmt.Sprintf(format, args...)})
}

func readGuardJSON(w http.ResponseWriter, r *http.Request, v any) bool {
	b, err := io.ReadAll(io.LimitReader(r.Body, maxGuardBody+1))
	if err != nil {
		guardError(w, http.StatusBadRequest, "read request: %v", err)
		return false
	}
	if len(b) > maxGuardBody {
		guardError(w, http.StatusRequestEntityTooLarge, "request body over %d bytes", maxGuardBody)
		return false
	}
	if len(bytes.TrimSpace(b)) == 0 {
		b = []byte("{}")
	}
	if err := json.Unmarshal(b, v); err != nil {
		guardError(w, http.StatusBadRequest, "request body: %v", err)
		return false
	}
	return true
}

func setGuardBody(r *http.Request, v any) {
	b, _ := json.Marshal(v)
	r.Body = io.NopCloser(bytes.NewReader(b))
	r.ContentLength = int64(len(b))
	r.Header.Set("Content-Length", fmt.Sprint(len(b)))
	r.Header.Set("Content-Type", "application/json")
}

func asMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	return m
}

func asList(v any) []any {
	l, _ := v.([]any)
	return l
}

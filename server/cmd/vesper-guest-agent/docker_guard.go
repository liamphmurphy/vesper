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
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"sync"
	"sync/atomic"

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

// dockerGuard is one turn's Docker API, modelled on the former host Docker backend's
// turn proxy. It forwards an allowlist of
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
	// bindRoot, when non-empty (set on Linux root PID 1), holds fd-pinned bind
	// mounts under /run/vesper-binds/<key> so uid 1000 cannot swap a bind source
	// for a symlink before dockerd calls mount(2).
	bindRoot    string
	pinBindFD   func(fd int, isDir bool) (string, error) // test hook
	bindSeq     atomic.Uint64
	pinnedMu    sync.Mutex
	pinnedBinds []string
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
	rawFilters, err := singleQueryParam(q, "filters")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	filters, err := withLabel(rawFilters, g.filter())
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
		body, ok := readGuardJSON(w, r)
		if !ok {
			return
		}
		if on, _ := foldGet(body, "Privileged").(bool); on {
			guardError(w, http.StatusForbidden, "privileged exec isn't allowed")
			return
		}
		out := map[string]any{"Privileged": false}
		for _, field := range []string{"AttachStdin", "AttachStdout", "AttachStderr", "DetachKeys", "Tty", "Env", "Cmd", "User", "WorkingDir", "ConsoleSize"} {
			if v, ok := foldLookup(body, field); ok && v != nil {
				out[field] = v
			}
		}
		setGuardBody(r, out)
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
	body, ok := readGuardJSON(w, r)
	if !ok {
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

// allowedContainerSysctls is the explicit allowlist of safe, container-scoped
// sysctls a turn container may set.
var allowedContainerSysctls = map[string]bool{
	"net.core.somaxconn":                  true,
	"net.ipv4.ip_unprivileged_port_start": true,
	"net.ipv4.ping_group_range":           true,
	"net.ipv4.tcp_keepalive_time":         true,
	"net.ipv4.tcp_keepalive_intvl":        true,
	"net.ipv4.tcp_keepalive_probes":       true,
	"kernel.shmmax":                       true,
	"kernel.shmall":                       true,
	"kernel.shmmni":                       true,
	"kernel.msgmax":                       true,
	"kernel.msgmnb":                       true,
	"kernel.msgmni":                       true,
	"kernel.sem":                          true,
}

// allowedContainerConfigFields is the explicit allowlist of top-level
// container.Config fields forwarded on POST /containers/create. Unknown keys
// (such as differently-cased "hostconfig" or "labels") are never forwarded.
var allowedContainerConfigFields = []string{
	"Hostname", "Domainname", "User", "AttachStdin", "AttachStdout", "AttachStderr",
	"ExposedPorts", "Tty", "OpenStdin", "StdinOnce", "Env", "Cmd", "Healthcheck",
	"ArgsEscaped", "Image", "Volumes", "WorkingDir", "Entrypoint", "NetworkDisabled",
	"MacAddress", "OnBuild", "StopSignal", "StopTimeout", "Shell",
}

// sandbox rebuilds a container create request from fields that only shape
// the container. Anything that would reach past it is refused with a reason
// rather than dropped, so a test fails with a message instead of oddly.
// All field lookups are case-insensitive because dockerd decodes JSON with
// Go's case-insensitive struct matching.
func (g *dockerGuard) sandbox(body map[string]any, ownVolume, ownNetwork func(string) bool) (map[string]any, error) {
	in := asMap(foldGet(body, "HostConfig"))
	refuse := func(field, why string) error { return fmt.Errorf("HostConfig.%s isn't allowed: %s", field, why) }
	if on, _ := foldGet(in, "Privileged").(bool); on {
		return nil, refuse("Privileged", "a privileged container controls the VM")
	}
	for _, field := range []string{"CapAdd", "Devices", "DeviceRequests", "DeviceCgroupRules", "VolumesFrom", "Links"} {
		if list, _ := foldGet(in, field).([]any); len(list) > 0 {
			return nil, refuse(field, "it reaches past the container")
		}
	}
	for _, field := range []string{"CgroupParent", "Runtime", "Cgroup", "VolumeDriver"} {
		if s, _ := foldGet(in, field).(string); s != "" {
			return nil, refuse(field, "it changes how the VM runs the container")
		}
	}
	for _, field := range []string{"PidMode", "IpcMode", "UTSMode", "UsernsMode", "CgroupnsMode"} {
		if s, _ := foldGet(in, field).(string); s == "host" || strings.HasPrefix(s, "container:") {
			return nil, refuse(field, "it shares another namespace")
		}
	}
	for _, opt := range asList(foldGet(in, "SecurityOpt")) {
		if s, _ := opt.(string); s != "no-new-privileges" && s != "no-new-privileges:true" {
			return nil, refuse("SecurityOpt", "only no-new-privileges is accepted")
		}
	}

	host := map[string]any{}
	for _, field := range []string{"Tmpfs", "ShmSize", "Init", "AutoRemove", "Ulimits", "ExtraHosts", "ReadonlyRootfs",
		"Dns", "DnsOptions", "DnsSearch", "NanoCpus", "CpuShares", "CpuQuota", "CpuPeriod",
		"Memory", "MemoryReservation", "PidsLimit", "CapDrop", "PortBindings", "PublishAllPorts"} {
		if v, ok := foldLookup(in, field); ok && v != nil {
			host[field] = v
		}
	}
	if v, ok := foldLookup(in, "OomScoreAdj"); ok && v != nil {
		adj, ok := v.(float64)
		if !ok || adj < 0 || adj > 1000 {
			return nil, refuse("OomScoreAdj", "must be between 0 and 1000")
		}
		host["OomScoreAdj"] = int(adj)
	}
	if v, ok := foldLookup(in, "Sysctls"); ok && v != nil {
		sysctls := asMap(v)
		if sysctls == nil {
			return nil, refuse("Sysctls", "must be a map of strings")
		}
		cleanSysctls := make(map[string]string, len(sysctls))
		for k, sv := range sysctls {
			if !allowedContainerSysctls[k] {
				return nil, refuse("Sysctls", fmt.Sprintf("sysctl %q isn't allowed", k))
			}
			strVal, ok := sv.(string)
			if !ok {
				return nil, refuse("Sysctls", fmt.Sprintf("sysctl %q must have a string value", k))
			}
			cleanSysctls[k] = strVal
		}
		if len(cleanSysctls) > 0 {
			host["Sysctls"] = cleanSysctls
		}
	}

	host["SecurityOpt"] = []string{"no-new-privileges"}
	restart := asMap(foldGet(in, "RestartPolicy"))
	if name, _ := foldGet(restart, "Name").(string); name == "on-failure" {
		rp := map[string]any{"Name": "on-failure"}
		if maxRetry, ok := foldLookup(restart, "MaximumRetryCount"); ok && maxRetry != nil {
			rp["MaximumRetryCount"] = maxRetry
		}
		host["RestartPolicy"] = rp
	} else {
		host["RestartPolicy"] = map[string]any{"Name": "no"}
	}

	var binds []string
	var mounts []any
	for _, b := range asList(foldGet(in, "Binds")) {
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
	for _, m := range asList(foldGet(in, "Mounts")) {
		mount := asMap(m)
		t, _ := foldGet(mount, "Type").(string)
		dst, _ := foldGet(mount, "Target").(string)
		ro, _ := foldGet(mount, "ReadOnly").(bool)
		switch t {
		case "tmpfs":
			rebuilt := map[string]any{"Type": "tmpfs", "Target": dst, "ReadOnly": ro}
			if topts := asMap(foldGet(mount, "TmpfsOptions")); len(topts) > 0 {
				cleanOpts := map[string]any{}
				for _, field := range []string{"SizeBytes", "Mode"} {
					if v, ok := foldLookup(topts, field); ok && v != nil {
						cleanOpts[field] = v
					}
				}
				if len(cleanOpts) > 0 {
					rebuilt["TmpfsOptions"] = cleanOpts
				}
			}
			mounts = append(mounts, rebuilt)
		case "volume":
			src, _ := foldGet(mount, "Source").(string)
			if src != "" && !ownVolume(src) {
				return nil, refuse("Mounts", fmt.Sprintf("volume %q wasn't created by this turn", src))
			}
			// The local driver's options are a mount(2) call: type=none,o=bind
			// binds any path.
			volOpts := asMap(foldGet(mount, "VolumeOptions"))
			if len(asMap(foldGet(volOpts, "DriverConfig"))) > 0 {
				return nil, refuse("Mounts", "volume driver options can mount any path")
			}
			rebuilt := map[string]any{"Type": "volume", "Source": src, "Target": dst, "ReadOnly": ro}
			if len(volOpts) > 0 {
				cleanOpts := map[string]any{}
				if nc, ok := foldLookup(volOpts, "NoCopy"); ok && nc != nil {
					cleanOpts["NoCopy"] = nc
				}
				if lbls, ok := foldLookup(volOpts, "Labels"); ok && lbls != nil {
					cleanOpts["Labels"] = lbls
				}
				if len(cleanOpts) > 0 {
					rebuilt["VolumeOptions"] = cleanOpts
				}
			}
			mounts = append(mounts, rebuilt)
		case "bind":
			src, _ := foldGet(mount, "Source").(string)
			real, err := g.bindSource(src)
			if err != nil {
				return nil, refuse("Mounts", fmt.Sprintf("bind %q: %v", src, err))
			}
			mounts = append(mounts, map[string]any{"Type": "bind", "Source": real, "Target": dst, "ReadOnly": ro})
		default:
			return nil, refuse("Mounts", fmt.Sprintf("%q mounts reach past the container; use a volume, a tmpfs or a bind from the checkout", t))
		}
	}
	if len(mounts) > 0 {
		host["Mounts"] = mounts
	}

	// Networking: the VM's default bridge, none, or a network this turn
	// created; never the VM's own, another container's, or the run's services'.
	network, _ := foldGet(in, "NetworkMode").(string)
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
	for _, field := range allowedContainerConfigFields {
		if v, ok := foldLookup(body, field); ok && v != nil {
			out[field] = v
		}
	}
	if nc := asMap(foldGet(body, "NetworkingConfig")); nc != nil {
		endpoints := map[string]any{}
		for name, cfg := range asMap(foldGet(nc, "EndpointsConfig")) {
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
	out["Labels"] = g.labels(foldGet(body, "Labels"))
	return out, nil
}

// bindSource validates src inside workspace or user-owned scratch and, on
// Linux root PID 1, pins it via an fd-based bind mount under /run/vesper-binds
// so uid 1000 cannot swap it for a symlink before dockerd calls mount(2).
func (g *dockerGuard) bindSource(src string) (string, error) {
	return g.resolveAndPinBind(src)
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
	src, err := singleQueryParam(q, "fromSrc")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	ref, err := singleQueryParam(q, "fromImage")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	repo, err := singleQueryParam(q, "repo")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	tag, err := singleQueryParam(q, "tag")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	if src != "" {
		ref = repo
	}
	if tag != "" && ref != "" && !strings.Contains(ref, "@") {
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
	v, err := singleQueryParam(q, "version")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	if v != "" && v != "1" {
		guardError(w, http.StatusForbidden, "BuildKit isn't available to agents; build with DOCKER_BUILDKIT=0")
		return
	}
	mode, err := singleQueryParam(q, "networkmode")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	switch mode {
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
	rawLabels, err := singleQueryParam(q, "labels")
	if err != nil {
		guardError(w, http.StatusBadRequest, "%v", err)
		return
	}
	var own map[string]any
	if rawLabels != "" {
		_ = json.Unmarshal([]byte(rawLabels), &own)
	}
	b, _ := json.Marshal(g.labels(own))
	q.Set("labels", string(b))
	q.Set("version", "1")
	r.URL.RawQuery = q.Encode()
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) createNetwork(w http.ResponseWriter, r *http.Request) {
	body, ok := readGuardJSON(w, r)
	if !ok {
		return
	}
	if driver, _ := foldGet(body, "Driver").(string); driver != "" && driver != "bridge" {
		guardError(w, http.StatusForbidden, "only bridge networks are available to agents")
		return
	}
	// Driver options and custom address ranges could claim interface names
	// or routes the VM relies on; Docker picks both.
	out := map[string]any{"Name": foldGet(body, "Name"), "Driver": "bridge", "Labels": g.labels(foldGet(body, "Labels"))}
	for _, field := range []string{"Internal", "Attachable", "CheckDuplicate", "EnableIPv6"} {
		if v, ok := foldLookup(body, field); ok {
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
		body, ok := readGuardJSON(w, r)
		if !ok {
			return
		}
		container, _ := foldGet(body, "Container").(string)
		if !g.ownsContainer(ctx, container) {
			guardError(w, http.StatusNotFound, "no such container in this turn: %s", container)
			return
		}
		out := map[string]any{"Container": container}
		if action == "connect" {
			if ep, ok := foldLookup(body, "EndpointConfig"); ok && ep != nil {
				out["EndpointConfig"] = ep
			}
		} else {
			if force, ok := foldLookup(body, "Force"); ok && force != nil {
				out["Force"] = force
			}
		}
		setGuardBody(r, out)
	}
	g.fwd.ServeHTTP(w, r)
}

func (g *dockerGuard) createVolume(w http.ResponseWriter, r *http.Request) {
	body, ok := readGuardJSON(w, r)
	if !ok {
		return
	}
	if driver, _ := foldGet(body, "Driver").(string); driver != "" && driver != "local" {
		guardError(w, http.StatusForbidden, "only local volumes are available to agents")
		return
	}
	if len(asMap(foldGet(body, "DriverOpts"))) > 0 {
		guardError(w, http.StatusForbidden, "volume driver options can mount any path")
		return
	}
	setGuardBody(r, map[string]any{"Name": foldGet(body, "Name"), "Driver": "local", "Labels": g.labels(foldGet(body, "Labels"))})
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

func readGuardJSON(w http.ResponseWriter, r *http.Request) (map[string]any, bool) {
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
		return map[string]any{}, true
	}
	obj, err := decodeStrictJSONObject(b)
	if err != nil {
		guardError(w, http.StatusBadRequest, "request body: %v", err)
		return nil, false
	}
	return obj, true
}

// decodeStrictJSONObject parses a JSON object while rejecting any object (at
// any nesting depth) that contains duplicate keys case-insensitively. This
// prevents smuggling fields past the guard to dockerd's case-insensitive Go
// encoding/json decoder.
func decodeStrictJSONObject(b []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	v, err := decodeStrictValue(dec, 0)
	if err != nil {
		return nil, err
	}
	if tok, err := dec.Token(); err != io.EOF {
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("unexpected trailing JSON token %v", tok)
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("expected JSON object")
	}
	return obj, nil
}

const maxJSONDepth = 64

func decodeStrictValue(dec *json.Decoder, depth int) (any, error) {
	if depth > maxJSONDepth {
		return nil, errors.New("JSON nesting depth exceeded")
	}
	tok, err := dec.Token()
	if err != nil {
		return nil, err
	}
	d, ok := tok.(json.Delim)
	if !ok {
		return tok, nil
	}
	switch d {
	case '{':
		m := map[string]any{}
		seen := map[string]struct{}{}
		for dec.More() {
			ktok, err := dec.Token()
			if err != nil {
				return nil, err
			}
			key, ok := ktok.(string)
			if !ok {
				return nil, errors.New("expected string object key")
			}
			lk := strings.ToLower(key)
			if _, dup := seen[lk]; dup {
				return nil, fmt.Errorf("duplicate JSON key %q (case-insensitive)", key)
			}
			seen[lk] = struct{}{}
			val, err := decodeStrictValue(dec, depth+1)
			if err != nil {
				return nil, err
			}
			m[key] = val
		}
		end, err := dec.Token()
		if err != nil {
			return nil, err
		}
		if end != json.Delim('}') {
			return nil, fmt.Errorf("expected '}', got %v", end)
		}
		return m, nil
	case '[':
		var arr []any
		for dec.More() {
			val, err := decodeStrictValue(dec, depth+1)
			if err != nil {
				return nil, err
			}
			arr = append(arr, val)
		}
		end, err := dec.Token()
		if err != nil {
			return nil, err
		}
		if end != json.Delim(']') {
			return nil, fmt.Errorf("expected ']', got %v", end)
		}
		return arr, nil
	default:
		return nil, fmt.Errorf("unexpected delimiter %v", d)
	}
}

func foldLookup(m map[string]any, key string) (any, bool) {
	if m == nil {
		return nil, false
	}
	if v, ok := m[key]; ok {
		return v, true
	}
	for k, v := range m {
		if strings.EqualFold(k, key) {
			return v, true
		}
	}
	return nil, false
}

func foldGet(m map[string]any, key string) any {
	v, _ := foldLookup(m, key)
	return v
}

func singleQueryParam(q url.Values, key string) (string, error) {
	vals := q[key]
	if len(vals) > 1 {
		return "", fmt.Errorf("duplicate query parameter %q", key)
	}
	if len(vals) == 0 {
		return "", nil
	}
	return vals[0], nil
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

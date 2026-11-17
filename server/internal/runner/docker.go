package runner

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
)

// maxCodexAuth matches the 16 KB limit on a stored secret.
const maxCodexAuth = 16 << 10

// Docker runs each process as a container from the agent image, with the
// run's checkout at /workspace (§6.5): its named volume, or a host folder. It
// talks to the Engine API over the socket directly, so the runner image needs
// no docker CLI.
//
// Mounting the socket gives the runner root-equivalent access to the host.
// v1 targets a single laptop, where that's documented and accepted.
type Docker struct {
	Socket  string // /var/run/docker.sock
	Image   string // vesper/agent-base:latest
	Network string // where api:8000 resolves; "" = default bridge
	// Stack labels this install's containers. Installs sharing a Docker daemon
	// (the dev stack and the full compose stack) must differ, or each runner's
	// startup Cleanup kills the other's running turns. "" means "default".
	Stack string
	// RequestTimeout bounds finite Engine calls and the attach handshake.
	// Running containers and their output streams are bounded by their context.
	RequestTimeout time.Duration
	// UsageTimeout bounds one usage check; 0 means probeUsageTimeout.
	UsageTimeout time.Duration
	// MemoryMB and PidsLimit cap each container; 0 leaves that limit off.
	// ModelsTimeout bounds one model listing; 0 means listModelsTimeout.
	ModelsTimeout time.Duration
	MemoryMB      int64
	PidsLimit     int64
	// SaveCodexAuth stores a ChatGPT login a turn refreshed. scope is what
	// SecretEnv put in CodexAuthScopeEnv.
	SaveCodexAuth func(ctx context.Context, scope, auth string) error
	// SaveClaudeAuth stores a Claude OAuth login a turn refreshed. scope is
	// what SecretEnv put in ClaudeAuthScopeEnv.
	SaveClaudeAuth func(ctx context.Context, scope, auth string) error
	// HostWorkspaces is where checkouts go when they live in a folder on the
	// person's machine (RUNNER_HOST_WORKSPACES_DIR); "" turns that off. The
	// runner must see it at the same absolute path as the Docker daemon: it
	// creates and removes the run folders itself, then hands the path to
	// Docker as a bind source.
	HostWorkspaces string
	// ProxyDir is where this runner serves each turn's Docker API socket, and
	// ProxyVolume is the volume holding it, mounted read-only into turns at
	// proxyMountPath (RUNNER_DOCKER_PROXY_DIR, RUNNER_DOCKER_PROXY_VOLUME).
	// Either empty turns the per-turn Docker API off.
	ProxyDir, ProxyVolume string
	// NixVolume is the Nix store every turn shares through the runner's
	// nix-daemon (RUNNER_NIX_VOLUME); "" leaves turns without Nix.
	NixVolume string
	// nixUnhealthy is set when CheckNixDaemon found the daemon unresponsive.
	nixUnhealthy atomic.Bool
	client       *http.Client
	clientMu     sync.Mutex
	// self is the runner's own container, once selfID has found it.
	selfMu sync.Mutex
	self   string
	// dialPlayground reaches a playground process; nil dials TCP (tests
	// stand in for the container network).
	dialPlayground func(ctx context.Context, addr string) (net.Conn, error)
}

const (
	dockerAPI      = "http://docker/v1.43"
	workspacePath  = "/workspace"
	homePath       = "/home/node"
	claudeAuthPath = ".claude/.credentials.json"
	codexAuthPath  = ".codex/auth.json"
	labelKey       = "dev.lazyagents.run"
	stackLabelKey  = "dev.lazyagents.stack"
)

func (d *Docker) Name() string   { return "docker" }
func (d *Docker) Isolates() bool { return true }

func (d *Docker) stack() string {
	if d.Stack == "" {
		return "default"
	}
	return d.Stack
}

// labels marks a container or volume as this install's, for the run.
func (d *Docker) labels(runID string) map[string]string {
	return map[string]string{labelKey: runID, stackLabelKey: d.stack()}
}

func (d *Docker) http() *http.Client {
	d.clientMu.Lock()
	defer d.clientMu.Unlock()
	if d.client == nil {
		d.client = &http.Client{Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", d.Socket)
			},
		}}
	}
	return d.client
}

type cancelBody struct {
	io.ReadCloser
	cancel context.CancelFunc
}

func (b cancelBody) Close() error { defer b.cancel(); return b.ReadCloser.Close() }

func (d *Docker) do(ctx context.Context, method, path string, body io.Reader, ctype string, out any) (*http.Response, error) {
	timeout := d.RequestTimeout
	if timeout <= 0 {
		timeout = 30 * time.Second
	}
	cancel := context.CancelFunc(func() {})
	switch {
	case strings.Contains(path, "/attach?"):
		// Limit the handshake without imposing that limit on the subsequent
		// event stream. Its lifetime remains tied to the process context.
		ctx, cancel = context.WithCancel(ctx)
		timer := time.AfterFunc(timeout, cancel)
		defer timer.Stop()
	case strings.HasSuffix(path, "/wait"), strings.HasPrefix(path, "/images/create?"),
		strings.HasPrefix(path, "/exec/") && strings.HasSuffix(path, "/start"):
		// Long polls, pulls and streamed execs have caller-owned deadlines.
	default:
		ctx, cancel = context.WithTimeout(ctx, timeout)
	}
	req, err := http.NewRequestWithContext(ctx, method, dockerAPI+path, body)
	if err != nil {
		cancel()
		return nil, err
	}
	if ctype != "" {
		req.Header.Set("Content-Type", ctype)
	}
	res, err := d.http().Do(req)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("docker %s %s: %w", method, path, err)
	}
	res.Body = cancelBody{ReadCloser: res.Body, cancel: cancel}
	if res.StatusCode >= 300 {
		defer res.Body.Close()
		b, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
		var msg struct{ Message string }
		_ = json.Unmarshal(b, &msg)
		if msg.Message == "" {
			msg.Message = strings.TrimSpace(string(b))
		}
		return res, &dockerError{Status: res.StatusCode, Msg: msg.Message}
	}
	if out != nil {
		defer res.Body.Close()
		return res, json.NewDecoder(res.Body).Decode(out)
	}
	if res.ContentLength == 0 {
		_ = res.Body.Close()
	}
	return res, nil
}

type dockerError struct {
	Status int
	Msg    string
}

func (e *dockerError) Error() string { return fmt.Sprintf("docker: %d %s", e.Status, e.Msg) }

func isStatus(err error, code int) bool {
	var de *dockerError
	return errors.As(err, &de) && de.Status == code
}

func jsonBody(v any) io.Reader {
	b, _ := json.Marshal(v)
	return bytes.NewReader(b)
}

func volumeName(runID string) string { return "lazyagents-run-" + runID }

// homeVolumeName is the run's home directory. Each turn is a new container, so
// the harness sessions a later turn resumes have to outlive the container.
func homeVolumeName(runID string) string { return volumeName(runID) + "-home" }

func (d *Docker) WorkspaceDir(string) string { return workspacePath }

// Ping checks the socket and that the image exists.
func (d *Docker) Ping(ctx context.Context) error {
	if _, err := d.do(ctx, "GET", "/_ping", nil, "", nil); err != nil {
		return err
	}
	if _, err := d.do(ctx, "GET", "/images/"+url.PathEscape(d.Image)+"/json", nil, "", nil); err != nil {
		if isStatus(err, 404) {
			return fmt.Errorf("image %s not found: build it with `docker compose build agent-base`", d.Image)
		}
		return err
	}
	return nil
}

// A run's checkout is either its named volume or, when it was created with
// EnsureHostWorkspace, a folder under HostWorkspaces. Which one is fixed when
// the workspace is first created: switching later would hand the next turn an
// empty checkout. The home directory is always a volume; it holds harness
// sessions and logins, nothing a person needs to open.

func (d *Docker) createVolumes(ctx context.Context, runID string, names ...string) error {
	for _, name := range names {
		_, err := d.do(ctx, "POST", "/volumes/create", jsonBody(map[string]any{
			"Name": name, "Labels": d.labels(runID),
		}), "application/json", nil)
		if err != nil {
			return err
		}
	}
	return nil
}

func (d *Docker) EnsureWorkspace(ctx context.Context, runID string) error {
	folder, err := d.hostFolder(runID)
	if err != nil {
		return err
	}
	if folder != "" {
		return d.createVolumes(ctx, runID, homeVolumeName(runID))
	}
	return d.createVolumes(ctx, runID, volumeName(runID), homeVolumeName(runID))
}

// HostWorkspacesDir implements HostFolders.
func (d *Docker) HostWorkspacesDir() string { return d.HostWorkspaces }

// EnsureHostWorkspace implements HostFolders.
func (d *Docker) EnsureHostWorkspace(ctx context.Context, runID string) (string, error) {
	folder, err := d.hostFolderPath(runID)
	if err != nil {
		return "", err
	}
	hasVolume, err := d.hasVolume(ctx, runID)
	if err != nil {
		return "", err
	}
	if hasVolume { // created before host folders were turned on: it stays
		return "", d.EnsureWorkspace(ctx, runID)
	}
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return "", fmt.Errorf("create workspace folder: %w", err)
	}
	// Turns run as the image's node user (uid 1000). A runner that isn't root
	// can't chown; Docker Desktop and OrbStack map bind-mount ownership to the
	// container user anyway, and elsewhere setup fails with a clear
	// permission error on its first write.
	if err := os.Chown(folder, 1000, 1000); err != nil && !errors.Is(err, fs.ErrPermission) {
		return "", fmt.Errorf("hand the workspace folder to the agent user: %w", err)
	}
	if err := d.createVolumes(ctx, runID, homeVolumeName(runID)); err != nil {
		return "", err
	}
	return folder, nil
}

// hostFolderPath is where the run's folder goes under HostWorkspaces.
func (d *Docker) hostFolderPath(runID string) (string, error) {
	if d.HostWorkspaces == "" {
		return "", errors.New("runner: RUNNER_HOST_WORKSPACES_DIR is not set")
	}
	// The ID becomes one path element that RemoveWorkspace deletes, so it
	// must never be empty or reach outside its own folder.
	if runID == "" || runID == "." || runID == ".." || strings.ContainsAny(runID, `/\`) {
		return "", fmt.Errorf("runner: bad workspace id %q", runID)
	}
	return filepath.Join(d.HostWorkspaces, runID), nil
}

// hostFolder is the run's checkout folder when it has one, else "".
func (d *Docker) hostFolder(runID string) (string, error) {
	if d.HostWorkspaces == "" {
		return "", nil
	}
	folder, err := d.hostFolderPath(runID)
	if err != nil {
		return "", err
	}
	if _, err := os.Stat(folder); errors.Is(err, fs.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", err
	}
	return folder, nil
}

func (d *Docker) hasVolume(ctx context.Context, runID string) (bool, error) {
	res, err := d.do(ctx, "GET", "/volumes/"+volumeName(runID), nil, "", nil)
	if isStatus(err, 404) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	res.Body.Close()
	return true, nil
}

func (d *Docker) HasWorkspace(ctx context.Context, runID string) (bool, error) {
	folder, err := d.hostFolder(runID)
	if err != nil || folder != "" {
		return folder != "", err
	}
	return d.hasVolume(ctx, runID)
}

func (d *Docker) RemoveWorkspace(ctx context.Context, runID string) error {
	for _, name := range []string{volumeName(runID), homeVolumeName(runID)} {
		_, err := d.do(ctx, "DELETE", "/volumes/"+name+"?force=1", nil, "", nil)
		if err != nil && !isStatus(err, 404) {
			return err
		}
	}
	folder, err := d.hostFolder(runID)
	if err != nil || folder == "" {
		return err
	}
	return os.RemoveAll(folder)
}

// workspaceMount is the run's checkout as a container mount.
func (d *Docker) workspaceMount(runID string) (map[string]any, error) {
	folder, err := d.hostFolder(runID)
	if err != nil {
		return nil, err
	}
	if folder != "" {
		return map[string]any{"Type": "bind", "Source": folder, "Target": workspacePath}, nil
	}
	return map[string]any{"Type": "volume", "Source": volumeName(runID), "Target": workspacePath}, nil
}

// Cleanup removes turn containers left by a runner of this install that died;
// their turns are re-run (the harness resumes its session). Another install's
// containers on the same daemon are running turns of its own: they're left alone.
func (d *Docker) Cleanup(ctx context.Context) error {
	filters, _ := json.Marshal(map[string][]string{"label": {labelKey, stackLabelKey + "=" + d.stack()}})
	var list []struct{ ID string }
	if _, err := d.do(ctx, "GET", "/containers/json?all=1&filters="+url.QueryEscape(string(filters)), nil, "", &list); err != nil {
		return err
	}
	for _, c := range list {
		// v=1: a service's anonymous data volume (postgres declares one) goes
		// with it, as does a playground's.
		_, _ = d.do(ctx, "DELETE", "/containers/"+c.ID+"?force=1&v=1", nil, "", nil)
	}
	// Then the service networks those turns had (their containers are gone).
	var nets []struct{ ID string }
	if _, err := d.do(ctx, "GET", "/networks?filters="+url.QueryEscape(string(filters)), nil, "", &nets); err != nil {
		return err
	}
	self, selfErr := d.selfID(ctx)
	for _, n := range nets {
		// A restarted runner container is still on its playgrounds' networks.
		if selfErr == nil {
			_, _ = d.do(ctx, "POST", "/networks/"+n.ID+"/disconnect", jsonBody(map[string]any{"Container": self, "Force": true}), "application/json", nil)
		}
		_, _ = d.do(ctx, "DELETE", "/networks/"+n.ID, nil, "", nil)
	}
	// And the volumes their tests created through the Docker proxy. Run
	// checkouts are volumes too, but they carry no proxy label.
	proxyFilters, _ := json.Marshal(map[string][]string{"label": {proxyLabelKey, stackLabelKey + "=" + d.stack()}})
	var vols struct{ Volumes []struct{ Name string } }
	if _, err := d.do(ctx, "GET", "/volumes?filters="+url.QueryEscape(string(proxyFilters)), nil, "", &vols); err != nil {
		return err
	}
	for _, v := range vols.Volumes {
		_, _ = d.do(ctx, "DELETE", "/volumes/"+url.PathEscape(v.Name)+"?force=1", nil, "", nil)
	}
	return nil
}

func tarFiles(files map[string][]byte) (*bytes.Buffer, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	names := make([]string, 0, len(files))
	for n := range files {
		names = append(names, n)
	}
	sort.Strings(names)
	dirs := map[string]bool{}
	for _, n := range names {
		if strings.Contains(n, "..") || strings.HasPrefix(n, "/") {
			return nil, fmt.Errorf("runner: bad file path %q", n)
		}
		// Parent directories first, owned by the agent user (uid 1000).
		parts := strings.Split(n, "/")
		for i := 1; i < len(parts); i++ {
			dir := strings.Join(parts[:i], "/") + "/"
			if !dirs[dir] {
				dirs[dir] = true
				if err := tw.WriteHeader(&tar.Header{Name: dir, Mode: 0o755, Typeflag: tar.TypeDir, Uid: 1000, Gid: 1000, ModTime: time.Now()}); err != nil {
					return nil, err
				}
			}
		}
		if err := tw.WriteHeader(&tar.Header{Name: n, Mode: 0o600, Size: int64(len(files[n])), Uid: 1000, Gid: 1000, ModTime: time.Now()}); err != nil {
			return nil, err
		}
		if _, err := tw.Write(files[n]); err != nil {
			return nil, err
		}
	}
	return &buf, tw.Close()
}

// hostConfig is the sandbox every turn runs in: no capabilities, no privilege
// escalation through setuid binaries, and bounded resources.
func (d *Docker) hostConfig(mounts []map[string]any) map[string]any {
	host := map[string]any{
		"Mounts":      mounts,
		"NetworkMode": d.Network,
		"Init":        true, // forward SIGINT to the harness, reap children
		"CapDrop":     []string{"ALL"},
		"SecurityOpt": []string{"no-new-privileges"},
		// A runner on the host is reached by this name, on Linux too.
		"ExtraHosts": []string{"host.docker.internal:host-gateway"},
	}
	if d.MemoryMB > 0 {
		host["Memory"] = d.MemoryMB << 20
	}
	if d.PidsLimit > 0 {
		host["PidsLimit"] = d.PidsLimit
	}
	return host
}

// singleFileTar builds an archive unpacking content at relPath under $HOME.
func singleFileTar(relPath, content string) (io.Reader, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	dir, _ := path.Split(relPath)
	if dir != "" {
		if err := tw.WriteHeader(&tar.Header{Typeflag: tar.TypeDir, Name: dir, Mode: 0o700, Uid: 1000, Gid: 1000, ModTime: time.Now()}); err != nil {
			return nil, err
		}
	}
	if err := tw.WriteHeader(&tar.Header{Name: relPath, Mode: 0o600, Size: int64(len(content)), Uid: 1000, Gid: 1000, ModTime: time.Now()}); err != nil {
		return nil, err
	}
	if _, err := io.WriteString(tw, content); err != nil {
		return nil, err
	}
	return &buf, tw.Close()
}

// claudeAuthTar puts a Claude OAuth login at ~/.claude/.credentials.json.
func claudeAuthTar(auth string) (io.Reader, error) { return singleFileTar(claudeAuthPath, auth) }

// codexAuthTar is the archive that puts a ChatGPT login at ~/.codex/auth.json.
func codexAuthTar(auth string) (io.Reader, error) { return singleFileTar(codexAuthPath, auth) }

// antigravityAuthTar builds a tar archive unpacking an Antigravity login bundle
// under $HOME in a container.
func antigravityAuthTar(raw string) (io.Reader, error) {
	auth, ok := chatmodels.ParseAntigravityAuth(raw)
	if !ok {
		return nil, fmt.Errorf("runner: invalid Antigravity login")
	}
	files, ok := auth.DecodeFiles()
	if !ok {
		return nil, fmt.Errorf("runner: invalid Antigravity login")
	}
	return tarFiles(files)
}

func (d *Docker) Start(ctx context.Context, runID string, spec ExecSpec) (Process, error) {
	if spec.Env == nil {
		spec.Env = map[string]string{}
	}
	workspace := path.Join(workspacePath, spec.Dir)
	for k, v := range dependencyEnv(d.DependencyCacheDir(), workspace) {
		if _, exists := spec.Env[k]; !exists {
			spec.Env[k] = v
		}
	}
	if _, exists := spec.Env[SSHDirEnv]; !exists {
		spec.Env[SSHDirEnv] = path.Join(homePath, ".lazyagents", "ssh")
	}
	checkout, err := d.workspaceMount(runID)
	if err != nil {
		return nil, err
	}
	mounts := []map[string]any{checkout}
	// A persistent volume is shared by all runs and deliberately has no run
	// label, so workspace cleanup never removes downloaded dependencies.
	mounts = append(mounts, map[string]any{"Type": "volume", "Source": homeVolumeName(runID), "Target": homePath})
	mounts = append(mounts, map[string]any{"Type": "volume", "Source": "lazyagents-dependency-cache", "Target": "/cache"})
	if m := d.nixMount(); m != nil {
		mounts = append(mounts, m)
	}
	if d.ProxyDir != "" && d.ProxyVolume != "" {
		// Read-only, and turns can't list it: a turn reaches only the socket
		// whose name its DOCKER_HOST carries.
		mounts = append(mounts, map[string]any{"Type": "volume", "Source": d.ProxyVolume, "Target": proxyMountPath, "ReadOnly": true})
	}
	env := make([]string, 0, len(spec.Env))
	for k, v := range spec.Env {
		if k == ClaudeAuthEnv || k == ClaudeAuthScopeEnv || k == CodexAuthEnv || k == CodexAuthScopeEnv || k == AntigravityAuthEnv {
			continue // delivered as a file below, never through the environment
		}
		env = append(env, k+"="+v)
	}
	sort.Strings(env)
	dir := workspacePath
	if spec.Dir != "" {
		if strings.Contains(spec.Dir, "..") || strings.HasPrefix(spec.Dir, "/") {
			return nil, fmt.Errorf("runner: bad directory %q", spec.Dir)
		}
		dir = path.Join(workspacePath, spec.Dir)
	}
	body := map[string]any{
		"Image": d.Image, "Cmd": spec.Argv, "Env": env, "WorkingDir": dir,
		"Labels":     d.labels(runID),
		"HostConfig": d.hostConfig(mounts),
	}
	var created struct{ ID string }
	name := url.QueryEscape(spec.Name)
	if _, err := d.do(ctx, "POST", "/containers/create?name="+name, jsonBody(body), "application/json", &created); err != nil {
		if isStatus(err, 409) { // a stale container with this name
			_, _ = d.do(ctx, "DELETE", "/containers/"+name+"?force=1", nil, "", nil)
			_, err = d.do(ctx, "POST", "/containers/create?name="+name, jsonBody(body), "application/json", &created)
		}
		if err != nil {
			return nil, err
		}
	}
	p := &dockerProc{
		d: d, id: created.ID, parent: ctx,
		claudeAuth: spec.Env[ClaudeAuthEnv], claudeScope: spec.Env[ClaudeAuthScopeEnv],
		codexAuth: spec.Env[CodexAuthEnv], codexScope: spec.Env[CodexAuthScopeEnv],
	}
	for _, item := range []struct {
		raw   string
		build func(string) (io.Reader, error)
	}{
		{p.claudeAuth, claudeAuthTar},
		{p.codexAuth, codexAuthTar},
		{spec.Env[AntigravityAuthEnv], antigravityAuthTar},
	} {
		if item.raw == "" {
			continue
		}
		tb, err := item.build(item.raw)
		if err != nil {
			p.remove()
			return nil, err
		}
		if _, err := d.do(ctx, "PUT", "/containers/"+created.ID+"/archive?path="+url.QueryEscape(homePath), tb, "application/x-tar", nil); err != nil {
			p.remove()
			return nil, err
		}
	}
	if len(spec.Files) > 0 {
		tb, err := tarFiles(spec.Files)
		if err != nil {
			p.remove()
			return nil, err
		}
		if _, err := d.do(ctx, "PUT", "/containers/"+created.ID+"/archive?path="+url.QueryEscape(dir), tb, "application/x-tar", nil); err != nil {
			p.remove()
			return nil, err
		}
	}
	for _, n := range spec.Networks {
		if _, err := d.do(ctx, "POST", "/networks/"+url.PathEscape(n)+"/connect", jsonBody(map[string]any{"Container": created.ID}), "application/json", nil); err != nil {
			p.remove()
			return nil, fmt.Errorf("join network %s: %w", n, err)
		}
	}
	// Attach before start so no output is lost.
	logs, err := d.do(p.context(), "POST", "/containers/"+created.ID+"/attach?stream=1&stdout=1&stderr=1", nil, "", nil)
	if err != nil {
		p.remove()
		return nil, err
	}
	if _, err := d.do(ctx, "POST", "/containers/"+created.ID+"/start", nil, "", nil); err != nil {
		logs.Body.Close()
		p.remove()
		return nil, err
	}
	outR, outW := io.Pipe()
	errR, errW := io.Pipe()
	p.out, p.err = outR, errR
	p.logs = logs.Body
	go func() {
		defer logs.Body.Close()
		e := demux(logs.Body, outW, errW)
		outW.CloseWithError(e)
		errW.CloseWithError(e)
	}()
	return p, nil
}

// demux splits Docker's multiplexed attach stream (8-byte frame headers).
func demux(r io.Reader, stdout, stderr io.Writer) error {
	hdr := make([]byte, 8)
	for {
		if _, err := io.ReadFull(r, hdr); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return nil
			}
			return err
		}
		n := int64(binary.BigEndian.Uint32(hdr[4:]))
		w := stdout
		if hdr[0] == 2 {
			w = stderr
		}
		if _, err := io.CopyN(w, r, n); err != nil {
			return err
		}
	}
}

type dockerProc struct {
	d           *Docker
	id          string
	out         io.Reader
	err         io.Reader
	parent      context.Context
	ctx         context.Context
	cancel      context.CancelFunc
	contextOnce sync.Once
	logs        io.Closer
	// The Claude/ChatGPT logins this process was given, and where they are stored.
	claudeAuth, claudeScope string
	codexAuth, codexScope   string
	// nixManifest is the run's Nix profile as the turn left it.
	nixManifest []byte
}

func (p *dockerProc) context() context.Context {
	p.contextOnce.Do(func() {
		parent := p.parent
		if parent == nil {
			parent = context.Background()
		}
		p.ctx, p.cancel = context.WithCancel(parent)
	})
	return p.ctx
}

func (p *dockerProc) Close() error {
	p.context()
	p.cancel()
	if p.logs != nil {
		_ = p.logs.Close()
	}
	for _, rd := range []io.Reader{p.out, p.err} {
		if c, ok := rd.(io.Closer); ok {
			_ = c.Close()
		}
	}
	return nil
}

// NixManifest implements NixManifestProcess.
func (p *dockerProc) NixManifest() []byte { return p.nixManifest }

func (p *dockerProc) Stdout() io.Reader { return p.out }
func (p *dockerProc) Stderr() io.Reader { return p.err }

func (p *dockerProc) signal(sig string) error {
	ctx, cancel := context.WithTimeout(context.Background(), controlTimeout)
	defer cancel()
	_, err := p.d.do(ctx, "POST", "/containers/"+p.id+"/kill?signal="+sig, nil, "", nil)
	if isStatus(err, 409) { // not running any more
		return nil
	}
	return err
}

func (p *dockerProc) Interrupt() error { return p.signal("SIGINT") }
func (p *dockerProc) Kill() error {
	err := p.signal("SIGKILL")
	p.context()
	p.cancel() // A lost /wait or attach connection must also be released.
	return err
}

func (p *dockerProc) remove() {
	ctx, cancel := context.WithTimeout(context.Background(), controlTimeout)
	defer cancel()
	_, _ = p.d.do(ctx, "DELETE", "/containers/"+p.id+"?force=1", nil, "", nil)
	if p.logs == nil {
		_ = p.Close()
	}
}

// waitRetries is how many times Wait re-attaches to a container after the
// long-poll fails at the transport (the socket dropped, e.g. across a Docker
// VM sleep). Removing the container then would kill a turn that is still fine.
const waitRetries = 3

var waitBackoff = time.Second

func (p *dockerProc) Wait() (int, error) {
	defer p.remove()
	var res struct{ StatusCode int }
	var err error
	for attempt := 0; ; attempt++ {
		_, err = p.d.do(p.context(), "POST", "/containers/"+p.id+"/wait", nil, "", &res)
		var de *dockerError
		if err == nil || errors.As(err, &de) || p.context().Err() != nil || attempt >= waitRetries {
			break // done, or the engine answered with an error retrying won't change
		}
		slog.Warn("docker wait failed; retrying", "container", p.id, "err", err)
		timer := time.NewTimer(waitBackoff << attempt)
		select {
		case <-timer.C:
		case <-p.context().Done():
		}
		timer.Stop()
	}
	if err != nil {
		return -1, err
	}
	// Even a failed turn may have rotated the Claude or Codex login: keep it first.
	p.keepRefreshedLogins()
	p.readNixManifest()
	if res.StatusCode != 0 && p.oomKilled() {
		return res.StatusCode, fmt.Errorf("the container ran out of memory (exit %d); raise RUNNER_MEMORY_MB or reduce what the run builds at once", res.StatusCode)
	}
	return res.StatusCode, nil
}

// oomKilled reports whether the kernel killed the container for its memory
// limit, which otherwise looks like any other SIGKILL (exit 137).
func (p *dockerProc) oomKilled() bool {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var info struct{ State struct{ OOMKilled bool } }
	if _, err := p.d.do(ctx, "GET", "/containers/"+p.id+"/json", nil, "", &info); err != nil {
		return false
	}
	return info.State.OOMKilled
}

// keepRefreshedLogins persists any Claude or Codex OAuth login rotated inside
// the container before it is removed. Both files are agent-writable, so only a
// strictly newer login validated by refreshed is saved.
func (p *dockerProc) keepRefreshedLogins() {
	p.keepRefreshedLogin(claudeAuthPath, p.claudeAuth, p.claudeScope, p.d.SaveClaudeAuth, chatmodels.ClaudeAuthRefreshed, "claude")
	p.keepRefreshedLogin(codexAuthPath, p.codexAuth, p.codexScope, p.d.SaveCodexAuth, chatmodels.CodexAuthRefreshed, "codex")
}

func (p *dockerProc) keepRefreshedLogin(relPath, current, scope string, save func(context.Context, string, string) error, refreshed func(string, string) bool, label string) {
	if current == "" || save == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	next, ok := p.d.refreshedAuthFile(ctx, p.id, relPath, current, refreshed)
	if !ok {
		return
	}
	if err := save(ctx, scope, next); err != nil {
		slog.Warn("save refreshed "+label+" login", "err", err)
	}
}

// readNixManifest keeps what the run's Nix profile holds, read from the
// stopped container like the Codex login, so the runner can add the tools the
// agent installed to the repository's test environment.
func (p *dockerProc) readNixManifest() {
	if p.d.NixVolume == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// ~/.nix-profile is a symlink into the store; the Engine resolves every
	// path element but the last inside the container's mounts.
	res, err := p.d.do(ctx, "GET", "/containers/"+p.id+"/archive?path="+url.QueryEscape(path.Join(homePath, ".nix-profile", "manifest.json")), nil, "", nil)
	if err != nil {
		return // no profile: the agent installed nothing
	}
	defer res.Body.Close()
	tr := tar.NewReader(res.Body)
	if _, err := tr.Next(); err != nil {
		return
	}
	b, err := io.ReadAll(io.LimitReader(tr, 1<<20))
	if err == nil {
		p.nixManifest = b
	}
}

// refreshedAuthFile reads relPath back out of a container and returns it only
// when valid(current, next) accepts it as a newer login.
func (d *Docker) refreshedAuthFile(ctx context.Context, id, relPath, current string, valid func(string, string) bool) (string, bool) {
	res, err := d.do(ctx, "GET", "/containers/"+id+"/archive?path="+url.QueryEscape(path.Join(homePath, relPath)), nil, "", nil)
	if err != nil {
		return "", false
	}
	defer res.Body.Close()
	tr := tar.NewReader(res.Body)
	if _, err := tr.Next(); err != nil {
		return "", false
	}
	next, err := io.ReadAll(io.LimitReader(tr, maxCodexAuth+1))
	if err != nil || len(next) > maxCodexAuth || !valid(current, string(next)) {
		return "", false
	}
	return string(next), true
}

func (d *Docker) refreshedCodexAuth(ctx context.Context, id, current string) (string, bool) {
	return d.refreshedAuthFile(ctx, id, codexAuthPath, current, chatmodels.CodexAuthRefreshed)
}

func (d *Docker) refreshedClaudeAuth(ctx context.Context, id, current string) (string, bool) {
	return d.refreshedAuthFile(ctx, id, claudeAuthPath, current, chatmodels.ClaudeAuthRefreshed)
}

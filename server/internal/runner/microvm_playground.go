package runner

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/playground"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

var _ PlaygroundBackend = (*MicroVM)(nil)

type activePlaygroundVM struct {
	id        uuid.UUID
	runID     string
	dir       string
	spec      playground.Spec
	vm        microvm.VM
	egress    *microvm.Egress
	addrs     map[string]string
	listeners []net.Listener
	logs      *playgroundLogHub
	stopMu    sync.Mutex
	stopped   bool
}

func (a *activePlaygroundVM) stop(ctx context.Context) {
	a.stopMu.Lock()
	if a.stopped {
		a.stopMu.Unlock()
		return
	}
	a.stopped = true
	a.stopMu.Unlock()

	if a.logs != nil {
		a.logs.close()
	}
	for _, ln := range a.listeners {
		_ = ln.Close()
	}
	if a.vm != nil {
		sctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		_ = a.vm.Stop(sctx)
		cancel()
	}
	if a.egress != nil {
		_ = a.egress.Close()
	}
	if a.dir != "" {
		_ = os.RemoveAll(a.dir)
	}
}

func (b *MicroVM) StackName() string                     { return "microvm" }
func (b *MicroVM) PlaygroundNetwork(id uuid.UUID) string { return playgroundNetwork(id) }
func (b *MicroVM) PullMissing(_ context.Context, _ string) (bool, error) {
	return false, nil
}

func (b *MicroVM) playgroundDir(id uuid.UUID) (string, error) {
	if b.StateDir == "" {
		return "", errors.New("microvm: StateDir is required")
	}
	return filepath.Join(b.StateDir, "playgrounds", id.String()), nil
}

func (b *MicroVM) StartPlayground(ctx context.Context, pg PlaygroundRun, step func(string)) (map[string]string, error) {
	if step == nil {
		step = func(string) {}
	}
	_ = b.StopPlayground(ctx, pg.ID)

	pgDir, err := b.playgroundDir(pg.ID)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(pgDir, 0o755); err != nil {
		return nil, err
	}

	ap := &activePlaygroundVM{
		id:    pg.ID,
		runID: pg.RunID,
		dir:   pgDir,
		spec:  pg.Spec,
		addrs: make(map[string]string),
		logs:  newPlaygroundLogHub(2000),
	}
	keep := false
	defer func() {
		if !keep {
			ap.stop(context.Background())
		}
	}()

	// Security invariant: never attach home.ext4 to a playground VM so /home/node
	// stays an empty tmpfs overlay isolated from harness OAuth credentials.
	drives := []microvm.DriveSpec{
		{Path: b.RootfsPath, ReadOnly: true},
	}
	var shares []microvm.VirtioFSSpec
	if hostDir, ok := b.hostWorkspacePath(pg.RunID); ok {
		shares = append(shares, microvm.VirtioFSSpec{Tag: "workspace", HostDir: hostDir, ReadOnly: false})
	} else {
		runDir, rerr := b.runDir(pg.RunID)
		if rerr != nil {
			return nil, rerr
		}
		parentWS := filepath.Join(runDir, "workspace.ext4")
		if _, serr := os.Stat(parentWS); serr != nil {
			return nil, fmt.Errorf("playground workspace missing for run %s: %w", pg.RunID, serr)
		}
		pgWS := filepath.Join(pgDir, "workspace.ext4")
		if cerr := cloneFile(parentWS, pgWS); cerr != nil {
			return nil, fmt.Errorf("clone workspace for playground: %w", cerr)
		}
		drives = append(drives, microvm.DriveSpec{Path: pgWS, ReadOnly: false})
	}

	if len(pg.Spec.Services) > 0 {
		dkrSz := b.TestDockerBytes
		if dkrSz <= 0 {
			dkrSz = dkrTemplateSize
		}
		tmpl, terr := b.ensureExt4Template(ctx, "dkr.ext4", dkrDiskLabel, dkrSz)
		if terr != nil {
			return nil, terr
		}
		pgDkr := filepath.Join(pgDir, "docker.ext4")
		if cerr := cloneFile(tmpl, pgDkr); cerr != nil {
			return nil, fmt.Errorf("clone docker disk for playground: %w", cerr)
		}
		drives = append(drives, microvm.DriveSpec{Path: pgDkr, ReadOnly: false})
	}
	if b.CacheStore != nil {
		drives = append(drives, b.CacheStore.LatestEROFSDrives()...)
	}

	eg := microvm.NewEgress(microvm.EgressConfig{
		Log:           b.logger(),
		CacheHandler:  b.cacheHandler(),
		Resolver:      b.Resolver,
		TestUpstreams: b.TestUpstreams,
	})
	ap.egress = eg

	cpus := b.CPUs
	if cpus <= 0 {
		cpus = 2
	}
	memMB := b.MemoryMB
	if memMB <= 0 {
		memMB = 2048
	}
	vm, err := b.Driver.Start(ctx, microvm.VMConfig{
		KernelPath:  b.KernelPath,
		CPUs:        cpus,
		MemoryBytes: uint64(memMB) << 20,
		Drives:      drives,
		Shares:      shares,
		Listeners:   eg.Listeners(),
	})
	if err != nil {
		return nil, fmt.Errorf("boot playground VM: %w", err)
	}
	ap.vm = vm
	client := vm.Client()
	b.trustNewVM(ctx, client)

	if wf, ok := b.nixConfFileWrite(); ok {
		if err := client.WriteFiles(ctx, []guestproto.FileWrite{wf}); err != nil {
			return nil, fmt.Errorf("configure playground nix: %w", err)
		}
	}

	if len(pg.Spec.Services) > 0 || len(pg.Spec.NixPackages) > 0 {
		step(startingStep(pg.Spec))
	}
	if len(pg.Spec.Services) > 0 {
		hc := &http.Client{
			Timeout: 5 * time.Minute,
			Transport: &http.Transport{
				DialContext: func(dctx context.Context, _, _ string) (net.Conn, error) {
					return vm.DialVSock(dctx, guestproto.PortDocker)
				},
			},
		}
		netName := "vesper-pg-" + playgroundKey(pg.ID)
		if _, err := b.startGuestServices(ctx, client, hc, netName, "pg-"+playgroundKey(pg.ID), pg.Spec.Services); err != nil {
			return nil, &PlaygroundError{Msg: err.Error(), Log: ap.logs.tailText(60)}
		}
	}

	baseEnv := dependencyEnv("/cache", workspacePath)
	baseEnv["HOME"] = homePath
	baseEnv["USER"] = "node"
	baseEnv["LOGNAME"] = "node"
	baseEnv["TMPDIR"] = "/tmp"
	baseEnv["GOCACHE"] = "/tmp/go-build"
	baseEnv["PATH"] = homePath + "/.nix-profile/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin"
	b.applyCacheEnv(baseEnv)
	b.applyTrustEnv(baseEnv)
	for k, v := range pg.Spec.Env {
		baseEnv[k] = v
	}

	if len(pg.Spec.NixPackages) > 0 {
		if err := b.runPlaygroundOneShot(ctx, client, ap.logs, playgroundTools, nixInstallScript(pg.Spec.NixPackages), baseEnv); err != nil {
			return nil, &PlaygroundError{
				Msg: "installing " + strings.Join(pg.Spec.NixPackages, ", ") + " " + err.Error(),
				Log: ap.logs.tailText(60),
			}
		}
	}
	if len(pg.Spec.Setup) > 0 {
		step("Running setup")
		if err := b.runPlaygroundOneShot(ctx, client, ap.logs, playgroundSetup, setupScript(pg.Spec.Setup), baseEnv); err != nil {
			return nil, &PlaygroundError{
				Msg: "setup " + err.Error(),
				Log: ap.logs.tailText(60),
			}
		}
	}

	var procNames []string
	for _, p := range pg.Spec.Processes {
		procNames = append(procNames, p.Name)
	}
	step("Starting " + joinAnd(procNames))

	type startedProc struct {
		spec   playground.Process
		rp     *guestproto.RemoteProcess
		exited chan error
	}
	procs := make(map[string]*startedProc, len(pg.Spec.Processes))
	for _, p := range pg.Spec.Processes {
		pEnv := make(map[string]string, len(baseEnv)+len(p.Env)+1)
		for k, v := range baseEnv {
			pEnv[k] = v
		}
		for k, v := range p.Env {
			pEnv[k] = v
		}
		if p.Port > 0 {
			pEnv["PORT"] = strconv.Itoa(p.Port)
		}
		dir := path.Join(pg.Spec.Directory, p.Dir)
		rp, serr := client.StartExec(ctx, guestproto.ExecReq{
			Argv: []string{"bash", "-c", processScript(dir, p.Command)},
			Env:  pEnv,
			Dir:  workspacePath,
			UID:  1000,
			GID:  1000,
		})
		if serr != nil {
			return nil, &PlaygroundError{Msg: fmt.Sprintf("start %s: %v", p.Name, serr), Log: ap.logs.tailText(60)}
		}
		sp := &startedProc{spec: p, rp: rp, exited: make(chan error, 1)}
		go streamPlaygroundPipe(ap.logs, p.Name, "stdout", rp.Stdout())
		go streamPlaygroundPipe(ap.logs, p.Name, "stderr", rp.Stderr())
		go func() {
			ex, werr := rp.Wait()
			if werr != nil {
				sp.exited <- werr
			} else {
				sp.exited <- fmt.Errorf("exited with code %d", ex.Code)
			}
			close(sp.exited)
		}()
		procs[p.Name] = sp
	}

	for _, p := range pg.Spec.Processes {
		if p.Background() {
			continue
		}
		step(fmt.Sprintf("Waiting for %s on :%d", p.Name, p.Port))
		if err := waitGuestPortListening(ctx, client, uint16(p.Port), procs[p.Name].exited); err != nil {
			return nil, &PlaygroundError{Msg: fmt.Sprintf("%s %v", p.Name, err), Log: ap.logs.tailText(60)}
		}
		ln, lerr := net.Listen("tcp", "127.0.0.1:0")
		if lerr != nil {
			return nil, lerr
		}
		ap.listeners = append(ap.listeners, ln)
		ap.addrs[p.Name] = ln.Addr().String()
		go servePlaygroundPortForward(ln, vm, uint16(p.Port))
	}

	for _, p := range pg.Spec.Processes {
		if !p.Background() {
			continue
		}
		step("Checking " + p.Name)
		timer := time.NewTimer(PlaygroundBackgroundGrace)
		select {
		case exitErr := <-procs[p.Name].exited:
			timer.Stop()
			return nil, &PlaygroundError{Msg: fmt.Sprintf("%s %v", p.Name, exitErr), Log: ap.logs.tailText(60)}
		case <-timer.C:
		case <-ctx.Done():
			timer.Stop()
			return nil, ctx.Err()
		}
	}

	if p, ok := pg.Spec.Route("/"); ok && !p.Background() {
		step("Loading " + p.Name + "'s first page")
		warmUpPlaygroundRoute(ctx, ap.addrs[p.Name])
	}

	b.pgMu.Lock()
	if b.playgrounds == nil {
		b.playgrounds = make(map[uuid.UUID]*activePlaygroundVM)
	}
	b.playgrounds[pg.ID] = ap
	b.pgMu.Unlock()
	keep = true
	return ap.addrs, nil
}

func (b *MicroVM) runPlaygroundOneShot(ctx context.Context, client *guestproto.Client, hub *playgroundLogHub, source, script string, env map[string]string) error {
	sctx, cancel := context.WithTimeout(ctx, PlaygroundSetupTimeout)
	defer cancel()
	rp, err := client.StartExec(sctx, guestproto.ExecReq{
		Argv: []string{"bash", "-c", script},
		Env:  env,
		Dir:  workspacePath,
		UID:  1000,
		GID:  1000,
	})
	if err != nil {
		return err
	}
	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); streamPlaygroundPipe(hub, source, "stdout", rp.Stdout()) }()
	go func() { defer wg.Done(); streamPlaygroundPipe(hub, source, "stderr", rp.Stderr()) }()
	wg.Wait()
	ex, werr := rp.Wait()
	if werr != nil {
		if errors.Is(sctx.Err(), context.DeadlineExceeded) {
			return fmt.Errorf("took longer than %s", PlaygroundSetupTimeout)
		}
		return werr
	}
	if ex.Code != 0 {
		return fmt.Errorf("exited with code %d", ex.Code)
	}
	return nil
}

func waitGuestPortListening(ctx context.Context, client *guestproto.Client, port uint16, exited <-chan error) error {
	wctx, cancel := context.WithTimeout(ctx, PlaygroundReadyTimeout)
	defer cancel()
	for {
		pctx, pcancel := context.WithTimeout(wctx, time.Second)
		listening, err := client.CheckTCPPort(pctx, port)
		pcancel()
		if err == nil && listening {
			return nil
		}
		select {
		case exitErr := <-exited:
			return fmt.Errorf("%v before listening on its port", exitErr)
		case <-wctx.Done():
			if errors.Is(wctx.Err(), context.DeadlineExceeded) {
				return fmt.Errorf("wasn't listening on 0.0.0.0:%d after %s", port, PlaygroundReadyTimeout)
			}
			return wctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func servePlaygroundPortForward(ln net.Listener, vm microvm.VM, guestPort uint16) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer conn.Close()
			dctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			vconn, derr := vm.DialVSock(dctx, guestproto.PortPlayground)
			cancel()
			if derr != nil {
				return
			}
			defer vconn.Close()
			if herr := guestproto.WritePlaygroundHeader(vconn, guestPort); herr != nil {
				return
			}
			var wg sync.WaitGroup
			wg.Add(2)
			go func() {
				defer wg.Done()
				_, _ = io.Copy(vconn, conn)
				if cw, ok := vconn.(interface{ CloseWrite() error }); ok {
					_ = cw.CloseWrite()
				}
			}()
			go func() {
				defer wg.Done()
				_, _ = io.Copy(conn, vconn)
				if tc, ok := conn.(*net.TCPConn); ok {
					_ = tc.CloseWrite()
				}
			}()
			wg.Wait()
		}()
	}
}

func warmUpPlaygroundRoute(ctx context.Context, addr string) {
	wctx, cancel := context.WithTimeout(ctx, PlaygroundWarmUpTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(wctx, http.MethodGet, "http://"+addr+"/", nil)
	if err != nil {
		return
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return
	}
	_, _ = io.Copy(io.Discard, res.Body)
	res.Body.Close()
}

func (b *MicroVM) StopPlayground(ctx context.Context, id uuid.UUID) error {
	b.pgMu.Lock()
	ap := b.playgrounds[id]
	if ap != nil {
		delete(b.playgrounds, id)
	}
	b.pgMu.Unlock()
	if ap != nil {
		ap.stop(ctx)
		return nil
	}
	if dir, err := b.playgroundDir(id); err == nil {
		_ = os.RemoveAll(dir)
	}
	return nil
}

func (b *MicroVM) RunningPlaygrounds(_ context.Context) ([]uuid.UUID, error) {
	b.pgMu.Lock()
	defer b.pgMu.Unlock()
	ids := make([]uuid.UUID, 0, len(b.playgrounds))
	for id := range b.playgrounds {
		ids = append(ids, id)
	}
	return ids, nil
}

func (b *MicroVM) ReadFile(ctx context.Context, id uuid.UUID, rel string) ([]byte, error) {
	b.pgMu.Lock()
	ap := b.playgrounds[id]
	b.pgMu.Unlock()
	if ap == nil || ap.vm == nil {
		return nil, errors.New("the playground isn't running")
	}
	clean := path.Clean("/" + rel)
	if strings.Contains(rel, "..") {
		return nil, fmt.Errorf("invalid path %q", rel)
	}
	target := workspacePath
	if trimmed := strings.TrimPrefix(clean, "/"); trimmed != "" {
		target = path.Join(workspacePath, trimmed)
	}
	return ap.vm.Client().ReadFile(ctx, target, playground.MaxSpecBytes+1)
}

func (b *MicroVM) Logs(ctx context.Context, id uuid.UUID, tail int, follow bool, emit func(playground.LogLine) error) error {
	b.pgMu.Lock()
	ap := b.playgrounds[id]
	b.pgMu.Unlock()
	if ap == nil || ap.logs == nil {
		return errors.New("the playground isn't running")
	}
	return ap.logs.stream(ctx, tail, follow, emit)
}

func (b *MicroVM) cleanupPlaygrounds(ctx context.Context) {
	b.pgMu.Lock()
	list := make([]*activePlaygroundVM, 0, len(b.playgrounds))
	for id, ap := range b.playgrounds {
		list = append(list, ap)
		delete(b.playgrounds, id)
	}
	b.pgMu.Unlock()
	for _, ap := range list {
		ap.stop(ctx)
	}
}

func (b *MicroVM) attachPlaygroundProxy(spec ExecSpec, env map[string]string, eg *microvm.Egress) bool {
	if eg == nil || len(spec.Networks) == 0 {
		return false
	}
	var pgNet string
	for _, n := range spec.Networks {
		if strings.HasPrefix(n, "lazyagents-play-") {
			pgNet = n
			break
		}
	}
	if pgNet == "" {
		return false
	}

	// If Runner set PLAYGROUND_URL=http://playground:<gatewayPort>, proxy playground.vesper.internal -> 127.0.0.1:<gatewayPort>.
	if rawURL := env["PLAYGROUND_URL"]; rawURL != "" {
		if u, err := url.Parse(rawURL); err == nil && strings.EqualFold(u.Hostname(), PlaygroundHost) && u.Port() != "" {
			target, _ := url.Parse("http://127.0.0.1:" + u.Port())
			eg.SetPlaygroundHandler(httputil.NewSingleHostReverseProxy(target))
			oldBase := u.Scheme + "://" + u.Host
			newBase := "http://" + microvm.InternalPlaygroundHost
			env["PLAYGROUND_URL"] = strings.Replace(rawURL, oldBase, newBase, 1)
			if enter := env["PLAYGROUND_ENTER_URL"]; enter != "" {
				env["PLAYGROUND_ENTER_URL"] = strings.Replace(enter, oldBase, newBase, 1)
			}
			return true
		}
	}

	b.pgMu.Lock()
	var matched *activePlaygroundVM
	for _, ap := range b.playgrounds {
		if playgroundNetwork(ap.id) == pgNet {
			matched = ap
			break
		}
	}
	b.pgMu.Unlock()
	if matched == nil {
		return false
	}
	h := matched.reverseProxy()
	if h == nil {
		return false
	}
	eg.SetPlaygroundHandler(h)
	if env["PLAYGROUND_URL"] == "" {
		env["PLAYGROUND_URL"] = "http://" + microvm.InternalPlaygroundHost
	}
	return true
}

func (a *activePlaygroundVM) reverseProxy() http.Handler {
	type routeProxy struct {
		prefix string
		proxy  http.Handler
	}
	var routes []routeProxy
	for _, rt := range a.spec.Routes {
		if addr := a.addrs[rt.Process]; addr != "" {
			if u, err := url.Parse("http://" + addr); err == nil {
				routes = append(routes, routeProxy{prefix: rt.Path, proxy: httputil.NewSingleHostReverseProxy(u)})
			}
		}
	}
	sort.SliceStable(routes, func(i, j int) bool {
		return len(routes[i].prefix) > len(routes[j].prefix)
	})
	var fallback http.Handler
	for _, p := range a.spec.Processes {
		if addr := a.addrs[p.Name]; addr != "" {
			if u, err := url.Parse("http://" + addr); err == nil {
				fallback = httputil.NewSingleHostReverseProxy(u)
				break
			}
		}
	}
	if fallback == nil && len(routes) == 0 {
		return nil
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		for _, rt := range routes {
			if r.URL.Path == rt.prefix || strings.HasPrefix(r.URL.Path, strings.TrimRight(rt.prefix, "/")+"/") || rt.prefix == "/" {
				rt.proxy.ServeHTTP(w, r)
				return
			}
		}
		if fallback != nil {
			fallback.ServeHTTP(w, r)
			return
		}
		http.NotFound(w, r)
	})
}

type playgroundLogHub struct {
	mu      sync.Mutex
	max     int
	lines   []playground.LogLine
	closed  bool
	subs    map[chan playground.LogLine]struct{}
	doneCh  chan struct{}
	closeDo sync.Once
}

func newPlaygroundLogHub(max int) *playgroundLogHub {
	if max <= 0 {
		max = 1000
	}
	return &playgroundLogHub{
		max:    max,
		subs:   make(map[chan playground.LogLine]struct{}),
		doneCh: make(chan struct{}),
	}
}

func (h *playgroundLogHub) add(l playground.LogLine) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.lines) >= h.max {
		copy(h.lines, h.lines[1:])
		h.lines[len(h.lines)-1] = l
	} else {
		h.lines = append(h.lines, l)
	}
	for ch := range h.subs {
		select {
		case ch <- l:
		default:
		}
	}
}

func (h *playgroundLogHub) close() {
	h.closeDo.Do(func() {
		h.mu.Lock()
		h.closed = true
		close(h.doneCh)
		for ch := range h.subs {
			delete(h.subs, ch)
			close(ch)
		}
		h.mu.Unlock()
	})
}

func (h *playgroundLogHub) tailText(n int) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	if n <= 0 || len(h.lines) == 0 {
		return ""
	}
	start := len(h.lines) - n
	if start < 0 {
		start = 0
	}
	var b strings.Builder
	for i := start; i < len(h.lines); i++ {
		if i > start {
			b.WriteByte('\n')
		}
		b.WriteString(h.lines[i].Text)
	}
	return strings.TrimSpace(b.String())
}

func (h *playgroundLogHub) stream(ctx context.Context, tail int, follow bool, emit func(playground.LogLine) error) error {
	h.mu.Lock()
	var snap []playground.LogLine
	if tail > 0 && len(h.lines) > 0 {
		start := len(h.lines) - tail
		if start < 0 {
			start = 0
		}
		snap = append([]playground.LogLine(nil), h.lines[start:]...)
	}
	var ch chan playground.LogLine
	if follow && !h.closed {
		ch = make(chan playground.LogLine, 128)
		h.subs[ch] = struct{}{}
	}
	h.mu.Unlock()

	if ch != nil {
		defer func() {
			h.mu.Lock()
			if _, ok := h.subs[ch]; ok {
				delete(h.subs, ch)
				close(ch)
			}
			h.mu.Unlock()
		}()
	}

	for _, l := range snap {
		if err := emit(l); err != nil {
			return err
		}
	}
	if !follow || ch == nil {
		return nil
	}
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-h.doneCh:
			return nil
		case l, ok := <-ch:
			if !ok {
				return nil
			}
			if err := emit(l); err != nil {
				return err
			}
		}
	}
}

func streamPlaygroundPipe(hub *playgroundLogHub, source, streamName string, r io.Reader) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		hub.add(playground.LogLine{
			Time:   time.Now().UTC(),
			Source: source,
			Stream: streamName,
			Text:   sc.Text(),
		})
	}
	_, _ = io.Copy(io.Discard, r)
}

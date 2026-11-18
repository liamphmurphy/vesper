package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/githubpr"
	"github.com/liamphmurphy/vesper/server/internal/httpapi"
	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/metrics"
	"github.com/liamphmurphy/vesper/server/internal/pgembed"
	"github.com/liamphmurphy/vesper/server/internal/prsync"
	"github.com/liamphmurphy/vesper/server/internal/realtime"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/transcript"
	"github.com/liamphmurphy/vesper/server/internal/usage"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

type appRuntimeMetadata struct {
	URL         string `json:"url"`
	DatabaseURL string `json:"databaseUrl"`
	PID         int    `json:"pid"`
}

func runApp(ctx context.Context, log *slog.Logger, args []string) error {
	// Security invariant: desktop mode never disables session cookies.
	if v := strings.TrimSpace(os.Getenv("VESPER_NO_SIGNIN")); v != "" && v != "0" && strings.ToLower(v) != "false" {
		return errors.New("vesper app refuses VESPER_NO_SIGNIN: authenticated browser sessions are required")
	}

	secretsKey := strings.TrimSpace(os.Getenv("SECRETS_KEY"))
	box, err := secrets.NewBox(secretsKey)
	if err != nil {
		return fmt.Errorf("vesper app invalid SECRETS_KEY: %w", err)
	}
	if box == nil {
		return errors.New("vesper app requires a 32-byte base64 SECRETS_KEY")
	}

	fs := flag.NewFlagSet("app", flag.ContinueOnError)
	defaultData := defaultAppDataDir()
	dataDirFlag := fs.String("data-dir", envOr("VESPER_APP_DATA_DIR", defaultData), "persistent Vesper desktop data directory")
	addrFlag := fs.String("addr", envOr("VESPER_APP_ADDR", "127.0.0.1:8080"), "loopback listen address for Vesper app")
	if err := fs.Parse(args); err != nil {
		return err
	}

	dataDir := *dataDirFlag
	if dataDir == "" {
		return errors.New("vesper app: data-dir is required")
	}
	if !isLoopbackHostPort(*addrFlag) {
		return fmt.Errorf("vesper app refuses non-loopback addr %q", *addrFlag)
	}

	for _, sub := range []string{"postgres", "blobs", "images", "vm", "logs"} {
		if err := os.MkdirAll(filepath.Join(dataDir, sub), 0o755); err != nil {
			return err
		}
	}

	exeDir := ""
	if exe, eerr := os.Executable(); eerr == nil {
		exeDir = filepath.Dir(exe)
	}

	pgBinDir := strings.TrimSpace(os.Getenv("VESPER_POSTGRES_BIN_DIR"))
	if pgBinDir == "" && exeDir != "" {
		cand := filepath.Join(exeDir, "..", "postgres", "bin")
		if st, serr := os.Stat(filepath.Join(cand, "postgres")); serr == nil && !st.IsDir() {
			pgBinDir = cand
		}
	}

	pgCluster, err := pgembed.Start(ctx, pgembed.Config{
		BinDir:   pgBinDir,
		DataDir:  filepath.Join(dataDir, "postgres"),
		Database: "vesper",
		User:     "vesper",
		LogPath:  filepath.Join(dataDir, "logs", "postgres.log"),
		Log:      log,
	})
	if err != nil {
		return fmt.Errorf("embedded postgres: %w", err)
	}
	defer func() {
		sctx, scancel := context.WithTimeout(context.Background(), 10*time.Second)
		_ = pgCluster.Stop(sctx)
		scancel()
	}()

	poolCtx, poolCancel := context.WithTimeout(ctx, 60*time.Second)
	pool, err := db.Open(poolCtx, pgCluster.DSN())
	poolCancel()
	if err != nil {
		return err
	}
	defer pool.Close()

	migCtx, migCancel := context.WithTimeout(ctx, 60*time.Second)
	err = db.Migrate(migCtx, pool)
	migCancel()
	if err != nil {
		return err
	}

	blobCfg := config.Blob{
		Dir:            filepath.Join(dataDir, "blobs"),
		ArtifactBucket: envOr("BLOB_ARTIFACT_BUCKET", "artifacts"),
	}
	blobs := blob.New(blobCfg)
	if err := blobs.EnsureBuckets(ctx); err != nil {
		return err
	}

	arts := &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: blobCfg.ArtifactBucket}
	localName := envOr("LOCAL_USER_NAME", "Local user")
	localEmail := envOr("LOCAL_USER_EMAIL", "me@localhost")
	if _, err := seed.Run(ctx, pool, seed.Options{
		Demo:      false,
		UserName:  localName,
		UserEmail: localEmail,
		Artifacts: arts,
	}); err != nil {
		return fmt.Errorf("seed: %w", err)
	}

	// Seal onboarding claim immediately BEFORE opening the HTTP listener so
	// unauthenticated requests cannot claim the workspace.
	if _, err := pool.Exec(ctx, `UPDATE users SET claimed_at = COALESCE(claimed_at, now())`); err != nil {
		return fmt.Errorf("seal local user claim: %w", err)
	}

	ln, err := net.Listen("tcp", *addrFlag)
	if err != nil {
		return fmt.Errorf("listen %s: %w", *addrFlag, err)
	}
	baseURL := "http://" + ln.Addr().String()

	runtimePath := filepath.Join(dataDir, "runtime.json")
	rtBytes, _ := json.MarshalIndent(appRuntimeMetadata{
		URL:         baseURL,
		DatabaseURL: pgCluster.DSN(),
		PID:         os.Getpid(),
	}, "", "  ")
	if err := os.WriteFile(runtimePath, append(rtBytes, '\n'), 0o600); err != nil {
		_ = ln.Close()
		return err
	}
	defer func() { _ = os.Remove(runtimePath) }()

	designToken := randomHex16()
	webDistDir := resolveWebDistDir(exeDir)
	var webHandler http.Handler
	var designWorkerURL string
	if webDistDir != "" {
		// The UI is a static build Go serves itself; node runs only the design worker beside it.
		webHandler = staticSPAHandler(webDistDir)
		workerPort, stopFn, werr := startDesignWorker(ctx, log, webDistDir, designToken, filepath.Join(dataDir, "logs", "design-worker.log"))
		if werr != nil {
			_ = ln.Close()
			return fmt.Errorf("start design worker: %w", werr)
		}
		defer stopFn()
		designWorkerURL = fmt.Sprintf("http://127.0.0.1:%d/internal/designs", workerPort)
	}

	jobs, err := metrics.NewClient(pool, log)
	if err != nil {
		_ = ln.Close()
		return err
	}
	if err := jobs.Start(ctx); err != nil {
		_ = ln.Close()
		return err
	}
	defer func() {
		jctx, jcancel := context.WithTimeout(context.Background(), 10*time.Second)
		_ = jobs.Stop(jctx)
		jcancel()
	}()

	q := store.New(pool)
	secretsSvc := &secrets.Service{Q: q, Box: box}
	trackerSvc := &tracker.Service{Pool: pool}
	events := realtime.New()
	go events.Run(ctx, pool)

	cfg, err := config.Load()
	if err != nil {
		_ = ln.Close()
		return err
	}
	appCfg := cfg
	appCfg.DatabaseURL = pgCluster.DSN()
	appCfg.Blob = blobCfg
	appCfg.SecretsKey = secretsKey
	appCfg.PublicURL = baseURL
	appCfg.WebURL = baseURL

	var runnerStarting atomic.Bool
	disableRunner := os.Getenv("VESPER_APP_DISABLE_RUNNER") == "1"
	if !disableRunner {
		runnerStarting.Store(true)
	}

	version := appCfg.Version
	srv := &httpapi.Server{
		AnonymousAPI: false,
		Events:       events,
		Version:      version,
		Checks:       map[string]httpapi.Pinger{"postgres": pool, "s3": blobs},
		Pool:         pool,
		Q:            q,
		Tracker:      trackerSvc,
		Artifacts:    arts,
		Agents:       &agents.Service{Pool: pool},
		Secrets:      secretsSvc,
		Runs: &runs.Service{
			Pool:                  pool,
			Secrets:               secretsSvc,
			Artifacts:             arts,
			Tracker:               trackerSvc,
			RequireHarnessKey:     true,
			PlanModels:            (&chatmodels.QueuedListings{Pool: pool}).Models,
			Transcripts:           transcript.Shared,
			RolloverContextTokens: int64(appCfg.RolloverContextTokens),
		},
		Wiki:           &wiki.Service{Pool: pool, Artifacts: arts, Tracker: trackerSvc},
		PublicURL:      baseURL,
		Blobs:          blobs,
		ArtifactBucket: blobCfg.ArtifactBucket,
		DesignWorker:   &designs.Worker{URL: designWorkerURL, Token: designToken},
		Log:            log,
		Usage:          &usage.Service{Q: q, Log: log, Queued: true},
		Exporter:       exporter(appCfg, pool, log),
		DriveBackups:   driveBackupRunner(appCfg, pool, box, apiHolder(), log),
		RunnerStarting: runnerStarting.Load,
	}
	go srv.Wiki.RunVaultWorker(ctx, log)
	if appCfg.PRSyncInterval > 0 {
		prSyncer := &prsync.Syncer{Pool: pool, Secrets: secretsSvc, Tracker: trackerSvc, Log: log, MinAge: time.Duration(appCfg.PRSyncInterval) * time.Second}
		go prSyncer.Run(ctx, time.Duration(appCfg.PRSyncInterval)*time.Second)
		approvals := &githubpr.ApprovalSyncer{Queries: q, Secrets: secretsSvc, GitHub: &githubpr.Service{BaseURL: srv.GitHubAPIURL}, Log: log}
		go approvals.Run(ctx, time.Duration(appCfg.PRSyncInterval)*time.Second)
	}
	if appCfg.MemoryConsolidateInterval > 0 {
		go memory.RunConsolidation(ctx, q, log, time.Duration(appCfg.MemoryConsolidateInterval)*time.Second)
	}

	imgMgr := NewImageManager()
	apiHandler := srv.Handler()
	// Only the outer listener checks Host: microVMs reach apiHandler in-process as
	// api.vesper.internal, which is not a loopback name.
	topHandler := loopbackHostOnly(buildAppMux(apiHandler, webHandler, imgMgr), ln.Addr().(*net.TCPAddr).Port)

	hs := &http.Server{
		Handler:           topHandler,
		ReadHeaderTimeout: 10 * time.Second,
	}
	errc := make(chan error, 1)
	go func() { errc <- hs.Serve(ln) }()

	var runnerDone chan error
	if !disableRunner {
		runnerDone = make(chan error, 1)
		go func() {
			defer runnerStarting.Store(false)
			runnerDone <- runAppMicroVMRunner(ctx, log, dataDir, exeDir, baseURL, designWorkerURL, designToken, pool, blobs, box, blobCfg.ArtifactBucket, appCfg, apiHandler, imgMgr, func() {
				runnerStarting.Store(false)
			})
		}()
	}

	// The native shell asks for a one-time sign-in code on stdout (its own pipe), so it can
	// sign its web view in without reading runtime.json or running sign-in-link.
	if os.Getenv("VESPER_APP_SIGN_IN_CODE") == "stdout" {
		code, cerr := auth.NewSignInCode(ctx, q)
		if cerr != nil {
			return fmt.Errorf("sign-in code: %w", cerr)
		}
		fmt.Printf("VESPER_SIGN_IN_CODE=%s\n", code)
	}
	fmt.Printf("VESPER_READY_URL=%s\n", baseURL)
	log.Info("vesper app ready", "url", baseURL, "data_dir", dataDir, "web_dir", webDistDir)

	var serveErr error
	select {
	case err := <-errc:
		if !errors.Is(err, http.ErrServerClosed) {
			serveErr = err
		}
	case <-ctx.Done():
	}

	sctx, scancel := context.WithTimeout(context.Background(), 10*time.Second)
	if serr := hs.Shutdown(sctx); serr != nil && serveErr == nil {
		serveErr = serr
	}
	scancel()
	bctx, bcancel := context.WithTimeout(context.Background(), 5*time.Second)
	if berr := srv.DriveBackups.Shutdown(bctx); berr != nil {
		log.Warn("drive backups still running at exit", "err", berr)
	}
	bcancel()
	if runnerDone != nil {
		select {
		case <-runnerDone:
		case <-time.After(15 * time.Second):
		}
	}
	return serveErr
}

func buildAppMux(apiHandler, webHandler http.Handler, imgMgr *ImageManager) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if p == "/internal" || strings.HasPrefix(p, "/internal/") {
			http.NotFound(w, r)
			return
		}
		if p == "/api/v1/system/vm-image" && r.Method == http.MethodGet && imgMgr != nil {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(imgMgr.Status())
			return
		}
		if strings.HasPrefix(p, "/api/") || p == "/mcp" || strings.HasPrefix(p, "/mcp/") || p == "/events" {
			apiHandler.ServeHTTP(w, r)
			return
		}
		if webHandler != nil {
			webHandler.ServeHTTP(w, r)
			return
		}
		http.NotFound(w, r)
	})
}

// loopbackHostOnly refuses requests whose Host isn't a loopback name for this
// listener's port. A page on another site that rebinds its DNS to 127.0.0.1
// still sends its own Host, so it can't reach the API or the UI through it.
func loopbackHostOnly(next http.Handler, port int) http.Handler {
	p := strconv.Itoa(port)
	allowed := map[string]bool{
		net.JoinHostPort("127.0.0.1", p): true,
		net.JoinHostPort("localhost", p): true,
		net.JoinHostPort("::1", p):       true,
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !allowed[strings.ToLower(r.Host)] {
			http.Error(w, "unknown host", http.StatusMisdirectedRequest)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func runAppMicroVMRunner(
	ctx context.Context,
	log *slog.Logger,
	dataDir, exeDir, baseURL, designWorkerURL, designToken string,
	pool *pgxpool.Pool,
	blobs *blob.Store,
	box *secrets.Box,
	artifactBucket string,
	cfg config.Config,
	apiHandler http.Handler,
	imgMgr *ImageManager,
	onHeartbeat func(),
) error {
	kernel := ResolveKernelPath(cfg.Runner.KernelPath, dataDir, exeDir)
	if kernel == "" {
		log.Warn("vesper app microvm kernel missing; runner inactive")
		return nil
	}
	rootfs, err := imgMgr.EnsureRootfs(ctx, cfg.Runner.RootfsPath, dataDir, os.Getenv("VESPER_IMAGE_SOURCE_DIR"), exeDir)
	if err != nil {
		log.Warn("vesper app rootfs unavailable; runner inactive", "err", err)
		return nil
	}

	vmDir := filepath.Join(dataDir, "vm")
	var cacheStore *microvm.CacheStore
	if cs, cerr := microvm.NewCacheStore(microvm.CacheStoreConfig{Dir: filepath.Join(vmDir, "caches")}); cerr == nil {
		cacheStore = cs
	} else {
		log.Warn("vesper app cache store disabled", "err", cerr)
	}

	secretStore := &secrets.Service{Q: store.New(pool), Box: box}
	saveClaude, saveCodex := buildAuthSavers(secretStore)
	m := &runner.MicroVM{
		Driver:         microvm.NewVZDriver(),
		StateDir:       vmDir,
		KernelPath:     kernel,
		RootfsPath:     rootfs,
		HostWorkspaces: cfg.Runner.HostWorkspaces,
		CPUs:           cfg.Runner.CPUs,
		MemoryMB:       cfg.Runner.MemoryMB,
		PidsLimit:      cfg.Runner.PidsLimit,
		WarmTTL:        cfg.Runner.WarmTTL,
		SpareVMs:       cfg.Runner.SpareVMs,
		MCPURL:         "http://" + microvm.InternalAPIHost + "/mcp",
		APIHandler:     apiHandler,
		APIUpstream:    baseURL,
		CacheStore:     cacheStore,
		SaveClaudeAuth: saveClaude,
		SaveCodexAuth:  saveCodex,
		Log:            log,
	}
	defer func() { _ = m.Close() }()

	host, _ := os.Hostname()
	arts := &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: artifactBucket}
	workflows := runs.NewWorkflowEngine(pool, arts, &tracker.Service{Pool: pool})
	workflows.Catalog = chatmodels.Catalog{
		RequireKey: true,
		Secrets:    secretStore,
		PlanModels: (&chatmodels.QueuedListings{Pool: pool}).Models,
	}
	r := &runner.Runner{
		Cfg: runner.Config{
			ModelPrices:           cfg.Runner.ModelPrices,
			ID:                    fmt.Sprintf("%s-app-%d", host, os.Getpid()),
			MaxConcurrent:         cfg.Runner.MaxConcurrent,
			MCPURL:                "http://" + microvm.InternalAPIHost + "/mcp",
			Grace:                 30 * time.Second,
			LogBucket:             "run-logs",
			AttachmentBucket:      artifactBucket,
			Version:               cfg.Version,
			RequireHarnessKey:     true,
			ChatIdleTTL:           cfg.Runner.ChatIdleTTL,
			MaxHold:               cfg.Runner.MaxHold,
			MaxHoldAttempts:       cfg.Runner.MaxHoldAttempts,
			RolloverContextTokens: int64(cfg.RolloverContextTokens),
			RepoMap:               cfg.Runner.RepoMap,
			Playgrounds: runner.PlaygroundConfig{
				Ports:   appPlaygroundPorts(cfg.Runner.PlaygroundPorts),
				Host:    "127.0.0.1",
				IdleTTL: cfg.Runner.PlaygroundIdleTTL,
				// The window loads localhost; baseURL is the 127.0.0.1 listener.
				Origins: origins(baseURL, localhostURL(baseURL)),
			},
		},
		Pool:        pool,
		Backend:     m,
		Secrets:     secretStore,
		Tracker:     &tracker.Service{Pool: pool},
		Blobs:       blobs,
		Attachments: blobs,
		Log:         log,
		Workflows:   workflows,
		Designs:     &designs.Service{Pool: pool, Worker: &designs.Worker{URL: designWorkerURL, Token: designToken}, Blobs: blobs, Bucket: artifactBucket},
		Scheduled: &runs.Service{
			Pool:                  pool,
			Secrets:               secretStore,
			Tracker:               &tracker.Service{Pool: pool},
			Artifacts:             arts,
			RequireHarnessKey:     true,
			PlanModels:            (&chatmodels.QueuedListings{Pool: pool}).Models,
			RolloverContextTokens: int64(cfg.RolloverContextTokens),
		},
		DriveBackups: driveBackupRunner(cfg, pool, box, fmt.Sprintf("%s-app-%d", host, os.Getpid()), log),
		StoreSecret: func(ctx context.Context, ws, by uuid.UUID, name, value string) error {
			_, err := secretStore.Set(ctx, ws, by, secrets.SetInput{Name: name, Value: value})
			return err
		},
		OnHeartbeat: onHeartbeat,
	}
	log.Info("vesper app microvm runner started", "kernel", kernel, "rootfs", rootfs)
	return r.Run(ctx)
}

// startDesignWorker runs the bundled design worker (web/design-worker/server.mjs, bundled by
// web/scripts/build-design-worker.mjs) on a free loopback port with node, and waits until it listens.
func startDesignWorker(ctx context.Context, log *slog.Logger, webDir, designToken, logPath string) (int, func(), error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, nil, err
	}
	port := ln.Addr().(*net.TCPAddr).Port
	_ = ln.Close()

	nodeBin := strings.TrimSpace(os.Getenv("VESPER_NODE_BIN"))
	if nodeBin == "" {
		var lerr error
		nodeBin, lerr = exec.LookPath("node")
		if lerr != nil {
			return 0, nil, fmt.Errorf("node binary not found (set VESPER_NODE_BIN): %w", lerr)
		}
	}

	serverJS := filepath.Join(webDir, "design-worker", "server.mjs")
	cmd := exec.Command(nodeBin, serverJS)
	cmd.Dir = webDir
	cmd.Env = []string{
		"PATH=" + os.Getenv("PATH"),
		"HOME=" + os.Getenv("HOME"),
		"NODE_ENV=production",
		"HOSTNAME=127.0.0.1",
		"PORT=" + strconv.Itoa(port),
		"DESIGN_WORKER_TOKEN=" + designToken,
	}
	if os.Getenv("VESPER_NODE_RUN_AS_NODE") == "1" {
		cmd.Env = append(cmd.Env, "ELECTRON_RUN_AS_NODE=1")
	}

	var lf *os.File
	if logPath != "" {
		if f, oerr := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644); oerr == nil {
			lf = f
			cmd.Stdout = f
			cmd.Stderr = f
		}
	}
	if lf == nil {
		cmd.Stdout = io.Discard
		cmd.Stderr = io.Discard
	}

	if err := cmd.Start(); err != nil {
		if lf != nil {
			_ = lf.Close()
		}
		return 0, nil, err
	}
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		if lf != nil {
			_ = lf.Close()
		}
		close(done)
	}()

	wctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	for {
		c, derr := (&net.Dialer{Timeout: 250 * time.Millisecond}).DialContext(wctx, "tcp", addr)
		if derr == nil {
			_ = c.Close()
			break
		}
		select {
		case <-done:
			return 0, nil, errors.New("design worker exited prematurely")
		case <-wctx.Done():
			_ = cmd.Process.Kill()
			return 0, nil, fmt.Errorf("design worker did not listen: %w", wctx.Err())
		case <-time.After(50 * time.Millisecond):
		}
	}

	stopFn := func() {
		if cmd.Process == nil {
			return
		}
		_ = cmd.Process.Signal(os.Interrupt)
		select {
		case <-done:
		case <-time.After(3 * time.Second):
			_ = cmd.Process.Kill()
			<-done
		}
	}
	return port, stopFn, nil
}

func resolveWebDistDir(exeDir string) string {
	var cands []string
	if d := strings.TrimSpace(os.Getenv("VESPER_WEB_DIST_DIR")); d != "" {
		cands = append(cands, d)
	}
	if exeDir != "" {
		cands = append(cands,
			filepath.Join(exeDir, "..", "web"),
			filepath.Join(exeDir, "web"),
		)
	}
	for _, c := range cands {
		if st, err := os.Stat(filepath.Join(c, "index.html")); err == nil && !st.IsDir() {
			return c
		}
	}
	return ""
}

func defaultAppDataDir() string {
	home, err := os.UserHomeDir()
	if err == nil && runtime.GOOS == "darwin" {
		return filepath.Join(home, "Library", "Application Support", "Vesper")
	}
	if dir, err := os.UserConfigDir(); err == nil {
		return filepath.Join(dir, "Vesper")
	}
	return filepath.Join(os.TempDir(), "vesper-app")
}

func isLoopbackHostPort(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func randomHex16() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

// appPlaygroundPorts are the gateway ports for playgrounds and the dev
// workspace terminal: RUNNER_PLAYGROUND_PORTS, else the Docker stack's default
// 8090-8094. The app serves them on loopback only.
func appPlaygroundPorts(configured []int) []int {
	if len(configured) > 0 {
		return configured
	}
	return []int{8090, 8091, 8092, 8093, 8094}
}

// localhostURL is baseURL with its loopback IP spelled localhost, the name the
// desktop window loads; "" when baseURL isn't a loopback IP.
func localhostURL(baseURL string) string {
	u, err := url.Parse(baseURL)
	if err != nil {
		return ""
	}
	if ip := net.ParseIP(u.Hostname()); ip == nil || !ip.IsLoopback() {
		return ""
	}
	u.Host = net.JoinHostPort("localhost", u.Port())
	return u.String()
}

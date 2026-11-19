// Command vesper is the single Vesper binary.
//
//	vesper serve        run migrations, ensure buckets, serve HTTP (default)
//	vesper app          run all-in-one embedded Postgres + API + Web + MicroVM desktop backend
//	vesper app-import   inspect or import a backup archive into Vesper desktop storage
//	vesper migrate      run migrations and exit
//	vesper runner       execute dispatched runs in hardened containers
//	vesper healthcheck  exit 0 if the local API reports healthy (for container probes)
//	vesper export       write every table and stored object to one archive (-o FILE)
//	vesper import       load such an archive into this instance ([--replace] FILE)
//	vesper sign-in-link print a one-time link that signs a browser in (-code: just the code)
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
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

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	cmd := "serve"
	if len(os.Args) > 1 {
		cmd = os.Args[1]
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	var err error
	switch cmd {
	case "serve":
		err = serve(ctx, log)
	case "app":
		err = runApp(ctx, log, os.Args[2:])
	case "app-import":
		err = runAppImport(ctx, log, os.Args[2:])
	case "migrate":
		err = migrateOnly(ctx)
	case "runner":
		err = runRunner(ctx, log)
	case "healthcheck":
		err = healthcheck(ctx)
	case "export":
		err = exportData(ctx, log, os.Args[2:])
	case "import":
		err = importData(ctx, log, os.Args[2:])
	case "sign-in-link":
		err = printSignInLink(ctx, len(os.Args) > 2 && os.Args[2] == "-code")
	default:
		err = fmt.Errorf("unknown command %q (want serve|app|app-import|migrate|runner|healthcheck|export|import|sign-in-link)", cmd)
	}
	if err != nil {
		log.Error("exit", "err", err)
		os.Exit(1)
	}
}

func connect(ctx context.Context, cfg config.Config) (*pgxpool.Pool, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, err
	}
	if err := db.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, err
	}
	return pool, nil
}

func migrateOnly(ctx context.Context) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	pool, err := connect(ctx, cfg)
	if err != nil {
		return err
	}
	pool.Close()
	return nil
}

func serve(ctx context.Context, log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	pool, err := connect(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	log.Info("migrations applied")

	blobs := blob.New(cfg.Blob)
	bctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	err = blobs.EnsureBuckets(bctx)
	cancel()
	if err != nil {
		return err
	}

	arts := &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: cfg.Blob.ArtifactBucket}
	res, err := seed.Run(ctx, pool, seed.Options{Demo: cfg.Seed, UserName: cfg.LocalUserName, UserEmail: cfg.LocalUserEmail, Artifacts: arts})
	if err != nil {
		return fmt.Errorf("seed: %w", err)
	}
	if res.Created {
		log.Info("seeded first workspace", "demo", cfg.Seed)
	}

	jobs, err := metrics.NewClient(pool, log)
	if err != nil {
		return err
	}
	if err = jobs.Start(ctx); err != nil {
		return err
	}
	defer func() {
		stopCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = jobs.Stop(stopCtx)
	}()
	q := store.New(pool)
	box, err := secrets.NewBox(cfg.SecretsKey)
	if err != nil {
		return err
	}
	if box == nil {
		log.Warn("SECRETS_KEY is not set: storing secrets is disabled")
	}
	secretsSvc := &secrets.Service{Q: q, Box: box}
	trackerSvc := &tracker.Service{Pool: pool}
	events := realtime.New()
	go events.Run(ctx, pool)
	if cfg.NoSignIn {
		log.Warn("VESPER_NO_SIGNIN is on: the API serves anyone who reaches it as the local user, without signing in")
	}
	srv := &httpapi.Server{
		AnonymousAPI: cfg.NoSignIn,
		Events:       events,
		Version:      cfg.Version,
		Checks:       map[string]httpapi.Pinger{"postgres": pool, "s3": blobs},
		Pool:         pool,
		Q:            q,
		Tracker:      trackerSvc,

		Artifacts:      arts,
		Agents:         &agents.Service{Pool: pool},
		Secrets:        secretsSvc,
		Runs:           &runs.Service{Pool: pool, Secrets: secretsSvc, Artifacts: arts, Tracker: trackerSvc, RequireHarnessKey: config.IsolatesBackend(cfg.Runner.Backend), PlanModels: planModels(cfg.Runner.Backend, pool), Transcripts: transcript.Shared, RolloverContextTokens: int64(cfg.RolloverContextTokens)},
		Wiki:           &wiki.Service{Pool: pool, Artifacts: arts, Tracker: trackerSvc},
		PublicURL:      cfg.PublicURL,
		Blobs:          blobs,
		ArtifactBucket: cfg.Blob.ArtifactBucket,
		DesignWorker:   &designs.Worker{URL: cfg.DesignWorkerURL, Token: cfg.DesignWorkerToken},
		Log:            log,
		Usage:          &usage.Service{Q: q, Log: log},
		Exporter:       exporter(cfg, pool, log),
	}
	go srv.Wiki.RunVaultWorker(ctx, log)
	// In isolated backends (Docker, microVM) the CLIs and logins live inside the
	// sandbox, so the API queues usage checks for a runner to answer. The fake
	// backend's stand-in harnesses (config requires RUNNER_*_BIN) answer directly.
	if config.IsolatesBackend(cfg.Runner.Backend) {
		srv.Usage.Queued = true
	} else {
		srv.Usage.Probe = usage.Probe
	}
	if cfg.PRSyncInterval > 0 {
		sync := &prsync.Syncer{Pool: pool, Secrets: secretsSvc, Tracker: trackerSvc, Log: log,
			MinAge: time.Duration(cfg.PRSyncInterval) * time.Second}
		go sync.Run(ctx, time.Duration(cfg.PRSyncInterval)*time.Second)
		approvals := &githubpr.ApprovalSyncer{Queries: q, Secrets: secretsSvc, GitHub: &githubpr.Service{BaseURL: srv.GitHubAPIURL}, Log: log}
		go approvals.Run(ctx, time.Duration(cfg.PRSyncInterval)*time.Second)
	}
	if cfg.MemoryConsolidateInterval > 0 {
		go memory.RunConsolidation(ctx, q, log, time.Duration(cfg.MemoryConsolidateInterval)*time.Second)
	}
	hs := &http.Server{
		Addr:              cfg.Addr,
		Handler:           srv.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	errc := make(chan error, 1)
	go func() { errc <- hs.ListenAndServe() }()
	log.Info("listening", "addr", cfg.Addr, "version", cfg.Version)
	if err := logFirstSignInLink(ctx, q, cfg, log); err != nil {
		return err
	}

	select {
	case err := <-errc:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	case <-ctx.Done():
		sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return hs.Shutdown(sctx)
	}
}

// signInLink is the browser link that spends code (see auth.RedeemSignInCode).
func signInLink(cfg config.Config, code string) string {
	return cfg.WebURL + httpapi.SignInPath + "?code=" + code
}

// logFirstSignInLink tells a fresh install's owner where to start: an
// unclaimed install is set up in the browser, and a claimed one that has no
// password and no signed-in browser can only be opened with a sign-in link.
// The link is one-time and short-lived; `vesper sign-in-link` makes more.
func logFirstSignInLink(ctx context.Context, q *store.Queries, cfg config.Config, log *slog.Logger) error {
	if cfg.NoSignIn {
		return nil
	}
	u, err := q.GetLocalUser(ctx)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	} else if err != nil {
		return err
	}
	if u.ClaimedAt == nil {
		log.Info("Vesper isn't set up yet: open it in a browser to choose your username and password", "url", cfg.WebURL)
		return nil
	}
	if u.PasswordSetAt != nil {
		return nil
	}
	n, err := q.CountBrowserSessions(ctx)
	if err != nil || n > 0 {
		return err
	}
	code, err := auth.NewSignInCode(ctx, q)
	if err != nil {
		return err
	}
	log.Info("no browser is signed in yet: open this link to sign in", "url", signInLink(cfg, code), "expires_in", auth.SignInCodeTTL.String())
	return nil
}

// printSignInLink writes a one-time sign-in link (or only its code) to stdout.
// It talks to the database directly: whoever can run it already holds the
// database credentials, and no agent container can.
func printSignInLink(ctx context.Context, codeOnly bool) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	pool, err := connect(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	code, err := auth.NewSignInCode(ctx, store.New(pool))
	if err != nil {
		return err
	}
	if codeOnly {
		fmt.Println(code)
		return nil
	}
	fmt.Println(signInLink(cfg, code))
	return nil
}

// healthcheck probes the running server. Distroless images have no curl.
func healthcheck(ctx context.Context) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	port := cfg.Addr
	if i := strings.LastIndex(port, ":"); i >= 0 {
		port = port[i+1:]
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://127.0.0.1:"+port+"/api/v1/health", nil)
	if err != nil {
		return err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("health: status %d", resp.StatusCode)
	}
	return nil
}

// runRunner executes dispatched runs (docs/dev/plan.md §6.4–6.6). It shares the
// database with the API and reaches it over /mcp like any agent.
func runRunner(ctx context.Context, log *slog.Logger) error {
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	pool, err := connect(ctx, cfg)
	if err != nil {
		return err
	}
	defer pool.Close()
	box, err := secrets.NewBox(cfg.SecretsKey)
	if err != nil {
		return err
	}
	if box == nil {
		log.Warn("SECRETS_KEY is not set: runs get no secrets (harness keys, git:pat)")
	}
	rc := cfg.Runner
	var backend runner.Backend
	switch rc.Backend {
	case "microvm":
		apiUpstream := os.Getenv("API_INTERNAL_URL")
		if apiUpstream == "" {
			if u, err := url.Parse(rc.MCPURL); err == nil && u.Host != "" && u.Host != microvm.InternalAPIHost {
				apiUpstream = u.Scheme + "://" + u.Host
			} else {
				apiUpstream = cfg.PublicURL
			}
		}
		var cacheStore *microvm.CacheStore
		if rc.VMDir != "" {
			if cs, cerr := microvm.NewCacheStore(microvm.CacheStoreConfig{Dir: filepath.Join(rc.VMDir, "caches")}); cerr == nil {
				cacheStore = cs
			} else {
				log.Warn("runner: microvm cache store disabled", "err", cerr)
			}
		}
		driver := microvm.NewVZDriver()
		m := &runner.MicroVM{
			Driver:         driver,
			MacOS:          macOSGuests(log, rc.MacOS, rc.VMDir, driver),
			StateDir:       rc.VMDir,
			KernelPath:     rc.KernelPath,
			RootfsPath:     rc.RootfsPath,
			HostWorkspaces: rc.HostWorkspaces,
			CPUs:           rc.CPUs,
			MemoryMB:       rc.MemoryMB,
			PidsLimit:      rc.PidsLimit,
			WarmTTL:        rc.WarmTTL,
			SpareVMs:       rc.SpareVMs,
			MCPURL:         rc.MCPURL,
			APIUpstream:    apiUpstream,
			CacheStore:     cacheStore,
			Log:            log,
		}
		defer func() { _ = m.Close() }()
		backend = m
	case "fake":
		log.Warn("RUNNER_BACKEND=fake runs stand-in harnesses on this machine with no isolation; it's only for tests and playgrounds")
		bins := map[string]string{"claude": rc.ClaudeBin, "codex": rc.CodexBin}
		if rc.AntigravityBin != "" {
			bins["agy"] = rc.AntigravityBin
		}
		backend = &runner.Fake{Dir: rc.DataDir, Bins: bins}
	}
	host, _ := os.Hostname()
	blobs := blob.New(cfg.Blob)
	secretStore := &secrets.Service{Q: store.New(pool), Box: box}
	saveClaude, saveCodex := buildAuthSavers(secretStore)
	if m, ok := backend.(*runner.MicroVM); ok {
		m.SaveClaudeAuth = saveClaude
		m.SaveCodexAuth = saveCodex
	}
	workflows := runs.NewWorkflowEngine(pool, &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: cfg.Blob.ArtifactBucket}, &tracker.Service{Pool: pool})
	workflows.Catalog = chatmodels.Catalog{RequireKey: config.IsolatesBackend(rc.Backend), Secrets: secretStore, PlanModels: planModels(rc.Backend, pool)}
	r := &runner.Runner{
		Cfg: runner.Config{
			ModelPrices: rc.ModelPrices,
			ID:          fmt.Sprintf("%s-%d", host, os.Getpid()), MaxConcurrent: rc.MaxConcurrent, MCPURL: rc.MCPURL,
			Grace: 30 * time.Second, LogBucket: "run-logs", AttachmentBucket: cfg.Blob.ArtifactBucket, Version: cfg.Version, RequireHarnessKey: config.IsolatesBackend(rc.Backend),
			ChatIdleTTL: rc.ChatIdleTTL, MaxHold: rc.MaxHold, MaxHoldAttempts: rc.MaxHoldAttempts, RolloverContextTokens: int64(cfg.RolloverContextTokens),
			RepoMap:     rc.RepoMap,
			Playgrounds: runner.PlaygroundConfig{Ports: rc.PlaygroundPorts, IdleTTL: rc.PlaygroundIdleTTL, Origins: origins(cfg.WebURL, cfg.PublicURL)},
		},
		Pool: pool, Backend: backend, Secrets: secretStore,
		Tracker: &tracker.Service{Pool: pool}, Blobs: blobs, Attachments: blobs, Log: log,
		Workflows: workflows,
		Designs:   &designs.Service{Pool: pool, Worker: &designs.Worker{URL: cfg.DesignWorkerURL, Token: cfg.DesignWorkerToken}, Blobs: blobs, Bucket: cfg.Blob.ArtifactBucket},
		Scheduled: &runs.Service{Pool: pool, Secrets: secretStore, Tracker: &tracker.Service{Pool: pool}, Artifacts: &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: cfg.Blob.ArtifactBucket}, RequireHarnessKey: config.IsolatesBackend(rc.Backend), PlanModels: planModels(rc.Backend, pool), RolloverContextTokens: int64(cfg.RolloverContextTokens)},
		StoreSecret: func(ctx context.Context, ws, by uuid.UUID, name, value string) error {
			_, err := secretStore.Set(ctx, ws, by, secrets.SetInput{Name: name, Value: value})
			return err
		},
	}
	log.Info("runner started", "backend", rc.Backend, "slots", rc.MaxConcurrent, "mcp", rc.MCPURL)
	return r.Run(ctx)
}

// origins are the browser origins of Vesper's own URLs, deduplicated.
func origins(urls ...string) []string {
	var out []string
	for _, raw := range urls {
		u, err := url.Parse(raw)
		if err != nil || u.Scheme == "" || u.Host == "" {
			continue
		}
		if o := u.Scheme + "://" + u.Host; !slices.Contains(out, o) {
			out = append(out, o)
		}
	}
	return out
}

// planModels lists plan-login models through a runner in isolated modes
// (microVM) where the API lacks direct sandbox CLIs; nil elsewhere.
func planModels(backend string, pool *pgxpool.Pool) func(context.Context, uuid.UUID, string, bool) ([]chatmodels.Model, error) {
	if !config.IsolatesBackend(backend) {
		return nil
	}
	return (&chatmodels.QueuedListings{Pool: pool}).Models
}

func buildAuthSavers(secretStore *secrets.Service) (saveClaude, saveCodex func(context.Context, string, string) error) {
	saveScoped := func(secret string, valid func(current, next string) bool) func(context.Context, string, string) error {
		return func(ctx context.Context, scope, auth string) error {
			ws, project, err := runner.ParseCodexAuthScope(scope)
			if err != nil {
				return err
			}
			return secretStore.Replace(ctx, ws, project, secret, func(current string) (string, bool) {
				return auth, valid(current, auth)
			})
		}
	}
	return saveScoped(chatmodels.KeySecret[agentdef.HarnessClaudeCode], chatmodels.ClaudeAuthRefreshed),
		saveScoped(chatmodels.KeySecret[agentdef.HarnessCodex], chatmodels.CodexAuthRefreshed)
}

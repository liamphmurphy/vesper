// Command vesper is the single Vesper binary.
//
//	vesper serve        run migrations, ensure buckets, serve HTTP (default)
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
	"github.com/liamphmurphy/vesper/server/internal/httpapi"
	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/metrics"
	"github.com/liamphmurphy/vesper/server/internal/prsync"
	"github.com/liamphmurphy/vesper/server/internal/realtime"
	"github.com/liamphmurphy/vesper/server/internal/runner"
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
		err = fmt.Errorf("unknown command %q (want serve|migrate|runner|healthcheck|export|import|sign-in-link)", cmd)
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

	blobs := blob.New(cfg.S3)
	bctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	err = blobs.EnsureBuckets(bctx)
	cancel()
	if err != nil {
		return err
	}

	arts := &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: cfg.S3.ArtifactBucket}
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
		Runs:           &runs.Service{Pool: pool, Secrets: secretsSvc, Artifacts: arts, Tracker: trackerSvc, RequireHarnessKey: cfg.Runner.Backend == "docker", PlanModels: planModels(cfg.Runner.Backend, pool), Transcripts: transcript.Shared, RolloverContextTokens: int64(cfg.RolloverContextTokens)},
		Wiki:           &wiki.Service{Pool: pool, Artifacts: arts, Tracker: trackerSvc},
		PublicURL:      cfg.PublicURL,
		Blobs:          blobs,
		ArtifactBucket: cfg.S3.ArtifactBucket,
		DesignWorker:   &designs.Worker{URL: cfg.DesignWorkerURL, Token: cfg.DesignWorkerToken},
		Log:            log,
		Usage:          &usage.Service{Q: q, Log: log},
		Exporter:       exporter(cfg, pool, log),
	}
	go srv.Wiki.RunVaultWorker(ctx, log)
	// In Docker the CLIs and logins live in agent containers, so the API
	// queues usage checks for a runner to answer. The fake backend's stand-in
	// harnesses (config requires RUNNER_*_BIN) answer the API directly.
	if cfg.Runner.Backend == "docker" {
		srv.Usage.Queued = true
	} else {
		srv.Usage.Probe = usage.Probe
	}
	if cfg.PRSyncInterval > 0 {
		sync := &prsync.Syncer{Pool: pool, Secrets: secretsSvc, Tracker: trackerSvc, Log: log,
			MinAge: time.Duration(cfg.PRSyncInterval) * time.Second}
		go sync.Run(ctx, time.Duration(cfg.PRSyncInterval)*time.Second)
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
	case "docker":
		d := &runner.Docker{Socket: rc.DockerSocket, Image: rc.Image, Network: rc.Network, Stack: rc.Stack, MemoryMB: rc.MemoryMB, PidsLimit: rc.PidsLimit, HostWorkspaces: rc.HostWorkspaces,
			ProxyDir: rc.DockerProxyDir, ProxyVolume: rc.DockerProxyVolume, NixVolume: rc.NixVolume}
		if err := d.PrepareDockerProxy(); err != nil {
			return fmt.Errorf("runner: %w", err)
		}
		pctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		err := d.Ping(pctx)
		cancel()
		if err != nil {
			return fmt.Errorf("runner: docker: %w", err)
		}
		// Without the daemon turns still run; nix commands in them say they
		// can't reach it.
		nctx, cancel := context.WithTimeout(ctx, time.Minute)
		if err := d.EnsureNixDaemon(nctx); err != nil {
			log.Warn("runner: turns won't have Nix", "err", err)
		} else if st, err := d.CheckNixDaemon(nctx); err != nil {
			log.Warn("runner: turns won't have Nix", "err", err, "probe", st.Probe, "daemon_log", st.DaemonLog)
		}
		cancel()
		backend = d
	case "fake":
		log.Warn("RUNNER_BACKEND=fake runs stand-in harnesses on this machine with no isolation; it's only for tests and playgrounds")
		bins := map[string]string{"claude": rc.ClaudeBin, "codex": rc.CodexBin}
		if rc.AntigravityBin != "" {
			bins["agy"] = rc.AntigravityBin
		}
		backend = &runner.Fake{Dir: rc.DataDir, Bins: bins}
	}
	host, _ := os.Hostname()
	blobs := blob.New(cfg.S3)
	secretStore := &secrets.Service{Q: store.New(pool), Box: box}
	if d, ok := backend.(*runner.Docker); ok {
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
		d.SaveClaudeAuth = saveScoped(chatmodels.KeySecret[agentdef.HarnessClaudeCode], chatmodels.ClaudeAuthRefreshed)
		d.SaveCodexAuth = saveScoped(chatmodels.KeySecret[agentdef.HarnessCodex], chatmodels.CodexAuthRefreshed)
	}
	workflows := runs.NewWorkflowEngine(pool, &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: cfg.S3.ArtifactBucket}, &tracker.Service{Pool: pool})
	workflows.Catalog = chatmodels.Catalog{RequireKey: rc.Backend == "docker", Secrets: secretStore, PlanModels: planModels(rc.Backend, pool)}
	r := &runner.Runner{
		Cfg: runner.Config{
			ModelPrices: rc.ModelPrices,
			ID:          fmt.Sprintf("%s-%d", host, os.Getpid()), MaxConcurrent: rc.MaxConcurrent, MCPURL: rc.MCPURL,
			Grace: 30 * time.Second, LogBucket: "run-logs", AttachmentBucket: cfg.S3.ArtifactBucket, Version: cfg.Version, RequireHarnessKey: rc.Backend == "docker",
			ChatIdleTTL: rc.ChatIdleTTL, MaxHold: rc.MaxHold, MaxHoldAttempts: rc.MaxHoldAttempts, RolloverContextTokens: int64(cfg.RolloverContextTokens),
			RepoMap:     rc.RepoMap,
			Playgrounds: runner.PlaygroundConfig{Ports: rc.PlaygroundPorts, IdleTTL: rc.PlaygroundIdleTTL, Origins: origins(cfg.WebURL, cfg.PublicURL)},
		},
		Pool: pool, Backend: backend, Secrets: secretStore,
		Tracker: &tracker.Service{Pool: pool}, Blobs: blobs, Attachments: blobs, Log: log,
		Workflows: workflows,
		Designs:   &designs.Service{Pool: pool, Worker: &designs.Worker{URL: cfg.DesignWorkerURL, Token: cfg.DesignWorkerToken}, Blobs: blobs, Bucket: cfg.S3.ArtifactBucket},
		Scheduled: &runs.Service{Pool: pool, Secrets: secretStore, Tracker: &tracker.Service{Pool: pool}, Artifacts: &artifacts.Service{Pool: pool, Blobs: blobs, Bucket: cfg.S3.ArtifactBucket}, RequireHarnessKey: rc.Backend == "docker", PlanModels: planModels(rc.Backend, pool), RolloverContextTokens: int64(cfg.RolloverContextTokens)},
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

// planModels lists plan-login models through a runner in Docker mode, where
// the API image has no harness CLI; nil elsewhere (the local CLI is used).
func planModels(backend string, pool *pgxpool.Pool) func(context.Context, uuid.UUID, string, bool) ([]chatmodels.Model, error) {
	if backend != "docker" {
		return nil
	}
	return (&chatmodels.QueuedListings{Pool: pool}).Models
}

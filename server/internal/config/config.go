// Package config loads process configuration from the environment.
package config

import (
	"encoding/json"
	"fmt"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"math"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Addr        string // HTTP listen address, e.g. ":8000"
	DatabaseURL string
	Blob        Blob
	Seed        bool
	Version     string

	// The local user created when SEED=false (first boot only). There is no
	// login for now; every request acts as this user.
	LocalUserName  string
	LocalUserEmail string

	// SecretsKey encrypts stored secrets (base64, 32 bytes). Empty = secrets disabled.
	SecretsKey string
	// NoSignIn serves the person-facing API without a browser session
	// (VESPER_NO_SIGNIN), for a disposable local instance such as one an
	// agent runs in a playground. Load refuses it unless PublicURL is a
	// loopback address.
	NoSignIn bool
	// PublicURL is how agents and browsers reach the app (Caddy in compose).
	PublicURL string
	// WebURL is where the person's browser opens the app, for sign-in links.
	// It differs from PublicURL under `make dev`, where agents reach the API
	// on :8000 and the browser uses Next on :3000.
	WebURL string

	// DesignWorkerURL and DesignWorkerToken reach the Node design worker that
	// renders designs (DESIGN_WORKER_URL, DESIGN_WORKER_TOKEN). With no token,
	// renders are unavailable.
	DesignWorkerURL, DesignWorkerToken string

	Runner Runner
	// PRSyncInterval is how often open PRs are polled (0 disables).
	PRSyncInterval int // seconds
	// MemoryConsolidateInterval is how often personal memories are
	// consolidated (duplicates merged; 0 disables).
	MemoryConsolidateInterval int // seconds
	// RolloverContextTokens (ROLLOVER_CONTEXT_TOKENS) continues a main agent
	// in a fresh session, briefed from run state, when its delegations finish
	// and its context is at least this many tokens. 0 never rolls over.
	RolloverContextTokens int
}

// Runner configures `vesper runner` (docs/dev/plan.md §6.5).
type Runner struct {
	ModelPrices   map[string]harness.Price
	Backend       string // microvm, or fake (stand-in harnesses on the host, for tests)
	MaxConcurrent int
	MCPURL        string // how turns reach the API's /mcp
	MemoryMB      int64  // microvm: per-VM memory limit
	PidsLimit     int64  // microvm: per-VM process limit, 0 = none
	DataDir       string // fake: run workspaces
	ClaudeBin     string // fake: stand-in for `claude`
	CodexBin      string // fake: stand-in for `codex`
	// AntigravityBin is the fake backend's stand-in for `agy`. Optional: without
	// it Antigravity is simply unavailable on that instance.
	AntigravityBin string
	// MicroVM settings (RUNNER_VM_DIR, RUNNER_KERNEL_PATH, RUNNER_ROOTFS_PATH,
	// RUNNER_CPUS, RUNNER_VM_WARM_TTL_S, RUNNER_VM_SPARES).
	VMDir      string
	KernelPath string
	RootfsPath string
	CPUs       int
	WarmTTL    time.Duration
	// SpareVMs is how many VMs stay booted ahead of new runs, so a new
	// chat's first turn doesn't wait for one (0 turns it off).
	SpareVMs int
	// ChatIdleTTL is how long an idle Personal Assistant chat keeps its run
	// and workspace (RUNNER_CHAT_IDLE_TTL_S).
	ChatIdleTTL time.Duration
	// MaxHold and MaxHoldAttempts bound how long a run waits at a provider
	// limit (RUNNER_MAX_HOLD_S, RUNNER_MAX_HOLD_ATTEMPTS).
	MaxHold         time.Duration
	MaxHoldAttempts int
	// RepoMap gives ticket runs a generated map of their repository at its
	// base commit as a context file (RUNNER_REPO_MAP, default off).
	RepoMap bool

	// HostWorkspaces is the absolute folder that checkouts go in when a person
	// turns on host-folder workspaces (RUNNER_HOST_WORKSPACES_DIR, microvm).
	// The runner and the VM must both see it at that path.
	HostWorkspaces string
	// ExtraCAFiles are PEM or DER certificate files of roots every VM trusts on
	// top of its image's, for a TLS-inspecting corporate proxy such as Zscaler
	// (RUNNER_EXTRA_CA_FILE, path-list separated, microvm).
	ExtraCAFiles []string
	// PlaygroundPorts are where the runner serves chats' playgrounds, one
	// each (RUNNER_PLAYGROUND_PORTS, e.g. 8090-8094). The browser reaches them
	// on Vesper's host, so publish them there. Unset, chats can't start
	// playgrounds on this runner.
	PlaygroundPorts []int
	// PlaygroundIdleTTL stops a playground unused this long
	// (RUNNER_PLAYGROUND_IDLE_S).
	PlaygroundIdleTTL time.Duration
	// MacOS configures the macOS guest VMs behind `mac` (microvm).
	MacOS MacOSGuests
}

// MacOSGuests configures the macOS guest VMs runs reach with `mac`. They're on
// when a golden image is set up (see docs/dev/microvm-architecture.md).
type MacOSGuests struct {
	// ImageDir holds the golden image (RUNNER_MACOS_IMAGE_DIR); empty means
	// macos-golden in the runner's VM directory.
	ImageDir string
	// MaxVMs is how many may run at once (RUNNER_MACOS_VMS, 0–2, default 2;
	// Apple allows 2 per Mac). 0 turns macOS guests off.
	MaxVMs int
	// IdleTTL stops a run's macOS VM unused this long (RUNNER_MACOS_IDLE_TTL_S).
	IdleTTL  time.Duration
	CPUs     int   // RUNNER_MACOS_CPUS
	MemoryMB int64 // RUNNER_MACOS_MEMORY_MB
	// User is the image's account commands run as (RUNNER_MACOS_USER).
	User string
}

// IsolatesBackend reports whether backend runs harnesses inside an isolated
// sandbox (a microVM) rather than unisolated host fake mode.
func IsolatesBackend(backend string) bool {
	return backend == "microvm"
}

// Blob configures the local-directory blob store: one subdirectory per bucket.
type Blob struct {
	Dir     string // BLOB_DIR: the store's root directory
	Buckets []string
	// ArtifactBucket holds uploaded artifact files (one of Buckets).
	ArtifactBucket string
}

// Load reads configuration from environment variables, applying local-dev defaults.
func Load() (Config, error) {
	c := Config{
		Addr:        env("API_ADDR", ":8000"),
		DatabaseURL: env("DATABASE_URL", "postgres://lazyagents:lazyagents@localhost:5432/lazyagents?sslmode=disable"),
		Blob: Blob{
			Dir:            env("BLOB_DIR", ".lazyagents/blobs"),
			Buckets:        splitList(env("BLOB_BUCKETS", "artifacts,run-logs")),
			ArtifactBucket: env("BLOB_ARTIFACT_BUCKET", "artifacts"),
		},
		Version:        env("LAZYAGENTS_VERSION", "dev"),
		LocalUserName:  env("LOCAL_USER_NAME", "Local user"),
		LocalUserEmail: env("LOCAL_USER_EMAIL", "me@localhost"),
		SecretsKey:     env("SECRETS_KEY", ""),
		PublicURL:      env("PUBLIC_URL", "http://localhost:8080"),

		DesignWorkerURL:   env("DESIGN_WORKER_URL", "http://127.0.0.1:3000/internal/designs"),
		DesignWorkerToken: env("DESIGN_WORKER_TOKEN", ""),
	}
	c.WebURL = strings.TrimRight(env("WEB_URL", c.PublicURL), "/")
	var err error
	if c.Seed, err = boolEnv("SEED", false); err != nil {
		return c, err
	}
	if c.NoSignIn, err = boolEnv("VESPER_NO_SIGNIN", false); err != nil {
		return c, err
	}
	if c.NoSignIn && !loopbackURL(c.PublicURL) {
		return c, fmt.Errorf("config: VESPER_NO_SIGNIN lets anyone who reaches the API act as you; it's only for a local instance, and PUBLIC_URL=%q isn't a loopback address", c.PublicURL)
	}
	r := Runner{
		Backend:        env("RUNNER_BACKEND", "microvm"),
		DataDir:        env("RUNNER_DATA_DIR", ".lazyagents/runs"),
		VMDir:          env("RUNNER_VM_DIR", ".lazyagents/vm"),
		KernelPath:     env("RUNNER_KERNEL_PATH", ""),
		RootfsPath:     env("RUNNER_ROOTFS_PATH", ""),
		ClaudeBin:      env("RUNNER_CLAUDE_BIN", ""),
		CodexBin:       env("RUNNER_CODEX_BIN", ""),
		AntigravityBin: env("RUNNER_ANTIGRAVITY_BIN", ""),
	}
	if r.HostWorkspaces = env("RUNNER_HOST_WORKSPACES_DIR", ""); r.HostWorkspaces != "" && !filepath.IsAbs(r.HostWorkspaces) {
		return c, fmt.Errorf("config: RUNNER_HOST_WORKSPACES_DIR=%q must be an absolute path", r.HostWorkspaces)
	}
	if raw := env("RUNNER_EXTRA_CA_FILE", ""); raw != "" {
		for _, p := range filepath.SplitList(raw) {
			p = strings.TrimSpace(p)
			if p == "" {
				continue
			}
			if !filepath.IsAbs(p) {
				return c, fmt.Errorf("config: RUNNER_EXTRA_CA_FILE=%q must be an absolute path", p)
			}
			if !slices.Contains(r.ExtraCAFiles, p) {
				r.ExtraCAFiles = append(r.ExtraCAFiles, p)
			}
		}
	}
	if r.MacOS, err = loadMacOSGuests(); err != nil {
		return c, err
	}
	switch r.Backend {
	case "microvm":
	case "fake":
		// Fake turns run on the host with no isolation, so they may only ever
		// start stand-in harnesses, never a real CLI found on PATH.
		if r.ClaudeBin == "" || r.CodexBin == "" {
			return c, fmt.Errorf("config: RUNNER_BACKEND=fake needs RUNNER_CLAUDE_BIN and RUNNER_CODEX_BIN set to fake harness binaries")
		}
	default:
		return c, fmt.Errorf("config: RUNNER_BACKEND=%q must be microvm (or fake, for tests and playgrounds)", r.Backend)
	}
	defMCP := "http://api:8000/mcp"
	switch r.Backend {
	case "fake":
		defMCP = "http://localhost:8000/mcp"
	case "microvm":
		defMCP = "http://api.vesper.internal/mcp"
	}
	r.MCPURL = env("RUNNER_MCP_URL", defMCP)
	if r.CPUs, err = intEnv("RUNNER_CPUS", 4); err != nil {
		return c, err
	}
	if r.CPUs < 1 || r.CPUs > 32 {
		return c, fmt.Errorf("config: RUNNER_CPUS must be 1–32")
	}
	warmTTL, err := intEnv("RUNNER_VM_WARM_TTL_S", 180)
	if err != nil {
		return c, err
	}
	if warmTTL < 10 {
		return c, fmt.Errorf("config: RUNNER_VM_WARM_TTL_S must be at least 10")
	}
	r.WarmTTL = time.Duration(warmTTL) * time.Second
	if r.SpareVMs, err = intEnv("RUNNER_VM_SPARES", 1); err != nil {
		return c, err
	}
	if r.SpareVMs < 0 || r.SpareVMs > 4 {
		return c, fmt.Errorf("config: RUNNER_VM_SPARES must be 0–4")
	}
	memory, err := intEnv("RUNNER_MEMORY_MB", 8192)
	if err != nil {
		return c, err
	}
	pids, err := intEnv("RUNNER_PIDS_LIMIT", 4096)
	if err != nil {
		return c, err
	}
	if memory < 0 || pids < 0 {
		return c, fmt.Errorf("config: RUNNER_MEMORY_MB and RUNNER_PIDS_LIMIT can't be negative")
	}
	r.MemoryMB, r.PidsLimit = int64(memory), int64(pids)
	if r.MaxConcurrent, err = intEnv("RUNNER_MAX_CONCURRENT", 2); err != nil {
		return c, err
	}
	if r.MaxConcurrent < 1 || r.MaxConcurrent > 32 {
		return c, fmt.Errorf("config: RUNNER_MAX_CONCURRENT must be 1–32")
	}
	if raw := os.Getenv("RUNNER_MODEL_PRICES"); raw != "" {
		if err := json.Unmarshal([]byte(raw), &r.ModelPrices); err != nil {
			return c, fmt.Errorf("config: RUNNER_MODEL_PRICES must be a JSON object of model token prices")
		}
		var entries map[string]map[string]json.RawMessage
		if err := json.Unmarshal([]byte(raw), &entries); err != nil {
			return c, fmt.Errorf("config: invalid model price entries")
		}
		for model, price := range r.ModelPrices {
			for _, key := range []string{"input_per_million", "cached_input_per_million", "output_per_million"} {
				if value, ok := entries[model][key]; !ok || string(value) == "null" {
					return c, fmt.Errorf("config: model %s is missing %s", model, key)
				}
			}
			for _, v := range []float64{price.Input, price.CachedInput, price.Output} {
				if v < 0 || math.IsNaN(v) || math.IsInf(v, 0) {
					return c, fmt.Errorf("config: invalid token price for %s", model)
				}
			}
		}
	}
	ttl, err := intEnv("RUNNER_CHAT_IDLE_TTL_S", 4*60*60)
	if err != nil {
		return c, err
	}
	if ttl < 60 {
		return c, fmt.Errorf("config: RUNNER_CHAT_IDLE_TTL_S must be at least 60")
	}
	r.ChatIdleTTL = time.Duration(ttl) * time.Second
	hold, err := intEnv("RUNNER_MAX_HOLD_S", 24*60*60)
	if err != nil {
		return c, err
	}
	if hold < 60 {
		return c, fmt.Errorf("config: RUNNER_MAX_HOLD_S must be at least 60")
	}
	r.MaxHold = time.Duration(hold) * time.Second
	if r.PlaygroundPorts, err = portList(env("RUNNER_PLAYGROUND_PORTS", "")); err != nil {
		return c, err
	}
	idle, err := intEnv("RUNNER_PLAYGROUND_IDLE_S", 30*60)
	if err != nil {
		return c, err
	}
	if idle < 60 {
		return c, fmt.Errorf("config: RUNNER_PLAYGROUND_IDLE_S must be at least 60")
	}
	r.PlaygroundIdleTTL = time.Duration(idle) * time.Second
	if r.MaxHoldAttempts, err = intEnv("RUNNER_MAX_HOLD_ATTEMPTS", 12); err != nil {
		return c, err
	}
	if r.MaxHoldAttempts < 1 {
		return c, fmt.Errorf("config: RUNNER_MAX_HOLD_ATTEMPTS must be at least 1")
	}
	if r.RepoMap, err = boolEnv("RUNNER_REPO_MAP", false); err != nil {
		return c, err
	}
	c.Runner = r
	if c.PRSyncInterval, err = intEnv("PR_SYNC_INTERVAL_S", 60); err != nil {
		return c, err
	}
	if c.MemoryConsolidateInterval, err = intEnv("MEMORY_CONSOLIDATE_INTERVAL_S", 6*60*60); err != nil {
		return c, err
	}
	if c.RolloverContextTokens, err = intEnv("ROLLOVER_CONTEXT_TOKENS", 0); err != nil {
		return c, err
	}
	if c.RolloverContextTokens < 0 {
		return c, fmt.Errorf("config: ROLLOVER_CONTEXT_TOKENS=%d must be 0 (off) or a token count", c.RolloverContextTokens)
	}
	return c, nil
}

// loopbackURL reports whether a URL's host is this machine.
func loopbackURL(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	host := u.Hostname()
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// maxPlaygroundPorts bounds RUNNER_PLAYGROUND_PORTS: each is a running app.
const maxPlaygroundPorts = 20

// portList parses "8090-8094" or "8090,8091" into ports.
func portList(v string) ([]int, error) {
	var ports []int
	bad := fmt.Errorf("config: RUNNER_PLAYGROUND_PORTS=%q must be ports or ranges like 8090-8094, at most %d", v, maxPlaygroundPorts)
	for _, part := range splitList(v) {
		lo, hi, isRange := strings.Cut(part, "-")
		if !isRange {
			hi = lo
		}
		a, errA := strconv.Atoi(strings.TrimSpace(lo))
		b, errB := strconv.Atoi(strings.TrimSpace(hi))
		if errA != nil || errB != nil || a < 1 || b > 65535 || a > b || b-a >= maxPlaygroundPorts {
			return nil, bad
		}
		for p := a; p <= b; p++ {
			if !slices.Contains(ports, p) {
				ports = append(ports, p)
			}
		}
	}
	if len(ports) > maxPlaygroundPorts {
		return nil, bad
	}
	return ports, nil
}

func loadMacOSGuests() (MacOSGuests, error) {
	m := MacOSGuests{ImageDir: env("RUNNER_MACOS_IMAGE_DIR", ""), User: env("RUNNER_MACOS_USER", "admin")}
	if m.ImageDir != "" && !filepath.IsAbs(m.ImageDir) {
		return m, fmt.Errorf("config: RUNNER_MACOS_IMAGE_DIR=%q must be an absolute path", m.ImageDir)
	}
	var err error
	if m.MaxVMs, err = intEnv("RUNNER_MACOS_VMS", 2); err != nil {
		return m, err
	}
	if m.MaxVMs < 0 || m.MaxVMs > 2 {
		return m, fmt.Errorf("config: RUNNER_MACOS_VMS must be 0–2 (Apple allows 2 macOS VMs per Mac)")
	}
	idle, err := intEnv("RUNNER_MACOS_IDLE_TTL_S", 600)
	if err != nil {
		return m, err
	}
	if idle < 30 {
		return m, fmt.Errorf("config: RUNNER_MACOS_IDLE_TTL_S must be at least 30")
	}
	m.IdleTTL = time.Duration(idle) * time.Second
	if m.CPUs, err = intEnv("RUNNER_MACOS_CPUS", 4); err != nil {
		return m, err
	}
	if m.CPUs < 2 || m.CPUs > 32 {
		return m, fmt.Errorf("config: RUNNER_MACOS_CPUS must be 2–32")
	}
	mem, err := intEnv("RUNNER_MACOS_MEMORY_MB", 8192)
	if err != nil {
		return m, err
	}
	if mem < 4096 {
		return m, fmt.Errorf("config: RUNNER_MACOS_MEMORY_MB must be at least 4096")
	}
	m.MemoryMB = int64(mem)
	if m.User == "" {
		return m, fmt.Errorf("config: RUNNER_MACOS_USER can't be empty")
	}
	return m, nil
}

func intEnv(key string, def int) (int, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def, fmt.Errorf("config: %s=%q is not a number", key, v)
	}
	return n, nil
}

func env(key, def string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return def
}

func boolEnv(key string, def bool) (bool, error) {
	v, ok := os.LookupEnv(key)
	if !ok || v == "" {
		return def, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return def, fmt.Errorf("config: %s=%q is not a boolean", key, v)
	}
	return b, nil
}

func splitList(s string) []string {
	var out []string
	for _, p := range strings.Split(s, ",") {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

package runner

import (
	"context"
	"errors"
	"io"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/playground"
)

// Paths inside a run's sandbox: the checkout, the harness user's home, and the
// harness login files under it.
const (
	workspacePath  = "/workspace"
	homePath       = "/home/node"
	claudeAuthPath = ".claude/.credentials.json"
	codexAuthPath  = ".codex/auth.json"
)

// DevPTY is an interactive terminal session inside a dev workspace.
type DevPTY interface {
	io.ReadWriteCloser
	Resize(ctx context.Context, cols, rows int) error
}

// DevWorkspaceBackend manages the persistent standalone dev-workspace
// container and interactive PTY sessions.
type DevWorkspaceBackend interface {
	EnsureDevWorkspaceContainer(ctx context.Context, workspaceID uuid.UUID) (string, error)
	ExecDevWorkspaceScript(ctx context.Context, containerID, script string, env []string) (string, int, error)
	StopDevWorkspaceContainer(ctx context.Context, workspaceID uuid.UUID) error
	OpenDevWorkspacePTY(ctx context.Context, workspaceID uuid.UUID, cols, rows int) (DevPTY, error)
}

// ProxyBackend gives a turn its own sandboxed Docker API.
type ProxyBackend interface {
	// StartDockerProxy serves a Docker API for one turn. The turn joins
	// Network and gets Env; Stop removes everything the turn created and is
	// safe to call more than once.
	// workspaceID names the run's checkout, which containers may bind from.
	StartDockerProxy(ctx context.Context, runID, workspaceID, key string) (*TurnDocker, error)
}

// TurnDocker is a turn's Docker API.
type TurnDocker struct {
	Network string
	Env     map[string]string
	Stop    func()
}

// errProxyOff means this runner has no sockets directory shared with turns.
var errProxyOff = errors.New("this runner has no per-turn Docker API")

func proxyNetworkName(key string) string { return "lazyagents-dkr-" + key }

var (
	// ServiceReadyTimeout bounds how long a service may take to pass its
	// healthcheck (or start running, without one).
	ServiceReadyTimeout = 2 * time.Minute
	// servicePullTimeout bounds pulling a missing service image.
	servicePullTimeout = 5 * time.Minute
	servicePoll        = 500 * time.Millisecond
)

func serviceNetworkName(key string) string { return "lazyagents-svc-" + key }

func serviceContainerName(key, service string) string { return "lazyagents-svc-" + key + "-" + service }

const (
	playgroundSetup = "setup"
	playgroundTools = "tools"
	// PlaygroundHost is the runner's name on each playground network.
	PlaygroundHost = "playground"
	// playgroundProfile holds the Nix packages a playground installs, in the
	// workspace (git-excluded) so every one of its containers sees them.
	playgroundProfile = workspacePath + "/.lazyagents/playground-profile"
)

var (
	// PlaygroundSetupTimeout bounds a playground's setup commands together.
	PlaygroundSetupTimeout = 15 * time.Minute
	// PlaygroundReadyTimeout bounds how long a process may take to listen on
	// its port (a first `go run` compiles).
	PlaygroundReadyTimeout = 5 * time.Minute
	// PlaygroundBackgroundGrace is how long a background process must keep
	// running after start before the playground counts as up.
	PlaygroundBackgroundGrace = 3 * time.Second
	// PlaygroundWarmUpTimeout bounds loading the first page once a process
	// listens; one slower than this starts anyway.
	PlaygroundWarmUpTimeout = 2 * time.Minute
)

// PlaygroundRun is a playground as the backend starts it.
type PlaygroundRun struct {
	ID    uuid.UUID
	RunID string // whose workspace it runs
	Spec  playground.Spec
}

// PlaygroundError is a playground that couldn't start, with the end of the
// output that says why.
type PlaygroundError struct {
	Msg string
	Log string
}

func (e *PlaygroundError) Error() string { return e.Msg }

// PlaygroundBackend runs playgrounds (the microVM backend).
type PlaygroundBackend interface {
	// StartPlayground starts everything fresh, replacing what was running,
	// and returns where each process listens as the runner reaches it.
	StartPlayground(ctx context.Context, pg PlaygroundRun, step func(string)) (map[string]string, error)
	// StopPlayground removes everything; safe to call more than once.
	StopPlayground(ctx context.Context, id uuid.UUID) error
	// RunningPlaygrounds lists the playgrounds with containers here.
	RunningPlaygrounds(ctx context.Context) ([]uuid.UUID, error)
	// StackName is the install whose containers this backend owns.
	StackName() string
	// PlaygroundNetwork is the network a turn joins to reach a playground.
	PlaygroundNetwork(id uuid.UUID) string
	// PullMissing pulls an image unless it's here already, and says whether
	// it pulled.
	PullMissing(ctx context.Context, image string) (bool, error)
	playground.Backend
}

func playgroundKey(id uuid.UUID) string {
	h := strings.ReplaceAll(id.String(), "-", "")
	return h[len(h)-12:] // the random end of a v7 UUID
}

// Names stay within a 63-character DNS label: the runner reaches each
// process by its container name.
func playgroundNetwork(id uuid.UUID) string { return "lazyagents-play-" + playgroundKey(id) }

// nixInstallScript installs pkgs into the playground profile, unless the
// last install there was of the same packages and the profile still holds
// them: a restart would otherwise evaluate nixpkgs again for nothing. The
// manifest check follows the profile into the store, so packages Nix has
// since collected are installed again.
func nixInstallScript(pkgs []string) string {
	want := shellQuote(strings.Join(pkgs, " "))
	stamp := shellQuote(playgroundProfile + ".packages")
	profile := shellQuote(playgroundProfile)
	return "if [ -e " + profile + "/manifest.json ] && [ \"$(cat " + stamp + " 2>/dev/null)\" = " + want + " ]; then\n" +
		"  echo 'tools already installed'\n  exit 0\nfi\n" +
		"nix profile install --profile " + profile + " " + strings.Join(quoteAll(pkgs), " ") +
		" && printf '%s\\n' " + want + " > " + stamp + "\n"
}

// startingStep names what a playground starts before its setup.
func startingStep(spec playground.Spec) string {
	var names []string
	for _, s := range spec.Services {
		names = append(names, s.Name)
	}
	switch {
	case len(names) > 0 && len(spec.NixPackages) > 0:
		return "Starting " + joinAnd(names) + ", installing tools"
	case len(names) > 0:
		return "Starting " + joinAnd(names)
	default:
		return "Installing tools"
	}
}

func joinAnd(items []string) string {
	if len(items) < 2 {
		return strings.Join(items, "")
	}
	return strings.Join(items[:len(items)-1], ", ") + " and " + items[len(items)-1]
}

// processScript runs command in dir, which it creates as the container's
// user, with the playground's Nix tools first on PATH.
func processScript(dir, command string) string {
	script := "export PATH=" + playgroundProfile + "/bin:\"$PATH\"\n"
	if dir != "" {
		script += "mkdir -p -- " + shellQuote(dir) + " && cd -- " + shellQuote(dir) + " || exit 1\n"
	}
	return script + command
}

func quoteAll(ss []string) []string {
	out := make([]string, len(ss))
	for i, s := range ss {
		out[i] = shellQuote(s)
	}
	return out
}

// setupScript runs each setup command from the workspace root, as the spec
// promises, in a subshell of its own: a cd in one doesn't move the next, and
// a command whose status is non-zero stops setup even when it's an && chain,
// which set -e alone lets through.
func setupScript(cmds []string) string {
	var b strings.Builder
	b.WriteString("set -e\n")
	for _, c := range cmds {
		b.WriteString("(cd " + workspacePath + " && " + c + "\n)\n")
	}
	return b.String()
}

// playgroundBody is a setup or process container: the agent image in the
// turn's sandbox, with the workspace and shared caches but not the run's home

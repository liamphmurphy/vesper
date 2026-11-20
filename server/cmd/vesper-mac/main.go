// Command vesper-mac is `mac` in a run's Linux VM: it runs a command in the
// run's macOS guest VM, for the Apple-platform work (swift, xcodebuild) Linux
// can't do. It first mirrors the git checkout it's run in to the macOS VM,
// sending only what changed, then runs the command in the same relative
// directory there and exits with its exit code.
//
// The macOS VM boots on a run's first call and is shared by the run's later
// ones; see docs/dev/microvm-architecture.md.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/macclient"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// workspaceRoot is the run's workspace in the Linux VM; the macOS copy
// mirrors paths relative to it.
const workspaceRoot = "/workspace"

const usage = `usage: mac [-e KEY=VALUE]... [--pull PATH]... [--no-sync] [--] COMMAND [ARG...]
       mac --agent-log

Runs COMMAND in this run's macOS VM, in the directory matching the current
one. Before it runs, the git checkout you're in is mirrored there (tracked
files plus untracked ones git doesn't ignore; only what changed is sent).
Ignored files (build output, .build, DerivedData) stay on each side.

The first call in a run boots macOS, which can take a minute; later calls
reuse it. The macOS VM has no network access.

  -e KEY=VALUE   set an environment variable for COMMAND (repeatable)
  --pull PATH    after COMMAND, copy PATH (relative to the current directory)
                 back from the macOS VM (repeatable; even if COMMAND fails)
  --no-sync      skip mirroring the checkout
  --agent-log    print the end of the macOS VM's guest agent log and exit, to
                 see why mac itself is failing (booting the VM if needed)

Examples:
  mac make -C macos mac-test
  mac swift test --package-path macos
  mac --pull macos/.build/test-results.xml xcodebuild test ...
`

type multiFlag []string

func (m *multiFlag) String() string     { return strings.Join(*m, ",") }
func (m *multiFlag) Set(v string) error { *m = append(*m, v); return nil }

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("mac", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() { fmt.Fprint(stderr, usage) }
	var envs, pulls multiFlag
	fs.Var(&envs, "e", "")
	fs.Var(&pulls, "pull", "")
	noSync := fs.Bool("no-sync", false, "")
	agentLog := fs.Bool("agent-log", false, "")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return 0
		}
		return 2
	}
	argv := fs.Args()
	if *agentLog {
		if len(argv) > 0 || len(envs) > 0 || len(pulls) > 0 || *noSync {
			fmt.Fprintln(stderr, "mac: --agent-log takes no command or other flags")
			return 2
		}
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		c := &macclient.Client{BaseURL: "http://" + microvm.InternalMacHost, Status: stderr}
		log, err := c.AgentLog(ctx)
		if err != nil {
			fmt.Fprintf(stderr, "mac: %v\n", err)
			return 1
		}
		fmt.Fprint(stdout, log)
		return 0
	}
	if len(argv) == 0 {
		fs.Usage()
		return 2
	}
	env := map[string]string{}
	for _, kv := range envs {
		k, v, ok := strings.Cut(kv, "=")
		if !ok || k == "" {
			fmt.Fprintf(stderr, "mac: -e wants KEY=VALUE, got %q\n", kv)
			return 2
		}
		env[k] = v
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cwd, err := os.Getwd()
	if err != nil {
		fmt.Fprintf(stderr, "mac: %v\n", err)
		return 1
	}
	if cwd, err = filepath.EvalSymlinks(cwd); err != nil {
		fmt.Fprintf(stderr, "mac: %v\n", err)
		return 1
	}
	relCwd, err := macclient.RelDir(workspaceRoot, cwd)
	if err != nil {
		fmt.Fprintf(stderr, "mac: run mac from inside the workspace (%s): %v\n", workspaceRoot, err)
		return 2
	}
	var pullPaths []string
	for _, p := range pulls {
		rel, err := guestproto.CleanMacPath(filepath.ToSlash(filepath.Join(relCwd, p)), false)
		if err != nil {
			fmt.Fprintf(stderr, "mac: --pull %s: %v\n", p, err)
			return 2
		}
		pullPaths = append(pullPaths, rel)
	}

	c := &macclient.Client{BaseURL: "http://" + microvm.InternalMacHost, Status: stderr}
	if err := c.Start(ctx); err != nil {
		fmt.Fprintf(stderr, "mac: %v\n", err)
		return 1
	}
	if !*noSync {
		top, err := gitTopLevel(ctx, cwd)
		if err != nil {
			fmt.Fprintf(stderr, "mac: %v (run mac inside a git checkout, or pass --no-sync)\n", err)
			return 2
		}
		m, err := macclient.ListFiles(ctx, workspaceRoot, top)
		if err != nil {
			fmt.Fprintf(stderr, "mac: %v\n", err)
			return 1
		}
		if _, err := c.Sync(ctx, workspaceRoot, m); err != nil {
			fmt.Fprintf(stderr, "mac: sync to the macOS VM: %v\n", err)
			return 1
		}
	}

	code, err := c.Exec(ctx, guestproto.MacExecReq{Argv: argv, Dir: relCwd, Env: env}, stdout, stderr)
	if err != nil {
		fmt.Fprintf(stderr, "mac: %v\n", err)
		if code <= 0 {
			code = 1
		}
	}
	if len(pullPaths) > 0 && ctx.Err() == nil {
		if perr := c.Pull(ctx, workspaceRoot, pullPaths, stderr); perr != nil {
			fmt.Fprintf(stderr, "mac: --pull: %v\n", perr)
			if code == 0 {
				code = 1
			}
		}
	}
	return code
}

func gitTopLevel(ctx context.Context, dir string) (string, error) {
	out, err := exec.CommandContext(ctx, "git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return "", fmt.Errorf("%s isn't in a git checkout", dir)
	}
	top := strings.TrimSpace(string(out))
	if resolved, err := filepath.EvalSymlinks(top); err == nil {
		top = resolved
	}
	return top, nil
}

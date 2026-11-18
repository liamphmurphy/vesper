package runner

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// TurnGateBackend lets a chat turn's harness start before the turn's
// services and Docker API are up: a cold VM spends seconds starting dockerd
// and waiting for a database to become healthy, and most turns read code or
// just answer before they need either. The gate is a bash startup file
// (BASH_ENV) that makes each shell command wait for the backend's ready
// marker, then exports what the environment exposes. File reads and MCP tools
// never wait; only shell commands, which are how tests reach services.
type TurnGateBackend interface {
	// OpenTurnGate installs the gate for one turn (key) and returns the env
	// that applies it to the turn's processes.
	OpenTurnGate(ctx context.Context, runID, key string) (map[string]string, error)
	// ReleaseTurnGate lets the turn's shell commands through with env
	// exported, or prints failure when the environment couldn't start.
	ReleaseTurnGate(ctx context.Context, runID, key string, env map[string]string, failure string) error
	// CloseTurnGate removes the gate's files once the turn has ended.
	CloseTurnGate(ctx context.Context, runID, key string)
}

const (
	gateScriptFile = "gate.sh"
	gateEnvFile    = "env"
	gateReadyFile  = "ready"
	gateFailedFile = "failed"
	// gateWaitTenths bounds the wait at 8 minutes, past the longest service
	// start (an image pull plus becoming healthy), so a runner that died
	// mid-start can't hang a command forever.
	gateWaitTenths = 4800
)

// turnGateScript is the BASH_ENV file for a gate whose markers are in dir.
// It runs at the start of every non-interactive bash (each harness shell
// command, and bash scripts those start); sh scripts don't read it and
// inherit what it exported instead.
func turnGateScript(dir string) []byte {
	d := shellQuote(dir)
	return []byte(`# Vesper: this turn's services and Docker API start alongside it.
__vesper_gate=` + d + `
if [ ! -e "$__vesper_gate/` + gateReadyFile + `" ] && [ ! -e "$__vesper_gate/` + gateFailedFile + `" ]; then
  echo "vesper: waiting for this turn's services to start..." >&2
  __vesper_i=0
  while [ ! -e "$__vesper_gate/` + gateReadyFile + `" ] && [ ! -e "$__vesper_gate/` + gateFailedFile + `" ] && [ "$__vesper_i" -lt ` + fmt.Sprint(gateWaitTenths) + ` ]; do
    sleep 0.1
    __vesper_i=$((__vesper_i + 1))
  done
  unset __vesper_i
  if [ ! -e "$__vesper_gate/` + gateReadyFile + `" ] && [ ! -e "$__vesper_gate/` + gateFailedFile + `" ]; then
    echo "vesper: gave up waiting for this turn's services" >&2
  fi
fi
if [ -e "$__vesper_gate/` + gateFailedFile + `" ]; then
  cat "$__vesper_gate/` + gateFailedFile + `" >&2
fi
if [ -e "$__vesper_gate/` + gateEnvFile + `" ]; then
  . "$__vesper_gate/` + gateEnvFile + `"
fi
unset __vesper_gate
`)
}

var shellVarName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// turnGateEnv is env as shell exports, skipping names a shell can't hold.
func turnGateEnv(env map[string]string) []byte {
	keys := make([]string, 0, len(env))
	for k := range env {
		if shellVarName.MatchString(k) {
			keys = append(keys, k)
		}
	}
	sort.Strings(keys)
	var b strings.Builder
	for _, k := range keys {
		b.WriteString("export " + k + "=" + shellQuote(env[k]) + "\n")
	}
	return []byte(b.String())
}

func turnGateFailure(failure string) []byte {
	return []byte("vesper: this turn's services didn't start: " + failure + "\n")
}

// The fake backend keeps a gate's files on the host, beside the run's
// workspace; its turns are host processes.
func (l *Fake) gateDir(runID, key string) string {
	return filepath.Join(filepath.Dir(l.WorkspaceDir(runID)), "gates", key)
}

func (l *Fake) OpenTurnGate(_ context.Context, runID, key string) (map[string]string, error) {
	dir := l.gateDir(runID, key)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	script := filepath.Join(dir, gateScriptFile)
	if err := os.WriteFile(script, turnGateScript(dir), 0o644); err != nil {
		return nil, err
	}
	return map[string]string{"BASH_ENV": script}, nil
}

func (l *Fake) ReleaseTurnGate(_ context.Context, runID, key string, env map[string]string, failure string) error {
	dir := l.gateDir(runID, key)
	if failure != "" {
		return os.WriteFile(filepath.Join(dir, gateFailedFile), turnGateFailure(failure), 0o644)
	}
	// The env is complete before ready appears: commands check ready first.
	if err := os.WriteFile(filepath.Join(dir, gateEnvFile), turnGateEnv(env), 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, gateReadyFile), nil, 0o644)
}

func (l *Fake) CloseTurnGate(_ context.Context, runID, key string) {
	_ = os.RemoveAll(l.gateDir(runID, key))
}

package runner

import (
	"context"
	_ "embed"
	"encoding/json"
	"path/filepath"
	"strings"
)

//go:embed dependencies.py
var dependencySetup string

// Dependency setup is opt-in through a versioned file in the checkout. The
// runner owns execution, including for read-only delegated agents.
func dependencySetupScript() string {
	return "python3 -c " + shellQuote(dependencySetup) + "\n"
}

// CacheBackend supplies a persistent cache shared by this runner's workspaces.
// Package installations remain checkout-local; download, browser and Go build
// caches are shared, so a new chat doesn't compile its dependencies from
// scratch (Go's build cache is safe for concurrent builds). These caches are
// intended for one trusted user's projects.
type CacheBackend interface{ DependencyCacheDir() string }

func (l *Fake) DependencyCacheDir() string {
	dir, _ := filepath.Abs(filepath.Join(l.Dir, "cache"))
	return dir
}

func dependencyEnv(cache, workspace string) map[string]string {
	return map[string]string{
		"GOMODCACHE":               filepath.Join(cache, "go-mod"),
		"GOCACHE":                  filepath.Join(cache, "go-build"),
		"npm_config_cache":         filepath.Join(cache, "npm"),
		"PLAYWRIGHT_BROWSERS_PATH": filepath.Join(cache, "playwright"),
	}
}

// recordEnvironment strips machine-readable setup metadata from the human log
// and stores it as a lifecycle event. Snapshots survive workspace cleanup.
func (r *Runner) recordEnvironment(ctx context.Context, c runCtx, output string, failed bool) string {
	const prefix = "LAZYAGENTS_ENVIRONMENT="
	var log []string
	for _, line := range strings.Split(output, "\n") {
		if !strings.HasPrefix(line, prefix) {
			log = append(log, line)
			continue
		}
		var report map[string]any
		if json.Unmarshal([]byte(strings.TrimPrefix(line, prefix)), &report) != nil || report == nil {
			continue
		}
		if failed && report["status"] != "failed" {
			report["status"] = "failed"
			report["error"] = "Workspace setup failed after dependency preparation. Open the run log for details."
		}
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{
			"state": "environment_snapshot", "runner_id": r.Cfg.ID, "backend": r.Backend.Name(), "report": report,
		})
	}
	return strings.Join(log, "\n")
}

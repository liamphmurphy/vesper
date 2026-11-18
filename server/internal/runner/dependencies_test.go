package runner

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDependencySetup(t *testing.T) {
	root := t.TempDir()
	bin := filepath.Join(root, "bin")
	for _, dir := range []string{bin, filepath.Join(root, "web"), filepath.Join(root, "server")} {
		if err := os.MkdirAll(dir, 0755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), 0755); err != nil {
			t.Fatal(err)
		}
	}
	write("bin/node", "#!/bin/sh\necho v24\n")
	write("bin/npm", "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 11; else echo install >> ../installs; mkdir -p node_modules; fi\n")
	write("bin/go", "#!/bin/sh\necho download >> ../downloads\n")
	write("server/go.mod", "module test\n")
	write("web/package.json", `{"dependencies":{"example":"^1.0.0"}}`)
	write("web/package-lock.json", `{"packages":{"node_modules/example":{"version":"1.2.3"}}}`)
	write(".lazyagents-deps.json", `{"version":1,"required_tools":["go","npm"],"go_modules":["server"],"npm_projects":["web"]}`)
	run := func() ([]byte, error) {
		cmd := exec.Command("python3", "-c", dependencySetup)
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"), "GOMODCACHE="+filepath.Join(root, "cache", "go-mod"))
		return cmd.CombinedOutput()
	}
	var lastReport map[string]any
	readReport := func(out []byte) map[string]any {
		t.Helper()
		for _, line := range strings.Split(string(out), "\n") {
			if value, ok := strings.CutPrefix(line, "LAZYAGENTS_ENVIRONMENT="); ok {
				var report map[string]any
				if err := json.Unmarshal([]byte(value), &report); err != nil {
					t.Fatal(err)
				}
				return report
			}
		}
		t.Fatal("environment snapshot missing")
		return nil
	}
	for i := 0; i < 2; i++ {
		out, err := run()
		if err != nil {
			t.Fatalf("%v %s", err, out)
		}
		lastReport = readReport(out)
	}
	if lastReport["status"] != "ready" || len(lastReport["tools"].([]any)) != 2 {
		t.Fatal(lastReport)
	}
	packages := lastReport["packages"].([]any)
	if len(packages) != 1 || packages[0].(map[string]any)["version"] != "1.2.3" {
		t.Fatal(packages)
	}
	caches := lastReport["caches"].([]any)
	if len(caches) == 0 || caches[0].(map[string]any)["shared"] != true {
		t.Fatal(caches)
	}
	b, _ := os.ReadFile(filepath.Join(root, "installs"))
	if string(b) != "install\n" {
		t.Fatalf("reinstalled unchanged lock: %s", b)
	}
	write("web/package-lock.json", `{"changed":true}`)
	if out, err := run(); err != nil {
		t.Fatalf("%v %s", err, out)
	}
	b, _ = os.ReadFile(filepath.Join(root, "installs"))
	if string(b) != "install\ninstall\n" {
		t.Fatalf("did not refresh changed lock: %s", b)
	}
	write(".lazyagents-deps.json", `{"version":1,"required_tools":["not-a-real-tool-lazyagents"]}`)
	out, err := run()
	if err == nil || !strings.Contains(string(out), "missing required tool") {
		t.Fatalf("%v %s", err, out)
	}
	failed := readReport(out)
	if failed["status"] != "failed" || failed["error"] == nil {
		t.Fatal(failed)
	}
	write(".lazyagents-deps.json", `{"version":1,"npm_projects":["../escape"]}`)
	if out, err := run(); err == nil || !strings.Contains(string(out), "inside the checkout") {
		t.Fatalf("%v %s", err, out)
	}
	write(".lazyagents-deps.json", `{"version":1,"npm_projects":["web"]}`)
	write("bin/npm", "#!/bin/sh\nif [ \"$1\" = --version ]; then echo 12; else exit 42; fi\n")
	if out, err := run(); err == nil || !strings.Contains(string(out), "Environment setup failed") {
		t.Fatalf("%v %s", err, out)
	}
}

func TestLocalDependencyCachesAreSharedAcrossWorkspaces(t *testing.T) {
	l := &Fake{Dir: t.TempDir()}
	for _, id := range []string{"one", "two"} {
		if err := l.EnsureWorkspace(context.Background(), id); err != nil {
			t.Fatal(err)
		}
		p, err := l.Start(context.Background(), id, ExecSpec{Argv: []string{"sh", "-c", `printf '%s\n' "$GOMODCACHE" "$GOCACHE" "$npm_config_cache" "$PLAYWRIGHT_BROWSERS_PATH"`}})
		if err != nil {
			t.Fatal(err)
		}
		// Drain before Wait, matching the runner's pipe contract.
		var b strings.Builder
		done := make(chan struct{})
		go func() { _, _ = io.Copy(&b, p.Stdout()); close(done) }()
		code, err := p.Wait()
		<-done
		if err != nil || code != 0 {
			t.Fatalf("%d %v", code, err)
		}
		if closer, ok := p.(interface{ Close() error }); ok {
			_ = closer.Close()
		}
		lines := strings.Split(strings.TrimSpace(b.String()), "\n")
		if len(lines) != 4 || lines[0] != filepath.Join(l.DependencyCacheDir(), "go-mod") || lines[1] != filepath.Join(l.DependencyCacheDir(), "go-build") {
			t.Fatal(lines)
		}
	}
}

// A coding chat's setup leaves Playwright's browsers to the first browser
// test; other setups (tickets, delegated worktrees) still install them.
func TestChatDependencySetupLeavesBrowsersToFirstUse(t *testing.T) {
	root := t.TempDir()
	bin := filepath.Join(root, "bin")
	cli := filepath.Join(root, "web", "node_modules", "playwright")
	for _, dir := range []string{bin, cli} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(name, content string, mode os.FileMode) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(root, name), []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	write("bin/node", "#!/bin/sh\nif [ \"$1\" = --version ]; then echo v24; else echo \"$2 $3\" >> \"$BROWSER_LOG\"; fi\n", 0o755)
	write("bin/npm", "#!/bin/sh\necho 11\n", 0o755)
	write("web/package.json", `{}`, 0o644)
	write("web/package-lock.json", `{}`, 0o644)
	write("web/node_modules/playwright/cli.js", "", 0o644)
	write(".lazyagents-deps.json", `{"version":1,"npm_projects":["web"],"playwright":["web"]}`, 0o644)
	browserLog := filepath.Join(root, "browsers")
	run := func(script string) string {
		t.Helper()
		cmd := exec.Command("sh", "-c", script)
		cmd.Dir = root
		cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"), "BROWSER_LOG="+browserLog)
		out, err := cmd.CombinedOutput()
		if err != nil || !strings.Contains(string(out), "dependencies ready") {
			t.Fatalf("%v %s", err, out)
		}
		return string(out)
	}

	out := run(chatDependencySetupScript())
	if _, err := os.Stat(browserLog); err == nil {
		t.Fatal("a chat's setup installed Playwright's browsers")
	}
	if !strings.Contains(out, "npx playwright install chromium") {
		t.Fatalf("setup log doesn't say how to install the browsers: %s", out)
	}

	run(dependencySetupScript())
	if b, _ := os.ReadFile(browserLog); string(b) != "install chromium\n" {
		t.Fatalf("other setups' browser installs: %q", b)
	}
}

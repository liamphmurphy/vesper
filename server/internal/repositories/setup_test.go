package repositories

import (
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestSetupScriptWithFork(t *testing.T) {
	tmp := t.TempDir()
	bare := filepath.Join(tmp, "origin.git")
	work := filepath.Join(tmp, "seed")
	run := func(dir string, args ...string) string {
		t.Helper()
		cmd := exec.Command("git", args...)
		cmd.Dir = dir
		cmd.Env = append(cmd.Environ(),
			"GIT_AUTHOR_NAME=Tester",
			"GIT_AUTHOR_EMAIL=test@example.com",
			"GIT_COMMITTER_NAME=Tester",
			"GIT_COMMITTER_EMAIL=test@example.com",
		)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v in %s failed: %v\n%s", args, dir, err, out)
		}
		return strings.TrimSpace(string(out))
	}

	run(tmp, "init", "--bare", bare)
	run(tmp, "clone", bare, work)
	run(work, "checkout", "-B", "main")
	run(work, "commit", "--allow-empty", "-m", "first")
	sha1 := run(work, "rev-parse", "HEAD")
	run(work, "commit", "--allow-empty", "-m", "second")
	sha2 := run(work, "rev-parse", "HEAD")
	if sha1 == sha2 {
		t.Fatal("expected distinct commits")
	}
	run(work, "push", "-u", "origin", "main")

	forkBranch := "feat/fork-point"
	script := SetupScriptWithFork("file://"+bare, "checkout", []string{"feat/existing"}, &sha1, &forkBranch, "Tester", "test@example.com")
	if !strings.Contains(script, "feat/fork-point") {
		t.Fatalf("expected fork branch in script:\n%s", script)
	}
	if !strings.Contains(PrePushHook([]string{forkBranch}), forkBranch) {
		t.Fatalf("expected fork branch in pre-push hook")
	}

	ws := filepath.Join(tmp, "ws")
	cmd := exec.Command("sh", "-c", script)
	cmd.Dir = tmp
	if err := exec.Command("mkdir", "-p", ws).Run(); err != nil {
		t.Fatal(err)
	}
	cmd.Dir = ws
	cmd.Env = append(cmd.Environ(), "GH_TOKEN=dummy")
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("setup script failed: %v\n%s\nscript:\n%s", err, out, script)
	}

	repoDir := filepath.Join(ws, "checkout")
	gotBranch := run(repoDir, "rev-parse", "--abbrev-ref", "HEAD")
	if gotBranch != forkBranch {
		t.Fatalf("got branch %q, want %q", gotBranch, forkBranch)
	}
	gotHead := run(repoDir, "rev-parse", "HEAD")
	if gotHead != sha1 {
		t.Fatalf("got HEAD %q, want fork-point commit %q (not %q)", gotHead, sha1, sha2)
	}
	gotCfg := run(repoDir, "config", "--get-all", BranchConfig)
	if !strings.Contains(gotCfg, forkBranch) {
		t.Fatalf("expected %s=%q in git config, got %q", BranchConfig, forkBranch, gotCfg)
	}
}

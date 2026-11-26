package runner

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureSafeHostGitConfigRefusesSymlinksAndNeutralizesExecKeys(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	b := &MicroVM{}

	// 1. Symlinked .git pointing outside hostDir must NOT be touched.
	outsideRepo := t.TempDir()
	outsideGit := filepath.Join(outsideRepo, ".git")
	if err := os.MkdirAll(outsideGit, 0o755); err != nil {
		t.Fatal(err)
	}
	outsideCfg := filepath.Join(outsideGit, "config")
	origOutside := "[core]\n\trepositoryformatversion = 0\n"
	if err := os.WriteFile(outsideCfg, []byte(origOutside), 0o644); err != nil {
		t.Fatal(err)
	}
	hostDir1 := t.TempDir()
	if err := os.Symlink(outsideGit, filepath.Join(hostDir1, ".git")); err != nil {
		t.Fatal(err)
	}
	b.ensureSafeHostGitConfig(hostDir1)
	if got, _ := os.ReadFile(outsideCfg); string(got) != origOutside {
		t.Fatalf("symlinked .git modified outside config:\n%s", got)
	}

	// 2. Symlinked .git/config pointing outside hostDir must NOT be touched.
	outsideTarget := filepath.Join(t.TempDir(), "target.conf")
	if err := os.WriteFile(outsideTarget, []byte("untouched\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	hostDir2 := t.TempDir()
	if err := os.MkdirAll(filepath.Join(hostDir2, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outsideTarget, filepath.Join(hostDir2, ".git", "config")); err != nil {
		t.Fatal(err)
	}
	b.ensureSafeHostGitConfig(hostDir2)
	if got, _ := os.ReadFile(outsideTarget); string(got) != "untouched\n" {
		t.Fatalf("symlinked .git/config modified outside target:\n%s", got)
	}

	// 3. Real .git/config with guest-planted execution directives gets neutralized
	// while benign remote settings stay intact.
	hostDir3 := t.TempDir()
	gitDir3 := filepath.Join(hostDir3, ".git")
	if err := os.MkdirAll(gitDir3, 0o755); err != nil {
		t.Fatal(err)
	}
	planted := `[core]
	repositoryformatversion = 0
	hooksPath = /tmp/evil-hooks
	fsmonitor = /tmp/evil-fsmon
	sshCommand = /tmp/evil-ssh
	pager = /tmp/evil-pager
[diff]
	external = /tmp/evil-diff
[credential]
	helper = /tmp/evil-cred
[filter "evil"]
	smudge = /tmp/evil-smudge
	clean = /tmp/evil-clean
	process = /tmp/evil-proc
[remote "origin"]
	url = https://github.com/example/repo.git
`
	cfg3 := filepath.Join(gitDir3, "config")
	if err := os.WriteFile(cfg3, []byte(planted), 0o644); err != nil {
		t.Fatal(err)
	}
	b.ensureSafeHostGitConfig(hostDir3)
	gotBytes, err := os.ReadFile(cfg3)
	if err != nil {
		t.Fatal(err)
	}
	got := string(gotBytes)
	if !strings.Contains(got, "hooksPath = /dev/null") {
		t.Errorf("expected core.hooksPath = /dev/null, got:\n%s", got)
	}
	if !strings.Contains(got, "fsmonitor = false") {
		t.Errorf("expected core.fsmonitor = false, got:\n%s", got)
	}
	for _, forbidden := range []string{
		"/tmp/evil-hooks", "/tmp/evil-fsmon", "/tmp/evil-ssh",
		"/tmp/evil-pager", "/tmp/evil-diff", "/tmp/evil-cred",
		"/tmp/evil-smudge", "/tmp/evil-clean", "/tmp/evil-proc",
	} {
		if strings.Contains(got, forbidden) {
			t.Errorf("dangerous config value %q survived neutralization:\n%s", forbidden, got)
		}
	}
	if !strings.Contains(got, "https://github.com/example/repo.git") {
		t.Errorf("benign remote config was lost:\n%s", got)
	}
}

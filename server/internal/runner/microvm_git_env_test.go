package runner

import (
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// Git credentials stay on the host: the fetch proxy and host-side pushes use
// them, so no form of one reaches a VM process's environment.
func TestMicroVMKeepsGitCredentialsOnTheHost(t *testing.T) {
	for _, k := range []string{SSHKeyEnv, "GH_TOKEN", "GITHUB_TOKEN", envName("git:pat"), ClaudeAuthEnv, CodexAuthEnv, AntigravityAuthEnv} {
		if !hostOnlyEnv(k) {
			t.Errorf("%s would enter the VM", k)
		}
	}
	for _, k := range []string{"DATABASE_URL", "OPENAI_API_KEY", "PATH"} {
		if hostOnlyEnv(k) {
			t.Errorf("%s is stripped but isn't a host-only credential", k)
		}
	}
}

// With no SSH key in the VM, SSH remotes on github.com must fetch through
// the host proxy like HTTPS ones. git itself resolves the URLs here.
func TestMicroVMRoutesGitHubRemotesThroughTheProxy(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not installed")
	}
	env := map[string]string{"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.autocrlf", "GIT_CONFIG_VALUE_0": "false"}
	rewriteGitInsteadOfEnv(env, "")
	proxy := "http://" + microvm.InternalGitHost + "/github/"
	for remote, want := range map[string]string{
		"https://github.com/org/repo.git":      proxy + "org/repo.git",
		"git@github.com:org/repo.git":          proxy + "org/repo.git",
		"ssh://git@github.com/org/repo.git":    proxy + "org/repo.git",
		"ssh://git@github.com:22/org/repo.git": proxy + "org/repo.git",
		"git@gitlab.com:org/repo.git":          "git@gitlab.com:org/repo.git",
		"https://example.com/github.com/x.git": "https://example.com/github.com/x.git",
	} {
		cmd := exec.Command("git", "ls-remote", "--get-url", remote)
		cmd.Dir = t.TempDir()
		cmd.Env = append(os.Environ(), "HOME="+t.TempDir(), "GIT_CONFIG_NOSYSTEM=1")
		for k, v := range env {
			cmd.Env = append(cmd.Env, k+"="+v)
		}
		out, err := cmd.Output()
		if err != nil {
			t.Fatalf("git ls-remote --get-url %s: %v", remote, err)
		}
		if got := strings.TrimSpace(string(out)); got != want {
			t.Errorf("%s resolves to %s, want %s", remote, got, want)
		}
	}
	if env["GIT_CONFIG_KEY_0"] != "core.autocrlf" {
		t.Error("existing GIT_CONFIG entries must be kept")
	}
}

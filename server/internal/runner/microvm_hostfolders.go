package runner

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const hostWorkspaceMarker = "host_workspace"

var errHostWorkspacesOff = errors.New("runner: RUNNER_HOST_WORKSPACES_DIR is not set")

var _ HostFolders = (*MicroVM)(nil)

func (b *MicroVM) HostWorkspacesDir() string {
	return b.HostWorkspaces
}

func (b *MicroVM) EnsureHostWorkspace(_ context.Context, runID string) (string, error) {
	if b.HostWorkspaces == "" {
		return "", errHostWorkspacesOff
	}
	key, err := safeVMRunKey(runID)
	if err != nil {
		return "", err
	}
	hostDir := filepath.Join(b.HostWorkspaces, key)
	if err := os.MkdirAll(hostDir, 0o755); err != nil {
		return "", err
	}
	runStateDir, err := b.runDir(runID)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(runStateDir, 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(runStateDir, hostWorkspaceMarker), []byte(hostDir), 0o644); err != nil {
		return "", err
	}
	b.ensureSafeHostGitConfig(hostDir)
	return hostDir, nil
}

func (b *MicroVM) hostWorkspacePath(runID string) (string, bool) {
	dir, err := b.runDir(runID)
	if err != nil {
		return "", false
	}
	raw, err := os.ReadFile(filepath.Join(dir, hostWorkspaceMarker))
	if err != nil {
		return "", false
	}
	hostDir := strings.TrimSpace(string(raw))
	if hostDir == "" || !filepath.IsAbs(hostDir) {
		return "", false
	}
	return hostDir, true
}

// ensureSafeHostGitConfig neutralizes repository-local git execution settings
// inside shared virtiofs workspaces so opening the folder on macOS cannot run
// guest-planted hooks, fsmonitor, sshCommand, diff.external, credential helpers,
// or filter drivers. Both .git and .git/config are verified via os.Root + Lstat
// so guest-created symlinks cannot direct host git config writes outside hostDir.
func (b *MicroVM) ensureSafeHostGitConfig(hostDir string) {
	root, err := os.OpenRoot(hostDir)
	if err != nil {
		return
	}
	defer root.Close()

	gitInfo, err := root.Lstat(".git")
	if err != nil || gitInfo.Mode()&os.ModeSymlink != 0 || !gitInfo.IsDir() {
		return
	}
	cfgInfo, err := root.Lstat(filepath.Join(".git", "config"))
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			return
		}
	} else if cfgInfo.Mode()&os.ModeSymlink != 0 || !cfgInfo.Mode().IsRegular() {
		return
	}

	realHost, err := filepath.EvalSymlinks(hostDir)
	if err != nil {
		return
	}
	gitDir := filepath.Join(hostDir, ".git")
	realGit, err := filepath.EvalSymlinks(gitDir)
	if err != nil || realGit != filepath.Join(realHost, ".git") {
		return
	}
	cfgPath := filepath.Join(realGit, "config")
	if cfgInfo != nil {
		realCfg, cerr := filepath.EvalSymlinks(cfgPath)
		if cerr != nil || realCfg != cfgPath {
			return
		}
	}

	gitBin, gerr := exec.LookPath("git")
	if gerr != nil {
		return
	}
	gitEnv := []string{
		"PATH=" + os.Getenv("PATH"),
		"GIT_CONFIG_NOSYSTEM=1",
		"GIT_CONFIG_GLOBAL=/dev/null",
	}
	runGitConfig := func(args ...string) ([]byte, error) {
		full := append([]string{"config", "--file", cfgPath}, args...)
		cmd := exec.Command(gitBin, full...)
		cmd.Env = gitEnv
		return cmd.Output()
	}

	_, _ = runGitConfig("core.hooksPath", "/dev/null")
	_, _ = runGitConfig("core.fsmonitor", "false")
	for _, key := range []string{
		"core.sshCommand",
		"core.pager",
		"core.editor",
		"core.askPass",
		"diff.external",
		"credential.helper",
	} {
		_, _ = runGitConfig("--unset-all", key)
	}
	if out, err := runGitConfig("--name-only", "--get-regexp", `^filter\..*\.(clean|smudge|process)$`); err == nil {
		seen := map[string]struct{}{}
		for _, line := range strings.Split(string(out), "\n") {
			key := strings.TrimSpace(line)
			if key == "" {
				continue
			}
			if _, ok := seen[key]; ok {
				continue
			}
			seen[key] = struct{}{}
			_, _ = runGitConfig("--unset-all", key)
		}
	}
}

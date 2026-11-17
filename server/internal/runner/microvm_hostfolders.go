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

// ensureSafeHostGitConfig disables repository-local git hooks inside shared
// virtiofs workspaces so opening the folder on macOS cannot execute guest-written hooks.
func (b *MicroVM) ensureSafeHostGitConfig(hostDir string) {
	gitDir := filepath.Join(hostDir, ".git")
	info, err := os.Stat(gitDir)
	if err != nil || !info.IsDir() {
		return
	}
	if gitBin, gerr := exec.LookPath("git"); gerr == nil {
		_ = exec.Command(gitBin, "-C", hostDir, "config", "--local", "core.hooksPath", "/dev/null").Run()
	}
}

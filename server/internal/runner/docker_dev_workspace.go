package runner

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/devworkspace"
)

const devWorkspaceLabelKey = "dev.lazyagents.dev-workspace"

// DevPTY is an interactive terminal session inside a dev-workspace container.
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

func (d *Docker) devWorkspaceKey(workspaceID uuid.UUID) string {
	h := strings.ReplaceAll(workspaceID.String(), "-", "")
	return h[len(h)-12:]
}

func (d *Docker) devWorkspaceContainerName(workspaceID uuid.UUID) string {
	return "lazyagents-dev-" + d.stack() + "-" + d.devWorkspaceKey(workspaceID)
}

func (d *Docker) devWorkspaceVolumeName(workspaceID uuid.UUID) string {
	return "lazyagents-dev-ws-" + d.stack() + "-" + d.devWorkspaceKey(workspaceID)
}

func (d *Docker) devWorkspaceHomeVolumeName(workspaceID uuid.UUID) string {
	return "lazyagents-dev-home-" + d.stack() + "-" + d.devWorkspaceKey(workspaceID)
}

// EnsureDevWorkspaceContainer creates and starts the persistent dev-workspace
// container for workspaceID if it isn't already running.
func (d *Docker) EnsureDevWorkspaceContainer(ctx context.Context, workspaceID uuid.UUID) (string, error) {
	name := d.devWorkspaceContainerName(workspaceID)
	var info struct {
		ID    string
		State struct{ Running bool }
	}
	_, err := d.do(ctx, "GET", "/containers/"+url.PathEscape(name)+"/json", nil, "", &info)
	switch {
	case err == nil && info.State.Running:
		return info.ID, nil
	case err == nil:
		if _, err := d.do(ctx, "POST", "/containers/"+url.PathEscape(name)+"/start", nil, "", nil); err != nil && !isStatus(err, 304) {
			return "", fmt.Errorf("start dev workspace container: %w", err)
		}
		return info.ID, nil
	case !isStatus(err, 404):
		return "", fmt.Errorf("inspect dev workspace container: %w", err)
	}

	if err := d.EnsureNixDaemon(ctx); err != nil {
		return "", err
	}
	for _, vol := range []string{d.devWorkspaceVolumeName(workspaceID), d.devWorkspaceHomeVolumeName(workspaceID)} {
		if _, err := d.do(ctx, "POST", "/volumes/create", jsonBody(map[string]any{
			"Name":   vol,
			"Labels": map[string]string{stackLabelKey: d.stack(), devWorkspaceLabelKey: workspaceID.String()},
		}), "application/json", nil); err != nil {
			return "", fmt.Errorf("create dev workspace volume %s: %w", vol, err)
		}
	}

	mounts := []map[string]any{
		{"Type": "volume", "Source": d.devWorkspaceVolumeName(workspaceID), "Target": workspacePath},
		{"Type": "volume", "Source": d.devWorkspaceHomeVolumeName(workspaceID), "Target": homePath},
	}
	if nm := d.nixMount(); nm != nil {
		mounts = append(mounts, nm)
	}

	env := []string{
		"HOME=" + homePath,
		"NIX_REMOTE=daemon",
		"TERM=xterm-256color",
		"PATH=" + devworkspace.ProfilePath + "/bin:" + homePath + "/.nix-profile/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin",
	}
	// No labelKey: Cleanup removes leftover turns, and this container persists.
	body := map[string]any{
		"Image":      d.Image,
		"Cmd":        []string{"sleep", "infinity"},
		"User":       "1000",
		"WorkingDir": workspacePath,
		"Env":        env,
		"Labels":     map[string]string{stackLabelKey: d.stack(), devWorkspaceLabelKey: workspaceID.String()},
		"HostConfig": map[string]any{
			"Mounts":      mounts,
			"Init":        true,
			"SecurityOpt": []string{"no-new-privileges"},
			"CapDrop":     []string{"ALL"},
		},
	}
	var created struct{ ID string }
	if _, err := d.do(ctx, "POST", "/containers/create?name="+url.QueryEscape(name), jsonBody(body), "application/json", &created); err != nil {
		return "", fmt.Errorf("create dev workspace container: %w", err)
	}
	if _, err := d.do(ctx, "POST", "/containers/"+url.PathEscape(created.ID)+"/start", nil, "", nil); err != nil && !isStatus(err, 304) {
		return "", fmt.Errorf("start dev workspace container: %w", err)
	}
	return created.ID, nil
}

// ExecDevWorkspaceScript runs a shell script inside the dev-workspace container.
func (d *Docker) ExecDevWorkspaceScript(ctx context.Context, containerID, script string, env []string) (string, int, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	fullEnv := append([]string{
		"HOME=" + homePath,
		"NIX_REMOTE=daemon",
		"PATH=" + devworkspace.ProfilePath + "/bin:" + homePath + "/.nix-profile/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin",
	}, env...)
	var created struct{ ID string }
	if _, err := d.do(ctx, "POST", "/containers/"+url.PathEscape(containerID)+"/exec", jsonBody(map[string]any{
		"Cmd":          []string{"sh", "-c", script},
		"User":         "1000",
		"WorkingDir":   workspacePath,
		"Env":          fullEnv,
		"AttachStdout": true,
		"AttachStderr": true,
	}), "application/json", &created); err != nil {
		return "", -1, err
	}
	res, err := d.do(ctx, "POST", "/exec/"+created.ID+"/start", jsonBody(map[string]any{"Detach": false, "Tty": false}), "application/json", nil)
	if err != nil {
		return "", -1, err
	}
	var out bytes.Buffer
	derr := demux(io.LimitReader(res.Body, 512<<10), &out, &out)
	res.Body.Close()
	if derr != nil {
		return out.String(), -1, derr
	}
	var info struct {
		ExitCode int
		Running  bool
	}
	if _, err := d.do(ctx, "GET", "/exec/"+created.ID+"/json", nil, "", &info); err != nil {
		return out.String(), -1, err
	}
	if info.Running {
		return out.String(), -1, fmt.Errorf("script still running when output ended")
	}
	return out.String(), info.ExitCode, nil
}

// StopDevWorkspaceContainer removes the running dev-workspace container while
// preserving its /workspace and /home/node volumes.
func (d *Docker) StopDevWorkspaceContainer(ctx context.Context, workspaceID uuid.UUID) error {
	name := d.devWorkspaceContainerName(workspaceID)
	_, err := d.do(ctx, "DELETE", "/containers/"+url.PathEscape(name)+"?force=1", nil, "", nil)
	if err != nil && !isStatus(err, 404) {
		return err
	}
	return nil
}

type dockerPTY struct {
	docker *Docker
	execID string
	conn   net.Conn
	br     *bufio.Reader
}

func (p *dockerPTY) Read(b []byte) (int, error)  { return p.br.Read(b) }
func (p *dockerPTY) Write(b []byte) (int, error) { return p.conn.Write(b) }
func (p *dockerPTY) Close() error                { return p.conn.Close() }

func (p *dockerPTY) Resize(ctx context.Context, cols, rows int) error {
	if cols <= 0 || rows <= 0 {
		return nil
	}
	_, err := p.docker.do(ctx, "POST", fmt.Sprintf("/exec/%s/resize?h=%d&w=%d", url.PathEscape(p.execID), rows, cols), nil, "", nil)
	return err
}

// OpenDevWorkspacePTY attaches an interactive TTY exec running tmux + LazyVim
// inside the workspace's dev container.
func (d *Docker) OpenDevWorkspacePTY(ctx context.Context, workspaceID uuid.UUID, cols, rows int) (DevPTY, error) {
	containerID, err := d.EnsureDevWorkspaceContainer(ctx, workspaceID)
	if err != nil {
		return nil, err
	}
	var created struct{ ID string }
	cmd := `if command -v tmux >/dev/null 2>&1; then exec tmux new-session -A -s dev -c /workspace 'if command -v nvim >/dev/null 2>&1; then exec nvim .; else exec sh; fi'; else exec sh; fi`
	if _, err := d.do(ctx, "POST", "/containers/"+url.PathEscape(containerID)+"/exec", jsonBody(map[string]any{
		"Cmd":          []string{"sh", "-lc", cmd},
		"User":         "1000",
		"WorkingDir":   workspacePath,
		"Tty":          true,
		"AttachStdin":  true,
		"AttachStdout": true,
		"AttachStderr": true,
		"Env": []string{
			"HOME=" + homePath,
			"NIX_REMOTE=daemon",
			"TERM=xterm-256color",
			"COLORTERM=truecolor",
			"PATH=" + devworkspace.ProfilePath + "/bin:" + homePath + "/.nix-profile/bin:/usr/local/go/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/nix/var/nix/profiles/default/bin",
		},
	}), "application/json", &created); err != nil {
		return nil, err
	}

	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", d.Socket)
	if err != nil {
		return nil, err
	}
	payload, _ := json.Marshal(map[string]any{"Detach": false, "Tty": true})
	req, err := http.NewRequestWithContext(ctx, "POST", "http://docker/v1.43/exec/"+url.PathEscape(created.ID)+"/start", bytes.NewReader(payload))
	if err != nil {
		conn.Close()
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "tcp")
	if err := req.Write(conn); err != nil {
		conn.Close()
		return nil, err
	}
	br := bufio.NewReader(conn)
	res, err := http.ReadResponse(br, req)
	if err != nil {
		conn.Close()
		return nil, err
	}
	if res.StatusCode != http.StatusSwitchingProtocols && res.StatusCode != http.StatusOK {
		res.Body.Close()
		conn.Close()
		return nil, fmt.Errorf("docker exec hijack: status %d", res.StatusCode)
	}
	pty := &dockerPTY{docker: d, execID: created.ID, conn: conn, br: br}
	if cols > 0 && rows > 0 {
		_ = pty.Resize(ctx, cols, rows)
	}
	return pty, nil
}

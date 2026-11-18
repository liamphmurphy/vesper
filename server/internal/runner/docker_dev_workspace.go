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

// ExecDevWorkspaceScript runs a shell script inside the dev-workspace container
// over stdin (`sh -s`) so large scripts (such as syncing hundreds of repos)
// never hit Linux's per-argument MAX_ARG_STRLEN limit.
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
		"Cmd":          []string{"sh", "-s"},
		"User":         "1000",
		"WorkingDir":   workspacePath,
		"Env":          fullEnv,
		"AttachStdin":  true,
		"AttachStdout": true,
		"AttachStderr": true,
		"Tty":          false,
	}), "application/json", &created); err != nil {
		return "", -1, err
	}

	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", d.Socket)
	if err != nil {
		return "", -1, fmt.Errorf("docker exec dial: %w", err)
	}
	defer conn.Close()

	done := make(chan struct{})
	defer close(done)
	go func() {
		select {
		case <-ctx.Done():
			_ = conn.Close()
		case <-done:
		}
	}()

	reqTimeout := d.RequestTimeout
	if reqTimeout <= 0 {
		reqTimeout = 30 * time.Second
	}
	_ = conn.SetDeadline(time.Now().Add(reqTimeout))

	payload, _ := json.Marshal(map[string]any{"Detach": false, "Tty": false})
	req, err := http.NewRequestWithContext(ctx, "POST", dockerAPI+"/exec/"+url.PathEscape(created.ID)+"/start", bytes.NewReader(payload))
	if err != nil {
		return "", -1, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", "tcp")
	if err := req.Write(conn); err != nil {
		return "", -1, fmt.Errorf("docker exec start write: %w", err)
	}
	br := bufio.NewReader(conn)
	res, err := http.ReadResponse(br, req)
	if err != nil {
		return "", -1, fmt.Errorf("docker exec start response: %w", err)
	}
	if res.StatusCode != http.StatusSwitchingProtocols && res.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(res.Body, 4096))
		res.Body.Close()
		return "", -1, fmt.Errorf("docker exec start: status %d %s", res.StatusCode, strings.TrimSpace(string(msg)))
	}
	_ = conn.SetDeadline(time.Time{})

	out := cappedBuffer{limit: 512 << 10}
	demuxErrCh := make(chan error, 1)
	go func() {
		demuxErrCh <- demux(br, &out, &out)
	}()

	if script != "" && !strings.HasSuffix(script, "\n") {
		script += "\n"
	}
	if _, err := io.WriteString(conn, script); err != nil {
		_ = conn.Close()
		<-demuxErrCh
		return out.buf.String(), -1, fmt.Errorf("docker exec stdin: %w", err)
	}
	if cw, ok := conn.(interface{ CloseWrite() error }); ok {
		_ = cw.CloseWrite()
	}

	if derr := <-demuxErrCh; derr != nil {
		return out.buf.String(), -1, derr
	}

	var info struct {
		ExitCode int
		Running  bool
	}
	if _, err := d.do(ctx, "GET", "/exec/"+url.PathEscape(created.ID)+"/json", nil, "", &info); err != nil {
		return out.buf.String(), -1, err
	}
	if info.Running {
		return out.buf.String(), -1, fmt.Errorf("script still running when output ended")
	}
	return out.buf.String(), info.ExitCode, nil
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
	// Use `sh -c` (not `-lc`) so Debian's /etc/profile does not overwrite the
	// Nix profile PATH before tmux/nvim/zsh are resolved.
	cmd := `if command -v tmux >/dev/null 2>&1; then exec tmux -u new-session -A -s dev -c /workspace 'if command -v nvim >/dev/null 2>&1; then nvim .; fi; if command -v zsh >/dev/null 2>&1; then exec zsh; else exec bash; fi'; elif command -v zsh >/dev/null 2>&1; then exec zsh; else exec bash; fi`
	if _, err := d.do(ctx, "POST", "/containers/"+url.PathEscape(containerID)+"/exec", jsonBody(map[string]any{
		"Cmd":          []string{"sh", "-c", cmd},
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
			"LANG=" + devTerminalLang,
			"SHELL=" + devworkspace.ProfilePath + "/bin/zsh",
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

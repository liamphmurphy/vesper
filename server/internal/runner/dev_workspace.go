package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"golang.org/x/net/websocket"

	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/devworkspace"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// devTerminalLang is the Dev workspace terminal's locale. Without a UTF-8
// one, tmux draws every non-ASCII character as "_" (box drawing, prompt
// glyphs, Claude Code's logo) and CLIs fall back to ASCII. The PTY's tmux is
// also started with -u, in case a user's shell config overrides LANG.
const devTerminalLang = "C.UTF-8"

func (r *Runner) devWorkspaceBackend() (DevWorkspaceBackend, bool) {
	db, ok := r.Backend.(DevWorkspaceBackend)
	return db, ok
}

// InitDevWorkspaces resets any stale dev-workspace ports from an earlier runner
// to stopped; the VM starts on demand when the Dev workspace is opened.
func (r *Runner) InitDevWorkspaces(ctx context.Context) {
	pb, ok := r.Backend.(PlaygroundBackend)
	if !ok {
		return
	}
	if err := r.q().StopStackDevWorkspaces(ctx, refOf(pb.StackName())); err != nil && ctx.Err() == nil {
		r.Log.Warn("dev workspace: reset stack state", "err", err)
	}
}

func (r *Runner) tickDevWorkspace(ctx context.Context) {
	if _, ok := r.devWorkspaceBackend(); !ok {
		return
	}
	if !r.devWSBusy.CompareAndSwap(false, true) {
		return
	}
	r.wg.Add(1)
	go func() {
		defer r.wg.Done()
		defer r.devWSBusy.Store(false)
		var stack *string
		if pb, ok := r.Backend.(PlaygroundBackend); ok {
			s := pb.StackName()
			stack = &s
		}
		row, err := r.q().ClaimDevWorkspaceAction(ctx, store.ClaimDevWorkspaceActionParams{
			RunnerID: &r.Cfg.ID,
			Stack:    stack,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			return
		}
		if err != nil {
			if ctx.Err() == nil {
				r.Log.Warn("dev workspace: claim action", "err", err)
			}
			return
		}
		r.runDevWorkspaceAction(ctx, row)
	}()
}

func (r *Runner) runDevWorkspaceAction(ctx context.Context, row store.ClaimDevWorkspaceActionRow) {
	db, ok := r.devWorkspaceBackend()
	if !ok {
		return
	}
	action := ""
	if row.ClaimedAction != nil {
		action = *row.ClaimedAction
	}
	if action == "stop" || !row.Enabled {
		r.releaseDevWorkspacePort(row.WorkspaceID)
		if err := db.StopDevWorkspaceContainer(ctx, row.WorkspaceID); err != nil {
			r.Log.Warn("dev workspace: stop container", "workspace", row.WorkspaceID, "err", err)
		}
		_ = r.q().UpdateDevWorkspaceState(ctx, store.UpdateDevWorkspaceStateParams{
			WorkspaceID: row.WorkspaceID,
			State:       "stopped",
		})
		return
	}

	fail := func(msg string) {
		r.releaseDevWorkspacePort(row.WorkspaceID)
		_ = r.q().UpdateDevWorkspaceState(ctx, store.UpdateDevWorkspaceStateParams{
			WorkspaceID: row.WorkspaceID,
			State:       "error",
			Error:       &msg,
		})
	}
	setStep := func(step string) {
		_ = r.q().UpdateDevWorkspaceState(ctx, store.UpdateDevWorkspaceStateParams{
			WorkspaceID: row.WorkspaceID,
			State:       "starting",
			Step:        &step,
		})
	}

	setStep("Starting container")
	containerID, err := db.EnsureDevWorkspaceContainer(ctx, row.WorkspaceID)
	if err != nil {
		fail(err.Error())
		return
	}

	var customZshrc, customTmuxConf, customGitconfig string
	if row.CustomZshrc != nil {
		customZshrc = *row.CustomZshrc
	}
	if row.CustomTmuxConf != nil {
		customTmuxConf = *row.CustomTmuxConf
	}
	if row.CustomGitconfig != nil {
		customGitconfig = *row.CustomGitconfig
	}

	var extraPackages []string
	_ = json.Unmarshal(row.ExtraPackages, &extraPackages)

	var arch *string
	var repos []devworkspace.RepoSpec
	_ = json.Unmarshal(row.Repos, &repos)

	if action == "open_branch" {
		if row.Arch == nil || row.Port == nil {
			setStep("Installing Nix + LazyVim")
			out, code, err := db.ExecDevWorkspaceScript(ctx, containerID, devworkspace.SetupNixScript(false, customZshrc, row.TmuxPrefix, customTmuxConf, customGitconfig, extraPackages), nil)
			if err != nil || code != 0 {
				fail(fmt.Sprintf("nix setup failed (exit %d): %s", code, lastLines(out, 20)))
				return
			}
			if a := parseArch(out); a != "" {
				arch = &a
			}
		}
		targetRepo := ""
		if row.ClaimedRepo != nil {
			targetRepo = strings.TrimSpace(*row.ClaimedRepo)
		}
		targetBranch := ""
		if row.ClaimedBranch != nil {
			targetBranch = strings.TrimSpace(*row.ClaimedBranch)
		}
		if targetRepo == "" || targetBranch == "" {
			fail("open branch failed: missing target repository or branch")
			return
		}
		prNum := 0
		if row.ClaimedPrNumber != nil {
			prNum = int(*row.ClaimedPrNumber)
		}
		dir := devworkspace.ResolveRepoDir(repos, targetRepo)
		setStep(fmt.Sprintf("Checking out %s in %s", targetBranch, dir))
		env := r.devWorkspaceGitEnv(ctx, row.WorkspaceID)
		userName, userEmail := r.devWorkspaceAuthor(ctx, row.WorkspaceID, row.UserID)
		out, code, err := db.ExecDevWorkspaceScript(ctx, containerID, devworkspace.OpenBranchScript(repos, targetRepo, targetBranch, prNum, userName, userEmail), env)
		if err != nil || code != 0 {
			msg := lastLines(out, 20)
			if err != nil && msg == "" {
				msg = err.Error()
			}
			fail(fmt.Sprintf("open branch failed (exit %d): %s", code, msg))
			return
		}
	} else {
		var archOut *string
		if action == "start" || action == "rebuild" {
			setStep("Installing Nix + LazyVim")
			out, code, err := db.ExecDevWorkspaceScript(ctx, containerID, devworkspace.SetupNixScript(action == "rebuild", customZshrc, row.TmuxPrefix, customTmuxConf, customGitconfig, extraPackages), nil)
			if err != nil || code != 0 {
				fail(fmt.Sprintf("nix setup failed (exit %d): %s", code, lastLines(out, 20)))
				return
			}
			if a := parseArch(out); a != "" {
				archOut = &a
			}
		} else if action == "sync" {
			setStep("Updating shell config")
			out, code, err := db.ExecDevWorkspaceScript(ctx, containerID, devworkspace.WriteShellConfigScript(customZshrc, row.TmuxPrefix, customTmuxConf, customGitconfig), nil)
			if err != nil || code != 0 {
				fail(fmt.Sprintf("shell config sync failed (exit %d): %s", code, lastLines(out, 20)))
				return
			}
		}
		if archOut != nil {
			arch = archOut
		}

		if len(repos) > 0 {
			env := r.devWorkspaceGitEnv(ctx, row.WorkspaceID)
			userName, userEmail := r.devWorkspaceAuthor(ctx, row.WorkspaceID, row.UserID)
			if err := syncDevWorkspaceRepos(ctx, db, containerID, repos, userName, userEmail, env, setStep); err != nil {
				fail(err.Error())
				return
			}
		}
	}

	port, ok := r.acquireDevWorkspacePort(row.WorkspaceID)
	if !ok {
		fail("no gateway port available (increase RUNNER_PLAYGROUND_PORTS or stop an idle playground)")
		return
	}
	var port32 int32 = int32(port)
	if err := r.q().UpdateDevWorkspaceState(ctx, store.UpdateDevWorkspaceStateParams{
		WorkspaceID: row.WorkspaceID,
		State:       "ready",
		Port:        &port32,
		Arch:        arch,
	}); err != nil {
		r.Log.Warn("dev workspace: update ready state", "err", err)
	}
}

const devWorkspaceRepoSyncBatchSize = 100

func syncDevWorkspaceRepos(
	ctx context.Context,
	db DevWorkspaceBackend,
	containerID string,
	repos []devworkspace.RepoSpec,
	userName, userEmail string,
	env []string,
	setStep func(string),
) error {
	for i := 0; i < len(repos); i += devWorkspaceRepoSyncBatchSize {
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("repo sync canceled: %w", err)
		}
		end := min(i+devWorkspaceRepoSyncBatchSize, len(repos))
		if len(repos) > devWorkspaceRepoSyncBatchSize {
			setStep(fmt.Sprintf("Syncing repositories (%d/%d)", i, len(repos)))
		} else {
			setStep("Syncing repositories")
		}
		out, code, err := db.ExecDevWorkspaceScript(ctx, containerID, devworkspace.SyncReposScript(repos[i:end], userName, userEmail), env)
		if err != nil || code != 0 {
			msg := lastLines(out, 20)
			if err != nil && msg == "" {
				msg = err.Error()
			}
			return fmt.Errorf("repo sync failed (exit %d): %s", code, msg)
		}
	}
	return nil
}

func (r *Runner) devWorkspaceGitEnv(ctx context.Context, workspaceID uuid.UUID) []string {
	if r.Secrets == nil {
		return nil
	}
	var env []string
	if tok, err := r.Secrets.Reveal(ctx, workspaceID, nil, "git:pat"); err == nil && tok != "" {
		env = append(env, "GH_TOKEN="+tok)
	}
	if key, err := r.Secrets.Reveal(ctx, workspaceID, nil, "git:ssh"); err == nil && key != "" {
		env = append(env, SSHKeyEnv+"="+key)
	}
	return env
}

func (r *Runner) devWorkspaceAuthor(ctx context.Context, workspaceID, userID uuid.UUID) (string, string) {
	u, err := r.q().GetUser(ctx, store.GetUserParams{ID: userID, WorkspaceID: workspaceID})
	if err != nil {
		return "Vesper User", "vesper@localhost"
	}
	name := strings.TrimSpace(u.Name)
	if name == "" {
		name = "Vesper User"
	}
	email := strings.TrimSpace(u.Email)
	if email == "" {
		email = "vesper@localhost"
	}
	return name, email
}

func parseArch(output string) string {
	lines := strings.Split(strings.TrimSpace(output), "\n")
	if len(lines) == 0 {
		return ""
	}
	switch strings.TrimSpace(lines[len(lines)-1]) {
	case "x86_64":
		return "x86_64-linux"
	case "aarch64", "arm64":
		return "aarch64-linux"
	default:
		return ""
	}
}

func (r *Runner) acquireDevWorkspacePort(workspaceID uuid.UUID) (int, bool) {
	if r.playgrounds == nil {
		return 0, false
	}
	r.playgrounds.mu.Lock()
	if p, ok := r.playgrounds.ports[workspaceID]; ok {
		r.playgrounds.mu.Unlock()
		r.playgrounds.gateway.RegisterCustomHandler(p, r.devWorkspaceHandler(workspaceID))
		return p, true
	}
	r.playgrounds.mu.Unlock()

	p, ok := r.playgrounds.take(workspaceID)
	if !ok {
		return 0, false
	}
	r.playgrounds.done(workspaceID)
	r.playgrounds.gateway.RegisterCustomHandler(p, r.devWorkspaceHandler(workspaceID))
	return p, true
}

func (r *Runner) releaseDevWorkspacePort(workspaceID uuid.UUID) {
	if r.playgrounds == nil {
		return
	}
	r.playgrounds.mu.Lock()
	p, ok := r.playgrounds.ports[workspaceID]
	r.playgrounds.mu.Unlock()
	if ok {
		r.playgrounds.gateway.UnregisterCustomHandler(p)
		r.playgrounds.release(workspaceID)
	}
}

func (r *Runner) devWorkspaceHandler(workspaceID uuid.UUID) http.Handler {
	wsServer := websocket.Server{
		Handshake: func(_ *websocket.Config, _ *http.Request) error {
			return nil // origin and session are checked below
		},
		Handler: func(ws *websocket.Conn) {
			defer ws.Close()
			db, ok := r.devWorkspaceBackend()
			if !ok {
				return
			}
			cols, _ := strconv.Atoi(ws.Request().URL.Query().Get("cols"))
			rows, _ := strconv.Atoi(ws.Request().URL.Query().Get("rows"))
			if cols <= 0 {
				cols = 120
			}
			if rows <= 0 {
				rows = 36
			}
			ctx, cancel := context.WithCancel(ws.Request().Context())
			defer cancel()
			pty, err := db.OpenDevWorkspacePTY(ctx, workspaceID, cols, rows)
			if err != nil {
				_, _ = ws.Write([]byte("\r\n[vesper] failed to attach terminal: " + err.Error() + "\r\n"))
				return
			}
			defer pty.Close()

			var wg sync.WaitGroup
			wg.Add(2)
			go func() {
				defer wg.Done()
				defer ws.Close()
				buf := make([]byte, 32*1024)
				for {
					n, rerr := pty.Read(buf)
					if n > 0 {
						if werr := websocket.Message.Send(ws, buf[:n]); werr != nil {
							return
						}
					}
					if rerr != nil {
						return
					}
				}
			}()
			go func() {
				defer wg.Done()
				defer pty.Close()
				for {
					var raw []byte
					if rerr := websocket.Message.Receive(ws, &raw); rerr != nil {
						return
					}
					if len(raw) > 0 && raw[0] == '{' {
						var ctrl struct {
							Type string `json:"type"`
							Cols int    `json:"cols"`
							Rows int    `json:"rows"`
						}
						if json.Unmarshal(raw, &ctrl) == nil && ctrl.Type == "resize" {
							_ = pty.Resize(ctx, ctrl.Cols, ctrl.Rows)
							continue
						}
					}
					if _, werr := pty.Write(raw); werr != nil && !errors.Is(werr, io.EOF) {
						return
					}
				}
			}()
			wg.Wait()
		},
	}

	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		// The session cookie is SameSite=Strict, which keeps other sites out but
		// not other origins on this one: a playground on a neighbouring port
		// gets the cookie too. Only Vesper's own pages may open the terminal.
		if !slices.Contains(r.Cfg.Playgrounds.Origins, req.Header.Get("Origin")) {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		c, err := req.Cookie(auth.SessionCookie)
		if err != nil || c.Value == "" {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		ok, err := auth.ValidSession(req.Context(), r.q(), c.Value)
		if err != nil || !ok {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		if req.URL.Path == "/ws" {
			wsServer.ServeHTTP(w, req)
			return
		}
		http.NotFound(w, req)
	})
}

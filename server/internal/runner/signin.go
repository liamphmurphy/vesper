package runner

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"path"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Sign-ins started from Settings: the provider's own CLI runs in a throwaway
// container, the runner relays its link and code to the person, and the login
// it produces is stored as the provider's secret. Only the microVM backend can
// do this.

// LoginStarter starts the containers sign-ins run in.
type LoginStarter interface {
	StartLogin(ctx context.Context, spec LoginSpec) (LoginProcess, error)
}

type LoginSpec struct {
	Name, Label string
	Argv        []string
	Env         map[string]string
	// TTY gives the CLI a terminal the runner can type into (Claude's
	// setup-token reads the pasted code from one).
	TTY bool
}

type LoginProcess interface {
	Output() io.Reader // stdout and stderr together
	Input() io.Writer  // nil without a TTY
	Wait() (int, error)
	// ReadFile reads a file the CLI wrote, after it exited and before Close.
	ReadFile(ctx context.Context, path string) ([]byte, error)
	Kill() error
	Close()
}

// SecretStorer saves a sign-in's login (secrets.Service.Set).
type SecretStorer func(ctx context.Context, ws, by uuid.UUID, name, value string) error

const (
	signInPoll      = 500 * time.Millisecond
	maxSignInOutput = 256 << 10
)

type signInProvider struct {
	secret string
	argv   []string
	tty    bool
	// prompt finds the sign-in link (and the one-time code to enter there,
	// if any) in the CLI's output so far.
	prompt func(out string) (link, code string, ok bool)
	// pastes: the provider's page shows a code the person pastes back.
	pastes bool
	// complete reports the login is in the output, so the CLI needn't exit.
	complete func(out string) bool
	// login is the value to store, once the CLI exited (or completed).
	login func(ctx context.Context, p LoginProcess, out string, exit int) (string, error)
}

var (
	claudeURLRe      = regexp.MustCompile(`https://claude\.(?:com|ai)/[^\s"'<>]+`)
	codexURLRe       = regexp.MustCompile(`https://auth\.openai\.com/[^\s"'<>]+`)
	codexCodeRe      = regexp.MustCompile(`one-time code[^\n]*\n\s*([A-Z0-9]{4,5}-[A-Z0-9]{4,5})\b`)
	githubURLRe      = regexp.MustCompile(`https://github\.com/login/device[^\s"'<>]*`)
	githubCodeRe     = regexp.MustCompile(`one-time code: ([A-Z0-9]{4}-[A-Z0-9]{4})\b`)
	githubTokenRe    = regexp.MustCompile(`(?m)^VESPER_GH_TOKEN=((?:gh[opsu]_|github_pat_)[A-Za-z0-9_]+)\s*$`)
	antigravityURLRe = regexp.MustCompile(`https://accounts\.google\.com/o/oauth2/[^\s"'<>]+`)
)

type homeFilesReader interface {
	ReadHomeFiles(ctx context.Context, keep func(rel string, size int64) bool) (map[string][]byte, error)
}

func isAntigravityLoginFile(rel string, size int64) bool {
	if size <= 0 || size > 12<<10 {
		return false
	}
	if _, ok := chatmodels.CleanAntigravityRelPath(rel); !ok {
		return false
	}
	for _, seg := range strings.Split(rel, "/") {
		switch seg {
		case "builtin", "log", "logs", "cache", "crashes", "conversations", "brain", "annotations", "presence", "implicit", "persistent_terminals", "updater":
			return false
		}
	}
	base := path.Base(rel)
	switch base {
	case "mcp_config.json", "hooks.json", "settings.json", ".migrated", "default_project_id.txt", "default-cli-project.json", "last_check.timestamp":
		return false
	}
	for _, ext := range []string{".log", ".db", ".db-wal", ".db-shm", ".lock", ".tmp"} {
		if strings.HasSuffix(base, ext) {
			return false
		}
	}
	return true
}

func buildAntigravityAuthBundle(files map[string][]byte) (string, error) {
	names := make([]string, 0, len(files))
	for rel, b := range files {
		if len(b) == 0 || !isAntigravityLoginFile(rel, int64(len(b))) {
			continue
		}
		names = append(names, rel)
	}
	if len(names) == 0 {
		return "", errors.New("Antigravity didn't save any login files")
	}
	sort.Strings(names)
	bundle := chatmodels.AntigravityAuth{Version: 1}
	for _, rel := range names {
		b := files[rel]
		if utf8.Valid(b) {
			if bundle.Files == nil {
				bundle.Files = map[string]string{}
			}
			bundle.Files[rel] = string(b)
		} else {
			if bundle.FilesB64 == nil {
				bundle.FilesB64 = map[string]string{}
			}
			bundle.FilesB64[rel] = base64.StdEncoding.EncodeToString(b)
		}
	}
	raw, err := json.Marshal(bundle)
	if err != nil {
		return "", err
	}
	if len(raw) > 16<<10 {
		return "", errors.New("Antigravity login exceeds 16 KB secret limit")
	}
	return string(raw), nil
}

const (
	// claudeAuthFile is where `claude auth login` writes its login in the container.
	claudeAuthFile = homePath + "/" + claudeAuthPath
	// codexAuthFile is where `codex login` writes its login in the container.
	codexAuthFile = homePath + "/" + codexAuthPath
)

var signInProviders = map[string]signInProvider{
	"claude": {
		secret: chatmodels.KeySecret[agentdef.HarnessClaudeCode],
		// A wide terminal keeps the long sign-in URL on one line. --claudeai
		// requests user:profile alongside user:inference so usage probes work.
		argv: []string{"sh", "-c", "stty cols 2000; exec claude auth login --claudeai"},
		tty:  true,
		prompt: func(out string) (string, string, bool) {
			link := claudeURLRe.FindString(out)
			return link, "", link != ""
		},
		pastes: true,
		login: func(ctx context.Context, p LoginProcess, _ string, exit int) (string, error) {
			if exit != 0 {
				return "", fmt.Errorf("claude auth login exited with %d", exit)
			}
			b, err := p.ReadFile(ctx, claudeAuthFile)
			if err != nil {
				return "", fmt.Errorf("read the Claude login: %w", err)
			}
			if _, ok := chatmodels.ParseClaudeAuth(string(b)); !ok {
				return "", errors.New("Claude didn't save a subscription login")
			}
			return string(b), nil
		},
	},
	"codex": {
		secret: chatmodels.KeySecret[agentdef.HarnessCodex],
		argv:   []string{"codex", "login", "--device-auth", "-c", `cli_auth_credentials_store="file"`},
		prompt: func(out string) (string, string, bool) {
			link, m := codexURLRe.FindString(out), codexCodeRe.FindStringSubmatch(out)
			if link == "" || m == nil {
				return "", "", false
			}
			return link, m[1], true
		},
		login: func(ctx context.Context, p LoginProcess, _ string, exit int) (string, error) {
			if exit != 0 {
				return "", fmt.Errorf("codex login exited with %d", exit)
			}
			b, err := p.ReadFile(ctx, codexAuthFile)
			if err != nil {
				return "", fmt.Errorf("read the Codex login: %w", err)
			}
			if _, ok := chatmodels.ParseCodexAuth(string(b)); !ok {
				return "", errors.New("Codex didn't save a ChatGPT login")
			}
			return string(b), nil
		},
	},
	"github": {
		secret: "git:pat",
		argv: []string{"sh", "-c", `gh auth login --web --hostname github.com --git-protocol https --skip-ssh-key && ` +
			`printf '\nVESPER_GH_TOKEN=%s\n' "$(gh auth token --hostname github.com)"`},
		prompt: func(out string) (string, string, bool) {
			link, m := githubURLRe.FindString(out), githubCodeRe.FindStringSubmatch(out)
			if link == "" || m == nil {
				return "", "", false
			}
			return link, m[1], true
		},
		login: func(_ context.Context, _ LoginProcess, out string, exit int) (string, error) {
			if exit != 0 {
				return "", fmt.Errorf("gh auth login exited with %d", exit)
			}
			m := githubTokenRe.FindStringSubmatch(out)
			if m == nil {
				return "", errors.New("gh didn't print a token")
			}
			return m[1], nil
		},
	},
	"antigravity": {
		secret: chatmodels.KeySecret[agentdef.HarnessAntigravity],
		// A wide terminal keeps the long OAuth URL on one line.
		argv: []string{"sh", "-c", "stty cols 2000; exec agy acp --login"},
		tty:  true,
		prompt: func(out string) (string, string, bool) {
			link := antigravityURLRe.FindString(out)
			return link, "", link != ""
		},
		pastes: true,
		login: func(ctx context.Context, p LoginProcess, _ string, exit int) (string, error) {
			if exit != 0 {
				return "", fmt.Errorf("antigravity login exited with %d", exit)
			}
			hr, ok := p.(homeFilesReader)
			if !ok {
				return "", errors.New("sign-in backend can't capture container home files")
			}
			files, err := hr.ReadHomeFiles(ctx, isAntigravityLoginFile)
			if err != nil {
				return "", fmt.Errorf("read the Antigravity login: %w", err)
			}
			return buildAntigravityAuthBundle(files)
		},
	},
}

// tickSignIns starts every sign-in waiting for a runner. They don't take a
// run slot: each is one small container waiting on a person.
func (r *Runner) tickSignIns(ctx context.Context) {
	ls, ok := r.Backend.(LoginStarter)
	if !ok || r.StoreSecret == nil {
		return
	}
	q := r.q()
	for range 4 {
		s, err := q.ClaimSignIn(ctx, &r.Cfg.ID)
		if err != nil {
			if !errors.Is(err, pgx.ErrNoRows) && ctx.Err() == nil {
				r.Log.Error("claim sign-in", "err", err)
			}
			return
		}
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			r.runSignIn(ctx, ls, s)
		}()
	}
}

// signInOutput collects what the CLI printed, capped.
type signInOutput struct {
	mu  sync.Mutex
	buf []byte
}

func (o *signInOutput) Write(p []byte) (int, error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if room := maxSignInOutput - len(o.buf); room > 0 {
		o.buf = append(o.buf, p[:min(len(p), room)]...)
	}
	return len(p), nil
}

func (o *signInOutput) text() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return terminalText(string(o.buf))
}

var (
	cursorRightRe = regexp.MustCompile(`\x1b\[(\d*)C`)
	escapeRe      = regexp.MustCompile(`\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b[=>78]|\x1b`)
)

// terminalText turns terminal output into plain text: Ink draws spaces as
// cursor moves, and colours and other escapes are dropped.
func terminalText(s string) string {
	s = cursorRightRe.ReplaceAllStringFunc(s, func(m string) string {
		n := 1
		if d := m[2 : len(m)-1]; d != "" {
			_, _ = fmt.Sscan(d, &n)
		}
		return strings.Repeat(" ", min(n, 200))
	})
	s = escapeRe.ReplaceAllString(s, "")
	return strings.ReplaceAll(s, "\r", "")
}

var secretLikeRe = regexp.MustCompile(`sk-ant-[A-Za-z0-9_-]+|gh[opsu]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|VESPER_GH_TOKEN=\S*|4/0[A-Za-z0-9_-]{20,}|1//[A-Za-z0-9_-]{20,}|ya29\.[A-Za-z0-9._-]+`)

// outputTail is the end of the CLI's output for an error message, with
// anything that looks like a login removed.
func outputTail(out string) string {
	var lines []string
	for _, l := range strings.Split(out, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	lines = lines[max(0, len(lines)-3):]
	t := secretLikeRe.ReplaceAllString(strings.Join(lines, " "), "…")
	if len(t) > 300 {
		t = t[len(t)-300:]
	}
	return t
}

// pasteSubmitDelay separates a pasted code from the Enter that submits it.
// Claude's Ink prompt reads the terminal raw and treats a chunk of input as a
// paste, Enter included: code+"\r" in one write lands as text in the box and
// is never submitted. Locally 20ms is enough; the margin covers the VM
// attach stream.
var pasteSubmitDelay = 300 * time.Millisecond

// typeCode types a code into the CLI's terminal, then presses Enter on its own.
func typeCode(ctx context.Context, w io.Writer, code string) error {
	if _, err := io.WriteString(w, code); err != nil {
		return err
	}
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(pasteSubmitDelay):
	}
	_, err := io.WriteString(w, "\r")
	return err
}

func signInURLAllowed(provider, link string) bool {
	u, err := url.Parse(link)
	if err != nil || u.Scheme != "https" || u.User != nil {
		return false
	}
	switch provider {
	case "claude":
		return u.Host == "claude.com" || u.Host == "claude.ai"
	case "codex":
		return u.Host == "auth.openai.com"
	case "github":
		return u.Host == "github.com" && strings.HasPrefix(u.Path, "/login/device")
	case "antigravity":
		return u.Host == "accounts.google.com" && strings.HasPrefix(u.Path, "/o/oauth2/")
	}
	return false
}

func (r *Runner) runSignIn(parent context.Context, ls LoginStarter, s store.SignIn) {
	q := r.q()
	finish := func(status, msg string) {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		if err := q.FinishSignIn(ctx, store.FinishSignInParams{ID: s.ID, Status: status, Error: msg}); err != nil {
			r.Log.Warn("finish sign-in", "id", s.ID, "err", err)
		}
	}
	prov, ok := signInProviders[s.Provider]
	if !ok {
		finish("failed", "Unknown provider "+s.Provider+".")
		return
	}
	ctx, cancel := context.WithDeadline(parent, s.ExpiresAt)
	defer cancel()
	p, err := ls.StartLogin(ctx, LoginSpec{
		Name: "vesper-signin-" + s.ID.String(), Label: "signin-" + s.ID.String(),
		Argv: prov.argv, Env: map[string]string{}, TTY: prov.tty,
	})
	if err != nil {
		finish("failed", "Couldn't start the sign-in container: "+err.Error())
		return
	}
	defer p.Close()

	var out signInOutput
	go func() { _, _ = io.Copy(&out, p.Output()) }()
	type exit struct {
		code int
		err  error
	}
	exited := make(chan exit, 1)
	go func() {
		code, err := p.Wait()
		exited <- exit{code, err}
	}()

	prompted, completed := false, false
	tick := time.NewTicker(signInPoll)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			_ = p.Kill()
			if errors.Is(ctx.Err(), context.DeadlineExceeded) {
				finish("failed", "The sign-in timed out. Start it again.")
			} else {
				finish("failed", "The runner stopped during sign-in. Start it again.")
			}
			return

		case e := <-exited:
			// The attach stream can trail the exit by a moment.
			time.Sleep(200 * time.Millisecond)
			text := out.text()
			if e.err != nil {
				finish("failed", "The sign-in container failed: "+e.err.Error())
				return
			}
			if !completed && !prompted {
				finish("failed", "The sign-in ended before showing a link: "+outputTail(text))
				return
			}
			value, err := prov.login(ctx, p, text, e.code)
			if err != nil {
				if t := outputTail(text); t != "" {
					err = fmt.Errorf("%w: %s", err, t)
				}
				finish("failed", "Sign-in didn't finish. "+err.Error())
				return
			}
			if err := r.StoreSecret(ctx, s.WorkspaceID, s.RequestedBy, prov.secret, value); err != nil {
				finish("failed", "Couldn't save the login: "+err.Error())
				return
			}
			finish("done", "")
			return

		case <-tick.C:
			status, err := q.SignInStatus(ctx, s.ID)
			if err == nil && status != "running" && status != "verifying" {
				_ = p.Kill() // cancelled or expired from the API side
				return
			}
			text := out.text()
			if !prompted {
				if link, code, ok := prov.prompt(text); ok {
					if !signInURLAllowed(s.Provider, link) {
						_ = p.Kill()
						finish("failed", "The CLI showed an unexpected sign-in link, so Vesper stopped.")
						return
					}
					if err := q.SetSignInPrompt(ctx, store.SetSignInPromptParams{ID: s.ID, Url: link, UserCode: code}); err != nil {
						r.Log.Warn("sign-in prompt", "id", s.ID, "err", err)
						continue
					}
					prompted = true
				}
			}
			if prompted && prov.pastes && p.Input() != nil {
				code, err := q.TakeSignInCode(ctx, s.ID)
				if err == nil {
					if err := typeCode(ctx, p.Input(), code); err != nil {
						if ctx.Err() != nil {
							continue // the ctx.Done case reports it
						}
						_ = p.Kill()
						finish("failed", "Couldn't hand the code to the CLI: "+err.Error())
						return
					}
				} else if !errors.Is(err, pgx.ErrNoRows) {
					r.Log.Warn("sign-in code", "id", s.ID, "err", err)
				}
			}
			if !completed && prov.complete != nil && prov.complete(text) {
				// The login is printed; the CLI may linger on a final screen.
				completed = true
				_ = p.Kill()
			}
		}
	}
}

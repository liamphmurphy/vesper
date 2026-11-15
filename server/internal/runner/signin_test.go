package runner

import (
	"context"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// fakeLogins runs a shell script in place of the provider's CLI. It embeds
// Local only to be a Backend.
type fakeLogins struct {
	*Fake
	script string
	home   string
	mu     sync.Mutex
	specs  []LoginSpec
	killed bool
	typed  []string // each write to the terminal, as the runner made it
}

func (f *fakeLogins) StartLogin(_ context.Context, spec LoginSpec) (LoginProcess, error) {
	f.mu.Lock()
	f.specs = append(f.specs, spec)
	f.mu.Unlock()
	cmd := exec.Command("sh", "-c", f.script)
	cmd.Env = []string{"PATH=/usr/bin:/bin", "HOME=" + f.home}
	r, w := io.Pipe()
	cmd.Stdout, cmd.Stderr = w, w
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	p := &fakeLogin{f: f, cmd: cmd, out: r, w: w}
	if spec.TTY {
		p.in = crlf{f, in} // a terminal turns Enter's \r into \n
	}
	return p, nil
}

type crlf struct {
	f *fakeLogins
	w io.Writer
}

func (c crlf) Write(b []byte) (int, error) {
	c.f.mu.Lock()
	c.f.typed = append(c.f.typed, string(b))
	c.f.mu.Unlock()
	return c.w.Write([]byte(strings.ReplaceAll(string(b), "\r", "\n")))
}

type fakeLogin struct {
	f   *fakeLogins
	cmd *exec.Cmd
	out io.Reader
	w   *io.PipeWriter
	in  io.Writer
}

func (p *fakeLogin) Output() io.Reader { return p.out }
func (p *fakeLogin) Input() io.Writer  { return p.in }
func (p *fakeLogin) Wait() (int, error) {
	err := p.cmd.Wait()
	p.w.Close()
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode(), nil
	}
	return 0, err
}
func (p *fakeLogin) Kill() error {
	p.f.mu.Lock()
	p.f.killed = true
	p.f.mu.Unlock()
	if p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
	return nil
}
func (p *fakeLogin) ReadFile(_ context.Context, file string) ([]byte, error) {
	return os.ReadFile(filepath.Join(p.f.home, strings.TrimPrefix(file, homePath)))
}
func (p *fakeLogin) Close() {}

type signInEnv struct {
	ctx    context.Context
	q      *store.Queries
	r      *Runner
	f      *fakeLogins
	ws, me uuid.UUID
	stored map[string]string
	mu     *sync.Mutex
}

func newSignInEnv(t *testing.T, script string) signInEnv {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeLogins{Fake: &Fake{Dir: t.TempDir()}, script: script, home: t.TempDir()}
	e := signInEnv{ctx: ctx, q: q, f: f, ws: me.WorkspaceID, me: me.ID, stored: map[string]string{}, mu: &sync.Mutex{}}
	e.r = &Runner{Cfg: Config{ID: "test-runner"}, Pool: pool, Backend: f, Log: slog.New(slog.NewTextHandler(io.Discard, nil)),
		StoreSecret: func(_ context.Context, ws, by uuid.UUID, name, value string) error {
			if ws != e.ws || by != e.me {
				t.Errorf("stored for %s by %s", ws, by)
			}
			e.mu.Lock()
			e.stored[name] = value
			e.mu.Unlock()
			return nil
		}}
	if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: "test-runner", Backend: "docker", MaxConcurrent: 1, Version: "test"}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(e.r.wg.Wait)
	return e
}

func (e signInEnv) start(t *testing.T, provider string) store.SignIn {
	t.Helper()
	s, err := e.q.CreateSignIn(e.ctx, store.CreateSignInParams{WorkspaceID: e.ws, Provider: provider, RequestedBy: e.me, ExpiresAt: time.Now().Add(time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	e.r.tickSignIns(e.ctx)
	return s
}

func (e signInEnv) waitFor(t *testing.T, id uuid.UUID, ok func(store.SignIn) bool) store.SignIn {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for {
		s, err := e.q.GetSignIn(e.ctx, store.GetSignInParams{ID: id, WorkspaceID: e.ws})
		if err != nil {
			t.Fatal(err)
		}
		if ok(s) {
			return s
		}
		if time.Now().After(deadline) {
			t.Fatalf("sign-in stuck at %+v", s)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func (e signInEnv) secret(name string) string {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.stored[name]
}

func (f *fakeLogins) wasKilled() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.killed
}

func ended(s store.SignIn) bool {
	return s.Status == "done" || s.Status == "failed" || s.Status == "cancelled"
}

func TestGitHubSignInStoresToken(t *testing.T) {
	e := newSignInEnv(t, `echo '! First copy your one-time code: AB12-CD34' >&2
echo 'Open this URL to continue in your web browser: https://github.com/login/device' >&2
sleep 1
printf '\nVESPER_GH_TOKEN=gho_abcdefghijklmnop0123\n'`)
	s := e.start(t, "github")
	shown := e.waitFor(t, s.ID, func(s store.SignIn) bool { return s.Url != "" || ended(s) })
	if shown.Url != "https://github.com/login/device" || shown.UserCode != "AB12-CD34" {
		t.Fatalf("prompt = %q %q", shown.Url, shown.UserCode)
	}
	if done := e.waitFor(t, s.ID, ended); done.Status != "done" {
		t.Fatalf("status %s: %s", done.Status, done.Error)
	}
	if e.secret("git:pat") != "gho_abcdefghijklmnop0123" {
		t.Fatal("wrong secret stored")
	}
	if spec := e.f.specs[0]; spec.TTY || !strings.Contains(strings.Join(spec.Argv, " "), "gh auth login --web") || spec.Label != "signin-"+s.ID.String() {
		t.Fatalf("spec %+v", spec)
	}
}

func TestCodexSignInStoresAuthFile(t *testing.T) {
	e := newSignInEnv(t, `printf '1. Open this link\n   \033[94mhttps://auth.openai.com/codex/device\033[0m\n\n2. Enter this one-time code \033[90m(expires in 15 minutes)\033[0m\n   WXYZ-12345\n'
sleep 1
mkdir -p "$HOME/.codex"
printf '{"auth_mode":"chatgpt","tokens":{"refresh_token":"r","account_id":"a"}}' > "$HOME/.codex/auth.json"`)
	s := e.start(t, "codex")
	shown := e.waitFor(t, s.ID, func(s store.SignIn) bool { return s.Url != "" || ended(s) })
	if shown.Url != "https://auth.openai.com/codex/device" || shown.UserCode != "WXYZ-12345" {
		t.Fatalf("prompt = %q %q", shown.Url, shown.UserCode)
	}
	if done := e.waitFor(t, s.ID, ended); done.Status != "done" {
		t.Fatalf("status %s: %s", done.Status, done.Error)
	}
	if !strings.Contains(e.secret("harness:openai"), `"auth_mode":"chatgpt"`) {
		t.Fatal("wrong secret stored")
	}
}

// Claude's page shows a code the person pastes back: it reaches the CLI's
// terminal once, and the ~/.claude/.credentials.json file it saves is stored on exit.
func TestClaudeSignInRelaysPastedCode(t *testing.T) {
	e := newSignInEnv(t, `printf 'Browser\033[1Cdidn'"'"'t\033[1Copen?\r\n\033[32mhttps://claude.com/cai/oauth/authorize?code=true&state=x\033[0m\r\n\r\nPaste code here if prompted > '
read code
mkdir -p "$HOME/.claude"
printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-%s","refreshToken":"sk-ant-ort01-r","expiresAt":4070908800000,"scopes":["user:profile","user:inference"]}}' "$code" > "$HOME/.claude/.credentials.json"`)
	s := e.start(t, "claude")
	shown := e.waitFor(t, s.ID, func(s store.SignIn) bool { return s.Url != "" || ended(s) })
	if shown.Url != "https://claude.com/cai/oauth/authorize?code=true&state=x" || shown.UserCode != "" {
		t.Fatalf("prompt = %q %q", shown.Url, shown.UserCode)
	}
	if !e.f.specs[0].TTY {
		t.Fatal("claude needs a terminal")
	}
	code := "pastedcode"
	if _, err := e.q.SubmitSignInCode(e.ctx, store.SubmitSignInCodeParams{ID: s.ID, WorkspaceID: e.ws, PastedCode: &code}); err != nil {
		t.Fatal(err)
	}
	done := e.waitFor(t, s.ID, ended)
	if done.Status != "done" {
		t.Fatalf("status %s: %s", done.Status, done.Error)
	}
	if done.PastedCode != nil {
		t.Fatal("the pasted code was kept")
	}
	if !strings.Contains(e.secret("harness:anthropic"), `"accessToken":"sk-ant-oat01-pastedcode"`) {
		t.Fatalf("wrong secret stored: %q", e.secret("harness:anthropic"))
	}
	// Enter goes on its own: in one chunk with the code, Claude's prompt
	// takes it as part of a paste and never submits.
	e.f.mu.Lock()
	typed := e.f.typed
	e.f.mu.Unlock()
	if len(typed) != 2 || typed[0] != code || typed[1] != "\r" {
		t.Fatalf("typed %q, want the code then Enter separately", typed)
	}
}

func TestSignInCancelStopsTheCLI(t *testing.T) {
	e := newSignInEnv(t, `echo '! First copy your one-time code: AB12-CD34'; echo 'https://github.com/login/device'; exec sleep 60`)
	s := e.start(t, "github")
	e.waitFor(t, s.ID, func(s store.SignIn) bool { return s.Url != "" })
	if _, err := e.q.CancelSignIn(e.ctx, store.CancelSignInParams{ID: s.ID, WorkspaceID: e.ws}); err != nil {
		t.Fatal(err)
	}
	e.r.wg.Wait()
	if !e.f.wasKilled() || e.secret("git:pat") != "" {
		t.Fatalf("killed=%v stored=%q", e.f.wasKilled(), e.secret("git:pat"))
	}
	if got := e.waitFor(t, s.ID, ended); got.Status != "cancelled" {
		t.Fatalf("status %s", got.Status)
	}
}

func TestSignInFailureHidesSecrets(t *testing.T) {
	e := newSignInEnv(t, `echo 'one-time code: AB12-CD34 https://github.com/login/device'; sleep 1; echo 'oops gho_leakedleakedleaked'; exit 1`)
	s := e.start(t, "github")
	got := e.waitFor(t, s.ID, ended)
	if got.Status != "failed" || !strings.Contains(got.Error, "exited with 1") || strings.Contains(got.Error, "gho_leaked") {
		t.Fatalf("status %s: %q", got.Status, got.Error)
	}
}

func TestExpireSignInsEndsOrphans(t *testing.T) {
	e := newSignInEnv(t, `true`)
	s, err := e.q.CreateSignIn(e.ctx, store.CreateSignInParams{WorkspaceID: e.ws, Provider: "codex", RequestedBy: e.me, ExpiresAt: time.Now().Add(time.Minute)})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.q.ClaimSignIn(e.ctx, ptr("gone-runner")); err != nil {
		t.Fatal(err)
	}
	if err := e.q.ExpireSignIns(e.ctx); err != nil {
		t.Fatal(err)
	}
	got, _ := e.q.GetSignIn(e.ctx, store.GetSignInParams{ID: s.ID, WorkspaceID: e.ws})
	if got.Status != "failed" || !strings.Contains(got.Error, "runner stopped") {
		t.Fatalf("%s: %s", got.Status, got.Error)
	}
}

func ptr[T any](v T) *T { return &v }

func TestTerminalText(t *testing.T) {
	in := "\x1b7\x1b8Welcome\x1b[1Cto\x1b[3CClaude\r\n\x1b]0;title\x07\x1b[>0q\x1b[94mhttps://claude.com/x?a=1\x1b[0m"
	if got := terminalText(in); got != "Welcome to   Claude\nhttps://claude.com/x?a=1" {
		t.Fatalf("%q", got)
	}
}

func TestSignInURLAllowed(t *testing.T) {
	for link, want := range map[string]bool{
		"https://claude.com/cai/oauth/authorize?x=1": true,
		"https://claude.ai/oauth":                    true,
		"http://claude.com/":                         false,
		"https://claude.com.evil.io/":                false,
		"https://user@claude.com/":                   false,
	} {
		if got := signInURLAllowed("claude", link); got != want {
			t.Errorf("claude %s = %v", link, got)
		}
	}
	if !signInURLAllowed("github", "https://github.com/login/device") || signInURLAllowed("github", "https://github.com/settings") {
		t.Error("github")
	}
	if !signInURLAllowed("codex", "https://auth.openai.com/codex/device") || signInURLAllowed("codex", "https://openai.com.evil/") {
		t.Error("codex")
	}
	if !signInURLAllowed("antigravity", "https://accounts.google.com/o/oauth2/auth?client_id=1") ||
		signInURLAllowed("antigravity", "https://accounts.google.com/evil") ||
		signInURLAllowed("antigravity", "https://accounts.google.com.evil/o/oauth2/auth") {
		t.Error("antigravity")
	}
}

type fakeSignInProc struct {
	files map[string][]byte
}

func (f *fakeSignInProc) Output() io.Reader { return strings.NewReader("") }
func (f *fakeSignInProc) Input() io.Writer  { return nil }
func (f *fakeSignInProc) ReadFile(_ context.Context, path string) ([]byte, error) {
	b, ok := f.files[path]
	if !ok {
		return nil, context.DeadlineExceeded
	}
	return b, nil
}
func (f *fakeSignInProc) ReadHomeFiles(_ context.Context, keep func(rel string, size int64) bool) (map[string][]byte, error) {
	out := map[string][]byte{}
	prefix := homePath + "/"
	for p, b := range f.files {
		rel := strings.TrimPrefix(p, prefix)
		if rel != p && keep(rel, int64(len(b))) {
			out[rel] = b
		}
	}
	return out, nil
}
func (f *fakeSignInProc) Wait() (int, error) { return 0, nil }
func (f *fakeSignInProc) Kill() error        { return nil }
func (f *fakeSignInProc) Close()             {}

func TestAntigravitySignInProvider(t *testing.T) {
	prov, ok := signInProviders["antigravity"]
	if !ok || !prov.pastes || !prov.tty {
		t.Fatalf("unexpected antigravity provider config: %+v %v", prov, ok)
	}
	link, code, ready := prov.prompt("Open this link:\n\n  https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=123\n\nThen paste")
	if !ready || code != "" || link != "https://accounts.google.com/o/oauth2/auth?response_type=code&client_id=123" {
		t.Fatalf("prompt = (%q, %q, %v)", link, code, ready)
	}
	proc := &fakeSignInProc{files: map[string][]byte{
		homePath + "/.gemini/antigravity-cli/oauth_creds.bin":           {0xff, 0x00, 0x01, 0x02},
		homePath + "/.gemini/config/config.json":                        []byte(`{"ok":true}`),
		homePath + "/.gemini/antigravity-cli/log/acp-login.log":         []byte("noisy log"),
		homePath + "/.gemini/antigravity-cli/conversation_summaries.db": []byte("sqlite"),
		homePath + "/.gemini/antigravity-cli/builtin/keep.txt":          []byte("builtin"),
		homePath + "/.bashrc":                                           []byte("export PATH="),
	}}
	val, err := prov.login(context.Background(), proc, "", 0)
	if err != nil {
		t.Fatal(err)
	}
	parsed, ok := chatmodels.ParseAntigravityAuth(val)
	if !ok || parsed.Files[".gemini/config/config.json"] != `{"ok":true}` || parsed.FilesB64[".gemini/antigravity-cli/oauth_creds.bin"] == "" {
		t.Fatalf("parsed bundle = %+v %v", parsed, ok)
	}
	if _, hasLog := parsed.Files[".gemini/antigravity-cli/log/acp-login.log"]; hasLog {
		t.Fatalf("log file should be excluded: %+v", parsed)
	}
	if _, err := prov.login(context.Background(), &fakeSignInProc{}, "", 0); err == nil {
		t.Fatal("empty login files must fail")
	}
}

type writeLog struct{ writes []string }

func (w *writeLog) Write(b []byte) (int, error) {
	w.writes = append(w.writes, string(b))
	return len(b), nil
}

func TestTypeCodePressesEnterSeparately(t *testing.T) {
	var w writeLog
	start := time.Now()
	if err := typeCode(context.Background(), &w, "abc#def"); err != nil {
		t.Fatal(err)
	}
	if len(w.writes) != 2 || w.writes[0] != "abc#def" || w.writes[1] != "\r" {
		t.Fatalf("writes %q", w.writes)
	}
	if time.Since(start) < pasteSubmitDelay {
		t.Fatal("Enter followed the code without a pause")
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	w = writeLog{}
	if err := typeCode(ctx, &w, "abc"); err == nil || len(w.writes) != 1 {
		t.Fatalf("cancelled: err %v writes %q", err, w.writes)
	}
}

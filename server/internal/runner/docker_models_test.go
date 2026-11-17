package runner

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

// modelsEngine is the part of the Docker Engine API a model listing uses: a
// hijacked non-TTY attach that answers the harness's control protocol.
type modelsEngine struct {
	mu      sync.Mutex
	created map[string]any
	name    string
	calls   []string
	archive map[string]string // PUT /archive: path -> file contents
	// authBack is what ~/.codex/auth.json holds when the runner reads it back.
	authBack string
	// failStart makes /start fail; hang makes the harness never answer.
	failStart, hang bool
	// signedOut makes usage checks answer as a CLI with no plan login.
	signedOut bool
	// agyMode makes speak emit agyErr/agyOut once /start runs and close stdout.
	agyMode        bool
	agyOut, agyErr string
	started        chan struct{}
	startOnce      sync.Once
}

func (f *modelsEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p := strings.TrimPrefix(r.URL.Path, "/v1.43")
	f.mu.Lock()
	f.calls = append(f.calls, r.Method+" "+p)
	f.mu.Unlock()
	switch {
	case p == "/containers/create":
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		f.mu.Lock()
		f.created, f.name = body, r.URL.Query().Get("name")
		f.mu.Unlock()
		_, _ = io.WriteString(w, `{"Id":"m1"}`)
	case r.Method == "PUT" && p == "/containers/m1/archive":
		tr := tar.NewReader(r.Body)
		for {
			h, err := tr.Next()
			if err != nil {
				break
			}
			b, _ := io.ReadAll(tr)
			f.mu.Lock()
			if f.archive == nil {
				f.archive = map[string]string{}
			}
			f.archive[r.URL.Query().Get("path")+"|"+h.Name] = string(b)
			f.mu.Unlock()
		}
	case r.Method == "GET" && p == "/containers/m1/archive":
		var b bytes.Buffer
		tw := tar.NewWriter(&b)
		_ = tw.WriteHeader(&tar.Header{Name: "auth.json", Mode: 0o600, Size: int64(len(f.authBack))})
		_, _ = io.WriteString(tw, f.authBack)
		_ = tw.Close()
		_, _ = w.Write(b.Bytes())
	case p == "/containers/m1/attach" && r.Header.Get("Upgrade") == "tcp":
		conn, buf, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return
		}
		go f.speak(conn, buf.Reader)
	case p == "/containers/m1/start" && f.failStart:
		http.Error(w, "boom", 500)
	case p == "/containers/m1/wait":
		_, _ = io.WriteString(w, `{"StatusCode":0}`)
	case p == "/containers/m1/start":
		f.startOnce.Do(func() {
			if f.started != nil {
				close(f.started)
			}
		})
		w.WriteHeader(204)
	case p == "/containers/m1/kill", r.Method == "DELETE" && p == "/containers/m1":
		w.WriteHeader(204)
	default:
		http.NotFound(w, r)
	}
}

// speak plays the harness: Claude answers its model and usage requests,
// Codex walks initialize then model/list or account/rateLimits/read.
func (f *modelsEngine) speak(conn net.Conn, in *bufio.Reader) {
	defer conn.Close()
	_, _ = io.WriteString(conn, "HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.raw-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n")
	say := func(stream byte, s string) {
		s += "\n"
		h := make([]byte, 8)
		h[0] = stream
		binary.BigEndian.PutUint32(h[4:], uint32(len(s)))
		_, _ = conn.Write(append(h, s...))
	}
	if f.agyMode {
		if f.started != nil {
			<-f.started
		}
		if f.agyErr != "" {
			say(2, f.agyErr)
		}
		if f.agyOut != "" {
			say(1, f.agyOut)
		}
		return
	}
	for {
		line, err := in.ReadString('\n')
		if err != nil {
			return
		}
		if f.hang {
			continue
		}
		say(2, "stderr noise that must be ignored")
		var msg struct {
			ID      int    `json:"id"`
			Method  string `json:"method"`
			Type    string `json:"type"`
			Request struct {
				Subtype string `json:"subtype"`
			} `json:"request"`
		}
		_ = json.Unmarshal([]byte(line), &msg)
		switch {
		case msg.Request.Subtype == "get_usage" && f.signedOut:
			say(1, `{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null}}}`)
		case msg.Request.Subtype == "get_usage":
			say(1, `{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":38,"resets_at":"2099-01-01T00:00:00Z"},"seven_day":{"utilization":61,"resets_at":"2099-01-05T00:00:00Z"}}}}}`)
		case msg.Type == "control_request" && msg.Request.Subtype == "initialize" && strings.Contains(line, `"request_id":"initialize"`):
			say(1, `{"type":"control_response","response":{"subtype":"success","request_id":"initialize","response":{}}}`)
		case msg.Method == "account/rateLimits/read":
			say(1, fmt.Sprintf(`{"id":%d,"result":{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":12,"windowDurationMins":300,"resetsAt":4070908800},"secondary":{"usedPercent":70,"windowDurationMins":10080,"resetsAt":4071513600}}}}`, msg.ID))
		case msg.Type == "control_request":
			say(1, `{"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[{"value":"default","displayName":"Recommended"},{"value":"opus","displayName":"Opus"}]}}}`)
		case msg.Method == "initialize":
			say(1, `{"id":1,"result":{}}`)
		case msg.Method == "model/list":
			say(1, fmt.Sprintf(`{"id":%d,"result":{"data":[{"model":"gpt-x","displayName":"GPT X","isDefault":true}],"nextCursor":null}}`, msg.ID))
		}
	}
}

func startModelsEngine(t *testing.T) (*modelsEngine, *Docker) {
	t.Helper()
	// A short path: unix socket names are limited to about 100 bytes.
	sock := filepath.Join(shortTempDir(t), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	f := &modelsEngine{started: make(chan struct{})}
	srv := &http.Server{Handler: f}
	go func() { _ = srv.Serve(l) }()
	t.Cleanup(func() { _ = srv.Close() })
	return f, &Docker{Socket: sock, Image: "img"}
}

const (
	codexLoginOld = `{"auth_mode":"chatgpt","last_refresh":"2024-01-01T00:00:00Z","tokens":{"access_token":"tok-access","refresh_token":"tok-refresh","id_token":"tok-id","account_id":"acct"}}`
	codexLoginNew = `{"auth_mode":"chatgpt","last_refresh":"2025-01-01T00:00:00Z","tokens":{"access_token":"tok-access2","refresh_token":"tok-refresh2","id_token":"tok-id","account_id":"acct"}}`
)

func (f *modelsEngine) hasCall(c string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Contains(f.calls, c)
}

func TestDockerListModelsClaudeUsesSandboxAndTokenEnv(t *testing.T) {
	f, d := startModelsEngine(t)
	const scope = "11111111-1111-1111-1111-111111111111"
	models, err := d.ListModels(context.Background(), "claim1", agentdef.HarnessClaudeCode, "sk-ant-oat01-secret", scope)
	if err != nil || len(models) != 2 || models[1].ID != "opus" {
		t.Fatalf("models %+v err %v", models, err)
	}
	c := f.created
	host := c["HostConfig"].(map[string]any)
	if m, _ := host["Mounts"].([]any); len(m) != 0 {
		t.Fatalf("mounts %v", host["Mounts"])
	}
	if cd := host["CapDrop"].([]any); len(cd) != 1 || cd[0] != "ALL" {
		t.Fatalf("CapDrop %v", cd)
	}
	if so := host["SecurityOpt"].([]any); len(so) != 1 || so[0] != "no-new-privileges" {
		t.Fatalf("SecurityOpt %v", so)
	}
	labels := c["Labels"].(map[string]any)
	if labels[labelKey] != "models-claude-code" || labels[stackLabelKey] == "" {
		t.Fatalf("labels %v", labels)
	}
	env := c["Env"].([]any)
	if len(env) != 1 || env[0] != ClaudeOAuthEnv+"=sk-ant-oat01-secret" {
		t.Fatalf("env %v", env)
	}
	if c["Tty"] != false || c["OpenStdin"] != true || c["StdinOnce"] != true || c["AttachStdin"] != true {
		t.Fatalf("stdin settings %v", c)
	}
	if cmd := c["Cmd"].([]any); cmd[0] != "claude" || c["WorkingDir"] != homePath {
		t.Fatalf("cmd %v dir %v", cmd, c["WorkingDir"])
	}
	if f.name != "vesper-models-claim1" {
		t.Fatalf("name %q", f.name)
	}
	if len(f.archive) != 0 {
		t.Fatalf("Claude uploaded files: %v", f.archive)
	}
	if !f.hasCall("POST /containers/m1/kill") || !f.hasCall("DELETE /containers/m1") {
		t.Fatalf("container not cleaned up: %v", f.calls)
	}
}

func TestDockerListModelsCodexUploadsLoginAndKeepsRefreshedOne(t *testing.T) {
	const scope = "11111111-1111-1111-1111-111111111111"
	for _, tc := range []struct {
		name, back string
		saved      bool
	}{
		{"refreshed", codexLoginNew, true},
		{"unchanged", codexLoginOld, false},
		{"other account", strings.Replace(codexLoginNew, "acct", "someone-else", 1), false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, d := startModelsEngine(t)
			f.authBack = tc.back
			var savedScope, savedAuth string
			d.SaveCodexAuth = func(_ context.Context, scope, auth string) error {
				savedScope, savedAuth = scope, auth
				return nil
			}
			models, err := d.ListModels(context.Background(), "claim1", agentdef.HarnessCodex, codexLoginOld, scope)
			if err != nil || len(models) != 1 || models[0].ID != "gpt-x" {
				t.Fatalf("models %+v err %v", models, err)
			}
			if got := f.archive[homePath+"|.codex/auth.json"]; got != codexLoginOld {
				t.Fatalf("uploaded %v", f.archive)
			}
			for _, e := range f.created["Env"].([]any) {
				if strings.Contains(e.(string), "tok-") || strings.Contains(e.(string), "chatgpt") {
					t.Fatalf("login in Env: %v", f.created["Env"])
				}
			}
			if tc.saved != (savedAuth != "") || (tc.saved && (savedScope != scope || savedAuth != tc.back)) {
				t.Fatalf("saved %q for %q", savedAuth, savedScope)
			}
			if !f.hasCall("DELETE /containers/m1") {
				t.Fatalf("container not removed: %v", f.calls)
			}
		})
	}
}

func (f *modelsEngine) index(c string) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return slices.Index(f.calls, c)
}

func TestDockerListModelsErrorPathsStillCleanUp(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(*modelsEngine, *Docker)
	}{
		{"start fails", func(f *modelsEngine, _ *Docker) { f.failStart = true }},
		{"hung stream", func(f *modelsEngine, d *Docker) { f.hang = true; d.ModelsTimeout = 200 * time.Millisecond }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f, d := startModelsEngine(t)
			tc.set(f, d)
			if _, err := d.ListModels(context.Background(), "claim1", agentdef.HarnessClaudeCode, "sk-ant-oat01-secret", "scope"); err == nil {
				t.Fatal("expected an error")
			}
			if !f.hasCall("POST /containers/m1/kill") || !f.hasCall("DELETE /containers/m1") {
				t.Fatalf("container not cleaned up: %v", f.calls)
			}
		})
	}
}

func TestDockerListModelsCodexReadsLoginBackAfterExit(t *testing.T) {
	f, d := startModelsEngine(t)
	f.authBack = codexLoginNew
	d.SaveCodexAuth = func(context.Context, string, string) error { return nil }
	if _, err := d.ListModels(context.Background(), "claim1", agentdef.HarnessCodex, codexLoginOld, "scope"); err != nil {
		t.Fatal(err)
	}
	wait, read, kill := f.index("POST /containers/m1/wait"), f.index("GET /containers/m1/archive"), f.index("POST /containers/m1/kill")
	if wait < 0 || read < 0 || kill < 0 || !(wait < read && read < kill) {
		t.Fatalf("want wait < archive read < kill, got %v", f.calls)
	}
}

func TestDockerListModelsAntigravityAndStderr(t *testing.T) {
	const agyLogin = `{"v":1,"files":{".gemini/antigravity-cli/antigravity-oauth-token":"tok"}}`

	f, d := startModelsEngine(t)
	f.agyMode = true
	f.agyOut = "gemini-4-carbon-medium\tGemini 4 Carbon (Medium)\ngemini-4-carbon-high\tGemini 4 Carbon (High)\nclaude-opus-5-5-low\tClaude Opus 5.5 (Low)"
	f.agyErr = "\r⠋ Fetching available models...\r⠙ Fetching available models..."
	models, err := d.ListModels(context.Background(), "claim-agy", agentdef.HarnessAntigravity, agyLogin, "scope")
	if err != nil || len(models) != 2 ||
		models[0].ID != "gemini-4-carbon" || models[0].Label != "Gemini 4 Carbon" || !models[0].Default || !slices.Equal(models[0].Efforts, []string{"medium", "high"}) ||
		models[1].ID != "claude-opus-5-5" || models[1].Label != "Claude Opus 5.5" || !slices.Equal(models[1].Efforts, []string{"low"}) {
		t.Fatalf("models %+v err %v", models, err)
	}
	if f.archive[homePath+"|.gemini/antigravity-cli/antigravity-oauth-token"] != "tok" {
		t.Fatalf("archive = %v", f.archive)
	}

	f2, d2 := startModelsEngine(t)
	f2.agyMode = true
	f2.agyErr = "\r⠋ Fetching available models...\r⠙ Fetching available models...\nError: Please sign in to view available models."
	_, err = d2.ListModels(context.Background(), "claim-agy-err", agentdef.HarnessAntigravity, agyLogin, "scope")
	if err == nil || !strings.Contains(err.Error(), "Error: Please sign in to view available models.") || strings.Contains(err.Error(), "\r") {
		t.Fatalf("expected cleaned stderr in error, got %v", err)
	}
}

// fakeLister stands in for the Docker backend. It embeds Local only to be a Backend.
type fakeLister struct {
	*Fake
	models []chatmodels.Model
	err    error
	mu     sync.Mutex
	calls  []string // harness|login|scope
}

func (f *fakeLister) ListModels(_ context.Context, _, harness, login, scope string) ([]chatmodels.Model, error) {
	f.mu.Lock()
	f.calls = append(f.calls, harness+"|"+login+"|"+scope)
	f.mu.Unlock()
	return f.models, f.err
}

type listingEnv struct {
	ctx context.Context
	q   *store.Queries
	r   *Runner
	f   *fakeLister
	ws  uuid.UUID
	set func(name, value string)
}

func newListingEnv(t *testing.T, f *fakeLister) listingEnv {
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
	key := make([]byte, 32)
	_, _ = rand.Read(key)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(key))
	if err != nil {
		t.Fatal(err)
	}
	svc := &secrets.Service{Q: q, Box: box}
	f.Fake = &Fake{Dir: t.TempDir()}
	r := &Runner{Cfg: Config{ID: "test-runner"}, Pool: pool, Backend: f, Secrets: svc, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	t.Cleanup(r.wg.Wait)
	return listingEnv{ctx: ctx, q: q, r: r, f: f, ws: me.WorkspaceID, set: func(name, value string) {
		if _, err := svc.Set(ctx, me.WorkspaceID, me.ID, secrets.SetInput{Name: name, Value: value}); err != nil {
			t.Fatal(err)
		}
	}}
}

// request queues a listing for the harness and lets the runner work on it.
func (e listingEnv) request(t *testing.T, harness string) store.HarnessModelListing {
	t.Helper()
	v, err := e.q.SecretVersion(e.ctx, store.SecretVersionParams{WorkspaceID: e.ws, Name: chatmodels.KeySecret[harness]})
	if err != nil {
		t.Fatal(err)
	}
	if err := e.q.RequestModelListing(e.ctx, store.RequestModelListingParams{WorkspaceID: e.ws, Harness: harness, LoginVersion: v}); err != nil {
		t.Fatal(err)
	}
	e.r.tickModelListings(e.ctx)
	e.r.wg.Wait()
	row, err := e.q.GetModelListing(e.ctx, store.GetModelListingParams{WorkspaceID: e.ws, Harness: harness})
	if err != nil {
		t.Fatal(err)
	}
	return row
}

func TestModelListingStoresModels(t *testing.T) {
	e := newListingEnv(t, &fakeLister{models: []chatmodels.Model{{ID: "opus", Label: "Opus", Default: true}}})
	e.set("harness:anthropic", "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz")
	row := e.request(t, agentdef.HarnessClaudeCode)
	if row.Status != "done" || row.ModelsVersion == nil || *row.ModelsVersion != row.LoginVersion {
		t.Fatalf("row %+v", row)
	}
	var got []chatmodels.Model
	if err := json.Unmarshal(row.Models, &got); err != nil || len(got) != 1 || got[0].ID != "opus" {
		t.Fatalf("models %s err %v", row.Models, err)
	}
	if want := "claude-code|sk-ant-oat01-abcdefghijklmnopqrstuvwxyz|" + e.ws.String(); len(e.f.calls) != 1 || e.f.calls[0] != want {
		t.Fatalf("calls %v", e.f.calls)
	}
}

// A runner may start with a newer harness CLI whose aliases mean newer
// models, so a fresh listing saved before it started is listed again.
func TestRunnerStartListsSavedModelsAgain(t *testing.T) {
	e := newListingEnv(t, &fakeLister{models: []chatmodels.Model{{ID: "fable", Label: "Fable 5.1", Default: true}}})
	e.set("harness:anthropic", "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz")
	if row := e.request(t, agentdef.HarnessClaudeCode); row.Status != "done" {
		t.Fatalf("row %+v", row)
	}
	listings := &chatmodels.QueuedListings{Pool: e.r.Pool}
	label := func() string {
		t.Helper()
		models, err := listings.Models(e.ctx, e.ws, agentdef.HarnessClaudeCode, false)
		if err != nil || len(models) != 1 {
			t.Fatalf("models %+v err %v", models, err)
		}
		return models[0].Label
	}

	e.f.models = []chatmodels.Model{{ID: "fable", Label: "Fable 5.2", Default: true}}
	e.r.expireModelListings(e.ctx)
	if got := label(); got != "Fable 5.1" {
		t.Fatalf("while listing again, got %q, want the saved models", got)
	}
	e.r.tickModelListings(e.ctx)
	e.r.wg.Wait()
	if got := label(); got != "Fable 5.2" {
		t.Fatalf("after listing again, got %q", got)
	}
}

func TestModelListingFailsForAPIKey(t *testing.T) {
	e := newListingEnv(t, &fakeLister{models: []chatmodels.Model{{ID: "x"}}})
	e.set("harness:anthropic", "sk-ant-api03-abcdefghijklmnopqrstuvwxyz")
	e.set("harness:openai", "sk-proj-abcdefghijklmnop")
	for _, h := range []string{agentdef.HarnessClaudeCode, agentdef.HarnessCodex} {
		row := e.request(t, h)
		if row.Status != "failed" || row.Error != "The saved login isn't a Claude or ChatGPT plan login." {
			t.Fatalf("%s row %+v", h, row)
		}
	}
	if len(e.f.calls) != 0 {
		t.Fatalf("an API key reached the CLI: %v", e.f.calls)
	}
}

func TestModelListingErrorIsFixedPublicText(t *testing.T) {
	const token = "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz"
	e := newListingEnv(t, &fakeLister{err: errors.New("claude said: bad token " + token)})
	e.set("harness:anthropic", token)
	row := e.request(t, agentdef.HarnessClaudeCode)
	if row.Status != "failed" || row.Error != "Couldn't list models with the saved Claude login. Sign in again in Settings." {
		t.Fatalf("row %+v", row)
	}
	if strings.Contains(row.Error, token) || strings.Contains(row.Error, "bad token") {
		t.Fatalf("CLI output leaked: %q", row.Error)
	}
}

func TestModelListingWithNoModelsFails(t *testing.T) {
	e := newListingEnv(t, &fakeLister{})
	e.set("harness:anthropic", "sk-ant-oat01-abcdefghijklmnopqrstuvwxyz")
	if row := e.request(t, agentdef.HarnessClaudeCode); row.Status != "failed" || row.Error != "No chat models available." {
		t.Fatalf("row %+v", row)
	}
}

func TestModelListingCodexLogin(t *testing.T) {
	e := newListingEnv(t, &fakeLister{models: []chatmodels.Model{{ID: "gpt-x", Default: true}}})
	e.set("harness:openai", codexLoginOld)
	if row := e.request(t, agentdef.HarnessCodex); row.Status != "done" {
		t.Fatalf("row %+v", row)
	}
}

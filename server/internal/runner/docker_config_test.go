package runner

import (
	"archive/tar"
	"context"
	"io"
	"slices"
	"testing"

	"github.com/google/uuid"
)

func TestHostConfigIsHardened(t *testing.T) {
	host := (&Docker{Network: "bridge", MemoryMB: 512, PidsLimit: 100}).hostConfig(nil)
	if caps, _ := host["CapDrop"].([]string); !slices.Equal(caps, []string{"ALL"}) {
		t.Fatalf("CapDrop = %v", host["CapDrop"])
	}
	if opts, _ := host["SecurityOpt"].([]string); !slices.Contains(opts, "no-new-privileges") {
		t.Fatalf("SecurityOpt = %v", host["SecurityOpt"])
	}
	if host["Memory"] != int64(512<<20) || host["PidsLimit"] != int64(100) {
		t.Fatalf("limits = %v %v", host["Memory"], host["PidsLimit"])
	}
	if _, ok := (&Docker{}).hostConfig(nil)["Memory"]; ok {
		t.Fatal("0 should leave the memory limit off")
	}
}

func TestCodexAuthTarIsOwnedByTheAgentUser(t *testing.T) {
	r, err := codexAuthTar(`{"x":1}`)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(r)
	if h, err := tr.Next(); err != nil || h.Typeflag != tar.TypeDir || h.Uid != 1000 {
		t.Fatalf("dir header %+v %v", h, err)
	}
	h, err := tr.Next()
	if err != nil || h.Name != ".codex/auth.json" || h.Uid != 1000 || h.Mode != 0o600 {
		t.Fatalf("file header %+v %v", h, err)
	}
	if b, _ := io.ReadAll(tr); string(b) != `{"x":1}` {
		t.Fatalf("body %s", b)
	}
}

type fakeRevealer map[string]string

func (f fakeRevealer) Reveal(_ context.Context, _ uuid.UUID, _ *uuid.UUID, name string) (string, error) {
	return f[name], nil
}

func TestAntigravityAuthTarIsOwnedByTheAgentUser(t *testing.T) {
	raw := `{"v":1,"files":{".config/antigravity/plugin-secrets.json":"{\"token\":\"ok\"}"}}`
	r, err := antigravityAuthTar(raw)
	if err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(r)
	var files []string
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if h.Uid != 1000 {
			t.Fatalf("entry %s uid = %d, want 1000", h.Name, h.Uid)
		}
		if h.Typeflag == tar.TypeReg {
			if h.Mode != 0o600 {
				t.Fatalf("file %s mode = %o, want 0600", h.Name, h.Mode)
			}
			b, _ := io.ReadAll(tr)
			if string(b) != `{"token":"ok"}` {
				t.Fatalf("body = %s", b)
			}
			files = append(files, h.Name)
		}
	}
	if !slices.Equal(files, []string{".config/antigravity/plugin-secrets.json"}) {
		t.Fatalf("files = %v", files)
	}
	b64Tar, err := antigravityAuthTar(`{"v":1,"files_b64":{".gemini/antigravity-cli/tok.bin":"AQID"}}`)
	if err != nil {
		t.Fatal(err)
	}
	tr2 := tar.NewReader(b64Tar)
	for {
		h, err := tr2.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			b, _ := io.ReadAll(tr2)
			if h.Name != ".gemini/antigravity-cli/tok.bin" || string(b) != "\x01\x02\x03" {
				t.Fatalf("binary entry %s = %x", h.Name, b)
			}
		}
	}
}

func TestSecretEnvDeliversPlanLogins(t *testing.T) {
	const login = `{"auth_mode":"chatgpt","tokens":{"access_token":"tok-access","refresh_token":"tok-refresh","id_token":"tok-id","account_id":"a"}}`
	const agyLogin = `{"v":1,"files":{".config/antigravity/plugin-secrets.json":"{\"token\":\"agy-secret-token-value\"}"}}`
	plan := []SecretDecision{
		{Name: "harness:anthropic", Injected: true, Env: []string{"ANTHROPIC_API_KEY"}},
		{Name: "harness:openai", Injected: true, Env: []string{"CODEX_API_KEY", "OPENAI_API_KEY"}},
		{Name: "harness:google", Injected: true},
	}
	ws, project := uuid.New(), uuid.New()
	env, err := SecretEnv(context.Background(), fakeRevealer{"harness:anthropic": "sk-ant-oat01-x", "harness:openai": login, "harness:google": agyLogin}, ws, &project, plan)
	if err != nil {
		t.Fatal(err)
	}
	if env[ClaudeOAuthEnv] != "sk-ant-oat01-x" || env["ANTHROPIC_API_KEY"] != "" {
		t.Fatalf("claude env %v", env)
	}
	if env[CodexAuthEnv] != login || env["OPENAI_API_KEY"] != "" || env["CODEX_API_KEY"] != "" {
		t.Fatalf("codex env %v", env)
	}
	if env[AntigravityAuthEnv] != agyLogin || env["GEMINI_API_KEY"] != "" {
		t.Fatalf("antigravity env %v", env)
	}
	if got := redact(`leaked {"token":"agy-secret-token-value"}`, sensitiveEnv(env)); got != "leaked [redacted]" {
		t.Fatalf("agy redact = %q", got)
	}
	gotWS, gotProject, err := ParseCodexAuthScope(env[CodexAuthScopeEnv])
	if err != nil || gotWS != ws || *gotProject != project {
		t.Fatalf("scope %v %v %v", gotWS, gotProject, err)
	}
	if got := redact("leaked tok-refresh here", sensitiveEnv(env)); got != "leaked [redacted] here" {
		t.Fatalf("redact = %q", got)
	}
	const claudeAuth = `{"claudeAiOauth":{"accessToken":"sk-ant-oat01-claude-access","refreshToken":"sk-ant-ort01-claude-refresh","expiresAt":4070908800000}}`
	claudeFileEnv, err := SecretEnv(context.Background(), fakeRevealer{"harness:anthropic": claudeAuth}, ws, &project, plan[:1])
	if err != nil {
		t.Fatal(err)
	}
	if claudeFileEnv[ClaudeAuthEnv] != claudeAuth || claudeFileEnv[ClaudeOAuthEnv] != "" || claudeFileEnv["ANTHROPIC_API_KEY"] != "" {
		t.Fatalf("claude auth env %v", claudeFileEnv)
	}
	if got := redact("leaked sk-ant-oat01-claude-access and sk-ant-ort01-claude-refresh", sensitiveEnv(claudeFileEnv)); got != "leaked [redacted] and [redacted]" {
		t.Fatalf("claude redact = %q", got)
	}
	keys, err := SecretEnv(context.Background(), fakeRevealer{"harness:anthropic": "sk-ant-api03-x", "harness:openai": "sk-proj-x"}, ws, nil, plan)
	if err != nil || keys["ANTHROPIC_API_KEY"] != "sk-ant-api03-x" || keys["OPENAI_API_KEY"] != "sk-proj-x" || keys[ClaudeOAuthEnv] != "" {
		t.Fatalf("api keys %v %v", keys, err)
	}
}

func TestRedactPayloadEncodesOnce(t *testing.T) {
	env := map[string]string{"TOKEN": "vsp_secretvalue", "SHORT": "1"}
	clean := map[string]any{"text": "nothing to hide", "n": 1}
	p, b := redactPayload(clean, env)
	if string(b) != `{"n":1,"text":"nothing to hide"}` || p["text"] != "nothing to hide" {
		t.Fatalf("clean payload: %v %s", p, b)
	}
	p, b = redactPayload(map[string]any{"text": "token vsp_secretvalue here"}, env)
	if string(b) != `{"text":"token [redacted] here"}` || p["text"] != "token [redacted] here" {
		t.Fatalf("secret payload: %v %s", p, b)
	}
}

package chatmodels

import (
	"encoding/base64"
	"encoding/json"
	"path"
	"strings"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// ClaudeOAuthToken reports whether a harness:anthropic value is a plan login
// from `claude setup-token` rather than an API key.
func ClaudeOAuthToken(v string) bool { return strings.HasPrefix(v, "sk-ant-oat") }

// ClaudeAuth is the part of Claude Code's ~/.claude/.credentials.json that
// `claude auth login --claudeai` writes, carrying user:profile and refresh
// tokens so `get_usage` and token rotation both work.
type ClaudeAuth struct {
	ClaudeAiOauth struct {
		AccessToken      string   `json:"accessToken"`
		RefreshToken     string   `json:"refreshToken"`
		ExpiresAt        int64    `json:"expiresAt"`
		Scopes           []string `json:"scopes,omitempty"`
		SubscriptionType string   `json:"subscriptionType,omitempty"`
		RateLimitTier    string   `json:"rateLimitTier,omitempty"`
	} `json:"claudeAiOauth"`
}

// ParseClaudeAuth reports whether a harness:anthropic value is a Claude Code
// ~/.claude/.credentials.json OAuth credential rather than a raw token or API key.
func ParseClaudeAuth(v string) (ClaudeAuth, bool) {
	var a ClaudeAuth
	if !strings.HasPrefix(strings.TrimSpace(v), "{") || json.Unmarshal([]byte(v), &a) != nil {
		return a, false
	}
	return a, a.ClaudeAiOauth.AccessToken != "" && a.ClaudeAiOauth.RefreshToken != ""
}

// ClaudeAuthRefreshed reports whether next is a newer OAuth credential than
// current. next comes from a container an agent could write to, so an
// invalidated or older expiry is rejected.
func ClaudeAuthRefreshed(current, next string) bool {
	cur, ok := ParseClaudeAuth(current)
	if !ok {
		return false
	}
	n, ok := ParseClaudeAuth(next)
	return ok && n.ClaudeAiOauth.ExpiresAt > cur.ClaudeAiOauth.ExpiresAt &&
		n.ClaudeAiOauth.ExpiresAt < time.Now().Add(365*24*time.Hour).UnixMilli()
}

// ClaudePlanLogin reports whether a harness:anthropic value is any Claude
// subscription login (either ~/.claude/.credentials.json or a setup-token).
func ClaudePlanLogin(v string) bool {
	if ClaudeOAuthToken(v) {
		return true
	}
	_, ok := ParseClaudeAuth(v)
	return ok
}

// CodexAuth is the part of Codex's auth.json Vesper reads.
type CodexAuth struct {
	AuthMode    string    `json:"auth_mode"`
	LastRefresh time.Time `json:"last_refresh"`
	Tokens      struct {
		AccessToken  string `json:"access_token"`
		RefreshToken string `json:"refresh_token"`
		IDToken      string `json:"id_token"`
		AccountID    string `json:"account_id"`
	} `json:"tokens"`
}

// ParseCodexAuth reports whether a harness:openai value is a ChatGPT login
// (an auth.json from `codex login`) rather than an API key.
func ParseCodexAuth(v string) (CodexAuth, bool) {
	var a CodexAuth
	if !strings.HasPrefix(strings.TrimSpace(v), "{") || json.Unmarshal([]byte(v), &a) != nil {
		return a, false
	}
	return a, a.AuthMode == "chatgpt" && a.Tokens.RefreshToken != ""
}

// CodexAuthRefreshed reports whether next is a later login for the same
// account as current. next comes from a container an agent could write to.
func CodexAuthRefreshed(current, next string) bool {
	cur, ok := ParseCodexAuth(current)
	if !ok {
		return false
	}
	n, ok := ParseCodexAuth(next)
	return ok && n.Tokens.AccountID == cur.Tokens.AccountID && n.LastRefresh.After(cur.LastRefresh) &&
		n.LastRefresh.Before(time.Now().Add(5*time.Minute))
}

// AntigravityAuth is the serialized container login state produced by
// `agy acp --login`, stored in harness:google and restored into a run
// container's $HOME before starting `agy`. Non-UTF-8 files are base64-encoded
// in FilesB64 so the secret remains valid UTF-8 JSON.
type AntigravityAuth struct {
	Version  int               `json:"v"`
	Files    map[string]string `json:"files,omitempty"`
	FilesB64 map[string]string `json:"files_b64,omitempty"`
}

// CleanAntigravityRelPath validates that rel is a safe relative path under an
// Antigravity config/state directory (.config/, .gemini/, .local/, or
// .antigravity/) with no traversal components.
func CleanAntigravityRelPath(rel string) (string, bool) {
	if rel == "" || strings.HasPrefix(rel, "/") || strings.Contains(rel, "\\") || strings.ContainsRune(rel, 0) {
		return "", false
	}
	cleaned := path.Clean(rel)
	if cleaned == "." || cleaned == ".." || strings.HasPrefix(cleaned, "../") || cleaned != rel {
		return "", false
	}
	for _, prefix := range []string{".config/", ".gemini/", ".local/", ".antigravity/"} {
		if strings.HasPrefix(cleaned, prefix) {
			return cleaned, true
		}
	}
	return "", false
}

// DecodeFiles validates and decodes all text and base64-encoded files in the bundle.
func (a AntigravityAuth) DecodeFiles() (map[string][]byte, bool) {
	if a.Version != 1 || len(a.Files)+len(a.FilesB64) == 0 {
		return nil, false
	}
	out := make(map[string][]byte, len(a.Files)+len(a.FilesB64))
	for rel, content := range a.Files {
		cleaned, ok := CleanAntigravityRelPath(rel)
		if !ok || content == "" {
			return nil, false
		}
		out[cleaned] = []byte(content)
	}
	for rel, b64 := range a.FilesB64 {
		cleaned, ok := CleanAntigravityRelPath(rel)
		if !ok || b64 == "" {
			return nil, false
		}
		raw, err := base64.StdEncoding.DecodeString(b64)
		if err != nil || len(raw) == 0 {
			return nil, false
		}
		out[cleaned] = raw
	}
	return out, true
}

// ParseAntigravityAuth reports whether a harness:google value is a native
// Antigravity login bundle captured from `agy acp --login`.
func ParseAntigravityAuth(v string) (AntigravityAuth, bool) {
	var a AntigravityAuth
	if !strings.HasPrefix(strings.TrimSpace(v), "{") || json.Unmarshal([]byte(v), &a) != nil {
		return a, false
	}
	if _, ok := a.DecodeFiles(); !ok {
		return AntigravityAuth{}, false
	}
	return a, true
}

func subscriptionLogin(harness, key string) bool {
	switch harness {
	case agentdef.HarnessClaudeCode:
		return ClaudePlanLogin(key)
	case agentdef.HarnessAntigravity:
		_, ok := ParseAntigravityAuth(key)
		return ok
	}
	_, ok := ParseCodexAuth(key)
	return ok
}

package chatmodels

import (
	"encoding/base64"
	"fmt"
	"testing"
	"time"
)

func fakeJWT(sub string) string {
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256"}`))
	body := base64.RawURLEncoding.EncodeToString([]byte(fmt.Sprintf(`{"sub":%q}`, sub)))
	return hdr + "." + body + ".sig"
}

func codexAuth(account string, at time.Time) string {
	return fmt.Sprintf(`{"auth_mode":"chatgpt","last_refresh":%q,"tokens":{"access_token":"a","refresh_token":"r","id_token":"i","account_id":%q}}`, at.Format(time.RFC3339), account)
}

func TestParseCodexAuth(t *testing.T) {
	for v, want := range map[string]bool{
		codexAuth("acct", time.Now()):                 true,
		"sk-proj-apikey":                              false,
		`{"auth_mode":"apikey","OPENAI_API_KEY":"x"}`: false,
		`{"auth_mode":"chatgpt","tokens":{}}`:         false,
		`{not json`:                                   false,
	} {
		if _, ok := ParseCodexAuth(v); ok != want {
			t.Errorf("ParseCodexAuth(%q) = %v, want %v", v, ok, want)
		}
	}
}

func TestCodexAuthRefreshed(t *testing.T) {
	now := time.Now().Add(-time.Hour)
	cur := codexAuth("acct", now)
	for name, tc := range map[string]struct {
		next string
		want bool
	}{
		"newer":         {codexAuth("acct", now.Add(time.Minute)), true},
		"unchanged":     {cur, false},
		"older":         {codexAuth("acct", now.Add(-time.Minute)), false},
		"other account": {codexAuth("attacker", now.Add(time.Minute)), false},
		"far future":    {codexAuth("acct", time.Now().Add(time.Hour)), false},
		"garbage":       {"{}", false},
		"dropped access": {fmt.Sprintf(`{"auth_mode":"chatgpt","last_refresh":%q,"tokens":{"access_token":"","refresh_token":"r2","id_token":"i","account_id":"acct"}}`, now.Add(time.Minute).Format(time.RFC3339)), false},
	} {
		if got := CodexAuthRefreshed(cur, tc.next); got != tc.want {
			t.Errorf("%s: got %v, want %v", name, got, tc.want)
		}
	}
	// Empty account_id in current must never accept a forged refresh.
	if CodexAuthRefreshed(codexAuth("", now), codexAuth("", now.Add(time.Minute))) {
		t.Error("empty account_id should be rejected")
	}
	// When current id_token is a JWT with a sub claim, next must preserve the same sub.
	jwtCur := fmt.Sprintf(`{"auth_mode":"chatgpt","last_refresh":%q,"tokens":{"access_token":"a","refresh_token":"r","id_token":%q,"account_id":"acct"}}`, now.Format(time.RFC3339), fakeJWT("user-123"))
	jwtSame := fmt.Sprintf(`{"auth_mode":"chatgpt","last_refresh":%q,"tokens":{"access_token":"a2","refresh_token":"r2","id_token":%q,"account_id":"acct"}}`, now.Add(time.Minute).Format(time.RFC3339), fakeJWT("user-123"))
	jwtOther := fmt.Sprintf(`{"auth_mode":"chatgpt","last_refresh":%q,"tokens":{"access_token":"a2","refresh_token":"r2","id_token":%q,"account_id":"acct"}}`, now.Add(time.Minute).Format(time.RFC3339), fakeJWT("attacker-999"))
	if !CodexAuthRefreshed(jwtCur, jwtSame) {
		t.Error("matching JWT sub should be accepted")
	}
	if CodexAuthRefreshed(jwtCur, jwtOther) {
		t.Error("mismatched JWT sub should be rejected")
	}
}

func TestClaudeOAuthToken(t *testing.T) {
	if !ClaudeOAuthToken("sk-ant-oat01-abc") || ClaudeOAuthToken("sk-ant-api03-abc") {
		t.Fatal("token shapes misread")
	}
}

func claudeAuthJSON(access, refresh string, expiresAt int64) string {
	return fmt.Sprintf(`{"claudeAiOauth":{"accessToken":%q,"refreshToken":%q,"expiresAt":%d,"scopes":["user:profile","user:inference"],"subscriptionType":"max"}}`, access, refresh, expiresAt)
}

func TestParseClaudeAuth(t *testing.T) {
	for name, tc := range map[string]struct {
		v    string
		want bool
	}{
		"valid":        {claudeAuthJSON("sk-ant-oat01-a", "sk-ant-ort01-r", time.Now().Add(time.Hour).UnixMilli()), true},
		"setup token":  {"sk-ant-oat01-abc", false},
		"api key":      {"sk-ant-api03-abc", false},
		"no refresh":   {`{"claudeAiOauth":{"accessToken":"sk-ant-oat01-a"}}`, false},
		"invalidacted": {`{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}`, false},
		"garbage":      {"{not json", false},
	} {
		if _, ok := ParseClaudeAuth(tc.v); ok != tc.want {
			t.Errorf("%s: ParseClaudeAuth = %v, want %v", name, ok, tc.want)
		}
	}
	if !ClaudePlanLogin("sk-ant-oat01-abc") || !ClaudePlanLogin(claudeAuthJSON("a", "r", 1)) || ClaudePlanLogin("sk-ant-api03-abc") {
		t.Fatal("ClaudePlanLogin misclassified credential")
	}
}

func TestClaudeAuthRefreshed(t *testing.T) {
	base := time.Now().Add(time.Hour)
	cur := claudeAuthJSON("sk-ant-oat01-old", "sk-ant-ort01-old", base.UnixMilli())
	for name, tc := range map[string]struct {
		next string
		want bool
	}{
		"newer":            {claudeAuthJSON("sk-ant-oat01-new", "sk-ant-ort01-new", base.Add(time.Minute).UnixMilli()), true},
		"unchanged":        {cur, false},
		"unrotated":        {claudeAuthJSON("sk-ant-oat01-old", "sk-ant-ort01-old", base.Add(time.Minute).UnixMilli()), false},
		"bad access pfx":   {claudeAuthJSON("evil-token", "sk-ant-ort01-new", base.Add(time.Minute).UnixMilli()), false},
		"bad refresh pfx":  {claudeAuthJSON("sk-ant-oat01-new", "evil-refresh", base.Add(time.Minute).UnixMilli()), false},
		"older":            {claudeAuthJSON("sk-ant-oat01-old", "sk-ant-ort01-old", base.Add(-time.Minute).UnixMilli()), false},
		"far future":       {claudeAuthJSON("sk-ant-oat01-new", "sk-ant-ort01-new", time.Now().Add(45*24*time.Hour).UnixMilli()), false},
		"empty":            {`{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}`, false},
	} {
		if got := ClaudeAuthRefreshed(cur, tc.next); got != tc.want {
			t.Errorf("%s: got %v, want %v", name, got, tc.want)
		}
	}
}

func TestParseAntigravityAuth(t *testing.T) {
	valid := `{"v":1,"files":{".gemini/antigravity-cli/installation_id":"id-1",".gemini/antigravity-cli/jetski_state.pbtxt":"state"}}`
	validB64 := `{"v":1,"files_b64":{".local/share/antigravity/token.bin":"AQID"}}`
	for name, tc := range map[string]struct {
		v    string
		want bool
	}{
		"valid bundle":      {valid, true},
		"valid b64 bundle":  {validB64, true},
		"legacy gemini key": {"AIzaSyTestKey", false},
		"wrong version":     {`{"v":2,"files":{".config/antigravity/plugin-secrets.json":"x"}}`, false},
		"empty bundle":      {`{"v":1,"files":{}}`, false},
		"empty file value":  {`{"v":1,"files":{".config/antigravity/plugin-secrets.json":""}}`, false},
		"invalid base64":    {`{"v":1,"files_b64":{".gemini/token.bin":"!!!not-b64"}}`, false},
		"path traversal":    {`{"v":1,"files":{".config/antigravity/plugin-secrets.json":"x",".gemini/../.ssh/id_rsa":"k"}}`, false},
		"absolute path":     {`{"v":1,"files":{".config/antigravity/plugin-secrets.json":"x","/etc/passwd":"k"}}`, false},
		"disallowed dotdir": {`{"v":1,"files":{".config/antigravity/plugin-secrets.json":"x",".ssh/authorized_keys":"k"}}`, false},
		"invalid json":      {`{not json`, false},
	} {
		if _, ok := ParseAntigravityAuth(tc.v); ok != tc.want {
			t.Errorf("%s: ParseAntigravityAuth = %v, want %v", name, ok, tc.want)
		}
	}
}

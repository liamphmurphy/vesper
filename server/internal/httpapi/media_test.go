package httpapi

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

func rawReq(t *testing.T, e *chatEnv, method, path string, body any) (int, string) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequest(method, e.srv.URL+"/api/v1"+path, rd)
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return res.StatusCode, string(raw)
}

func newMediaEnv(t *testing.T, withBox bool) (*chatEnv, *fake.Controller) {
	t.Helper()
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.Register(reg, ctrl)
	media.RegisterLocalMLXPlaceholder(reg)

	var box *secrets.Box
	if withBox {
		k := make([]byte, 32)
		_, _ = rand.Read(k)
		var err error
		box, err = secrets.NewBox(base64.StdEncoding.EncodeToString(k))
		if err != nil {
			t.Fatal(err)
		}
	}

	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.MediaRegistry = reg
	})
	return e, ctrl
}

func TestMediaProviderEndpoints(t *testing.T) {
	e, ctrl := newMediaEnv(t, true)

	snap := e.want("GET", "/media/providers", nil, http.StatusOK)
	providers := snap["providers"].([]any)
	if len(providers) != 2 {
		t.Fatalf("got %d providers, want 2", len(providers))
	}

	// Validation rejections return 422.
	e.want("PUT", "/media/providers/unknown", map[string]any{"settings": map[string]any{}}, http.StatusUnprocessableEntity)
	e.want("PUT", "/media/providers/fake", map[string]any{"settings": map[string]any{"unknown_field": "x"}}, http.StatusUnprocessableEntity)
	e.want("PUT", "/media/providers/local-mlx", map[string]any{"enabled": true}, http.StatusUnprocessableEntity)

	// Save encrypted secret; verify plaintext never appears in PUT or GET responses.
	const secretVal = "sk-fake-super-secret-9999"
	code, rawPut := rawReq(t, e, "PUT", "/media/providers/fake", map[string]any{
		"settings": map[string]any{"mode": "slow"},
		"secrets":  map[string]any{"api_key": secretVal},
	})
	if code != http.StatusOK {
		t.Fatalf("PUT provider = %d %s", code, rawPut)
	}
	if strings.Contains(rawPut, secretVal) || strings.Contains(rawPut, "9999") {
		t.Fatalf("PUT leaked secret: %s", rawPut)
	}
	code, rawGet := rawReq(t, e, "GET", "/media/providers", nil)
	if code != http.StatusOK {
		t.Fatalf("GET providers = %d %s", code, rawGet)
	}
	if strings.Contains(rawGet, secretVal) || strings.Contains(rawGet, "9999") {
		t.Fatalf("GET leaked secret: %s", rawGet)
	}
	if !strings.Contains(rawGet, `"api_key":true`) {
		t.Fatalf("expected secrets_set.api_key true: %s", rawGet)
	}

	// Check endpoint: OK, then classified auth failure.
	chk := e.want("POST", "/media/providers/fake/check", nil, http.StatusOK)
	if chk["ok"] != true {
		t.Fatalf("check = %v", chk)
	}
	ctrl.CheckErr = &media.ProviderError{Provider: "fake", Kind: media.ErrKindAuth, Message: "API key rejected"}
	chk = e.want("POST", "/media/providers/fake/check", nil, http.StatusOK)
	if chk["ok"] != false || chk["error_kind"] != "auth" {
		t.Fatalf("failed check = %v", chk)
	}

	// Default selector rejects coming_soon and invalid provider; accepts fake.
	e.want("PUT", "/media/defaults/music", map[string]any{"provider_id": "local-mlx"}, http.StatusUnprocessableEntity)
	e.want("PUT", "/media/defaults/music", map[string]any{"provider_id": "missing"}, http.StatusUnprocessableEntity)
	defResp := e.want("PUT", "/media/defaults/music", map[string]any{"provider_id": "fake"}, http.StatusOK)
	if defResp["defaults"].(map[string]any)["music"] != "fake" {
		t.Fatalf("defaults = %v", defResp["defaults"])
	}

	// Clear secret -> 204 and available becomes false.
	e.want("DELETE", "/media/providers/fake/secret?field=api_key", nil, http.StatusNoContent)
	afterClear := e.want("GET", "/media/providers", nil, http.StatusOK)
	first := afterClear["providers"].([]any)[0].(map[string]any)
	if first["available"] != false {
		t.Fatalf("expected unavailable after clearing secret: %v", first)
	}
}

func TestMediaProviderRequiresSecretsKey(t *testing.T) {
	e, _ := newMediaEnv(t, false)
	e.want("PUT", "/media/providers/fake", map[string]any{
		"secrets": map[string]any{"api_key": "sk-no-key"},
	}, http.StatusConflict)
}

func TestMediaProviderVideoAndTTSDefaults(t *testing.T) {
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.RegisterVideo(reg, ctrl)
	fake.RegisterSpeech(reg, ctrl)

	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.MediaRegistry = reg
	})

	e.want("PUT", "/media/providers/"+fake.VideoProviderID, map[string]any{
		"secrets": map[string]any{"api_key": "sk-video"},
	}, http.StatusOK)
	e.want("PUT", "/media/providers/"+fake.SpeechProviderID, map[string]any{
		"secrets": map[string]any{"api_key": "sk-speech"},
	}, http.StatusOK)

	vDef := e.want("PUT", "/media/defaults/video", map[string]any{"provider_id": fake.VideoProviderID}, http.StatusOK)
	if vDef["defaults"].(map[string]any)["video"] != fake.VideoProviderID {
		t.Fatalf("video default = %v", vDef["defaults"])
	}
	tDef := e.want("PUT", "/media/defaults/tts", map[string]any{"provider_id": fake.SpeechProviderID}, http.StatusOK)
	if tDef["defaults"].(map[string]any)["tts"] != fake.SpeechProviderID {
		t.Fatalf("tts default = %v", tDef["defaults"])
	}
	// Mismatched capability is rejected.
	e.want("PUT", "/media/defaults/video", map[string]any{"provider_id": fake.SpeechProviderID}, http.StatusUnprocessableEntity)
}

func TestImageEngineIncludesGeminiMediaProvider(t *testing.T) {
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.RegisterImage(reg, "gemini", ctrl)

	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.MediaRegistry = reg
	})

	findOption := func(resp map[string]any, engine string) map[string]any {
		t.Helper()
		for _, raw := range resp["options"].([]any) {
			opt := raw.(map[string]any)
			if opt["engine"] == engine {
				return opt
			}
		}
		t.Fatalf("engine %q missing from options: %v", engine, resp["options"])
		return nil
	}

	// Initially Gemini is listed as an option, unavailable with its default model.
	before := e.want("GET", "/image-engine", nil, http.StatusOK)
	gBefore := findOption(before, "gemini")
	if gBefore["available"] != false || gBefore["label"] != "Gemini API" || gBefore["model"] != "fake-nano-banana" {
		t.Fatalf("gemini option before config = %v", gBefore)
	}

	// Saving Gemini's API key & custom model makes Gemini API available in /image-engine.
	e.want("PUT", "/media/providers/gemini", map[string]any{
		"settings": map[string]any{"image_model": "fake-nano-banana-fast"},
		"secrets":  map[string]any{"api_key": "AIza-image-test"},
	}, http.StatusOK)

	after := e.want("GET", "/image-engine", nil, http.StatusOK)
	gAfter := findOption(after, "gemini")
	if gAfter["available"] != true || gAfter["model"] != "fake-nano-banana-fast" {
		t.Fatalf("gemini option after config = %v", gAfter)
	}

	// Workspace can select gemini as its image engine.
	saved := e.want("PUT", "/image-engine", map[string]any{"engine": "gemini"}, http.StatusOK)
	if saved["engine"] != "gemini" {
		t.Fatalf("saved engine = %v, want gemini", saved["engine"])
	}
}

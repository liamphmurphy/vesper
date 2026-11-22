package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func newVoiceEnv(t *testing.T, configure bool) (*chatEnv, *fake.Controller) {
	t.Helper()
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.RegisterSpeech(reg, ctrl)
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	blobs := newFakeBlobs(t)
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.MediaRegistry = reg
		s.Blobs = blobs.Store
		s.ArtifactBucket = avatarBucket
	})
	if configure {
		e.want("PUT", "/media/providers/fake-speech", map[string]any{"secrets": map[string]any{"api_key": "k"}}, http.StatusOK)
	}
	return e, ctrl
}

func (e *chatEnv) speech(chatID, msgID string) (*http.Response, []byte) {
	e.t.Helper()
	res, err := http.Get(e.srv.URL + "/api/v1/chats/" + chatID + "/messages/" + msgID + "/speech")
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res, b
}

func TestReplySpeechUsesThePersonasVoiceAndCaches(t *testing.T) {
	e, ctrl := newVoiceEnv(t, true)
	p := e.want("POST", "/personas", map[string]any{"name": "Laura"}, http.StatusCreated)
	pid := p["id"].(string)
	if v := p["voice"].(map[string]any); v["mode"] != "off" || v["name"] != "" {
		t.Fatalf("default voice = %v", v)
	}
	chat := e.newChat(map[string]any{"persona_id": pid})
	chatID := chat["id"].(string)
	m, err := e.q.AppendChatMessage(context.Background(), store.AppendChatMessageParams{
		SessionID: uuid.MustParse(chatID), Role: "assistant", ContextRefs: json.RawMessage("[]"), Citations: json.RawMessage("[]"),
		BodyMd: "## Done\n\nI fixed the **lock** [1].\n\n```go\nx := 1\n```\n\nSee https://example.com for more.",
	})
	if err != nil {
		t.Fatal(err)
	}
	msgID := m.ID.String()

	// Off by default: nothing is generated.
	if res, _ := e.speech(chatID, msgID); res.StatusCode != http.StatusConflict {
		t.Fatalf("voice off = %d", res.StatusCode)
	}
	upd := e.want("PATCH", "/personas/"+pid, map[string]any{"revision": p["revision"], "voice_mode": "popout", "voice_name": "Sulafat", "voice_style": "warm, unhurried"}, http.StatusOK)
	if v := upd["voice"].(map[string]any); v["mode"] != "popout" || v["name"] != "Sulafat" || v["style"] != "warm, unhurried" {
		t.Fatalf("voice after patch = %v", v)
	}

	res, body := e.speech(chatID, msgID)
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "audio/wav" || res.Header.Get("X-Speech-Words") != "8" || string(body[:4]) != "RIFF" {
		t.Fatalf("speech = %d %v %q", res.StatusCode, res.Header, body[:4])
	}
	calls := ctrl.SpeechRequests()
	if len(calls) != 1 || calls[0].Voice != "Sulafat" || calls[0].Style != "warm, unhurried" || calls[0].Text != "Done. I fixed the lock. See for more." {
		t.Fatalf("speech requests = %+v", calls)
	}
	// A replay is served from storage, not spoken again.
	if res, _ := e.speech(chatID, msgID); res.StatusCode != 200 || len(ctrl.SpeechRequests()) != 1 {
		t.Fatalf("replay = %d, %d calls", res.StatusCode, len(ctrl.SpeechRequests()))
	}
	// A new style speaks afresh.
	e.want("PATCH", "/personas/"+pid, map[string]any{"revision": upd["revision"], "voice_style": "bright"}, http.StatusOK)
	if res, _ := e.speech(chatID, msgID); res.StatusCode != 200 || len(ctrl.SpeechRequests()) != 2 {
		t.Fatalf("after a new style: %d, %d calls", res.StatusCode, len(ctrl.SpeechRequests()))
	}

	// Your own messages aren't spoken; someone else's chat is a 404.
	mine, _ := e.q.AppendChatMessage(context.Background(), store.AppendChatMessageParams{SessionID: uuid.MustParse(chatID), Role: "user", BodyMd: "hi", ContextRefs: json.RawMessage("[]"), Citations: json.RawMessage("[]")})
	if res, _ := e.speech(chatID, mine.ID.String()); res.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("user message = %d", res.StatusCode)
	}
	if res, _ := e.speech(uuid.NewString(), msgID); res.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown chat = %d", res.StatusCode)
	}
}

func TestPersonaVoicesPreviewAndValidation(t *testing.T) {
	e, ctrl := newVoiceEnv(t, false)
	p := e.want("POST", "/personas", map[string]any{"name": "Iris"}, http.StatusCreated)
	pid := p["id"].(string)

	// No provider yet: the list says why instead of failing.
	list := e.want("GET", "/personas/voices", nil, http.StatusOK)
	if list["available"] != false || !strings.Contains(list["reason"].(string), "Speech provider") {
		t.Fatalf("voices without a provider = %v", list)
	}
	e.want("POST", "/personas/"+pid+"/voice-preview", map[string]any{}, http.StatusConflict)

	e.want("PUT", "/media/providers/fake-speech", map[string]any{"secrets": map[string]any{"api_key": "k"}}, http.StatusOK)
	list = e.want("GET", "/personas/voices", nil, http.StatusOK)
	if list["available"] != true || list["default_voice"] != "Kore" || len(list["voices"].([]any)) != 2 {
		t.Fatalf("voices = %v", list)
	}
	res, err := http.Post(e.srv.URL+"/api/v1/personas/"+pid+"/voice-preview", "application/json", strings.NewReader(`{"voice_name":"Sulafat","voice_style":"playful"}`))
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "audio/wav" {
		t.Fatalf("preview = %d %v", res.StatusCode, res.Header)
	}
	if c := ctrl.SpeechRequests(); len(c) != 1 || c[0].Voice != "Sulafat" || c[0].Style != "playful" || !strings.Contains(c[0].Text, "Iris") {
		t.Fatalf("preview request = %+v", c)
	}

	rev := p["revision"]
	e.invalid("PATCH", "/personas/"+pid, map[string]any{"revision": rev, "voice_mode": "loud"}, "voice_mode", "use one of")
	e.invalid("PATCH", "/personas/"+pid, map[string]any{"revision": rev, "voice_name": "Not a voice!"}, "voice_name", "pick a voice")
}

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
	"github.com/liamphmurphy/vesper/server/internal/speech"
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

func (e *chatEnv) speech(chatID, msgID string, query ...string) (*http.Response, []byte) {
	e.t.Helper()
	url := e.srv.URL + "/api/v1/chats/" + chatID + "/messages/" + msgID + "/speech"
	if len(query) > 0 {
		url += "?" + strings.Join(query, "&")
	}
	res, err := http.Get(url)
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

func TestReplySpeechSpeaksTheLeadAndRestSeparately(t *testing.T) {
	e, ctrl := newVoiceEnv(t, true)
	p := e.want("POST", "/personas", map[string]any{"name": "Iris"}, http.StatusCreated)
	pid := p["id"].(string)
	e.want("PATCH", "/personas/"+pid, map[string]any{"revision": p["revision"], "voice_mode": "always"}, http.StatusOK)
	chatID := e.newChat(map[string]any{"persona_id": pid})["id"].(string)
	reply := func(body string) string {
		m, err := e.q.AppendChatMessage(context.Background(), store.AppendChatMessageParams{
			SessionID: uuid.MustParse(chatID), Role: "assistant", BodyMd: body, ContextRefs: json.RawMessage("[]"), Citations: json.RawMessage("[]"),
		})
		if err != nil {
			t.Fatal(err)
		}
		return m.ID.String()
	}
	msgID := reply("Sure. I checked the **runner** and it looks fine.\n\nWant the logs?")

	res, _ := e.speech(chatID, msgID, "part=lead")
	if res.StatusCode != 200 || res.Header.Get("X-Speech-Words") != "9" {
		t.Fatalf("lead = %d %v", res.StatusCode, res.Header)
	}
	res, _ = e.speech(chatID, msgID, "part=rest")
	if res.StatusCode != 200 || res.Header.Get("X-Speech-Words") != "3" {
		t.Fatalf("rest = %d %v", res.StatusCode, res.Header)
	}
	calls := ctrl.SpeechRequests()
	if len(calls) != 2 || calls[0].Text != "Sure. I checked the runner and it looks fine." || calls[1].Text != "Want the logs?" {
		t.Fatalf("speech requests = %+v", calls)
	}
	// Each part caches apart from the whole reply, which still speaks in one piece.
	if res, _ := e.speech(chatID, msgID, "part=lead"); res.StatusCode != 200 || len(ctrl.SpeechRequests()) != 2 {
		t.Fatalf("lead replay = %d, %d calls", res.StatusCode, len(ctrl.SpeechRequests()))
	}
	if res, _ := e.speech(chatID, msgID); res.StatusCode != 200 || res.Header.Get("X-Speech-Words") != "12" {
		t.Fatalf("whole = %d %v", res.StatusCode, res.Header)
	}

	// A reply that's all lead has no rest to speak.
	short := reply("Done, it's merged.")
	if res, _ := e.speech(chatID, short, "part=rest"); res.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("empty rest = %d", res.StatusCode)
	}
	if res, _ := e.speech(chatID, short, "part=middle"); res.StatusCode < 400 || res.StatusCode >= 500 {
		t.Fatalf("unknown part = %d", res.StatusCode)
	}
}

func TestReplySpeechStreamReturnsPCMAndCachesWAV(t *testing.T) {
	e, ctrl := newVoiceEnv(t, true)
	p := e.want("POST", "/personas", map[string]any{"name": "Iris"}, http.StatusCreated)
	pid := p["id"].(string)
	e.want("PATCH", "/personas/"+pid, map[string]any{"revision": p["revision"], "voice_mode": "always"}, http.StatusOK)
	chatID := e.newChat(map[string]any{"persona_id": pid})["id"].(string)
	m, err := e.q.AppendChatMessage(context.Background(), store.AppendChatMessageParams{
		SessionID: uuid.MustParse(chatID), Role: "assistant", BodyMd: "Sure. I checked the runner and it looks fine.\n\nWant the logs?",
		ContextRefs: json.RawMessage("[]"), Citations: json.RawMessage("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}
	msgID := m.ID.String()

	streamURL := e.srv.URL + "/api/v1/chats/" + chatID + "/messages/" + msgID + "/speech/stream?part=lead"
	res, err := http.Get(streamURL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || !strings.HasPrefix(strings.ToLower(res.Header.Get("Content-Type")), "audio/l16") || res.Header.Get("X-Speech-Words") != "9" || res.Header.Get("X-Speech-Sample-Rate") == "" || len(body) == 0 {
		t.Fatalf("stream = %d %v (%d bytes)", res.StatusCode, res.Header, len(body))
	}
	if len(ctrl.SpeechRequests()) != 1 {
		t.Fatalf("speech calls = %d, want 1", len(ctrl.SpeechRequests()))
	}
	// Cached WAV serves both replay streams and the WAV endpoint without re-synthesizing.
	res2, err := http.Get(streamURL)
	if err != nil {
		t.Fatal(err)
	}
	body2, _ := io.ReadAll(res2.Body)
	res2.Body.Close()
	if res2.StatusCode != http.StatusOK || len(body2) != len(body) || len(ctrl.SpeechRequests()) != 1 {
		t.Fatalf("stream replay = %d (%d vs %d bytes), %d calls", res2.StatusCode, len(body2), len(body), len(ctrl.SpeechRequests()))
	}
	wavRes, wavBody := e.speech(chatID, msgID, "part=lead")
	if wavRes.StatusCode != http.StatusOK || string(wavBody[:4]) != "RIFF" || len(ctrl.SpeechRequests()) != 1 {
		t.Fatalf("wav replay after stream = %d, %d calls", wavRes.StatusCode, len(ctrl.SpeechRequests()))
	}
}

func TestReplySpeechStreamUsesPreSynthesizedBrokerClip(t *testing.T) {
	broker := speech.NewBroker(0)
	defer broker.Close()

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
		s.SpeechBroker = broker
	})
	e.want("PUT", "/media/providers/fake-speech", map[string]any{"secrets": map[string]any{"api_key": "k"}}, http.StatusOK)

	p := e.want("POST", "/personas", map[string]any{"name": "Iris"}, http.StatusCreated)
	pid := p["id"].(string)
	e.want("PATCH", "/personas/"+pid, map[string]any{"revision": p["revision"], "voice_mode": "always", "voice_name": "Kore"}, http.StatusOK)
	chatID := e.newChat(map[string]any{"persona_id": pid})["id"].(string)
	m, err := e.q.AppendChatMessage(context.Background(), store.AppendChatMessageParams{
		SessionID: uuid.MustParse(chatID), Role: "assistant",
		BodyMd:      "Sure. I checked the runner and it looks fine.\n\nWant the logs?",
		ContextRefs: json.RawMessage("[]"), Citations: json.RawMessage("[]"),
	})
	if err != nil {
		t.Fatal(err)
	}

	prePCM := []byte{0x11, 0x22, 0x33, 0x44, 0x55, 0x66}
	hash := speech.CacheHash("fake-speech", "Kore", "", "Sure. I checked the runner and it looks fine.")
	broker.Start(hash, func(ctx context.Context, onChunk func([]byte, int) error) ([]byte, string, error) {
		_ = onChunk(prePCM, 24000)
		return speech.WAVFromPCM(prePCM, 24000), "fake-tts", nil
	})

	streamURL := e.srv.URL + "/api/v1/chats/" + chatID + "/messages/" + m.ID.String() + "/speech/stream?part=lead"
	res, err := http.Get(streamURL)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || string(body) != string(prePCM) {
		t.Fatalf("presynth stream = %d %x, want 200 %x", res.StatusCode, body, prePCM)
	}
	if len(ctrl.SpeechRequests()) != 0 {
		t.Fatalf("expected 0 provider calls on presynth hit, got %d", len(ctrl.SpeechRequests()))
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

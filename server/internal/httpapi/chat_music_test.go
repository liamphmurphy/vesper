package httpapi

import (
	"crypto/rand"
	"encoding/base64"
	"net/http"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

func newChatMusicEnv(t *testing.T, configure bool) (*chatEnv, *fake.Controller) {
	t.Helper()
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.Register(reg, ctrl)
	media.RegisterLocalMLXPlaceholder(reg)

	blobs := newFakeBlobs(t)
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}

	var srv *Server
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.MediaRegistry = reg
		s.Blobs = blobs.Store
		s.ArtifactBucket = avatarBucket
		srv = s
	})
	t.Cleanup(func() {
		if srv != nil {
			srv.CloseMedia()
		}
	})

	if configure {
		e.want("PUT", "/media/providers/fake", map[string]any{
			"secrets": map[string]any{"api_key": "fake-secret-key"},
		}, http.StatusOK)
		e.want("PUT", "/media/defaults/music", map[string]any{
			"provider_id": "fake",
		}, http.StatusOK)
	}
	return e, ctrl
}

func waitForAudioJob(t *testing.T, e *chatEnv, chatID, audioID string) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		listed := e.want("GET", "/chats/"+chatID+"/audio", nil, http.StatusOK)["audio"].([]any)
		for _, raw := range listed {
			item := raw.(map[string]any)
			if item["id"] == audioID && item["state"] != "running" {
				return item
			}
		}
		time.Sleep(15 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for audio job %s", audioID)
	return nil
}

func TestChatMusicHappyPath(t *testing.T) {
	e, ctrl := newChatMusicEnv(t, true)
	chat := e.newChat(nil)
	chatID := chat["id"].(string)

	job := e.want("POST", "/chats/"+chatID+"/music", map[string]any{
		"title":        "Rainy Synthwave",
		"prompt":       "warm analog synthwave loop at 105 bpm",
		"lyrics":       "neon rain on glass",
		"instrumental": false,
		"length":       "clip",
	}, http.StatusCreated)

	if job["source_kind"] != "music" || job["state"] != "running" {
		t.Fatalf("created job = %v", job)
	}
	audioID := job["id"].(string)

	done := waitForAudioJob(t, e, chatID, audioID)
	if done["state"] != "done" || done["provider_id"] != "fake" {
		t.Fatalf("finished job = %v", done)
	}
	if done["prompt"] != "warm analog synthwave loop at 105 bpm" || done["lyrics"] != "neon rain on glass" || done["instrumental"] != false {
		t.Fatalf("metadata mismatch = %v", done)
	}
	if done["library_item_id"] == nil {
		t.Fatalf("expected library_item_id on finished music job: %v", done)
	}
	out := done["output"].(map[string]any)
	if out["content_type"] != "audio/wav" {
		t.Fatalf("output content_type = %v", out)
	}
	peaks := done["peaks"].([]any)
	if len(peaks) != runs.AudioPeakBuckets {
		t.Fatalf("got %d peaks, want %d", len(peaks), runs.AudioPeakBuckets)
	}

	if len(ctrl.Calls) != 1 || ctrl.Calls[0].Length != media.LengthClip || ctrl.Calls[0].Instrumental {
		t.Fatalf("fake calls = %+v", ctrl.Calls)
	}

	res, body := fetch(t, e.srv.URL+"/api/v1/chats/"+chatID+"/audio/"+audioID+"/content", map[string]string{"Range": "bytes=0-3"})
	if res.StatusCode != http.StatusPartialContent || body != "RIFF" {
		t.Fatalf("range response = %d %q", res.StatusCode, body)
	}

	lib := e.want("GET", "/library?kind=audio", nil, http.StatusOK)["items"].([]any)
	if len(lib) != 1 || lib[0].(map[string]any)["id"] != done["library_item_id"] {
		t.Fatalf("library items = %v", lib)
	}
}

func TestChatMusicStop(t *testing.T) {
	e, ctrl := newChatMusicEnv(t, true)
	ctrl.BlockCh = make(chan struct{})
	defer close(ctrl.BlockCh)

	chat := e.newChat(nil)
	chatID := chat["id"].(string)

	job := e.want("POST", "/chats/"+chatID+"/music", map[string]any{
		"prompt": "slow ambient drone",
	}, http.StatusCreated)
	audioID := job["id"].(string)

	stopped := e.want("POST", "/chats/"+chatID+"/audio/"+audioID+"/stop", nil, http.StatusOK)
	if stopped["state"] != "failed" || stopped["failure_kind"] != "stopped" {
		t.Fatalf("stopped job = %v", stopped)
	}
}

func TestChatMusicErrorMappingAndValidation(t *testing.T) {
	// Unconfigured provider returns 409.
	unconfEnv, _ := newChatMusicEnv(t, false)
	c0 := unconfEnv.newChat(nil)
	unconfEnv.want("POST", "/chats/"+c0["id"].(string)+"/music", map[string]any{"prompt": "upbeat lo-fi"}, http.StatusConflict)

	// Empty prompt returns 422.
	e, ctrl := newChatMusicEnv(t, true)
	chat := e.newChat(nil)
	chatID := chat["id"].(string)
	e.want("POST", "/chats/"+chatID+"/music", map[string]any{"prompt": "   "}, http.StatusUnprocessableEntity)

	cases := []struct {
		name string
		err  error
		want string
	}{
		{name: "quota", err: &media.ProviderError{Provider: "fake", Kind: media.ErrKindQuota, Message: "Gemini spending cap or quota reached."}, want: "quota"},
		{name: "auth", err: &media.ProviderError{Provider: "fake", Kind: media.ErrKindAuth, Message: "Gemini API key was rejected."}, want: "auth"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctrl.GenerateErr = tc.err
			job := e.want("POST", "/chats/"+chatID+"/music", map[string]any{"prompt": "ambient pad"}, http.StatusCreated)
			done := waitForAudioJob(t, e, chatID, job["id"].(string))
			if done["state"] != "failed" || done["error_kind"] != tc.want {
				t.Fatalf("got state=%v error_kind=%v (full=%v)", done["state"], done["error_kind"], done)
			}
		})
	}
}

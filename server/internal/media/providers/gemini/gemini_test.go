package gemini

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
)

func TestGenerateMusicClipFullAndPolling(t *testing.T) {
	wav := fake.SineWAV(8000, 1)
	b64WAV := base64.StdEncoding.EncodeToString(wav)

	var (
		gotModel  string
		gotPrompt string
		gotAPIKey string
		pollCount atomic.Int32
	)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAPIKey = r.Header.Get("x-goog-api-key")
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/interactions"):
			var body map[string]any
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Fatal(err)
			}
			gotModel, _ = body["model"].(string)
			gotPrompt, _ = body["input"].(string)

			if gotModel == "lyria-3-pro-preview" {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"id":     "inter_poll_1",
					"status": "in_progress",
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_clip_1",
				"status": "completed",
				"steps": []map[string]any{{
					"type": "model_output",
					"content": []map[string]any{
						{"type": "text", "text": "Generated synth notes"},
						{"type": "audio", "data": b64WAV, "mime_type": "audio/wav"},
					},
				}},
			})
		case r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, "/interactions/inter_poll_1"):
			if pollCount.Add(1) < 2 {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"id":     "inter_poll_1",
					"status": "in_progress",
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_poll_1",
				"status": "completed",
				"steps": []map[string]any{{
					"type": "model_output",
					"content": []map[string]any{
						{"type": "text", "text": "[Verse 1]\nNeon rain"},
						{"type": "audio", "data": b64WAV, "mime_type": "audio/wav"},
					},
				}},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()

	const secretKey = "AIzaTestSecret9876"
	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api", "model": "auto"},
		Secrets:  map[string]string{"api_key": secretKey},
	}, WithBaseURL(ts.URL), WithPollInterval(5*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}

	// Clip + instrumental.
	clip, err := prov.GenerateMusic(context.Background(), media.MusicRequest{
		Prompt:       "Midnight lo-fi synth",
		Lyrics:       "Ignored lyrics",
		Instrumental: true,
		Length:       media.LengthClip,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if gotAPIKey != secretKey {
		t.Fatalf("api key header = %q, want %q", gotAPIKey, secretKey)
	}
	if gotModel != "lyria-3-clip-preview" {
		t.Fatalf("clip model = %q, want lyria-3-clip-preview", gotModel)
	}
	if !strings.Contains(gotPrompt, "Instrumental only") || strings.Contains(gotPrompt, "Ignored lyrics") {
		t.Fatalf("unexpected instrumental prompt: %q", gotPrompt)
	}
	if clip.ContentType != "audio/wav" || clip.FilenameExt != ".wav" || len(clip.Data) != len(wav) {
		t.Fatalf("unexpected clip: type=%s ext=%s len=%d", clip.ContentType, clip.FilenameExt, len(clip.Data))
	}

	// Full track + lyrics + polling.
	full, err := prov.GenerateMusic(context.Background(), media.MusicRequest{
		Prompt: "Warm Rhodes groove",
		Lyrics: "[Verse 1]\nNeon rain",
		Length: media.LengthFull,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if gotModel != "lyria-3-pro-preview" {
		t.Fatalf("full model = %q, want lyria-3-pro-preview", gotModel)
	}
	if !strings.Contains(gotPrompt, "Lyrics:\n[Verse 1]") {
		t.Fatalf("unexpected lyrics prompt: %q", gotPrompt)
	}
	if pollCount.Load() < 2 {
		t.Fatalf("expected polling at least twice, got %d", pollCount.Load())
	}
	if full.GeneratedLyrics != "[Verse 1]\nNeon rain" {
		t.Fatalf("generated lyrics = %q", full.GeneratedLyrics)
	}
}

func TestCheckAndErrorMapping(t *testing.T) {
	const secretKey = "AIzaSecretLeakCheck999"
	var statusCode int
	var respBody map[string]any
	var retryHdr string

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if retryHdr != "" {
			w.Header().Set("Retry-After", retryHdr)
		}
		if statusCode == http.StatusOK && strings.Contains(r.URL.Path, "/models") {
			_ = json.NewEncoder(w).Encode(map[string]any{"models": []map[string]any{{"name": "models/lyria-3-clip-preview"}}})
			return
		}
		w.WriteHeader(statusCode)
		_ = json.NewEncoder(w).Encode(respBody)
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api"},
		Secrets:  map[string]string{"api_key": secretKey},
	}, WithBaseURL(ts.URL), WithPollInterval(5*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}

	// Check OK.
	statusCode = http.StatusOK
	if err := prov.Check(context.Background()); err != nil {
		t.Fatalf("Check OK failed: %v", err)
	}

	// Check 401/403 maps to ErrKindAuth and scrubs API key.
	statusCode = http.StatusForbidden
	respBody = map[string]any{"error": map[string]any{"code": 403, "status": "PERMISSION_DENIED", "message": "key " + secretKey + " has billing disabled"}}
	err = prov.Check(context.Background())
	var pe *media.ProviderError
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindAuth {
		t.Fatalf("403 check = %v, want ErrKindAuth", err)
	}
	if strings.Contains(err.Error(), secretKey) {
		t.Fatalf("error leaked secret key: %s", err.Error())
	}

	// GenerateMusic 429 (Interactions string error code) maps to ErrKindQuota with RetryAfter.
	statusCode = http.StatusTooManyRequests
	retryHdr = "12"
	respBody = map[string]any{"error": map[string]any{"code": "RESOURCE_EXHAUSTED", "message": "Quota exceeded for key " + secretKey}}
	_, err = prov.GenerateMusic(context.Background(), media.MusicRequest{Prompt: "test"}, nil)
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindQuota || pe.RetryAfter != 12*time.Second {
		t.Fatalf("429 generate = %+v (%v), want ErrKindQuota + 12s RetryAfter", pe, err)
	}
	if strings.Contains(err.Error(), secretKey) {
		t.Fatalf("429 error leaked secret key: %s", err.Error())
	}

	// Numeric error.code fallback (ResponseValidationError) also maps cleanly to ErrKindAuth/ErrKindQuota.
	retryHdr = ""
	statusCode = http.StatusUnauthorized
	respBody = map[string]any{"error": map[string]any{"code": 401, "message": "API key not valid: " + secretKey}}
	_, err = prov.GenerateMusic(context.Background(), media.MusicRequest{Prompt: "test"}, nil)
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindAuth {
		t.Fatalf("401 numeric generate = %+v (%v), want ErrKindAuth", pe, err)
	}
	if strings.Contains(err.Error(), secretKey) {
		t.Fatalf("401 error leaked secret key: %s", err.Error())
	}

	// Safety block in Interactions error maps to ErrKindFiltered.
	statusCode = http.StatusBadRequest
	respBody = map[string]any{"error": map[string]any{"code": "safety_blocked", "message": "Prompt blocked due to safety policy"}}
	_, err = prov.GenerateMusic(context.Background(), media.MusicRequest{Prompt: "test"}, nil)
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindFiltered {
		t.Fatalf("safety generate = %v, want ErrKindFiltered", err)
	}
}

func TestGenerateMusicContextCancel(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"id": "inter_cancel", "status": "in_progress"})
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api"},
		Secrets:  map[string]string{"api_key": "AIzaCancel"},
	}, WithBaseURL(ts.URL), WithPollInterval(200*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, err = prov.GenerateMusic(ctx, media.MusicRequest{Prompt: "cancel test"}, nil)
	if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		t.Fatalf("got %v, want context cancellation", err)
	}
}

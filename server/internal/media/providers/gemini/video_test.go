package gemini

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"google.golang.org/genai/interactions/models/interactions"

	"github.com/liamphmurphy/vesper/server/internal/media"
)

func fakeMP4Bytes() []byte {
	// Minimal ISO BMFF ftyp box header followed by payload bytes.
	return append([]byte{0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p', 'i', 's', 'o', 'm'}, []byte("fake-mp4-video-stream")...)
}

func fakePNGBytes() []byte {
	return []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0x00, 0x00, 0x00, 0x0d}
}

func TestDescriptorAdvertisesMusicAndVideoWithBackwardCompat(t *testing.T) {
	desc := Descriptor()
	if !desc.Supports(media.CapMusic) {
		t.Fatal("expected Gemini descriptor to support CapMusic")
	}
	if !desc.Supports(media.CapVideo) {
		t.Fatal("expected Gemini descriptor to support CapVideo")
	}

	fields := make(map[string]media.FieldSpec, len(desc.Fields))
	for _, f := range desc.Fields {
		fields[f.Key] = f
	}
	if fields["model"].Default != modelAuto {
		t.Fatalf("Lyria model default = %q, want %q", fields["model"].Default, modelAuto)
	}
	vm, ok := fields["video_model"]
	if !ok {
		t.Fatal("missing video_model field in Gemini descriptor")
	}
	if vm.Default != string(interactions.ModelGeminiOmni12Flash) {
		t.Fatalf("video_model default = %q, want %q", vm.Default, interactions.ModelGeminiOmni12Flash)
	}
	if vm.Kind != "select" || len(vm.Options) == 0 {
		t.Fatalf("unexpected video_model field: %+v", vm)
	}

	reg := media.NewRegistry()
	Register(reg)
	if !reg.HasCapability(ProviderID, media.CapMusic) || !reg.HasCapability(ProviderID, media.CapVideo) {
		t.Fatal("registered Gemini provider missing expected capabilities")
	}
}

func TestGenerateVideoTextToVideoAndPolling(t *testing.T) {
	mp4 := fakeMP4Bytes()
	b64MP4 := base64.StdEncoding.EncodeToString(mp4)

	var (
		gotBody   map[string]any
		gotAPIKey string
		pollCount atomic.Int32
	)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotAPIKey = r.Header.Get("x-goog-api-key")
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1beta/interactions":
			if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
				t.Fatal(err)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_vid_poll_1",
				"status": "queued",
			})
		case r.Method == http.MethodGet && r.URL.Path == "/v1beta/interactions/inter_vid_poll_1":
			n := pollCount.Add(1)
			if n == 1 {
				_ = json.NewEncoder(w).Encode(map[string]any{
					"id":     "inter_vid_poll_1",
					"status": "in_progress",
				})
				return
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_vid_poll_1",
				"status": "completed",
				"steps": []map[string]any{{
					"type": "model_output",
					"content": []map[string]any{
						{"type": "video", "data": b64MP4, "mime_type": "video/mp4"},
					},
				}},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()

	const secretKey = "AIzaVideoSecret123"
	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api"},
		Secrets:  map[string]string{"api_key": secretKey},
	}, WithBaseURL(ts.URL), WithPollInterval(5*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}

	var (
		progMu   sync.Mutex
		progress []media.VideoProgress
	)
	clip, err := prov.GenerateVideo(context.Background(), media.VideoRequest{
		Prompt:      "A tabby cat piloting a glowing paper boat down a neon river",
		AspectRatio: "16:9",
		DurationSec: 6,
	}, func(p media.VideoProgress) {
		progMu.Lock()
		progress = append(progress, p)
		progMu.Unlock()
	})
	if err != nil {
		t.Fatalf("GenerateVideo failed: %v", err)
	}

	if gotAPIKey != secretKey {
		t.Fatalf("api key header = %q, want %q", gotAPIKey, secretKey)
	}
	if gotBody["model"] != string(interactions.ModelGeminiOmni12Flash) {
		t.Fatalf("model = %v, want %q", gotBody["model"], interactions.ModelGeminiOmni12Flash)
	}
	if gotBody["input"] != "A tabby cat piloting a glowing paper boat down a neon river" {
		t.Fatalf("input = %#v", gotBody["input"])
	}
	if _, hasPrev := gotBody["previous_interaction_id"]; hasPrev {
		t.Fatalf("unexpected previous_interaction_id on initial request: %v", gotBody["previous_interaction_id"])
	}
	rf, _ := gotBody["response_format"].(map[string]any)
	if rf["aspect_ratio"] != "16:9" || rf["duration"] != "6s" || rf["delivery"] != "inline" {
		t.Fatalf("unexpected response_format: %#v", rf)
	}
	gc, _ := gotBody["generation_config"].(map[string]any)
	vc, _ := gc["video_config"].(map[string]any)
	if vc["task"] != string(interactions.TaskTextToVideo) {
		t.Fatalf("video_config.task = %v, want %q", vc["task"], interactions.TaskTextToVideo)
	}

	if pollCount.Load() != 2 {
		t.Fatalf("pollCount = %d, want 2", pollCount.Load())
	}
	if !bytes.Equal(clip.Data, mp4) {
		t.Fatalf("clip data mismatch: got %d bytes, want %d", len(clip.Data), len(mp4))
	}
	if clip.ContentType != "video/mp4" || clip.FilenameExt != ".mp4" {
		t.Fatalf("clip format = %s / %s, want video/mp4 / .mp4", clip.ContentType, clip.FilenameExt)
	}
	if clip.DurationMS != 6000 {
		t.Fatalf("clip DurationMS = %d, want 6000", clip.DurationMS)
	}
	if clip.Model != string(interactions.ModelGeminiOmni12Flash) {
		t.Fatalf("clip Model = %q, want %q", clip.Model, interactions.ModelGeminiOmni12Flash)
	}
	if clip.InteractionID != "inter_vid_poll_1" {
		t.Fatalf("clip InteractionID = %q, want inter_vid_poll_1", clip.InteractionID)
	}
	if len(progress) < 3 {
		t.Fatalf("expected at least 3 progress updates, got %d: %+v", len(progress), progress)
	}
}

func TestGenerateVideoMultimodalFramesAndReferences(t *testing.T) {
	mp4 := fakeMP4Bytes()
	b64MP4 := base64.StdEncoding.EncodeToString(mp4)
	firstFrame := fakePNGBytes()
	lastFrame := append([]byte{0xff, 0xd8, 0xff, 0xe0}, []byte("jpeg-end")...)
	refImg := fakePNGBytes()

	var gotBody map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost && r.URL.Path == "/v1beta/interactions" {
			if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
				t.Fatal(err)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_bookend_1",
				"status": "completed",
				"steps": []map[string]any{{
					"type": "model_output",
					"content": []map[string]any{
						{"type": "video", "data": b64MP4, "mime_type": "video/mp4"},
					},
				}},
			})
			return
		}
		http.NotFound(w, r)
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api"},
		Secrets:  map[string]string{"api_key": "AIzaFrames"},
	}, WithBaseURL(ts.URL), WithPollInterval(5*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}

	clip, err := prov.GenerateVideo(context.Background(), media.VideoRequest{
		Prompt: "Smooth dolly zoom transitioning between the two frames",
		FirstFrame: &media.VideoFrame{
			Data:        firstFrame,
			ContentType: "image/png",
		},
		LastFrame: &media.VideoFrame{
			Data:        lastFrame,
			ContentType: "image/jpeg",
		},
		ReferenceImages: []media.VideoFrame{
			{Data: refImg, ContentType: "image/png"},
		},
		Model: string(interactions.ModelGeminiOmni11Flash),
	}, nil)
	if err != nil {
		t.Fatalf("GenerateVideo bookend failed: %v", err)
	}
	if clip.Model != string(interactions.ModelGeminiOmni11Flash) || clip.InteractionID != "inter_bookend_1" {
		t.Fatalf("unexpected clip metadata: %+v", clip)
	}

	gc, _ := gotBody["generation_config"].(map[string]any)
	vc, _ := gc["video_config"].(map[string]any)
	if vc["task"] != string(interactions.TaskImageToVideo) {
		t.Fatalf("task = %v, want %q", vc["task"], interactions.TaskImageToVideo)
	}

	blocks, ok := gotBody["input"].([]any)
	if !ok {
		t.Fatalf("expected array input for multimodal frames, got %T", gotBody["input"])
	}
	var imageMIMEs []string
	var textParts []string
	for _, rawBlock := range blocks {
		b, _ := rawBlock.(map[string]any)
		switch b["type"] {
		case "image":
			mt, _ := b["mime_type"].(string)
			imageMIMEs = append(imageMIMEs, mt)
			if data, _ := b["data"].(string); data == "" {
				t.Fatal("expected base64 image data in image block")
			}
		case "text":
			txt, _ := b["text"].(string)
			textParts = append(textParts, txt)
		}
	}
	wantMIMEs := []string{"image/png", "image/jpeg", "image/png"}
	if !slices.Equal(imageMIMEs, wantMIMEs) {
		t.Fatalf("image mime types = %v, want %v", imageMIMEs, wantMIMEs)
	}
	if !slices.Contains(textParts, "First frame:") || !slices.Contains(textParts, "Last frame:") || !slices.Contains(textParts, "Reference image:") {
		t.Fatalf("missing frame labels in text parts: %v", textParts)
	}

	// Reference-only request uses reference_to_video task.
	_, err = prov.GenerateVideo(context.Background(), media.VideoRequest{
		Prompt:          "Keep the character consistent",
		ReferenceImages: []media.VideoFrame{{Data: refImg}},
	}, nil)
	if err != nil {
		t.Fatalf("GenerateVideo reference-only failed: %v", err)
	}
	gc, _ = gotBody["generation_config"].(map[string]any)
	vc, _ = gc["video_config"].(map[string]any)
	if vc["task"] != string(interactions.TaskReferenceToVideo) {
		t.Fatalf("reference-only task = %v, want %q", vc["task"], interactions.TaskReferenceToVideo)
	}

	// Empty frame data fails before hitting the API.
	_, err = prov.GenerateVideo(context.Background(), media.VideoRequest{
		Prompt:     "bad frame",
		FirstFrame: &media.VideoFrame{},
	}, nil)
	if err == nil {
		t.Fatal("expected error for empty FirstFrame")
	}
}

func TestGenerateVideoFollowUpWithPreviousInteractionID(t *testing.T) {
	mp4 := fakeMP4Bytes()
	b64MP4 := base64.StdEncoding.EncodeToString(mp4)

	var gotBody map[string]any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.Method == http.MethodPost && r.URL.Path == "/v1beta/interactions" {
			if err := json.NewDecoder(r.Body).Decode(&gotBody); err != nil {
				t.Fatal(err)
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_followup_2",
				"status": "completed",
				"steps": []map[string]any{{
					"type": "model_output",
					"content": []map[string]any{
						{"type": "video", "data": b64MP4, "mime_type": "video/mp4"},
					},
				}},
			})
			return
		}
		http.NotFound(w, r)
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api"},
		Secrets:  map[string]string{"api_key": "AIzaFollowUp"},
	}, WithBaseURL(ts.URL), WithPollInterval(5*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}

	clip, err := prov.GenerateVideo(context.Background(), media.VideoRequest{
		Prompt:                "Make the sky sunset orange and slow down the camera pan",
		PreviousInteractionID: "inter_vid_poll_1",
	}, nil)
	if err != nil {
		t.Fatalf("follow-up GenerateVideo failed: %v", err)
	}
	if gotBody["previous_interaction_id"] != "inter_vid_poll_1" {
		t.Fatalf("previous_interaction_id = %v, want inter_vid_poll_1", gotBody["previous_interaction_id"])
	}
	if _, hasGenCfg := gotBody["generation_config"]; hasGenCfg {
		t.Fatalf("expected generation_config omitted on follow-up edit so model infers edit/extend, got %#v", gotBody["generation_config"])
	}
	if clip.InteractionID != "inter_followup_2" {
		t.Fatalf("InteractionID = %q, want inter_followup_2", clip.InteractionID)
	}
}

func TestGenerateVideoURIDownloadAndVertexAI(t *testing.T) {
	mp4 := fakeMP4Bytes()
	var (
		gotVideoAPIKey string
		gotVertexPath  string
	)
	var ts *httptest.Server
	ts = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/v1beta/interactions":
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_uri_1",
				"status": "completed",
				"steps": []map[string]any{{
					"type": "model_output",
					"content": []map[string]any{
						{"type": "video", "uri": ts.URL + "/files/video-1.mp4", "mime_type": "video/mp4"},
					},
				}},
			})
		case r.Method == http.MethodGet && r.URL.Path == "/files/video-1.mp4":
			gotVideoAPIKey = r.Header.Get("x-goog-api-key")
			w.Header().Set("Content-Type", "video/mp4")
			_, _ = w.Write(mp4)
		case r.Method == http.MethodPost && r.URL.Path == "/v1beta1/projects/vid-proj/locations/us-central1/interactions":
			gotVertexPath = r.URL.Path
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_vertex_vid_1",
				"status": "completed",
				"steps": []map[string]any{{
					"type": "model_output",
					"content": []map[string]any{
						{"type": "video", "data": base64.StdEncoding.EncodeToString(mp4), "mime_type": "video/mp4"},
					},
				}},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer ts.Close()

	// Gemini API + URI download.
	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api"},
		Secrets:  map[string]string{"api_key": "AIzaURIKey"},
	}, WithBaseURL(ts.URL), WithHTTPClient(ts.Client()), WithPollInterval(5*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	clip, err := prov.GenerateVideo(context.Background(), media.VideoRequest{Prompt: "URI test"}, nil)
	if err != nil {
		t.Fatalf("GenerateVideo URI failed: %v", err)
	}
	if gotVideoAPIKey != "AIzaURIKey" {
		t.Fatalf("URI download api key = %q, want AIzaURIKey", gotVideoAPIKey)
	}
	if !bytes.Equal(clip.Data, mp4) || clip.InteractionID != "inter_uri_1" {
		t.Fatalf("unexpected URI clip: len=%d id=%q", len(clip.Data), clip.InteractionID)
	}

	// Vertex AI backend.
	vprov, err := New(media.ResolvedConfig{
		Settings: map[string]string{
			"backend":  "vertex_ai",
			"project":  "vid-proj",
			"location": "us-central1",
		},
	}, WithBaseURL(ts.URL), WithHTTPClient(ts.Client()), WithPollInterval(5*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}
	vclip, err := vprov.GenerateVideo(context.Background(), media.VideoRequest{Prompt: "Vertex video"}, nil)
	if err != nil {
		t.Fatalf("GenerateVideo vertex_ai failed: %v", err)
	}
	if gotVertexPath != "/v1beta1/projects/vid-proj/locations/us-central1/interactions" {
		t.Fatalf("vertex path = %q", gotVertexPath)
	}
	if !bytes.Equal(vclip.Data, mp4) || vclip.InteractionID != "inter_vertex_vid_1" {
		t.Fatalf("unexpected vertex clip: len=%d id=%q", len(vclip.Data), vclip.InteractionID)
	}
}

func TestGenerateVideoCancelAndErrorMapping(t *testing.T) {
	const secretKey = "AIzaVideoErrSecret777"
	var (
		mode       string
		statusCode int
		respBody   map[string]any
		retryHdr   string
	)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if retryHdr != "" {
			w.Header().Set("Retry-After", retryHdr)
		}
		if mode == "poll_forever" {
			_ = json.NewEncoder(w).Encode(map[string]any{"id": "inter_vid_cancel", "status": "in_progress"})
			return
		}
		if mode == "failed_status" {
			_ = json.NewEncoder(w).Encode(map[string]any{
				"id":     "inter_vid_fail",
				"status": "failed",
				"errors": []map[string]any{{"code": "safety", "message": "Video blocked by safety policy"}},
			})
			return
		}
		w.WriteHeader(statusCode)
		_ = json.NewEncoder(w).Encode(respBody)
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": "gemini_api"},
		Secrets:  map[string]string{"api_key": secretKey},
	}, WithBaseURL(ts.URL), WithPollInterval(200*time.Millisecond))
	if err != nil {
		t.Fatal(err)
	}

	// Context cancellation during polling.
	mode = "poll_forever"
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()
	_, err = prov.GenerateVideo(ctx, media.VideoRequest{Prompt: "cancel video"}, nil)
	if !errors.Is(err, context.DeadlineExceeded) && !errors.Is(err, context.Canceled) {
		t.Fatalf("cancel err = %v, want context deadline/cancel", err)
	}

	// Failed interaction with safety error maps to ErrKindFiltered.
	mode = "failed_status"
	_, err = prov.GenerateVideo(context.Background(), media.VideoRequest{Prompt: "filtered video"}, nil)
	var pe *media.ProviderError
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindFiltered {
		t.Fatalf("failed safety err = %v, want ErrKindFiltered", err)
	}

	// 429 quota error with Retry-After and API key scrubbing.
	mode = "http_err"
	statusCode = http.StatusTooManyRequests
	retryHdr = "15"
	respBody = map[string]any{"error": map[string]any{"code": "RESOURCE_EXHAUSTED", "message": "Quota exceeded for " + secretKey}}
	_, err = prov.GenerateVideo(context.Background(), media.VideoRequest{Prompt: "quota video"}, nil)
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindQuota || pe.RetryAfter != 15*time.Second {
		t.Fatalf("429 err = %+v (%v), want ErrKindQuota + 15s RetryAfter", pe, err)
	}
	if strings.Contains(err.Error(), secretKey) {
		t.Fatalf("429 error leaked secret key: %s", err.Error())
	}

	// 401 auth error scrubs secret key.
	retryHdr = ""
	statusCode = http.StatusUnauthorized
	respBody = map[string]any{"error": map[string]any{"code": "UNAUTHENTICATED", "message": "Bad key " + secretKey}}
	_, err = prov.GenerateVideo(context.Background(), media.VideoRequest{Prompt: "auth video"}, nil)
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindAuth {
		t.Fatalf("401 err = %+v (%v), want ErrKindAuth", pe, err)
	}
	if strings.Contains(err.Error(), secretKey) {
		t.Fatalf("401 error leaked secret key: %s", err.Error())
	}
}

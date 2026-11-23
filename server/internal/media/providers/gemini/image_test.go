package gemini

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/runs"
)

// tinyPNG is a valid 1x1 PNG image so runs.GeneratedImageType accepts it.
var tinyPNG = []byte{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
	0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
	0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41,
	0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
	0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d,
	0xb0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
	0x44, 0xae, 0x42, 0x60, 0x82,
}

func TestGenerateImageSendsReferencesAndSkipsThoughtParts(t *testing.T) {
	thoughtBytes := []byte("not-final-image")
	var gotPath string
	var gotParts []struct {
		Text       string `json:"text"`
		InlineData *struct {
			MimeType string `json:"mimeType"`
			Data     string `json:"data"`
		} `json:"inlineData"`
	}
	var gotImageConfig map[string]any
	var gotModalities []any

	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		var body struct {
			Contents []struct {
				Parts []struct {
					Text       string `json:"text"`
					InlineData *struct {
						MimeType string `json:"mimeType"`
						Data     string `json:"data"`
					} `json:"inlineData"`
				} `json:"parts"`
			} `json:"contents"`
			GenerationConfig map[string]any `json:"generationConfig"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		gotParts = body.Contents[0].Parts
		gotModalities, _ = body.GenerationConfig["responseModalities"].([]any)
		gotImageConfig, _ = body.GenerationConfig["imageConfig"].(map[string]any)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"candidates": []any{
				map[string]any{
					"content": map[string]any{
						"parts": []any{
							map[string]any{
								"thought":    true,
								"inlineData": map[string]any{"mimeType": "image/png", "data": base64.StdEncoding.EncodeToString(thoughtBytes)},
							},
							map[string]any{
								"inlineData": map[string]any{"mimeType": "image/png", "data": base64.StdEncoding.EncodeToString(tinyPNG)},
							},
						},
					},
				},
			},
		})
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{
			"backend":     backendGeminiAPI,
			"image_model": "gemini-3.1-flash-image",
			"image_size":  "4K",
		},
		Secrets: map[string]string{"api_key": "secret-key"},
	}, WithBaseURL(ts.URL))
	if err != nil {
		t.Fatal(err)
	}

	got, err := prov.GenerateImage(context.Background(), media.ImageRequest{
		Prompt:      "A neon workshop in Night City",
		AspectRatio: "16:9",
		References: []media.ImageReference{
			{Role: runs.ReferencePersona, Data: tinyPNG, ContentType: "image/png"},
		},
	})
	if err != nil {
		t.Fatalf("GenerateImage: %v", err)
	}
	if !strings.HasSuffix(gotPath, "/models/gemini-3.1-flash-image:generateContent") {
		t.Errorf("path = %q", gotPath)
	}
	if len(gotModalities) != 2 {
		t.Errorf("modalities = %v", gotModalities)
	}
	if gotImageConfig["imageSize"] != "4K" || gotImageConfig["aspectRatio"] != "16:9" {
		t.Errorf("imageConfig = %v", gotImageConfig)
	}
	// Reference label + reference inline image + prompt text.
	if len(gotParts) != 3 || gotParts[1].InlineData == nil || gotParts[2].Text != "A neon workshop in Night City" {
		t.Fatalf("unexpected parts: %+v", gotParts)
	}
	if !bytes.Equal(got.Data, tinyPNG) {
		t.Fatalf("returned thought bytes instead of final image")
	}
	if got.ContentType != "image/png" || got.FilenameExt != ".png" || got.Model != "gemini-3.1-flash-image" {
		t.Errorf("got = %+v", got)
	}
}

func TestGenerateImageSafetyRefusal(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"candidates":[{"finishReason":"IMAGE_SAFETY","finishMessage":"blocked by safety policy"}]}`))
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": backendGeminiAPI},
		Secrets:  map[string]string{"api_key": "k"},
	}, WithBaseURL(ts.URL))
	if err != nil {
		t.Fatal(err)
	}
	_, err = prov.GenerateImage(context.Background(), media.ImageRequest{Prompt: "something blocked"})
	var pe *media.ProviderError
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindFiltered {
		t.Fatalf("want ErrKindFiltered, got %v", err)
	}
}

func TestGenerateImagePromptFeedbackBlock(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"promptFeedback":{"blockReason":"PROHIBITED_CONTENT","blockReasonMessage":"prompt prohibited"}}`))
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": backendGeminiAPI},
		Secrets:  map[string]string{"api_key": "k"},
	}, WithBaseURL(ts.URL))
	if err != nil {
		t.Fatal(err)
	}
	_, err = prov.GenerateImage(context.Background(), media.ImageRequest{Prompt: "blocked prompt"})
	var pe *media.ProviderError
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindFiltered || !strings.Contains(pe.Message, "prompt prohibited") {
		t.Fatalf("want ErrKindFiltered with message, got %v", err)
	}
}

func TestGenerateImageEmptyPromptRejected(t *testing.T) {
	prov, _ := New(media.ResolvedConfig{
		Settings: map[string]string{"backend": backendGeminiAPI},
		Secrets:  map[string]string{"api_key": "k"},
	})
	var pe *media.ProviderError
	if _, err := prov.GenerateImage(context.Background(), media.ImageRequest{Prompt: "   "}); !errors.As(err, &pe) {
		t.Fatalf("expected ProviderError for empty prompt, got %v", err)
	}
}

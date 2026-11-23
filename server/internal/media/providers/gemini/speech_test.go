package gemini

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/media"
)

func TestGenerateSpeechWrapsPCMAsWAV(t *testing.T) {
	pcm := bytes.Repeat([]byte{0x10, 0x00}, 24000) // one second of 16-bit mono at 24 kHz
	var gotPath, gotVoice, gotText, gotStyle string
	var gotModalities []any
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		var body struct {
			Contents []struct {
				Parts []struct {
					Text           string            `json:"text"`
					SpeechMetadata map[string]string `json:"speechMetadata"`
				} `json:"parts"`
			} `json:"contents"`
			GenerationConfig map[string]any `json:"generationConfig"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		gotText = body.Contents[0].Parts[0].Text
		gotStyle = body.Contents[0].Parts[0].SpeechMetadata["style"]
		gotModalities, _ = body.GenerationConfig["responseModalities"].([]any)
		sc, _ := body.GenerationConfig["speechConfig"].(map[string]any)
		vc, _ := sc["voiceConfig"].(map[string]any)
		pv, _ := vc["prebuiltVoiceConfig"].(map[string]any)
		gotVoice, _ = pv["voiceName"].(string)
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{
			map[string]any{"inlineData": map[string]any{"mimeType": "audio/L16;codec=pcm;rate=24000", "data": base64.StdEncoding.EncodeToString(pcm)}},
		}}}}})
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{Settings: map[string]string{"backend": "gemini_api"}, Secrets: map[string]string{"api_key": "k"}}, WithBaseURL(ts.URL))
	if err != nil {
		t.Fatal(err)
	}
	clip, err := prov.GenerateSpeech(context.Background(), media.SpeechRequest{Text: "Hello there.", Voice: "Sulafat", Style: "warm, unhurried"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(gotPath, "/models/"+defaultSpeechModel+":generateContent") {
		t.Errorf("path = %q", gotPath)
	}
	if gotVoice != "Sulafat" || len(gotModalities) != 1 || gotModalities[0] != "AUDIO" {
		t.Errorf("voice %q, modalities %v", gotVoice, gotModalities)
	}
	// 3.8 TTS reads its input word for word: the style must never be in the text.
	if gotText != "Hello there." || gotStyle != "warm, unhurried" {
		t.Errorf("text = %q, speechMetadata.style = %q", gotText, gotStyle)
	}
	if clip.ContentType != "audio/wav" || clip.DurationMS != 1000 || clip.Model != defaultSpeechModel {
		t.Errorf("clip = %s %dms %s", clip.ContentType, clip.DurationMS, clip.Model)
	}
	if string(clip.Data[:4]) != "RIFF" || string(clip.Data[8:12]) != "WAVE" || len(clip.Data) != 44+len(pcm) {
		t.Fatalf("not a WAV of the PCM: %q… (%d bytes)", clip.Data[:12], len(clip.Data))
	}
	if rate := binary.LittleEndian.Uint32(clip.Data[24:28]); rate != 24000 {
		t.Errorf("sample rate = %d", rate)
	}
}

func TestGenerateSpeechRefusals(t *testing.T) {
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"candidates":[{"content":{"parts":[{"text":"no"}]}}]}`))
	}))
	defer ts.Close()
	prov, _ := New(media.ResolvedConfig{Settings: map[string]string{"backend": "gemini_api", "tts_model": liteSpeechModel}, Secrets: map[string]string{"api_key": "k"}}, WithBaseURL(ts.URL))
	var pe *media.ProviderError
	if _, err := prov.GenerateSpeech(context.Background(), media.SpeechRequest{Text: "   "}); !errors.As(err, &pe) {
		t.Errorf("empty text: %v", err)
	}
	if _, err := prov.GenerateSpeech(context.Background(), media.SpeechRequest{Text: "hi"}); !errors.As(err, &pe) || pe.Kind != media.ErrKindFiltered {
		t.Errorf("no audio part: %v", err)
	}
	if len(prov.Voices()) != 30 {
		t.Errorf("voices = %d", len(prov.Voices()))
	}
}

// wavWithTrailer builds a WAV like gemini-3.8-flash-tts returns: header, the
// audio, then a provenance (C2PA) chunk that is not sound.
func wavWithTrailer(pcm []byte, rate int) []byte {
	body := wavFromPCM(pcm, rate)
	trailer := append([]byte("C2PA"), 0, 0x10, 0, 0)
	trailer = append(trailer, bytes.Repeat([]byte{0x7f, 0x80}, 0x800)...)
	out := append(body, trailer...)
	binary.LittleEndian.PutUint32(out[4:8], uint32(len(out)-8))
	return out
}

func TestGenerateSpeechKeepsOnlyTheAudioOfAWAVResponse(t *testing.T) {
	pcm := bytes.Repeat([]byte{0x10, 0x00}, 24000)
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{
			map[string]any{"inlineData": map[string]any{"mimeType": "audio/wav", "data": base64.StdEncoding.EncodeToString(wavWithTrailer(pcm, 24000))}},
		}}}}})
	}))
	defer ts.Close()
	prov, _ := New(media.ResolvedConfig{Settings: map[string]string{"backend": "gemini_api"}, Secrets: map[string]string{"api_key": "k"}}, WithBaseURL(ts.URL))
	clip, err := prov.GenerateSpeech(context.Background(), media.SpeechRequest{Text: "Hello."})
	if err != nil {
		t.Fatal(err)
	}
	// Exactly one header and the audio: no nested header (a click) and no
	// provenance bytes played as sound (the static at the end).
	if len(clip.Data) != 44+len(pcm) || !bytes.Equal(clip.Data[44:], pcm) || clip.DurationMS != 1000 {
		t.Fatalf("clip = %d bytes, %dms; want %d bytes of audio only", len(clip.Data), clip.DurationMS, 44+len(pcm))
	}
}

func TestStreamSpeechEmitsChunksAndWrapsWAV(t *testing.T) {
	chunk1 := bytes.Repeat([]byte{0x10, 0x00}, 6000)
	chunk2 := bytes.Repeat([]byte{0x20, 0x00}, 6000)
	var gotPath string
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		w.Header().Set("Content-Type", "text/event-stream")
		flusher, _ := w.(http.Flusher)
		for _, ch := range [][]byte{chunk1, chunk2} {
			payload, _ := json.Marshal(map[string]any{"candidates": []any{map[string]any{"content": map[string]any{"parts": []any{
				map[string]any{"inlineData": map[string]any{"mimeType": "audio/L16;codec=pcm;rate=24000", "data": base64.StdEncoding.EncodeToString(ch)}},
			}}}}})
			_, _ = w.Write([]byte("data: "))
			_, _ = w.Write(payload)
			_, _ = w.Write([]byte("\n\n"))
			if flusher != nil {
				flusher.Flush()
			}
		}
	}))
	defer ts.Close()

	prov, err := New(media.ResolvedConfig{Settings: map[string]string{"backend": "gemini_api"}, Secrets: map[string]string{"api_key": "k"}}, WithBaseURL(ts.URL))
	if err != nil {
		t.Fatal(err)
	}
	var chunks [][]byte
	var rates []int
	clip, err := prov.StreamSpeech(context.Background(), media.SpeechRequest{Text: "Hello streaming.", Voice: "Kore"}, func(c media.SpeechChunk) error {
		chunks = append(chunks, append([]byte(nil), c.PCM...))
		rates = append(rates, c.SampleRate)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(gotPath, "/models/"+defaultSpeechModel+":streamGenerateContent") {
		t.Errorf("path = %q", gotPath)
	}
	if len(chunks) != 2 || !bytes.Equal(chunks[0], chunk1) || !bytes.Equal(chunks[1], chunk2) {
		t.Fatalf("got %d chunks, want 2 matching PCM slices", len(chunks))
	}
	if rates[0] != 24000 || rates[1] != 24000 {
		t.Fatalf("rates = %v, want [24000 24000]", rates)
	}
	wantPCM := append(append([]byte(nil), chunk1...), chunk2...)
	if len(clip.Data) != 44+len(wantPCM) || !bytes.Equal(clip.Data[44:], wantPCM) || clip.DurationMS != 500 {
		t.Fatalf("clip = %d bytes, %dms; want %d bytes, 500ms", len(clip.Data), clip.DurationMS, 44+len(wantPCM))
	}
}

// quotaBody is a Gemini API 429 as AI Studio returns it, with the quota that
// ran out in a QuotaFailure and the suggested wait in a RetryInfo.
func quotaBody(quotaID, retryDelay string) string {
	return `{"error":{"code":429,"message":"You exceeded your current quota, please check your plan and billing details.","status":"RESOURCE_EXHAUSTED","details":[` +
		`{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaMetric":"generativelanguage.googleapis.com/generate_content_free_tier_requests","quotaId":"` + quotaID + `","quotaDimensions":{"location":"global","model":"gemini-3.8-flash-tts"},"quotaValue":"100"}]},` +
		`{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"` + retryDelay + `"}]}}`
}

func TestSpeechQuotaErrorsNameTheLimit(t *testing.T) {
	for _, tc := range []struct {
		name, quotaID string
		kind          media.ErrorKind
		say           string
		minWait       time.Duration
		maxWait       time.Duration
	}{
		// The free tier's daily cap: Gemini suggests a retry in seconds, but
		// nothing succeeds until the day resets at midnight Pacific.
		{"daily", "GenerateRequestsPerDayPerProjectPerModel-FreeTier", media.ErrKindQuota, "daily limit of 100", 0, 24*time.Hour + time.Second},
		{"per minute", "GenerateRequestsPerMinutePerProjectPerModel-FreeTier", media.ErrKindRateLimit, "try again in 37s", 37 * time.Second, 37 * time.Second},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(http.StatusTooManyRequests)
				_, _ = w.Write([]byte(quotaBody(tc.quotaID, "36.2s")))
			}))
			defer ts.Close()
			prov, _ := New(media.ResolvedConfig{Settings: map[string]string{"backend": "gemini_api"}, Secrets: map[string]string{"api_key": "k"}}, WithBaseURL(ts.URL))
			for name, call := range map[string]func() error{
				"generate": func() error {
					_, err := prov.GenerateSpeech(context.Background(), media.SpeechRequest{Text: "Hello."})
					return err
				},
				"stream": func() error {
					_, err := prov.StreamSpeech(context.Background(), media.SpeechRequest{Text: "Hello."}, nil)
					return err
				},
			} {
				var pe *media.ProviderError
				if err := call(); !errors.As(err, &pe) {
					t.Fatalf("%s: err = %v, want a ProviderError", name, err)
				}
				if pe.Kind != tc.kind || !strings.Contains(pe.Message, tc.say) {
					t.Errorf("%s: kind %q, message %q; want %q saying %q", name, pe.Kind, pe.Message, tc.kind, tc.say)
				}
				if pe.RetryAfter <= tc.minWait-time.Second || pe.RetryAfter > tc.maxWait {
					t.Errorf("%s: RetryAfter = %v, want within (%v, %v]", name, pe.RetryAfter, tc.minWait-time.Second, tc.maxWait)
				}
			}
		})
	}
}

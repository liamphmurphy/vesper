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

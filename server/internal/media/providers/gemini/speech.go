package gemini

import (
	"context"
	"fmt"
	"mime"
	"strconv"
	"strings"

	"google.golang.org/genai"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/speech"
)

const (
	defaultSpeechModel = "gemini-3.8-flash-tts"
	liteSpeechModel    = "gemini-3.8-flash-lite-tts"
	// DefaultVoice is spoken when a persona hasn't picked one.
	DefaultVoice = "Kore"
	// Gemini TTS returns 16-bit mono PCM at this rate unless the MIME type says otherwise.
	defaultPCMRate = 24000
	// maxSpeechChars bounds what one request may speak (the clients cap replies far lower).
	maxSpeechChars = 4000
)

// voices are Gemini's prebuilt TTS voices and the tone Google describes for each.
var voices = []media.Voice{
	{Name: "Zephyr", Tone: "Bright"}, {Name: "Puck", Tone: "Upbeat"}, {Name: "Charon", Tone: "Informative"},
	{Name: "Kore", Tone: "Firm"}, {Name: "Fenrir", Tone: "Excitable"}, {Name: "Leda", Tone: "Youthful"},
	{Name: "Orus", Tone: "Firm"}, {Name: "Aoede", Tone: "Breezy"}, {Name: "Callirrhoe", Tone: "Easy-going"},
	{Name: "Autonoe", Tone: "Bright"}, {Name: "Enceladus", Tone: "Breathy"}, {Name: "Iapetus", Tone: "Clear"},
	{Name: "Umbriel", Tone: "Easy-going"}, {Name: "Algieba", Tone: "Smooth"}, {Name: "Despina", Tone: "Smooth"},
	{Name: "Erinome", Tone: "Clear"}, {Name: "Algenib", Tone: "Gravelly"}, {Name: "Rasalgethi", Tone: "Informative"},
	{Name: "Laomedeia", Tone: "Upbeat"}, {Name: "Achernar", Tone: "Soft"}, {Name: "Alnilam", Tone: "Firm"},
	{Name: "Schedar", Tone: "Even"}, {Name: "Gacrux", Tone: "Mature"}, {Name: "Pulcherrima", Tone: "Forward"},
	{Name: "Achird", Tone: "Friendly"}, {Name: "Zubenelgenubi", Tone: "Casual"}, {Name: "Vindemiatrix", Tone: "Gentle"},
	{Name: "Sadachbia", Tone: "Lively"}, {Name: "Sadaltager", Tone: "Knowledgeable"}, {Name: "Sulafat", Tone: "Warm"},
}

var (
	_ media.SpeechGenerator          = (*Provider)(nil)
	_ media.StreamingSpeechGenerator = (*Provider)(nil)
)

// DefaultVoice is the voice for a persona that hasn't picked one.
func (p *Provider) DefaultVoice() string { return DefaultVoice }

// Voices lists Gemini's prebuilt voices.
func (p *Provider) Voices() []media.Voice { return append([]media.Voice(nil), voices...) }

func (p *Provider) prepareSpeech(req media.SpeechRequest) (model string, contents []*genai.Content, cfg *genai.GenerateContentConfig, err error) {
	text := strings.TrimSpace(req.Text)
	if text == "" || len(text) > maxSpeechChars {
		return "", nil, nil, &media.ProviderError{Provider: ProviderID, Kind: media.ErrKindUnknown, Message: fmt.Sprintf("Speech text must be 1–%d characters.", maxSpeechChars)}
	}
	voice := strings.TrimSpace(req.Voice)
	if voice == "" {
		voice = DefaultVoice
	}
	model = strings.TrimSpace(req.Model)
	if model == "" {
		model = p.cfg.Setting(p.desc, "tts_model")
	}
	if model == "" {
		model = defaultSpeechModel
	}
	// Gemini 3.8 TTS speaks its text word for word, so a style written into
	// the text is read aloud; it goes in the part's speech metadata instead.
	part := &genai.Part{Text: text}
	if style := strings.TrimSpace(req.Style); style != "" {
		part.SpeechMetadata = &genai.SpeechMetadata{Style: style}
	}
	contents = []*genai.Content{genai.NewContentFromParts([]*genai.Part{part}, genai.RoleUser)}
	cfg = &genai.GenerateContentConfig{
		ResponseModalities: []string{"AUDIO"},
		SpeechConfig: &genai.SpeechConfig{
			VoiceConfig: &genai.VoiceConfig{PrebuiltVoiceConfig: &genai.PrebuiltVoiceConfig{VoiceName: voice}},
		},
	}
	return model, contents, cfg, nil
}

// GenerateSpeech speaks req.Text with a prebuilt voice. The style rides in the
// part's speech metadata, which Gemini TTS follows, and the PCM it returns is
// wrapped as WAV so every client can play it without a decoder.
func (p *Provider) GenerateSpeech(ctx context.Context, req media.SpeechRequest) (media.SpeechClip, error) {
	model, contents, cfg, err := p.prepareSpeech(req)
	if err != nil {
		return media.SpeechClip{}, err
	}
	client, err := p.newClient(ctx)
	if err != nil {
		return media.SpeechClip{}, err
	}
	resp, err := client.Models.GenerateContent(ctx, model, contents, cfg)
	if err != nil {
		return media.SpeechClip{}, p.mapError(err)
	}
	pcm, rate, err := speechPCM(resp)
	if err != nil {
		return media.SpeechClip{}, err
	}
	return media.SpeechClip{
		Data:        speech.WAVFromPCM(pcm, rate),
		ContentType: "audio/wav",
		DurationMS:  len(pcm) * 1000 / (rate * 2),
		Model:       model,
	}, nil
}

// StreamSpeech synthesizes req.Text via Gemini's streaming endpoint, invoking
// onChunk with each 16-bit mono PCM chunk as it arrives and returning the
// complete WAV clip for caching once the stream completes.
func (p *Provider) StreamSpeech(ctx context.Context, req media.SpeechRequest, onChunk func(media.SpeechChunk) error) (media.SpeechClip, error) {
	model, contents, cfg, err := p.prepareSpeech(req)
	if err != nil {
		return media.SpeechClip{}, err
	}
	client, err := p.newClient(ctx)
	if err != nil {
		return media.SpeechClip{}, err
	}
	var fullPCM []byte
	sampleRate := defaultPCMRate
	for resp, err := range client.Models.GenerateContentStream(ctx, model, contents, cfg) {
		if err != nil {
			return media.SpeechClip{}, p.mapError(err)
		}
		pcm, rate, ok := extractSpeechPCM(resp)
		if !ok || len(pcm) == 0 {
			continue
		}
		if rate > 0 {
			sampleRate = rate
		}
		fullPCM = append(fullPCM, pcm...)
		if onChunk != nil {
			if err := onChunk(media.SpeechChunk{PCM: pcm, SampleRate: sampleRate}); err != nil {
				return media.SpeechClip{}, err
			}
		}
	}
	if len(fullPCM) == 0 {
		return media.SpeechClip{}, &media.ProviderError{Provider: ProviderID, Kind: media.ErrKindFiltered, Message: "Gemini returned no speech for this text."}
	}
	return media.SpeechClip{
		Data:        speech.WAVFromPCM(fullPCM, sampleRate),
		ContentType: "audio/wav",
		DurationMS:  len(fullPCM) * 1000 / (sampleRate * 2),
		Model:       model,
	}, nil
}

// speechPCM pulls the audio part out of a response, with its sample rate.
func speechPCM(resp *genai.GenerateContentResponse) ([]byte, int, error) {
	if pcm, rate, ok := extractSpeechPCM(resp); ok {
		return pcm, rate, nil
	}
	return nil, 0, &media.ProviderError{Provider: ProviderID, Kind: media.ErrKindFiltered, Message: "Gemini returned no speech for this text."}
}

// extractSpeechPCM extracts all audio parts from a single GenerateContentResponse.
func extractSpeechPCM(resp *genai.GenerateContentResponse) ([]byte, int, bool) {
	if resp == nil {
		return nil, 0, false
	}
	var out []byte
	rate := defaultPCMRate
	found := false
	for _, c := range resp.Candidates {
		if c == nil || c.Content == nil {
			continue
		}
		for _, part := range c.Content.Parts {
			if part == nil || part.InlineData == nil || len(part.InlineData.Data) == 0 {
				continue
			}
			if !strings.HasPrefix(strings.ToLower(part.InlineData.MIMEType), "audio/") {
				continue
			}
			data := part.InlineData.Data
			// 3.8 TTS returns a whole WAV file with a provenance (C2PA) chunk after
			// the audio; only its data chunk is sound. Older models send bare PCM.
			if pcm, r, ok := speech.WAVData(data); ok {
				out = append(out, pcm...)
				rate = r
			} else {
				out = append(out, data...)
				rate = pcmRate(part.InlineData.MIMEType)
			}
			found = true
		}
	}
	return out, rate, found
}

// pcmRate reads rate=N from a MIME type like audio/L16;codec=pcm;rate=24000.
func pcmRate(mt string) int {
	if _, params, err := mime.ParseMediaType(mt); err == nil {
		if r, err := strconv.Atoi(params["rate"]); err == nil && r > 0 {
			return r
		}
	}
	return defaultPCMRate
}

// wavFromPCM is kept as a package alias for tests.
func wavFromPCM(pcm []byte, rate int) []byte { return speech.WAVFromPCM(pcm, rate) }

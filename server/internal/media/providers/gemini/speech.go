package gemini

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
	"mime"
	"strconv"
	"strings"

	"google.golang.org/genai"

	"github.com/liamphmurphy/vesper/server/internal/media"
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

var _ media.SpeechGenerator = (*Provider)(nil)

// DefaultVoice is the voice for a persona that hasn't picked one.
func (p *Provider) DefaultVoice() string { return DefaultVoice }

// Voices lists Gemini's prebuilt voices.
func (p *Provider) Voices() []media.Voice { return append([]media.Voice(nil), voices...) }

// GenerateSpeech speaks req.Text with a prebuilt voice. The style rides in the
// prompt as a delivery direction, which Gemini TTS follows, and the PCM it
// returns is wrapped as WAV so every client can play it without a decoder.
func (p *Provider) GenerateSpeech(ctx context.Context, req media.SpeechRequest) (media.SpeechClip, error) {
	text := strings.TrimSpace(req.Text)
	if text == "" || len(text) > maxSpeechChars {
		return media.SpeechClip{}, &media.ProviderError{Provider: ProviderID, Kind: media.ErrKindUnknown, Message: fmt.Sprintf("Speech text must be 1–%d characters.", maxSpeechChars)}
	}
	voice := strings.TrimSpace(req.Voice)
	if voice == "" {
		voice = DefaultVoice
	}
	model := strings.TrimSpace(req.Model)
	if model == "" {
		model = p.cfg.Setting(p.desc, "tts_model")
	}
	if model == "" {
		model = defaultSpeechModel
	}
	prompt := text
	if style := strings.TrimSpace(req.Style); style != "" {
		prompt = "Read the following aloud in a " + style + " way:\n\n" + text
	}

	client, err := p.newClient(ctx)
	if err != nil {
		return media.SpeechClip{}, err
	}
	resp, err := client.Models.GenerateContent(ctx, model, genai.Text(prompt), &genai.GenerateContentConfig{
		ResponseModalities: []string{"AUDIO"},
		SpeechConfig: &genai.SpeechConfig{
			VoiceConfig: &genai.VoiceConfig{PrebuiltVoiceConfig: &genai.PrebuiltVoiceConfig{VoiceName: voice}},
		},
	})
	if err != nil {
		return media.SpeechClip{}, p.mapError(err)
	}
	pcm, rate, err := speechPCM(resp)
	if err != nil {
		return media.SpeechClip{}, err
	}
	wav := wavFromPCM(pcm, rate)
	return media.SpeechClip{
		Data:        wav,
		ContentType: "audio/wav",
		DurationMS:  len(pcm) * 1000 / (rate * 2),
		Model:       model,
	}, nil
}

// speechPCM pulls the audio part out of a response, with its sample rate.
func speechPCM(resp *genai.GenerateContentResponse) ([]byte, int, error) {
	if resp != nil {
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
				return part.InlineData.Data, pcmRate(part.InlineData.MIMEType), nil
			}
		}
	}
	return nil, 0, &media.ProviderError{Provider: ProviderID, Kind: media.ErrKindFiltered, Message: "Gemini returned no speech for this text."}
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

// wavFromPCM wraps 16-bit little-endian mono PCM in a RIFF/WAVE header.
func wavFromPCM(pcm []byte, rate int) []byte {
	var b bytes.Buffer
	b.Grow(44 + len(pcm))
	w := func(v any) { _ = binary.Write(&b, binary.LittleEndian, v) }
	b.WriteString("RIFF")
	w(uint32(36 + len(pcm)))
	b.WriteString("WAVEfmt ")
	w(uint32(16))       // fmt chunk size
	w(uint16(1))        // PCM
	w(uint16(1))        // mono
	w(uint32(rate))     // sample rate
	w(uint32(rate * 2)) // byte rate
	w(uint16(2))        // block align
	w(uint16(16))       // bits per sample
	b.WriteString("data")
	w(uint32(len(pcm)))
	b.Write(pcm)
	return b.Bytes()
}

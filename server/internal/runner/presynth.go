package runner

import (
	"context"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/speech"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// preSynthesizeReply starts voicing a Live Voice turn's reply through the
// SpeechBroker as soon as it is stored, so the client's speech request (made
// once it sees the reply) joins audio already on its way. The whole reply is
// one provider request: Gemini streams PCM, so first audio arrives about as
// soon as it would for a separately voiced first sentence, and a reply spends
// one request of the provider's quota rather than two. Typed turns are left
// alone: they're voiced, if at all, when someone asks.
func (r *Runner) preSynthesizeReply(ctx context.Context, c runCtx, turn store.RunTurn, chat store.ChatSession, body string) {
	if r.SpeechBroker == nil || r.Media == nil || !turn.Spoken {
		return
	}
	speakerID := chatSpeaker(chat)
	if speakerID == nil {
		return
	}
	p, err := (&personas.Service{Pool: r.Pool}).Get(ctx, personas.Owner{WorkspaceID: c.run.WorkspaceID, UserID: chat.CreatedBy}, *speakerID)
	if err != nil || p.VoiceMode == "off" {
		return
	}
	// The same text and key the speech endpoint derives from the stored reply.
	text, words := speech.Speakable(body, speech.MaxWords)
	if words == 0 {
		return
	}
	gen, desc, err := r.Media.ResolveSpeech(ctx, c.run.WorkspaceID)
	if err != nil {
		return
	}
	req := media.SpeechRequest{Text: text, Voice: p.VoiceName, Style: p.VoiceStyle}
	r.SpeechBroker.Start(speech.CacheHash(desc.ID, p.VoiceName, p.VoiceStyle, text), func(ctx context.Context, onChunk func([]byte, int) error) ([]byte, string, error) {
		if sg, ok := gen.(media.StreamingSpeechGenerator); ok {
			clip, err := sg.StreamSpeech(ctx, req, func(ch media.SpeechChunk) error {
				return onChunk(ch.PCM, ch.SampleRate)
			})
			return clip.Data, clip.Model, err
		}
		clip, err := gen.GenerateSpeech(ctx, req)
		if err != nil {
			return nil, "", err
		}
		pcm, rate, ok := speech.WAVData(clip.Data)
		if !ok {
			pcm, rate = clip.Data, speech.DefaultPCMRate
		}
		if err := onChunk(pcm, rate); err != nil {
			return nil, "", err
		}
		return clip.Data, clip.Model, nil
	})
}

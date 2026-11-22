package runner

import (
	"context"

	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/speech"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// chatLeadPreSynthesizer watches streaming assistant text deltas on a voiced
// chat turn and starts synthesizing sentence 1 through SpeechBroker while the
// model is still writing the rest of the reply.
type chatLeadPreSynthesizer struct {
	broker   *speech.Broker
	gen      media.SpeechGenerator
	provider string
	voice    string
	style    string
	watcher  speech.LeadWatcher
}

func (r *Runner) newChatLeadPreSynthesizer(ctx context.Context, q *store.Queries, c runCtx) *chatLeadPreSynthesizer {
	if r.SpeechBroker == nil || r.Media == nil || c.run.Purpose != "chat" {
		return nil
	}
	chat, err := q.ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		return nil
	}
	speakerID := chatSpeaker(chat)
	if speakerID == nil {
		return nil
	}
	p, err := (&personas.Service{Pool: r.Pool}).Get(ctx, personas.Owner{WorkspaceID: c.run.WorkspaceID, UserID: chat.CreatedBy}, *speakerID)
	if err != nil || p.VoiceMode == "off" {
		return nil
	}
	gen, desc, err := r.Media.ResolveSpeech(ctx, c.run.WorkspaceID)
	if err != nil {
		return nil
	}
	return &chatLeadPreSynthesizer{
		broker:   r.SpeechBroker,
		gen:      gen,
		provider: desc.ID,
		voice:    p.VoiceName,
		style:    p.VoiceStyle,
	}
}

func (p *chatLeadPreSynthesizer) onEvent(e harness.Event) {
	if p == nil {
		return
	}
	if e.Type == "tool_call" || e.Type == "tool_use" {
		p.watcher.Reset()
	}
}

func (p *chatLeadPreSynthesizer) onTextDelta(delta string) {
	if p == nil {
		return
	}
	lead, ok := p.watcher.Feed(delta)
	if !ok {
		return
	}
	hash := speech.CacheHash(p.provider, p.voice, p.style, lead)
	req := media.SpeechRequest{Text: lead, Voice: p.voice, Style: p.style}
	p.broker.Start(hash, func(ctx context.Context, onChunk func([]byte, int) error) ([]byte, string, error) {
		if sg, ok := p.gen.(media.StreamingSpeechGenerator); ok {
			clip, err := sg.StreamSpeech(ctx, req, func(ch media.SpeechChunk) error {
				return onChunk(ch.PCM, ch.SampleRate)
			})
			return clip.Data, clip.Model, err
		}
		clip, err := p.gen.GenerateSpeech(ctx, req)
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

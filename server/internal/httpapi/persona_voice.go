package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/speech"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Persona voices: a reply's prose spoken in its persona's voice during the
// companion's talking phase. Speech is made once per reply and voice, and
// kept in the blob store, so replaying it costs nothing.

const (
	speechTimeout = 90 * time.Second
	// maxSpeechBytes bounds a cached clip read back (~120 words of 24 kHz WAV is ~2-3 MB).
	maxSpeechBytes = 16 << 20
)

func toPersonaVoice(p store.Persona) api.PersonaVoice {
	return api.PersonaVoice{Mode: api.PersonaVoiceMode(p.VoiceMode), Name: p.VoiceName, Style: p.VoiceStyle}
}

// resolveSpeech is the workspace's speech provider, or a 409 naming what to set up.
func (s *Server) resolveSpeech(ctx context.Context) (media.SpeechGenerator, media.Descriptor, error) {
	_, _, ws := me(ctx)
	gen, desc, err := s.mediaService().ResolveSpeech(ctx, ws)
	var pe *media.ProviderError
	if errors.As(err, &pe) {
		return nil, desc, apperr.Conflict("%s", pe.Message)
	}
	return gen, desc, err
}

func (s *Server) ListPersonaVoices(ctx context.Context, _ api.ListPersonaVoicesRequestObject) (api.ListPersonaVoicesResponseObject, error) {
	gen, _, err := s.resolveSpeech(ctx)
	if err != nil {
		var ae *apperr.ConflictError
		if errors.As(err, &ae) {
			reason := ae.Error()
			return api.ListPersonaVoices200JSONResponse{Available: false, Reason: &reason, Voices: []struct {
				Name string `json:"name"`
				Tone string `json:"tone"`
			}{}}, nil
		}
		return nil, err
	}
	out := api.ListPersonaVoices200JSONResponse{Available: true}
	def := gen.DefaultVoice()
	out.DefaultVoice = &def
	for _, v := range gen.Voices() {
		out.Voices = append(out.Voices, struct {
			Name string `json:"name"`
			Tone string `json:"tone"`
		}{Name: v.Name, Tone: v.Tone})
	}
	return out, nil
}

func (s *Server) PreviewPersonaVoice(ctx context.Context, req api.PreviewPersonaVoiceRequestObject) (api.PreviewPersonaVoiceResponseObject, error) {
	p, err := s.personas().Get(ctx, personaOwner(ctx), req.Id)
	if err != nil {
		return nil, err
	}
	voice, style := p.VoiceName, p.VoiceStyle
	if b := req.Body; b != nil {
		if b.VoiceName != nil {
			voice = *b.VoiceName
		}
		if b.VoiceStyle != nil {
			style = *b.VoiceStyle
		}
	}
	gen, _, err := s.resolveSpeech(ctx)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, speechTimeout)
	defer cancel()
	clip, err := gen.GenerateSpeech(ctx, media.SpeechRequest{
		Text:  "Hi, I'm " + p.Name + ". This is how I'll sound when I talk you through things.",
		Voice: voice, Style: style,
	})
	if err != nil {
		return nil, speechError(err)
	}
	return api.PreviewPersonaVoice200AudiowavResponse{Body: bytes.NewReader(clip.Data), ContentLength: int64(len(clip.Data))}, nil
}

func (s *Server) GetChatMessageSpeech(ctx context.Context, req api.GetChatMessageSpeechRequestObject) (api.GetChatMessageSpeechResponseObject, error) {
	c, err := s.ownChat(ctx, req.Id)
	if err != nil {
		return nil, err
	}
	msg, err := s.Q.GetChatMessageByID(ctx, store.GetChatMessageByIDParams{ID: req.MessageId, SessionID: c.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if msg.Role != "assistant" {
		return nil, apperr.Invalid("messageId", "only replies are spoken")
	}
	// The reply's author speaks, else the chat's host.
	personaID := msg.PersonaID
	if personaID == nil {
		personaID = c.PersonaID
	}
	if personaID == nil {
		return nil, apperr.Conflict("The built-in Assistant has no voice. Give a persona one in Settings → Personas.")
	}
	p, err := s.personas().Get(ctx, personaOwner(ctx), *personaID)
	if errors.Is(err, apperr.ErrNotFound) {
		return nil, apperr.Conflict("This reply's persona was deleted, so it has no voice.")
	} else if err != nil {
		return nil, err
	}
	if p.VoiceMode == "off" {
		return nil, apperr.Conflict("%s's voice is off. Turn it on in Settings → Personas.", p.Name)
	}
	text, words := speech.Speakable(msg.BodyMd, speech.MaxWords)
	if words == 0 {
		return nil, apperr.Invalid("messageId", "this reply has no prose to speak")
	}
	if s.Blobs == nil {
		return nil, errNoBlobs
	}
	gen, desc, err := s.resolveSpeech(ctx)
	if err != nil {
		return nil, err
	}
	// The key covers everything that changes the audio, so a new voice or
	// style speaks afresh while a replay is served from storage.
	sum := sha256.Sum256([]byte(desc.ID + "\x00" + p.VoiceName + "\x00" + p.VoiceStyle + "\x00" + text))
	key := "speech/" + c.ID.String() + "/" + msg.ID.String() + "/" + hex.EncodeToString(sum[:12]) + ".wav"
	cache := "private, max-age=604800"
	if obj, err := s.Blobs.Get(ctx, s.ArtifactBucket, key); err == nil {
		defer obj.Body.Close()
		b, err := io.ReadAll(io.LimitReader(obj.Body, maxSpeechBytes))
		if err != nil {
			return nil, err
		}
		return speechResponse(b, words, cache), nil
	} else if !errors.Is(err, blob.ErrNotFound) {
		return nil, err
	}
	genCtx, cancel := context.WithTimeout(ctx, speechTimeout)
	defer cancel()
	clip, err := gen.GenerateSpeech(genCtx, media.SpeechRequest{Text: text, Voice: p.VoiceName, Style: p.VoiceStyle})
	if err != nil {
		return nil, speechError(err)
	}
	// A failed cache write only means the next replay speaks again.
	if err := s.Blobs.Put(context.WithoutCancel(ctx), s.ArtifactBucket, key, bytes.NewReader(clip.Data), int64(len(clip.Data)), clip.ContentType); err != nil {
		s.Log.Warn("cache reply speech", "key", key, "err", err)
	}
	return speechResponse(clip.Data, words, cache), nil
}

func speechResponse(b []byte, words int, cache string) api.GetChatMessageSpeech200AudiowavResponse {
	return api.GetChatMessageSpeech200AudiowavResponse{
		Body:          bytes.NewReader(b),
		ContentLength: int64(len(b)),
		Headers:       api.GetChatMessageSpeech200ResponseHeaders{XSpeechWords: &words, CacheControl: &cache},
	}
}

// speechError turns a provider failure into a 409 the clients can show.
func speechError(err error) error {
	var pe *media.ProviderError
	if errors.As(err, &pe) {
		return apperr.Conflict("%s", pe.Message)
	}
	return err
}

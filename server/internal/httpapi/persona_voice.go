package httpapi

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
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

type resolvedChatSpeech struct {
	chatID    uuid.UUID
	messageID uuid.UUID
	partLabel string
	text      string
	words     int
	voice     string
	style     string
	hash      string
	key       string
	gen       media.SpeechGenerator
}

func (s *Server) resolveChatSpeech(ctx context.Context, chatID, messageID uuid.UUID, part *api.GetChatMessageSpeechParamsPart) (resolvedChatSpeech, error) {
	c, err := s.ownChat(ctx, chatID)
	if err != nil {
		return resolvedChatSpeech{}, err
	}
	msg, err := s.Q.GetChatMessageByID(ctx, store.GetChatMessageByIDParams{ID: messageID, SessionID: c.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return resolvedChatSpeech{}, apperr.ErrNotFound
	} else if err != nil {
		return resolvedChatSpeech{}, err
	}
	if msg.Role != "assistant" {
		return resolvedChatSpeech{}, apperr.Invalid("messageId", "only replies are spoken")
	}
	// The reply's author speaks, else the chat's host.
	personaID := msg.PersonaID
	if personaID == nil {
		personaID = c.PersonaID
	}
	if personaID == nil {
		return resolvedChatSpeech{}, apperr.Conflict("The built-in Assistant has no voice. Give a persona one in Settings → Personas.")
	}
	p, err := s.personas().Get(ctx, personaOwner(ctx), *personaID)
	if errors.Is(err, apperr.ErrNotFound) {
		return resolvedChatSpeech{}, apperr.Conflict("This reply's persona was deleted, so it has no voice.")
	} else if err != nil {
		return resolvedChatSpeech{}, err
	}
	if p.VoiceMode == "off" {
		return resolvedChatSpeech{}, apperr.Conflict("%s's voice is off. Turn it on in Settings → Personas.", p.Name)
	}
	text, words := speech.Speakable(msg.BodyMd, speech.MaxWords)
	partLabel := "full"
	// A part lets the client play the lead while the rest is still being voiced.
	if part != nil {
		if !part.Valid() {
			return resolvedChatSpeech{}, apperr.Invalid("part", "part is lead or rest")
		}
		partLabel = string(*part)
		lead, rest := speech.SplitLead(text)
		text = lead
		if *part == api.Rest {
			text = rest
		}
		words = len(strings.Fields(text))
		if words == 0 {
			return resolvedChatSpeech{}, apperr.Invalid("part", "this part of the reply has nothing to speak")
		}
	}
	if words == 0 {
		return resolvedChatSpeech{}, apperr.Invalid("messageId", "this reply has no prose to speak")
	}
	if s.Blobs == nil {
		return resolvedChatSpeech{}, errNoBlobs
	}
	gen, desc, err := s.resolveSpeech(ctx)
	if err != nil {
		return resolvedChatSpeech{}, err
	}
	// The key covers everything that changes the audio, so a new voice or
	// style speaks afresh while a replay is served from storage. Bump
	// speech.CacheVersion when the audio itself changes for the same inputs.
	hash := speech.CacheHash(desc.ID, p.VoiceName, p.VoiceStyle, text)
	key := "speech/" + c.ID.String() + "/" + msg.ID.String() + "/" + hash + ".wav"
	return resolvedChatSpeech{
		chatID:    c.ID,
		messageID: msg.ID,
		partLabel: partLabel,
		text:      text,
		words:     words,
		voice:     p.VoiceName,
		style:     p.VoiceStyle,
		hash:      hash,
		key:       key,
		gen:       gen,
	}, nil
}

func (s *Server) speechRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/chats/{id}/messages/{messageId}/speech/stream", s.streamChatMessageSpeech)
}

func (s *Server) streamChatMessageSpeech(w http.ResponseWriter, r *http.Request) {
	chatID, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		s.responseError(w, r, apperr.Invalid("id", "invalid chat id"))
		return
	}
	messageID, err := uuid.Parse(r.PathValue("messageId"))
	if err != nil {
		s.responseError(w, r, apperr.Invalid("messageId", "invalid message id"))
		return
	}
	var part *api.GetChatMessageSpeechParamsPart
	if rawPart := strings.TrimSpace(r.URL.Query().Get("part")); rawPart != "" {
		p := api.GetChatMessageSpeechParamsPart(rawPart)
		part = &p
	}
	res, err := s.resolveChatSpeech(r.Context(), chatID, messageID, part)
	if err != nil {
		s.responseError(w, r, err)
		return
	}

	const cacheHeader = "private, max-age=604800"
	start := time.Now()
	rc := http.NewResponseController(w)
	writeStreamHeaders := func(sampleRate int) {
		if sampleRate <= 0 {
			sampleRate = speech.DefaultPCMRate
		}
		w.Header().Set("Content-Type", fmt.Sprintf("audio/L16; rate=%d; channels=1", sampleRate))
		w.Header().Set("X-Speech-Words", strconv.Itoa(res.words))
		w.Header().Set("X-Speech-Sample-Rate", strconv.Itoa(sampleRate))
		w.Header().Set("Cache-Control", cacheHeader)
		w.WriteHeader(http.StatusOK)
	}

	if obj, err := s.Blobs.Get(r.Context(), s.ArtifactBucket, res.key); err == nil {
		defer obj.Body.Close()
		b, err := io.ReadAll(io.LimitReader(obj.Body, maxSpeechBytes))
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		pcm, rate, ok := speech.WAVData(b)
		if !ok {
			pcm, rate = b, speech.DefaultPCMRate
		}
		writeStreamHeaders(rate)
		_, _ = w.Write(pcm)
		_ = rc.Flush()
		if s.Log != nil {
			s.Log.Info("speech_timing", "chat_id", res.chatID, "message_id", res.messageID, "part", res.partLabel, "streaming", true, "cached", true, "first_byte_ms", time.Since(start).Milliseconds(), "tts_ms", time.Since(start).Milliseconds(), "words", res.words)
		}
		return
	} else if !errors.Is(err, blob.ErrNotFound) {
		s.responseError(w, r, err)
		return
	}

	genCtx, cancel := context.WithTimeout(r.Context(), speechTimeout)
	defer cancel()
	speechReq := media.SpeechRequest{Text: res.text, Voice: res.voice, Style: res.style}

	var clip media.SpeechClip
	headersSent := false
	firstByteMS := int64(-1)
	presynthHit := false
	writeChunk := func(pcm []byte, rate int) error {
		if len(pcm) == 0 {
			return nil
		}
		if !headersSent {
			headersSent = true
			firstByteMS = time.Since(start).Milliseconds()
			writeStreamHeaders(rate)
		}
		if _, werr := w.Write(pcm); werr != nil {
			return werr
		}
		_ = rc.Flush()
		return nil
	}

	if s.SpeechBroker != nil {
		if hit, wav, model, berr := s.SpeechBroker.Subscribe(genCtx, res.hash, writeChunk); hit {
			if berr == nil {
				presynthHit = true
				clip = media.SpeechClip{Data: wav, ContentType: "audio/wav", Model: model}
			} else if headersSent {
				if s.Log != nil {
					s.Log.Warn("stream pre-synthesized speech interrupted", "chat_id", res.chatID, "message_id", res.messageID, "err", berr)
				}
				return
			}
		}
	}

	if !presynthHit {
		if sg, ok := res.gen.(media.StreamingSpeechGenerator); ok {
			clip, err = sg.StreamSpeech(genCtx, speechReq, func(chunk media.SpeechChunk) error {
				return writeChunk(chunk.PCM, chunk.SampleRate)
			})
		} else {
			clip, err = res.gen.GenerateSpeech(genCtx, speechReq)
			if err == nil {
				pcm, rate, ok := speech.WAVData(clip.Data)
				if !ok {
					pcm, rate = clip.Data, speech.DefaultPCMRate
				}
				err = writeChunk(pcm, rate)
			}
		}
		if err != nil {
			if !headersSent {
				s.writeSpeechError(w, r, err)
			} else if s.Log != nil {
				s.Log.Warn("stream reply speech interrupted", "chat_id", res.chatID, "message_id", res.messageID, "err", err)
			}
			return
		}
	}
	if s.Log != nil {
		s.Log.Info("speech_timing", "chat_id", res.chatID, "message_id", res.messageID, "part", res.partLabel, "streaming", true, "cached", false, "presynth_hit", presynthHit, "first_byte_ms", firstByteMS, "tts_ms", time.Since(start).Milliseconds(), "words", res.words, "model", clip.Model)
	}
	if len(clip.Data) > 0 {
		if err := s.Blobs.Put(context.WithoutCancel(r.Context()), s.ArtifactBucket, res.key, bytes.NewReader(clip.Data), int64(len(clip.Data)), clip.ContentType); err != nil && s.Log != nil {
			s.Log.Warn("cache reply speech", "key", res.key, "err", err)
		}
	}
}

func (s *Server) GetChatMessageSpeech(ctx context.Context, req api.GetChatMessageSpeechRequestObject) (api.GetChatMessageSpeechResponseObject, error) {
	res, err := s.resolveChatSpeech(ctx, req.Id, req.MessageId, req.Params.Part)
	if err != nil {
		return nil, err
	}
	cache := "private, max-age=604800"
	start := time.Now()
	if obj, err := s.Blobs.Get(ctx, s.ArtifactBucket, res.key); err == nil {
		defer obj.Body.Close()
		b, err := io.ReadAll(io.LimitReader(obj.Body, maxSpeechBytes))
		if err != nil {
			return nil, err
		}
		if s.Log != nil {
			s.Log.Info("speech_timing", "chat_id", res.chatID, "message_id", res.messageID, "part", res.partLabel, "streaming", false, "cached", true, "tts_ms", time.Since(start).Milliseconds(), "words", res.words)
		}
		return speechResponse(b, res.words, cache), nil
	} else if !errors.Is(err, blob.ErrNotFound) {
		return nil, err
	}
	genCtx, cancel := context.WithTimeout(ctx, speechTimeout)
	defer cancel()
	var clip media.SpeechClip
	presynthHit := false
	if s.SpeechBroker != nil {
		if hit, wav, model, berr := s.SpeechBroker.Subscribe(genCtx, res.hash, nil); hit && berr == nil && len(wav) > 0 {
			presynthHit = true
			clip = media.SpeechClip{Data: wav, ContentType: "audio/wav", Model: model}
		}
	}
	if !presynthHit {
		clip, err = res.gen.GenerateSpeech(genCtx, media.SpeechRequest{Text: res.text, Voice: res.voice, Style: res.style})
		if err != nil {
			return nil, speechError(err)
		}
	}
	if s.Log != nil {
		s.Log.Info("speech_timing", "chat_id", res.chatID, "message_id", res.messageID, "part", res.partLabel, "streaming", false, "cached", false, "presynth_hit", presynthHit, "tts_ms", time.Since(start).Milliseconds(), "words", res.words, "model", clip.Model)
	}
	// A failed cache write only means the next replay speaks again.
	if err := s.Blobs.Put(context.WithoutCancel(ctx), s.ArtifactBucket, res.key, bytes.NewReader(clip.Data), int64(len(clip.Data)), clip.ContentType); err != nil {
		s.Log.Warn("cache reply speech", "key", res.key, "err", err)
	}
	return speechResponse(clip.Data, res.words, cache), nil
}

func speechResponse(b []byte, words int, cache string) api.GetChatMessageSpeech200AudiowavResponse {
	return api.GetChatMessageSpeech200AudiowavResponse{
		Body:          bytes.NewReader(b),
		ContentLength: int64(len(b)),
		Headers:       api.GetChatMessageSpeech200ResponseHeaders{XSpeechWords: &words, CacheControl: &cache},
	}
}

// writeSpeechError answers a quota or rate-limit refusal with 429 and when to
// retry, so a client can tell "out of voice for now" from a reply that can't be
// spoken and use another voice meanwhile. Other failures go through speechError.
func (s *Server) writeSpeechError(w http.ResponseWriter, r *http.Request, err error) {
	var pe *media.ProviderError
	if errors.As(err, &pe) && (pe.Kind == media.ErrKindQuota || pe.Kind == media.ErrKindRateLimit) {
		if pe.RetryAfter > 0 {
			w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(pe.RetryAfter.Seconds()))))
		}
		writeError(w, http.StatusTooManyRequests, api.Conflict, pe.Message, "")
		return
	}
	s.responseError(w, r, speechError(err))
}

// speechError turns a provider failure into a 409 the clients can show.
func speechError(err error) error {
	var pe *media.ProviderError
	if errors.As(err, &pe) {
		return apperr.Conflict("%s", pe.Message)
	}
	return err
}

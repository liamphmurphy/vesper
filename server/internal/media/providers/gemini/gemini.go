// Package gemini implements Vesper's media.ImageGenerator,
// media.MusicGenerator, media.VideoGenerator, and media.SpeechGenerator
// adapters backed by Google's official google.golang.org/genai SDK.
package gemini

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"google.golang.org/genai"
	"google.golang.org/genai/interactions/models/apierrors"
	"google.golang.org/genai/interactions/models/components"
	"google.golang.org/genai/interactions/models/interactions"
	"google.golang.org/genai/interactions/models/operations"
	"google.golang.org/genai/interactions/retry"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/runs"
)

const (
	ProviderID         = "gemini"
	geminiAPIVersion   = "v1beta"
	defaultPollEvery   = 2 * time.Second
	defaultVertexLoc   = "us-central1"
	modelAuto          = "auto"
	backendGeminiAPI   = "gemini_api"
	backendVertexAI    = "vertex_ai"
	maxClipPayloadSize = runs.MaxChatAttachmentBytes
)

// Option overrides transport or polling defaults for tests.
type Option func(*options)

type options struct {
	baseURL      string
	httpClient   *http.Client
	pollInterval time.Duration
}

// WithBaseURL overrides the Gemini/Interactions endpoint URL (for tests).
func WithBaseURL(rawURL string) Option {
	return func(o *options) { o.baseURL = strings.TrimSpace(rawURL) }
}

// WithHTTPClient overrides the underlying HTTP client (for tests).
func WithHTTPClient(hc *http.Client) Option {
	return func(o *options) { o.httpClient = hc }
}

// WithPollInterval overrides how often background interactions are polled.
func WithPollInterval(d time.Duration) Option {
	return func(o *options) {
		if d > 0 {
			o.pollInterval = d
		}
	}
}

// Descriptor returns Gemini's provider metadata and Settings field schema.
func Descriptor() media.Descriptor {
	return media.Descriptor{
		ID:           ProviderID,
		Label:        "Gemini (Nano Banana, Lyria, Omni & TTS)",
		Description:  "Nano Banana images, Lyria 3 music, Gemini Omni video and Gemini TTS persona voices via Google AI Studio API key or GCP Vertex AI.",
		Capabilities: []media.Capability{media.CapImage, media.CapMusic, media.CapVideo, media.CapTTS},
		Fields: []media.FieldSpec{
			{
				Key:     "backend",
				Label:   "Backend",
				Kind:    "segmented",
				Default: backendGeminiAPI,
				Help:    "Use AI Studio API key (applies GCP credits) or Vertex AI billing",
				Options: []media.FieldOption{
					{Value: backendGeminiAPI, Label: "Gemini API"},
					{Value: backendVertexAI, Label: "Vertex AI"},
				},
			},
			{
				Key:         "api_key",
				Label:       "API Key",
				Kind:        "secret",
				Required:    true,
				Placeholder: "AIza...",
				ShowWhen:    map[string]string{"backend": backendGeminiAPI},
			},
			{
				Key:         "project",
				Label:       "GCP Project ID",
				Kind:        "text",
				Required:    true,
				Placeholder: "my-gcp-project",
				ShowWhen:    map[string]string{"backend": backendVertexAI},
			},
			{
				Key:         "location",
				Label:       "GCP Location",
				Kind:        "text",
				Required:    true,
				Default:     defaultVertexLoc,
				Placeholder: defaultVertexLoc,
				ShowWhen:    map[string]string{"backend": backendVertexAI},
			},
			{
				Key:     "image_model",
				Label:   "Image Model",
				Kind:    "select",
				Default: defaultImageModel,
				Help:    "Used when Image engine is set to Gemini API (or Auto fallback)",
				Options: []media.FieldOption{
					{Value: string(interactions.ModelGemini3ProImage), Label: "Gemini 3 Pro Image (Nano Banana Pro — highest quality)"},
					{Value: string(interactions.ModelGemini31FlashImage), Label: "Gemini 3.1 Flash Image (Nano Banana 2 — fast & sharp)"},
					{Value: string(interactions.ModelGeminiNanoBanana21), Label: "Nano Banana 2.1 (Fast editing & consistency)"},
					{Value: string(interactions.ModelGemini31FlashLiteImage), Label: "Gemini 3.1 Flash-Lite Image (Fastest)"},
					{Value: string(interactions.ModelGemini25FlashImage), Label: "Gemini 2.5 Flash Image"},
				},
			},
			{
				Key:     "image_size",
				Label:   "Image Resolution",
				Kind:    "segmented",
				Default: defaultImageSize,
				Options: []media.FieldOption{
					{Value: "1K", Label: "1K"},
					{Value: "2K", Label: "2K"},
					{Value: "4K", Label: "4K"},
				},
			},
			{
				Key:     "model",
				Label:   "Music Model",
				Kind:    "select",
				Default: modelAuto,
				Options: []media.FieldOption{
					{Value: modelAuto, Label: "Lyria 3 (Auto: Clip for 30s, Pro for full track)"},
					{Value: string(interactions.ModelLyria3ClipPreview), Label: "Lyria 3 Clip (30s preview)"},
					{Value: string(interactions.ModelLyria3ProPreview), Label: "Lyria 3 Pro (Full track)"},
					{Value: string(interactions.ModelLyria35), Label: "Lyria 3.5 (Flagship full track)"},
				},
			},
			{
				Key:     "video_model",
				Label:   "Video Model",
				Kind:    "select",
				Default: string(interactions.ModelGeminiOmni12Flash),
				Options: []media.FieldOption{
					{Value: string(interactions.ModelGeminiOmni12Flash), Label: "Gemini Omni 1.2 Flash"},
					{Value: string(interactions.ModelGeminiOmni11Flash), Label: "Gemini Omni 1.1 Flash"},
					{Value: string(interactions.ModelGeminiOmniFlashPreview), Label: "Gemini Omni Flash (Preview)"},
				},
			},
			{
				Key:     "tts_model",
				Label:   "Voice Model",
				Kind:    "select",
				Default: defaultSpeechModel,
				Help:    "Persona voices: Flash sounds best; Flash-Lite costs about a third less",
				Options: []media.FieldOption{
					{Value: defaultSpeechModel, Label: "Gemini 3.8 Flash TTS"},
					{Value: liteSpeechModel, Label: "Gemini 3.8 Flash-Lite TTS"},
				},
			},
		},
	}
}

// Register adds the Gemini Lyria music provider to reg.
func Register(reg *media.Registry, opts ...Option) {
	if reg == nil {
		return
	}
	desc := Descriptor()
	reg.Register(media.Entry{
		Descriptor: desc,
		CheckAvailability: func(cfg media.ResolvedConfig) (bool, string) {
			switch cfg.Setting(desc, "backend") {
			case backendVertexAI:
				if strings.TrimSpace(cfg.Settings["project"]) == "" {
					return false, "Set a GCP Project ID in Settings → Workspace → Media providers."
				}
				if strings.TrimSpace(cfg.Setting(desc, "location")) == "" {
					return false, "Set a GCP Location in Settings → Workspace → Media providers."
				}
				return true, ""
			default:
				if strings.TrimSpace(cfg.Secrets["api_key"]) == "" {
					return false, "Add a Gemini API key in Settings → Workspace → Media providers."
				}
				return true, ""
			}
		},
		New: func(cfg media.ResolvedConfig) (media.Provider, error) {
			return New(cfg, opts...)
		},
	})
}

// Provider implements media.Provider, media.MusicGenerator, and
// media.VideoGenerator via google.golang.org/genai.
type Provider struct {
	desc   media.Descriptor
	cfg    media.ResolvedConfig
	opts   options
	apiKey string
}

var (
	_ media.ImageGenerator = (*Provider)(nil)
	_ media.MusicGenerator = (*Provider)(nil)
	_ media.VideoGenerator = (*Provider)(nil)
)

// New validates cfg and constructs a Gemini music provider without storing keys in logs.
func New(cfg media.ResolvedConfig, opts ...Option) (*Provider, error) {
	o := options{pollInterval: defaultPollEvery}
	for _, fn := range opts {
		if fn != nil {
			fn(&o)
		}
	}
	return &Provider{
		desc:   Descriptor(),
		cfg:    cfg,
		opts:   o,
		apiKey: strings.TrimSpace(cfg.Secrets["api_key"]),
	}, nil
}

func (p *Provider) ID() string    { return ProviderID }
func (p *Provider) Label() string { return p.desc.Label }

func (p *Provider) newClient(ctx context.Context) (*genai.Client, error) {
	cc := &genai.ClientConfig{
		HTTPClient: p.opts.httpClient,
	}
	if p.opts.baseURL != "" {
		cc.HTTPOptions = genai.HTTPOptions{BaseURL: p.opts.baseURL}
	}
	backend := p.cfg.Setting(p.desc, "backend")
	switch backend {
	case backendVertexAI:
		cc.Backend = genai.BackendVertexAI
		cc.Project = strings.TrimSpace(p.cfg.Settings["project"])
		cc.Location = strings.TrimSpace(p.cfg.Setting(p.desc, "location"))
		if cc.Project == "" || cc.Location == "" {
			return nil, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnavailable,
				Message:  "Vertex AI backend requires a GCP Project ID and Location.",
			}
		}
	default:
		if p.apiKey == "" {
			return nil, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnavailable,
				Message:  "Gemini API key is not configured.",
			}
		}
		cc.Backend = genai.BackendGeminiAPI
		cc.APIKey = p.apiKey
		// Interactions API + Lyria models require v1beta on the Gemini API backend;
		// google.golang.org/genai defaults BackendGeminiAPI to v1 when unset.
		cc.HTTPOptions.APIVersion = geminiAPIVersion
	}
	client, err := genai.NewClient(ctx, cc)
	if err != nil {
		return nil, p.mapError(err)
	}
	return client, nil
}

// Check verifies credentials and reachability without generating billable audio.
func (p *Provider) Check(ctx context.Context) error {
	client, err := p.newClient(ctx)
	if err != nil {
		return err
	}
	if _, err := client.Models.List(ctx, &genai.ListModelsConfig{PageSize: 1}); err != nil {
		return p.mapError(err)
	}
	return nil
}

// GenerateMusic calls Gemini's Lyria model via the Interactions API and polls
// if the backend returns an in-progress interaction.
func (p *Provider) GenerateMusic(ctx context.Context, req media.MusicRequest, onProgress func(media.MusicProgress)) (media.AudioClip, error) {
	if strings.TrimSpace(req.Prompt) == "" {
		return media.AudioClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "A music prompt is required.",
		}
	}
	client, err := p.newClient(ctx)
	if err != nil {
		return media.AudioClip{}, err
	}

	model := p.resolveModel(req)
	prompt := formatPrompt(req)
	if onProgress != nil {
		onProgress(media.MusicProgress{Percent: 20, Note: "Sending request to Gemini · Lyria…"})
	}

	noRetry := operations.WithRetries(retry.Config{Strategy: "none"})
	input := interactions.NewInteractionsInput(prompt)
	createReq := operations.CreateInteractionRequest{
		Body: operations.NewCreateInteractionRequestBody(interactions.CreateModelInteraction{
			Model: interactions.Model(model),
			Input: &input,
		}),
	}
	res, err := client.Interactions.Create(ctx, createReq, noRetry)
	if err != nil {
		return media.AudioClip{}, p.mapError(err)
	}
	if res == nil || res.Interaction == nil {
		return media.AudioClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini returned an empty response.",
		}
	}

	inter := res.Interaction
	progressPct := 35
	for inter.Status == interactions.InteractionStatusInProgress || inter.Status == interactions.InteractionStatusQueued {
		if inter.ID == nil || strings.TrimSpace(*inter.ID) == "" {
			return media.AudioClip{}, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnknown,
				Message:  "Gemini returned an in-progress interaction without an ID.",
			}
		}
		if onProgress != nil {
			if progressPct < 80 {
				progressPct += 10
			}
			onProgress(media.MusicProgress{Percent: progressPct, Note: "Generating with Gemini · Lyria…"})
		}
		timer := time.NewTimer(p.opts.pollInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return media.AudioClip{}, ctx.Err()
		case <-timer.C:
		}
		got, err := client.Interactions.Get(ctx, operations.GetInteractionByIDRequest{ID: *inter.ID}, noRetry)
		if err != nil {
			return media.AudioClip{}, p.mapError(err)
		}
		if got == nil || got.Interaction == nil {
			return media.AudioClip{}, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnknown,
				Message:  "Gemini returned an empty interaction poll response.",
			}
		}
		inter = got.Interaction
	}

	if inter.Status != "" && inter.Status != interactions.InteractionStatusCompleted {
		return media.AudioClip{}, p.interactionError(inter)
	}

	audio := extractAudio(inter)
	if audio == nil {
		if len(inter.Errors) > 0 {
			return media.AudioClip{}, p.interactionError(inter)
		}
		return media.AudioClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini completed without returning any audio data.",
		}
	}

	if audio.Data == nil || strings.TrimSpace(*audio.Data) == "" {
		if audio.URI != nil && *audio.URI != "" {
			return media.AudioClip{}, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnknown,
				Message:  "Gemini returned an external audio URI without inline audio bytes.",
			}
		}
		return media.AudioClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini returned an empty audio block.",
		}
	}

	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(*audio.Data))
	if err != nil {
		return media.AudioClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini returned malformed base64 audio.",
			Err:      err,
		}
	}
	if len(raw) == 0 || int64(len(raw)) > maxClipPayloadSize {
		return media.AudioClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  fmt.Sprintf("Gemini audio size (%d bytes) is outside the allowed range.", len(raw)),
		}
	}

	ct, ext := normalizeAudioFormat(audio.MimeType, raw)
	if onProgress != nil {
		onProgress(media.MusicProgress{Percent: 85, Note: "Processing generated track…"})
	}

	var lyrics string
	if inter.OutputText != nil {
		lyrics = strings.TrimSpace(*inter.OutputText)
	}

	return media.AudioClip{
		Data:            raw,
		ContentType:     ct,
		FilenameExt:     ext,
		GeneratedLyrics: lyrics,
		Model:           model,
	}, nil
}

func (p *Provider) resolveModel(req media.MusicRequest) string {
	if m := strings.TrimSpace(req.Model); m != "" && m != modelAuto {
		return m
	}
	if m := strings.TrimSpace(p.cfg.Setting(p.desc, "model")); m != "" && m != modelAuto {
		return m
	}
	if req.Length == media.LengthFull {
		return string(interactions.ModelLyria3ProPreview)
	}
	return string(interactions.ModelLyria3ClipPreview)
}

func formatPrompt(req media.MusicRequest) string {
	prompt := strings.TrimSpace(req.Prompt)
	if req.Instrumental {
		return prompt + "\n\nInstrumental only. No vocals or lyrics."
	}
	if lyrics := strings.TrimSpace(req.Lyrics); lyrics != "" {
		return prompt + "\n\nLyrics:\n" + lyrics
	}
	return prompt
}

func extractAudio(inter *interactions.Interaction) *interactions.AudioContent {
	if inter == nil {
		return nil
	}
	if inter.OutputAudio != nil {
		return inter.OutputAudio
	}
	for i := len(inter.Steps) - 1; i >= 0; i-- {
		step := inter.Steps[i]
		if step.Type != interactions.StepTypeModelOutput || step.ModelOutputStep == nil {
			continue
		}
		for j := len(step.ModelOutputStep.Content) - 1; j >= 0; j-- {
			c := step.ModelOutputStep.Content[j]
			if c.Type == interactions.ContentTypeAudio && c.AudioContent != nil {
				return c.AudioContent
			}
		}
	}
	return nil
}

func normalizeAudioFormat(mt *interactions.AudioContentMimeType, data []byte) (contentType, ext string) {
	if mt != nil {
		switch strings.ToLower(strings.TrimSpace(string(*mt))) {
		case "audio/mp3", "audio/mpeg":
			return "audio/mpeg", ".mp3"
		case "audio/wav", "audio/x-wav", "audio/l16":
			return "audio/wav", ".wav"
		case "audio/ogg":
			return "audio/ogg", ".ogg"
		case "audio/m4a", "audio/mp4", "audio/aac":
			return "audio/mp4", ".m4a"
		}
	}
	switch runs.AudioTypeFromHead(data) {
	case "audio/wav":
		return "audio/wav", ".wav"
	case "audio/ogg":
		return "audio/ogg", ".ogg"
	case "audio/mp4":
		return "audio/mp4", ".m4a"
	default:
		return "audio/mpeg", ".mp3"
	}
}

func (p *Provider) interactionError(inter *interactions.Interaction) error {
	return p.interactionErrorFor(inter, "music")
}

func (p *Provider) interactionErrorFor(inter *interactions.Interaction, mediaKind string) error {
	var parts []string
	for _, e := range inter.Errors {
		if e.Message != nil && strings.TrimSpace(*e.Message) != "" {
			parts = append(parts, strings.TrimSpace(*e.Message))
		} else if e.Code != nil && strings.TrimSpace(*e.Code) != "" {
			parts = append(parts, strings.TrimSpace(*e.Code))
		}
	}
	detail := p.scrub(strings.Join(parts, "; "))
	lower := strings.ToLower(detail)
	kind := media.ErrKindUnknown
	switch {
	case inter.Status == interactions.InteractionStatusBudgetExceeded || strings.Contains(lower, "quota") || strings.Contains(lower, "resource_exhausted") || strings.Contains(lower, "budget"):
		kind = media.ErrKindQuota
	case strings.Contains(lower, "safety") || strings.Contains(lower, "prohibited") || strings.Contains(lower, "blocked") || strings.Contains(lower, "policy"):
		kind = media.ErrKindFiltered
	case strings.Contains(lower, "permission") || strings.Contains(lower, "unauthenticated") || strings.Contains(lower, "unauthorized"):
		kind = media.ErrKindAuth
	}
	msg := fmt.Sprintf("Gemini %s generation ended with status %s.", mediaKind, inter.Status)
	if detail != "" {
		msg = detail
	}
	return &media.ProviderError{
		Provider: ProviderID,
		Kind:     kind,
		Message:  msg,
	}
}

func (p *Provider) mapError(err error) error {
	if err == nil {
		return nil
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return err
	}
	var pe *media.ProviderError
	if errors.As(err, &pe) {
		pe.Message = p.scrub(pe.Message)
		return pe
	}

	var (
		status     int
		apiStatus  string
		rawMsg     string
		retryAfter time.Duration
		details    []map[string]any
	)
	extractMeta := func(meta components.HTTPMetadata) {
		if meta.Response != nil {
			status = meta.Response.StatusCode
			retryAfter = parseRetryAfter(meta.Response.Header.Get("Retry-After"))
		}
	}
	extractInterErr := func(ie interactions.Error) {
		if ie.Code != nil {
			apiStatus = *ie.Code
		}
		if ie.Message != nil {
			rawMsg = *ie.Message
		}
	}

	var (
		gErr     genai.APIError
		gErrPtr  *genai.APIError
		iErr     *apierrors.APIError
		iRespVal *apierrors.ResponseValidationError
		cClient  *apierrors.CreateInteractionClientError
		cServer  *apierrors.CreateInteractionServerError
		gClient  *apierrors.GetInteractionByIDClientError
		gServer  *apierrors.GetInteractionByIDServerError
	)
	switch {
	case errors.As(err, &cClient) && cClient != nil:
		extractMeta(cClient.HTTPMeta)
		extractInterErr(cClient.Error_)
	case errors.As(err, &cServer) && cServer != nil:
		extractMeta(cServer.HTTPMeta)
		extractInterErr(cServer.Error_)
	case errors.As(err, &gClient) && gClient != nil:
		extractMeta(gClient.HTTPMeta)
		extractInterErr(gClient.Error_)
	case errors.As(err, &gServer) && gServer != nil:
		extractMeta(gServer.HTTPMeta)
		extractInterErr(gServer.Error_)
	case errors.As(err, &iRespVal) && iRespVal != nil:
		status = iRespVal.StatusCode
		rawMsg = iRespVal.Body
		if rawMsg == "" {
			rawMsg = iRespVal.Message
		}
		if iRespVal.RawResponse != nil {
			retryAfter = parseRetryAfter(iRespVal.RawResponse.Header.Get("Retry-After"))
		}
	case errors.As(err, &gErrPtr) && gErrPtr != nil:
		status = gErrPtr.Code
		apiStatus = gErrPtr.Status
		rawMsg = gErrPtr.Message
		details = gErrPtr.Details
	case errors.As(err, &gErr):
		status = gErr.Code
		apiStatus = gErr.Status
		rawMsg = gErr.Message
		details = gErr.Details
	case errors.As(err, &iErr) && iErr != nil:
		status = iErr.StatusCode
		rawMsg = iErr.Message
		if iErr.Body != "" {
			rawMsg = iErr.Body
		}
		if iErr.RawResponse != nil {
			retryAfter = parseRetryAfter(iErr.RawResponse.Header.Get("Retry-After"))
		}
	default:
		rawMsg = err.Error()
	}

	cleaned := p.scrub(strings.TrimSpace(rawMsg))
	lower := strings.ToLower(cleaned + " " + apiStatus)

	kind := media.ErrKindUnknown
	friendly := cleaned
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden ||
		strings.Contains(lower, "unauthenticated") || strings.Contains(lower, "permission_denied") ||
		strings.Contains(lower, "api_key_invalid") || strings.Contains(lower, "api key not valid"):
		kind = media.ErrKindAuth
		friendly = "Gemini rejected this API key or billing is disabled. Verify your key and GCP billing link in Settings → Workspace → Media providers."
		if cleaned != "" && !strings.Contains(lower, "api key not valid") {
			friendly += " (" + truncateErr(cleaned) + ")"
		}
	case status == http.StatusTooManyRequests || strings.Contains(lower, "resource_exhausted") || strings.Contains(lower, "quota"):
		kind = media.ErrKindQuota
		friendly = "Gemini quota or monthly credit limit reached (429). Check your GCP credit budget or try again shortly."
		// AI Studio's free tier names the quota that ran out: a per-day cap
		// holds until midnight Pacific whatever retry delay it suggests, while
		// a per-minute one lifts after that delay.
		switch q := parseQuotaDetails(details); {
		case q.daily:
			friendly = q.message()
			retryAfter = untilDailyReset(time.Now())
		case q.perMinute:
			kind = media.ErrKindRateLimit
			friendly = q.message()
			retryAfter = max(retryAfter, q.retryDelay)
		}
	case strings.Contains(lower, "safety") || strings.Contains(lower, "prohibited") || strings.Contains(lower, "content filter") || strings.Contains(lower, "blocked"):
		kind = media.ErrKindFiltered
		friendly = "Gemini blocked this prompt under content safety rules. Edit the prompt or lyrics and try again."
	case status >= 500 || status == http.StatusRequestTimeout:
		kind = media.ErrKindUnavailable
		friendly = fmt.Sprintf("Gemini service returned HTTP %d. Try again in a moment.", status)
	default:
		if friendly == "" {
			friendly = "Gemini request failed."
		} else {
			friendly = truncateErr(friendly)
		}
	}

	return &media.ProviderError{
		Provider:   ProviderID,
		Kind:       kind,
		HTTPStatus: status,
		RetryAfter: retryAfter,
		Message:    friendly,
		Err:        fmt.Errorf("%s", truncateErr(cleaned)),
	}
}

func (p *Provider) scrub(s string) string {
	if p.apiKey == "" || s == "" {
		return s
	}
	s = strings.ReplaceAll(s, p.apiKey, "[REDACTED]")
	s = strings.ReplaceAll(s, url.QueryEscape(p.apiKey), "[REDACTED]")
	return s
}

func parseRetryAfter(val string) time.Duration {
	val = strings.TrimSpace(val)
	if val == "" {
		return 0
	}
	if secs, err := strconv.Atoi(val); err == nil && secs > 0 {
		return time.Duration(secs) * time.Second
	}
	if t, err := http.ParseTime(val); err == nil {
		if d := time.Until(t); d > 0 {
			return d
		}
	}
	return 0
}

func truncateErr(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if len(s) > 240 {
		return s[:240] + "…"
	}
	return s
}

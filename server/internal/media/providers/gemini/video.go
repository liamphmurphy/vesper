package gemini

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"google.golang.org/genai/interactions/models/interactions"
	"google.golang.org/genai/interactions/models/operations"
	"google.golang.org/genai/interactions/retry"

	"github.com/liamphmurphy/vesper/server/internal/media"
)

const (
	defaultVideoModel   = string(interactions.ModelGeminiOmni12Flash)
	maxVideoPayloadSize = 64 << 20 // 64 MiB
)

// GenerateVideo calls Gemini Omni via the Interactions API to generate or edit
// a video clip, polling until completion and returning inline or URI-fetched bytes.
func (p *Provider) GenerateVideo(ctx context.Context, req media.VideoRequest, onProgress func(media.VideoProgress)) (media.VideoClip, error) {
	prompt := strings.TrimSpace(req.Prompt)
	if prompt == "" {
		return media.VideoClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "A video prompt is required.",
		}
	}
	client, err := p.newClient(ctx)
	if err != nil {
		return media.VideoClip{}, err
	}

	input, err := buildVideoInput(req, prompt)
	if err != nil {
		return media.VideoClip{}, err
	}

	model := p.resolveVideoModel(req)
	prevID := strings.TrimSpace(req.PreviousInteractionID)

	vrf := interactions.VideoResponseFormat{
		Delivery: interactions.VideoResponseFormatDeliveryInline.ToPointer(),
	}
	if ar := strings.TrimSpace(req.AspectRatio); ar != "" {
		v := interactions.VideoResponseFormatAspectRatio(ar)
		vrf.AspectRatio = &v
	}
	if req.DurationSec > 0 {
		d := fmt.Sprintf("%ds", req.DurationSec)
		vrf.Duration = &d
	}
	respFmt := interactions.NewCreateModelInteractionResponseFormat(interactions.NewResponseFormat(vrf))

	body := interactions.CreateModelInteraction{
		Model:          interactions.Model(model),
		Input:          &input,
		ResponseFormat: &respFmt,
	}
	if prevID != "" {
		body.PreviousInteractionID = &prevID
	} else {
		task := inferVideoTask(req)
		body.GenerationConfig = &interactions.GenerationConfig{
			VideoConfig: &interactions.VideoConfig{
				Task: &task,
			},
		}
	}

	if onProgress != nil {
		onProgress(media.VideoProgress{Percent: 20, Note: "Sending request to Gemini · Omni…"})
	}

	noRetry := operations.WithRetries(retry.Config{Strategy: "none"})
	createReq := operations.CreateInteractionRequest{
		Body: operations.NewCreateInteractionRequestBody(body),
	}
	res, err := client.Interactions.Create(ctx, createReq, noRetry)
	if err != nil {
		return media.VideoClip{}, p.mapError(err)
	}
	if res == nil || res.Interaction == nil {
		return media.VideoClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini returned an empty response.",
		}
	}

	inter := res.Interaction
	progressPct := 35
	for inter.Status == interactions.InteractionStatusInProgress || inter.Status == interactions.InteractionStatusQueued {
		if inter.ID == nil || strings.TrimSpace(*inter.ID) == "" {
			return media.VideoClip{}, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnknown,
				Message:  "Gemini returned an in-progress interaction without an ID.",
			}
		}
		if onProgress != nil {
			if progressPct < 80 {
				progressPct += 10
			}
			onProgress(media.VideoProgress{Percent: progressPct, Note: "Generating video with Gemini · Omni…"})
		}
		timer := time.NewTimer(p.opts.pollInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return media.VideoClip{}, ctx.Err()
		case <-timer.C:
		}
		got, err := client.Interactions.Get(ctx, operations.GetInteractionByIDRequest{ID: *inter.ID}, noRetry)
		if err != nil {
			return media.VideoClip{}, p.mapError(err)
		}
		if got == nil || got.Interaction == nil {
			return media.VideoClip{}, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnknown,
				Message:  "Gemini returned an empty interaction poll response.",
			}
		}
		inter = got.Interaction
	}

	if inter.Status != "" && inter.Status != interactions.InteractionStatusCompleted {
		return media.VideoClip{}, p.interactionErrorFor(inter, "video")
	}

	video := extractVideo(inter)
	if video == nil {
		if len(inter.Errors) > 0 {
			return media.VideoClip{}, p.interactionErrorFor(inter, "video")
		}
		return media.VideoClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini completed without returning any video data.",
		}
	}

	var (
		raw        []byte
		fetchedCT  string
	)
	switch {
	case video.Data != nil && strings.TrimSpace(*video.Data) != "":
		encoded := strings.TrimSpace(*video.Data)
		if len(encoded) > base64.StdEncoding.EncodedLen(maxVideoPayloadSize)+4 {
			return media.VideoClip{}, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnknown,
				Message:  fmt.Sprintf("Gemini video payload exceeds the %d byte limit.", maxVideoPayloadSize),
			}
		}
		raw, err = base64.StdEncoding.DecodeString(encoded)
		if err != nil {
			return media.VideoClip{}, &media.ProviderError{
				Provider: ProviderID,
				Kind:     media.ErrKindUnknown,
				Message:  "Gemini returned malformed base64 video.",
				Err:      err,
			}
		}
	case video.URI != nil && strings.TrimSpace(*video.URI) != "":
		raw, fetchedCT, err = p.downloadVideoURI(ctx, strings.TrimSpace(*video.URI))
		if err != nil {
			return media.VideoClip{}, err
		}
	default:
		return media.VideoClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini returned an empty video block.",
		}
	}

	if len(raw) == 0 || int64(len(raw)) > maxVideoPayloadSize {
		return media.VideoClip{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  fmt.Sprintf("Gemini video size (%d bytes) is outside the allowed range.", len(raw)),
		}
	}

	ct, ext := normalizeVideoFormat(video.MimeType, fetchedCT, raw)
	if onProgress != nil {
		onProgress(media.VideoProgress{Percent: 85, Note: "Processing generated video…"})
	}

	var interactionID string
	if inter.ID != nil {
		interactionID = strings.TrimSpace(*inter.ID)
	}
	var durationMS int
	if req.DurationSec > 0 {
		durationMS = req.DurationSec * 1000
	}

	return media.VideoClip{
		Data:          raw,
		ContentType:   ct,
		FilenameExt:   ext,
		DurationMS:    durationMS,
		Model:         model,
		InteractionID: interactionID,
	}, nil
}

func (p *Provider) resolveVideoModel(req media.VideoRequest) string {
	if m := strings.TrimSpace(req.Model); m != "" {
		return m
	}
	if m := strings.TrimSpace(p.cfg.Setting(p.desc, "video_model")); m != "" {
		return m
	}
	return defaultVideoModel
}

func inferVideoTask(req media.VideoRequest) interactions.Task {
	if req.FirstFrame != nil || req.LastFrame != nil {
		return interactions.TaskImageToVideo
	}
	if len(req.ReferenceImages) > 0 {
		return interactions.TaskReferenceToVideo
	}
	return interactions.TaskTextToVideo
}

func buildVideoInput(req media.VideoRequest, prompt string) (interactions.InteractionsInput, error) {
	if req.FirstFrame == nil && req.LastFrame == nil && len(req.ReferenceImages) == 0 {
		return interactions.NewInteractionsInput(prompt), nil
	}

	contents := make([]interactions.Content, 0, 1+2*(2+len(req.ReferenceImages)))
	if req.FirstFrame != nil {
		img, err := imageContentFromFrame(*req.FirstFrame, "first frame")
		if err != nil {
			return interactions.InteractionsInput{}, err
		}
		contents = append(contents,
			interactions.NewContent(interactions.TextContent{Text: "First frame:"}),
			img,
		)
	}
	if req.LastFrame != nil {
		img, err := imageContentFromFrame(*req.LastFrame, "last frame")
		if err != nil {
			return interactions.InteractionsInput{}, err
		}
		contents = append(contents,
			interactions.NewContent(interactions.TextContent{Text: "Last frame:"}),
			img,
		)
	}
	for i, ref := range req.ReferenceImages {
		img, err := imageContentFromFrame(ref, fmt.Sprintf("reference image %d", i+1))
		if err != nil {
			return interactions.InteractionsInput{}, err
		}
		contents = append(contents,
			interactions.NewContent(interactions.TextContent{Text: "Reference image:"}),
			img,
		)
	}
	contents = append(contents, interactions.NewContent(interactions.TextContent{Text: prompt}))
	return interactions.NewInteractionsInput(contents), nil
}

func imageContentFromFrame(frame media.VideoFrame, label string) (interactions.Content, error) {
	if len(frame.Data) == 0 {
		return interactions.Content{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  fmt.Sprintf("Video %s is empty.", label),
		}
	}
	b64 := base64.StdEncoding.EncodeToString(frame.Data)
	mt := normalizeImageMimeType(frame.ContentType, frame.Data)
	return interactions.NewContent(interactions.ImageContent{
		Data:     &b64,
		MimeType: &mt,
	}), nil
}

func normalizeImageMimeType(contentType string, data []byte) interactions.ImageContentMimeType {
	ct := strings.ToLower(strings.TrimSpace(strings.Split(contentType, ";")[0]))
	if ct == "" && len(data) > 0 {
		ct = strings.ToLower(strings.Split(http.DetectContentType(data), ";")[0])
	}
	switch ct {
	case "image/png":
		return interactions.ImageContentMimeTypeImagePng
	case "image/jpeg", "image/jpg":
		return interactions.ImageContentMimeTypeImageJpeg
	case "image/webp":
		return interactions.ImageContentMimeTypeImageWebp
	case "image/heic":
		return interactions.ImageContentMimeTypeImageHeic
	case "image/heif":
		return interactions.ImageContentMimeTypeImageHeif
	case "image/gif":
		return interactions.ImageContentMimeTypeImageGif
	case "image/bmp":
		return interactions.ImageContentMimeTypeImageBmp
	case "image/tiff":
		return interactions.ImageContentMimeTypeImageTiff
	default:
		return interactions.ImageContentMimeTypeImagePng
	}
}

func extractVideo(inter *interactions.Interaction) *interactions.VideoContent {
	if inter == nil {
		return nil
	}
	if inter.OutputVideo != nil {
		return inter.OutputVideo
	}
	for i := len(inter.Steps) - 1; i >= 0; i-- {
		step := inter.Steps[i]
		if step.Type != interactions.StepTypeModelOutput || step.ModelOutputStep == nil {
			continue
		}
		for j := len(step.ModelOutputStep.Content) - 1; j >= 0; j-- {
			c := step.ModelOutputStep.Content[j]
			if c.Type == interactions.ContentTypeVideo && c.VideoContent != nil {
				return c.VideoContent
			}
		}
	}
	return nil
}

func (p *Provider) downloadVideoURI(ctx context.Context, rawURI string) ([]byte, string, error) {
	u, err := url.Parse(rawURI)
	if err != nil {
		return nil, "", &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini returned an invalid video URI.",
			Err:      err,
		}
	}
	if u.Scheme != "http" && u.Scheme != "https" {
		return nil, "", &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  fmt.Sprintf("Gemini returned an unsupported video URI scheme (%q).", u.Scheme),
		}
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURI, nil)
	if err != nil {
		return nil, "", p.mapError(err)
	}
	if p.apiKey != "" && p.shouldAttachAPIKey(u) {
		req.Header.Set("x-goog-api-key", p.apiKey)
	}

	hc := p.opts.httpClient
	if hc == nil {
		hc = http.DefaultClient
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, "", p.mapError(err)
	}
	defer resp.Body.Close()

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return nil, "", p.mapHTTPStatusError(resp.StatusCode, resp.Header.Get("Retry-After"), string(body))
	}

	raw, err := io.ReadAll(io.LimitReader(resp.Body, maxVideoPayloadSize+1))
	if err != nil {
		return nil, "", p.mapError(err)
	}
	if int64(len(raw)) > maxVideoPayloadSize {
		return nil, "", &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  fmt.Sprintf("Gemini video payload exceeds the %d byte limit.", maxVideoPayloadSize),
		}
	}
	return raw, resp.Header.Get("Content-Type"), nil
}

func (p *Provider) shouldAttachAPIKey(target *url.URL) bool {
	if target == nil {
		return false
	}
	host := strings.ToLower(target.Host)
	if host == "generativelanguage.googleapis.com" || strings.HasSuffix(host, ".googleapis.com") {
		return true
	}
	if p.opts.baseURL != "" {
		if base, err := url.Parse(p.opts.baseURL); err == nil && strings.EqualFold(base.Host, target.Host) {
			return true
		}
	}
	return false
}

func (p *Provider) mapHTTPStatusError(status int, retryAfterHdr, body string) error {
	cleaned := p.scrub(strings.TrimSpace(body))
	lower := strings.ToLower(cleaned)
	retryAfter := parseRetryAfter(retryAfterHdr)

	kind := media.ErrKindUnknown
	friendly := cleaned
	switch {
	case status == http.StatusUnauthorized || status == http.StatusForbidden:
		kind = media.ErrKindAuth
		friendly = "Gemini rejected this API key or billing is disabled while downloading the video."
	case status == http.StatusTooManyRequests || strings.Contains(lower, "resource_exhausted") || strings.Contains(lower, "quota"):
		kind = media.ErrKindQuota
		friendly = "Gemini quota or monthly credit limit reached (429)."
	case status >= 500 || status == http.StatusRequestTimeout:
		kind = media.ErrKindUnavailable
		friendly = fmt.Sprintf("Gemini video download returned HTTP %d. Try again in a moment.", status)
	default:
		if friendly == "" {
			friendly = fmt.Sprintf("Gemini video download failed with HTTP %d.", status)
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
		Err:        fmt.Errorf("http %d: %s", status, truncateErr(cleaned)),
	}
}

func normalizeVideoFormat(mt *interactions.VideoContentMimeType, respCT string, data []byte) (contentType, ext string) {
	candidates := make([]string, 0, 2)
	if mt != nil {
		candidates = append(candidates, string(*mt))
	}
	if respCT != "" {
		candidates = append(candidates, respCT)
	}
	for _, raw := range candidates {
		ct := strings.ToLower(strings.TrimSpace(strings.Split(raw, ";")[0]))
		switch ct {
		case "video/mp4":
			return "video/mp4", ".mp4"
		case "video/webm":
			return "video/webm", ".webm"
		case "video/mov", "video/quicktime":
			return "video/quicktime", ".mov"
		case "video/mpeg", "video/mpg":
			return "video/mpeg", ".mpeg"
		case "video/avi", "video/x-msvideo":
			return "video/avi", ".avi"
		case "video/x-flv":
			return "video/x-flv", ".flv"
		case "video/wmv", "video/x-ms-wmv":
			return "video/wmv", ".wmv"
		case "video/3gpp":
			return "video/3gpp", ".3gp"
		}
	}
	if len(data) >= 12 && bytes.Equal(data[4:8], []byte("ftyp")) {
		return "video/mp4", ".mp4"
	}
	if len(data) >= 4 && data[0] == 0x1a && data[1] == 0x45 && data[2] == 0xdf && data[3] == 0xa3 {
		return "video/webm", ".webm"
	}
	return "video/mp4", ".mp4"
}

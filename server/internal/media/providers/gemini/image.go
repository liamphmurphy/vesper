package gemini

import (
	"context"
	"fmt"
	"strings"

	"google.golang.org/genai"
	"google.golang.org/genai/interactions/models/interactions"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/runs"
)

const (
	defaultImageModel = string(interactions.ModelGemini3ProImage)
	defaultImageSize  = "2K"
)

// GenerateImage calls Gemini's native image generation models (Nano Banana Pro
// / Nano Banana 2) via GenerateContent, passing any reference images inline.
func (p *Provider) GenerateImage(ctx context.Context, req media.ImageRequest) (media.GeneratedImage, error) {
	prompt := strings.TrimSpace(req.Prompt)
	if prompt == "" {
		return media.GeneratedImage{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "An image prompt is required.",
		}
	}
	client, err := p.newClient(ctx)
	if err != nil {
		return media.GeneratedImage{}, err
	}

	model := p.resolveImageModel(req)
	imageSize := strings.TrimSpace(req.ImageSize)
	if imageSize == "" {
		imageSize = strings.TrimSpace(p.cfg.Setting(p.desc, "image_size"))
	}

	parts := buildImageParts(prompt, req.References)
	contents := []*genai.Content{genai.NewContentFromParts(parts, genai.RoleUser)}
	cfg := &genai.GenerateContentConfig{
		ResponseModalities: []string{"TEXT", "IMAGE"},
	}
	imgCfg := &genai.ImageConfig{
		AspectRatio: strings.TrimSpace(req.AspectRatio),
		ImageSize:   imageSize,
	}
	if imgCfg.AspectRatio != "" || imgCfg.ImageSize != "" {
		cfg.ImageConfig = imgCfg
	}

	resp, err := client.Models.GenerateContent(ctx, model, contents, cfg)
	if err != nil {
		return media.GeneratedImage{}, p.mapError(err)
	}
	return p.extractGeneratedImage(resp, model)
}

func (p *Provider) resolveImageModel(req media.ImageRequest) string {
	if m := strings.TrimSpace(req.Model); m != "" {
		return m
	}
	if m := strings.TrimSpace(p.cfg.Setting(p.desc, "image_model")); m != "" {
		return m
	}
	return defaultImageModel
}

func buildImageParts(prompt string, refs []media.ImageReference) []*genai.Part {
	parts := make([]*genai.Part, 0, len(refs)*2+1)
	for _, ref := range refs {
		if len(ref.Data) == 0 {
			continue
		}
		ct := strings.TrimSpace(ref.ContentType)
		if ct == "" {
			ct = "image/png"
		}
		switch ref.Role {
		case runs.ReferencePersona:
			parts = append(parts, &genai.Part{Text: "Reference image of the chat's persona. Keep this likeness (face, hair, build, distinguishing features) wherever the image shows them:"})
		case runs.ReferencePerson:
			parts = append(parts, &genai.Part{Text: "Reference image of the person the chat is with. Keep this likeness (face, hair, build, distinguishing features) wherever the image shows them:"})
		}
		parts = append(parts, genai.NewPartFromBytes(ref.Data, ct))
	}
	parts = append(parts, &genai.Part{Text: prompt})
	return parts
}

func (p *Provider) extractGeneratedImage(resp *genai.GenerateContentResponse, model string) (media.GeneratedImage, error) {
	if resp == nil {
		return media.GeneratedImage{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindUnknown,
			Message:  "Gemini returned an empty image response.",
		}
	}
	if resp.PromptFeedback != nil && resp.PromptFeedback.BlockReason != "" && resp.PromptFeedback.BlockReason != genai.BlockedReasonUnspecified {
		detail := strings.TrimSpace(p.scrub(resp.PromptFeedback.BlockReasonMessage))
		if detail == "" {
			detail = strings.ToLower(strings.ReplaceAll(string(resp.PromptFeedback.BlockReason), "_", " "))
		}
		return media.GeneratedImage{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindFiltered,
			Message:  truncateErr(detail),
		}
	}

	var notes []string
	var blockReason string
	for _, cand := range resp.Candidates {
		if cand == nil {
			continue
		}
		if cand.Content != nil {
			for _, part := range cand.Content.Parts {
				if part == nil || part.Thought {
					continue
				}
				if part.InlineData != nil && len(part.InlineData.Data) > 0 {
					data := part.InlineData.Data
					if len(data) > maxClipPayloadSize {
						return media.GeneratedImage{}, &media.ProviderError{
							Provider: ProviderID,
							Kind:     media.ErrKindUnknown,
							Message:  fmt.Sprintf("Generated image exceeds the %d MB limit.", maxClipPayloadSize/(1<<20)),
						}
					}
					ct, ok := runs.GeneratedImageType(data)
					if !ok {
						if declared := strings.ToLower(strings.TrimSpace(part.InlineData.MIMEType)); strings.HasPrefix(declared, "image/") {
							ct = declared
						} else {
							continue
						}
					}
					return media.GeneratedImage{
						Data:        data,
						ContentType: ct,
						FilenameExt: imageExtForContentType(ct),
						Model:       model,
					}, nil
				}
				if txt := strings.TrimSpace(part.Text); txt != "" {
					notes = append(notes, txt)
				}
			}
		}
		if isImageSafetyFinish(cand.FinishReason) {
			if msg := strings.TrimSpace(p.scrub(cand.FinishMessage)); msg != "" {
				blockReason = msg
			} else {
				blockReason = strings.ToLower(strings.ReplaceAll(string(cand.FinishReason), "_", " "))
			}
		}
	}

	if blockReason != "" {
		return media.GeneratedImage{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     media.ErrKindFiltered,
			Message:  truncateErr(blockReason),
		}
	}
	if len(notes) > 0 {
		note := p.scrub(strings.Join(notes, " "))
		lower := strings.ToLower(note)
		kind := media.ErrKindUnknown
		if strings.Contains(lower, "safety") || strings.Contains(lower, "policy") ||
			strings.Contains(lower, "cannot") || strings.Contains(lower, "can't") ||
			strings.Contains(lower, "unable to") || strings.Contains(lower, "inappropriate") {
			kind = media.ErrKindFiltered
		}
		return media.GeneratedImage{}, &media.ProviderError{
			Provider: ProviderID,
			Kind:     kind,
			Message:  truncateErr(note),
		}
	}
	return media.GeneratedImage{}, &media.ProviderError{
		Provider: ProviderID,
		Kind:     media.ErrKindUnknown,
		Message:  "Gemini returned no image for this prompt.",
	}
}

func isImageSafetyFinish(r genai.FinishReason) bool {
	switch r {
	case genai.FinishReasonSafety,
		genai.FinishReasonProhibitedContent,
		genai.FinishReasonRecitation,
		genai.FinishReasonBlocklist,
		genai.FinishReasonSPII,
		genai.FinishReasonImageSafety,
		genai.FinishReasonImageProhibitedContent,
		genai.FinishReasonImageRecitation:
		return true
	}
	return false
}

func imageExtForContentType(ct string) string {
	switch strings.ToLower(strings.TrimSpace(ct)) {
	case "image/jpeg":
		return ".jpg"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	default:
		return ".png"
	}
}

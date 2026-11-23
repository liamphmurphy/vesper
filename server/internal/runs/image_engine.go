package runs

import (
	"context"
	"errors"
	"slices"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Image engines: the backend that makes an image. A workspace chooses one
// (EngineAuto uses the first connected: Codex, Antigravity, then Gemini API);
// a persona or a workflow step may override it.
const (
	EngineAuto        = "auto"
	EngineCodex       = agentdef.HarnessCodex
	EngineAntigravity = agentdef.HarnessAntigravity
	EngineGemini      = "gemini"
)

// ImageEngines lists every selectable image engine in Auto preference order.
var ImageEngines = []string{EngineCodex, EngineAntigravity, EngineGemini}

// GeminiImageInfo reports the workspace's Gemini API image provider readiness.
type GeminiImageInfo struct {
	Available bool
	Model     string
	Reason    string
}

// ValidImageEngine reports whether s names an engine (or auto).
func ValidImageEngine(s string) bool {
	return s == EngineAuto || slices.Contains(ImageEngines, s)
}

// ImageEngineLabel is how an engine reads to the person.
func ImageEngineLabel(engine string) string {
	switch engine {
	case EngineAntigravity:
		return "Antigravity"
	case EngineCodex:
		return "Codex"
	case EngineGemini:
		return "Gemini API"
	}
	return "an image engine"
}

// PickImageEngine chooses the engine and model that make an image without
// Gemini API status (equivalent to PickImageEngineWith with an unconfigured
// Gemini provider).
func PickImageEngine(catalog []chatmodels.Harness, preference string) (harness, model, reason string) {
	return PickImageEngineWith(catalog, GeminiImageInfo{}, preference)
}

// PickImageEngineWith chooses the engine and model that make an image.
// preference is an engine, EngineAuto or "" (auto). A non-empty reason is why
// none can, worded for the person; it names the engine they asked for, or each
// candidate when auto.
func PickImageEngineWith(catalog []chatmodels.Harness, gemini GeminiImageInfo, preference string) (engine, model, reason string) {
	candidates := ImageEngines
	if preference != "" && preference != EngineAuto {
		candidates = []string{preference}
	}
	why := map[string]string{}
	for _, name := range candidates {
		if name == EngineGemini {
			if gemini.Available {
				return EngineGemini, gemini.Model, ""
			}
			r := strings.TrimSpace(gemini.Reason)
			if r == "" {
				r = "isn't configured"
			}
			why[name] = r
			continue
		}
		var found *chatmodels.Harness
		for i := range catalog {
			if catalog[i].Harness == name {
				found = &catalog[i]
			}
		}
		switch {
		case found == nil:
			why[name] = "isn't available"
		case !found.Available:
			why[name] = "isn't available: " + found.UnavailableReason
		default:
			picked := ""
			for _, m := range found.Models {
				if picked == "" || m.Default {
					picked = m.ID
				}
			}
			if picked != "" {
				return name, picked, ""
			}
			why[name] = "has no models available"
		}
	}
	if len(candidates) == 1 {
		return "", "", ImageEngineLabel(candidates[0]) + " " + why[candidates[0]]
	}
	var parts []string
	for _, name := range candidates {
		parts = append(parts, ImageEngineLabel(name)+" "+why[name])
	}
	return "", "", "no image engine is connected (" + strings.Join(parts, "; ") + ")"
}

func (s *Service) geminiImageInfo(ctx context.Context, ws uuid.UUID) GeminiImageInfo {
	if s == nil || s.GeminiImageStatus == nil {
		return GeminiImageInfo{Reason: "isn't configured"}
	}
	model, ok, reason := s.GeminiImageStatus(ctx, ws)
	return GeminiImageInfo{Available: ok, Model: model, Reason: reason}
}

// ImageEnginePreference is the engine a request should use: the persona's own
// choice when it has one, else the workspace's.
func ImageEnginePreference(ctx context.Context, q *store.Queries, ws uuid.UUID, personaEngine string) (string, error) {
	if personaEngine != "" && personaEngine != EngineAuto {
		return personaEngine, nil
	}
	engine, err := q.WorkspaceImageEngine(ctx, ws)
	if errors.Is(err, pgx.ErrNoRows) {
		return EngineAuto, nil
	}
	if err != nil {
		return "", err
	}
	if personaEngine == EngineAuto {
		return EngineAuto, nil
	}
	return engine, nil
}

// chatPersonaImageEngine is the image engine the persona answering a chat has
// chosen ("" inherits the workspace's).
func chatPersonaImageEngine(ctx context.Context, q *store.Queries, chat store.ChatSession) (string, error) {
	id := ChatSpeakerID(chat)
	if id == nil {
		return "", nil
	}
	p, err := q.GetPersona(ctx, store.GetPersonaParams{ID: *id, WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy})
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return p.ImageEngine, err
}

// SetWorkspaceImageEngine saves the workspace's choice.
func (s *Service) SetWorkspaceImageEngine(ctx context.Context, ws uuid.UUID, engine string) error {
	if !ValidImageEngine(engine) {
		return apperr.Invalid("engine", "must be auto, codex, antigravity or gemini")
	}
	return store.New(s.Pool).SetWorkspaceImageEngine(ctx, store.SetWorkspaceImageEngineParams{ID: ws, ImageEngine: engine})
}

// WorkspaceImageEngine reads the workspace's choice.
func (s *Service) WorkspaceImageEngine(ctx context.Context, ws uuid.UUID) (string, error) {
	return ImageEnginePreference(ctx, store.New(s.Pool), ws, "")
}

// ImageEngineOptions lists what the person can choose from and whether each is
// connected right now, for the Settings and persona pickers.
func (s *Service) ImageEngineOptions(ctx context.Context, ws uuid.UUID) ([]ImageEngineOption, error) {
	catalog, err := s.ChatCatalog().List(ctx, store.New(s.Pool), ws)
	if err != nil {
		return nil, err
	}
	gemini := s.geminiImageInfo(ctx, ws)
	var out []ImageEngineOption
	for _, name := range ImageEngines {
		_, model, reason := PickImageEngineWith(catalog, gemini, name)
		opt := ImageEngineOption{
			Engine:    name,
			Label:     ImageEngineLabel(name),
			Available: reason == "",
			Reason:    strings.TrimPrefix(reason, ImageEngineLabel(name)+" "),
			Model:     model,
		}
		if name == EngineGemini && opt.Model == "" {
			opt.Model = gemini.Model
		}
		out = append(out, opt)
	}
	return out, nil
}

// ImageEngineOption is one engine and whether it can make images now.
type ImageEngineOption struct {
	Engine    string
	Label     string
	Available bool
	Reason    string
	Model     string
}

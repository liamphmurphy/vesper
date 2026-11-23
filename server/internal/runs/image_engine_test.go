package runs

import (
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
)

func TestPickImageEngineWithGemini(t *testing.T) {
	codexReady := chatmodels.Harness{Harness: agentdef.HarnessCodex, Available: true, Models: []chatmodels.Model{{ID: "codex-main", Default: true}}}
	codexDown := chatmodels.Harness{Harness: agentdef.HarnessCodex, Available: false, UnavailableReason: "not connected"}
	agyDown := chatmodels.Harness{Harness: agentdef.HarnessAntigravity, Available: false, UnavailableReason: "not connected"}
	geminiReady := GeminiImageInfo{Available: true, Model: "gemini-3-pro-image"}
	geminiDown := GeminiImageInfo{Available: false, Reason: "Add a Gemini API key in Settings → Workspace → Media providers."}

	if !ValidImageEngine(EngineGemini) || ImageEngineLabel(EngineGemini) != "Gemini API" {
		t.Fatalf("gemini engine registration broken")
	}

	// Explicit Gemini API selection works even when Codex is also connected.
	eng, model, reason := PickImageEngineWith([]chatmodels.Harness{codexReady, agyDown}, geminiReady, EngineGemini)
	if eng != EngineGemini || model != "gemini-3-pro-image" || reason != "" {
		t.Fatalf("explicit gemini = (%q, %q, %q)", eng, model, reason)
	}

	// Explicit Gemini API when unconfigured reports Gemini's reason.
	eng, model, reason = PickImageEngineWith([]chatmodels.Harness{codexReady}, geminiDown, EngineGemini)
	if eng != "" || model != "" || reason == "" {
		t.Fatalf("unconfigured gemini = (%q, %q, %q)", eng, model, reason)
	}

	// Auto prefers Codex over Gemini when Codex is connected.
	eng, model, reason = PickImageEngineWith([]chatmodels.Harness{codexReady, agyDown}, geminiReady, EngineAuto)
	if eng != EngineCodex || model != "codex-main" || reason != "" {
		t.Fatalf("auto with codex+gemini = (%q, %q, %q)", eng, model, reason)
	}

	// Auto falls back to Gemini API when neither Codex nor Antigravity is connected.
	eng, model, reason = PickImageEngineWith([]chatmodels.Harness{codexDown, agyDown}, geminiReady, EngineAuto)
	if eng != EngineGemini || model != "gemini-3-pro-image" || reason != "" {
		t.Fatalf("auto fallback to gemini = (%q, %q, %q)", eng, model, reason)
	}
}

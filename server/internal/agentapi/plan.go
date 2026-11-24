package agentapi

import (
	"context"
	"slices"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

// SetPlanIn is set_plan's input. harness.TrackPlans reads the same shape from
// the turn's tool calls, so keep the two in step.
type SetPlanIn struct {
	Steps []SetPlanStep `json:"steps" jsonschema:"The whole checklist, in order; an empty list clears it"`
}

type SetPlanStep struct {
	Title  string `json:"title" jsonschema:"One short sentence"`
	Status string `json:"status,omitempty" jsonschema:"pending (default), in_progress, completed or failed"`
}

var setPlanStatuses = []string{"", "pending", "in_progress", "completed", "failed"}

// setPlanMaxSteps matches the cap harness.planEvent applies.
const setPlanMaxSteps = 50

// setPlan validates a chat turn's checklist. It stores nothing: the runner
// sees the call in the turn's events and turns it into the plan event the
// chat shows (harness.TrackPlans), as it does a harness's own plan tool.
func setPlan(ctx context.Context, d Deps, c agents.Caller, in SetPlanIn) (any, error) {
	s, err := chatScopeFor(ctx, d, c)
	if err != nil {
		return nil, err
	}
	if s == nil {
		return nil, apperr.Conflict("set_plan only works in a chat; a ticket run posts its plan with post_plan")
	}
	if len(in.Steps) > setPlanMaxSteps {
		return nil, apperr.Invalid("steps", "give at most %d steps", setPlanMaxSteps)
	}
	for _, st := range in.Steps {
		if strings.TrimSpace(st.Title) == "" {
			return nil, apperr.Invalid("steps", "every step needs a title")
		}
		if !slices.Contains(setPlanStatuses, st.Status) {
			return nil, apperr.Invalid("steps", "status must be pending, in_progress, completed or failed")
		}
	}
	return map[string]any{"steps": len(in.Steps)}, nil
}

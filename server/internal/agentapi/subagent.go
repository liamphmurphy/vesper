package agentapi

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type RunSubagentIn struct {
	Type   string `json:"type" jsonschema:"Subagent type: explorer (read-only code search on a fast model) or helper (self-contained task using the parent run's workspace permissions)."`
	Role   string `json:"role,omitempty" jsonschema:"Short role label (2-5 words), e.g. Codebase Researcher."`
	Prompt string `json:"prompt" jsonschema:"Clear, self-contained instructions. Subagents cannot ask follow-up questions."`
}

const subagentPollInterval = 100 * time.Millisecond

func runSubagentTool(ctx context.Context, d Deps, c agents.Caller, in RunSubagentIn) (any, error) {
	if c.RunID == nil {
		return nil, apperr.Conflict("run_subagent requires a running turn")
	}
	typ := strings.TrimSpace(in.Type)
	prompt := strings.TrimSpace(in.Prompt)
	if prompt == "" {
		return nil, apperr.Invalid("prompt", "prompt is required")
	}
	run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
	if err != nil {
		return nil, err
	}
	if run.State != "running" {
		return nil, apperr.Conflict("run is not running")
	}
	spec, err := runs.Spec(run)
	if err != nil {
		return nil, apperr.Invalid("spec", "invalid run spec")
	}
	if !agentdef.SubagentsOn(spec) {
		return nil, apperr.Conflict("subagents are disabled for this run")
	}
	switch typ {
	case agentdef.ExplorerAgent:
		if !agentdef.ExplorerOn(spec) {
			return nil, apperr.Invalid("type", "explorer subagent is disabled for this run")
		}
	case agentdef.HelperAgent:
	default:
		return nil, apperr.Invalid("type", "unknown subagent type %q; want explorer or helper", typ)
	}

	job, err := d.Q.CreateSubagentJob(ctx, store.CreateSubagentJobParams{
		RunID:     run.ID,
		AgentType: typ,
		Role:      strings.TrimSpace(in.Role),
		Prompt:    prompt,
	})
	if err != nil {
		return nil, err
	}

	t := time.NewTicker(subagentPollInterval)
	defer t.Stop()
	for {
		j, err := d.Q.GetSubagentJob(ctx, job.ID)
		if err != nil {
			return nil, err
		}
		switch j.Status {
		case "completed":
			return map[string]any{
				"job_id":        j.ID.String(),
				"type":          j.AgentType,
				"role":          j.Role,
				"result":        j.ResultText,
				"tool_calls":    j.ToolCalls,
				"input_tokens":  j.InputTokens,
				"output_tokens": j.OutputTokens,
			}, nil
		case "failed", "canceled":
			msg := j.Error
			if msg == "" {
				msg = "subagent " + j.Status
			}
			return nil, apperr.Conflict("subagent %s: %s", j.Status, msg)
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-t.C:
		}
	}
}

func checkSubagentJobPolicy(ctx context.Context, d Deps, c agents.Caller, rawJobID string, in runs.ToolCheck) (runs.ToolDecision, error) {
	deny := func(reason string) (runs.ToolDecision, error) {
		return runs.ToolDecision{Decision: "deny", Reason: reason}, nil
	}
	if c.RunID == nil {
		return deny("Tool policy requires a run-scoped token")
	}
	jobID, err := uuid.Parse(strings.TrimSpace(rawJobID))
	if err != nil {
		return deny("Invalid subagent job id")
	}
	job, err := d.Q.GetSubagentJob(ctx, jobID)
	if errors.Is(err, pgx.ErrNoRows) {
		return deny("Subagent job is not active")
	}
	if err != nil {
		return runs.ToolDecision{}, err
	}
	if job.RunID != *c.RunID || job.Status != "running" {
		return deny("Subagent job is not running")
	}
	run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
	if errors.Is(err, pgx.ErrNoRows) {
		return deny("Run not found")
	}
	if err != nil {
		return runs.ToolDecision{}, err
	}
	parentSpec, err := runs.Spec(run)
	if err != nil {
		return deny("Invalid parent run spec")
	}
	subSpec, err := runs.SubagentSpec(parentSpec, job.AgentType)
	if err != nil {
		return deny("Invalid subagent type")
	}
	return d.Runs.CheckToolWithSpec(ctx, c, subSpec, in)
}

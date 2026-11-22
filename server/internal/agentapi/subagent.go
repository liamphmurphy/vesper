package agentapi

import (
	"context"
	"errors"
	"fmt"
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

type RunSubagentsIn struct {
	Tasks []RunSubagentIn `json:"tasks" jsonschema:"List of independent subagents to run in parallel (at least 1). Each runs in a fresh isolated session up to the workspace's concurrency limit; extra tasks wait in the queue."`
}

const (
	subagentPollInterval = 100 * time.Millisecond
	maxSubagentBatch     = 20
)

func loadSubagentRun(ctx context.Context, d Deps, c agents.Caller, toolName string) (store.Run, agentdef.Resolved, error) {
	if c.RunID == nil {
		return store.Run{}, agentdef.Resolved{}, apperr.Conflict("%s requires a running turn", toolName)
	}
	run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
	if err != nil {
		return store.Run{}, agentdef.Resolved{}, err
	}
	if run.State != "running" {
		return store.Run{}, agentdef.Resolved{}, apperr.Conflict("run is not running")
	}
	spec, err := runs.Spec(run)
	if err != nil {
		return store.Run{}, agentdef.Resolved{}, apperr.Invalid("spec", "invalid run spec")
	}
	if !agentdef.SubagentsOn(spec) {
		return store.Run{}, agentdef.Resolved{}, apperr.Conflict("subagents are disabled for this run")
	}
	return run, spec, nil
}

func validateSubagentTask(spec agentdef.Resolved, in RunSubagentIn, fieldPrefix string) (typ, role, prompt string, err error) {
	typ = strings.TrimSpace(in.Type)
	role = strings.TrimSpace(in.Role)
	prompt = strings.TrimSpace(in.Prompt)
	if prompt == "" {
		return "", "", "", apperr.Invalid(fieldPrefix+"prompt", "prompt is required")
	}
	switch typ {
	case agentdef.ExplorerAgent:
		if !agentdef.ExplorerOn(spec) {
			return "", "", "", apperr.Invalid(fieldPrefix+"type", "explorer subagent is disabled for this run")
		}
	case agentdef.HelperAgent:
	default:
		return "", "", "", apperr.Invalid(fieldPrefix+"type", "unknown subagent type %q; want explorer or helper", typ)
	}
	return typ, role, prompt, nil
}

func runSubagentTool(ctx context.Context, d Deps, c agents.Caller, in RunSubagentIn) (any, error) {
	run, spec, err := loadSubagentRun(ctx, d, c, "run_subagent")
	if err != nil {
		return nil, err
	}
	typ, role, prompt, err := validateSubagentTask(spec, in, "")
	if err != nil {
		return nil, err
	}

	job, err := d.Q.CreateSubagentJob(ctx, store.CreateSubagentJobParams{
		RunID:     run.ID,
		AgentType: typ,
		Role:      role,
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

func runSubagentsTool(ctx context.Context, d Deps, c agents.Caller, in RunSubagentsIn) (any, error) {
	run, spec, err := loadSubagentRun(ctx, d, c, "run_subagents")
	if err != nil {
		return nil, err
	}
	if len(in.Tasks) == 0 {
		return nil, apperr.Invalid("tasks", "at least one task is required")
	}
	if len(in.Tasks) > maxSubagentBatch {
		return nil, apperr.Invalid("tasks", "at most %d tasks per batch", maxSubagentBatch)
	}

	// Validate every task before inserting any jobs so a malformed batch creates zero rows.
	validated := make([]store.CreateSubagentJobParams, len(in.Tasks))
	for i, task := range in.Tasks {
		typ, role, prompt, err := validateSubagentTask(spec, task, fmt.Sprintf("tasks[%d].", i))
		if err != nil {
			return nil, err
		}
		validated[i] = store.CreateSubagentJobParams{
			RunID:     run.ID,
			AgentType: typ,
			Role:      role,
			Prompt:    prompt,
		}
	}

	// Enqueue all jobs up front so startSubagentWorker claims and runs them concurrently.
	jobs := make([]store.SubagentJob, len(validated))
	for i, params := range validated {
		job, err := d.Q.CreateSubagentJob(ctx, params)
		if err != nil {
			return nil, err
		}
		jobs[i] = job
	}

	results := make([]map[string]any, len(jobs))
	done := make([]bool, len(jobs))
	remaining := len(jobs)

	t := time.NewTicker(subagentPollInterval)
	defer t.Stop()
	for {
		for i, job := range jobs {
			if done[i] {
				continue
			}
			j, err := d.Q.GetSubagentJob(ctx, job.ID)
			if err != nil {
				return nil, err
			}
			switch j.Status {
			case "completed":
				results[i] = map[string]any{
					"index":         i,
					"job_id":        j.ID.String(),
					"type":          j.AgentType,
					"role":          j.Role,
					"status":        j.Status,
					"result":        j.ResultText,
					"tool_calls":    j.ToolCalls,
					"input_tokens":  j.InputTokens,
					"output_tokens": j.OutputTokens,
				}
				done[i] = true
				remaining--
			case "failed", "canceled":
				msg := j.Error
				if msg == "" {
					msg = "subagent " + j.Status
				}
				results[i] = map[string]any{
					"index":         i,
					"job_id":        j.ID.String(),
					"type":          j.AgentType,
					"role":          j.Role,
					"status":        j.Status,
					"error":         msg,
					"tool_calls":    j.ToolCalls,
					"input_tokens":  j.InputTokens,
					"output_tokens": j.OutputTokens,
				}
				done[i] = true
				remaining--
			}
		}
		if remaining == 0 {
			return map[string]any{"results": results}, nil
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

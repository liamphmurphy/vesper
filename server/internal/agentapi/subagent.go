package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type RunSubagentIn struct {
	Type   string `json:"type" jsonschema:"Subagent type: explorer (read-only code search, defaults to fast tier) or helper (self-contained task using the parent run's workspace permissions, defaults to standard tier)."`
	Tier   string `json:"tier,omitempty" jsonschema:"Optional model tier within the parent's harness, capped at the parent's own tier: fast (search, reading, summaries, mechanical edits, running tests), standard (well-scoped implementation, bug fixes, tests, routine review), or deep (tricky debugging, subtle concurrency/security/architecture review, ambiguous multi-file design). Omit for the default (fast for explorer, standard for helper)."`
	Role   string `json:"role,omitempty" jsonschema:"Short role label (2-5 words), e.g. Codebase Researcher."`
	Reason string `json:"reason,omitempty" jsonschema:"One short sentence explaining why you are spawning this subagent and why this tier fits (shown in the decision tree)."`
	Prompt string `json:"prompt" jsonschema:"Clear, self-contained instructions. Subagents cannot ask follow-up questions."`
}

type RunSubagentsIn struct {
	Tasks []RunSubagentIn `json:"tasks" jsonschema:"List of independent subagents to run in parallel (at least 1). Each runs in a fresh isolated session up to the workspace's concurrency limit; extra tasks wait in the queue."`
}

const (
	subagentPollInterval = 100 * time.Millisecond
	maxSubagentBatch     = 20
	maxSubagentReason    = 500
)

func clipRunes(s string, n int) string {
	if n <= 0 || len(s) <= n {
		return s
	}
	count := 0
	for i := range s {
		if count == n {
			return s[:i]
		}
		count++
	}
	return s
}

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

func validateSubagentTask(spec agentdef.Resolved, in RunSubagentIn, fieldPrefix string) (typ, tier, role, reason, prompt string, err error) {
	typ = strings.TrimSpace(in.Type)
	tier = strings.TrimSpace(strings.ToLower(in.Tier))
	role = strings.TrimSpace(in.Role)
	reason = clipRunes(strings.TrimSpace(in.Reason), maxSubagentReason)
	prompt = strings.TrimSpace(in.Prompt)
	if prompt == "" {
		return "", "", "", "", "", apperr.Invalid(fieldPrefix+"prompt", "prompt is required")
	}
	switch typ {
	case agentdef.ExplorerAgent:
		if !agentdef.ExplorerOn(spec) {
			return "", "", "", "", "", apperr.Invalid(fieldPrefix+"type", "explorer subagent is disabled for this run")
		}
	case agentdef.HelperAgent:
	default:
		return "", "", "", "", "", apperr.Invalid(fieldPrefix+"type", "unknown subagent type %q; want explorer or helper", typ)
	}
	if tier != "" && !agentdef.ValidSubagentTier(tier) {
		return "", "", "", "", "", apperr.Invalid(fieldPrefix+"tier", "unknown subagent tier %q; want fast, standard, or deep", tier)
	}
	return typ, tier, role, reason, prompt, nil
}

func emitSubagentQueuedEvent(ctx context.Context, q *store.Queries, j store.SubagentJob, batchSize int) {
	pl := map[string]any{
		"state":         "subagent_queued",
		"subagent":      true,
		"subagent_id":   j.ID.String(),
		"subagent_type": j.AgentType,
		"created_at":    j.CreatedAt.UTC().Format(time.RFC3339Nano),
	}
	if j.Role != "" {
		pl["subagent_role"] = j.Role
	}
	if j.Reason != "" {
		pl["reason"] = j.Reason
	}
	if j.RequestedTier != "" {
		pl["requested_tier"] = j.RequestedTier
	}
	if j.Tier != "" {
		pl["subagent_tier"] = j.Tier
	}
	if j.Model != "" {
		pl["subagent_model"] = j.Model
	}
	if j.Effort != "" {
		pl["subagent_effort"] = j.Effort
	}
	if j.BatchID != nil {
		pl["batch_id"] = j.BatchID.String()
	}
	if batchSize > 1 {
		pl["batch_size"] = batchSize
	}
	raw, err := json.Marshal(pl)
	if err != nil {
		return
	}
	_ = q.AddRunEvent(ctx, store.AddRunEventParams{RunID: j.RunID, Type: "lifecycle", Payload: raw})
}

func resolveSubagentModel(ctx context.Context, d Deps, ws uuid.UUID, spec agentdef.Resolved, typ, tier string) chatmodels.SubagentModelResult {
	var cat chatmodels.Catalog
	if d.Runs != nil {
		cat = d.Runs.ChatCatalog()
	}
	return cat.ResolveSubagent(ctx, d.Q, ws, spec, typ, tier)
}

func subagentResultMap(j store.SubagentJob) map[string]any {
	out := map[string]any{
		"job_id":        j.ID.String(),
		"type":          j.AgentType,
		"role":          j.Role,
		"tool_calls":    j.ToolCalls,
		"input_tokens":  j.InputTokens,
		"output_tokens": j.OutputTokens,
	}
	if j.Reason != "" {
		out["reason"] = j.Reason
	}
	if j.RequestedTier != "" {
		out["requested_tier"] = j.RequestedTier
	}
	if j.Tier != "" {
		out["tier"] = j.Tier
	}
	if j.Model != "" {
		out["model"] = j.Model
	}
	if j.Effort != "" {
		out["effort"] = j.Effort
	}
	return out
}

func runSubagentTool(ctx context.Context, d Deps, c agents.Caller, in RunSubagentIn) (any, error) {
	run, spec, err := loadSubagentRun(ctx, d, c, "run_subagent")
	if err != nil {
		return nil, err
	}
	typ, tier, role, reason, prompt, err := validateSubagentTask(spec, in, "")
	if err != nil {
		return nil, err
	}
	sel := resolveSubagentModel(ctx, d, c.Agent.WorkspaceID, spec, typ, tier)

	job, err := d.Q.CreateSubagentJob(ctx, store.CreateSubagentJobParams{
		RunID:         run.ID,
		AgentType:     typ,
		Role:          role,
		Prompt:        prompt,
		Tier:          sel.Tier,
		Model:         sel.Model,
		Effort:        sel.Effort,
		RequestedTier: tier,
		Reason:        reason,
	})
	if err != nil {
		return nil, err
	}
	emitSubagentQueuedEvent(ctx, d.Q, job, 1)

	t := time.NewTicker(subagentPollInterval)
	defer t.Stop()
	for {
		j, err := d.Q.GetSubagentJob(ctx, job.ID)
		if err != nil {
			return nil, err
		}
		switch j.Status {
		case "completed":
			out := subagentResultMap(j)
			out["result"] = j.ResultText
			return out, nil
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

	// Validate every task before resolving models or inserting any jobs so a
	// malformed batch creates zero rows.
	type validTask struct {
		typ, tier, role, reason, prompt string
	}
	valid := make([]validTask, len(in.Tasks))
	for i, task := range in.Tasks {
		typ, tier, role, reason, prompt, err := validateSubagentTask(spec, task, fmt.Sprintf("tasks[%d].", i))
		if err != nil {
			return nil, err
		}
		valid[i] = validTask{typ: typ, tier: tier, role: role, reason: reason, prompt: prompt}
	}
	batchID := uuid.New()
	validated := make([]store.CreateSubagentJobParams, len(valid))
	for i, task := range valid {
		sel := resolveSubagentModel(ctx, d, c.Agent.WorkspaceID, spec, task.typ, task.tier)
		validated[i] = store.CreateSubagentJobParams{
			RunID:         run.ID,
			AgentType:     task.typ,
			Role:          task.role,
			Prompt:        task.prompt,
			Tier:          sel.Tier,
			Model:         sel.Model,
			Effort:        sel.Effort,
			RequestedTier: task.tier,
			Reason:        task.reason,
			BatchID:       &batchID,
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
		emitSubagentQueuedEvent(ctx, d.Q, job, len(validated))
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
				out := subagentResultMap(j)
				out["index"] = i
				out["status"] = j.Status
				out["result"] = j.ResultText
				results[i] = out
				done[i] = true
				remaining--
			case "failed", "canceled":
				msg := j.Error
				if msg == "" {
					msg = "subagent " + j.Status
				}
				out := subagentResultMap(j)
				out["index"] = i
				out["status"] = j.Status
				out["error"] = msg
				results[i] = out
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
	subSpec, err := runs.SubagentSpecForJob(parentSpec, job.AgentType, job.Model, job.Effort)
	if err != nil {
		return deny("Invalid subagent type")
	}
	return d.Runs.CheckToolWithSpec(ctx, c, subSpec, in)
}

package runner

import (
	"context"
	"errors"
	"fmt"
	"io"
	"maps"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const subagentWorkerPoll = 40 * time.Millisecond

// startSubagentWorker claims queued subagent_jobs for the running parent turn
// and executes up to the workspace's configured max_concurrent_subagents limit
// in parallel inside the same workspace using isolated per-job configs and
// bidirectional stdio sessions. The returned stop function cancels any running
// subagents, waits for all workers to finish, and cancels any unstarted queued jobs.
func (r *Runner) startSubagentWorker(ctx context.Context, c runCtx, ws harness.Workspace, baseEnv, sensitive map[string]string, networks []string, dir string) func() {
	wCtx, cancelAll := context.WithCancel(ctx)
	var wg sync.WaitGroup
	limit := runs.DefaultMaxConcurrentSubagents
	if cfg, err := r.q().WorkspaceRunnerSettings(ctx, c.run.WorkspaceID); err == nil {
		limit = runs.ClampConcurrentSubagents(int(cfg.MaxConcurrentSubagents))
	} else if ctx.Err() == nil {
		r.Log.Warn("load workspace runner settings for subagents", "workspace", c.run.WorkspaceID, "err", err)
	}
	sem := make(chan struct{}, limit)

	wg.Add(1)
	go func() {
		defer wg.Done()
		q := r.q()
		for {
			select {
			case sem <- struct{}{}:
			case <-wCtx.Done():
				return
			}
			job, err := q.ClaimNextSubagentJob(wCtx, c.run.ID)
			if err != nil {
				<-sem
				if !errors.Is(err, pgx.ErrNoRows) && wCtx.Err() == nil {
					r.Log.Warn("claim subagent job", "run", c.run.ID, "err", err)
				}
				if wCtx.Err() != nil {
					return
				}
				t := time.NewTimer(subagentWorkerPoll)
				select {
				case <-wCtx.Done():
					t.Stop()
					return
				case <-t.C:
				}
				continue
			}
			wg.Add(1)
			go func() {
				defer func() {
					<-sem
					wg.Done()
				}()
				r.runSubagentJob(wCtx, c, job, ws, baseEnv, sensitive, networks, dir)
			}()
		}
	}()

	return func() {
		cancelAll()
		wg.Wait()
		cctx, cancel := context.WithTimeout(context.Background(), controlTimeout)
		defer cancel()
		if err := r.q().CancelPendingSubagentJobsForRun(cctx, store.CancelPendingSubagentJobsForRunParams{
			RunID: c.run.ID,
			Error: "parent turn ended",
		}); err != nil {
			r.Log.Warn("cancel pending subagent jobs", "run", c.run.ID, "err", err)
		}
	}
}

func (r *Runner) emitSubagentLifecycle(ctx context.Context, c runCtx, sensitive map[string]string, state string, job store.SubagentJob, subSpec agentdef.Resolved, extra map[string]any) {
	pl := map[string]any{
		"state":         state,
		"subagent":      true,
		"subagent_id":   job.ID.String(),
		"subagent_type": job.AgentType,
		"created_at":    job.CreatedAt.UTC().Format(time.RFC3339Nano),
	}
	if job.Role != "" {
		pl["subagent_role"] = job.Role
	}
	if job.Reason != "" {
		pl["reason"] = job.Reason
	}
	if job.RequestedTier != "" {
		pl["requested_tier"] = job.RequestedTier
	}
	if job.Tier != "" {
		pl["subagent_tier"] = job.Tier
	}
	if subSpec.Model != "" {
		pl["subagent_model"] = subSpec.Model
	}
	if eff := subSpec.HarnessOptions["effort"]; eff != "" {
		pl["subagent_effort"] = eff
	}
	if job.BatchID != nil {
		pl["batch_id"] = job.BatchID.String()
	}
	for k, v := range extra {
		pl[k] = v
	}
	redacted, _ := redactPayload(pl, sensitive)
	r.event(ctx, c.run.ID, "lifecycle", redacted)
}

func (r *Runner) runSubagentJob(ctx context.Context, c runCtx, job store.SubagentJob, ws harness.Workspace, baseEnv, sensitive map[string]string, networks []string, dir string) {
	finCtx := context.Background()
	startedAt := time.Now()
	if job.StartedAt != nil {
		startedAt = *job.StartedAt
	}
	queuedMs := max(int64(0), startedAt.Sub(job.CreatedAt).Milliseconds())
	var subSpec agentdef.Resolved
	failJob := func(msg string, usage harness.Usage, calls int32) {
		var cost *float64
		if usage.CostSource == "harness" || usage.CostSource == "computed" {
			v := usage.CostUSD
			cost = &v
		}
		if err := r.q().FailSubagentJob(finCtx, store.FailSubagentJobParams{
			ID:           job.ID,
			Error:        msg,
			InputTokens:  usage.InputTokens,
			OutputTokens: usage.OutputTokens,
			CachedTokens: usage.CachedTokens,
			CostUsd:      cost,
			ToolCalls:    calls,
		}); err != nil {
			r.Log.Warn("fail subagent job", "job", job.ID, "err", err)
		}
		extra := map[string]any{
			"status":        "failed",
			"error":         msg,
			"tool_calls":    calls,
			"input_tokens":  usage.InputTokens,
			"output_tokens": usage.OutputTokens,
			"cached_tokens": usage.CachedTokens,
			"queued_ms":     queuedMs,
			"duration_ms":   max(int64(0), time.Since(startedAt).Milliseconds()),
		}
		if cost != nil {
			extra["cost_usd"] = *cost
		}
		r.emitSubagentLifecycle(finCtx, c, sensitive, "subagent_finished", job, subSpec, extra)
		r.recordSubagentUsage(finCtx, c.run.ID, usage, calls)
	}

	var err error
	subSpec, err = runs.SubagentSpecForJob(c.spec, job.AgentType, job.Model, job.Effort)
	if err != nil {
		failJob(err.Error(), harness.Usage{}, 0)
		return
	}
	scopeNote := "You are running as an isolated Vesper " + job.AgentType + " subagent with no Vesper MCP tools. " +
		"Ignore parent Vesper chat or ticket workflow rules in AGENTS.md and .agents/rules/vesper-*.md " +
		"(such as claim_ticket, post_plan, complete_run, run_subagent, run_subagents, memory, or opening-line rules); " +
		"follow only the role instructions and task below plus the repository's own coding conventions."
	sysAppend := agentdef.HelperPrompt
	if job.AgentType == agentdef.ExplorerAgent {
		sysAppend = agentdef.ExplorerPrompt
	}
	if job.Role != "" {
		sysAppend = "Role: " + job.Role + "\n\n" + sysAppend
	}
	sysAppend = scopeNote + "\n\n" + sysAppend

	h, err := harness.For(subSpec.Harness)
	if err != nil {
		failJob(err.Error(), harness.Usage{}, 0)
		return
	}
	if subSpec.Harness == agentdef.HarnessCodex {
		h = harness.Codex{Prices: r.Cfg.ModelPrices}
	}
	sh, ok := h.(harness.SessionHarness)
	if !ok {
		failJob("subagent harness does not support bidirectional sessions", harness.Usage{}, 0)
		return
	}

	subTurn := harness.Turn{
		Spec:         subSpec,
		Prompt:       job.Prompt,
		SystemAppend: sysAppend,
		ConfigTag:    "subagent-" + job.ID.String(),
	}
	inv, err := sh.SessionInvocation(ws, subTurn)
	if err != nil {
		failJob(err.Error(), harness.Usage{}, 0)
		return
	}
	env := maps.Clone(baseEnv)
	if env == nil {
		env = map[string]string{}
	}
	for k, v := range inv.Env {
		env[k] = v
	}
	env["LAZYAGENTS_SUBAGENT_JOB_ID"] = job.ID.String()

	proc, err := r.Backend.Start(ctx, wsID(c.run), ExecSpec{
		Name:     fmt.Sprintf("lazyagents-subagent-%s", job.ID.String()[:8]),
		Argv:     inv.Argv,
		Env:      env,
		Dir:      dir,
		Files:    inv.Files,
		Networks: networks,
	})
	if err != nil {
		failJob("couldn't start subagent: "+err.Error(), harness.Usage{}, 0)
		return
	}
	r.emitSubagentLifecycle(ctx, c, sensitive, "subagent_started", job, subSpec, map[string]any{
		"queued_ms":  queuedMs,
		"started_at": startedAt.UTC().Format(time.RFC3339Nano),
	})

	var ctrlMu sync.Mutex
	var ctrl harness.SessionControl
	done := make(chan struct{})
	var killOnce sync.Once
	go func() {
		select {
		case <-ctx.Done():
			ctrlMu.Lock()
			sc := ctrl
			ctrlMu.Unlock()
			if sc != nil {
				_ = sc.Interrupt()
			}
			killOnce.Do(func() { _ = proc.Kill() })
		case <-done:
		}
	}()

	var stderr captureWriter
	var res harness.Result
	var sessErr error
	var observedCalls int32
	var readers sync.WaitGroup
	readers.Add(2)
	go func() {
		defer readers.Done()
		_, _ = io.Copy(&stderr, proc.Stderr())
	}()
	go func() {
		defer readers.Done()
		res, sessErr = sh.RunSession(ctx, proc.Stdin(), proc.Stdout(), ws, subTurn, harness.SessionCallbacks{
			OnEvent: func(e harness.Event) {
				if e.Type != "tool_call" && e.Type != "tool_result" {
					return
				}
				if e.Type == "tool_call" {
					observedCalls++
				}
				pl := maps.Clone(e.Payload)
				if pl == nil {
					pl = map[string]any{}
				}
				pl["subagent"] = true
				pl["subagent_id"] = job.ID.String()
				pl["subagent_type"] = job.AgentType
				if job.Role != "" {
					pl["subagent_role"] = job.Role
				}
				if job.Tier != "" {
					pl["subagent_tier"] = job.Tier
				}
				if subSpec.Model != "" {
					pl["subagent_model"] = subSpec.Model
				}
				if eff := subSpec.HarnessOptions["effort"]; eff != "" {
					pl["subagent_effort"] = eff
				}
				if job.BatchID != nil {
					pl["batch_id"] = job.BatchID.String()
				}
				redacted, _ := redactPayload(pl, sensitive)
				r.event(ctx, c.run.ID, e.Type, redacted)
			},
			OnControl: func(sc harness.SessionControl) {
				ctrlMu.Lock()
				ctrl = sc
				ctrlMu.Unlock()
			},
			CheckTool: r.policyCheckWithSpec(c, subSpec),
		})
		_, _ = io.Copy(io.Discard, proc.Stdout())
	}()

	code, waitErr := proc.Wait()
	close(done)
	drainErr := drainProcess(proc, &readers, nil)

	calls := max(observedCalls, int32(res.Usage.ToolCalls))
	if ctx.Err() != nil {
		r.recordSubagentUsage(finCtx, c.run.ID, res.Usage, calls)
		return
	}
	if runErr := errors.Join(waitErr, drainErr, sessErr); runErr != nil || code != 0 || res.IsError {
		msg := res.Error
		if msg == "" && runErr != nil {
			msg = runErr.Error()
		}
		if msg == "" && code != 0 {
			msg = fmt.Sprintf("subagent exited %d: %s", code, lastLines(redact(stderr.String(), sensitive), 8))
		}
		if msg == "" {
			msg = "subagent failed"
		}
		failJob(msg, res.Usage, calls)
		return
	}

	var cost *float64
	if res.Usage.CostSource == "harness" || res.Usage.CostSource == "computed" {
		v := res.Usage.CostUSD
		cost = &v
	}
	if err := r.q().CompleteSubagentJob(finCtx, store.CompleteSubagentJobParams{
		ID:           job.ID,
		ResultText:   res.Final,
		InputTokens:  res.Usage.InputTokens,
		OutputTokens: res.Usage.OutputTokens,
		CachedTokens: res.Usage.CachedTokens,
		CostUsd:      cost,
		ToolCalls:    calls,
	}); err != nil {
		r.Log.Warn("complete subagent job", "job", job.ID, "err", err)
	}
	extra := map[string]any{
		"status":        "completed",
		"tool_calls":    calls,
		"input_tokens":  res.Usage.InputTokens,
		"output_tokens": res.Usage.OutputTokens,
		"cached_tokens": res.Usage.CachedTokens,
		"queued_ms":     queuedMs,
		"duration_ms":   max(int64(0), time.Since(startedAt).Milliseconds()),
	}
	if cost != nil {
		extra["cost_usd"] = *cost
	}
	r.emitSubagentLifecycle(finCtx, c, sensitive, "subagent_finished", job, subSpec, extra)
	r.recordSubagentUsage(finCtx, c.run.ID, res.Usage, calls)
}

func (r *Runner) recordSubagentUsage(ctx context.Context, runID uuid.UUID, usage harness.Usage, calls int32) {
	if usage == (harness.Usage{}) && calls == 0 {
		return
	}
	var src *string
	if usage.CostSource != "" {
		s := usage.CostSource
		src = &s
	}
	if _, err := r.q().AddRunUsage(ctx, store.AddRunUsageParams{
		ID:            runID,
		ToolCalls:     calls,
		InputTokens:   usage.InputTokens,
		OutputTokens:  usage.OutputTokens,
		CostUsdMicros: int64(usage.CostUSD * 1e6),
		CostSource:    src,
	}); err != nil {
		r.Log.Warn("record subagent usage", "run", runID, "err", err)
	}
}

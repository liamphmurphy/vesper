package agentapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// delegate hands work to a fresh copy of the caller: there's no roster to pick
// from, and read_only gives a copy without repo:write.
func TestDelegateToolStartsACopy(t *testing.T) {
	if _, ok := ByName["list_subagents"]; ok {
		t.Fatal("list_subagents is still a tool")
	}
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Poll: 20 * time.Millisecond}
	out, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	parent := out[0]
	vol := parent.ID.String()
	if err := q.SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: parent.ID, WorkspaceVolume: &vol}); err != nil {
		t.Fatal(err)
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	exp := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &parent.ID, nil, &exp)
	if err != nil {
		t.Fatal(err)
	}
	c, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	res, err := ByName["delegate"].call(ctx, Deps{Q: q, Runs: svc}, c, json.RawMessage(`{"task":"Review the diff","read_only":true}`))
	if err != nil {
		t.Fatal(err)
	}
	got := res.(map[string]any)
	if got["state"] != "delegated" || got["agent"] != "atlas" || got["read_only"] != true {
		t.Fatalf("delegate = %v", got)
	}
	child, err := q.GetRun(ctx, store.GetRunParams{ID: got["run_id"].(uuid.UUID), WorkspaceID: ws})
	if err != nil {
		t.Fatal(err)
	}
	spec, _ := runs.Spec(child)
	if child.AgentID != atlas.ID || child.ParentRunID == nil || *child.ParentRunID != parent.ID || spec.Mode("repo:write") != agentdef.Denied {
		t.Fatalf("child %+v, repo:write %v", child, spec.Mode("repo:write"))
	}
}

func TestRunSubagentToolLifecycleAndValidation(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Poll: 20 * time.Millisecond}
	out, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	run := out[0]
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	exp := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &run.ID, nil, &exp)
	if err != nil {
		t.Fatal(err)
	}
	c, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	deps := Deps{Q: q, Runs: svc}
	call := ByName["run_subagent"].call

	// Requires a running turn.
	if _, err := call(ctx, deps, agents.Caller{Agent: atlas, Kind: "unmanaged"}, json.RawMessage(`{"type":"explorer","prompt":"find"}`)); err == nil {
		t.Fatal("expected error without run id")
	}
	// Empty prompt, unknown type, & unknown tier rejected.
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"explorer","prompt":"   "}`)); err == nil || !strings.Contains(err.Error(), "prompt") {
		t.Fatalf("empty prompt err = %v", err)
	}
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"bogus","prompt":"hi"}`)); err == nil || !strings.Contains(err.Error(), "unknown subagent type") {
		t.Fatalf("bad type err = %v", err)
	}
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"helper","tier":"ultra","prompt":"hi"}`)); err == nil || !strings.Contains(err.Error(), "unknown subagent tier") {
		t.Fatalf("bad tier err = %v", err)
	}

	// OptionExplorer="false" blocks explorer; OptionSubagents="false" blocks all.
	origSpec, err := runs.Spec(run)
	if err != nil {
		t.Fatal(err)
	}
	setSpecOpt := func(k, v string) {
		t.Helper()
		s := origSpec
		s.HarnessOptions = map[string]string{}
		for ok, ov := range origSpec.HarnessOptions {
			s.HarnessOptions[ok] = ov
		}
		if v == "" {
			delete(s.HarnessOptions, k)
		} else {
			s.HarnessOptions[k] = v
		}
		b, _ := json.Marshal(s)
		if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$1 WHERE id=$2", b, run.ID); err != nil {
			t.Fatal(err)
		}
	}
	setSpecOpt(agentdef.OptionExplorer, "false")
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"explorer","prompt":"find"}`)); err == nil || !strings.Contains(err.Error(), "explorer subagent is disabled") {
		t.Fatalf("explorer off err = %v", err)
	}
	setSpecOpt(agentdef.OptionSubagents, "false")
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"helper","prompt":"do"}`)); err == nil || !strings.Contains(err.Error(), "subagents are disabled") {
		t.Fatalf("subagents off err = %v", err)
	}
	setSpecOpt("", "")

	// Happy path: background worker claims & completes the queued job.
	done := make(chan error, 1)
	go func() {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			j, err := q.ClaimNextSubagentJob(ctx, run.ID)
			if err != nil {
				time.Sleep(15 * time.Millisecond)
				continue
			}
			done <- q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{
				ID:           j.ID,
				ResultText:   "found in main.go",
				InputTokens:  120,
				OutputTokens: 30,
				CachedTokens: 50,
				ToolCalls:    2,
			})
			return
		}
		done <- context.DeadlineExceeded
	}()
	res, err := call(ctx, deps, c, json.RawMessage(`{"type":"explorer","role":"Code Seeker","prompt":"find main"}`))
	if err != nil {
		t.Fatalf("run_subagent: %v", err)
	}
	if wErr := <-done; wErr != nil {
		t.Fatalf("worker: %v", wErr)
	}
	got := res.(map[string]any)
	if got["type"] != "explorer" || got["role"] != "Code Seeker" || got["result"] != "found in main.go" ||
		got["tool_calls"] != int32(2) || got["input_tokens"] != int64(120) || got["output_tokens"] != int64(30) || got["job_id"] == "" {
		t.Fatalf("run_subagent result = %#v", got)
	}

	// Failure path: worker fails the job -> run_subagent surfaces conflict error.
	go func() {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			j, err := q.ClaimNextSubagentJob(ctx, run.ID)
			if err != nil {
				time.Sleep(15 * time.Millisecond)
				continue
			}
			_ = q.FailSubagentJob(ctx, store.FailSubagentJobParams{ID: j.ID, Error: "boom"})
			return
		}
	}()
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"helper","prompt":"fail"}`)); err == nil || !strings.Contains(err.Error(), "subagent failed: boom") {
		t.Fatalf("failed job err = %v", err)
	}
}

func TestRunSubagentsToolBatchLifecycle(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Poll: 20 * time.Millisecond}
	out, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	run := out[0]
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	exp := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &run.ID, nil, &exp)
	if err != nil {
		t.Fatal(err)
	}
	c, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	deps := Deps{Q: q, Runs: svc}
	call := ByName["run_subagents"].call

	assertJobCount := func(want int) {
		t.Helper()
		jobs, err := q.ListSubagentJobsForRun(ctx, run.ID)
		if err != nil || len(jobs) != want {
			t.Fatalf("jobs = %d (%v), want %d", len(jobs), err, want)
		}
	}

	// Requires a running turn.
	if _, err := call(ctx, deps, agents.Caller{Agent: atlas, Kind: "unmanaged"}, json.RawMessage(`{"tasks":[{"type":"explorer","prompt":"find"}]}`)); err == nil {
		t.Fatal("expected error without run id")
	}
	// Empty tasks rejected without creating jobs.
	if _, err := call(ctx, deps, c, json.RawMessage(`{"tasks":[]}`)); err == nil || !strings.Contains(err.Error(), "at least one task") {
		t.Fatalf("empty tasks err = %v", err)
	}
	// Batch exceeding maxSubagentBatch rejected without creating jobs.
	tooMany := make([]RunSubagentIn, maxSubagentBatch+1)
	for i := range tooMany {
		tooMany[i] = RunSubagentIn{Type: agentdef.ExplorerAgent, Prompt: "find"}
	}
	tooManyRaw, _ := json.Marshal(RunSubagentsIn{Tasks: tooMany})
	if _, err := call(ctx, deps, c, tooManyRaw); err == nil || !strings.Contains(err.Error(), "at most") {
		t.Fatalf("too many tasks err = %v", err)
	}
	// Invalid task in batch (bad type, bad tier, or empty prompt) -> zero rows inserted.
	if _, err := call(ctx, deps, c, json.RawMessage(`{"tasks":[{"type":"explorer","prompt":"ok"},{"type":"bogus","prompt":"bad"}]}`)); err == nil || !strings.Contains(err.Error(), "unknown subagent type") {
		t.Fatalf("invalid type err = %v", err)
	}
	if _, err := call(ctx, deps, c, json.RawMessage(`{"tasks":[{"type":"helper","prompt":"ok"},{"type":"helper","tier":"max","prompt":"bad"}]}`)); err == nil || !strings.Contains(err.Error(), "unknown subagent tier") {
		t.Fatalf("invalid tier err = %v", err)
	}
	if _, err := call(ctx, deps, c, json.RawMessage(`{"tasks":[{"type":"helper","prompt":"ok"},{"type":"explorer","prompt":"   "}]}`)); err == nil || !strings.Contains(err.Error(), "prompt") {
		t.Fatalf("empty prompt err = %v", err)
	}
	assertJobCount(0)

	// Out-of-order completion: all 3 jobs must be enqueued before any completes,
	// and results must be returned in input order (0, 1, 2).
	batch1Done := make(chan error, 1)
	go func() {
		deadline := time.Now().Add(5 * time.Second)
		var claimed []store.SubagentJob
		for len(claimed) < 3 {
			if time.Now().After(deadline) {
				batch1Done <- context.DeadlineExceeded
				return
			}
			j, err := q.ClaimNextSubagentJob(ctx, run.ID)
			if err != nil {
				time.Sleep(15 * time.Millisecond)
				continue
			}
			claimed = append(claimed, j)
		}
		// Complete in reverse order: index 2 -> 0 -> 1.
		for _, idx := range []int{2, 0, 1} {
			j := claimed[idx]
			if err := q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{
				ID:           j.ID,
				ResultText:   "done:" + j.Prompt,
				InputTokens:  int64(100 + idx),
				OutputTokens: int64(20 + idx),
				ToolCalls:    int32(idx + 1),
			}); err != nil {
				batch1Done <- err
				return
			}
		}
		batch1Done <- nil
	}()
	res, err := call(ctx, deps, c, json.RawMessage(`{"tasks":[
		{"type":"explorer","role":"First","prompt":"p0"},
		{"type":"helper","role":"Second","prompt":"p1"},
		{"type":"explorer","role":"Third","prompt":"p2"}
	]}`))
	if err != nil {
		t.Fatalf("run_subagents out-of-order: %v", err)
	}
	if wErr := <-batch1Done; wErr != nil {
		t.Fatalf("batch1 worker: %v", wErr)
	}
	gotResults := res.(map[string]any)["results"].([]map[string]any)
	if len(gotResults) != 3 {
		t.Fatalf("results len = %d, want 3", len(gotResults))
	}
	for i, wantPrompt := range []string{"p0", "p1", "p2"} {
		r := gotResults[i]
		if r["index"] != i || r["status"] != "completed" || r["result"] != "done:"+wantPrompt || r["job_id"] == "" {
			t.Fatalf("result[%d] = %#v, want index=%d status=completed result=done:%s", i, r, i, wantPrompt)
		}
	}

	// Partial failure: one job completes while another fails -> both returned in input order without failing the tool call.
	partialDone := make(chan error, 1)
	go func() {
		deadline := time.Now().Add(5 * time.Second)
		var claimed []store.SubagentJob
		for len(claimed) < 2 {
			if time.Now().After(deadline) {
				partialDone <- context.DeadlineExceeded
				return
			}
			j, err := q.ClaimNextSubagentJob(ctx, run.ID)
			if err != nil {
				time.Sleep(15 * time.Millisecond)
				continue
			}
			claimed = append(claimed, j)
		}
		if err := q.FailSubagentJob(ctx, store.FailSubagentJobParams{
			ID:           claimed[1].ID,
			Error:        "compile failed",
			InputTokens:  500,
			OutputTokens: 100,
			ToolCalls:    3,
		}); err != nil {
			partialDone <- err
			return
		}
		if err := q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{
			ID:           claimed[0].ID,
			ResultText:   "all good",
			InputTokens:  1000,
			OutputTokens: 400,
			ToolCalls:    12,
		}); err != nil {
			partialDone <- err
			return
		}
		partialDone <- nil
	}()
	partialRes, err := call(ctx, deps, c, json.RawMessage(`{"tasks":[
		{"type":"helper","role":"Passer","prompt":"succeed"},
		{"type":"helper","role":"Failer","prompt":"explode"}
	]}`))
	if err != nil {
		t.Fatalf("partial failure should return results, got err: %v", err)
	}
	if wErr := <-partialDone; wErr != nil {
		t.Fatalf("partial worker: %v", wErr)
	}
	pr := partialRes.(map[string]any)["results"].([]map[string]any)
	if len(pr) != 2 || pr[0]["status"] != "completed" || pr[0]["result"] != "all good" || pr[0]["tool_calls"] != int32(12) ||
		pr[1]["status"] != "failed" || pr[1]["error"] != "compile failed" || pr[1]["tool_calls"] != int32(3) {
		t.Fatalf("partial results = %#v", pr)
	}

	// Context cancellation while waiting returns ctx.Err().
	cancelCtx, cancel := context.WithCancel(ctx)
	go func() {
		time.Sleep(150 * time.Millisecond)
		cancel()
	}()
	if _, err := call(cancelCtx, deps, c, json.RawMessage(`{"tasks":[{"type":"explorer","prompt":"hang"}]}`)); err != context.Canceled {
		t.Fatalf("canceled batch err = %v, want context.Canceled", err)
	}
}

func TestRunSubagentTierPersistenceAndCeiling(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{
		Pool:    pool,
		Tracker: &tracker.Service{Pool: pool},
		Poll:    20 * time.Millisecond,
		ModelDiscovery: func(_ context.Context, h, _ string) ([]chatmodels.Model, error) {
			if h == agentdef.HarnessClaudeCode {
				return []chatmodels.Model{
					{ID: "fable", Label: "Fable 5.2", Efforts: agentdef.Efforts},
					{ID: "sonnet", Label: "Sonnet 5.5", Default: true, Efforts: agentdef.Efforts},
					{ID: "haiku", Label: "Haiku 5.5"},
				}, nil
			}
			return nil, nil
		},
	}
	out, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	run := out[0]
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	// Configure parent run as a standard Claude Sonnet parent with high effort.
	spec, err := runs.Spec(run)
	if err != nil {
		t.Fatal(err)
	}
	spec.Harness = agentdef.HarnessClaudeCode
	spec.Model = "sonnet"
	if spec.HarnessOptions == nil {
		spec.HarnessOptions = map[string]string{}
	}
	spec.HarnessOptions["effort"] = "high"
	rawSpec, _ := json.Marshal(spec)
	if _, err := pool.Exec(ctx, "UPDATE runs SET resolved_spec=$1 WHERE id=$2", rawSpec, run.ID); err != nil {
		t.Fatal(err)
	}

	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	exp := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &run.ID, nil, &exp)
	if err != nil {
		t.Fatal(err)
	}
	c, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	deps := Deps{Q: q, Runs: svc}

	// 1. Default workspace mode: effort-only scaling on the parent model (no cross-model switch).
	doneEffortOnly := make(chan store.SubagentJob, 1)
	go func() {
		for {
			if j, err := q.ClaimNextSubagentJob(ctx, run.ID); err == nil {
				_ = q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{ID: j.ID, ResultText: "ok"})
				doneEffortOnly <- j
				return
			}
			time.Sleep(15 * time.Millisecond)
		}
	}()
	effortRes, err := ByName["run_subagent"].call(ctx, deps, c, json.RawMessage(`{"type":"helper","tier":"fast","role":"Quick Search","reason":"Read callers before editing.","prompt":"search"}`))
	if err != nil {
		t.Fatalf("default effort-only run_subagent: %v", err)
	}
	effortJob := <-doneEffortOnly
	if effortJob.Tier != "fast" || effortJob.RequestedTier != "fast" || effortJob.Model != "sonnet" || effortJob.Effort != "low" {
		t.Fatalf("default effort-only job = %+v, want tier=fast model=sonnet effort=low", effortJob)
	}
	if er := effortRes.(map[string]any); er["model"] != "sonnet" || er["effort"] != "low" || er["tier"] != "fast" {
		t.Fatalf("default effort-only output = %#v", er)
	}

	// 2. Configure a per-harness Claude ladder: deep requests on a sonnet parent cap at standard (sonnet, medium).
	if err := q.SetWorkspaceRunnerSettings(ctx, store.SetWorkspaceRunnerSettingsParams{
		ID:                 ws,
		SubagentTierModels: json.RawMessage(`{"claude-code":{"fast":"haiku","standard":"sonnet","deep":"fable"}}`),
	}); err != nil {
		t.Fatalf("SetWorkspaceRunnerSettings ladder: %v", err)
	}

	// Single call requesting deep on a standard parent is capped at standard (sonnet, medium).
	doneSingle := make(chan store.SubagentJob, 1)
	go func() {
		for {
			if j, err := q.ClaimNextSubagentJob(ctx, run.ID); err == nil {
				_ = q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{ID: j.ID, ResultText: "ok"})
				doneSingle <- j
				return
			}
			time.Sleep(15 * time.Millisecond)
		}
	}()
	singleRes, err := ByName["run_subagent"].call(ctx, deps, c, json.RawMessage(`{"type":"helper","tier":"deep","role":"Hard Task","reason":"Check lock ordering across stores.","prompt":"debug"}`))
	if err != nil {
		t.Fatalf("run_subagent: %v", err)
	}
	singleJob := <-doneSingle
	if singleJob.Tier != "standard" || singleJob.RequestedTier != "deep" || singleJob.Model != "sonnet" || singleJob.Effort != "medium" ||
		singleJob.Reason != "Check lock ordering across stores." || singleJob.BatchID != nil {
		t.Fatalf("persisted single job = %+v", singleJob)
	}
	sg := singleRes.(map[string]any)
	if sg["tier"] != "standard" || sg["requested_tier"] != "deep" || sg["model"] != "sonnet" || sg["effort"] != "medium" ||
		sg["reason"] != "Check lock ordering across stores." {
		t.Fatalf("single tool output = %#v", sg)
	}

	// Batch call with fast + deep (capped to standard): persists per-task tiers/models, shared batch_id, and reason, plus subagent_queued lifecycle events.
	doneBatch := make(chan []store.SubagentJob, 1)
	go func() {
		var claimed []store.SubagentJob
		for len(claimed) < 2 {
			if j, err := q.ClaimNextSubagentJob(ctx, run.ID); err == nil {
				_ = q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{ID: j.ID, ResultText: "done:" + j.Prompt})
				claimed = append(claimed, j)
				continue
			}
			time.Sleep(15 * time.Millisecond)
		}
		doneBatch <- claimed
	}()
	batchRes, err := ByName["run_subagents"].call(ctx, deps, c, json.RawMessage(`{"tasks":[
		{"type":"helper","role":"Quick Check","reason":"Fast check with omitted tier.","prompt":"t0"},
		{"type":"helper","tier":"deep","role":"Capped Deep","reason":"Complex reasoning attempt.","prompt":"t1"}
	]}`))
	if err != nil {
		t.Fatalf("run_subagents: %v", err)
	}
	batchJobs := <-doneBatch
	if batchJobs[0].Tier != "standard" || batchJobs[0].RequestedTier != "" || batchJobs[0].Model != "sonnet" ||
		batchJobs[0].Reason != "Fast check with omitted tier." || batchJobs[0].BatchID == nil {
		t.Fatalf("batch job[0] = %+v", batchJobs[0])
	}
	if batchJobs[1].Tier != "standard" || batchJobs[1].RequestedTier != "deep" || batchJobs[1].Model != "sonnet" || batchJobs[1].Effort != "medium" ||
		batchJobs[1].Reason != "Complex reasoning attempt." || batchJobs[1].BatchID == nil || *batchJobs[1].BatchID != *batchJobs[0].BatchID {
		t.Fatalf("batch job[1] = %+v", batchJobs[1])
	}
	br := batchRes.(map[string]any)["results"].([]map[string]any)
	if br[0]["tier"] != "standard" || br[0]["requested_tier"] != nil || br[0]["reason"] != "Fast check with omitted tier." ||
		br[1]["tier"] != "standard" || br[1]["requested_tier"] != "deep" || br[1]["model"] != "sonnet" || br[1]["effort"] != "medium" ||
		br[1]["reason"] != "Complex reasoning attempt." {
		t.Fatalf("batch results = %#v", br)
	}

	// 3. Turning subagent_tier_routing off restores exact pre-tier behavior: helper inherits parent model/effort verbatim,
	// explorer uses DefaultExplorerModel, and tier/requested_tier remain empty.
	off := false
	if err := q.SetWorkspaceRunnerSettings(ctx, store.SetWorkspaceRunnerSettingsParams{
		ID:                  ws,
		SubagentTierRouting: &off,
	}); err != nil {
		t.Fatalf("SetWorkspaceRunnerSettings off: %v", err)
	}
	doneLegacy := make(chan []store.SubagentJob, 1)
	go func() {
		var claimed []store.SubagentJob
		for len(claimed) < 2 {
			if j, err := q.ClaimNextSubagentJob(ctx, run.ID); err == nil {
				_ = q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{ID: j.ID, ResultText: "legacy:" + j.AgentType})
				claimed = append(claimed, j)
				continue
			}
			time.Sleep(15 * time.Millisecond)
		}
		doneLegacy <- claimed
	}()
	legacyRes, err := ByName["run_subagents"].call(ctx, deps, c, json.RawMessage(`{"tasks":[
		{"type":"explorer","tier":"deep","role":"Explorer","reason":"Check explorer legacy default.","prompt":"l0"},
		{"type":"helper","tier":"fast","role":"Helper","reason":"Check helper legacy inheritance.","prompt":"l1"}
	]}`))
	if err != nil {
		t.Fatalf("legacy off run_subagents: %v", err)
	}
	legacyJobs := <-doneLegacy
	if legacyJobs[0].Tier != "" || legacyJobs[0].RequestedTier != "" || legacyJobs[0].Model != agentdef.DefaultExplorerModel || legacyJobs[0].Effort != "" {
		t.Fatalf("legacy off explorer job = %+v", legacyJobs[0])
	}
	if legacyJobs[1].Tier != "" || legacyJobs[1].RequestedTier != "" || legacyJobs[1].Model != "sonnet" || legacyJobs[1].Effort != "high" {
		t.Fatalf("legacy off helper job = %+v", legacyJobs[1])
	}
	lr := legacyRes.(map[string]any)["results"].([]map[string]any)
	if lr[0]["tier"] != nil || lr[0]["requested_tier"] != nil || lr[1]["tier"] != nil || lr[1]["requested_tier"] != nil {
		t.Fatalf("legacy off tool results should omit tier/requested_tier: %#v", lr)
	}

	evs, err := q.ListRunEvents(ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
	if err != nil {
		t.Fatal(err)
	}
	queuedByID := map[string]map[string]any{}
	for _, ev := range evs {
		if ev.Type != "lifecycle" {
			continue
		}
		var pl map[string]any
		if json.Unmarshal(ev.Payload, &pl) == nil && pl["state"] == "subagent_queued" {
			id, _ := pl["subagent_id"].(string)
			queuedByID[id] = pl
		}
	}
	if len(queuedByID) != 6 {
		t.Fatalf("subagent_queued events = %d, want 6", len(queuedByID))
	}
	qSingle := queuedByID[singleJob.ID.String()]
	if qSingle["reason"] != "Check lock ordering across stores." || qSingle["requested_tier"] != "deep" ||
		qSingle["subagent_tier"] != "standard" || qSingle["subagent_model"] != "sonnet" || qSingle["batch_id"] != nil {
		t.Fatalf("single subagent_queued payload = %#v", qSingle)
	}
	qBatch := queuedByID[batchJobs[1].ID.String()]
	if qBatch["batch_id"] != batchJobs[0].BatchID.String() || qBatch["batch_size"] != float64(2) {
		t.Fatalf("batch subagent_queued payload = %#v", qBatch)
	}
}

func TestToolPolicySubagentJobHeader(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	svc := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Poll: 20 * time.Millisecond}
	out, err := svc.Dispatch(ctx, ws, me.ID, []string{"PAY-214", "PAY-224"})
	if err != nil {
		t.Fatal(err)
	}
	runA, runB := out[0], out[1]
	for _, id := range []uuid.UUID{runA.ID, runB.ID} {
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: id, State: "running"}); err != nil {
			t.Fatal(err)
		}
	}
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	exp := time.Now().Add(time.Hour)
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "run", "", &runA.ID, nil, &exp)
	if err != nil {
		t.Fatal(err)
	}
	h := RESTHandler(Deps{Q: q, Runs: svc})
	postPolicy := func(jobHeader, tool string, input map[string]any) runs.ToolDecision {
		t.Helper()
		body, _ := json.Marshal(runs.ToolCheck{Tool: tool, Input: input})
		req := httptest.NewRequest(http.MethodPost, "/api/v1/agent/tool-policy", bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer "+tok)
		req.Header.Set("Content-Type", "application/json")
		if jobHeader != "" {
			req.Header.Set("X-Vesper-Subagent-Job", jobHeader)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("status=%d body=%s", rec.Code, rec.Body.String())
		}
		var dec runs.ToolDecision
		if err := json.Unmarshal(rec.Body.Bytes(), &dec); err != nil {
			t.Fatalf("decode %q: %v", rec.Body.String(), err)
		}
		return dec
	}

	exJob, err := q.CreateSubagentJob(ctx, store.CreateSubagentJobParams{RunID: runA.ID, AgentType: agentdef.ExplorerAgent, Role: "Reader", Prompt: "read"})
	if err != nil {
		t.Fatal(err)
	}
	// Queued (not running yet) fails closed.
	if d := postPolicy(exJob.ID.String(), "Read", map[string]any{"file_path": "a.go"}); d.Decision != "deny" {
		t.Fatalf("queued job Read = %+v, want deny", d)
	}
	// Claimed explorer allows Read, denies Write and Bash.
	if _, err := q.ClaimNextSubagentJob(ctx, runA.ID); err != nil {
		t.Fatal(err)
	}
	if d := postPolicy(exJob.ID.String(), "Read", map[string]any{"file_path": "a.go"}); d.Decision != "allow" {
		t.Fatalf("running explorer Read = %+v", d)
	}
	if d := postPolicy(exJob.ID.String(), "Write", map[string]any{"file_path": "a.go"}); d.Decision != "deny" {
		t.Fatalf("running explorer Write = %+v", d)
	}
	if d := postPolicy(exJob.ID.String(), "Bash", map[string]any{"command": "ls"}); d.Decision != "allow" {
		t.Fatalf("running explorer read-only Bash (ls) = %+v", d)
	}
	if d := postPolicy(exJob.ID.String(), "Bash", map[string]any{"command": "go test ./..."}); d.Decision != "deny" {
		t.Fatalf("running explorer Bash (go test) = %+v", d)
	}
	// Completed fails closed.
	if err := q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{ID: exJob.ID, ResultText: "ok"}); err != nil {
		t.Fatal(err)
	}
	if d := postPolicy(exJob.ID.String(), "Read", map[string]any{"file_path": "a.go"}); d.Decision != "deny" {
		t.Fatalf("completed explorer Read = %+v", d)
	}

	// Claimed helper inherits workspace write permissions.
	hJob, err := q.CreateSubagentJob(ctx, store.CreateSubagentJobParams{RunID: runA.ID, AgentType: agentdef.HelperAgent, Role: "Writer", Prompt: "write"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.ClaimNextSubagentJob(ctx, runA.ID); err != nil {
		t.Fatal(err)
	}
	if d := postPolicy(hJob.ID.String(), "Write", map[string]any{"file_path": "a.go"}); d.Decision != "allow" {
		t.Fatalf("running helper Write = %+v", d)
	}

	// Invalid UUID, unknown ID, and another run's running job all fail closed.
	otherJob, err := q.CreateSubagentJob(ctx, store.CreateSubagentJobParams{RunID: runB.ID, AgentType: agentdef.HelperAgent, Role: "Other", Prompt: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.ClaimNextSubagentJob(ctx, runB.ID); err != nil {
		t.Fatal(err)
	}
	for name, hdr := range map[string]string{
		"invalid uuid":  "not-a-uuid",
		"unknown uuid":  uuid.NewString(),
		"other run job": otherJob.ID.String(),
	} {
		if d := postPolicy(hdr, "Read", map[string]any{"file_path": "a.go"}); d.Decision != "deny" {
			t.Fatalf("%s Read = %+v, want deny", name, d)
		}
	}
}

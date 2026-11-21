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
	// Empty prompt & unknown type rejected.
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"explorer","prompt":"   "}`)); err == nil || !strings.Contains(err.Error(), "prompt") {
		t.Fatalf("empty prompt err = %v", err)
	}
	if _, err := call(ctx, deps, c, json.RawMessage(`{"type":"bogus","prompt":"hi"}`)); err == nil || !strings.Contains(err.Error(), "unknown subagent type") {
		t.Fatalf("bad type err = %v", err)
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

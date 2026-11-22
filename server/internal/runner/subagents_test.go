package runner_test

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestSubagentCrossHarnessE2E(t *testing.T) {
	for _, tc := range []struct {
		harness string
		model   string
	}{
		{agentdef.HarnessClaudeCode, "sonnet-5.5"},
		{agentdef.HarnessCodex, "gpt-5-codex"},
		{agentdef.HarnessAntigravity, "gemini-3.8-flash"},
	} {
		t.Run(tc.harness, func(t *testing.T) {
			e := setup(t)
			holdFile := filepath.Join(t.TempDir(), "release")
			calls, err := json.Marshal([]map[string]string{
				{"type": agentdef.ExplorerAgent, "role": "Scope Reader", "prompt": "TRY_WRITE"},
				{"type": agentdef.HelperAgent, "role": "Workspace Writer", "prompt": "DO_WRITE"},
				{"type": agentdef.ExplorerAgent, "role": "Hold Inspector", "prompt": "HOLD=" + holdFile},
			})
			if err != nil {
				t.Fatal(err)
			}
			svc := &agents.Service{Pool: e.pool}
			p, err := e.q.GetProjectByKey(e.ctx, store.GetProjectByKeyParams{WorkspaceID: e.ws, Key: "PAY"})
			if err != nil {
				t.Fatal(err)
			}
			row, err := e.q.GetOverride(e.ctx, store.GetOverrideParams{AgentID: e.atlas.ID, ProjectID: p.ID})
			if err != nil {
				t.Fatal(err)
			}
			ov, err := agents.DecodeOverride(row.Spec)
			if err != nil {
				t.Fatal(err)
			}
			ov.Harness = tc.harness
			ov.Model = tc.model
			if err := svc.SetOverride(e.ctx, e.ws, e.me.ID, "atlas", "PAY", ov); err != nil {
				t.Fatal(err)
			}

			t.Setenv("FAKE_HARNESS_MODE", "subagent")
			t.Setenv("FAKE_SUBAGENT_CALLS", string(calls))
			e.dispatch("PAY-214")
			run := e.run("PAY-214")

			stopTick := make(chan struct{})
			tickDone := make(chan struct{})
			var stopOnce sync.Once
			stop := func() {
				stopOnce.Do(func() { close(stopTick) })
				<-tickDone
			}
			go func() {
				defer close(tickDone)
				for {
					select {
					case <-stopTick:
						return
					default:
						e.runner.Tick(e.ctx)
						time.Sleep(25 * time.Millisecond)
					}
				}
			}()
			defer func() {
				stop()
				e.runner.Wait()
			}()

			// Wait until the 3rd subagent holds, ensuring the first two completed while
			// the run workspace is still mounted on disk.
			deadline := time.Now().Add(15 * time.Second)
			for {
				if _, err := os.Stat(holdFile + ".started"); err == nil {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("%s timed out waiting for hold subagent", tc.harness)
				}
				time.Sleep(25 * time.Millisecond)
			}

			wsDir := filepath.Join(e.dir, "work", "runs", run.ID.String(), "workspace")
			if b, err := os.ReadFile(filepath.Join(wsDir, "helper.txt")); err != nil || !strings.Contains(string(b), "written by helper") {
				_ = os.WriteFile(holdFile, []byte("go"), 0o644)
				t.Fatalf("helper.txt = %q (%v)", b, err)
			}
			if _, err := os.Stat(filepath.Join(wsDir, "blocked-by-explorer.txt")); !os.IsNotExist(err) {
				_ = os.WriteFile(holdFile, []byte("go"), 0o644)
				t.Fatalf("explorer unexpectedly wrote file: err=%v", err)
			}
			agentsMD, err := os.ReadFile(filepath.Join(wsDir, "AGENTS.md"))
			if err != nil {
				_ = os.WriteFile(holdFile, []byte("go"), 0o644)
				t.Fatalf("read AGENTS.md: %v", err)
			}
			instrContent := string(agentsMD)
			if tc.harness == agentdef.HarnessAntigravity {
				if !strings.Contains(instrContent, ".agents/rules/vesper-*.md") {
					_ = os.WriteFile(holdFile, []byte("go"), 0o644)
					t.Fatalf("agy AGENTS.md pointer corrupted:\n%s", instrContent)
				}
				rule1, rErr := os.ReadFile(filepath.Join(wsDir, ".agents", "rules", "vesper-01.md"))
				if rErr != nil {
					_ = os.WriteFile(holdFile, []byte("go"), 0o644)
					t.Fatalf("read vesper-01.md: %v", rErr)
				}
				instrContent = string(rule1)
			}
			if !strings.Contains(instrContent, "Vesper run: PAY-214") ||
				strings.Contains(instrContent, agentdef.ExplorerPrompt) ||
				strings.Contains(instrContent, agentdef.HelperPrompt) {
				_ = os.WriteFile(holdFile, []byte("go"), 0o644)
				t.Fatalf("instructions corrupted: %s", instrContent)
			}
			if err := os.WriteFile(holdFile, []byte("go"), 0o644); err != nil {
				t.Fatal(err)
			}

			e.until("completed", e.state("PAY-214=completed"))
			stop()
			e.runner.Wait()

			run = e.run("PAY-214")
			if run.Outcome == nil ||
				!strings.Contains(*run.Outcome, "explorer:policy write=false bash=false read=true") ||
				!strings.Contains(*run.Outcome, "helper:wrote=true") {
				t.Fatalf("%s outcome = %v", tc.harness, deref(run.Outcome))
			}

			jobs, err := e.q.ListSubagentJobsForRun(e.ctx, run.ID)
			if err != nil || len(jobs) != 3 {
				t.Fatalf("jobs = %d (%v)", len(jobs), err)
			}
			for _, j := range jobs {
				if j.Status != "completed" || j.ToolCalls < 1 || j.InputTokens <= 0 || j.OutputTokens <= 0 {
					t.Fatalf("job %+v not completed with usage/tool_calls", j)
				}
			}

			evs, err := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
			if err != nil {
				t.Fatal(err)
			}
			var subCalls, subResults int
			seenTypes := map[string]bool{}
			for _, ev := range evs {
				var pl map[string]any
				if json.Unmarshal(ev.Payload, &pl) != nil || pl["subagent"] != true {
					continue
				}
				if typ, ok := pl["subagent_type"].(string); ok {
					seenTypes[typ] = true
				}
				switch ev.Type {
				case "tool_call":
					subCalls++
				case "tool_result":
					subResults++
				}
			}
			if subCalls < 2 || subResults < 2 || !seenTypes[agentdef.ExplorerAgent] || !seenTypes[agentdef.HelperAgent] {
				t.Fatalf("subagent events calls=%d results=%d types=%v (all=%s)", subCalls, subResults, seenTypes, e.eventTypes(run.ID))
			}
			if run.ToolCalls < 5 || run.InputTokens < 2000 {
				t.Fatalf("rolled up run usage too low: tool_calls=%d input_tokens=%d", run.ToolCalls, run.InputTokens)
			}
		})
	}
}

func TestSubagentConcurrencyLimit(t *testing.T) {
	e := setup(t)
	holdDir := t.TempDir()
	var callDefs []map[string]string
	for i := range 4 {
		callDefs = append(callDefs, map[string]string{
			"type":   agentdef.ExplorerAgent,
			"role":   fmt.Sprintf("Worker %d", i),
			"prompt": "HOLD=" + filepath.Join(holdDir, fmt.Sprintf("job-%d", i)),
		})
	}
	rawCalls, _ := json.Marshal(callDefs)
	t.Setenv("FAKE_HARNESS_MODE", "subagent")
	t.Setenv("FAKE_SUBAGENT_CALLS", string(rawCalls))
	t.Setenv("FAKE_SUBAGENT_PARALLEL", "1")

	e.dispatch("PAY-214")
	run := e.run("PAY-214")

	stopTick := make(chan struct{})
	tickDone := make(chan struct{})
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() { close(stopTick) })
		<-tickDone
	}
	go func() {
		defer close(tickDone)
		for {
			select {
			case <-stopTick:
				return
			default:
				e.runner.Tick(e.ctx)
				time.Sleep(25 * time.Millisecond)
			}
		}
	}()
	defer func() {
		stop()
		e.runner.Wait()
	}()

	startedFiles := func() []string {
		entries, _ := os.ReadDir(holdDir)
		var out []string
		for _, ent := range entries {
			if strings.HasSuffix(ent.Name(), ".started") {
				out = append(out, ent.Name())
			}
		}
		return out
	}

	deadline := time.Now().Add(15 * time.Second)
	for len(startedFiles()) < 3 {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for 3 active subagents, got %v", startedFiles())
		}
		time.Sleep(25 * time.Millisecond)
	}
	// Give any excess worker a chance to erroneously start; cap must hold at 3.
	time.Sleep(250 * time.Millisecond)
	gotStarted := startedFiles()
	if len(gotStarted) != 3 {
		t.Fatalf("active started files = %d (%v), want 3", len(gotStarted), gotStarted)
	}
	jobs, err := e.q.ListSubagentJobsForRun(e.ctx, run.ID)
	if err != nil || len(jobs) != 4 {
		t.Fatalf("jobs=%d err=%v", len(jobs), err)
	}
	counts := map[string]int{}
	for _, j := range jobs {
		counts[j.Status]++
	}
	if counts["running"] != 3 || counts["queued"] != 1 {
		t.Fatalf("job status counts = %v, want 3 running & 1 queued", counts)
	}

	// Release one active job -> 4th job starts.
	firstRelease := strings.TrimSuffix(gotStarted[0], ".started")
	if err := os.WriteFile(filepath.Join(holdDir, firstRelease), []byte("go"), 0o644); err != nil {
		t.Fatal(err)
	}
	deadline = time.Now().Add(10 * time.Second)
	for len(startedFiles()) < 4 {
		if time.Now().After(deadline) {
			t.Fatalf("4th subagent never started after slot freed, got %v", startedFiles())
		}
		time.Sleep(25 * time.Millisecond)
	}
	// Release all 4 hold files so every worker completes cleanly.
	for i := range 4 {
		if err := os.WriteFile(filepath.Join(holdDir, fmt.Sprintf("job-%d", i)), []byte("go"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	e.until("completed", e.state("PAY-214=completed"))
	jobs, err = e.q.ListSubagentJobsForRun(e.ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	for _, j := range jobs {
		if j.Status != "completed" {
			t.Fatalf("job %s status = %s, want completed", j.ID, j.Status)
		}
	}
}

func TestSubagentCanceledWhenParentInterrupted(t *testing.T) {
	e := setup(t)
	holdDir := t.TempDir()
	var callDefs []map[string]string
	for i := range 4 {
		callDefs = append(callDefs, map[string]string{
			"type":   agentdef.ExplorerAgent,
			"role":   fmt.Sprintf("Held %d", i),
			"prompt": "HOLD=" + filepath.Join(holdDir, fmt.Sprintf("h-%d", i)),
		})
	}
	rawCalls, _ := json.Marshal(callDefs)
	t.Setenv("FAKE_HARNESS_MODE", "subagent")
	t.Setenv("FAKE_SUBAGENT_CALLS", string(rawCalls))
	t.Setenv("FAKE_SUBAGENT_PARALLEL", "1")

	e.dispatch("PAY-214")
	run := e.run("PAY-214")

	stopTick := make(chan struct{})
	go func() {
		for {
			select {
			case <-stopTick:
				return
			default:
				e.runner.Tick(e.ctx)
				time.Sleep(25 * time.Millisecond)
			}
		}
	}()

	startedCount := func() int {
		entries, _ := os.ReadDir(holdDir)
		n := 0
		for _, ent := range entries {
			if strings.HasSuffix(ent.Name(), ".started") {
				n++
			}
		}
		return n
	}
	deadline := time.Now().Add(15 * time.Second)
	for startedCount() < 3 {
		if time.Now().After(deadline) {
			close(stopTick)
			t.Fatalf("timed out waiting for active subagents (%d started)", startedCount())
		}
		time.Sleep(25 * time.Millisecond)
	}

	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, run.ID, "pause"); err != nil {
		close(stopTick)
		t.Fatal(err)
	}
	deadline = time.Now().Add(15 * time.Second)
	for {
		turns, _ := e.q.ListTurns(e.ctx, run.ID)
		if len(turns) > 0 && turns[0].Status == "done" {
			break
		}
		if time.Now().After(deadline) {
			close(stopTick)
			t.Fatal("pause did not finish parent turn")
		}
		time.Sleep(30 * time.Millisecond)
	}
	close(stopTick)
	e.runner.Wait()

	if r := e.run("PAY-214"); r.State != "paused" {
		t.Fatalf("run state = %s, want paused", r.State)
	}
	jobs, err := e.q.ListSubagentJobsForRun(e.ctx, run.ID)
	if err != nil || len(jobs) != 4 {
		t.Fatalf("jobs = %d (%v)", len(jobs), err)
	}
	for _, j := range jobs {
		if j.Status != "canceled" {
			t.Fatalf("job %s status = %s (err=%q), want canceled", j.ID, j.Status, j.Error)
		}
	}
}

func TestSubagentConcurrencyLimitFromSettings(t *testing.T) {
	runSubagentLimitCase := func(t *testing.T, configuredLimit, totalJobs int) {
		t.Helper()
		e := setup(t)
		v := int32(configuredLimit)
		if err := e.q.SetWorkspaceRunnerSettings(e.ctx, store.SetWorkspaceRunnerSettingsParams{
			ID:                     e.ws,
			MaxConcurrentSubagents: &v,
		}); err != nil {
			t.Fatal(err)
		}

		holdDir := t.TempDir()
		t.Cleanup(func() {
			for i := range totalJobs {
				_ = os.WriteFile(filepath.Join(holdDir, fmt.Sprintf("job-%d", i)), []byte("go"), 0o644)
			}
		})

		var callDefs []map[string]string
		for i := range totalJobs {
			callDefs = append(callDefs, map[string]string{
				"type":   agentdef.ExplorerAgent,
				"role":   fmt.Sprintf("Worker %d", i),
				"prompt": "HOLD=" + filepath.Join(holdDir, fmt.Sprintf("job-%d", i)),
			})
		}
		rawCalls, _ := json.Marshal(callDefs)
		t.Setenv("FAKE_HARNESS_MODE", "subagent")
		t.Setenv("FAKE_SUBAGENT_CALLS", string(rawCalls))
		t.Setenv("FAKE_SUBAGENT_PARALLEL", "1")

		e.dispatch("PAY-214")
		run := e.run("PAY-214")

		stopTick := make(chan struct{})
		tickDone := make(chan struct{})
		var stopOnce sync.Once
		stop := func() {
			stopOnce.Do(func() { close(stopTick) })
			<-tickDone
		}
		go func() {
			defer close(tickDone)
			for {
				select {
				case <-stopTick:
					return
				default:
					e.runner.Tick(e.ctx)
					time.Sleep(25 * time.Millisecond)
				}
			}
		}()
		defer func() {
			stop()
			e.runner.Wait()
		}()

		startedFiles := func() []string {
			entries, _ := os.ReadDir(holdDir)
			var out []string
			for _, ent := range entries {
				if strings.HasSuffix(ent.Name(), ".started") {
					out = append(out, ent.Name())
				}
			}
			return out
		}

		wantActive := min(configuredLimit, totalJobs)
		deadline := time.Now().Add(15 * time.Second)
		for len(startedFiles()) < wantActive {
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %d active subagents, got %v", wantActive, startedFiles())
			}
			time.Sleep(25 * time.Millisecond)
		}
		// Give any excess worker a chance to erroneously start; cap must hold.
		time.Sleep(250 * time.Millisecond)
		gotStarted := startedFiles()
		if len(gotStarted) != wantActive {
			t.Fatalf("active started files = %d (%v), want %d", len(gotStarted), gotStarted, wantActive)
		}

		jobs, err := e.q.ListSubagentJobsForRun(e.ctx, run.ID)
		if err != nil || len(jobs) != totalJobs {
			t.Fatalf("jobs=%d err=%v", len(jobs), err)
		}
		counts := map[string]int{}
		for _, j := range jobs {
			counts[j.Status]++
		}
		if counts["running"] != wantActive || counts["queued"] != totalJobs-wantActive {
			t.Fatalf("job status counts = %v, want %d running & %d queued", counts, wantActive, totalJobs-wantActive)
		}

		if totalJobs > wantActive {
			firstRelease := strings.TrimSuffix(gotStarted[0], ".started")
			if err := os.WriteFile(filepath.Join(holdDir, firstRelease), []byte("go"), 0o644); err != nil {
				t.Fatal(err)
			}
			deadline = time.Now().Add(10 * time.Second)
			for len(startedFiles()) < wantActive+1 {
				if time.Now().After(deadline) {
					t.Fatalf("next subagent never started after slot freed, got %v", startedFiles())
				}
				time.Sleep(25 * time.Millisecond)
			}
		}

		for i := range totalJobs {
			if err := os.WriteFile(filepath.Join(holdDir, fmt.Sprintf("job-%d", i)), []byte("go"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		e.until("completed", e.state("PAY-214=completed"))
		jobs, err = e.q.ListSubagentJobsForRun(e.ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, j := range jobs {
			if j.Status != "completed" {
				t.Fatalf("job %s status = %s, want completed", j.ID, j.Status)
			}
		}
	}

	t.Run("raised_to_4", func(t *testing.T) {
		runSubagentLimitCase(t, 4, 4)
	})
	t.Run("lowered_to_2", func(t *testing.T) {
		runSubagentLimitCase(t, 2, 3)
	})
}

func TestSubagentBatchConcurrencyLimit(t *testing.T) {
	runBatchCase := func(t *testing.T, configuredLimit, totalJobs int) {
		t.Helper()
		e := setup(t)
		v := int32(configuredLimit)
		if err := e.q.SetWorkspaceRunnerSettings(e.ctx, store.SetWorkspaceRunnerSettingsParams{
			ID:                     e.ws,
			MaxConcurrentSubagents: &v,
		}); err != nil {
			t.Fatal(err)
		}

		// Run under Antigravity to mirror the single-call batch path agy needs
		// (since agy executes separate MCP tools/call requests sequentially).
		svc := &agents.Service{Pool: e.pool}
		p, err := e.q.GetProjectByKey(e.ctx, store.GetProjectByKeyParams{WorkspaceID: e.ws, Key: "PAY"})
		if err != nil {
			t.Fatal(err)
		}
		row, err := e.q.GetOverride(e.ctx, store.GetOverrideParams{AgentID: e.atlas.ID, ProjectID: p.ID})
		if err != nil {
			t.Fatal(err)
		}
		ov, err := agents.DecodeOverride(row.Spec)
		if err != nil {
			t.Fatal(err)
		}
		ov.Harness = agentdef.HarnessAntigravity
		ov.Model = "gemini-3.8-flash"
		if err := svc.SetOverride(e.ctx, e.ws, e.me.ID, "atlas", "PAY", ov); err != nil {
			t.Fatal(err)
		}

		holdDir := t.TempDir()
		t.Cleanup(func() {
			for i := range totalJobs {
				_ = os.WriteFile(filepath.Join(holdDir, fmt.Sprintf("batch-%d", i)), []byte("go"), 0o644)
			}
		})

		var callDefs []map[string]string
		for i := range totalJobs {
			callDefs = append(callDefs, map[string]string{
				"type":   agentdef.ExplorerAgent,
				"role":   fmt.Sprintf("Batch Worker %d", i),
				"prompt": "HOLD=" + filepath.Join(holdDir, fmt.Sprintf("batch-%d", i)),
			})
		}
		rawCalls, _ := json.Marshal(callDefs)
		t.Setenv("FAKE_HARNESS_MODE", "subagent")
		t.Setenv("FAKE_SUBAGENT_CALLS", string(rawCalls))
		t.Setenv("FAKE_SUBAGENT_BATCH", "1")

		e.dispatch("PAY-214")
		run := e.run("PAY-214")

		stopTick := make(chan struct{})
		tickDone := make(chan struct{})
		var stopOnce sync.Once
		stop := func() {
			stopOnce.Do(func() { close(stopTick) })
			<-tickDone
		}
		go func() {
			defer close(tickDone)
			for {
				select {
				case <-stopTick:
					return
				default:
					e.runner.Tick(e.ctx)
					time.Sleep(25 * time.Millisecond)
				}
			}
		}()
		defer func() {
			stop()
			e.runner.Wait()
		}()

		startedFiles := func() []string {
			entries, _ := os.ReadDir(holdDir)
			var out []string
			for _, ent := range entries {
				if strings.HasSuffix(ent.Name(), ".started") {
					out = append(out, ent.Name())
				}
			}
			return out
		}

		wantActive := min(configuredLimit, totalJobs)
		deadline := time.Now().Add(15 * time.Second)
		for len(startedFiles()) < wantActive {
			if time.Now().After(deadline) {
				t.Fatalf("timed out waiting for %d active batch subagents, got %v", wantActive, startedFiles())
			}
			time.Sleep(25 * time.Millisecond)
		}
		// Cap must hold even though all jobs were enqueued at once.
		time.Sleep(250 * time.Millisecond)
		gotStarted := startedFiles()
		if len(gotStarted) != wantActive {
			t.Fatalf("active started files = %d (%v), want %d", len(gotStarted), gotStarted, wantActive)
		}

		jobs, err := e.q.ListSubagentJobsForRun(e.ctx, run.ID)
		if err != nil || len(jobs) != totalJobs {
			t.Fatalf("jobs=%d err=%v", len(jobs), err)
		}
		counts := map[string]int{}
		for _, j := range jobs {
			counts[j.Status]++
		}
		if counts["running"] != wantActive || counts["queued"] != totalJobs-wantActive {
			t.Fatalf("job status counts = %v, want %d running & %d queued", counts, wantActive, totalJobs-wantActive)
		}

		// Freeing a slot starts a queued job; release the rest in reverse order to verify input ordering.
		if totalJobs > wantActive {
			firstRelease := strings.TrimSuffix(gotStarted[0], ".started")
			if err := os.WriteFile(filepath.Join(holdDir, firstRelease), []byte("go"), 0o644); err != nil {
				t.Fatal(err)
			}
			deadline = time.Now().Add(10 * time.Second)
			for len(startedFiles()) < wantActive+1 {
				if time.Now().After(deadline) {
					t.Fatalf("next queued batch subagent never started, got %v", startedFiles())
				}
				time.Sleep(25 * time.Millisecond)
			}
		}
		for i := totalJobs - 1; i >= 0; i-- {
			if err := os.WriteFile(filepath.Join(holdDir, fmt.Sprintf("batch-%d", i)), []byte("go"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
		e.until("completed", e.state("PAY-214=completed"))

		run = e.run("PAY-214")
		if run.Outcome == nil {
			t.Fatal("missing run outcome")
		}
		prevIdx := -1
		for i := range totalJobs {
			prefix := fmt.Sprintf("%d:explorer:", i)
			batchTag := fmt.Sprintf("batch-%d", i)
			pos := strings.Index(*run.Outcome, prefix)
			if pos <= prevIdx || !strings.Contains((*run.Outcome)[pos:], batchTag) {
				t.Fatalf("outcome missing ordered result %q / %q: %s", prefix, batchTag, *run.Outcome)
			}
			prevIdx = pos
		}
		jobs, err = e.q.ListSubagentJobsForRun(e.ctx, run.ID)
		if err != nil {
			t.Fatal(err)
		}
		for _, j := range jobs {
			if j.Status != "completed" {
				t.Fatalf("job %s status = %s, want completed", j.ID, j.Status)
			}
		}
	}

	t.Run("capped_at_2_with_4_tasks", func(t *testing.T) {
		runBatchCase(t, 2, 4)
	})
	t.Run("all_4_concurrent_when_limit_4", func(t *testing.T) {
		runBatchCase(t, 4, 4)
	})
}

func TestSubagentTierSelectionAcrossHarnesses(t *testing.T) {
	discovery := func(_ context.Context, h, _ string) ([]chatmodels.Model, error) {
		switch h {
		case agentdef.HarnessClaudeCode:
			return []chatmodels.Model{
				{ID: "default", Label: "Default (recommended)", Default: true, Efforts: agentdef.Efforts},
				{ID: "opus", Label: "Opus 5.5", Efforts: agentdef.Efforts},
				{ID: "fable", Label: "Fable 5.2", Efforts: agentdef.Efforts},
				{ID: "sonnet", Label: "Sonnet 5.5", Efforts: agentdef.Efforts},
				{ID: "haiku", Label: "Haiku 5.5"},
			}, nil
		case agentdef.HarnessCodex:
			return []chatmodels.Model{
				{ID: "gpt-6-pro", Label: "GPT-6 Pro", Efforts: []string{"low", "medium", "high", "xhigh"}},
				{ID: "gpt-6-codex", Label: "GPT-6 Codex", Default: true, Efforts: []string{"low", "medium", "high", "xhigh"}},
				{ID: "gpt-6-codex-mini", Label: "GPT-6 Codex Mini", Efforts: []string{"medium", "high"}},
			}, nil
		case agentdef.HarnessAntigravity:
			return []chatmodels.Model{
				{ID: "gemini-4-carbon", Label: "Gemini 4 Carbon", Efforts: []string{"low", "medium", "high"}},
				{ID: "gemini-4-neon", Label: "Gemini 4 Neon", Efforts: []string{"low", "medium", "high", "xhigh"}},
				{ID: "gemini-4-hydrogen", Label: "Gemini 4 Hydrogen", Efforts: []string{"low", "medium", "high"}},
				{ID: "gemini-pro-orchestrator", Label: "Orchestrator (Carbon)"},
				{ID: "gemini-pro-orchestrator-neon", Label: "Orchestrator (Neon)"},
			}, nil
		}
		return nil, nil
	}

	type wantJob struct {
		tier, model, effort string
	}
	runTierCase := func(t *testing.T, harness, parentModel, parentEffort string, tierRouting *bool, tierRules json.RawMessage, calls []map[string]string, wants []wantJob) {
		t.Helper()
		e := setup(t)
		e.runs.ModelDiscovery = discovery

		if tierRouting != nil || len(tierRules) > 0 {
			if err := e.q.SetWorkspaceRunnerSettings(e.ctx, store.SetWorkspaceRunnerSettingsParams{
				ID:                  e.ws,
				SubagentTierRouting: tierRouting,
				SubagentTierModels:  tierRules,
			}); err != nil {
				t.Fatalf("SetWorkspaceRunnerSettings: %v", err)
			}
		}

		svc := &agents.Service{Pool: e.pool}
		p, err := e.q.GetProjectByKey(e.ctx, store.GetProjectByKeyParams{WorkspaceID: e.ws, Key: "PAY"})
		if err != nil {
			t.Fatal(err)
		}
		row, err := e.q.GetOverride(e.ctx, store.GetOverrideParams{AgentID: e.atlas.ID, ProjectID: p.ID})
		if err != nil {
			t.Fatal(err)
		}
		ov, err := agents.DecodeOverride(row.Spec)
		if err != nil {
			t.Fatal(err)
		}
		ov.Harness = harness
		ov.Model = parentModel
		if err := svc.SetOverride(e.ctx, e.ws, e.me.ID, "atlas", "PAY", ov); err != nil {
			t.Fatal(err)
		}

		rawCalls, _ := json.Marshal(calls)
		t.Setenv("FAKE_HARNESS_MODE", "subagent")
		t.Setenv("FAKE_SUBAGENT_CALLS", string(rawCalls))
		t.Setenv("FAKE_SUBAGENT_BATCH", "1")

		e.dispatch("PAY-214")
		run := e.run("PAY-214")
		if parentEffort != "" {
			var spec agentdef.Resolved
			if err := json.Unmarshal(run.ResolvedSpec, &spec); err != nil {
				t.Fatal(err)
			}
			if spec.HarnessOptions == nil {
				spec.HarnessOptions = map[string]string{}
			}
			spec.HarnessOptions["effort"] = parentEffort
			rawSpec, _ := json.Marshal(spec)
			if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET resolved_spec=$1 WHERE id=$2", rawSpec, run.ID); err != nil {
				t.Fatal(err)
			}
		}
		e.until("completed", e.state("PAY-214=completed"))

		run = e.run("PAY-214")
		if run.Outcome == nil {
			t.Fatal("missing run outcome")
		}
		jobs, err := e.q.ListSubagentJobsForRun(e.ctx, run.ID)
		if err != nil || len(jobs) != len(wants) {
			t.Fatalf("%s jobs=%d err=%v, want %d", harness, len(jobs), err, len(wants))
		}
		for i, w := range wants {
			j := jobs[i]
			if j.Status != "completed" || j.Tier != w.tier || j.Model != w.model || j.Effort != w.effort {
				t.Fatalf("%s job[%d] = status=%s tier=%q model=%q effort=%q, want tier=%q model=%q effort=%q",
					harness, i, j.Status, j.Tier, j.Model, j.Effort, w.tier, w.model, w.effort)
			}
			wantWire := fmt.Sprintf("model=%s effort=%s", w.model, w.effort)
			wantIdxPrefix := fmt.Sprintf("%d:%s:%s", i, j.AgentType, wantWire)
			if !strings.Contains(*run.Outcome, wantIdxPrefix) {
				t.Fatalf("%s outcome missing wire proof %q: %s", harness, wantIdxPrefix, *run.Outcome)
			}
		}

		evs, err := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
		if err != nil {
			t.Fatal(err)
		}
		seenEventModels := map[string]bool{}
		lifecycleStates := map[string]map[string]bool{}
		for _, ev := range evs {
			var pl map[string]any
			if json.Unmarshal(ev.Payload, &pl) != nil {
				continue
			}
			if pl["subagent"] != true {
				continue
			}
			if ev.Type == "lifecycle" {
				st, _ := pl["state"].(string)
				id, _ := pl["subagent_id"].(string)
				if st != "" && id != "" {
					if lifecycleStates[id] == nil {
						lifecycleStates[id] = map[string]bool{}
					}
					lifecycleStates[id][st] = true
					if pl["reason"] != "check model routing" || pl["batch_id"] == "" {
						t.Fatalf("%s lifecycle %s missing reason/batch_id: %#v", harness, st, pl)
					}
					if st == "subagent_finished" {
						if _, ok := pl["queued_ms"]; !ok {
							t.Fatalf("%s subagent_finished missing queued_ms: %#v", harness, pl)
						}
						if _, ok := pl["duration_ms"]; !ok {
							t.Fatalf("%s subagent_finished missing duration_ms: %#v", harness, pl)
						}
					}
				}
			}
			if m, _ := pl["subagent_model"].(string); m != "" {
				tier, _ := pl["subagent_tier"].(string)
				seenEventModels[tier+":"+m] = true
			}
		}
		for _, j := range jobs {
			gotStates := lifecycleStates[j.ID.String()]
			if !gotStates["subagent_queued"] || !gotStates["subagent_started"] || !gotStates["subagent_finished"] {
				t.Fatalf("%s job %s missing lifecycle states: %v", harness, j.ID, gotStates)
			}
		}
		for _, w := range wants {
			if !seenEventModels[w.tier+":"+w.model] {
				t.Fatalf("%s missing run event for %s:%s (got %v)", harness, w.tier, w.model, seenEventModels)
			}
		}
	}

	mixedCalls := []map[string]string{
		{"type": agentdef.ExplorerAgent, "role": "Search", "reason": "check model routing", "prompt": "REPORT_MODEL"},
		{"type": agentdef.HelperAgent, "tier": "fast", "role": "Fast Helper", "reason": "check model routing", "prompt": "REPORT_MODEL"},
		{"type": agentdef.HelperAgent, "tier": "standard", "role": "Std Helper", "reason": "check model routing", "prompt": "REPORT_MODEL"},
		{"type": agentdef.HelperAgent, "tier": "deep", "role": "Deep Helper", "reason": "check model routing", "prompt": "REPORT_MODEL"},
	}
	cappedCalls := []map[string]string{
		{"type": agentdef.HelperAgent, "tier": "fast", "role": "Fast Helper", "reason": "check model routing", "prompt": "REPORT_MODEL"},
		{"type": agentdef.HelperAgent, "tier": "deep", "role": "Capped Deep", "reason": "check model routing", "prompt": "REPORT_MODEL"},
	}

	// Default behavior (no custom ladder): effort-only scaling on parent model (de-orchestrated on agy).
	t.Run("claude_default_effort_only", func(t *testing.T) {
		runTierCase(t, agentdef.HarnessClaudeCode, "fable", "", nil, nil, mixedCalls, []wantJob{
			{"fast", "fable", "low"},
			{"fast", "fable", "low"},
			{"standard", "fable", "medium"},
			{"deep", "fable", "high"},
		})
	})
	t.Run("codex_default_effort_only", func(t *testing.T) {
		runTierCase(t, agentdef.HarnessCodex, "gpt-6-pro", "", nil, nil, mixedCalls, []wantJob{
			{"fast", "gpt-6-pro", "low"},
			{"fast", "gpt-6-pro", "low"},
			{"standard", "gpt-6-pro", "medium"},
			{"deep", "gpt-6-pro", "high"},
		})
	})
	t.Run("antigravity_orchestrator_neon_default_effort_only", func(t *testing.T) {
		runTierCase(t, agentdef.HarnessAntigravity, "gemini-pro-orchestrator-neon", "", nil, nil, mixedCalls, []wantJob{
			{"fast", "gemini-4-neon", "low"},
			{"fast", "gemini-4-neon", "low"},
			{"standard", "gemini-4-neon", "medium"},
			{"deep", "gemini-4-neon", "high"},
		})
	})

	// Custom Antigravity ladder: Carbon (deep) -> Neon (standard) -> Hydrogen (fast).
	agyLadder := json.RawMessage(`{"antigravity":{"deep":"gemini-4-carbon","standard":"gemini-4-neon","fast":"gemini-4-hydrogen"}}`)
	t.Run("antigravity_custom_ladder_carbon_parent", func(t *testing.T) {
		runTierCase(t, agentdef.HarnessAntigravity, "gemini-pro-orchestrator", "", nil, agyLadder, mixedCalls, []wantJob{
			{"fast", "gemini-4-hydrogen", "low"},
			{"fast", "gemini-4-hydrogen", "low"},
			{"standard", "gemini-4-neon", "medium"},
			{"deep", "gemini-4-carbon", "high"},
		})
	})
	t.Run("antigravity_custom_ladder_neon_parent_caps_deep", func(t *testing.T) {
		runTierCase(t, agentdef.HarnessAntigravity, "gemini-4-neon", "", nil, agyLadder, cappedCalls, []wantJob{
			{"fast", "gemini-4-hydrogen", "low"},
			{"standard", "gemini-4-neon", "medium"},
		})
	})

	// Custom Claude ladder: Fable -> Sonnet -> Haiku.
	claudeLadder := json.RawMessage(`{"claude-code":{"deep":"fable","standard":"sonnet","fast":"haiku"}}`)
	t.Run("claude_custom_ladder_sonnet_caps_deep", func(t *testing.T) {
		runTierCase(t, agentdef.HarnessClaudeCode, "sonnet", "", nil, claudeLadder, cappedCalls, []wantJob{
			{"fast", "haiku", ""},
			{"standard", "sonnet", "medium"},
		})
	})

	// Turning subagent_tier_routing off restores exact pre-tier behavior even when custom rules exist:
	// helper keeps parent model and effort verbatim; explorer uses legacy default.
	off := false
	t.Run("tier_routing_off_restores_legacy_behavior", func(t *testing.T) {
		runTierCase(t, agentdef.HarnessCodex, "gpt-6-pro", "xhigh", &off, json.RawMessage(`{"codex":{"deep":"gpt-6-pro","fast":"gpt-6-codex-mini"}}`), []map[string]string{
			{"type": agentdef.ExplorerAgent, "tier": "deep", "role": "Search", "reason": "check model routing", "prompt": "REPORT_MODEL"},
			{"type": agentdef.HelperAgent, "tier": "fast", "role": "Helper", "reason": "check model routing", "prompt": "REPORT_MODEL"},
		}, []wantJob{
			{"", "gpt-5-mini", ""},
			{"", "gpt-6-pro", "xhigh"},
		})
	})
}

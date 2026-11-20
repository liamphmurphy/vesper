package runner_test

import (
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

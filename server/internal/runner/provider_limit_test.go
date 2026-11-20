package runner_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type logLine struct {
	Resume string `json:"resume"`
	Prompt string `json:"prompt"`
	Codex  string `json:"harness"`
}

func readHarnessLog(t *testing.T, path string) []logLine {
	t.Helper()
	b, _ := os.ReadFile(path)
	var out []logLine
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if l == "" {
			continue
		}
		var x logLine
		if err := json.Unmarshal([]byte(l), &x); err != nil {
			t.Fatal(err)
		}
		out = append(out, x)
	}
	return out
}

func (e env) limit(harness string, until time.Time) {
	e.t.Helper()
	if err := e.q.MarkProviderLimited(e.ctx, store.MarkProviderLimitedParams{WorkspaceID: e.ws, Harness: harness, Until: until, Reason: "test"}); err != nil {
		e.t.Fatal(err)
	}
}

func (e env) setFallbacks(id uuid.UUID, raw []byte, fb ...agentdef.Fallback) {
	e.t.Helper()
	var spec agentdef.Resolved
	if err := json.Unmarshal(raw, &spec); err != nil {
		e.t.Fatal(err)
	}
	spec.Fallbacks = fb
	b, _ := json.Marshal(spec)
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", id, b); err != nil {
		e.t.Fatal(err)
	}
}

var codexFallback = agentdef.Fallback{Harness: agentdef.HarnessCodex, Model: "test-fallback"}

func TestUsageLimitRecordsProviderLimit(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	e.dispatch("PAY-214")
	run := e.run("PAY-214")
	e.setFallbacks(run.ID, run.ResolvedSpec, codexFallback)
	e.until("fallback completed", e.state("PAY-214=completed"))
	limits, err := e.q.ActiveProviderLimits(e.ctx, e.ws)
	if err != nil || len(limits) != 1 || limits[0].Harness != run.Harness {
		t.Fatalf("limits=%+v err=%v run harness %s", limits, err, run.Harness)
	}
	// "You have hit your usage limit" has no reset time: the default cooldown applies.
	if d := time.Until(limits[0].Until); d < 50*time.Minute || d > 61*time.Minute {
		t.Fatalf("until in %v", d)
	}
}

func TestNewRunSkipsLimitedHarness(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	e.dispatch("PAY-214")
	run := e.run("PAY-214")
	if run.Harness != agentdef.HarnessClaudeCode {
		t.Fatalf("primary %s", run.Harness)
	}
	e.setFallbacks(run.ID, run.ResolvedSpec, codexFallback)
	e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour))
	e.until("completed", e.state("PAY-214=completed"))
	run = e.run("PAY-214")
	if run.Harness != "codex" || run.Model != "test-fallback" {
		t.Fatalf("target %s %s", run.Harness, run.Model)
	}
	lines := readHarnessLog(t, logPath)
	if len(lines) != 1 || lines[0].Codex != "codex" {
		t.Fatalf("the limited primary must never be invoked: %+v", lines)
	}
	evs, _ := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
	found := false
	for _, ev := range evs {
		var p map[string]any
		_ = json.Unmarshal(ev.Payload, &p)
		if p["state"] == "harness_fallback" && p["reason"] == "provider_limited" && p["harness"] == "codex" {
			found = true
		}
	}
	if !found {
		t.Fatal("missing provider_limited fallback event")
	}
	turns, _ := e.q.ListTurns(e.ctx, run.ID)
	if len(turns) != 1 || strings.HasPrefix(turns[0].InputMessage, "Continue this existing") {
		t.Fatalf("a fresh run keeps its own prompt: %+v", turns)
	}
}

func TestDelegatedChildSkipsLimitedHarness(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	t.Setenv("FAKE_HARNESS_MODE", "delegate")
	e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour))
	e.dispatch("PAY-214") // no fallback on the parent: it stays on the limited primary
	patched := false
	e.until("child on fallback", func() bool {
		kids := e.children(e.run("PAY-214"))
		if len(kids) == 1 && !patched && kids[0].State == "queued" {
			e.setFallbacks(kids[0].ID, kids[0].ResolvedSpec, codexFallback)
			patched = true
		}
		return patched && e.run("PAY-214").State == "completed"
	})
	kid := e.children(e.run("PAY-214"))[0]
	if kid.Harness != "codex" {
		t.Fatalf("child harness %s", kid.Harness)
	}
	var claude, codex int
	for _, l := range readHarnessLog(t, logPath) {
		if l.Codex == "codex" {
			codex++
		} else {
			claude++
		}
	}
	// The parent's two turns ran on claude; only the child ran on codex.
	if claude != 2 || codex != 1 {
		t.Fatalf("claude=%d codex=%d", claude, codex)
	}
}

func TestResumedRunSwitchesWithHandoff(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	e.dispatch("PAY-214")
	e.until("waiting for approval", e.state("PAY-214=waiting"))
	run := e.run("PAY-214")
	if run.HarnessSessionID == nil {
		t.Fatal("no session")
	}
	e.setFallbacks(run.ID, run.ResolvedSpec, codexFallback)
	e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour))
	tk, _ := e.q.GetTicketByID(e.ctx, *run.TicketID)
	aps, _ := e.q.PendingApprovalsForTicket(e.ctx, tk.ID)
	if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, aps[0].ID, true, "go-ahead-marker"); err != nil {
		t.Fatal(err)
	}
	// A fresh fake codex session replays the first-turn script, so the run waits again.
	e.until("second turn on codex", func() bool {
		turns, _ := e.q.ListTurns(e.ctx, run.ID)
		return len(turns) == 2 && turns[1].Status == "done"
	})
	lines := readHarnessLog(t, logPath)
	if len(lines) != 2 || lines[1].Codex != "codex" || lines[1].Resume != "" {
		t.Fatalf("second turn must be a fresh codex session: %+v", lines)
	}
	if !strings.HasPrefix(lines[1].Prompt, "Continue this existing Vesper run after claude-code") {
		t.Fatalf("no handoff prompt: %q", lines[1].Prompt)
	}
	turns, _ := e.q.ListTurns(e.ctx, run.ID)
	// Only the first line reaches the log; the stored turn input is what's handed over.
	if n := strings.Count(turns[1].InputMessage, "go-ahead-marker"); n != 1 {
		t.Fatalf("approval input %q", turns[1].InputMessage)
	}
	if got := e.run("PAY-214"); got.Harness != "codex" || got.HarnessSessionID == nil || *got.HarnessSessionID == *run.HarnessSessionID {
		t.Fatalf("run %s session %v", got.Harness, got.HarnessSessionID)
	}
	if len(turns) != 2 {
		t.Fatalf("turns %d", len(turns))
	}
}

func TestExpiredOrUnusableLimitsAreIgnored(t *testing.T) {
	cases := []struct {
		name  string
		limit func(e env)
		fb    []agentdef.Fallback
	}{
		{"expired", func(e env) { e.limit(agentdef.HarnessClaudeCode, time.Now().Add(-time.Minute)) }, []agentdef.Fallback{codexFallback}},
		{"fallback also limited", func(e env) {
			e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour))
			e.limit(agentdef.HarnessCodex, time.Now().Add(time.Hour))
		}, []agentdef.Fallback{codexFallback}},
		{"no fallback", func(e env) { e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour)) }, nil},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			e := setup(t)
			logPath := filepath.Join(t.TempDir(), "log.jsonl")
			t.Setenv("FAKE_HARNESS_LOG", logPath)
			t.Setenv("FAKE_HARNESS_MODE", "complete")
			e.dispatch("PAY-214")
			run := e.run("PAY-214")
			e.setFallbacks(run.ID, run.ResolvedSpec, tc.fb...)
			tc.limit(e)
			e.until("completed", e.state("PAY-214=completed"))
			if got := e.run("PAY-214"); got.Harness != run.Harness {
				t.Fatalf("harness changed to %s", got.Harness)
			}
			if lines := readHarnessLog(t, logPath); len(lines) != 1 || lines[0].Codex == "codex" {
				t.Fatalf("should run on the primary: %+v", lines)
			}
		})
	}
}

func (e env) hasFallbackEvent(id uuid.UUID, reason, to string) bool {
	e.t.Helper()
	evs, _ := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: id, Seq: 0})
	for _, ev := range evs {
		var p map[string]any
		_ = json.Unmarshal(ev.Payload, &p)
		if p["state"] == "harness_fallback" && p["reason"] == reason && p["harness"] == to {
			return true
		}
	}
	return false
}

// setChain puts a run on chain[on], with the whole chain frozen into its spec.
func (e env) setChain(id uuid.UUID, raw []byte, on int, chain ...agentdef.Fallback) {
	e.t.Helper()
	var spec agentdef.Resolved
	if err := json.Unmarshal(raw, &spec); err != nil {
		e.t.Fatal(err)
	}
	spec.Chain = chain
	spec.Harness, spec.Model, spec.HarnessOptions = chain[on].Harness, chain[on].Model, chain[on].HarnessOptions
	spec.Fallbacks = append(append([]agentdef.Fallback{}, chain[:on]...), chain[on+1:]...)
	b, _ := json.Marshal(spec)
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET resolved_spec=$2, harness=$3, model=$4 WHERE id=$1", id, b, chain[on].Harness, chain[on].Model); err != nil {
		e.t.Fatal(err)
	}
}

func TestRunReturnsToPrimaryWhenLimitExpires(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	e.dispatch("PAY-214")
	e.until("waiting for approval", e.state("PAY-214=waiting"))
	run := e.run("PAY-214")
	e.setFallbacks(run.ID, run.ResolvedSpec, codexFallback)
	e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour))
	decide := func(note string) {
		tk, _ := e.q.GetTicketByID(e.ctx, *run.TicketID)
		aps, _ := e.q.PendingApprovalsForTicket(e.ctx, tk.ID)
		if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, aps[0].ID, true, note); err != nil {
			t.Fatal(err)
		}
	}
	turnsDone := func(n int) func() bool {
		return func() bool {
			turns, _ := e.q.ListTurns(e.ctx, run.ID)
			return len(turns) == n && turns[n-1].Status == "done"
		}
	}
	decide("first")
	e.until("second turn on codex", turnsDone(2))
	if got := e.run("PAY-214"); got.Harness != "codex" {
		t.Fatalf("harness %s", got.Harness)
	}
	// Claude's limit lifts: the next turn goes back to the primary.
	e.limit(agentdef.HarnessClaudeCode, time.Now().Add(-time.Minute))
	decide("second")
	e.until("third turn on claude", turnsDone(3))
	lines := readHarnessLog(t, logPath)
	if len(lines) != 3 || lines[2].Codex != "claude" || lines[2].Resume != "" {
		t.Fatalf("third turn must be a fresh claude session: %+v", lines)
	}
	if !strings.HasPrefix(lines[2].Prompt, "Continue this existing Vesper run after codex") {
		t.Fatalf("no handoff prompt: %q", lines[2].Prompt)
	}
	got := e.run("PAY-214")
	if got.Harness != agentdef.HarnessClaudeCode || !e.hasFallbackEvent(run.ID, "primary_available", agentdef.HarnessClaudeCode) {
		t.Fatalf("harness %s", got.Harness)
	}
}

func TestExhaustedFallbackReturnsToAvailablePrimary(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	t.Setenv("FAKE_HARNESS_CODEX_QUOTA", "1")
	t.Setenv("FAKE_HARNESS_QUOTA_SLEEP", "2s")
	e.dispatch("PAY-214")
	run := e.run("PAY-214")
	// On codex while claude (the primary) is still limited, so the turn starts there.
	e.setChain(run.ID, run.ResolvedSpec, 1, agentdef.Fallback{Harness: agentdef.HarnessClaudeCode, Model: "primary"}, codexFallback)
	e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour))
	// Claude's limit lifts while the codex turn runs.
	go func() {
		for i := 0; i < 200; i++ {
			if b, _ := os.ReadFile(logPath); len(b) > 0 {
				e.limit(agentdef.HarnessClaudeCode, time.Now().Add(-time.Minute))
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
	}()
	e.until("both exhausted", e.state("PAY-214=waiting_for_quota"))
	lines := readHarnessLog(t, logPath)
	if len(lines) != 2 || lines[0].Codex != "codex" || lines[1].Codex != "claude" {
		t.Fatalf("codex limit must send the run back to claude: %+v", lines)
	}
	if !e.hasFallbackEvent(run.ID, "provider_usage_exhausted", agentdef.HarnessClaudeCode) {
		t.Fatal("missing fallback event")
	}
}

func TestAllTargetsLimitedHolds(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	e.dispatch("PAY-214")
	run := e.run("PAY-214")
	e.setChain(run.ID, run.ResolvedSpec, 0, agentdef.Fallback{Harness: agentdef.HarnessClaudeCode, Model: "primary"}, codexFallback)
	e.limit(agentdef.HarnessClaudeCode, time.Now().Add(time.Hour))
	e.limit(agentdef.HarnessCodex, time.Now().Add(time.Hour))
	e.until("held", e.state("PAY-214=waiting_for_quota"))
	if lines := readHarnessLog(t, logPath); len(lines) != 1 || lines[0].Codex != "claude" {
		t.Fatalf("stays on the primary and holds: %+v", lines)
	}
	if got := e.run("PAY-214"); got.Harness != agentdef.HarnessClaudeCode {
		t.Fatalf("harness %s", got.Harness)
	}
}

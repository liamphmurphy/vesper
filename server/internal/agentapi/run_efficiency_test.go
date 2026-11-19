package agentapi

import (
	"bufio"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestSummariseRunEfficiency(t *testing.T) {
	t0 := time.Date(2026, 11, 13, 10, 0, 0, 0, time.UTC)
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
	ev := func(s int, typ, state, id, tool, cmd string, ctx int64) store.RunEfficiencyEventsRow {
		return store.RunEfficiencyEventsRow{Type: typ, At: at(s), State: state, CallID: id, Tool: tool, Command: cmd, ContextTokens: ctx}
	}
	got := summariseRunEfficiency([]store.RunEfficiencyEventsRow{
		ev(0, "lifecycle", "starting", "", "", "", 0),
		ev(95, "lifecycle", "workspace_ready", "", "", "", 0),
		ev(100, "tool_call", "", "a", "Read", "", 40_000),
		ev(101, "tool_call", "", "b", "Bash", "cd server && go test ./internal/harness 2>&1 | tail", 120_000),
		ev(131, "tool_result", "", "b", "Bash", "", 0),
		ev(132, "tool_call", "", "c", "Bash", "git status", 130_000),
		ev(133, "tool_call", "", "d", "Edit", "", 160_000),
		ev(140, "tool_call", "", "e", "shell", "npx playwright test e2e/foo.spec.ts", 0), // no context recorded (Codex)
		ev(200, "tool_result", "", "e", "shell", "", 0),
		ev(201, "tool_call", "", "f", "Write", "", 90_000), // a rollover shrank it
		// A second setup (a resumed workspace).
		ev(300, "lifecycle", "starting", "", "", "", 0),
		ev(305, "lifecycle", "workspace_ready", "", "", "", 0),
	})
	if got.SetupMs != 100_000 || got.Setups != 2 {
		t.Errorf("setup = %d ms over %d, want 100000 over 2", got.SetupMs, got.Setups)
	}
	if got.ToolCalls != 6 || got.CallsBeforeFirstEdit != 3 || got.ContextAtFirstEdit != 160_000 {
		t.Errorf("calls=%d before edit=%d context at edit=%d, want 6/3/160000", got.ToolCalls, got.CallsBeforeFirstEdit, got.ContextAtFirstEdit)
	}
	if got.PeakContext != 160_000 || got.ContextCrossed["100000"] != 2 || got.ContextCrossed["150000"] != 4 || len(got.ContextCrossed) != 2 {
		t.Errorf("peak=%d crossed=%v, want 160000 and 100k@2, 150k@4", got.PeakContext, got.ContextCrossed)
	}
	if got.TestRuns != 2 || got.TestMs != 90_000 || len(got.Tests) != 2 || got.Tests[0].Ms != 30_000 || got.Tests[1].Ms != 60_000 {
		t.Errorf("tests = %d runs %d ms %+v, want 2 runs 90000 ms (30s, 60s)", got.TestRuns, got.TestMs, got.Tests)
	}

	// No edits, no context, no setup: the unknowns stay unknown.
	empty := summariseRunEfficiency([]store.RunEfficiencyEventsRow{ev(0, "tool_call", "", "a", "Grep", "", 0)})
	if empty.CallsBeforeFirstEdit != -1 || empty.PeakContext != 0 || empty.ContextCrossed != nil || empty.Setups != 0 {
		t.Errorf("empty = %+v", empty)
	}
}

// The latency metrics mean the same on every harness: each recorded stream
// (internal/harness/testdata) goes through its own parser, then through the
// columns RunEfficiencyEvents selects, one second per event (LAZYAGENTS-257).
func TestRunEfficiencyAcrossHarnesses(t *testing.T) {
	t0 := time.Date(2026, 11, 19, 9, 0, 0, 0, time.UTC)
	rows := func(h harness.Harness, fixture string) []store.RunEfficiencyEventsRow {
		t.Helper()
		f, err := os.Open(filepath.Join("..", "harness", "testdata", fixture))
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		out := []store.RunEfficiencyEventsRow{{Type: "lifecycle", State: "turn_started", At: t0, InstructionBytes: 30_000}}
		p := h.NewParser("")
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 8<<20)
		for sc.Scan() {
			for _, e := range p.Line(sc.Bytes()) {
				if e.Type != "tool_call" && e.Type != "tool_result" {
					continue
				}
				in, _ := e.Payload["input"].(map[string]any)
				str := func(m map[string]any, k string) string { s, _ := m[k].(string); return s }
				out = append(out, store.RunEfficiencyEventsRow{Type: e.Type, At: t0.Add(time.Duration(len(out)) * time.Second),
					CallID: str(e.Payload, "id"), Tool: str(e.Payload, "tool"), Command: str(in, "command"), FilePath: str(in, "file_path")})
			}
		}
		return out
	}
	for _, c := range []struct {
		name    string
		h       harness.Harness
		fixture string
		want    runEfficiency
	}{
		// claim_ticket, then two shell commands, one at a time; no edit.
		{"claude", harness.ClaudeCode{}, "claude-turn.jsonl", runEfficiency{ToolCalls: 3, ModelTurns: 3, SingleCallTurns: 3, CallsBeforeFirstEdit: -1, MsToFirstEdit: -1}},
		// claim_ticket, a shell command, then apply_patch (the 5th event).
		{"codex", harness.Codex{}, "codex-turn.jsonl", runEfficiency{ToolCalls: 3, ModelTurns: 3, SingleCallTurns: 3, CallsBeforeFirstEdit: 2, MsToFirstEdit: 5_000}},
		// list_tickets, Read, Bash, then Write (the 7th event), then Agent.
		{"antigravity", harness.Antigravity{}, "antigravity-turn.jsonl", runEfficiency{ToolCalls: 5, ModelTurns: 5, SingleCallTurns: 5, CallsBeforeFirstEdit: 3, MsToFirstEdit: 7_000}},
	} {
		got := summariseRunEfficiency(rows(c.h, c.fixture))
		if got.ToolCalls != c.want.ToolCalls || got.ModelTurns != c.want.ModelTurns || got.SingleCallTurns != c.want.SingleCallTurns ||
			got.CallsBeforeFirstEdit != c.want.CallsBeforeFirstEdit || got.MsToFirstEdit != c.want.MsToFirstEdit || got.DiscoveryCalls != 0 || got.InstructionBytes != 30_000 {
			t.Errorf("%s: %+v, want %+v", c.name, got, c.want)
		}
	}

	// Calls made together are one model turn; finding a tool is a discovery call.
	at := func(s int) time.Time { return t0.Add(time.Duration(s) * time.Second) }
	got := summariseRunEfficiency([]store.RunEfficiencyEventsRow{
		{Type: "lifecycle", State: "turn_started", At: at(0), InstructionBytes: 50_000},
		{Type: "tool_call", At: at(1), CallID: "a", Tool: "ToolSearch"},
		{Type: "tool_result", At: at(2), CallID: "a", Tool: "ToolSearch"},
		{Type: "tool_call", At: at(3), CallID: "b", Tool: "Read", FilePath: "/home/agent/.gemini/antigravity-cli/mcp/lazyagents/get_ticket.json"},
		{Type: "tool_call", At: at(3), CallID: "c", Tool: "Read", FilePath: "/workspace/server/main.go"},
		{Type: "tool_call", At: at(3), CallID: "d", Tool: "Grep"},
		{Type: "tool_result", At: at(4), CallID: "b"}, {Type: "tool_result", At: at(4), CallID: "c"}, {Type: "tool_result", At: at(4), CallID: "d"},
		{Type: "lifecycle", State: "turn_started", At: at(60), InstructionBytes: 20_000},
		{Type: "tool_call", At: at(70), CallID: "e", Tool: "Edit"},
	})
	if got.ModelTurns != 3 || got.SingleCallTurns != 2 || got.DiscoveryCalls != 2 || got.MsToFirstEdit != 70_000 || got.InstructionBytes != 50_000 {
		t.Errorf("batched: %+v", got)
	}
}

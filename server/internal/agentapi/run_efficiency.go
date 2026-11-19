package agentapi

import (
	"regexp"
	"strconv"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// runEfficiency is where a ticket run's time and tokens went, worked out from
// its events for get_run. Fields that depend on per-call context sizes are
// only known for runs recorded after tool_call events carried
// context_tokens; they're omitted (0) for older runs.
type runEfficiency struct {
	// SetupMs is the workspace setup's wall time (clone, project setup, Nix
	// install), summed over setups: from each lifecycle "starting" to the
	// following "workspace_ready".
	SetupMs int64 `json:"setup_ms"`
	Setups  int   `json:"setups"`
	// ToolCalls counts the main agent's tool calls; sub agents' are excluded.
	ToolCalls int `json:"tool_calls"`
	// CallsBeforeFirstEdit is the main agent's tool calls before its first
	// file edit; -1 when it never edited a file.
	CallsBeforeFirstEdit int `json:"calls_before_first_edit"`
	// ContextAtFirstEdit is the prompt size of the request that made the
	// first edit (0 = unknown).
	ContextAtFirstEdit int64 `json:"context_tokens_at_first_edit,omitempty"`
	// PeakContext is the largest prompt size seen on a tool call (0 = unknown).
	PeakContext int64 `json:"peak_context_tokens,omitempty"`
	// ContextCrossed maps a prompt size to the 1-based tool call at which
	// the context first reached it: when a rollover at that limit could have
	// fired.
	ContextCrossed map[string]int `json:"context_crossed_at_call,omitempty"`
	// MsToFirstEdit is the wall time from the first turn starting to the main
	// agent's first file edit; -1 when it never edited a file.
	MsToFirstEdit int64 `json:"ms_to_first_edit"`
	// ModelTurns counts the main agent's batches of tool calls: calls that
	// arrive together, before any of their results, came from one model
	// request. SingleCallTurns are batches of one: serial lookups, each
	// paying a full model round-trip. Event order is the same on every
	// harness, so these compare across Claude Code, Codex and agy.
	ModelTurns      int `json:"model_turns"`
	SingleCallTurns int `json:"single_call_turns"`
	// DiscoveryCalls are tool calls spent finding a tool rather than using
	// one: Claude Code's ToolSearch, and agy reading a lazy MCP tool's
	// schema file (<appDataDir>/mcp/<server>/<tool>.json).
	DiscoveryCalls int `json:"discovery_calls"`
	// InstructionBytes is the largest generated instruction section a turn
	// started with (0 = recorded before turns carried it).
	InstructionBytes int64 `json:"instruction_bytes,omitempty"`
	TestRuns         int   `json:"test_runs"`
	TestMs           int64 `json:"test_ms"`
	// Tests lists the test commands (clipped), in order, with their wall time.
	Tests []testRun `json:"tests,omitempty"`
}

type testRun struct {
	Command string `json:"command"`
	Ms      int64  `json:"ms,omitempty"` // 0 when its result never arrived
}

var (
	editTools = map[string]bool{"Edit": true, "Write": true, "MultiEdit": true, "NotebookEdit": true, "apply_patch": true}
	// testCommand matches shell commands that run a test suite.
	testCommand       = regexp.MustCompile(`\b(go test|(npm|pnpm|yarn)( run)? (test|e2e)[\w:-]*|npx (playwright|vitest|jest)|playwright test|vitest|jest|pytest|cargo test|make (test|e2e|check)\b|e2e-stack/run\.sh)`)
	contextThresholds = []int64{100_000, 150_000, 200_000}
	agySchemaRead     = regexp.MustCompile(`/mcp/[^/]+/[^/]+\.json$`)
)

const maxListedTests = 30

func summariseRunEfficiency(evs []store.RunEfficiencyEventsRow) runEfficiency {
	out := runEfficiency{CallsBeforeFirstEdit: -1, MsToFirstEdit: -1}
	var setupStart, firstTurn time.Time
	batch := 0 // tool calls in the current batch
	endBatch := func() {
		if batch > 0 {
			out.ModelTurns++
			if batch == 1 {
				out.SingleCallTurns++
			}
		}
		batch = 0
	}
	pending := map[string]int{} // tool call id → index in out.Tests
	testAt := map[string]time.Time{}
	for _, e := range evs {
		switch e.Type {
		case "lifecycle":
			switch e.State {
			case "starting":
				setupStart = e.At
			case "workspace_ready":
				if !setupStart.IsZero() {
					out.SetupMs += e.At.Sub(setupStart).Milliseconds()
					out.Setups++
					setupStart = time.Time{}
				}
			case "turn_started":
				endBatch()
				if firstTurn.IsZero() {
					firstTurn = e.At
				}
				out.InstructionBytes = max(out.InstructionBytes, e.InstructionBytes)
			}
		case "tool_call":
			out.ToolCalls++
			batch++
			if e.Tool == "ToolSearch" || (e.Tool == "Read" && agySchemaRead.MatchString(e.FilePath)) {
				out.DiscoveryCalls++
			}
			if n := e.ContextTokens; n > 0 {
				out.PeakContext = max(out.PeakContext, n)
				for _, limit := range contextThresholds {
					k := strconv.FormatInt(limit, 10)
					if _, seen := out.ContextCrossed[k]; !seen && n >= limit {
						if out.ContextCrossed == nil {
							out.ContextCrossed = map[string]int{}
						}
						out.ContextCrossed[k] = out.ToolCalls
					}
				}
			}
			if editTools[e.Tool] && out.CallsBeforeFirstEdit < 0 {
				out.CallsBeforeFirstEdit = out.ToolCalls - 1
				out.ContextAtFirstEdit = e.ContextTokens
				if !firstTurn.IsZero() {
					out.MsToFirstEdit = e.At.Sub(firstTurn).Milliseconds()
				}
			}
			if (e.Tool == "Bash" || e.Tool == "shell") && testCommand.MatchString(e.Command) {
				out.TestRuns++
				if len(out.Tests) < maxListedTests {
					cmd := e.Command
					if r := []rune(cmd); len(r) > 200 {
						cmd = string(r[:200]) + "…"
					}
					out.Tests = append(out.Tests, testRun{Command: cmd})
					pending[e.CallID] = len(out.Tests) - 1
				} else {
					pending[e.CallID] = -1
				}
				testAt[e.CallID] = e.At
			}
		case "tool_result":
			endBatch()
			i, ok := pending[e.CallID]
			if !ok {
				continue
			}
			ms := e.At.Sub(testAt[e.CallID]).Milliseconds()
			out.TestMs += ms
			if i >= 0 {
				out.Tests[i].Ms = ms
			}
			delete(pending, e.CallID)
		}
	}
	endBatch()
	return out
}

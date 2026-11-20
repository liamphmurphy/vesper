package runs

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func liveEvent(t *testing.T, typ string, payload map[string]any) store.LiveTurnEventsRow {
	t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	return store.LiveTurnEventsRow{Type: typ, Payload: b}
}

// A long reply's opening steps reach the aside as an outline, not dropped:
// the aside has to see what the reply set out to do, not only its last steps.
func TestRenderLiveTurnKeepsLongReplyFromItsStart(t *testing.T) {
	rows := []store.LiveTurnEventsRow{
		liveEvent(t, "message", map[string]any{"role": "assistant", "text": "Plan: migrate the retry queue to\nexponential backoff."}),
	}
	for i := range 150 {
		rows = append(rows,
			liveEvent(t, "tool_call", map[string]any{"tool": "Read", "input": map[string]any{"file_path": fmt.Sprintf("/repo/f%03d.go", i)}}),
			liveEvent(t, "tool_result", map[string]any{"output": strings.Repeat("ok ", 150)}),
		)
		if i == 3 {
			rows = append(rows, liveEvent(t, "tool_result", map[string]any{"output": "go: build failed", "is_error": true}))
		}
	}
	rows = append(rows, liveEvent(t, "message", map[string]any{"role": "assistant", "text": "Now running the tests."}))

	got := renderLiveTurn(rows, 90*time.Second)

	before, after, ok := strings.Cut(got, "Latest steps, in full:")
	if !ok {
		t.Fatalf("no full section:\n%s", got)
	}
	for _, want := range []string{
		"Earlier steps, in brief:",
		"- You wrote: Plan: migrate the retry queue to exponential backoff.",
		`- Called Read {"file_path":"/repo/f000.go"}`,
		"- Error: go: build failed",
	} {
		if !strings.Contains(before, want) {
			t.Errorf("outline lacks %q:\n%s", want, before)
		}
	}
	if strings.Contains(before, "ok ok") {
		t.Errorf("a successful result reached the outline:\n%s", before)
	}
	if strings.Contains(got, "earliest steps left out") {
		t.Errorf("steps were dropped though the outline has room:\n%s", got)
	}
	if !strings.Contains(after, "Called Read {\"file_path\":\"/repo/f149.go\"}") || !strings.Contains(after, "> Now running the tests.") {
		t.Errorf("latest steps aren't in full:\n%s", after)
	}
	if n := len([]rune(got)); n > asideSnapshotRunes+asideOutlineRunes+500 {
		t.Errorf("snapshot is %d runes, over its budget", n)
	}
}

// A short reply is given in full, with no outline.
func TestRenderLiveTurnShortReplyInFull(t *testing.T) {
	got := renderLiveTurn([]store.LiveTurnEventsRow{
		liveEvent(t, "message", map[string]any{"role": "assistant", "text": "Working on it."}),
		liveEvent(t, "tool_call", map[string]any{"tool": "Bash", "input": map[string]any{"command": "go test ./..."}}),
	}, time.Second)
	if strings.Contains(got, "in brief") || strings.Contains(got, "left out") {
		t.Fatalf("a short reply was outlined:\n%s", got)
	}
	if !strings.Contains(got, "Working on it.") || !strings.Contains(got, `Called Bash {"command":"go test ./..."}`) {
		t.Fatalf("short reply incomplete:\n%s", got)
	}
}

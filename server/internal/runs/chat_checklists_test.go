package runs

import (
	"strings"
	"testing"
)

func TestApplyChecklistState(t *testing.T) {
	body := strings.Join([]string{
		"Here is the plan:",
		"- [ ] First step",
		"- [x] Second step",
		"```md",
		"- [ ] Ignored inside fence",
		"```",
		"  * [ ] Third step",
	}, "\n")

	items := ExtractChecklistItems(body)
	if len(items) != 3 {
		t.Fatalf("expected 3 items outside code fences, got %d: %+v", len(items), items)
	}
	if items[0].Checked || !items[1].Checked || items[2].Checked {
		t.Fatalf("unexpected initial checked states: %+v", items)
	}

	got := ApplyChecklistState(body, map[string]bool{"0": true, "1": false, "2": true})
	if !strings.Contains(got, "- [x] First step") {
		t.Fatalf("item 0 not ticked: %s", got)
	}
	if !strings.Contains(got, "- [ ] Second step") {
		t.Fatalf("item 1 not unticked: %s", got)
	}
	if !strings.Contains(got, "- [ ] Ignored inside fence") {
		t.Fatalf("fenced task item should stay untouched: %s", got)
	}
	if !strings.Contains(got, "  * [x] Third step") {
		t.Fatalf("item 2 not ticked: %s", got)
	}
}

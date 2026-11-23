package runs

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

var taskListLineRe = regexp.MustCompile(`^(\s*(?:[-*+]|\d+\.)\s+)\[([ xX])\](\s+.*)$`)

// ChecklistItem is one markdown task-list item extracted from a message outside fenced code blocks.
type ChecklistItem struct {
	Index   int
	Checked bool
	Text    string
}

// ParseChecklistState decodes a chat_messages.checklist_state JSONB column.
func ParseChecklistState(raw []byte) map[string]bool {
	if len(raw) == 0 {
		return nil
	}
	var out map[string]bool
	if err := json.Unmarshal(raw, &out); err != nil || len(out) == 0 {
		return nil
	}
	return out
}

// ExtractChecklistItems extracts all GFM task-list items outside fenced code blocks in 0-based order.
func ExtractChecklistItems(body string) []ChecklistItem {
	lines := strings.Split(body, "\n")
	var items []ChecklistItem
	var fenceChar byte
	var fenceLen int
	idx := 0
	for _, line := range lines {
		if ch, n, opened := checklistFenceOpener(line); opened {
			if fenceChar == 0 {
				fenceChar, fenceLen = ch, n
				continue
			}
		}
		if fenceChar != 0 {
			if checklistFenceCloser(line, fenceChar, fenceLen) {
				fenceChar, fenceLen = 0, 0
			}
			continue
		}
		if m := taskListLineRe.FindStringSubmatch(line); m != nil {
			checked := m[2] == "x" || m[2] == "X"
			items = append(items, ChecklistItem{
				Index:   idx,
				Checked: checked,
				Text:    strings.TrimSpace(m[3]),
			})
			idx++
		}
	}
	return items
}

// ApplyChecklistState rewrites task-list markers in body using persisted state overrides.
func ApplyChecklistState(body string, state map[string]bool) string {
	if len(state) == 0 {
		return body
	}
	lines := strings.Split(body, "\n")
	var fenceChar byte
	var fenceLen int
	idx := 0
	changed := false
	for i, line := range lines {
		if ch, n, opened := checklistFenceOpener(line); opened {
			if fenceChar == 0 {
				fenceChar, fenceLen = ch, n
				continue
			}
		}
		if fenceChar != 0 {
			if checklistFenceCloser(line, fenceChar, fenceLen) {
				fenceChar, fenceLen = 0, 0
			}
			continue
		}
		if m := taskListLineRe.FindStringSubmatch(line); m != nil {
			if checked, ok := state[strconv.Itoa(idx)]; ok {
				mark := " "
				if checked {
					mark = "x"
				}
				lines[i] = m[1] + "[" + mark + "]" + m[3]
				changed = true
			}
			idx++
		}
	}
	if !changed {
		return body
	}
	return strings.Join(lines, "\n")
}

// ChecklistPromptNotice formats persisted checklist states from recent assistant replies so
// continuing an active session exposes the person's latest ticks to the persona.
func ChecklistPromptNotice(ctx context.Context, q *store.Queries, sessionID uuid.UUID) (string, error) {
	rows, err := q.ListRecentAssistantChecklistMessages(ctx, sessionID)
	if err != nil || len(rows) == 0 {
		return "", err
	}
	var b strings.Builder
	const maxLines = 30
	written := 0
	// rows are newest-first; show oldest-first for natural reading order.
	for i := len(rows) - 1; i >= 0 && written < maxLines; i-- {
		r := rows[i]
		state := ParseChecklistState(r.ChecklistState)
		if len(state) == 0 {
			continue
		}
		items := ExtractChecklistItems(r.BodyMd)
		if len(items) == 0 {
			continue
		}
		for _, item := range items {
			if written >= maxLines {
				break
			}
			checked := item.Checked
			if v, ok := state[strconv.Itoa(item.Index)]; ok {
				checked = v
			}
			mark := " "
			if checked {
				mark = "x"
			}
			if written == 0 {
				b.WriteString("\n\n(Vesper: current checklist state from earlier replies in this chat:\n")
			}
			fmt.Fprintf(&b, "- [%s] %s\n", mark, item.Text)
			written++
		}
	}
	if written == 0 {
		return "", nil
	}
	b.WriteString(")")
	return b.String(), nil
}

func checklistFenceOpener(line string) (byte, int, bool) {
	trimmed := strings.TrimLeft(line, " \t")
	if len(trimmed) < 3 {
		return 0, 0, false
	}
	ch := trimmed[0]
	if ch != '`' && ch != '~' {
		return 0, 0, false
	}
	n := 0
	for n < len(trimmed) && trimmed[n] == ch {
		n++
	}
	if n < 3 {
		return 0, 0, false
	}
	return ch, n, true
}

func checklistFenceCloser(line string, ch byte, minLen int) bool {
	trimmed := strings.TrimSpace(line)
	if len(trimmed) < minLen {
		return false
	}
	for i := 0; i < len(trimmed); i++ {
		if trimmed[i] != ch {
			return false
		}
	}
	return true
}

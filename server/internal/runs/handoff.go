package runs

import (
	"fmt"
	"strings"
	"unicode/utf8"
)

const (
	// DefaultHandoffChars bounds the rendered handoff header and history.
	DefaultHandoffChars = 24000
	// handoffRows bounds the history query; older rows are only counted.
	handoffRows = 40
	// handoffRowChars clips one message body once its artifacts are compacted.
	handoffRowChars = 8000
)

// HandoffMessage is one prior chat message offered to a new harness segment.
type HandoffMessage struct {
	Seq            int64
	Role           string
	Harness, Model string
	// Persona names who wrote an assistant message in a chat with several
	// personas; empty otherwise.
	Persona string
	Body    string
}

const handoffClip = "\n[…message clipped]"

// handoffLead opens a handoff's header; an aside replaces it with its own.
const (
	handoffLead = "This conversation continues from earlier turns answered by a different harness or model."
	compactLead = "This conversation was compacted onto a fresh context window on the same harness. Prior messages are below, oldest first, as context only."
	forkLead    = "This conversation was forked from an earlier chat at this point. The prior messages up to the fork point are below, oldest first, as context only."
)

// HandoffOptions customizes a rendered handoff header, git summary, and footer.
type HandoffOptions struct {
	Lead     string
	Focus    string
	GitBrief string
	Footer   string
}

func handoffHeader(omitted int) string {
	return handoffHeaderWith(omitted, "", "")
}

func handoffHeaderWith(omitted int, lead, focus string) string {
	h := lead
	if h == "" {
		h = handoffLead + " Their messages are below, oldest first, as context only."
	}
	if omitted > 0 {
		h += fmt.Sprintf(" %d earlier message(s) were omitted to fit.", omitted)
	}
	if focus = strings.TrimSpace(focus); focus != "" {
		h += "\nCompaction focus requested by the user: " + focus
	}
	return h + "\n\n"
}

func handoffEntry(m HandoffMessage, body string) string {
	who := m.Role
	if m.Persona != "" {
		who += " " + m.Persona
	}
	if m.Harness != "" {
		who += " (" + m.Harness
		if m.Model != "" {
			who += "/" + m.Model
		}
		who += ")"
	}
	return fmt.Sprintf("[%d] %s:\n%s\n\n", m.Seq, who, body)
}

const handoffFooter = "---\nNew message from the user (answer this one):\n"

// relayFooter ends the handoff of a turn one persona handed to another: there
// is no new message from the user, only the hand-over note.
const relayFooter = "---\n"

// RenderHandoff builds the prompt for the first turn of a follow-up segment.
// history is newest first (as queried); total is the full count of prior
// messages. Header and history together stay within budget characters; the
// newest messages win and the header reports how many were omitted. The new
// message follows the footer, outside the budget. The newest SVG and app
// blocks, the chat's canvases and its image prompts follow the history, also
// outside it.
func RenderHandoff(history []HandoffMessage, total int, budget int, hc HandoffContext, body string) string {
	return renderHandoff(history, total, budget, hc, handoffFooter, body)
}

func renderHandoff(history []HandoffMessage, total int, budget int, hc HandoffContext, footer, body string) string {
	return renderHandoffWith(history, total, budget, hc, HandoffOptions{Footer: footer}, body)
}

func renderHandoffWith(history []HandoffMessage, total int, budget int, hc HandoffContext, opts HandoffOptions, body string) string {
	history, pinned := compactArtifacts(history)
	if budget <= 0 {
		budget = DefaultHandoffChars
	}
	if total < len(history) {
		total = len(history)
	}
	footer := opts.Footer
	if footer == "" {
		footer = handoffFooter
	}
	// Reserve for the longest header this call can produce.
	left := budget - utf8.RuneCountInString(handoffHeaderWith(total, opts.Lead, opts.Focus))
	var kept []string
	for _, m := range history {
		entry := handoffEntry(m, m.Body)
		n := utf8.RuneCountInString(entry)
		if n > left {
			if len(kept) > 0 {
				break
			}
			// The newest message alone is too big: keep its start.
			room := left - utf8.RuneCountInString(handoffEntry(m, "")) - utf8.RuneCountInString(handoffClip)
			if room <= 0 {
				break
			}
			entry = handoffEntry(m, string([]rune(m.Body)[:min(room, utf8.RuneCountInString(m.Body))])+handoffClip)
			n = utf8.RuneCountInString(entry)
		}
		kept = append(kept, entry)
		left -= n
	}
	var b strings.Builder
	b.WriteString(handoffHeaderWith(total-len(kept), opts.Lead, opts.Focus))
	for i := len(kept) - 1; i >= 0; i-- {
		b.WriteString(kept[i])
	}
	b.WriteString(renderArtifacts(pinned, hc))
	if brief := strings.TrimSpace(opts.GitBrief); brief != "" {
		b.WriteString("## Workspace git state\n")
		b.WriteString(brief)
		b.WriteString("\n\n")
	}
	b.WriteString(footer)
	b.WriteString(body)
	return b.String()
}

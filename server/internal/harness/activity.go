package harness

import (
	"strings"
	"time"
	"unicode/utf8"
)

const (
	// activityHeartbeatEvery bounds how often a streaming thinking or reply
	// block emits a lifecycle heartbeat, keeping the chat pulse alive without
	// flooding run_events.
	activityHeartbeatEvery = 8 * time.Second
	// writingReplyMinBytes and writingReplyMinAge keep short opening lines and
	// narrated decisions before tool calls from flashing "drafting a reply".
	writingReplyMinBytes = 160
	writingReplyMinAge   = 2 * time.Second
	// thinkingLineLimit caps a single buffered thinking line while scanning
	// for headings so long prose paragraphs never grow unbounded.
	thinkingLineLimit = 256
	// activityDetailMaxRunes caps the heading text emitted on activity events.
	activityDetailMaxRunes = 64
)

// activityTracker turns streaming thinking, text, and tool-input deltas into
// throttled lifecycle("activity") events so the chat status card knows whether
// a persona is actively thinking or drafting a reply rather than stalled.
type activityTracker struct {
	now               func() time.Time
	phase             string
	detail            string
	lastEmit          time.Time
	textStart         time.Time
	textBytes         int
	toolInputStart    time.Time
	thinkLine         []byte
	thinkLineOverflow bool
}

func (a *activityTracker) clock() time.Time {
	if a.now != nil {
		return a.now()
	}
	return time.Now()
}

// reset clears the active phase when a tool call, tool result, or complete
// assistant message takes over.
func (a *activityTracker) reset() {
	a.phase = ""
	a.detail = ""
	a.lastEmit = time.Time{}
	a.textStart = time.Time{}
	a.textBytes = 0
	a.toolInputStart = time.Time{}
	a.thinkLine = a.thinkLine[:0]
	a.thinkLineOverflow = false
}

// resetText restarts the prose threshold for a new assistant text block.
func (a *activityTracker) resetText() {
	a.textStart = time.Time{}
	a.textBytes = 0
}

// touch records that another status-bearing lifecycle event (e.g. reply_block)
// just emitted, so a heartbeat isn't sent immediately after it.
func (a *activityTracker) touch() {
	a.lastEmit = a.clock()
}

func (a *activityTracker) emit(phase, detail string) []Event {
	a.phase = phase
	if phase == "thinking" {
		if detail != "" {
			a.detail = detail
		}
	} else {
		a.detail = ""
	}
	a.lastEmit = a.clock()
	pl := map[string]any{"state": "activity", "phase": phase}
	if a.detail != "" {
		pl["detail"] = a.detail
	}
	return []Event{{"lifecycle", pl}}
}

// thinkingStart marks the start of a thinking block (or an active model step
// with no text yet) and emits immediately on transition, then throttles.
func (a *activityTracker) thinkingStart() []Event {
	if a.phase != "thinking" {
		a.detail = ""
		a.thinkLine = a.thinkLine[:0]
		a.thinkLineOverflow = false
		return a.emit("thinking", "")
	}
	if a.clock().Sub(a.lastEmit) >= activityHeartbeatEvery {
		return a.emit("thinking", a.detail)
	}
	return nil
}

// thinkingDelta consumes incremental thinking text, extracting standalone
// markdown headings as they complete and emitting on phase/heading changes or
// heartbeat intervals.
func (a *activityTracker) thinkingDelta(delta string) []Event {
	var heading string
	for len(delta) > 0 {
		i := strings.IndexByte(delta, '\n')
		if i < 0 {
			a.appendThinkLine(delta)
			break
		}
		a.appendThinkLine(delta[:i])
		if !a.thinkLineOverflow {
			if h := thinkingHeadingLine(string(a.thinkLine)); h != "" {
				heading = h
			}
		}
		a.thinkLine = a.thinkLine[:0]
		a.thinkLineOverflow = false
		delta = delta[i+1:]
	}
	if a.phase != "thinking" {
		a.detail = ""
		return a.emit("thinking", heading)
	}
	if heading != "" && heading != a.detail {
		return a.emit("thinking", heading)
	}
	if a.clock().Sub(a.lastEmit) >= activityHeartbeatEvery {
		return a.emit("thinking", a.detail)
	}
	return nil
}

func (a *activityTracker) appendThinkLine(s string) {
	if a.thinkLineOverflow {
		return
	}
	if len(a.thinkLine)+len(s) > thinkingLineLimit {
		a.thinkLine = a.thinkLine[:0]
		a.thinkLineOverflow = true
		return
	}
	a.thinkLine = append(a.thinkLine, s...)
}

// thinkingText handles snapshot-style reasoning updates (such as Codex
// item.started / item.updated) where each event carries the full text so far.
func (a *activityTracker) thinkingText(full string) []Event {
	heading := thinkingHeading(full)
	if a.phase != "thinking" {
		a.detail = ""
		return a.emit("thinking", heading)
	}
	if heading != "" && heading != a.detail {
		return a.emit("thinking", heading)
	}
	if a.clock().Sub(a.lastEmit) >= activityHeartbeatEvery {
		return a.emit("thinking", a.detail)
	}
	return nil
}

// textDelta tracks incremental assistant prose, transitioning to writing_reply
// once it clears the opening-line threshold and heartbeating thereafter.
func (a *activityTracker) textDelta(delta string) []Event {
	if delta == "" {
		return nil
	}
	now := a.clock()
	if a.textStart.IsZero() {
		a.textStart = now
	}
	a.textBytes += len(delta)
	return a.maybeWritingReply(now)
}

// textSnapshot tracks snapshot-style assistant prose updates (Codex).
func (a *activityTracker) textSnapshot(full string) []Event {
	if full == "" {
		return nil
	}
	now := a.clock()
	if a.textStart.IsZero() {
		a.textStart = now
	}
	a.textBytes = len(full)
	return a.maybeWritingReply(now)
}

func (a *activityTracker) maybeWritingReply(now time.Time) []Event {
	if a.textBytes < writingReplyMinBytes && now.Sub(a.textStart) < writingReplyMinAge {
		return nil
	}
	if a.phase != "writing_reply" {
		return a.emit("writing_reply", "")
	}
	if now.Sub(a.lastEmit) >= activityHeartbeatEvery {
		return a.emit("writing_reply", "")
	}
	return nil
}

// heartbeatIfDue emits a throttled heartbeat while streaming inside a fenced
// reply block (e.g. a long interactive app or SVG) so the turn stays alive.
func (a *activityTracker) heartbeatIfDue(phase string) []Event {
	if a.lastEmit.IsZero() || a.clock().Sub(a.lastEmit) < activityHeartbeatEvery {
		return nil
	}
	return a.emit(phase, a.detail)
}

// toolInputStartNow marks the beginning of a streaming tool_use block.
func (a *activityTracker) toolInputStartNow() {
	a.toolInputStart = a.clock()
}

// toolInputDelta keeps the pulse alive when a large tool call (such as Write
// on a long file) streams input_json_delta for many seconds before tool_use
// completes.
func (a *activityTracker) toolInputDelta() []Event {
	now := a.clock()
	if a.toolInputStart.IsZero() {
		a.toolInputStart = now
	}
	if now.Sub(a.toolInputStart) < writingReplyMinAge {
		return nil
	}
	if !a.lastEmit.IsZero() && now.Sub(a.lastEmit) < activityHeartbeatEvery {
		return nil
	}
	phase := a.phase
	if phase != "thinking" {
		phase = "thinking"
		a.detail = ""
	}
	return a.emit(phase, a.detail)
}

// thinkingHeading returns the newest safe standalone heading from a thinking
// block (such as "**Checking the test failure**" or "## Checking tests").
func thinkingHeading(text string) string {
	var latest string
	for _, line := range strings.Split(text, "\n") {
		if h := thinkingHeadingLine(line); h != "" {
			latest = h
		}
	}
	return latest
}

func thinkingHeadingLine(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	var candidate string
	switch {
	case strings.HasPrefix(s, "**") && strings.HasSuffix(s, "**") && len(s) > 4:
		inner := s[2 : len(s)-2]
		if strings.Contains(inner, "**") {
			return ""
		}
		candidate = inner
	case strings.HasPrefix(s, "#"):
		hashes := 0
		for hashes < len(s) && hashes < 3 && s[hashes] == '#' {
			hashes++
		}
		if hashes == 0 || hashes >= len(s) || (s[hashes] != ' ' && s[hashes] != '\t') {
			return ""
		}
		candidate = s[hashes+1:]
	default:
		return ""
	}
	candidate = strings.ReplaceAll(candidate, "`", "")
	candidate = strings.Join(strings.Fields(candidate), " ")
	candidate = strings.TrimRight(candidate, ":.")
	candidate = strings.TrimSpace(candidate)
	n := utf8.RuneCountInString(candidate)
	if n < 3 || n > 90 {
		return ""
	}
	for _, bad := range []string{"://", "=", "/Users/", "/home/", "/etc/", "/var/", "/tmp/"} {
		if strings.Contains(candidate, bad) {
			return ""
		}
	}
	if n > activityDetailMaxRunes {
		runes := []rune(candidate)
		candidate = strings.TrimSpace(string(runes[:activityDetailMaxRunes-1])) + "…"
	}
	return candidate
}

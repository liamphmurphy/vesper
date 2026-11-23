package harness

import (
	"bytes"
	"strings"
)

// richReplyBlocks are the fenced blocks the chat renders as something other
// than code. They can take a while to write and call no tool.
var richReplyBlocks = map[string]bool{
	"app":            true,
	"svg-image":      true,
	"svg-steps":      true,
	"chart":          true,
	"stats":          true,
	"mermaid":        true,
	"choices":        true,
	"workflow-run":   true,
	"recommend":      true,
	"gallery":        true,
	"product":        true,
	"diff":           true,
	"compare":        true,
	"timeline":       true,
	"tree":           true,
	"compare-images": true,
	"graph":          true,
	"plot":           true,
	"datatable":      true,
	"code-group":     true,
	"kv":             true,
	"json-tree":      true,
	"http":           true,
	"tabs":           true,
	"details":        true,
}

// replyScanner finds rich blocks in a reply as it streams, so the chat can say
// what's being written before the finished message arrives. A block is seen once
// its opening line is complete. Fences inside another code block don't count.
type replyScanner struct {
	// line is the unfinished line so far. It never holds a newline, so only
	// new text is searched, and appending keeps a long line (a minified app
	// or SVG) linear rather than recopied on every delta.
	line    []byte
	inFence bool
}

func (s *replyScanner) feed(text string) []Event {
	var out []Event
	for {
		i := strings.IndexByte(text, '\n')
		if i < 0 {
			s.line = append(s.line, text...)
			return out
		}
		s.line = append(s.line, text[:i]...)
		text = text[i+1:]
		line := bytes.TrimSpace(s.line)
		s.line = s.line[:0]
		if s.inFence {
			s.inFence = string(line) != "```"
			continue
		}
		if kind, ok := bytes.CutPrefix(line, []byte("```")); ok {
			s.inFence = true
			if richReplyBlocks[string(kind)] {
				out = append(out, Event{"lifecycle", map[string]any{"state": "reply_block", "kind": string(kind)}})
			}
		}
	}
}

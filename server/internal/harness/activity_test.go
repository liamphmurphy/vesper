package harness

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestThinkingHeading(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"standalone bold", "**Checking the test failure**\nLooking at stdout.", "Checking the test failure"},
		{"latest heading wins", "**First pass**\nnotes\n**Verifying `chat-ui.ts`:**\nmore", "Verifying chat-ui.ts"},
		{"markdown heading", "## Reviewing harness parsers.\nDetails.", "Reviewing harness parsers"},
		{"inline bold ignored", "**Note:** this is a full sentence, not a heading.\n", ""},
		{"multiple bold spans ignored", "**One** and **two**\n", ""},
		{"secret env rejected", "**API_KEY=secret**", ""},
		{"url rejected", "**https://example.com/private?token=1**", ""},
		{"host path rejected", "**Checking /Users/me/secret/file.go**", ""},
		{"long sentence rejected", "**" + strings.Repeat("word ", 20) + "**", ""},
		{"moderately long heading clipped", "## " + strings.Repeat("a", 70), strings.Repeat("a", 63) + "…"},
		{"plain prose ignored", "Just thinking through the next edit.", ""},
	}
	for _, tc := range cases {
		if got := thinkingHeading(tc.in); got != tc.want {
			t.Errorf("%s: got %q, want %q", tc.name, got, tc.want)
		}
	}
}

func TestActivityTrackerThrottlesAndTransitions(t *testing.T) {
	now := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	var a activityTracker
	a.now = func() time.Time { return now }

	// First thinking delta emits immediately.
	evs := a.thinkingStart()
	if len(evs) != 1 || evs[0].Payload["state"] != "activity" || evs[0].Payload["phase"] != "thinking" {
		t.Fatalf("start = %+v", evs)
	}
	// Further plain thinking inside the throttle window emits nothing.
	now = now.Add(3 * time.Second)
	if evs := a.thinkingDelta("considering options\n"); len(evs) != 0 {
		t.Fatalf("throttled delta emitted: %+v", evs)
	}
	// A new standalone heading emits immediately even inside the throttle window.
	evs = a.thinkingDelta("**Checking ")
	if len(evs) != 0 {
		t.Fatalf("partial heading emitted early: %+v", evs)
	}
	evs = a.thinkingDelta("branch state**\n")
	if len(evs) != 1 || evs[0].Payload["detail"] != "Checking branch state" {
		t.Fatalf("heading emit = %+v", evs)
	}
	// Heartbeat fires once the interval elapses and keeps the latest detail.
	now = now.Add(activityHeartbeatEvery)
	evs = a.thinkingDelta("still checking\n")
	if len(evs) != 1 || evs[0].Payload["phase"] != "thinking" || evs[0].Payload["detail"] != "Checking branch state" {
		t.Fatalf("heartbeat = %+v", evs)
	}
	// Short prose doesn't trigger writing_reply immediately.
	if evs := a.textDelta("Let me check."); len(evs) != 0 {
		t.Fatalf("short text triggered writing_reply: %+v", evs)
	}
	// Clearing the byte threshold switches to writing_reply and clears thinking detail.
	evs = a.textDelta(strings.Repeat("x", writingReplyMinBytes))
	if len(evs) != 1 || evs[0].Payload["phase"] != "writing_reply" {
		t.Fatalf("writing_reply = %+v", evs)
	}
	if _, hasDetail := evs[0].Payload["detail"]; hasDetail {
		t.Fatalf("writing_reply leaked thinking detail: %+v", evs[0].Payload)
	}
	// Reset clears state so the next thinking block emits immediately again.
	a.reset()
	if evs := a.thinkingStart(); len(evs) != 1 || evs[0].Payload["phase"] != "thinking" {
		t.Fatalf("after reset = %+v", evs)
	}
}

func TestClaudeStreamsThinkingAndWritingActivity(t *testing.T) {
	now := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	p := (ClaudeCode{}).NewParser("opus-5.5").(*claudeParser)
	p.activity.now = func() time.Time { return now }

	stream := func(ev map[string]any) []Event {
		b, _ := json.Marshal(map[string]any{"type": "stream_event", "event": ev})
		return p.Line(b)
	}

	evs := stream(map[string]any{"type": "content_block_start", "content_block": map[string]any{"type": "thinking"}})
	if len(evs) != 1 || evs[0].Payload["state"] != "activity" || evs[0].Payload["phase"] != "thinking" {
		t.Fatalf("thinking start = %+v", evs)
	}
	evs = stream(map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "thinking_delta", "thinking": "**Reviewing test failures**\n"}})
	if len(evs) != 1 || evs[0].Payload["detail"] != "Reviewing test failures" {
		t.Fatalf("thinking heading = %+v", evs)
	}

	// Large tool input streaming heartbeats after the initial delay + throttle.
	stream(map[string]any{"type": "content_block_start", "content_block": map[string]any{"type": "tool_use"}})
	now = now.Add(activityHeartbeatEvery)
	evs = stream(map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "input_json_delta", "partial_json": `{"content":"..."}`}})
	if len(evs) != 1 || evs[0].Payload["state"] != "activity" {
		t.Fatalf("tool input heartbeat = %+v", evs)
	}

	// Subagent stream events must never drive the main chat status.
	sub, _ := json.Marshal(map[string]any{
		"type":               "stream_event",
		"parent_tool_use_id": "toolu_parent",
		"event":              map[string]any{"type": "content_block_start", "content_block": map[string]any{"type": "thinking"}},
	})
	if got := p.Line(sub); len(got) != 0 {
		t.Fatalf("subagent stream emitted: %+v", got)
	}

	// Writing a long reply switches to writing_reply.
	stream(map[string]any{"type": "content_block_start", "content_block": map[string]any{"type": "text"}})
	evs = stream(map[string]any{"type": "content_block_delta", "delta": map[string]any{"type": "text_delta", "text": strings.Repeat("a", writingReplyMinBytes)}})
	if len(evs) != 1 || evs[0].Payload["phase"] != "writing_reply" {
		t.Fatalf("writing_reply = %+v", evs)
	}
}

func TestAntigravityStreamsActivityAndPreservesToolSummary(t *testing.T) {
	now := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	p := (Antigravity{}).NewParser("gemini-4-neon").(*agyParser)
	p.activity.now = func() time.Time { return now }

	// Active agent_response with no text yet reports thinking.
	evs := p.Line([]byte(`{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"ACTIVE","step_type":"agent_response"}}`))
	if len(evs) != 1 || evs[0].Payload["state"] != "activity" || evs[0].Payload["phase"] != "thinking" {
		t.Fatalf("active empty response = %+v", evs)
	}
	// Thinking delta with a heading updates the detail.
	evs = p.Line([]byte(`{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"ACTIVE","step_type":"agent_response","thinking_delta":"**Checking migration SQL**\n"}}`))
	if len(evs) != 1 || evs[0].Payload["detail"] != "Checking migration SQL" {
		t.Fatalf("thinking delta = %+v", evs)
	}
	// Streaming reply text triggers writing_reply and rich reply blocks.
	longText := strings.Repeat("Here are the findings. ", 10)
	evs = p.Line([]byte(`{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":` + mustJSON(longText) + `}}`))
	if len(evs) != 1 || evs[0].Payload["phase"] != "writing_reply" {
		t.Fatalf("writing_reply = %+v", evs)
	}
	evs = p.Line([]byte(`{"event":"step_update","step_update":{"conversation_id":"c","step_index":1,"state":"ACTIVE","step_type":"agent_response","text_delta":` + mustJSON("\n```chart\n") + `}}`))
	if len(evs) != 1 || evs[0].Payload["state"] != "reply_block" || evs[0].Payload["kind"] != "chart" {
		t.Fatalf("reply_block = %+v", evs)
	}
	// run_command preserves toolSummary as description on Bash.
	evs = p.Line([]byte(`{"event":"step_update","step_update":{"conversation_id":"c","step_index":2,"state":"ACTIVE","step_type":"tool","tool_name":"run_command","tool_info":{"name":"run_command","parameters":{"CommandLine":"go test ./internal/harness","toolSummary":"Run harness parser tests"}}}}`))
	if len(evs) != 1 || evs[0].Type != "tool_call" {
		t.Fatalf("run_command = %+v", evs)
	}
	in, _ := evs[0].Payload["input"].(map[string]any)
	if in["command"] != "go test ./internal/harness" || in["description"] != "Run harness parser tests" {
		t.Fatalf("normalized Bash input = %+v", in)
	}
}

func TestCodexStreamsReasoningAndWritingActivity(t *testing.T) {
	now := time.Date(2026, 11, 19, 10, 0, 0, 0, time.UTC)
	p := (Codex{}).NewParser("gpt-5-codex").(*codexParser)
	p.activity.now = func() time.Time { return now }

	// item.started + item.updated for reasoning emit thinking phase + heading.
	evs := p.Line([]byte(`{"type":"item.started","item":{"id":"r1","type":"reasoning","text":""}}`))
	if len(evs) != 1 || evs[0].Payload["state"] != "activity" || evs[0].Payload["phase"] != "thinking" {
		t.Fatalf("reasoning started = %+v", evs)
	}
	evs = p.Line([]byte(`{"type":"item.updated","item":{"id":"r1","type":"reasoning","text":"**Checking parser tests**\nReviewing edge cases."}}`))
	if len(evs) != 1 || evs[0].Payload["detail"] != "Checking parser tests" {
		t.Fatalf("reasoning updated = %+v", evs)
	}
	// item.completed emits the full thinking message and resets activity.
	evs = p.Line([]byte(`{"type":"item.completed","item":{"id":"r1","type":"reasoning","text":"**Checking parser tests**\nReviewing edge cases."}}`))
	if len(evs) != 1 || evs[0].Type != "message" || evs[0].Payload["kind"] != "thinking" {
		t.Fatalf("reasoning completed = %+v", evs)
	}
	// Streaming agent_message triggers writing_reply once past threshold.
	longReply := strings.Repeat("Summary of changes. ", 10)
	evs = p.Line([]byte(`{"type":"item.updated","item":{"id":"m1","type":"agent_message","text":` + mustJSON(longReply) + `}}`))
	if len(evs) != 1 || evs[0].Payload["phase"] != "writing_reply" {
		t.Fatalf("agent_message updated = %+v", evs)
	}
	// Rich block spotted in updated agent_message snapshot.
	evs = p.Line([]byte(`{"type":"item.updated","item":{"id":"m1","type":"agent_message","text":` + mustJSON(longReply+"\n```mermaid\n") + `}}`))
	if len(evs) != 1 || evs[0].Payload["state"] != "reply_block" || evs[0].Payload["kind"] != "mermaid" {
		t.Fatalf("codex reply_block = %+v", evs)
	}
}

func mustJSON(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

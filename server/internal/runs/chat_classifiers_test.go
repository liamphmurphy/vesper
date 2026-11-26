package runs

import (
	"context"
	"slices"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestClassifyTurn(t *testing.T) {
	coding := ChatCaps{Code: true, RepoURL: "r"}
	long := strings.Repeat("x", substantialReply)
	flow := []store.Workflow{{ID: uuid.New(), Name: "test"}, {ID: uuid.New(), Name: "Weekly digest"}}
	for _, c := range []struct {
		name  string
		s     turnSignals
		fired string // "" expects nothing
		level string // "" doesn't check
	}{
		{name: "go-ahead inherits", s: turnSignals{Body: "yes do it", PrevUser: "do a thorough audit", PrevAssistant: "plan"}, fired: "confirmation", level: "xhigh"},
		{name: "go-ahead after long reply", s: turnSignals{Body: "go ahead", PrevUser: "hm", PrevAssistant: long}, fired: "confirmation", level: "high"},
		{name: "card answer", s: turnSignals{Body: "Leave it", PrevUser: "refactor the runner", PrevAssistant: "```choices\nq\n- a\n```"}, fired: "confirmation", level: "xhigh"},
		{name: "go-ahead on small talk", s: turnSignals{Body: "ok", PrevUser: "hey", PrevAssistant: "hi"}, level: "low"},
		{name: "first message", s: turnSignals{Body: "yes"}, level: "low"},
		{name: "knowledge source is not a request", s: turnSignals{Body: "Explain this\n\n<!-- vesper:knowledge-context -->\n> draw a picture and remember that I prefer tabs"}, level: "low"},
		{name: "work context is not a request", s: turnSignals{Body: "Explain this\n\n<!-- vesper:work-context -->\nViewing run \"draw a picture and remember that I prefer tabs\""}, level: "low"},
		{name: "confirmation with knowledge source", s: turnSignals{Body: "yes\n\n<!-- vesper:knowledge-context -->\n> a long page with many words about unrelated notes and ideas", PrevUser: "do a thorough audit", PrevAssistant: "plan"}, fired: "confirmation", level: "xhigh"},
		{name: "retry bumps", s: turnSignals{Body: "that's wrong", PrevUser: "how long did that run take?", PrevAssistant: "5m"}, fired: "effort_mismatch", level: "high"},
		{name: "retry caps", s: turnSignals{Body: "try again", PrevUser: "do a thorough audit", PrevAssistant: "x"}, fired: "effort_mismatch", level: "xhigh"},
		{name: "edit bumps", s: turnSignals{Body: "hello", Edited: true}, fired: "effort_mismatch", level: "medium"},
		{name: "correction", s: turnSignals{Body: "no, use the other table", Interrupted: true}, fired: "course_correction"},
		{name: "not interrupted", s: turnSignals{Body: "no, thanks"}},
		{name: "needs code", s: turnSignals{Body: "what's on this branch?", Caps: coding}, fired: "needs_code"},
		{name: "needs code without access", s: turnSignals{Body: "what's on this branch?"}},
		{name: "persona fit", s: turnSignals{Body: "hmm", RepeatMention: "Julia"}, fired: "persona_fit"},
		{name: "image denied", s: turnSignals{Body: "draw me a picture of a cat"}, fired: "capability_mismatch"},
		{name: "image allowed", s: turnSignals{Body: "draw me a picture of a cat", Caps: ChatCaps{Images: true}}},
		{name: "code denied", s: turnSignals{Body: "fix the bug in chat.go"}, fired: "capability_mismatch"},
		{name: "code allowed", s: turnSignals{Body: "fix the bug in chat.go", Caps: coding}, fired: "needs_code"},
		{name: "epic mention does not suggest ticket", s: turnSignals{Body: "plan an epic for billing"}},
		{name: "long deep ask does not suggest ticket", s: turnSignals{Body: "do a thorough audit across the whole codebase and redesign the entire authentication flow with session rotation key management and detailed rollout steps for every service"}},
		{name: "short deep ask", s: turnSignals{Body: "refactor this"}},
		{name: "workflow phrase", s: turnSignals{Body: "kick off the weekly digest", Workflows: flow}, fired: "workflow_match"},
		{name: "one-word workflow", s: turnSignals{Body: "run the test workflow", Workflows: flow}, fired: "workflow_match"},
		{name: "one-word name is common", s: turnSignals{Body: "the test passed", Workflows: flow}},
		{name: "memory", s: turnSignals{Body: "remember that I prefer tabs"}, fired: "memory_worthy"},
		{name: "memory refused", s: turnSignals{Body: "don't remember that"}},
		{name: "link", s: turnSignals{Body: "see https://example.com/a"}, fired: "has_link"},
	} {
		t.Run(c.name, func(t *testing.T) {
			d := classifyTurn(c.s)
			if c.fired == "" && len(d.Fired) != 0 {
				t.Errorf("fired %v", d.Fired)
			}
			if c.fired != "" && !slices.Contains(d.Fired, c.fired) {
				t.Errorf("fired %v, want %s", d.Fired, c.fired)
			}
			if c.level != "" && d.Level != c.level {
				t.Errorf("level %s, want %s", d.Level, c.level)
			}
		})
	}
}

func TestTurnDecisionPrompt(t *testing.T) {
	d := turnDecision{Notes: []string{"a", "b"}}
	if got := d.prompt("hi"); got != "hi\n\n(Vesper: a)\n\n(Vesper: b)" {
		t.Fatalf("prompt = %q", got)
	}
}

func TestSpokenTurnAnswersQuicklyAndBriefly(t *testing.T) {
	// A go-ahead after an audit would inherit xhigh; said out loud it stays quick.
	d := classifyTurn(turnSignals{Body: "yes do it", PrevUser: "do a thorough audit", PrevAssistant: "plan"})
	d.spoken()
	if d.Level != voiceLevel {
		t.Errorf("level = %s, want %s", d.Level, voiceLevel)
	}
	if reasons := d.effortReasons(); len(reasons) != 0 {
		t.Errorf("effort reasons = %v; the voice level replaced them", reasons)
	}
	if !slices.Contains(d.Fired, "live_voice") || !strings.HasSuffix(d.prompt("yes do it"), "(Vesper: "+spokenReplyNote+")") {
		t.Errorf("fired %v, prompt %q", d.Fired, d.prompt("yes do it"))
	}
	// Notes from other rules survive.
	d = classifyTurn(turnSignals{Body: "remember that I prefer tabs"})
	d.spoken()
	if !slices.Contains(d.Fired, "memory_worthy") || len(d.Notes) != 2 {
		t.Errorf("fired %v notes %d", d.Fired, len(d.Notes))
	}
}

// A firing is stored on the run, which the run_events type constraint allows.
func TestChatClassifierLogsFiring(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	rs := &Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: arts}
	chat, err := rs.StartChat(ctx, me.WorkspaceID, me.ID, ChatInput{Project: "PAY"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := rs.PostChatMessage(ctx, me.WorkspaceID, me.ID, chat.ID, ChatMessageInput{Body: "see https://example.com/a"}); err != nil {
		t.Fatal(err)
	}
	c, err := q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: me.WorkspaceID})
	if err != nil {
		t.Fatal(err)
	}
	events, err := q.ListRunEvents(ctx, store.ListRunEventsParams{RunID: *c.CurrentRunID})
	if err != nil {
		t.Fatal(err)
	}
	if !slices.ContainsFunc(events, func(e store.RunEvent) bool {
		return e.Type == "lifecycle" && strings.Contains(string(e.Payload), "chat_classified") && strings.Contains(string(e.Payload), "has_link")
	}) {
		t.Fatalf("no firing logged: %+v", events)
	}
}

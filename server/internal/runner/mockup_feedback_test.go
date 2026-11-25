package runner_test

import (
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A person's decision on a mockup a persona posted in a chat is a system
// message in that chat, and reaches the persona in the prompt of the next
// turn (once), with the mockup_id a revision needs. Posting it starts no turn.
func TestMockupReviewReachesTheNextChatTurn(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Message: &runs.ChatMessageInput{Body: "Mock up the checkout"}})
	if err != nil {
		t.Fatal(err)
	}
	e.until("first reply", func() bool { return e.chat(chat.ID).State == "idle" })
	chat = e.chat(chat.ID)
	tok, _, err := agents.IssueToken(e.ctx, e.q, chat.AgentID, "run", "chat", chat.CurrentRunID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	persona, err := agents.ResolveToken(e.ctx, e.q, tok)
	if err != nil {
		t.Fatal(err)
	}
	svg := `<svg xmlns="http://www.w3.org/2000/svg" width="320" height="200"><rect width="320" height="200" fill="#fff"/><text x="10" y="20">Checkout</text></svg>`
	out, err := e.runs.CreateChatMockup(e.ctx, persona, runs.ChatMockup{ChatID: chat.ID, ProjectKey: "PAY", Title: "Checkout", SVG: svg})
	if err != nil {
		t.Fatal(err)
	}
	if out.Artifact.ChatSessionID == nil || *out.Artifact.ChatSessionID != chat.ID || out.Waiting {
		t.Fatalf("chat mockup: %+v", out)
	}
	if _, err := e.runs.ReviewMockup(e.ctx, e.ws, e.me.ID, out.Artifact.ID, out.Version.ID, "changes_requested", "Make the button bigger", nil, nil); err != nil {
		t.Fatal(err)
	}
	if got := e.chat(chat.ID); got.State == "running" {
		t.Fatal("posting the review started a turn")
	}
	msgs, _ := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 50})
	notice := msgs[len(msgs)-1]
	if notice.Role != "system" || !strings.Contains(notice.BodyMd, `Changes requested on mockup "Checkout" v1`) || !strings.Contains(notice.BodyMd, "Make the button bigger") {
		t.Fatalf("notice: %s %q", notice.Role, notice.BodyMd)
	}

	reply := func(body string) string {
		t.Helper()
		if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, chat.ID, runs.ChatMessageInput{Body: body}); err != nil {
			t.Fatal(err)
		}
		e.until("reply", func() bool { return e.chat(chat.ID).State == "idle" })
		msgs, _ := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chat.ID, Limit: 50})
		return msgs[len(msgs)-1].BodyMd // the fake harness echoes the prompt it received
	}
	got := reply("Can you fix it?")
	if !strings.Contains(got, "reviewed your mockups") || !strings.Contains(got, "Make the button bigger") || !strings.Contains(got, "mockup_id "+out.Artifact.ID.String()) {
		t.Fatalf("the persona's prompt lacks the review:\n%s", got)
	}
	if again := reply("Thanks"); strings.Contains(again, "Make the button bigger") {
		t.Fatalf("review repeated:\n%s", again)
	}

	// An approval is told the same way, with the reviewer's note.
	m, err := e.q.GetArtifact(e.ctx, store.GetArtifactParams{ID: out.Artifact.ID, WorkspaceID: e.ws, Viewer: pageview.From(e.ctx).UserID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.ReviewMockup(e.ctx, e.ws, e.me.ID, m.ID, *m.CurrentVersionID, "approved", "Ship it", nil, nil); err != nil {
		t.Fatal(err)
	}
	if got := reply("Next?"); !strings.Contains(got, `Mockup "Checkout" v1 approved.`) || !strings.Contains(got, "Note: Ship it") {
		t.Fatalf("approval missing from the prompt:\n%s", got)
	}
}

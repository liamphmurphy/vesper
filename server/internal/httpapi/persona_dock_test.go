package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (e *chatEnv) dockPersona(name string) uuid.UUID {
	e.t.Helper()
	p, err := e.q.CreatePersona(context.Background(), store.CreatePersonaParams{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID, Name: name, Tone: "neutral", Color: "#8b8fff", Repos: []string{}})
	if err != nil {
		e.t.Fatal(err)
	}
	return p.ID
}

func (e *chatEnv) dockChat(persona uuid.UUID) uuid.UUID {
	e.t.Helper()
	id, err := uuid.Parse(e.newChat(map[string]any{"persona_id": persona.String()})["id"].(string))
	if err != nil {
		e.t.Fatal(err)
	}
	return id
}

func (e *chatEnv) reply(chat uuid.UUID, persona *uuid.UUID, body string) int64 {
	e.t.Helper()
	m, err := e.q.AppendChatMessage(context.Background(), store.AppendChatMessageParams{SessionID: chat, Role: "assistant", BodyMd: body, ContextRefs: json.RawMessage("[]"), Citations: json.RawMessage("[]"), PersonaID: persona})
	if err != nil {
		e.t.Fatal(err)
	}
	return m.Seq
}

func (e *chatEnv) dock() []any {
	e.t.Helper()
	return e.want("GET", "/persona-dock", nil, 200)["personas"].([]any)
}

func field(entry any, key string) any { return entry.(map[string]any)[key] }

func TestPersonaDockIsGroupedByPersonaNewestFirst(t *testing.T) {
	e := newChatEnv(t)
	if len(e.dock()) != 0 {
		t.Fatal("no activity should mean no dock")
	}
	gwen, marcus := e.dockPersona("Gwen"), e.dockPersona("Marcus")
	a, b, c := e.dockChat(gwen), e.dockChat(marcus), e.dockChat(gwen)
	e.reply(a, &gwen, "First.")
	e.reply(b, &marcus, "Second.")
	e.reply(c, &gwen, "Third.")
	e.reply(c, &gwen, "Fourth.")
	got := e.dock()
	if len(got) != 2 {
		t.Fatalf("a persona must appear once: %v", got)
	}
	if field(field(got[0], "persona"), "name") != "Gwen" || field(got[0], "unread") != float64(3) || len(field(got[0], "chats").([]any)) != 2 {
		t.Fatalf("first %v", got[0])
	}
	if field(got[1], "state") != "replied" {
		t.Fatalf("second %v", got[1])
	}
}

func TestPersonaDockStates(t *testing.T) {
	e := newChatEnv(t)
	gwen := e.dockPersona("Gwen")
	a, b := e.dockChat(gwen), e.dockChat(gwen)
	if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET state='running' WHERE id=$1", a); err != nil {
		t.Fatal(err)
	}
	if got := e.dock(); len(got) != 1 || field(got[0], "state") != "working" {
		t.Fatalf("working %v", got)
	}
	e.reply(b, &gwen, "Done.\nWhich ending do you want?")
	got := e.dock()
	if field(got[0], "state") != "needs_you" {
		t.Fatalf("needs-you must take priority: %v", got)
	}
	var row map[string]any
	for _, ch := range field(got[0], "chats").([]any) {
		if field(ch, "id") == b.String() {
			row = ch.(map[string]any)
		}
	}
	if row["last_line"] != "Which ending do you want?" {
		t.Fatalf("row %v", row)
	}
}

func TestPersonaDockApprovalSurvivesReading(t *testing.T) {
	e := newChatEnv(t)
	gwen := e.dockPersona("Gwen")
	chat := e.dockChat(gwen)
	seq := e.reply(chat, &gwen, "May I add a persona.")
	if _, err := e.q.CreatePersonaProposal(context.Background(), store.CreatePersonaProposalParams{ChatID: chat, ProposedBy: &gwen, Name: "New", Tone: "neutral", Color: "#8b8fff"}); err != nil {
		t.Fatal(err)
	}
	e.want("POST", fmt.Sprintf("/chats/%s/read", chat), map[string]any{"seq": seq}, 204)
	if got := e.dock(); len(got) != 1 || field(got[0], "state") != "needs_you" || field(got[0], "unread") != float64(0) {
		t.Fatalf("got %v", got)
	}
}

func TestPersonaDockReadIsStoredAndBounded(t *testing.T) {
	e := newChatEnv(t)
	gwen := e.dockPersona("Gwen")
	chat := e.dockChat(gwen)
	path := fmt.Sprintf("/chats/%s/read", chat)
	seq := e.reply(chat, &gwen, "One.")
	e.want("POST", path, map[string]any{"seq": seq}, 204)
	if got := e.dock(); len(got) != 0 {
		t.Fatalf("read chat still shown: %v", got)
	}
	var stored int64
	if err := e.pool.QueryRow(context.Background(), "SELECT last_read_seq FROM chat_sessions WHERE id=$1", chat).Scan(&stored); err != nil || stored != seq {
		t.Fatalf("stored %d err %v", stored, err)
	}
	// Reading ahead can't swallow a later reply, and the position never goes back.
	e.want("POST", path, map[string]any{"seq": seq + 100}, 204)
	e.want("POST", path, map[string]any{"seq": 0}, 204)
	next := e.reply(chat, &gwen, "Two.")
	if got := e.dock(); len(got) != 1 || field(got[0], "unread") != float64(1) {
		t.Fatalf("got %v", got)
	}
	if next <= seq {
		t.Fatalf("seq %d after %d", next, seq)
	}
}

func TestPersonaDockFollowsHandOff(t *testing.T) {
	e := newChatEnv(t)
	gwen, marcus := e.dockPersona("Gwen"), e.dockPersona("Marcus")
	chat := e.dockChat(gwen)
	e.reply(chat, &gwen, "Over to @Marcus.")
	if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET state='running', speaker_persona_id=$2 WHERE id=$1", chat, marcus); err != nil {
		t.Fatal(err)
	}
	got := e.dock()
	if len(got) != 1 || field(field(got[0], "persona"), "name") != "Marcus" || field(got[0], "state") != "working" {
		t.Fatalf("hand-off %v", got)
	}
	e.reply(chat, &marcus, "On it.")
	if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET state='idle' WHERE id=$1", chat); err != nil {
		t.Fatal(err)
	}
	got = e.dock()
	if len(got) != 1 || field(field(got[0], "persona"), "name") != "Marcus" || field(got[0], "state") != "replied" {
		t.Fatalf("after reply %v", got)
	}
}

func TestPersonaDockHidesArchived(t *testing.T) {
	e := newChatEnv(t)
	gwen := e.dockPersona("Gwen")
	chat := e.dockChat(gwen)
	e.reply(chat, &gwen, "Hi.")
	if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET archived=true WHERE id=$1", chat); err != nil {
		t.Fatal(err)
	}
	if got := e.dock(); len(got) != 0 {
		t.Fatalf("archived chat shown: %v", got)
	}
}

func (e *chatEnv) listedUnread(chat uuid.UUID) any {
	e.t.Helper()
	for _, c := range e.want("GET", "/chats?persona_id=all", nil, 200)["chats"].([]any) {
		if field(c, "id") == chat.String() {
			return field(c, "unread")
		}
	}
	e.t.Fatalf("chat %s not listed", chat)
	return nil
}

func TestChatListCarriesUnreadReplies(t *testing.T) {
	e := newChatEnv(t)
	gwen := e.dockPersona("Gwen")
	chat := e.dockChat(gwen)
	if got := e.listedUnread(chat); got != float64(0) {
		t.Fatalf("new chat unread %v", got)
	}
	e.reply(chat, &gwen, "One.")
	seq := e.reply(chat, &gwen, "Two.")
	if got := e.listedUnread(chat); got != float64(2) {
		t.Fatalf("unread %v, want 2", got)
	}
	e.want("POST", fmt.Sprintf("/chats/%s/read", chat), map[string]any{"seq": seq}, 204)
	if got := e.listedUnread(chat); got != float64(0) {
		t.Fatalf("read chat unread %v", got)
	}
	// The person's own messages are never unread.
	if _, err := e.q.AppendChatMessage(context.Background(), store.AppendChatMessageParams{SessionID: chat, Role: "user", BodyMd: "Thanks.", ContextRefs: json.RawMessage("[]"), Citations: json.RawMessage("[]")}); err != nil {
		t.Fatal(err)
	}
	if got := e.listedUnread(chat); got != float64(0) {
		t.Fatalf("own message counted unread: %v", got)
	}
}

func (e *chatEnv) spaceChats() []any {
	e.t.Helper()
	return e.want("GET", "/persona-dock", nil, 200)["space_chats"].([]any)
}

func TestSpaceChatsListWorkingChatsMostRecentlyStartedFirst(t *testing.T) {
	e := newChatEnv(t)
	space := e.want("POST", "/chat-spaces", map[string]any{"name": "AIQ"}, 201)["id"].(string)
	older := e.want("POST", "/chats", map[string]any{"space_id": space}, 201)["id"].(string)
	newer := e.want("POST", "/chats", map[string]any{"space_id": space}, 201)["id"].(string)
	outside := e.dockChat(e.dockPersona("Gwen"))
	e.want("POST", "/chats", map[string]any{"space_id": space}, 201)
	if len(e.spaceChats()) != 0 {
		t.Fatal("idle chats are not activity")
	}
	// With no recorded turn start, a chat counts as started when it last moved.
	for id, ago := range map[string]string{older: "1 minute", newer: "10 seconds"} {
		if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET state='running', last_message_at=now() - $2::interval WHERE id=$1", id, ago); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET state='running' WHERE id=$1", outside); err != nil {
		t.Fatal(err)
	}
	got := e.spaceChats()
	if len(got) != 2 || field(got[0], "id") != newer || field(got[1], "id") != older {
		t.Fatalf("want newer then older, got %v", got)
	}
	if field(got[0], "state") != "working" || field(got[0], "space_id") != space || field(got[0], "started_at") == nil {
		t.Fatalf("row %v", got[0])
	}
}

func TestSpaceChatsPutChatsWaitingOnThePersonAfterWorkingOnes(t *testing.T) {
	e := newChatEnv(t)
	space := e.want("POST", "/chat-spaces", map[string]any{"name": "AIQ"}, 201)["id"].(string)
	asking := e.want("POST", "/chats", map[string]any{"space_id": space}, 201)["id"]
	working := e.want("POST", "/chats", map[string]any{"space_id": space}, 201)["id"]
	askingID, _ := uuid.Parse(asking.(string))
	e.reply(askingID, nil, "Which ending do you want?")
	if _, err := e.pool.Exec(context.Background(), "UPDATE chat_sessions SET state='running' WHERE id=$1", working); err != nil {
		t.Fatal(err)
	}
	got := e.spaceChats()
	if len(got) != 2 || field(got[0], "id") != working || field(got[1], "id") != asking || field(got[1], "state") != "needs_you" || field(got[1], "started_at") != nil {
		t.Fatalf("got %v", got)
	}
}

func TestPersonaDockLiveToolApproval(t *testing.T) {
	e := newChatEnv(t)
	gwen := e.dockPersona("Gwen")
	chat := e.dockChat(gwen)
	seq := e.reply(chat, &gwen, "Checking the repo.")
	e.want("POST", fmt.Sprintf("/chats/%s/read", chat), map[string]any{"seq": seq}, 204)

	agents, err := e.q.ListAgents(context.Background(), e.me.WorkspaceID)
	if err != nil || len(agents) == 0 {
		t.Fatalf("list agents: %v", err)
	}
	run, err := e.q.CreateRun(context.Background(), store.CreateRunParams{
		WorkspaceID: e.me.WorkspaceID, AgentID: agents[0].ID, Mode: "managed", State: "running",
		Harness: "claude", Model: "claude-sonnet-4-6", Purpose: "chat", ResolvedSpec: json.RawMessage("{}"),
	})
	if err != nil {
		t.Fatal(err)
	}
	ap, err := e.q.CreateApproval(context.Background(), store.CreateApprovalParams{
		WorkspaceID: e.me.WorkspaceID, RunID: run.ID, ChatID: &chat, AgentID: agents[0].ID,
		Scope: "tests:run", ActionSummary: "Allow Bash for tests:run", ActionDetail: json.RawMessage(`{"tool_name":"Bash"}`),
		RiskSummary: "Harness tool requested this exact input",
	})
	if err != nil {
		t.Fatal(err)
	}

	got := e.dock()
	if len(got) != 1 || field(got[0], "state") != "needs_you" || field(got[0], "unread") != float64(0) {
		t.Fatalf("dock with pending chat tool approval: %v", got)
	}

	e.want("POST", fmt.Sprintf("/approvals/%s/approve", ap.ID), map[string]any{}, 200)
	if got := e.dock(); len(got) != 0 {
		t.Fatalf("dock after approval resolved: %v", got)
	}
}

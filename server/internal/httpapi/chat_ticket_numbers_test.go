package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// People name tickets by number ("ticket 251"): list_tickets and get_ticket
// take the bare number, and get_ticket refuses to guess between projects.
func TestChatToolsResolveBareTicketNumbers(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()

	// PAY-214 comes from the seed; MOB-214 shares its number, PAY-9001 is unique.
	ticketAt := func(project string, number int32) {
		t.Helper()
		p, err := q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: project})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := q.CreateTicket(ctx, store.CreateTicketParams{WorkspaceID: ws, ProjectID: p.ID, Number: number,
			Key: project + "-" + strconv.Itoa(int(number)), Title: "Numbered " + project, Status: "todo", Priority: "medium"}); err != nil {
			t.Fatal(err)
		}
	}
	ticketAt("MOB", 214)
	ticketAt("PAY", 9001)

	chatToken := func(project string) string {
		t.Helper()
		chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{Project: project, Title: "Numbers " + project, Message: &runs.ChatMessageInput{Body: "hello"}})
		if err != nil {
			t.Fatal(err)
		}
		chat, err = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
		if err != nil || chat.CurrentRunID == nil {
			t.Fatalf("chat run: %v", err)
		}
		if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: *chat.CurrentRunID, State: "running"}); err != nil {
			t.Fatal(err)
		}
		token, _, err := agents.IssueToken(ctx, q, chat.AgentID, "run", "chat", chat.CurrentRunID, nil, nil)
		if err != nil {
			t.Fatal(err)
		}
		return token
	}
	call := func(token, name string, args any) (int, string) {
		t.Helper()
		raw, _ := json.Marshal(args)
		req := httptest.NewRequest("POST", "/api/v1/agent/tools/"+name, bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		return w.Code, w.Body.String()
	}
	listedKeys := func(body string) []string {
		t.Helper()
		var out struct{ Tickets []struct{ Key string } }
		if err := json.Unmarshal([]byte(body), &out); err != nil {
			t.Fatalf("list_tickets: %s", body)
		}
		keys := make([]string, len(out.Tickets))
		for i, tk := range out.Tickets {
			keys[i] = tk.Key
		}
		return keys
	}
	gotKey := func(body string) string {
		var out struct{ Key string }
		_ = json.Unmarshal([]byte(body), &out)
		return out.Key
	}

	noDefault := chatToken("")
	payChat := chatToken("PAY")

	if code, body := call(noDefault, "list_tickets", map[string]any{"q": "9001"}); code != 200 || !slices.Contains(listedKeys(body), "PAY-9001") {
		t.Fatalf("list_tickets q=9001: %d %s", code, body)
	}
	if code, body := call(noDefault, "list_tickets", map[string]any{"q": "#214", "status": []string{"all"}}); code != 200 ||
		!slices.Contains(listedKeys(body), "PAY-214") || !slices.Contains(listedKeys(body), "MOB-214") {
		t.Fatalf("list_tickets q=#214: %d %s", code, body)
	}

	// A number only one active project has resolves anywhere.
	if code, body := call(noDefault, "get_ticket", map[string]any{"ticket": "9001"}); code != 200 || gotKey(body) != "PAY-9001" {
		t.Fatalf("get_ticket 9001: %d %s", code, body)
	}
	// Two projects have 214: a chat without a default project must not guess.
	code, body := call(noDefault, "get_ticket", map[string]any{"ticket": "214"})
	if code == 200 || !strings.Contains(body, "MOB-214") || !strings.Contains(body, "PAY-214") {
		t.Fatalf("ambiguous get_ticket 214: %d %s", code, body)
	}
	// The chat's default project breaks the tie.
	if code, body := call(payChat, "get_ticket", map[string]any{"ticket": "#214"}); code != 200 || gotKey(body) != "PAY-214" {
		t.Fatalf("get_ticket #214 in a PAY chat: %d %s", code, body)
	}
	if code, body := call(noDefault, "get_ticket", map[string]any{"ticket": "777777"}); code == 200 || !strings.Contains(body, "full key") {
		t.Fatalf("get_ticket for a missing number: %d %s", code, body)
	}
	// Full keys work as before.
	if code, body := call(noDefault, "get_ticket", map[string]any{"ticket": "mob-214"}); code != 200 || gotKey(body) != "MOB-214" {
		t.Fatalf("get_ticket mob-214: %d %s", code, body)
	}
}

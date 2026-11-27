package httpapi

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestKnowledgeQueriesCaptureAndTools(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	page := e.want("POST", "/knowledge/pages", map[string]any{"title": "Harbour [notes]", "body_md": "# Harbour\n\nA paragraph. ^arrival\n\n[[Missing page]]\n", "properties": map[string]any{"tags": []string{"campaign"}, "role": "location"}}, 200)
	id := page["id"].(string)
	version := page["version_id"].(string)
	if page["audience"] != "private" || page["direct"] != true {
		t.Fatalf("defaults %v", page)
	}
	result := e.want("POST", "/knowledge/query", map[string]any{"tag": "campaign", "properties": map[string]any{"role": "location"}}, 200)
	if len(result["rows"].([]any)) != 1 {
		t.Fatalf("query %v", result)
	}
	e.want("POST", "/knowledge/capture", map[string]any{"title": "Ferry", "body_md": "Arrives at dawn"}, 200)
	first := e.want("POST", "/knowledge/daily", map[string]any{"date": "2026-11-13"}, 200)
	again := e.want("POST", "/knowledge/daily", map[string]any{"date": "2026-11-13"}, 200)
	if first["id"] != again["id"] {
		t.Fatal("daily duplicated")
	}
	chat := e.newChat(nil)
	token := e.canvasToken(uuid.MustParse(chat["id"].(string)))
	if code, out := e.tool(token, "page_outline", map[string]any{"ref": id}); code != 200 || strings.Contains(fmtJSON(out), "A paragraph") {
		t.Fatalf("outline %d %v", code, out)
	}
	// A review-first page keeps the persona's patch as a suggestion.
	e.want("PUT", "/knowledge/pages/"+id+"/controls", map[string]any{"direct": false, "paused": false}, 200)
	args := map[string]any{"ref": id, "base_version": version, "changes": []any{map[string]any{"before": "A paragraph.", "after": "A better paragraph.", "why": "Clarify"}}}
	if code, out := e.tool(token, "patch_page", args); code != 200 || out["state"] != "suggested" {
		t.Fatalf("patch %d %v", code, out)
	}
	reviewed := e.want("GET", "/knowledge/pages/"+id, nil, 200)
	if reviewed["body_md"] != page["body_md"] || len(reviewed["reviews"].([]any)) != 1 {
		t.Fatalf("patch bypassed review %v", reviewed)
	}
	review := reviewed["reviews"].([]any)[0].(map[string]any)
	e.want("POST", "/knowledge/pages/"+id+"/reviews/"+review["id"].(string)+"/resolve", map[string]any{"decisions": []any{map[string]any{"index": 0, "accept": true}}}, 200)
	// A direct page applies it at once, with the change left for review afterwards.
	e.want("PUT", "/knowledge/pages/"+id+"/controls", map[string]any{"direct": true, "paused": false}, 200)
	accepted := e.want("GET", "/knowledge/pages/"+id, nil, 200)
	direct := map[string]any{"ref": id, "base_version": accepted["version_id"], "changes": []any{map[string]any{"before": "A better paragraph.", "after": "The best paragraph.", "why": "Tighten"}}}
	if code, out := e.tool(token, "patch_page", direct); code != 200 || out["state"] != "published" {
		t.Fatalf("direct patch %d %v", code, out)
	}
	applied := e.want("GET", "/knowledge/pages/"+id, nil, 200)
	if !strings.Contains(applied["body_md"].(string), "The best paragraph.") || len(applied["reviews"].([]any)) != 1 {
		t.Fatalf("direct patch didn't apply for review afterwards %v", applied)
	}
	if code, out := e.tool(token, "set_properties", map[string]any{"ref": id, "base_version": applied["version_id"], "properties": map[string]any{"role": "harbour"}}); code != 200 || out["state"] != "published" {
		t.Fatalf("direct set_properties %d %v", code, out)
	}
	// Every page tool uses the ticket principal, including ID-based writes.
	atlas, err := e.q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: e.me.WorkspaceID, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}
	ticket, err := e.q.GetTicketByKey(ctx, store.GetTicketByKeyParams{WorkspaceID: e.me.WorkspaceID, Key: e.payKey})
	if err != nil {
		t.Fatal(err)
	}
	run, err := e.q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: e.me.WorkspaceID, TicketID: &ticket.ID, AgentID: atlas.ID, Mode: "managed", State: "running", Purpose: "ticket", Harness: "codex", Model: "test", ResolvedSpec: json.RawMessage(`{}`)})
	if err != nil {
		t.Fatal(err)
	}
	runToken, _, err := agents.IssueToken(ctx, e.q, atlas.ID, "run", "knowledge", &run.ID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, tool := range []string{"page_outline", "patch_page", "set_properties", "suggest_links"} {
		if code, out := e.tool(runToken, tool, map[string]any{"ref": id, "base_version": version, "properties": map[string]any{"role": "npc"}, "changes": args["changes"]}); code == 200 {
			t.Fatalf("%s read private page %v", tool, out)
		}
	}
	hiddenCode, hidden := e.tool(runToken, "list_pages", map[string]any{"tag": "campaign"})
	if hiddenCode != 200 || strings.Contains(fmtJSON(hidden), id) {
		t.Fatalf("run list leaked private %d %v", hiddenCode, hidden)
	}
}
func fmtJSON(v any) string { b, _ := json.Marshal(v); return string(b) }

func TestScheduledLibrarianProducesSuggestionsAndNeedsYou(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	e.want("POST", "/knowledge/pages", map[string]any{"title": "Harbour", "path": "Librarian/Harbour", "body_md": "# Harbour\n\nA place by the sea."}, 200)
	source := e.want("POST", "/knowledge/pages", map[string]any{"title": "Session recap", "path": "Librarian/Session", "body_md": "We visited Harbour before dawn."}, 200)
	task, err := e.runs.CreateScheduledTask(ctx, e.me.WorkspaceID, e.me.ID, runs.ScheduledTaskInput{Name: "Weekly Knowledge librarian", Kind: "prompt", Instructions: "Call librarian_pass for folder Librarian and report its suggestions.", Schedule: runs.Schedule{Frequency: "weekly", Weekdays: []int32{1}, MonthDay: 1, AtTime: "09:00", Timezone: "UTC"}})
	if err != nil {
		t.Fatal(err)
	}
	if err = e.runs.RunScheduledTaskNow(ctx, e.me.WorkspaceID, e.me.ID, task.ID); err != nil {
		t.Fatal(err)
	}
	jobs, err := e.q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID})
	if err != nil || len(jobs) != 1 || jobs[0].ChatID == nil {
		t.Fatalf("scheduled chat %+v %v", jobs, err)
	}
	chat, err := e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: *jobs[0].ChatID, WorkspaceID: e.me.WorkspaceID})
	if err != nil {
		t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, e.q, chat.AgentID, "run", "scheduled librarian", chat.CurrentRunID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	code, out := e.tool(token, "librarian_pass", map[string]any{"folder": "Librarian", "limit": 20})
	if code != 200 || !strings.Contains(fmtJSON(out), "suggested") {
		t.Fatalf("librarian %d %v", code, out)
	}
	page := e.want("GET", "/knowledge/pages/"+source["id"].(string), nil, 200)
	if page["body_md"] != source["body_md"] || len(page["reviews"].([]any)) != 1 {
		t.Fatalf("librarian published without review: %v", page)
	}
	if _, err = e.q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "assistant", BodyMd: "Knowledge links are ready for review.", ContextRefs: json.RawMessage(`[]`), Citations: json.RawMessage(`[]`)}); err != nil {
		t.Fatal(err)
	}
	if _, err = e.q.SetChatRunState(ctx, store.SetChatRunStateParams{ID: chat.ID, CurrentRunID: chat.CurrentRunID, State: "idle"}); err != nil {
		t.Fatal(err)
	}
	if err = e.runs.SettleScheduled(ctx); err != nil {
		t.Fatal(err)
	}
	inbox := e.want("GET", "/inbox", nil, 200)
	if !strings.Contains(fmtJSON(inbox), "Weekly Knowledge librarian") {
		t.Fatalf("no Needs you result: %v", inbox)
	}
}

func TestKnowledgePageWordCount(t *testing.T) {
	e := newChatEnv(t)

	body := "# Chapter 1\n\nIt's a well-known fact—really.\n\n```go\nfunc ignored() {}\n```\n\n![[map.png]]\nSee [[Lore/Umbra|the Umbra]].\n"
	// Prose words: Chapter(1) 1(2) It's(3) a(4) well-known(5) fact(6) really(7) See(8) the(9) Umbra(10) = 10
	created := e.want("POST", "/knowledge/pages", map[string]any{
		"title":   "Chapter 1",
		"path":    "Book/Part 1/Chapter 1",
		"body_md": body,
	}, 200)
	if got := int(created["word_count"].(float64)); got != 10 {
		t.Fatalf("created word_count = %d, want 10 (resp=%v)", got, created)
	}

	list := e.want("GET", "/knowledge/pages?folder=Book", nil, 200)
	rows := list["rows"].([]any)
	if len(rows) != 1 {
		t.Fatalf("expected 1 row in Book, got %v", list)
	}
	row := rows[0].(map[string]any)
	if got := int(row["word_count"].(float64)); got != 10 {
		t.Fatalf("list row word_count = %d, want 10 (row=%v)", got, row)
	}

	id := created["id"].(string)
	updated := e.want("PUT", "/knowledge/pages/"+id, map[string]any{
		"body_md":         "Three short words.",
		"base_version_id": created["version_id"],
	}, 200)
	if got := int(updated["word_count"].(float64)); got != 3 {
		t.Fatalf("updated word_count = %d, want 3 (resp=%v)", got, updated)
	}

	listAfter := e.want("GET", "/knowledge/pages?folder=Book", nil, 200)
	rowAfter := listAfter["rows"].([]any)[0].(map[string]any)
	if got := int(rowAfter["word_count"].(float64)); got != 3 {
		t.Fatalf("list row word_count after update = %d, want 3", got)
	}
}

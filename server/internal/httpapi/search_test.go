package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
)

// searchHits is GET /search's hits and counts, decoded loosely.
func (e *chatEnv) searchHits(path string) ([]map[string]any, map[string]any) {
	e.t.Helper()
	out := e.want("GET", path, nil, http.StatusOK)
	var hits []map[string]any
	for _, h := range out["hits"].([]any) {
		hits = append(hits, h.(map[string]any))
	}
	return hits, out["counts"].(map[string]any)
}

func hitsOf(hits []map[string]any, kind string) []map[string]any {
	var out []map[string]any
	for _, h := range hits {
		if h["target"].(map[string]any)["kind"] == kind {
			out = append(out, h)
		}
	}
	return out
}

func hasTitle(hits []map[string]any, title string) bool {
	for _, h := range hits {
		if h["target"].(map[string]any)["title"] == title {
			return true
		}
	}
	return false
}

// The palette's search: many tickets mentioning a word don't push the page and
// chat named for it out, a folder's name finds its pages, every type reports
// how many matched, and spaces, courses, scheduled tasks and canvases are found.
func TestSearchCapsEachTypeAndFindsEveryKind(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	for i := range 20 {
		e.want("POST", "/tickets", map[string]any{"project_key": "PAY", "title": fmt.Sprintf("Runner networking %d", i),
			"description_md": "Route it through Tailscale on the homelab box."}, http.StatusCreated)
	}
	arts := &artifacts.Service{Pool: e.pool}
	body := "MagicDNS gives the host a name; no ports open on the router."
	page, err := arts.Create(ctx, e.me.WorkspaceID, artifacts.Actor{Type: "user", ID: e.me.ID},
		artifacts.NewArtifact{Type: "note", Path: "Homelab/Tailscale setup", Content: artifacts.Content{BodyMD: &body}})
	if err != nil {
		t.Fatal(err)
	}
	chat := e.newChat(map[string]any{"title": "Tailscale ACLs"})
	chatID := chat["id"].(string)
	other := e.newChat(map[string]any{"title": "Deploy notes"})["id"].(string)
	exec := func(sql string, args ...any) {
		t.Helper()
		if _, err := e.pool.Exec(ctx, sql, args...); err != nil {
			t.Fatalf("%s: %v", sql, err)
		}
	}
	exec(`INSERT INTO chat_messages(session_id,seq,role,body_md) VALUES($1,1,'user','How do I keep the runner off my other tailscale nodes?')`, other)
	exec(`INSERT INTO chat_spaces(workspace_id,user_id,name) VALUES($1,$2,'Tailscale homelab')`, e.me.WorkspaceID, e.me.ID)
	exec(`INSERT INTO scheduled_tasks(workspace_id,user_id,name,kind,frequency) VALUES($1,$2,'Tailscale key check','prompt','daily')`, e.me.WorkspaceID, e.me.ID)
	exec(`INSERT INTO learning_courses(workspace_id,user_id,chat_id,topic,level,minutes_budget) VALUES($1,$2,$3,'Tailscale basics','new',30)`, e.me.WorkspaceID, e.me.ID, other)
	exec(`INSERT INTO chat_canvases(session_id,kind,title) VALUES($1,'text','Tailscale ACL draft')`, chatID)

	hits, counts := e.searchHits("/search?q=tailscale")
	if n := len(hitsOf(hits, "ticket")); n != 8 {
		t.Errorf("tickets in the All list = %d, want the cap of 8", n)
	}
	if counts["ticket"].(float64) < 20 {
		t.Errorf("ticket count %v, want every match (at least 20)", counts["ticket"])
	}
	if !hasTitle(hitsOf(hits, "artifact"), "Tailscale setup") {
		t.Error("the page named for the word was crowded out by tickets")
	}
	for kind, title := range map[string]string{"space": "Tailscale homelab", "scheduled": "Tailscale key check", "course": "Tailscale basics", "canvas": "Tailscale ACL draft", "chat": "Tailscale ACLs"} {
		if !hasTitle(hitsOf(hits, kind), title) {
			t.Errorf("no %s hit %q", kind, title)
		}
		if counts[kind] == nil {
			t.Errorf("no count for %s", kind)
		}
	}
	// A matching message is its chat, with the message as the anchor; both chats count.
	var anchored bool
	for _, h := range hitsOf(hits, "chat") {
		tg := h["target"].(map[string]any)
		if tg["id"] == other && tg["anchor"] != nil && h["detail"] == "You" {
			anchored = true
		}
	}
	if !anchored || counts["chat"].(float64) != 2 {
		t.Errorf("message hit not anchored under its chat, or chats miscounted (%v): %v", counts["chat"], hitsOf(hits, "chat"))
	}

	// A folder's name finds the pages in it, with the folder as context.
	hits, counts = e.searchHits("/search?q=homelab")
	pages := hitsOf(hits, "artifact")
	if !hasTitle(pages, "Tailscale setup") || counts["page"] == nil {
		t.Fatalf("folder name missed its page: %v", pages)
	}
	for _, h := range pages {
		if h["target"].(map[string]any)["id"] == page.ID.String() && h["detail"] != "Homelab" {
			t.Errorf("page detail %v, want its folder", h["detail"])
		}
	}

	// One type lifts the cap and leaves the rest out.
	hits, _ = e.searchHits("/search?q=tailscale&kind=ticket")
	if n := len(hits); n < 20 || len(hitsOf(hits, "ticket")) != n {
		t.Errorf("kind=ticket returned %d hits (%d tickets), want every ticket and nothing else", n, len(hitsOf(hits, "ticket")))
	}
	hits, _ = e.searchHits("/search?q=tailscale&kind=space")
	if len(hits) != 1 || !hasTitle(hits, "Tailscale homelab") {
		t.Errorf("kind=space: %v", hits)
	}
	e.invalid("GET", "/search?q=tailscale&kind=nonsense", nil, "kind", "unknown")

	// Persona, memory and Library hits open the item, not the page that lists them.
	var personaID string
	if err := e.pool.QueryRow(ctx, `INSERT INTO personas(workspace_id,user_id,name) VALUES($1,$2,'Tailscale Tutor') RETURNING id`, e.me.WorkspaceID, e.me.ID).Scan(&personaID); err != nil {
		t.Fatal(err)
	}
	hits, _ = e.searchHits("/search?q=tailscale%20tutor&kind=persona")
	if len(hits) == 0 || hits[0]["target"].(map[string]any)["href"] != "/settings?section=personas&persona="+personaID {
		t.Errorf("persona hit href: %v", hits)
	}
}

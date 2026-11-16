package prsync_test

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/prsync"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestMergedAndClosed(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	for key, n := range map[string]int{"PAY-214": 491, "PAY-224": 492} {
		tk, _ := tracker.Get(ctx, q, ws, key)
		url := "https://github.com/northwind/payments/pull/" + map[int]string{491: "491", 492: "492"}[n]
		num := int32(n)
		open := "open"
		if err := q.SetTicketPR(ctx, store.SetTicketPRParams{ID: tk.ID, PrNumber: &num, PrUrl: &url, PrState: &open}); err != nil {
			t.Fatal(err)
		}
	}
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/repos/northwind/payments/pulls/491"):
			_, _ = io.WriteString(w, `{"state":"closed","merged":true,"draft":false,"additions":120,"deletions":14}`)
		case strings.HasSuffix(r.URL.Path, "/pulls/492"):
			_, _ = io.WriteString(w, `{"state":"closed","merged":false,"additions":3,"deletions":1}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer gh.Close()
	s := &prsync.Syncer{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Log: slog.New(slog.NewTextHandler(io.Discard, nil)), BaseURL: gh.URL}
	if n, err := s.Once(ctx); err != nil || n < 2 {
		t.Fatalf("once: %d %v", n, err)
	}
	merged, _ := tracker.Get(ctx, q, ws, "PAY-214")
	if merged.Status != "done" || *merged.PrState != "merged" || *merged.PrAdditions != 120 {
		t.Fatalf("merged ticket: %s %v", merged.Status, *merged.PrState)
	}
	closed, _ := tracker.Get(ctx, q, ws, "PAY-224")
	if closed.Status == "done" || *closed.PrState != "closed" || !closed.PrClosedUnmerged {
		t.Fatalf("closed ticket: %s %v %v", closed.Status, *closed.PrState, closed.PrClosedUnmerged)
	}
	evs, _ := q.ListTicketActivity(ctx, &merged.ID)
	verbs := []string{}
	for _, e := range evs {
		verbs = append(verbs, e.Verb)
	}
	if !strings.Contains(strings.Join(verbs, ","), runs.VerbPRMerged+",status_changed") {
		t.Fatalf("verbs %v", verbs)
	}
	// Merged and closed PRs aren't polled again.
	if n, _ := s.Once(ctx); n != 0 {
		t.Fatalf("re-polled %d", n)
	}
}

func TestPushRequestPRSync(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	agents, err := q.ListAgents(ctx, ws)
	if err != nil || len(agents) == 0 {
		t.Fatalf("list agents: %v %d", err, len(agents))
	}
	ag := agents[0]
	chat, err := q.CreateChatSession(ctx, store.CreateChatSessionParams{
		WorkspaceID: ws, CreatedBy: me.ID, AgentID: ag.ID, Title: "PR sync chat", Harness: "claude", Model: "claude-sonnet-4-6", Effort: "medium",
	})
	if err != nil {
		t.Fatal(err)
	}
	mk := func(branch, prURL string, prNum int32, draft bool) store.PushRequest {
		r, err := q.CreatePushRequest(ctx, store.CreatePushRequestParams{
			WorkspaceID: ws, UserID: me.ID, ChatID: chat.ID, AgentID: ag.ID,
			RepoUrl: "https://github.com/northwind/payments.git", Branch: branch, Title: branch, Draft: draft,
		})
		if err != nil {
			t.Fatal(err)
		}
		prState := "open"
		if draft {
			prState = "draft"
		}
		r, err = q.FinishPushRequest(ctx, store.FinishPushRequestParams{
			ID: r.ID, State: "pushed", PrUrl: &prURL, PrNumber: &prNum, PrState: &prState,
		})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	openReq := mk("feat/open", "https://github.com/northwind/payments/pull/501", 501, false)
	draftReq := mk("feat/draft", "https://github.com/northwind/payments/pull/502", 502, true)

	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/repos/northwind/payments/pulls/501"):
			_, _ = io.WriteString(w, `{"state":"closed","merged":true,"draft":false}`)
		case strings.HasSuffix(r.URL.Path, "/repos/northwind/payments/pulls/502"):
			_, _ = io.WriteString(w, `{"state":"open","merged":false,"draft":false}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer gh.Close()
	s := &prsync.Syncer{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Log: slog.New(slog.NewTextHandler(io.Discard, nil)), BaseURL: gh.URL}
	if n, err := s.Once(ctx); err != nil || n < 2 {
		t.Fatalf("once: %d %v", n, err)
	}
	gotOpen, _ := q.GetPushRequest(ctx, store.GetPushRequestParams{ID: openReq.ID, WorkspaceID: ws, UserID: me.ID})
	if gotOpen.PrState == nil || *gotOpen.PrState != "merged" {
		t.Fatalf("openReq pr_state = %v, want merged", gotOpen.PrState)
	}
	gotDraft, _ := q.GetPushRequest(ctx, store.GetPushRequestParams{ID: draftReq.ID, WorkspaceID: ws, UserID: me.ID})
	if gotDraft.PrState == nil || *gotDraft.PrState != "open" {
		t.Fatalf("draftReq pr_state = %v, want open", gotDraft.PrState)
	}
}

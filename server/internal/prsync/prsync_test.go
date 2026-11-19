package prsync_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/prsync"
	"github.com/liamphmurphy/vesper/server/internal/pushreq"
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

type staticRevealer string

func (s staticRevealer) Reveal(_ context.Context, _ uuid.UUID, _ *uuid.UUID, name string) (string, error) {
	if name == "git:pat" {
		return string(s), nil
	}
	return "", nil
}

func TestPRSyncCleansUpContainedCheckpointsAndKeepsDiverged(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	agents, _ := q.ListAgents(ctx, ws)
	ag := agents[0]

	repoURL := "https://github.com/northwind/payments.git"
	tk, _ := tracker.Get(ctx, q, ws, "PAY-214")
	pr601URL := "https://github.com/northwind/payments/pull/601"
	pr601Num, openState := int32(601), "open"
	if err := q.SetTicketPR(ctx, store.SetTicketPRParams{ID: tk.ID, PrNumber: &pr601Num, PrUrl: &pr601URL, PrState: &openState}); err != nil {
		t.Fatal(err)
	}
	ticketRun, err := q.CreateRun(ctx, store.CreateRunParams{
		WorkspaceID: ws, TicketID: &tk.ID, AgentID: ag.ID, Mode: "managed", State: "completed", Harness: "claude", Model: "claude-sonnet-4-6", Purpose: "ticket", ResolvedSpec: []byte("{}"),
	})
	if err != nil {
		t.Fatal(err)
	}
	tkCkpt := "vesper-checkpoint/pay-214/r1"
	pr601SHA := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if err := q.RecordRunCheckpoint(ctx, store.RecordRunCheckpointParams{
		WorkspaceID: ws, RunID: &ticketRun.ID, TicketID: &tk.ID, RepoUrl: repoURL, Branch: tkCkpt, CommitSha: &pr601SHA,
	}); err != nil {
		t.Fatal(err)
	}

	chat, err := q.CreateChatSession(ctx, store.CreateChatSessionParams{
		WorkspaceID: ws, CreatedBy: me.ID, AgentID: ag.ID, Title: "PR sync ckpt", Harness: "claude", Model: "claude-sonnet-4-6", Effort: "medium",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.AttachChatRepository(ctx, store.AttachChatRepositoryParams{ChatID: chat.ID, RepoUrl: repoURL, Directory: "."}); err != nil {
		t.Fatal(err)
	}
	pr602URL := "https://github.com/northwind/payments/pull/602"
	pr602Num := int32(602)
	req, err := q.CreatePushRequest(ctx, store.CreatePushRequestParams{
		WorkspaceID: ws, UserID: me.ID, ChatID: chat.ID, AgentID: ag.ID,
		RepoUrl: repoURL, Branch: "feat/chat-pr", Title: "Chat PR",
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := q.FinishPushRequest(ctx, store.FinishPushRequestParams{
		ID: req.ID, State: "pushed", PrUrl: &pr602URL, PrNumber: &pr602Num, PrState: &openState,
	}); err != nil {
		t.Fatal(err)
	}
	keptCkpt := "vesper-checkpoint/chat/north/kept"
	keptSHA := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if err := q.RecordRunCheckpoint(ctx, store.RecordRunCheckpointParams{
		WorkspaceID: ws, ChatID: &chat.ID, RepoUrl: repoURL, Branch: keptCkpt, CommitSha: &keptSHA,
	}); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	pr602Head := "cccccccccccccccccccccccccccccccccccccccc"
	deleted := map[string]bool{}
	var compareCalls atomic.Int32
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		cur602Head := pr602Head
		mu.Unlock()
		p := r.URL.Path
		switch {
		case r.Method == "GET" && p == "/repos/northwind/payments/pulls/601":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"state": "closed", "merged": true, "draft": false,
				"head": map[string]any{"sha": pr601SHA, "ref": "atlas/pay-214"},
			})
		case r.Method == "GET" && p == "/repos/northwind/payments/pulls/602":
			_ = json.NewEncoder(w).Encode(map[string]any{
				"state": "open", "merged": false, "draft": false,
				"head": map[string]any{"sha": cur602Head, "ref": "feat/chat-pr"},
			})
		case r.Method == "GET" && p == "/repos/northwind/payments/git/ref/heads/"+tkCkpt:
			_ = json.NewEncoder(w).Encode(map[string]any{"object": map[string]any{"sha": pr601SHA}})
		case r.Method == "GET" && p == "/repos/northwind/payments/git/ref/heads/"+keptCkpt:
			_ = json.NewEncoder(w).Encode(map[string]any{"object": map[string]any{"sha": keptSHA}})
		case r.Method == "GET" && strings.HasPrefix(p, "/repos/northwind/payments/compare/"):
			compareCalls.Add(1)
			res := pushreq.CompareResult{Status: "ahead", AheadBy: 1}
			res.BaseCommit.Commit.Tree.SHA = "tree-602"
			res.MergeBaseCommit.Commit.Tree.SHA = "tree-base"
			_ = json.NewEncoder(w).Encode(res)
		case r.Method == "GET" && p == "/repos/northwind/payments/git/commits/"+keptSHA:
			_ = json.NewEncoder(w).Encode(map[string]any{"sha": keptSHA, "tree": map[string]any{"sha": "tree-kept"}})
		case r.Method == "DELETE" && strings.HasPrefix(p, "/repos/northwind/payments/git/refs/heads/"):
			branch := strings.TrimPrefix(p, "/repos/northwind/payments/git/refs/heads/")
			mu.Lock()
			deleted[branch] = true
			mu.Unlock()
			w.WriteHeader(204)
		default:
			http.NotFound(w, r)
		}
	}))
	defer gh.Close()

	s := &prsync.Syncer{
		Pool:    pool,
		Secrets: staticRevealer("ghp_testtoken123"),
		Tracker: &tracker.Service{Pool: pool},
		Log:     slog.New(slog.NewTextHandler(io.Discard, nil)),
		BaseURL: gh.URL,
		MinAge:  0,
	}

	// First poll: ticket checkpoint (exact match) deleted, chat keptCkpt (ahead) kept + LastCheckedPrSha set.
	if _, err := s.Once(ctx); err != nil {
		t.Fatal(err)
	}
	if !deleted[tkCkpt] || deleted[keptCkpt] {
		t.Fatalf("unexpected deleted map after poll 1: %+v", deleted)
	}
	openChat, _ := q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(openChat) != 1 || openChat[0].LastCheckedPrSha == nil || *openChat[0].LastCheckedPrSha != "cccccccccccccccccccccccccccccccccccccccc" {
		t.Fatalf("expected LastCheckedPrSha recorded, got %+v", openChat)
	}

	// Second poll with unchanged PR 602 head: 0 compare calls!
	before := compareCalls.Load()
	if _, err := s.Once(ctx); err != nil {
		t.Fatal(err)
	}
	if compareCalls.Load() != before {
		t.Fatalf("expected 0 compare calls on unchanged PR head, got %d", compareCalls.Load()-before)
	}

	// Advance PR 602 head to match keptSHA -> third poll deletes keptCkpt!
	mu.Lock()
	pr602Head = keptSHA
	mu.Unlock()
	if _, err := s.Once(ctx); err != nil {
		t.Fatal(err)
	}
	if !deleted[keptCkpt] {
		t.Fatalf("expected %s deleted once PR head advanced, got %+v", keptCkpt, deleted)
	}
	openChat, _ = q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(openChat) != 0 {
		t.Fatalf("expected 0 open chat checkpoints, got %+v", openChat)
	}
}

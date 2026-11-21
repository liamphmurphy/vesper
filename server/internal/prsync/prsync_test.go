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
	"time"

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

func TestPRFeedbackCheckRunsAndReviewThreadsWithETag(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tk, _ := tracker.Get(ctx, q, ws, "PAY-214")
	prURL := "https://github.com/northwind/payments/pull/701"
	num, openState := int32(701), "open"
	if err := q.SetTicketPR(ctx, store.SetTicketPRParams{ID: tk.ID, PrNumber: &num, PrUrl: &prURL, PrState: &openState}); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	phase := 1
	var seenPRIfNoneMatch, seenChecksIfNoneMatch, seenCommentsIfNoneMatch []string
	var graphqlCalls, checkCalls, commentCalls int

	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		p := phase
		mu.Unlock()
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/repos/northwind/payments/pulls/701":
			if inm := r.Header.Get("If-None-Match"); inm != "" {
				mu.Lock()
				seenPRIfNoneMatch = append(seenPRIfNoneMatch, inm)
				mu.Unlock()
			}
			switch p {
			case 1:
				w.Header().Set("ETag", `"pr-1"`)
				_ = json.NewEncoder(w).Encode(map[string]any{
					"state": "open", "merged": false, "draft": false,
					"head": map[string]any{"sha": "sha1", "ref": "atlas/pay-214"},
				})
			case 2:
				if r.Header.Get("If-None-Match") == `"pr-1"` {
					w.WriteHeader(http.StatusNotModified)
					return
				}
				t.Errorf("expected If-None-Match \"pr-1\" in phase 2, got %q", r.Header.Get("If-None-Match"))
			case 3:
				w.Header().Set("ETag", `"pr-2"`)
				_ = json.NewEncoder(w).Encode(map[string]any{
					"state": "open", "merged": false, "draft": false,
					"head": map[string]any{"sha": "sha2", "ref": "atlas/pay-214"},
				})
			case 4:
				w.Header().Set("ETag", `"pr-3"`)
				_ = json.NewEncoder(w).Encode(map[string]any{
					"state": "closed", "merged": true, "draft": false,
					"head": map[string]any{"sha": "sha2", "ref": "atlas/pay-214"},
				})
			}

		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/repos/northwind/payments/commits/"):
			mu.Lock()
			checkCalls++
			if inm := r.Header.Get("If-None-Match"); inm != "" {
				seenChecksIfNoneMatch = append(seenChecksIfNoneMatch, inm)
			}
			mu.Unlock()
			switch {
			case p == 1 && strings.HasSuffix(r.URL.Path, "/sha1/check-runs"):
				w.Header().Set("ETag", `"chk-1"`)
				_ = json.NewEncoder(w).Encode(map[string]any{
					"check_runs": []map[string]any{
						{"id": 10, "name": "lint", "status": "completed", "conclusion": "failure", "completed_at": "2026-11-20T10:00:00Z"},
						{"id": 11, "name": "lint", "status": "completed", "conclusion": "success", "completed_at": "2026-11-20T10:05:00Z"},
						{
							"id": 12, "name": "test", "status": "completed", "conclusion": "failure",
							"details_url":  "https://github.com/northwind/payments/runs/12",
							"completed_at": "2026-11-20T10:02:00Z",
							"output":       map[string]any{"title": "Unit tests failed", "summary": "FAIL TestFoo"},
						},
						{"id": 13, "name": "build", "status": "completed", "conclusion": "success", "completed_at": "2026-11-20T10:01:00Z"},
					},
				})
			case p == 2 && strings.HasSuffix(r.URL.Path, "/sha1/check-runs"):
				if r.Header.Get("If-None-Match") == `"chk-1"` {
					w.WriteHeader(http.StatusNotModified)
					return
				}
				t.Errorf("expected If-None-Match \"chk-1\" in phase 2, got %q", r.Header.Get("If-None-Match"))
			case p == 3 && strings.HasSuffix(r.URL.Path, "/sha2/check-runs"):
				if inm := r.Header.Get("If-None-Match"); inm != "" {
					t.Errorf("new head SHA sha2 must not send stale ETag %q", inm)
				}
				w.Header().Set("ETag", `"chk-2"`)
				_ = json.NewEncoder(w).Encode(map[string]any{
					"check_runs": []map[string]any{
						{"id": 20, "name": "test", "status": "completed", "conclusion": "success", "completed_at": "2026-11-20T10:10:00Z"},
					},
				})
			default:
				http.NotFound(w, r)
			}

		case r.Method == http.MethodGet && r.URL.Path == "/repos/northwind/payments/pulls/701/comments":
			mu.Lock()
			commentCalls++
			if inm := r.Header.Get("If-None-Match"); inm != "" {
				seenCommentsIfNoneMatch = append(seenCommentsIfNoneMatch, inm)
			}
			mu.Unlock()
			switch p {
			case 1:
				w.Header().Set("ETag", `"rev-1"`)
				_, _ = io.WriteString(w, `[]`)
			case 2:
				if r.Header.Get("If-None-Match") == `"rev-1"` {
					w.WriteHeader(http.StatusNotModified)
					return
				}
				t.Errorf("expected If-None-Match \"rev-1\" in phase 2, got %q", r.Header.Get("If-None-Match"))
			case 3:
				w.Header().Set("ETag", `"rev-2"`)
				_, _ = io.WriteString(w, `[]`)
			default:
				http.NotFound(w, r)
			}

		case r.Method == http.MethodPost && r.URL.Path == "/graphql":
			mu.Lock()
			graphqlCalls++
			mu.Unlock()
			nodes := []map[string]any{}
			if p == 1 {
				nodes = []map[string]any{
					{
						"id": "T1", "isResolved": true, "path": "old.go", "line": 1,
						"comments": map[string]any{"nodes": []map[string]any{{"author": map[string]any{"login": "bob"}, "body": "Resolved", "createdAt": "2026-11-20T09:00:00Z"}}},
					},
					{
						"id": "T2", "isResolved": false, "path": "server/main.go", "line": 42,
						"comments": map[string]any{"nodes": []map[string]any{{
							"author": map[string]any{"login": "alice"}, "body": "Handle nil error here",
							"url":       "https://github.com/northwind/payments/pull/701#discussion_r2",
							"createdAt": "2026-11-20T10:03:00Z", "diffHunk": "@@ -40,3 +40,3 @@\n+foo",
						}}},
					},
				}
			}
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": map[string]any{
					"repository": map[string]any{
						"pullRequest": map[string]any{
							"reviewThreads": map[string]any{"nodes": nodes},
						},
					},
				},
			})

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

	// Phase 1: Initial poll captures failing test check (deduplicating re-run lint) & unresolved GraphQL thread T2.
	if _, err := s.Once(ctx); err != nil {
		t.Fatal(err)
	}
	fb1, err := q.GetPRFeedback(ctx, store.GetPRFeedbackParams{WorkspaceID: ws, PrUrl: prURL})
	if err != nil {
		t.Fatal(err)
	}
	if fb1.CiState != "failing" || fb1.FailedChecksCount != 1 || fb1.UnresolvedThreads != 1 || fb1.HeadSha != "sha1" {
		t.Fatalf("phase 1 feedback = %+v", fb1)
	}
	if fb1.PrEtag != `"pr-1"` || fb1.ChecksEtag != `"chk-1"` || fb1.ReviewsEtag != `"rev-1"` {
		t.Fatalf("phase 1 etags = (%q, %q, %q)", fb1.PrEtag, fb1.ChecksEtag, fb1.ReviewsEtag)
	}
	if !strings.Contains(string(fb1.FailedChecks), `"test"`) || strings.Contains(string(fb1.FailedChecks), `"lint"`) {
		t.Fatalf("unexpected failed checks JSON: %s", fb1.FailedChecks)
	}
	if !strings.Contains(string(fb1.ReviewThreads), `"T2"`) || strings.Contains(string(fb1.ReviewThreads), `"T1"`) {
		t.Fatalf("unexpected review threads JSON: %s", fb1.ReviewThreads)
	}

	// Phase 2: 304 Not Modified skips GraphQL and preserves timestamps/feedback.
	mu.Lock()
	phase = 2
	beforeGQL := graphqlCalls
	mu.Unlock()
	if _, err := s.Once(ctx); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	afterGQL := graphqlCalls
	mu.Unlock()
	if afterGQL != beforeGQL {
		t.Fatalf("expected 0 GraphQL calls on 304 cache hit, got %d", afterGQL-beforeGQL)
	}
	fb2, err := q.GetPRFeedback(ctx, store.GetPRFeedbackParams{WorkspaceID: ws, PrUrl: prURL})
	if err != nil {
		t.Fatal(err)
	}
	if fb2.CiFailedAt == nil || fb1.CiFailedAt == nil || !fb2.CiFailedAt.Equal(*fb1.CiFailedAt) {
		t.Fatalf("phase 2 ci_failed_at changed: %v vs %v", fb2.CiFailedAt, fb1.CiFailedAt)
	}
	if len(seenPRIfNoneMatch) == 0 || len(seenChecksIfNoneMatch) == 0 || len(seenCommentsIfNoneMatch) == 0 {
		t.Fatalf("expected conditional If-None-Match headers, got pr=%v checks=%v comments=%v", seenPRIfNoneMatch, seenChecksIfNoneMatch, seenCommentsIfNoneMatch)
	}

	// Phase 3: New head SHA clears failing state and resolved threads.
	mu.Lock()
	phase = 3
	mu.Unlock()
	if _, err := s.Once(ctx); err != nil {
		t.Fatal(err)
	}
	fb3, err := q.GetPRFeedback(ctx, store.GetPRFeedbackParams{WorkspaceID: ws, PrUrl: prURL})
	if err != nil {
		t.Fatal(err)
	}
	if fb3.CiState != "passing" || fb3.FailedChecksCount != 0 || fb3.UnresolvedThreads != 0 || fb3.CiFailedAt != nil || fb3.ReviewUpdatedAt != nil || fb3.HeadSha != "sha2" {
		t.Fatalf("phase 3 feedback = %+v", fb3)
	}

	// Phase 4: Merged PR does not query check-runs or comments/GraphQL.
	mu.Lock()
	phase = 4
	beforeChecks, beforeComments, beforeGQL4 := checkCalls, commentCalls, graphqlCalls
	mu.Unlock()
	if _, err := s.Once(ctx); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	gotChecks, gotComments, gotGQL4 := checkCalls, commentCalls, graphqlCalls
	mu.Unlock()
	if gotChecks != beforeChecks || gotComments != beforeComments || gotGQL4 != beforeGQL4 {
		t.Fatalf("merged PR should skip feedback calls: checks %d->%d, comments %d->%d, gql %d->%d",
			beforeChecks, gotChecks, beforeComments, gotComments, beforeGQL4, gotGQL4)
	}
	_ = time.Second
}

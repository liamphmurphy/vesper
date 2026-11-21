package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/realtime"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestAttentionAndCrossTabApproval(t *testing.T) {
	pool := testdb.New(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: &artifacts.Service{Pool: pool}}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tr := &tracker.Service{Pool: pool}
	svc := &runs.Service{Pool: pool, Tracker: tr}
	h := realtime.New()
	done := make(chan struct{})
	go func() { defer close(done); h.Run(ctx, pool) }()
	defer func() { cancel(); <-done }()
	srv := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: svc, Events: h}
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	atlas, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: u.WorkspaceID, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "unmanaged", "test", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	caller, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	run, err := svc.Claim(ctx, caller, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	// Managed resumption must queue a turn. Nothing starts a real harness here.
	if _, err = pool.Exec(ctx, "UPDATE runs SET mode='managed' WHERE id=$1", run.ID); err != nil {
		t.Fatal(err)
	}
	outcome, err := svc.RequestApproval(ctx, caller, "PAY-214", "db:migrate", "Test migration", map[string]any{"sql": "SELECT 1"}, "Read only test")
	if err != nil {
		t.Fatal(err)
	}
	ap := outcome.Approval
	// Ensure the actual query scans unions, read state, and seeded suggestions.
	authctx := auth.WithUser(ctx, u)
	inbox, err := srv.ListInbox(authctx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	items := inbox.(api.ListInbox200JSONResponse).Items
	id := "approval:" + ap.ID.String()
	found := false
	for _, item := range items {
		if item.Id == id {
			found = true
			if item.Read || item.Resolved {
				t.Fatal("new approval should be unread and pending")
			}
			if item.Agent == nil || item.Agent.Handle != "atlas" || item.RunId == nil || *item.RunId != run.ID {
				t.Fatalf("approval should carry its agent and run: %+v", item)
			}
		}
	}
	if !found {
		t.Fatal("missing approval")
	}
	if _, err = srv.ReadInboxItem(authctx, api.ReadInboxItemRequestObject{Body: &api.ReadInboxItemJSONRequestBody{Id: id}}); err != nil {
		t.Fatal(err)
	}
	inbox, err = srv.ListInbox(authctx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range inbox.(api.ListInbox200JSONResponse).Items {
		if item.Id == id && !item.Read {
			t.Fatal("read state did not persist")
		}
	}
	// Undo: the item is open again.
	if _, err = srv.UnreadInboxItem(authctx, api.UnreadInboxItemRequestObject{Body: &api.UnreadInboxItemJSONRequestBody{Id: id}}); err != nil {
		t.Fatal(err)
	}
	inbox, err = srv.ListInbox(authctx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	for _, item := range inbox.(api.ListInbox200JSONResponse).Items {
		if item.Id == id && item.Read {
			t.Fatal("unread did not reopen the item")
		}
	}

	// Human mentions are matched by @email-local-part or @full name, with
	// self-comments excluded and read state isolated per user.
	tk, err := tracker.Get(ctx, q, u.WorkspaceID, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	var commentID string
	err = pool.QueryRow(ctx, `INSERT INTO comments(workspace_id,ticket_id,author_type,author_id,body_md)
 VALUES($1,$2,'agent',$3,$4) RETURNING id::text`, u.WorkspaceID, tk.ID, atlas.ID, "Please review, @"+strings.Split(u.Email, "@")[0]).Scan(&commentID)
	if err != nil {
		t.Fatal(err)
	}
	inbox, err = srv.ListInbox(authctx, api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	found = false
	for _, i := range inbox.(api.ListInbox200JSONResponse).Items {
		if i.Id == "mention:"+commentID {
			found = true
		}
	}
	if !found {
		t.Fatal("human mention missing")
	}
	users, err := q.ListUsers(ctx, u.WorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	for _, other := range users {
		if other.ID == u.ID {
			continue
		}
		otherItems, err := q.ListInbox(ctx, store.ListInboxParams{UserID: other.ID, WorkspaceID: u.WorkspaceID})
		if err != nil {
			t.Fatal(err)
		}
		for _, i := range otherItems {
			if i.ID == id && i.Read {
				t.Fatal("read state leaked between users")
			}
		}
		break
	}
	needs := api.ListTicketsParamsViewNeedsHuman
	tickets, err := srv.ListTickets(authctx, api.ListTicketsRequestObject{Params: api.ListTicketsParams{View: &needs}})
	if err != nil {
		t.Fatal(err)
	}
	found = false
	for _, tk := range tickets.(api.ListTickets200JSONResponse).Tickets {
		if tk.Key == "PAY-214" {
			found = true
		}
	}
	if !found {
		t.Fatal("needs human view missed pending approval")
	}
	// Open two browser-equivalent SSE connections before approving in one tab.
	streams := []chan string{}
	for range 2 {
		streamctx, stop := context.WithCancel(ctx)
		defer stop()
		req, _ := http.NewRequestWithContext(streamctx, "GET", ts.URL+"/events", nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		ch := make(chan string, 64)
		streams = append(streams, ch)
		go func() {
			defer close(ch)
			scan := bufio.NewScanner(resp.Body)
			for scan.Scan() {
				line := scan.Text()
				if strings.HasPrefix(line, "data: ") {
					ch <- strings.TrimPrefix(line, "data: ")
				}
			}
		}()
		select {
		case <-ch:
		case <-time.After(time.Second):
			t.Fatal("stream did not open")
		}
	}
	start := time.Now()
	resp, err := http.Post(ts.URL+"/api/v1/approvals/"+ap.ID.String()+"/approve", "application/json", strings.NewReader(`{"note":"Proceed"}`))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("approval status %d", resp.StatusCode)
	}
	for _, ch := range streams {
		got := false
		deadline := time.After(time.Second)
		for !got {
			select {
			case msg := <-ch:
				got = strings.Contains(msg, "approval.updated")
			case <-deadline:
				t.Fatal("other tab missed approval update")
			}
		}
	}
	if time.Since(start) > time.Second {
		t.Fatal("cross-tab update took over one second")
	}
	turns, err := q.ListTurns(ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	last := turns[len(turns)-1]
	if last.Trigger != "approval" || last.Status != "pending" || !strings.Contains(last.InputMessage, "Proceed") {
		t.Fatalf("no queued resume: %+v", last)
	}
	searchResp, err := http.Get(ts.URL + "/api/v1/search?q=Atlas")
	if err != nil {
		t.Fatal(err)
	}
	defer searchResp.Body.Close()
	var results api.Search200JSONResponse
	if err = json.NewDecoder(searchResp.Body).Decode(&results); err != nil {
		t.Fatal(err)
	}
	found = false
	for _, hit := range results.Hits {
		if hit.Target.Kind == api.LinkTargetKindAgent {
			found = true
		}
	}
	if !found {
		t.Fatal("global search missed agent")
	}
	// Partial and misspelled names match, and ticket runs are searchable.
	for query, kind := range map[string]api.LinkTargetKind{"Atl": api.LinkTargetKindAgent, "Atlsa": api.LinkTargetKindAgent, "PAY-214": api.LinkTargetKindRun} {
		r, err := http.Get(ts.URL + "/api/v1/search?q=" + query)
		if err != nil {
			t.Fatal(err)
		}
		var got api.Search200JSONResponse
		err = json.NewDecoder(r.Body).Decode(&got)
		r.Body.Close()
		if err != nil {
			t.Fatal(err)
		}
		if !slices.ContainsFunc(got.Hits, func(h api.SearchHit) bool { return h.Target.Kind == kind && h.Score > 0 }) {
			t.Fatalf("search %q missed a scored %s: %+v", query, kind, got.Hits)
		}
	}
	searchResp2, err := http.Get(ts.URL + "/api/v1/search?q=PAY-214&project=BIL")
	if err != nil {
		t.Fatal(err)
	}
	defer searchResp2.Body.Close()
	if err = json.NewDecoder(searchResp2.Body).Decode(&results); err != nil {
		t.Fatal(err)
	}
	for _, hit := range results.Hits {
		if hit.Target.Kind == api.LinkTargetKindTicket {
			t.Fatal("project scope leaked ticket")
		}
	}
}

// await_human questions and stalled runs are their own Inbox kinds, with the
// agent's question as the summary and the run to reply to, retry or cancel.
func TestInboxQuestionsAndStalledRuns(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: &artifacts.Service{Pool: pool}}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	tr := &tracker.Service{Pool: pool}
	svc := &runs.Service{Pool: pool, Tracker: tr}
	srv := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: svc}
	atlas, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: u.WorkspaceID, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}
	tok, _, err := agents.IssueToken(ctx, q, atlas.ID, "unmanaged", "test", nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	caller, err := agents.ResolveToken(ctx, q, tok)
	if err != nil {
		t.Fatal(err)
	}
	run, err := svc.Claim(ctx, caller, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	if err := svc.AwaitHuman(ctx, caller, "PAY-214", "Should retries cap at 5 or 8?"); err != nil {
		t.Fatal(err)
	}
	authctx := auth.WithUser(ctx, u)
	find := func(id string) *api.InboxItem {
		t.Helper()
		res, err := srv.ListInbox(authctx, api.ListInboxRequestObject{})
		if err != nil {
			t.Fatal(err)
		}
		for _, item := range res.(api.ListInbox200JSONResponse).Items {
			if item.Id == id {
				return &item
			}
		}
		return nil
	}
	question := find("question:" + run.ID.String())
	if question == nil {
		t.Fatal("await_human run missing from inbox")
	}
	if question.Kind != api.InboxItemKindQuestion || question.Summary != "Should retries cap at 5 or 8?" || question.TicketKey != "PAY-214" {
		t.Fatalf("question item: %+v", question)
	}
	if question.Agent == nil || question.Agent.Handle != "atlas" || question.RunId == nil || *question.RunId != run.ID {
		t.Fatalf("question should carry its agent and run: %+v", question)
	}
	if find("blocked:"+run.ID.String()) != nil {
		t.Fatal("a question must not also be listed as a blocked run")
	}

	// A running run with no event for 30 minutes is stalled; a fresh event clears it.
	if _, err := pool.Exec(ctx, `UPDATE runs SET state='running', wait_reason=NULL, started_at=now()-interval '2 hours' WHERE id=$1`, run.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE run_events SET at=now()-interval '45 minutes' WHERE run_id=$1`, run.ID); err != nil {
		t.Fatal(err)
	}
	if find("question:"+run.ID.String()) != nil {
		t.Fatal("answered question still listed")
	}
	stalled := find("stalled:" + run.ID.String())
	if stalled == nil || stalled.Kind != api.InboxItemKindStalled || stalled.Resolved || time.Since(stalled.CreatedAt) < 30*time.Minute {
		t.Fatalf("stalled run missing or wrong: %+v", stalled)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO run_events(run_id,type,payload) VALUES($1,'message','{}')`, run.ID); err != nil {
		t.Fatal(err)
	}
	if find("stalled:"+run.ID.String()) != nil {
		t.Fatal("a run with recent activity is not stalled")
	}

	// A failed delegated child is its parent's business (and can't be retried);
	// it must not hide the parent's own failure either.
	var child string
	err = pool.QueryRow(ctx, `INSERT INTO runs (workspace_id,ticket_id,agent_id,mode,state,resolved_spec,harness,model,purpose,parent_run_id,started_at)
 SELECT workspace_id,ticket_id,agent_id,'managed','failed',resolved_spec,harness,model,'ticket',id,now() FROM runs WHERE id=$1 RETURNING id::text`, run.ID).Scan(&child)
	if err != nil {
		t.Fatal(err)
	}
	if find("blocked:"+child) != nil {
		t.Fatal("a failed delegated child is listed as a failed run")
	}
	if _, err := pool.Exec(ctx, `UPDATE runs SET state='failed', outcome='Harness error' WHERE id=$1`, run.ID); err != nil {
		t.Fatal(err)
	}
	if failed := find("blocked:" + run.ID.String()); failed == nil || failed.Summary != "Harness error" {
		t.Fatalf("parent failure hidden by its child: %+v", failed)
	}
}

func TestInboxMentionsEscapedNameAndCommentIndexes(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: &artifacts.Service{Pool: pool}}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	// Give the user a display name containing SQL LIKE wildcards (% and _) to verify
	// LIKE pattern escaping matches only literal mentions.
	if _, err := pool.Exec(ctx, `UPDATE users SET name = 'Sam_100% Real' WHERE id = $1`, u.ID); err != nil {
		t.Fatal(err)
	}
	ticket, err := q.GetTicketByKey(ctx, store.GetTicketByKeyParams{WorkspaceID: u.WorkspaceID, Key: "PAY-214"})
	if err != nil {
		t.Fatal(err)
	}
	atlas, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: u.WorkspaceID, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}

	var exactID, wildcardFalseID, noAtID string
	if err := pool.QueryRow(ctx, `INSERT INTO comments(workspace_id,ticket_id,author_type,author_id,body_md) VALUES($1,$2,'agent',$3,'Hey @Sam_100% Real, check this?') RETURNING 'mention:'||id`,
		u.WorkspaceID, ticket.ID, atlas.ID).Scan(&exactID); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO comments(workspace_id,ticket_id,author_type,author_id,body_md) VALUES($1,$2,'agent',$3,'Hey @SamX100anything Real, ignore') RETURNING 'mention:'||id`,
		u.WorkspaceID, ticket.ID, atlas.ID).Scan(&wildcardFalseID); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO comments(workspace_id,ticket_id,author_type,author_id,body_md) VALUES($1,$2,'agent',$3,'Sam_100% Real without at-sign') RETURNING 'mention:'||id`,
		u.WorkspaceID, ticket.ID, atlas.ID).Scan(&noAtID); err != nil {
		t.Fatal(err)
	}

	srv := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: &tracker.Service{Pool: pool}, Runs: &runs.Service{Pool: pool}}
	res, err := srv.ListInbox(auth.WithUser(ctx, u), api.ListInboxRequestObject{})
	if err != nil {
		t.Fatal(err)
	}
	byID := map[string]api.InboxItem{}
	for _, item := range res.(api.ListInbox200JSONResponse).Items {
		byID[item.Id] = item
	}
	if _, ok := byID[exactID]; !ok {
		t.Fatalf("literal mention %s missing from ListInbox", exactID)
	}
	if _, ok := byID[wildcardFalseID]; ok {
		t.Fatalf("wildcard-like comment %s falsely matched escaped name", wildcardFalseID)
	}
	if _, ok := byID[noAtID]; ok {
		t.Fatalf("comment without @ %s falsely matched as mention", noAtID)
	}

	// Verify Postgres query planner uses comments_workspace_at_idx or comments_at_trgm_idx
	// on the mention filter when seqscan is disabled.
	tx, err := pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL enable_seqscan = off`); err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(ctx, `
		EXPLAIN (FORMAT TEXT)
		SELECT 'mention:'||c.id
		FROM comments c JOIN tickets t ON t.id=c.ticket_id JOIN projects p ON p.id=t.project_id JOIN users u ON u.id=$1
		WHERE c.workspace_id=$2 AND NOT (c.author_type='user' AND c.author_id=u.id)
		AND strpos(c.body_md, '@') > 0
		AND (lower(c.body_md) ~ ('@'||regexp_replace(lower(split_part(u.email,'@',1)), '([^a-z0-9_])', '\\\1','g')||'\y')
		OR lower(c.body_md) LIKE CASE WHEN u.name = '' THEN 'A' ELSE '%@'||regexp_replace(lower(u.name), '([%_\\])', '\\\1', 'g')||'%' END ESCAPE '\')`,
		u.ID, u.WorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	var planLines []string
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		planLines = append(planLines, line)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	plan := strings.Join(planLines, "\n")
	if !strings.Contains(plan, "comments_workspace_at_idx") && !strings.Contains(plan, "comments_at_trgm_idx") {
		t.Fatalf("expected comments_workspace_at_idx or comments_at_trgm_idx in EXPLAIN plan, got:\n%s", plan)
	}
}

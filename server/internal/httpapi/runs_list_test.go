package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"strconv"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// The Runs index lists top-level ticket and planning runs with their work and
// project, and filters by state, agent, project and purpose. Personal
// Assistant chat runs are never listed: they belong to Chat.
func TestListRuns(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: &artifacts.Service{Pool: pool}}); err != nil {
		t.Fatal(err)
	}
	tr := &tracker.Service{Pool: pool}
	s := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: &runs.Service{Pool: pool, Tracker: tr}}
	handler := s.Handler()
	list := func(query string, intended int) api.ListRuns200JSONResponse {
		t.Helper()
		r := httptest.NewRecorder()
		handler.ServeHTTP(r, httptest.NewRequest("GET", "/api/v1/runs"+query, nil))
		if r.Code != intended {
			t.Fatalf("%s: %d %s", query, r.Code, r.Body.String())
		}
		var out api.ListRuns200JSONResponse
		if intended == 200 {
			if err := json.Unmarshal(r.Body.Bytes(), &out); err != nil {
				t.Fatal(err)
			}
		}
		return out
	}
	ids := func(out api.ListRuns200JSONResponse) map[uuid.UUID]api.Run {
		m := map[uuid.UUID]api.Run{}
		for _, r := range out.Runs {
			m[r.Id] = r
		}
		return m
	}

	user, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ws := user.WorkspaceID
	agent := func(handle string) store.Agent {
		a, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: handle})
		if err != nil {
			t.Fatal(err)
		}
		return a
	}
	atlas := agent("atlas")
	ticket, err := tracker.Get(ctx, q, ws, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}
	newRun := func(a store.Agent, state, purpose string, ticketID, parent *uuid.UUID) store.Run {
		t.Helper()
		r, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: ws, TicketID: ticketID, AgentID: a.ID, Mode: "managed", State: state, ResolvedSpec: json.RawMessage(`{}`), Harness: "codex", Model: "m", ParentRunID: parent, Purpose: purpose})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	ticketRun := newRun(atlas, "waiting", "ticket", &ticket.ID, nil)
	child := newRun(atlas, "running", "ticket", &ticket.ID, &ticketRun.ID)

	var other struct {
		ID  uuid.UUID
		Key string
	}
	if err := pool.QueryRow(ctx, `SELECT id, key FROM projects WHERE workspace_id = $1 AND key <> 'PAY' ORDER BY key LIMIT 1`, ws).Scan(&other.ID, &other.Key); err != nil {
		t.Fatal(err)
	}
	planRun := newRun(atlas, "completed", "planning", nil, nil)
	var planID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO planning_sessions (workspace_id, project_id, goal, run_id, created_by) VALUES ($1, $2, 'Harden the ledger', $3, $4) RETURNING id`, ws, other.ID, planRun.ID, user.ID).Scan(&planID); err != nil {
		t.Fatal(err)
	}
	// A chat's earlier segment is found through its messages, not current_run_id.
	chatOld := newRun(atlas, "completed", "chat", nil, nil)
	chatRun := newRun(atlas, "running", "chat", nil, nil)
	var chatID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO chat_sessions (workspace_id, project_id, title, created_by, agent_id, harness, model, current_run_id) VALUES ($1, $2, 'Refund questions', $3, $4, 'codex', 'm', $5) RETURNING id`, ws, ticket.ProjectID, user.ID, atlas.ID, chatRun.ID).Scan(&chatID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO chat_messages (session_id, seq, role, body_md, run_id) VALUES ($1, 1, 'user', 'hi', $2)`, chatID, chatOld.ID); err != nil {
		t.Fatal(err)
	}

	var foreignWS uuid.UUID
	if err := pool.QueryRow(ctx, "INSERT INTO workspaces (name,slug) VALUES ('Other','other-runs') RETURNING id").Scan(&foreignWS); err != nil {
		t.Fatal(err)
	}
	foreign, err := q.CreateRun(ctx, store.CreateRunParams{WorkspaceID: foreignWS, AgentID: atlas.ID, Mode: "managed", State: "running", ResolvedSpec: json.RawMessage(`{}`), Harness: "codex", Model: "m", Purpose: "planning"})
	if err != nil {
		t.Fatal(err)
	}
	orphan := newRun(atlas, "running", "planning", nil, nil)
	live := ids(list("", 200))
	if _, ok := live[foreign.ID]; ok {
		t.Fatal("cross-workspace run leaked")
	}
	if _, ok := live[orphan.ID]; !ok {
		t.Fatal("legacy planning run without a session must not fail the index")
	}
	if _, ok := live[child.ID]; ok {
		t.Fatal("delegated runs belong to their parent, not the index")
	}
	if _, ok := live[planRun.ID]; ok {
		t.Fatal("live filter leaked a completed run")
	}
	tr0, ok := live[ticketRun.ID]
	if !ok {
		t.Fatalf("live runs missing: %+v", live)
	}
	if _, ok := live[chatRun.ID]; ok {
		t.Fatal("a chat run leaked into the Runs index")
	}
	if tr0.Purpose != api.RunPurposeTicket || tr0.ProjectKey == nil || *tr0.ProjectKey != "PAY" || tr0.WorkTitle == nil || *tr0.WorkTitle != ticket.Title || tr0.ChildCount == nil || *tr0.ChildCount != 1 {
		t.Fatalf("ticket run not enriched: %+v", tr0)
	}

	all := ids(list("?state=all", 200))
	pr := all[planRun.ID]
	if pr.PlanningId == nil || *pr.PlanningId != planID || pr.ProjectKey == nil || *pr.ProjectKey != other.Key || pr.WorkTitle == nil || *pr.WorkTitle != "Harden the ledger" {
		t.Fatalf("planning run not enriched: %+v", pr)
	}
	if _, ok := all[chatOld.ID]; ok {
		t.Fatal("an ended chat segment leaked into the Runs index")
	}

	if got := ids(list("?state=all&project="+other.Key, 200)); len(got) != 1 || got[planRun.ID].Id == uuid.Nil {
		t.Fatalf("project filter: %+v", got)
	}
	if got := ids(list("?state=all&project=PAY&purpose=chat", 200)); len(got) != 0 {
		t.Fatalf("purpose=chat must list nothing: %+v", got)
	}
	if got := ids(list("?state=waiting", 200)); got[ticketRun.ID].Id == uuid.Nil || got[chatRun.ID].Id != uuid.Nil {
		t.Fatalf("single state filter: %+v", got)
	}
	if got := list("?state=all&agent=atlas", 200); len(got.Runs) < 3 {
		t.Fatalf("agent filter dropped runs: %d", len(got.Runs))
	}
	// A ticket filter lists every run on that ticket, delegated runs included.
	byTicket := ids(list("?state=all&ticket=PAY-214", 200))
	if byTicket[ticketRun.ID].Id == uuid.Nil || byTicket[child.ID].Id == uuid.Nil {
		t.Fatalf("ticket filter missed the ticket's runs: %+v", byTicket)
	}
	for _, r := range byTicket {
		if r.TicketKey != "PAY-214" {
			t.Fatalf("ticket filter leaked %s run %s", r.Purpose, r.Id)
		}
	}
	if got := list("?ticket=NOPE-1", 200); len(got.Runs) != 0 {
		t.Fatal("unknown ticket must match nothing")
	}
	if got := list("?agent=nobody", 200); len(got.Runs) != 0 {
		t.Fatal("unknown agent must match nothing")
	}
	if got := list("?project=NOPE", 200); len(got.Runs) != 0 {
		t.Fatal("unknown project must match nothing")
	}
	list("?state=bogus", 422)
	list("?purpose=bogus", 422)
	list("?offset=-1", 422)
}

func TestListRunEventsAndBatchHydration(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: &artifacts.Service{Pool: pool}}); err != nil {
		t.Fatal(err)
	}
	tr := &tracker.Service{Pool: pool}
	s := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: &runs.Service{Pool: pool, Tracker: tr}}
	handler := s.Handler()

	user, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ws := user.WorkspaceID
	atlas, err := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	if err != nil {
		t.Fatal(err)
	}
	ticket, err := tracker.Get(ctx, q, ws, "PAY-214")
	if err != nil {
		t.Fatal(err)
	}

	parentRun, err := q.CreateRun(ctx, store.CreateRunParams{
		WorkspaceID: ws, TicketID: &ticket.ID, AgentID: atlas.ID, Mode: "managed", State: "running",
		ResolvedSpec: json.RawMessage(`{}`), Harness: "codex", Model: "m", Purpose: "ticket",
	})
	if err != nil {
		t.Fatal(err)
	}
	childRun, err := q.CreateRun(ctx, store.CreateRunParams{
		WorkspaceID: ws, TicketID: &ticket.ID, AgentID: atlas.ID, Mode: "managed", State: "completed",
		ResolvedSpec: json.RawMessage(`{}`), Harness: "codex", Model: "m", ParentRunID: &parentRun.ID, Purpose: "ticket",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := q.InsertPlanStep(ctx, store.InsertPlanStepParams{RunID: parentRun.ID, Position: 1, Text: "Inspect index", State: "done"}); err != nil {
		t.Fatal(err)
	}
	if err := q.InsertPlanStep(ctx, store.InsertPlanStepParams{RunID: childRun.ID, Position: 1, Text: "Child step", State: "pending"}); err != nil {
		t.Fatal(err)
	}

	chatOld, err := q.CreateRun(ctx, store.CreateRunParams{
		WorkspaceID: ws, AgentID: atlas.ID, Mode: "managed", State: "completed",
		ResolvedSpec: json.RawMessage(`{}`), Harness: "codex", Model: "m", Purpose: "chat",
	})
	if err != nil {
		t.Fatal(err)
	}
	var chatID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO chat_sessions (workspace_id, project_id, title, created_by, agent_id, harness, model, current_run_id) VALUES ($1, $2, 'Private chat', $3, $4, 'codex', 'm', $5) RETURNING id`, ws, ticket.ProjectID, user.ID, atlas.ID, chatOld.ID).Scan(&chatID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `INSERT INTO chat_messages (session_id, seq, role, body_md, run_id) VALUES ($1, 1, 'assistant', 'hello', $2)`, chatID, chatOld.ID); err != nil {
		t.Fatal(err)
	}

	if err := q.AddRunEvents(ctx, store.AddRunEventsParams{
		RunID:    chatOld.ID,
		Types:    []string{"message", "tool_call", "tool_result"},
		Payloads: []string{`{"role":"assistant","text":"one"}`, `{"id":"t1","tool":"Bash"}`, `{"id":"t1","output":"ok"}`},
	}); err != nil {
		t.Fatal(err)
	}

	// GET /runs/{id}/events fetches events and respects ?after=seq.
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest("GET", "/api/v1/runs/"+chatOld.ID.String()+"/events", nil))
	if rec.Code != 200 {
		t.Fatalf("events status=%d body=%s", rec.Code, rec.Body.String())
	}
	var all api.RunEventList
	if err := json.Unmarshal(rec.Body.Bytes(), &all); err != nil {
		t.Fatal(err)
	}
	if len(all.Events) != 3 {
		t.Fatalf("got %d events, want 3", len(all.Events))
	}

	rec2 := httptest.NewRecorder()
	handler.ServeHTTP(rec2, httptest.NewRequest("GET", "/api/v1/runs/"+chatOld.ID.String()+"/events?after="+strconv.FormatInt(all.Events[1].Seq, 10), nil))
	if rec2.Code != 200 {
		t.Fatalf("events after status=%d body=%s", rec2.Code, rec2.Body.String())
	}
	var tail api.RunEventList
	if err := json.Unmarshal(rec2.Body.Bytes(), &tail); err != nil {
		t.Fatal(err)
	}
	if len(tail.Events) != 1 || tail.Events[0].Seq != all.Events[2].Seq {
		t.Fatalf("tail=%+v want seq=%d", tail.Events, all.Events[2].Seq)
	}

	// Private chat runs reject another user in the same workspace.
	var otherID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO users (workspace_id, email, name, initials, password_hash) VALUES ($1, 'other-events@example.com', 'Other', 'O', 'x') RETURNING id`, ws).Scan(&otherID); err != nil {
		t.Fatal(err)
	}
	_, err = s.ListRunEvents(auth.WithUser(ctx, store.User{ID: otherID, WorkspaceID: ws}), api.ListRunEventsRequestObject{Id: chatOld.ID})
	if !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for another user's private chat run, got %v", err)
	}

	// GetRun hydrates subagent_jobs with spawn decision metadata (reason, tiers, model, effort, batch_id, tokens).
	batchID := uuid.New()
	sj, err := q.CreateSubagentJob(ctx, store.CreateSubagentJobParams{
		RunID:         parentRun.ID,
		AgentType:     "explorer",
		Role:          "Code Seeker",
		Prompt:        "find handlers",
		Tier:          "fast",
		Model:         "gemini-3.8-flash",
		Effort:        "low",
		RequestedTier: "deep",
		Reason:        "Locate auth call sites before modifying middleware.",
		BatchID:       &batchID,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := q.CompleteSubagentJob(ctx, store.CompleteSubagentJobParams{
		ID:           sj.ID,
		ResultText:   "Found 3 call sites",
		InputTokens:  1200,
		OutputTokens: 150,
		CachedTokens: 400,
		ToolCalls:    4,
	}); err != nil {
		t.Fatal(err)
	}

	// GetRun still hydrates child runs via toRuns (including child plan steps and project key).
	getRec := httptest.NewRecorder()
	handler.ServeHTTP(getRec, httptest.NewRequest("GET", "/api/v1/runs/"+parentRun.ID.String(), nil))
	if getRec.Code != 200 {
		t.Fatalf("getRun status=%d body=%s", getRec.Code, getRec.Body.String())
	}
	var detail api.RunDetail
	if err := json.Unmarshal(getRec.Body.Bytes(), &detail); err != nil {
		t.Fatal(err)
	}
	if detail.Run.ChildCount == nil || *detail.Run.ChildCount != 1 || len(detail.Run.Plan) != 1 {
		t.Fatalf("parent hydration wrong: %+v", detail.Run)
	}
	if len(detail.ChildRuns) != 1 || detail.ChildRuns[0].Id != childRun.ID || len(detail.ChildRuns[0].Plan) != 1 || detail.ChildRuns[0].ProjectKey == nil || *detail.ChildRuns[0].ProjectKey != "PAY" {
		t.Fatalf("child hydration wrong: %+v", detail.ChildRuns)
	}
	if detail.SubagentJobs == nil || len(*detail.SubagentJobs) != 1 {
		t.Fatalf("subagent_jobs = %+v, want 1", detail.SubagentJobs)
	}
	gotSJ := (*detail.SubagentJobs)[0]
	if gotSJ.Id != sj.ID || gotSJ.Role != "Code Seeker" || gotSJ.Reason != "Locate auth call sites before modifying middleware." ||
		gotSJ.RequestedTier != "deep" || gotSJ.Tier != "fast" || gotSJ.Model != "gemini-3.8-flash" || gotSJ.Effort != "low" ||
		!gotSJ.BatchId.IsSpecified() || gotSJ.BatchId.MustGet() != batchID || gotSJ.Status != "completed" ||
		gotSJ.ToolCalls != 4 || gotSJ.InputTokens != 1200 || gotSJ.OutputTokens != 150 || gotSJ.CachedTokens != 400 {
		t.Fatalf("subagent job hydration wrong: %+v", gotSJ)
	}
}

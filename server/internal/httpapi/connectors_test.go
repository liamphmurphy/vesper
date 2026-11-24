package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/connectors"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

type echoIn struct {
	Text string `json:"text"`
}

func upstreamMCP(t *testing.T) *httptest.Server {
	t.Helper()
	srv := mcp.NewServer(&mcp.Implementation{Name: "up", Version: "1"}, nil)
	add := func(name string, ro bool) {
		mcp.AddTool(srv, &mcp.Tool{Name: name, Annotations: &mcp.ToolAnnotations{ReadOnlyHint: ro}}, func(_ context.Context, _ *mcp.CallToolRequest, in echoIn) (*mcp.CallToolResult, any, error) {
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: name + ":" + in.Text}}}, nil, nil
		})
	}
	add("read_thing", true)
	add("write_thing", false)
	add("drop_thing", false)
	h := httptest.NewServer(mcp.NewStreamableHTTPHandler(func(*http.Request) *mcp.Server { return srv }, &mcp.StreamableHTTPOptions{DisableLocalhostProtection: true}))
	t.Cleanup(h.Close)
	return h
}

// A run reaches only what its persona was granted, with each tool's permission enforced.
func TestConnectorProxyEnforcesPermissions(t *testing.T) {
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
	srv := &Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts, Wiki: &wiki.Service{Pool: pool, Artifacts: arts, Tracker: tr}, PublicURL: "http://localhost"}
	vesper := httptest.NewServer(srv.Handler())
	t.Cleanup(vesper.Close)
	up := upstreamMCP(t)
	svc := srv.connectors()

	yes := true
	persona, err := (&personas.Service{Pool: pool}).Create(ctx, personas.Owner{WorkspaceID: ws, UserID: me.ID}, personas.NewInput{Name: "Bot", Connectors: &yes})
	if err != nil {
		t.Fatal(err)
	}
	conn, link, err := svc.Create(ctx, ws, me.ID, connectors.CreateInput{Name: "Up Stream", URL: up.URL, Auth: connectors.AuthNone})
	if err != nil || link != "" {
		t.Fatalf("create: %q %v", link, err)
	}
	if conn.Status != connectors.StatusConnected || conn.Slug != "up-stream" {
		t.Fatalf("connector = %s %s (%s)", conn.Status, conn.Slug, conn.LastError)
	}
	tools := connectors.Tools(conn)
	policy := map[string]string{}
	for _, x := range tools {
		policy[x.Name] = x.Policy
	}
	if policy["read_thing"] != "allow" || policy["write_thing"] != "ask" {
		t.Fatalf("defaults = %v", policy)
	}
	for i := range tools {
		if tools[i].Name == "drop_thing" {
			tools[i].Policy = "off"
		}
	}
	raw, _ := json.Marshal(tools)
	if _, err = q.UpdateConnector(ctx, store.UpdateConnectorParams{ID: conn.ID, WorkspaceID: ws, Revision: conn.Revision, Name: conn.Name, Tools: raw}); err != nil {
		t.Fatal(err)
	}

	chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{PersonaID: &persona.ID, Title: "C", Message: &runs.ChatMessageInput{Body: "hi"}})
	if err != nil {
		t.Fatal(err)
	}
	chat, _ = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
	token, _, err := agents.IssueToken(ctx, q, chat.AgentID, "run", "chat", chat.CurrentRunID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	dial := func() (*mcp.ClientSession, error) {
		c := mcp.NewClient(&mcp.Implementation{Name: "t", Version: "1"}, nil)
		return c.Connect(ctx, &mcp.StreamableClientTransport{Endpoint: vesper.URL + "/mcp/connectors/up-stream", DisableStandaloneSSE: true, MaxRetries: -1, HTTPClient: &http.Client{Transport: runBearer{token}}}, nil)
	}
	// Not granted: nothing to connect to.
	if s, err := dial(); err == nil {
		s.Close()
		t.Fatal("a persona without access connected")
	}
	if err := q.AddConnectorPersona(ctx, store.AddConnectorPersonaParams{ConnectorID: conn.ID, PersonaID: persona.ID}); err != nil {
		t.Fatal(err)
	}
	sess, err := dial()
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	listed, err := sess.ListTools(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(listed.Tools) != 2 {
		t.Fatalf("listed %d tools, want the two that aren't Off", len(listed.Tools))
	}
	text := func(r *mcp.CallToolResult) string { return r.Content[0].(*mcp.TextContent).Text }
	res, err := sess.CallTool(ctx, &mcp.CallToolParams{Name: "read_thing", Arguments: map[string]any{"text": "a"}})
	if err != nil || text(res) != "read_thing:a" {
		t.Fatalf("read: %q %v", text(res), err)
	}

	decide := func(want string) {
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			rows, _ := q.PendingConnectorApprovals(ctx, chat.ID)
			if len(rows) == 1 {
				body, _ := json.Marshal(map[string]string{"decision": want})
				res, err := http.Post(vesper.URL+"/api/v1/connector-approvals/"+rows[0].ID.String(), "application/json", bytes.NewReader(body))
				if err != nil || res.StatusCode != 204 {
					t.Errorf("decide: %v %v", res, err)
				}
				return
			}
			time.Sleep(50 * time.Millisecond)
		}
		t.Error("no approval appeared")
	}
	go decide("deny")
	res, err = sess.CallTool(ctx, &mcp.CallToolParams{Name: "write_thing", Arguments: map[string]any{"text": "b"}})
	if err != nil || !res.IsError || !strings.Contains(text(res), "denied") {
		t.Fatalf("denied write: %v %v", res, err)
	}
	go decide("allow")
	res, err = sess.CallTool(ctx, &mcp.CallToolParams{Name: "write_thing", Arguments: map[string]any{"text": "c"}})
	if err != nil || text(res) != "write_thing:c" {
		t.Fatalf("allowed write: %v %v", res, err)
	}

	// A persona with the capability proposes; the person's approval grants it.
	token2 := token
	body, _ := json.Marshal(map[string]string{"name": "Other", "url": up.URL, "auth": "none", "reason": "because"})
	req, _ := http.NewRequest("POST", vesper.URL+"/api/v1/agent/tools/propose_connector", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+token2)
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: *chat.CurrentRunID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("propose: %v %v", resp, err)
	}
	proposals, _ := q.ListConnectorProposals(ctx, chat.ID)
	if len(proposals) != 1 {
		t.Fatalf("proposals = %d", len(proposals))
	}
	other, _, err := svc.Create(ctx, ws, me.ID, connectors.CreateInput{Name: "Other", URL: up.URL, Auth: connectors.AuthNone, ProposalID: &proposals[0].ID})
	if err != nil {
		t.Fatal(err)
	}
	access, _ := q.ConnectorsForPersona(ctx, store.ConnectorsForPersonaParams{WorkspaceID: ws, UserID: me.ID, PersonaID: persona.ID})
	if len(access) != 2 || (access[0].ID != other.ID && access[1].ID != other.ID) {
		t.Fatalf("access after approval = %d", len(access))
	}
}

type runBearer struct{ token string }

func (b runBearer) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("Authorization", "Bearer "+b.token)
	return http.DefaultTransport.RoundTrip(r)
}

// A task overdue by many periods runs once, then waits for its next time.
func TestScheduledTaskCatchesUpOnce(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	rs := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: arts, ModelDiscovery: testChatModels}
	task, err := rs.CreateScheduledTask(ctx, ws, me.ID, runs.ScheduledTaskInput{Name: "Brief", Kind: "prompt", Instructions: "Summarise.", Enabled: true,
		Schedule: runs.Schedule{Frequency: "daily", AtTime: "08:00", Timezone: "UTC", MonthDay: 1, Weekdays: []int32{}}})
	if err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-72 * time.Hour)
	if err := q.AdvanceScheduledTask(ctx, store.AdvanceScheduledTaskParams{ID: task.ID, NextRunAt: &old}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := rs.RunDueScheduled(ctx); err != nil {
			t.Fatal(err)
		}
	}
	recent, err := q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if err != nil || len(recent) != 1 || recent[0].Trigger != "catchup" {
		t.Fatalf("runs = %+v, %v", recent, err)
	}
	if recent[0].ChatID == nil {
		t.Fatalf("no chat attached: %+v", recent[0])
	}
	task, _ = q.GetScheduledTask(ctx, store.GetScheduledTaskParams{ID: task.ID, WorkspaceID: ws, UserID: me.ID})
	if task.NextRunAt == nil || !task.NextRunAt.After(time.Now()) {
		t.Fatalf("next = %v", task.NextRunAt)
	}

	// When the reply ends, the run is done and lands in the Inbox.
	chat, _ := q.GetChatSession(ctx, store.GetChatSessionParams{ID: *recent[0].ChatID, WorkspaceID: ws})
	if !chat.Hidden {
		t.Fatal("a scheduled run's chat should stay out of the history")
	}
	if _, err := pool.Exec(ctx, `UPDATE chat_sessions SET state = 'idle' WHERE id = $1`, chat.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "assistant", BodyMd: "All clear.", ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
		t.Fatal(err)
	}
	if err := rs.SettleScheduled(ctx); err != nil {
		t.Fatal(err)
	}
	recent, _ = q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if recent[0].State != "done" || recent[0].Summary != "All clear." {
		t.Fatalf("settled = %+v", recent[0])
	}
}

// Scheduled tasks default to unlimited time and spend, but enforce optional
// per-task caps when configured.
func TestScheduledTaskUnlimitedAndConfiguredCaps(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	rs := &runs.Service{Pool: pool, Tracker: &tracker.Service{Pool: pool}, Artifacts: arts, ModelDiscovery: testChatModels}
	sched := runs.Schedule{Frequency: "daily", AtTime: "08:00", Timezone: "UTC", MonthDay: 1, Weekdays: []int32{}}

	// Invalid caps are rejected.
	zeroMin := int32(0)
	if _, err := rs.CreateScheduledTask(ctx, ws, me.ID, runs.ScheduledTaskInput{Name: "Bad min", Kind: "prompt", Instructions: "Hi.", Enabled: true, MaxMinutes: &zeroMin, Schedule: sched}); err == nil {
		t.Fatal("expected error for max_minutes = 0")
	}
	zeroCost := int64(0)
	if _, err := rs.CreateScheduledTask(ctx, ws, me.ID, runs.ScheduledTaskInput{Name: "Bad cost", Kind: "prompt", Instructions: "Hi.", Enabled: true, MaxCostMicros: &zeroCost, Schedule: sched}); err == nil {
		t.Fatal("expected error for max_cost_micros = 0")
	}

	// Default task has no time or cost cap: running past 15m and $1 keeps running.
	unlimited, err := rs.CreateScheduledTask(ctx, ws, me.ID, runs.ScheduledTaskInput{Name: "Unlimited", Kind: "prompt", Instructions: "Deep audit.", Enabled: true, Schedule: sched})
	if err != nil {
		t.Fatal(err)
	}
	if unlimited.MaxMinutes != nil || unlimited.MaxCostMicros != nil {
		t.Fatalf("expected nil caps by default, got min=%v cost=%v", unlimited.MaxMinutes, unlimited.MaxCostMicros)
	}
	if err := rs.RunScheduledTaskNow(ctx, ws, me.ID, unlimited.ID); err != nil {
		t.Fatal(err)
	}
	recent, err := q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if err != nil || len(recent) != 1 || recent[0].ChatID == nil {
		t.Fatalf("unlimited run = %+v, %v", recent, err)
	}
	chat, _ := q.GetChatSession(ctx, store.GetChatSessionParams{ID: *recent[0].ChatID, WorkspaceID: ws})
	if _, err := pool.Exec(ctx, `UPDATE scheduled_task_runs SET started_at = now() - interval '45 minutes' WHERE id = $1`, recent[0].ID); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `UPDATE runs SET cost_usd_micros = 5000000 WHERE id = $1`, *chat.CurrentRunID); err != nil {
		t.Fatal(err)
	}
	if err := rs.SettleScheduled(ctx); err != nil {
		t.Fatal(err)
	}
	recent, _ = q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if recent[0].State != "running" {
		t.Fatalf("unlimited run should still be running, got %+v", recent[0])
	}

	// Adding a cost cap stops the over-budget run on the next settle.
	capCost := int64(2_000_000)
	if _, err := rs.UpdateScheduledTask(ctx, ws, me.ID, unlimited.ID, runs.ScheduledTaskInput{Revision: unlimited.Revision, Name: unlimited.Name, Kind: unlimited.Kind, Instructions: unlimited.Instructions, Enabled: true, MaxCostMicros: &capCost, Schedule: sched}); err != nil {
		t.Fatal(err)
	}
	if err := rs.SettleScheduled(ctx); err != nil {
		t.Fatal(err)
	}
	recent, _ = q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if recent[0].State != "failed" || !strings.Contains(recent[0].Error, "cost limit") {
		t.Fatalf("expected cost limit failure, got %+v", recent[0])
	}

	// A time-capped task stops when elapsed time exceeds max_minutes.
	capMin := int32(10)
	timed, err := rs.CreateScheduledTask(ctx, ws, me.ID, runs.ScheduledTaskInput{Name: "Timed", Kind: "prompt", Instructions: "Quick check.", Enabled: true, MaxMinutes: &capMin, Schedule: sched})
	if err != nil {
		t.Fatal(err)
	}
	if err := rs.RunScheduledTaskNow(ctx, ws, me.ID, timed.ID); err != nil {
		t.Fatal(err)
	}
	recent, _ = q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if _, err := pool.Exec(ctx, `UPDATE scheduled_task_runs SET started_at = now() - interval '15 minutes' WHERE id = $1`, recent[0].ID); err != nil {
		t.Fatal(err)
	}
	if err := rs.SettleScheduled(ctx); err != nil {
		t.Fatal(err)
	}
	recent, _ = q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if recent[0].State != "failed" || !strings.Contains(recent[0].Error, "time limit") {
		t.Fatalf("expected time limit failure, got %+v", recent[0])
	}
}

// A scheduled task attached to a project launches its hidden chat in that
// project's space so the run inherits space repositories and context.
func TestScheduledTaskLaunchesInProjectSpace(t *testing.T) {
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

	pay, err := q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: "PAY"})
	if err != nil || pay.SpaceID == nil {
		t.Fatalf("seeded PAY project/space: %+v, %v", pay, err)
	}
	const spaceRepo = "https://github.com/acme/payments.git"
	if _, err := q.AddChatSpaceRepository(ctx, store.AddChatSpaceRepositoryParams{SpaceID: *pay.SpaceID, RepoUrl: spaceRepo}); err != nil {
		t.Fatal(err)
	}
	coder, err := q.CreatePersona(ctx, store.CreatePersonaParams{WorkspaceID: ws, UserID: me.ID, Name: "Coder", Tone: "neutral", Color: "#22aa66", CanCode: true, Repos: []string{}})
	if err != nil {
		t.Fatal(err)
	}

	sched := runs.Schedule{Frequency: "weekly", Weekdays: []int32{0}, MonthDay: 1, AtTime: "08:00", Timezone: "America/Los_Angeles"}
	task, err := rs.CreateScheduledTask(ctx, ws, me.ID, runs.ScheduledTaskInput{
		Name: "Space audit", Kind: "prompt", Instructions: "Check deps.", PersonaID: &coder.ID, Project: pay.Key, Enabled: true, Schedule: sched,
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := rs.RunScheduledTaskNow(ctx, ws, me.ID, task.ID); err != nil {
		t.Fatal(err)
	}
	recent, err := q.RecentScheduledRuns(ctx, store.RecentScheduledRunsParams{WorkspaceID: ws, UserID: me.ID})
	if err != nil || len(recent) == 0 || recent[0].ChatID == nil {
		t.Fatalf("recent scheduled runs: %+v, %v", recent, err)
	}
	chat, err := q.GetChatSession(ctx, store.GetChatSessionParams{ID: *recent[0].ChatID, WorkspaceID: ws})
	if err != nil {
		t.Fatal(err)
	}
	if chat.ProjectID == nil || *chat.ProjectID != pay.ID {
		t.Fatalf("chat.ProjectID = %v, want %v", chat.ProjectID, pay.ID)
	}
	if chat.SpaceID == nil || *chat.SpaceID != *pay.SpaceID {
		t.Fatalf("chat.SpaceID = %v, want %v", chat.SpaceID, *pay.SpaceID)
	}
	repos, err := q.ChatRepositories(ctx, chat.ID)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, r := range repos {
		if r.RepoUrl == spaceRepo {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("expected space repo %s attached to scheduled chat, got %+v", spaceRepo, repos)
	}
}

package runner_test

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/httpapi"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

type env struct {
	t      *testing.T
	ctx    context.Context
	pool   *pgxpool.Pool
	q      *store.Queries
	ws     uuid.UUID
	me     store.User
	runs   *runs.Service
	tr     *tracker.Service
	runner *runner.Runner
	dir    string
	atlas  store.Agent
}

func setup(t *testing.T) env { return setupWith(t, nil) }

// backendFor builds a backend given the fake harness binary path and the
// test server's URL; nil means the fake backend.
type backendFor func(t *testing.T, dir, bin, url string) (runner.Backend, string)

func setupWith(t *testing.T, mk backendFor) env {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	// No network in tests: projects start from an empty repository.
	if _, err := pool.Exec(ctx, "UPDATE projects SET repo_url = NULL"); err != nil {
		t.Fatal(err)
	}
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, _ := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	sec := &secrets.Service{Q: q, Box: box}
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Secrets: sec, Tracker: tr, Artifacts: arts, Poll: 20 * time.Millisecond}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := &httpapi.Server{Version: "test", Pool: pool, Q: q, Tracker: tr, Artifacts: arts, Secrets: sec,
		Agents: &agents.Service{Pool: pool}, Runs: rs, Wiki: &wiki.Service{Pool: pool, Artifacts: arts, Tracker: tr}, Log: logger}
	ts := httptest.NewUnstartedServer(srv.Handler())
	if mk != nil {
		// Containers call in as host.docker.internal; the MCP server refuses
		// non-local Host headers on a loopback listener (DNS rebinding).
		l, err := net.Listen("tcp", "0.0.0.0:0")
		if err != nil {
			t.Fatal(err)
		}
		ts.Listener.Close()
		ts.Listener = l
	}
	ts.Start()
	t.Cleanup(ts.Close)

	dir := t.TempDir()
	bin := filepath.Join(dir, "fake-claude")
	built := hostHarness
	if mk != nil { // the binary runs inside a Linux container
		built = linuxHarness
	}
	src, err := built()
	if err != nil {
		t.Fatal(err)
	}
	if err := linkOrCopy(src, bin); err != nil {
		t.Fatal(err)
	}
	// Belt and braces: only the fake can be found as claude or codex, so a
	// bug in binary substitution can't reach a real, logged-in CLI.
	for _, name := range []string{"claude", "codex", "agy"} {
		if err := os.Symlink(bin, filepath.Join(dir, name)); err != nil {
			t.Fatal(err)
		}
	}
	git, err := exec.LookPath("git")
	if err != nil {
		t.Skip("git not installed")
	}
	// Only git itself is linked in; its directory may hold real CLIs too.
	if err := os.Symlink(git, filepath.Join(dir, "git")); err != nil {
		t.Fatal(err)
	}
	safe := dir + ":/usr/bin:/bin"
	for _, p := range filepath.SplitList(safe)[1:] {
		for _, name := range []string{"claude", "codex", "agy"} {
			if _, err := os.Stat(filepath.Join(p, name)); err == nil {
				t.Fatalf("a real %s is on the test PATH (%s); refusing to run", name, p)
			}
		}
	}
	t.Setenv("PATH", safe)
	var backend runner.Backend = &runner.Fake{Dir: filepath.Join(dir, "work"), Bins: map[string]string{"claude": bin, "codex": bin, "agy": filepath.Join(dir, "agy")}}
	mcpURL := ts.URL + "/mcp"
	if mk != nil {
		backend, mcpURL = mk(t, dir, bin, ts.URL)
	}
	r := &runner.Runner{
		Cfg:     runner.Config{ID: "test-runner", MaxConcurrent: 2, MCPURL: mcpURL, Grace: 3 * time.Second, Version: "test"},
		Pool:    pool,
		Backend: backend,
		Secrets: sec, Tracker: tr, Log: logger,
	}
	// Let in-flight turns finish before their workspaces are removed: a turn
	// still writing there fails TempDir's cleanup.
	t.Cleanup(func() {
		done := make(chan struct{})
		go func() { r.Wait(); close(done) }()
		select {
		case <-done:
		case <-time.After(30 * time.Second):
			t.Error("runner work still running 30s after the test ended")
		}
	})
	atlas, _ := q.GetAgentByHandle(ctx, store.GetAgentByHandleParams{WorkspaceID: ws, Handle: "atlas"})
	return env{t, ctx, pool, q, ws, me, rs, tr, r, dir, atlas}
}

// fakeHarnessDir holds the fake harness, built once per test binary for each
// platform; TestMain removes it.
var fakeHarnessDir string

var (
	hostHarness  = sync.OnceValues(func() (string, error) { return buildFakeHarness("host") })
	linuxHarness = sync.OnceValues(func() (string, error) { return buildFakeHarness("linux") })
)

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "vesper-fake-harness-")
	if err != nil {
		panic(err)
	}
	fakeHarnessDir = dir
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}

func buildFakeHarness(platform string) (string, error) {
	bin := filepath.Join(fakeHarnessDir, "fake-harness-"+platform)
	build := exec.Command("go", "build", "-o", bin, "github.com/liamphmurphy/vesper/server/cmd/fake-harness")
	if platform == "linux" {
		build.Env = append(os.Environ(), "GOOS=linux", "CGO_ENABLED=0")
	}
	if out, err := build.CombinedOutput(); err != nil {
		return "", fmt.Errorf("build fake harness: %v\n%s", err, out)
	}
	return bin, nil
}

// linkOrCopy puts the shared fake harness at dst, hard-linked when it can be.
func linkOrCopy(src, dst string) error {
	if os.Link(src, dst) == nil {
		return nil
	}
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

func (e env) run(key string) store.Run {
	e.t.Helper()
	tk, err := tracker.Get(e.ctx, e.q, e.ws, key)
	if err != nil {
		e.t.Fatal(err)
	}
	r, err := e.q.LatestRunForTicket(e.ctx, &tk.ID)
	if err != nil {
		e.t.Fatal(err)
	}
	return r
}

// until ticks the runner until cond holds.
func (e env) until(what string, cond func() bool) {
	e.t.Helper()
	for i := 0; i < 300; i++ {
		e.runner.Tick(e.ctx)
		e.runner.Wait()
		if cond() {
			return
		}
		time.Sleep(30 * time.Millisecond)
	}
	rows, _ := e.pool.Query(e.ctx, "SELECT t.key, r.state, coalesce(r.outcome,''), r.id FROM runs r JOIN tickets t ON t.id = r.ticket_id WHERE r.mode = 'managed'")
	for rows.Next() {
		var k, st, out string
		var id uuid.UUID
		_ = rows.Scan(&k, &st, &out, &id)
		e.t.Logf("%s %s %q events: %s", k, st, out, e.eventTypes(id))
	}
	rows.Close()
	e.t.Fatalf("timed out waiting for %s", what)
}

func (e env) state(key string) func() bool {
	parts := strings.Split(key, "=")
	return func() bool { return e.run(parts[0]).State == parts[1] }
}

func (e env) assign(key string) {
	e.t.Helper()
	if _, err := e.tr.Update(e.ctx, e.ws, tracker.UserActor(e.me.ID), key, tracker.Patch{AssigneeAgentID: tracker.SetTo(e.atlas.ID)}); err != nil {
		e.t.Fatal(err)
	}
}

func (e env) dispatch(key string) {
	e.t.Helper()
	if _, err := e.runs.Dispatch(e.ctx, e.ws, e.me.ID, []string{key}); err != nil {
		e.t.Fatal(err)
	}
}

func (e env) eventTypes(runID uuid.UUID) string {
	evs, _ := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: runID, Seq: 0})
	var out []string
	for _, ev := range evs {
		var p map[string]any
		_ = json.Unmarshal(ev.Payload, &p)
		s := ev.Type
		if st, ok := p["state"].(string); ok {
			s += ":" + st
		}
		if tool, ok := p["tool"].(string); ok {
			s += ":" + strings.TrimPrefix(tool, "mcp__lazyagents__")
		}
		out = append(out, s)
	}
	return strings.Join(out, " ")
}

func TestApprovalRoundTrip(t *testing.T) {
	e := setup(t)
	e.dispatch("PAY-214")
	if r := e.run("PAY-214"); r.State != "queued" || r.Mode != "managed" {
		t.Fatalf("dispatched run %+v", r)
	}
	// Dispatching twice is refused; unmanaged sessions can't take it over.
	if _, err := e.runs.Dispatch(e.ctx, e.ws, e.me.ID, []string{"PAY-214"}); err == nil {
		t.Fatal("dispatched twice")
	}
	if _, err := e.runs.Claim(e.ctx, agents.Caller{Agent: e.atlas, Kind: "unmanaged"}, "PAY-214"); err == nil {
		t.Fatal("an unmanaged session claimed a dispatched ticket")
	}

	e.until("waiting for approval", e.state("PAY-214=waiting"))
	run := e.run("PAY-214")
	if run.HarnessSessionID == nil || run.CostUsdMicros != 12500 || run.ToolCalls != 3 || *run.WaitReason != "approval" {
		t.Fatalf("after turn 1: session=%v cost=%d tools=%d wait=%v", run.HarnessSessionID, run.CostUsdMicros, run.ToolCalls, deref(run.WaitReason))
	}
	evs := e.eventTypes(run.ID)
	if strings.Contains(evs, "ToolSearch") {
		t.Fatal("a real harness ran instead of the fake")
	}
	// Only secrets are redacted from events, not ordinary values like the key.
	raw, _ := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
	var all strings.Builder
	for _, ev := range raw {
		all.Write(ev.Payload)
	}
	if strings.Contains(all.String(), "[redacted]") || !strings.Contains(all.String(), `"PAY-214"`) {
		t.Fatal("event payloads were over-redacted")
	}
	for _, want := range []string{"lifecycle:queued", "lifecycle:workspace_ready", "lifecycle:running", "lifecycle:turn_started",
		"lifecycle:harness_started", "tool_call:claim_ticket", "tool_result:claim_ticket", "tool_call:request_approval", "usage", "lifecycle:turn_ended"} {
		if !strings.Contains(evs, want) {
			t.Errorf("missing %s in %s", want, evs)
		}
	}
	tk, _ := tracker.Get(e.ctx, e.q, e.ws, "PAY-214")
	if tk.Status != "in_progress" || tk.Branch == nil || !strings.HasPrefix(*tk.Branch, "atlas/pay-214-") {
		t.Fatalf("ticket %s %v", tk.Status, tk.Branch)
	}
	// The workspace is a git checkout on the branch, with our files excluded.
	wsDir := filepath.Join(e.dir, "work", "runs", run.ID.String(), "workspace")
	agentsMD, err := os.ReadFile(filepath.Join(wsDir, "AGENTS.md"))
	if err != nil || !strings.Contains(string(agentsMD), "Vesper run: PAY-214") || !strings.Contains(string(agentsMD), ".lazyagents/context/") {
		t.Fatalf("AGENTS.md: %v\n%s", err, agentsMD)
	}
	if out, _ := exec.Command("git", "-C", wsDir, "status", "--porcelain").CombinedOutput(); strings.TrimSpace(string(out)) != "" {
		t.Fatalf("workspace not clean: %s", out)
	}
	// Context files counted as reads at the start.
	n := int32(12)
	adr, _ := e.q.GetADRByNumber(e.ctx, store.GetADRByNumberParams{WorkspaceID: e.ws, Number: &n, Viewer: pageview.From(e.ctx).UserID})
	readers, _ := e.q.ListArtifactReaders(e.ctx, adr.ID)
	if len(readers) == 0 {
		t.Fatal("context file reads not recorded")
	}

	// A person approves: the next turn resumes the same session and finishes.
	aps, _ := e.q.PendingApprovalsForTicket(e.ctx, tk.ID)
	if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, aps[0].ID, true, "go"); err != nil {
		t.Fatal(err)
	}
	e.until("completed", e.state("PAY-214=completed"))
	turns, _ := e.q.ListTurns(e.ctx, run.ID)
	if len(turns) != 2 || turns[1].Trigger != "approval" || turns[1].Status != "done" || *turns[1].ExitCode != 0 {
		t.Fatalf("turns %+v", turns)
	}
	tk, _ = tracker.Get(e.ctx, e.q, e.ws, "PAY-214")
	if tk.Status != "in_review" {
		t.Fatalf("ticket %s", tk.Status)
	}
	if _, err := os.Stat(wsDir); !os.IsNotExist(err) {
		t.Fatal("workspace not removed")
	}
	toks, _ := e.q.ListAgentTokens(e.ctx, e.atlas.ID)
	for _, tok := range toks {
		if tok.Kind == "run" && tok.RevokedAt == nil {
			t.Fatal("run token left unrevoked")
		}
	}
}

func TestIdleNudgeThenPerson(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "idle")
	t.Setenv("FAKE_HARNESS_RESUME", "idle")
	e.dispatch("PAY-224")
	e.until("handed to a person", func() bool {
		r := e.run("PAY-224")
		return r.State == "waiting" && r.WaitReason != nil && *r.WaitReason == "human_reply"
	})
	turns, _ := e.q.ListTurns(e.ctx, e.run("PAY-224").ID)
	if len(turns) != 2 || turns[1].InputMessage != runner.IdleNudge {
		t.Fatalf("turns %+v", turns)
	}
	// An @mention resumes it; this time the agent finishes.
	t.Setenv("FAKE_HARNESS_RESUME", "")
	if err := e.runs.OnHumanComment(e.ctx, e.ws, "PAY-224", "@atlas please wrap up"); err != nil {
		t.Fatal(err)
	}
	e.until("completed", e.state("PAY-224=completed"))
}

func TestCrashFailsRun(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "crash")
	e.dispatch("PAY-224")
	e.until("failed", e.state("PAY-224=failed"))
	r := e.run("PAY-224")
	if r.Outcome == nil || !strings.Contains(*r.Outcome, "API Error: overloaded") {
		t.Fatalf("outcome %q", deref(r.Outcome))
	}
	// A failed run keeps its checkout (unpushed work), even after a sweep.
	e.runner.Sweep(e.ctx)
	if _, err := os.Stat(e.runner.Backend.WorkspaceDir(r.ID.String())); err != nil {
		t.Fatalf("failed run's workspace was removed: %v", err)
	}
	tk, _ := tracker.Get(e.ctx, e.q, e.ws, "PAY-224")
	evs, _ := e.q.ListTicketActivity(e.ctx, &tk.ID)
	if evs[len(evs)-1].Verb != runs.VerbRunFailed {
		t.Fatalf("last activity %s", evs[len(evs)-1].Verb)
	}
	// A failed run can be dispatched again.
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	e.dispatch("PAY-224")
	e.until("completed", e.state("PAY-224=completed"))
}

func TestRunRecordsContextTokens(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	t.Setenv("FAKE_HARNESS_CONTEXT_TOKENS", "180000")
	e.dispatch("PAY-224")
	e.until("completed", e.state("PAY-224=completed"))
	if r := e.run("PAY-224"); r.ContextTokens != 180000 {
		t.Fatalf("context_tokens %d, want 180000", r.ContextTokens)
	}
	turns, _ := e.q.ListTurns(e.ctx, e.run("PAY-224").ID)
	var u harness.Usage
	if len(turns) == 0 || json.Unmarshal(turns[0].Usage, &u) != nil || u.ContextTokens != 180000 || u.OtherOutputBytes == 0 {
		t.Fatalf("turn usage %+v", u)
	}
}

func TestPauseResumeAndGuards(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "slow")
	e.dispatch("PAY-224")
	run := e.run("PAY-224")
	// Tick in the background while the slow turn runs.
	stop := make(chan struct{})
	go func() {
		for {
			select {
			case <-stop:
				return
			default:
				e.runner.Tick(e.ctx)
				time.Sleep(30 * time.Millisecond)
			}
		}
	}()
	deadline := time.Now().Add(20 * time.Second)
	for !strings.Contains(e.eventTypes(run.ID), "tool_result:claim_ticket") {
		if time.Now().After(deadline) {
			t.Fatal("slow turn never started")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, run.ID, "pause"); err != nil {
		t.Fatal(err)
	}
	for {
		turns, _ := e.q.ListTurns(e.ctx, run.ID)
		if turns[0].Status == "done" {
			if *turns[0].ExitCode != 130 {
				t.Fatalf("paused turn exit %d", *turns[0].ExitCode)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("pause didn't interrupt the turn")
		}
		time.Sleep(50 * time.Millisecond)
	}
	close(stop)
	e.runner.Wait()
	if r := e.run("PAY-224"); r.State != "paused" {
		t.Fatalf("state %s", r.State)
	}
	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, run.ID, "resume"); err != nil {
		t.Fatal(err)
	}
	e.until("completed after resume", e.state("PAY-224=completed"))

	// The turn guard: a run frozen with max_turns 1 is stopped before the
	// nudge turn would run.
	t.Setenv("FAKE_HARNESS_MODE", "idle")
	e.dispatch("PAY-224")
	next := e.run("PAY-224")
	if _, err := e.pool.Exec(e.ctx, `UPDATE runs SET resolved_spec = jsonb_set(resolved_spec, '{budget,max_turns}', '1') WHERE id = $1`, next.ID); err != nil {
		t.Fatal(err)
	}
	e.until("stopped by the turn guard", e.state("PAY-224=cancelled"))
	if r := e.run("PAY-224"); r.Outcome == nil || !strings.Contains(*r.Outcome, "1-turn limit") {
		t.Fatalf("outcome %v", r.Outcome)
	}
}

func deref(s *string) string {
	if s == nil {
		return "<nil>"
	}
	return *s
}

// The exit criterion's second half (docs/dev/plan.md §9 Phase 5): a project override
// switches the agent to Codex, and the same approval flow works there.
func TestCodexOverride(t *testing.T) {
	e := setup(t)
	svc := &agents.Service{Pool: e.pool}
	p, _ := e.q.GetProjectByKey(e.ctx, store.GetProjectByKeyParams{WorkspaceID: e.ws, Key: "PAY"})
	row, err := e.q.GetOverride(e.ctx, store.GetOverrideParams{AgentID: e.atlas.ID, ProjectID: p.ID})
	if err != nil {
		t.Fatal(err)
	}
	pay, err := agents.DecodeOverride(row.Spec)
	if err != nil {
		t.Fatal(err)
	}
	pay.Harness = "codex"
	pay.Model = "gpt-5-codex"
	if err := svc.SetOverride(e.ctx, e.ws, e.me.ID, "atlas", "PAY", pay); err != nil {
		t.Fatal(err)
	}
	e.dispatch("PAY-214")
	if r := e.run("PAY-214"); r.Harness != "codex" {
		t.Fatalf("harness %s", r.Harness)
	}
	e.until("waiting for approval", e.state("PAY-214=waiting"))
	run := e.run("PAY-214")
	evs := e.eventTypes(run.ID)
	if !strings.Contains(evs, "tool_call:request_approval") || run.HarnessSessionID == nil || run.CostSource == nil || *run.CostSource != "computed" {
		t.Fatalf("codex turn: %s cost=%v", evs, run.CostSource)
	}
	if run.ContextTokens <= 0 {
		t.Fatalf("codex context_tokens %d, want > 0", run.ContextTokens)
	}
	tk, _ := tracker.Get(e.ctx, e.q, e.ws, "PAY-214")
	aps, _ := e.q.PendingApprovalsForTicket(e.ctx, tk.ID)
	if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, aps[0].ID, false, "not yet"); err != nil {
		t.Fatal(err)
	}
	e.until("completed after the denial", e.state("PAY-214=completed"))
	tk, _ = tracker.Get(e.ctx, e.q, e.ws, "PAY-214")
	if tk.Status != "todo" { // the fake hands a denied ticket back
		t.Fatalf("status %s", tk.Status)
	}
}

// Planning uses the same guarded fake binaries as execution tests. It has no
// ticket, skips repo/setup work, and submits through the real MCP transport.
func TestPlanningRun(t *testing.T) {
	for _, harness := range []string{"claude-code", "codex"} {
		t.Run(harness, func(t *testing.T) {
			e := setup(t)
			t.Setenv("FAKE_HARNESS_MODE", "planning")
			svc := &agents.Service{Pool: e.pool}
			if err := svc.SetOverride(e.ctx, e.ws, e.me.ID, "atlas", "PAY", agentdef.Override{Harness: harness, Setup: []string{"exit 79"}}); err != nil {
				t.Fatal(err)
			}
			if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url='https://invalid.example/planning-must-not-clone.git' WHERE key='PAY'"); err != nil {
				t.Fatal(err)
			}
			plan, err := e.runs.StartPlanning(e.ctx, e.ws, e.me.ID, runs.PlanningInput{Project: "PAY", AgentID: e.atlas.ID, Goal: "Plan safely"})
			if err != nil {
				t.Fatal(err)
			}
			sec := e.runner.Secrets.(*secrets.Service)
			for _, name := range []string{"git:pat", "db:staging", "harness:anthropic", "harness:openai"} {
				if _, err := sec.Set(e.ctx, e.ws, e.me.ID, secrets.SetInput{Name: name, Value: "fake-test-value"}); err != nil {
					t.Fatal(err)
				}
			}
			frozen, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: plan.RunID, WorkspaceID: e.ws})
			if err != nil {
				t.Fatal(err)
			}
			resolved, _ := runs.Spec(frozen)
			project, _ := e.q.GetProjectByKey(e.ctx, store.GetProjectByKeyParams{WorkspaceID: e.ws, Key: "PAY"})
			decisions, err := runner.PlanSecrets(e.ctx, e.q, e.ws, &project.ID, resolved)
			if err != nil {
				t.Fatal(err)
			}
			for _, decision := range decisions {
				if decision.Injected && !strings.HasPrefix(decision.Name, "harness:") {
					t.Fatalf("planning injected write credential %s", decision.Name)
				}
			}
			e.until("planning submitted", func() bool {
				p, err := e.q.GetPlanningSession(e.ctx, store.GetPlanningSessionParams{ID: plan.ID, WorkspaceID: e.ws})
				if err != nil {
					t.Fatal(err)
				}
				if p.State != "review" {
					run, _ := e.q.GetRun(e.ctx, store.GetRunParams{ID: p.RunID, WorkspaceID: e.ws})
					if run.State == "failed" {
						events, _ := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: run.ID})
						raw, _ := json.Marshal(events)
						t.Fatalf("planning failed: %v; events %s", deref(run.Outcome), raw)
					}
				}
				return p.State == "review"
			})
			run, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: plan.RunID, WorkspaceID: e.ws})
			if err != nil {
				t.Fatal(err)
			}
			if run.State != "completed" || run.TicketID != nil || run.ToolCalls != 3 || run.HarnessSessionID == nil {
				t.Fatalf("planning run %+v; events %s", run, e.eventTypes(run.ID))
			}
			p, _ := e.q.GetPlanningSession(e.ctx, store.GetPlanningSessionParams{ID: plan.ID, WorkspaceID: e.ws})
			var proposals []runs.Proposal
			if err := json.Unmarshal(p.Proposals, &proposals); err != nil {
				t.Fatal(err)
			}
			if len(proposals) != 1 || proposals[0].AgentID == nil || *proposals[0].AgentID != e.atlas.ID {
				t.Fatalf("MCP proposal corrupted: %s", p.Proposals)
			}
			if strings.Contains(e.eventTypes(run.ID), "ToolSearch") {
				t.Fatal("a real CLI ran")
			}
			if _, err := os.Stat(e.runner.Backend.WorkspaceDir(run.ID.String())); !os.IsNotExist(err) {
				t.Fatal("planning workspace was not cleaned up")
			}
			toks, _ := e.q.ListAgentTokens(e.ctx, e.atlas.ID)
			for _, tok := range toks {
				if tok.Kind == "run" && tok.RevokedAt == nil {
					t.Fatal("planning token left active")
				}
			}
		})
	}
}

func TestQueuedRunRechecksDependencies(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	blocker, err := e.tr.Create(e.ctx, e.ws, tracker.UserActor(e.me.ID), tracker.NewTicket{ProjectKey: "PAY", Title: "Prerequisite", Status: "done"})
	if err != nil {
		t.Fatal(err)
	}
	tk, err := tracker.Get(e.ctx, e.q, e.ws, "PAY-224")
	if err != nil {
		t.Fatal(err)
	}
	if err := e.tr.SetDependencies(e.ctx, e.ws, tracker.UserActor(e.me.ID), tk.Key, tk.DependencyRevision, []string{blocker.Key}); err != nil {
		t.Fatal(err)
	}
	e.dispatch(tk.Key)
	todo := "todo"
	if _, err := e.tr.Update(e.ctx, e.ws, tracker.UserActor(e.me.ID), blocker.Key, tracker.Patch{Status: &todo}); err != nil {
		t.Fatal(err)
	}
	// The run stays queued while its blocker is reopened, and starts once Done.
	time.Sleep(2 * time.Second)
	run := e.run(tk.Key)
	if run.State != "queued" || run.HarnessSessionID != nil || run.ToolCalls != 0 || strings.Contains(e.eventTypes(run.ID), "harness_started") {
		t.Fatalf("blocked run started: %+v", run)
	}
	done := "done"
	if _, err := e.tr.Update(e.ctx, e.ws, tracker.UserActor(e.me.ID), blocker.Key, tracker.Patch{Status: &done}); err != nil {
		t.Fatal(err)
	}
	e.until("queued run starts after the blocker is done", e.state(tk.Key+"=completed"))
}

func TestApprovedRepositoryAndBaseBranchAreFrozen(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "idle")
	origin := filepath.Join(e.dir, "origin")
	if err := os.MkdirAll(origin, 0700); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", origin}, args...)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
		return string(out)
	}
	git("init", "--quiet", "-b", "main")
	git("config", "user.name", "Test")
	git("config", "user.email", "test@example.com")
	if err := os.WriteFile(filepath.Join(origin, "main.txt"), []byte("main"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "--quiet", "-m", "main")
	git("checkout", "--quiet", "-b", "develop")
	if err := os.WriteFile(filepath.Join(origin, "develop.txt"), []byte("approved develop source"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "--quiet", "-m", "develop")
	git("checkout", "--quiet", "main")
	if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url=$1,default_branch='develop' WHERE key='PAY'", origin); err != nil {
		t.Fatal(err)
	}
	e.dispatch("PAY-224")
	if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url='https://invalid.example/must-not-clone.git',default_branch='main' WHERE key='PAY'"); err != nil {
		t.Fatal(err)
	}
	e.until("approved workspace ready", e.state("PAY-224=running"))
	run := e.run("PAY-224")
	root := e.runner.Backend.WorkspaceDir(run.ID.String())
	// The dispatcher's primary profile address overrides machine defaults and
	// the agent's synthetic identity when preparing a ticket checkout.
	cmd := exec.Command("git", "-C", root, "config", "user.email")
	out, err := cmd.CombinedOutput()
	if err != nil || strings.TrimSpace(string(out)) != e.me.Email {
		t.Fatalf("ticket commit author: %q %v", out, err)
	}
	content, err := os.ReadFile(filepath.Join(root, "develop.txt"))
	if err != nil || string(content) != "approved develop source" {
		t.Fatalf("did not clone approved base: %q %v", content, err)
	}
	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, run.ID, "cancel"); err != nil {
		t.Fatal(err)
	}
	e.runner.Sweep(e.ctx)
	// A cancelled run keeps its checkout; only completed runs are cleaned up.
	if _, err := os.Stat(root); err != nil {
		t.Fatalf("cancelled run's workspace was removed: %v", err)
	}
}

func TestDelegatedRunWorksInWorktreeOfParentWorkspace(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "delegate")
	report := "## Findings\n\n- child.txt:1 written as asked"
	t.Setenv("FAKE_HARNESS_CHILD_REPORT", report)
	e.dispatch("PAY-214")
	e.until("completed", e.state("PAY-214=completed"))
	parent := e.run("PAY-214")
	if parent.ParentRunID != nil || !strings.Contains(deref(parent.Outcome), "child.txt present=true") {
		t.Fatalf("parent outcome %q", deref(parent.Outcome))
	}
	kids, _ := e.q.ChildRuns(e.ctx, &parent.ID)
	if len(kids) != 1 || kids[0].State != "completed" || deref(kids[0].Outcome) != "Wrote child.txt" || kids[0].WorkspaceVolume != nil {
		t.Fatalf("children %+v", kids)
	}
	turns, _ := e.q.ListTurns(e.ctx, parent.ID)
	if len(turns) != 2 || turns[1].Trigger != "delegation" {
		t.Fatalf("parent turns %+v", turns)
	}
	// The child's report reaches the parent through the real MCP path.
	if deref(kids[0].Report) != report || !strings.Contains(turns[1].InputMessage, "Wrote child.txt\n\n#### Report\n\n"+report) {
		t.Fatalf("report %q; wake message:\n%s", deref(kids[0].Report), turns[1].InputMessage)
	}
	// The child worked in its own worktree and branch; its commit was merged into the parent's.
	var ct runs.Contract
	var ck runs.Checks
	if json.Unmarshal(kids[0].Contract, &ct) != nil || json.Unmarshal(kids[0].Checks, &ck) != nil ||
		ct.Worktree != ".lazyagents/worktrees/"+kids[0].ID.String() || !ck.Merged || ck.Branch != ct.Branch {
		t.Fatalf("contract %s checks %s", kids[0].Contract, kids[0].Checks)
	}
	tk, _ := tracker.Get(e.ctx, e.q, e.ws, "PAY-214")
	if tk.Status != "in_review" {
		t.Fatalf("ticket %s", tk.Status)
	}
	// The shared workspace goes once, with the parent.
	if _, err := os.Stat(filepath.Join(e.dir, "work", "runs", parent.ID.String(), "workspace")); !os.IsNotExist(err) {
		t.Fatal("workspace not removed")
	}
	if _, err := os.Stat(filepath.Join(e.dir, "work", "runs", kids[0].ID.String())); !os.IsNotExist(err) {
		t.Fatal("the delegated run got its own workspace")
	}
}

func TestDelegationChecksRunBeforeParentResumes(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "delegate_contract")
	e.dispatch("PAY-214")
	e.until("completed", e.state("PAY-214=completed"))
	parent := e.run("PAY-214")
	// child.txt is outside the docs/ boundary, so the checks fail, but the test command passes.
	if want := "checks failed=true outside=true test_passed=true criteria=true"; deref(parent.Outcome) != want {
		kk, _ := e.q.ChildRuns(e.ctx, &parent.ID)
		t.Fatalf("parent outcome %q, want %q; checks %s", deref(parent.Outcome), want, kk[0].Checks)
	}
	kids, _ := e.q.ChildRuns(e.ctx, &parent.ID)
	if len(kids) != 1 {
		t.Fatalf("children %+v", kids)
	}
	var contract runs.Contract
	if err := json.Unmarshal(kids[0].Contract, &contract); err != nil || contract.BaseSHA == "" || contract.TestCommand != "test -f child.txt" || len(contract.AllowedPaths) != 1 {
		t.Fatalf("contract %s (%v)", kids[0].Contract, err)
	}
	var checks runs.Checks
	if err := json.Unmarshal(kids[0].Checks, &checks); err != nil || !checks.Ran || checks.Passed || len(checks.OutOfBounds) != 1 || checks.TestExit == nil || *checks.TestExit != 0 {
		t.Fatalf("checks %s (%v)", kids[0].Checks, err)
	}
	rows, err := e.q.DelegationEfficiency(e.ctx, e.ws)
	if err != nil || len(rows) != 1 || rows[0].Delegations != 1 || rows[0].Checked != 1 || rows[0].FirstPass != 0 || rows[0].RepairLoops != 0 {
		t.Fatalf("efficiency %+v (%v)", rows, err)
	}
	// Phase timings: the parent was set up and ran the harness; the child ran the harness,
	// was baselined (setup) and was checked.
	if parent.SetupMs == nil || parent.HarnessMs == nil || *parent.HarnessMs <= 0 {
		t.Fatalf("parent timings setup=%v harness=%v", parent.SetupMs, parent.HarnessMs)
	}
	k := kids[0]
	if k.SetupMs == nil || k.HarnessMs == nil || k.ChecksMs == nil || *k.HarnessMs <= 0 {
		t.Fatalf("child timings setup=%v harness=%v checks=%v", k.SetupMs, k.HarnessMs, k.ChecksMs)
	}
	if rows[0].AvgHarnessSeconds <= 0 {
		t.Fatalf("avg harness seconds %v", rows[0].AvgHarnessSeconds)
	}
}

func TestUsageFallbackPreservesWorkspace(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	e.dispatch("PAY-214")
	run := e.run("PAY-214")
	var spec agentdef.Resolved
	if err := json.Unmarshal(run.ResolvedSpec, &spec); err != nil {
		t.Fatal(err)
	}
	spec.Fallbacks = []agentdef.Fallback{{Harness: agentdef.HarnessCodex, Model: "test-fallback"}}
	raw, _ := json.Marshal(spec)
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
		t.Fatal(err)
	}
	history, _ := json.Marshal(map[string]any{"tool": "get_ticket", "output": "Preserve this verified tool outcome across harnesses"})
	if err := e.q.AddRunEvent(e.ctx, store.AddRunEventParams{RunID: run.ID, Type: "tool_result", Payload: history}); err != nil {
		t.Fatal(err)
	}
	e.until("fallback completed", e.state("PAY-214=completed"))
	run = e.run("PAY-214")
	if run.Harness != "codex" || run.Model != "test-fallback" {
		t.Fatalf("target: %s %s", run.Harness, run.Model)
	}
	if run.CostSource == nil || *run.CostSource != "partial" {
		t.Fatalf("mixed priced/unpriced turns must remain partial: %v", run.CostSource)
	}
	if !strings.Contains(e.eventTypes(run.ID), "lifecycle:harness_fallback") {
		t.Fatal("missing fallback event")
	}
	turns, err := e.q.ListTurns(e.ctx, run.ID)
	if err != nil || len(turns) != 2 {
		t.Fatalf("turns=%d err=%v", len(turns), err)
	}
	if !strings.Contains(turns[1].InputMessage, "Preserve this verified tool outcome across harnesses") {
		t.Fatal("fallback lost normalized tool history")
	}
	if !strings.Contains(deref(run.Outcome), "preserved checkout") {
		t.Fatalf("outcome=%v", run.Outcome)
	}
}

func TestFallbackStopsOnExhaustionOrUnrelatedErrors(t *testing.T) {
	for _, tc := range []struct {
		mode, harness, model string
		turns                int
	}{
		// The fallback shares the exhausted harness, whose limit is recorded: skipped, so no second turn.
		{"quota", "claude-code", "another-model", 1},
		{"crash", "codex", "fallback-model", 1},
	} {
		t.Run(tc.mode, func(t *testing.T) {
			e := setup(t)
			t.Setenv("FAKE_HARNESS_MODE", tc.mode)
			e.dispatch("PAY-214")
			run := e.run("PAY-214")
			var spec agentdef.Resolved
			if err := json.Unmarshal(run.ResolvedSpec, &spec); err != nil {
				t.Fatal(err)
			}
			spec.Fallbacks = []agentdef.Fallback{{Harness: tc.harness, Model: tc.model}}
			raw, _ := json.Marshal(spec)
			if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET resolved_spec=$2 WHERE id=$1", run.ID, raw); err != nil {
				t.Fatal(err)
			}
			e.until("stopped without looping", func() bool { st := e.run("PAY-214").State; return st == "failed" || st == "waiting_for_quota" })
			turns, err := e.q.ListTurns(e.ctx, run.ID)
			if err != nil || len(turns) != tc.turns {
				t.Fatalf("turns=%d want=%d err=%v", len(turns), tc.turns, err)
			}
		})
	}
}

func TestHarnessToolApprovalParity(t *testing.T) {
	for _, name := range []string{"claude-code", "codex"} {
		t.Run(name, func(t *testing.T) {
			e := setup(t)
			e.runner.Cfg.ToolApprovalWait = 100 * time.Millisecond
			e.runner.Cfg.ToolApprovalPoll = 20 * time.Millisecond
			t.Setenv("FAKE_HARNESS_MODE", "policy")
			e.dispatch("PAY-214")
			run := e.run("PAY-214")
			var spec agentdef.Resolved
			if err := json.Unmarshal(run.ResolvedSpec, &spec); err != nil {
				t.Fatal(err)
			}
			spec.Harness = name
			for i := range spec.Scopes {
				if spec.Scopes[i].Scope == "tests:run" {
					spec.Scopes[i].Mode = agentdef.RequiresApproval
				}
			}
			raw, _ := json.Marshal(spec)
			if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET resolved_spec=$2,harness=$3 WHERE id=$1", run.ID, raw, name); err != nil {
				t.Fatal(err)
			}
			e.until("hook approval", e.state("PAY-214=waiting"))
			pending, err := e.q.ListApprovalsForRun(e.ctx, run.ID)
			if err != nil || len(pending) != 1 || pending[0].Scope != "tests:run" {
				t.Fatalf("approval: %+v %v", pending, err)
			}
			marker := filepath.Join(e.runner.Backend.WorkspaceDir(run.ID.String()), "approved-action.txt")
			if _, err := os.Stat(marker); !os.IsNotExist(err) {
				t.Fatal("tool executed before approval")
			}
			if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, pending[0].ID, true, ""); err != nil {
				t.Fatal(err)
			}
			e.until("approved tool completed", e.state("PAY-214=completed"))
			ap, _ := e.q.GetApproval(e.ctx, store.GetApprovalParams{ID: pending[0].ID, WorkspaceID: e.ws})
			if ap.ExecutedAt == nil {
				t.Fatal("approval was not consumed")
			}
		})
	}
}

func TestEpicTicketStacksOnEpicBranch(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "idle")
	origin := filepath.Join(e.dir, "origin")
	if err := os.MkdirAll(origin, 0700); err != nil {
		t.Fatal(err)
	}
	git := func(args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", origin}, args...)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v: %v %s", args, err, out)
		}
		return string(out)
	}
	var epicID uuid.UUID
	if err := e.pool.QueryRow(e.ctx, "SELECT e.id FROM epics e JOIN projects p ON p.id=e.project_id WHERE p.key='PAY' LIMIT 1").Scan(&epicID); err != nil {
		t.Fatal(err)
	}
	branch := agentdef.EpicBranch("PAY", epicID.String())
	git("init", "--quiet", "-b", "main")
	git("config", "user.name", "Test")
	git("config", "user.email", "test@example.com")
	if err := os.WriteFile(filepath.Join(origin, "main.txt"), []byte("main"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "--quiet", "-m", "main")
	git("checkout", "--quiet", "-b", branch)
	if err := os.WriteFile(filepath.Join(origin, "epic.txt"), []byte("earlier ticket"), 0600); err != nil {
		t.Fatal(err)
	}
	git("add", ".")
	git("commit", "--quiet", "-m", "earlier ticket")
	git("checkout", "--quiet", "main")
	if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url=$1,default_branch='main' WHERE key='PAY'", origin); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(e.ctx, "UPDATE tickets SET epic_id=$1 WHERE key='PAY-224'", epicID); err != nil {
		t.Fatal(err)
	}
	e.dispatch("PAY-224")
	e.until("workspace ready", e.state("PAY-224=running"))
	run := e.run("PAY-224")
	spec, err := runs.Spec(run)
	if err != nil || spec.Repository == nil || spec.Repository.EpicBranch != branch {
		t.Fatalf("run spec should freeze the epic branch %q: %+v %v", branch, spec.Repository, err)
	}
	root := e.runner.Backend.WorkspaceDir(run.ID.String())
	if content, err := os.ReadFile(filepath.Join(root, "epic.txt")); err != nil || string(content) != "earlier ticket" {
		t.Fatalf("ticket branch wasn't cut from the epic branch: %q %v", content, err)
	}
	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, run.ID, "cancel"); err != nil {
		t.Fatal(err)
	}
	e.runner.Sweep(e.ctx)
}

func TestHarnessKeyMapping(t *testing.T) {
	if k, err := runner.HarnessKey(agentdef.Resolved{Harness: agentdef.HarnessClaudeCode}); err != nil || k.Secret != "harness:anthropic" {
		t.Errorf("claude mapping changed: %+v %v", k, err)
	}
	if k, err := runner.HarnessKey(agentdef.Resolved{Harness: agentdef.HarnessCodex}); err != nil || k.Secret != "harness:openai" || len(k.Env) != 2 {
		t.Errorf("codex mapping changed: %+v %v", k, err)
	}
	if k, err := runner.HarnessKey(agentdef.Resolved{Harness: "mystery", Model: "x"}); err == nil {
		t.Errorf("unknown harness resolved to %+v instead of failing", k)
	}
}

func TestHeartbeatAppliesAndLiftsSlotLimit(t *testing.T) {
	e := setup(t)
	e.runner.Heartbeat(e.ctx)
	if got := e.runner.Capacity(); got != 2 {
		t.Fatalf("uncapped capacity %d, want MaxConcurrent 2", got)
	}
	one := int32(1)
	if err := e.q.SetRunnerSlotLimit(e.ctx, &one); err != nil {
		t.Fatal(err)
	}
	e.runner.Heartbeat(e.ctx)
	if got := e.runner.Capacity(); got != 1 {
		t.Fatalf("capped capacity %d, want 1", got)
	}
	// A cap above MaxConcurrent never raises it.
	ten := int32(10)
	if err := e.q.SetRunnerSlotLimit(e.ctx, &ten); err != nil {
		t.Fatal(err)
	}
	e.runner.Heartbeat(e.ctx)
	if got := e.runner.Capacity(); got != 2 {
		t.Fatalf("cap above max: capacity %d, want 2", got)
	}
	if err := e.q.SetRunnerSlotLimit(e.ctx, nil); err != nil {
		t.Fatal(err)
	}
	e.runner.Heartbeat(e.ctx)
	if got := e.runner.Capacity(); got != 2 {
		t.Fatalf("lifted capacity %d, want 2", got)
	}
}

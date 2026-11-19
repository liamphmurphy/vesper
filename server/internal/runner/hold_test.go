package runner_test

import (
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func (e env) due(id uuid.UUID) {
	e.t.Helper()
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET hold_until = now() - interval '1 minute' WHERE id = $1", id); err != nil {
		e.t.Fatal(err)
	}
}

func (e env) control(id uuid.UUID, action string) {
	e.t.Helper()
	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, id, action); err != nil {
		e.t.Fatal(err)
	}
}

func (e env) hasLifecycle(id uuid.UUID, state string) bool {
	e.t.Helper()
	return strings.Contains(e.eventTypes(id), "lifecycle:"+state)
}

func holdSetup(t *testing.T) (env, string) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	e.dispatch("PAY-214")
	e.until("held", e.state("PAY-214=waiting_for_quota"))
	return e, logPath
}

func TestHoldBacksOffWithoutResetTime(t *testing.T) {
	e, logPath := holdSetup(t)
	run := e.run("PAY-214")
	if run.HoldResetKnown || run.HoldAttempts != 1 || run.HoldUntil == nil {
		t.Fatalf("hold %+v", run)
	}
	if d := time.Until(*run.HoldUntil); d < 4*time.Minute || d > 5*time.Minute {
		t.Fatalf("first backoff %v", d)
	}
	// Nothing runs until the backoff is over, and no slot is held meanwhile.
	e.runner.Tick(e.ctx)
	e.runner.Wait()
	if lines := readHarnessLog(t, logPath); len(lines) != 1 {
		t.Fatalf("resumed early: %+v", lines)
	}
	if n, _ := e.q.LiveWorkRunsCount(e.ctx); n != 0 {
		t.Fatalf("a held run counts as busy: %d", n)
	}
	e.due(run.ID)
	e.until("held again", func() bool { return e.run("PAY-214").HoldAttempts == 2 })
	run = e.run("PAY-214")
	if d := time.Until(*run.HoldUntil); d < 9*time.Minute || d > 10*time.Minute {
		t.Fatalf("second backoff %v", d)
	}
}

func TestHoldResumesAfterParsedReset(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	t.Setenv("FAKE_HARNESS_QUOTA_MESSAGE", "You've hit your session limit · resets 9:20pm (UTC)")
	e.dispatch("PAY-214")
	e.until("held", e.state("PAY-214=waiting_for_quota"))
	run := e.run("PAY-214")
	if !run.HoldResetKnown || run.HoldUntil == nil {
		t.Fatalf("hold %+v", run)
	}
	if u := run.HoldUntil.UTC(); u.Hour() != 21 || u.Minute() != 21 {
		t.Fatalf("until %v, want the reset plus its grace", u)
	}
	active, err := e.q.RunActiveSeconds(e.ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET hold_started_at = now() - interval '2 hours' WHERE id = $1", run.ID); err != nil {
		t.Fatal(err)
	}
	if after, _ := e.q.RunActiveSeconds(e.ctx, run.ID); after.Seconds != active.Seconds {
		t.Fatalf("held time counted against the runtime: %v then %v", active.Seconds, after.Seconds)
	}
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	e.due(run.ID)
	e.until("completed", e.state("PAY-214=completed"))
	lines := readHarnessLog(t, logPath)
	if len(lines) != 2 || lines[1].Resume == "" || lines[1].Resume != *run.HarnessSessionID {
		t.Fatalf("must resume the same session %v: %+v", run.HarnessSessionID, lines)
	}
	if !e.hasLifecycle(run.ID, "quota_resumed") {
		t.Fatalf("no resume in the timeline: %s", e.eventTypes(run.ID))
	}
	if got := e.run("PAY-214"); got.HoldStartedAt != nil || got.HoldAttempts != 0 {
		t.Fatalf("hold not cleared: %+v", got)
	}
}

func TestCancelDuringHold(t *testing.T) {
	e, logPath := holdSetup(t)
	run := e.run("PAY-214")
	e.control(run.ID, "cancel")
	e.due(run.ID)
	e.runner.Tick(e.ctx)
	e.runner.Wait()
	if got := e.run("PAY-214"); got.State != "cancelled" {
		t.Fatalf("state %s", got.State)
	}
	if lines := readHarnessLog(t, logPath); len(lines) != 1 {
		t.Fatalf("a cancelled run must not resume: %+v", lines)
	}
}

func TestManualResumeDuringHold(t *testing.T) {
	e, logPath := holdSetup(t)
	run := e.run("PAY-214")
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	e.control(run.ID, "resume")
	e.until("completed", e.state("PAY-214=completed"))
	if lines := readHarnessLog(t, logPath); len(lines) != 2 {
		t.Fatalf("lines %+v", lines)
	}
	if !e.hasLifecycle(run.ID, "quota_resume_requested") {
		t.Fatalf("no request in the timeline: %s", e.eventTypes(run.ID))
	}
}

func TestMaxHoldTimeFails(t *testing.T) {
	e, _ := holdSetup(t)
	run := e.run("PAY-214")
	// Not due yet: the limit applies even to a reset time beyond it.
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET hold_started_at = now() - interval '25 hours' WHERE id = $1", run.ID); err != nil {
		t.Fatal(err)
	}
	e.until("failed", e.state("PAY-214=failed"))
	if got := e.run("PAY-214"); got.Outcome == nil || !strings.Contains(*got.Outcome, "held for 24h") {
		t.Fatalf("outcome %v", got.Outcome)
	}
}

func TestMaxHoldAttemptsFails(t *testing.T) {
	e, _ := holdSetup(t)
	e.runner.Cfg.MaxHoldAttempts = 1
	e.due(e.run("PAY-214").ID)
	e.until("failed", e.state("PAY-214=failed"))
	if got := e.run("PAY-214"); got.Outcome == nil || !strings.Contains(*got.Outcome, "1 resume attempts") {
		t.Fatalf("outcome %v", got.Outcome)
	}
}

func TestNonQuotaFailureIsNotHeld(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "crash")
	e.dispatch("PAY-214")
	e.until("failed", e.state("PAY-214=failed"))
	if got := e.run("PAY-214"); got.HoldAttempts != 0 {
		t.Fatalf("held: %+v", got)
	}
}

// withRepo points every project at a bare repository holding one commit.
func (e env) withRepo() string {
	e.t.Helper()
	root := e.t.TempDir()
	seedDir, bare := filepath.Join(root, "seed"), filepath.Join(root, "origin.git")
	gitIn(e.t, root, "init", "-q", "-b", "main", seedDir)
	if err := os.WriteFile(filepath.Join(seedDir, "README.md"), []byte("hello\n"), 0o644); err != nil {
		e.t.Fatal(err)
	}
	gitIn(e.t, seedDir, "add", ".")
	gitIn(e.t, seedDir, "commit", "-q", "-m", "init")
	gitIn(e.t, root, "clone", "-q", "--bare", seedDir, bare)
	if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url = $1, default_branch = 'main'", bare); err != nil {
		e.t.Fatal(err)
	}
	return bare
}

func TestCheckpointRecoveredByNextRun(t *testing.T) {
	e := setup(t)
	bare := e.withRepo()
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	e.dispatch("PAY-214")
	e.until("held", e.state("PAY-214=waiting_for_quota"))
	first := e.run("PAY-214")
	if _, err := os.Stat(filepath.Join(e.workspace(first), "before-fallback.txt")); err != nil {
		t.Fatal(err)
	}
	e.control(first.ID, "cancel")

	if _, err := e.pool.Exec(e.ctx, "UPDATE tickets SET status = 'todo' WHERE key = 'PAY-214'"); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	e.dispatch("PAY-214")
	second := e.run("PAY-214")
	if second.ID == first.ID {
		t.Fatal("no new run")
	}
	e.until("workspace recovered", func() bool { return e.hasLifecycle(second.ID, "checkpoint_recovered") })

	after, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: first.ID, WorkspaceID: e.ws})
	if err != nil {
		t.Fatal(err)
	}
	if after.CheckpointBranch == nil || !strings.HasPrefix(*after.CheckpointBranch, "vesper-checkpoint/pay-214/") {
		t.Fatalf("branch %v", after.CheckpointBranch)
	}
	files := gitIn(t, bare, "ls-tree", "-r", "--name-only", *after.CheckpointBranch)
	if !strings.Contains(files, "before-fallback.txt") {
		t.Fatalf("uncommitted work not saved: %s", files)
	}
	if strings.Contains(files, ".lazyagents") {
		t.Fatalf("Vesper's files were saved: %s", files)
	}
	if b, err := os.ReadFile(filepath.Join(e.workspace(second), "before-fallback.txt")); err != nil || string(b) != "work preserved" {
		t.Fatalf("recovered %q %v", b, err)
	}
}

func TestFailedCheckpointKeepsWorkspace(t *testing.T) {
	e := setup(t)
	bare := e.withRepo()
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	e.dispatch("PAY-214")
	e.until("held", e.state("PAY-214=waiting_for_quota"))
	run := e.run("PAY-214")
	if err := os.RemoveAll(bare); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(e.ctx, "UPDATE runs SET state = 'completed', ended_at = now() WHERE id = $1", run.ID); err != nil {
		t.Fatal(err)
	}
	e.runner.Sweep(e.ctx)
	got := e.run("PAY-214")
	if got.CheckpointError == nil || got.WorkspaceVolume == nil {
		t.Fatalf("checkpoint error %v volume %v", got.CheckpointError, got.WorkspaceVolume)
	}
	if _, err := os.Stat(filepath.Join(e.workspace(run), "before-fallback.txt")); err != nil {
		t.Fatalf("workspace discarded: %v", err)
	}
	if !e.hasLifecycle(run.ID, "checkpoint_failed") {
		t.Fatalf("not surfaced: %s", e.eventTypes(run.ID))
	}
}

func TestCheckpointSkipsWorkAlreadyOnOrigin(t *testing.T) {
	e := setup(t)
	e.withRepo()
	t.Setenv("FAKE_HARNESS_MODE", "complete")
	e.dispatch("PAY-214")
	e.until("completed", e.state("PAY-214=completed"))
	run := e.run("PAY-214")
	if run.CheckpointBranch != nil {
		t.Fatalf("nothing to save, but pushed %s", *run.CheckpointBranch)
	}
	if run.WorkspaceVolume != nil {
		t.Fatal("workspace kept")
	}
}

func TestTicketCheckpointDeletedAfterCompletedPR(t *testing.T) {
	for _, name := range []string{"GH_TOKEN", "GITHUB_TOKEN", "GIT_PAT"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	e := setup(t)
	bare := bareRepo(t)
	gitIn(t, bare, "symbolic-ref", "HEAD", "refs/heads/main")
	config := filepath.Join(t.TempDir(), "gitconfig")
	if out, err := exec.Command("git", "config", "--file", config, "url."+bare+".insteadOf", "https://github.com/acme/alpha.git").CombinedOutput(); err != nil {
		t.Fatalf("rewrite: %v %s", err, out)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	if _, err := e.pool.Exec(e.ctx, "UPDATE projects SET repo_url = 'https://github.com/acme/alpha.git', default_branch = 'main'"); err != nil {
		t.Fatal(err)
	}
	sec := e.runner.Secrets.(*secrets.Service)
	if _, err := sec.Set(e.ctx, e.ws, e.me.ID, secrets.SetInput{Name: "git:pat", Value: "ghp_testtoken123"}); err != nil {
		t.Fatal(err)
	}
	gh := &fakeGitHub{t: t, bare: bare}
	srv := httptest.NewServer(gh)
	t.Cleanup(srv.Close)
	e.runner.Cfg.GitHubAPIURL = srv.URL

	// Run 1 hits quota with uncommitted before-fallback.txt, then cancels.
	t.Setenv("FAKE_HARNESS_MODE", "quota")
	e.dispatch("PAY-214")
	e.until("held", e.state("PAY-214=waiting_for_quota"))
	first := e.run("PAY-214")
	e.control(first.ID, "cancel")

	if _, err := e.pool.Exec(e.ctx, "UPDATE tickets SET status = 'todo' WHERE key = 'PAY-214'"); err != nil {
		t.Fatal(err)
	}
	// Run 2 recovers Run 1's checkpoint and pauses waiting for approval.
	t.Setenv("FAKE_HARNESS_MODE", "approval")
	e.dispatch("PAY-214")
	second := e.run("PAY-214")
	e.until("waiting for approval", e.state("PAY-214=waiting"))
	if !e.hasLifecycle(second.ID, "checkpoint_recovered") {
		t.Fatalf("expected checkpoint_recovered on second run, events: %s", e.eventTypes(second.ID))
	}

	// Simulate Run 2 polishing the recovered work, committing cleanly, pushing its branch, and recording PR #42.
	tk, err := tracker.Get(e.ctx, e.q, e.ws, "PAY-214")
	if err != nil || tk.Branch == nil || *tk.Branch == "" {
		t.Fatalf("ticket = %+v, err = %v", tk, err)
	}
	ws := e.workspace(second)
	gitIn(t, ws, "reset", "--soft", "main")
	if err := os.WriteFile(filepath.Join(ws, "before-fallback.txt"), []byte("polished work preserved\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitIn(t, ws, "add", "before-fallback.txt")
	gitIn(t, ws, "commit", "-qm", "Implement PAY-214 cleanly")
	gitIn(t, ws, "push", "-q", bare, "HEAD:refs/heads/"+*tk.Branch)
	prSHA := gitIn(t, ws, "rev-parse", "HEAD")

	gh.mu.Lock()
	gh.pulls = append(gh.pulls, map[string]any{
		"number":   42,
		"html_url": "https://github.com/acme/alpha/pull/42",
		"head":     map[string]any{"sha": prSHA, "ref": *tk.Branch},
		"head_ref": *tk.Branch,
		"head_sha": prSHA,
		"base":     "main",
		"title":    "Implement PAY-214",
		"draft":    false,
		"state":    "open",
		"merged":   false,
	})
	gh.mu.Unlock()
	prNum := int32(42)
	prURL := "https://github.com/acme/alpha/pull/42"
	prState := "open"
	if err := e.q.SetTicketPR(e.ctx, store.SetTicketPRParams{ID: tk.ID, PrNumber: &prNum, PrUrl: &prURL, PrState: &prState}); err != nil {
		t.Fatal(err)
	}

	// Approve so Run 2 completes -> cleanup deletes Run 1's checkpoint branch.
	aps, err := e.q.PendingApprovalsForTicket(e.ctx, tk.ID)
	if err != nil || len(aps) == 0 {
		t.Fatalf("pending approvals: %+v, err=%v", aps, err)
	}
	if _, err := e.runs.Decide(e.ctx, e.ws, e.me.ID, aps[0].ID, true, "ship it"); err != nil {
		t.Fatal(err)
	}
	e.until("completed", e.state("PAY-214=completed"))
	e.runner.Wait()

	if refs := listCheckpointRefs(t, bare); len(refs) != 0 {
		t.Fatalf("ticket checkpoint still present on bare after completed PR: %v", refs)
	}
	open, err := e.q.OpenTicketCheckpoints(e.ctx, tk.ID)
	if err != nil || len(open) != 0 {
		t.Fatalf("expected 0 open ticket checkpoints, got %+v, err=%v", open, err)
	}
	afterFirst, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: first.ID, WorkspaceID: e.ws})
	if err != nil || afterFirst.CheckpointBranch != nil {
		t.Fatalf("expected Run 1 checkpoint_branch cleared, got %v, err=%v", afterFirst.CheckpointBranch, err)
	}
	if !e.hasLifecycle(second.ID, "checkpoint_deleted") {
		t.Fatalf("expected checkpoint_deleted event on Run 2, got %s", e.eventTypes(second.ID))
	}
}

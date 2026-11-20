package runner_test

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// delegationTurns counts the parent's turns that woke it with a delegation report.
func (e env) delegationTurns(parent store.Run) int {
	e.t.Helper()
	turns, err := e.q.ListTurns(e.ctx, parent.ID)
	if err != nil {
		e.t.Fatal(err)
	}
	n := 0
	for _, turn := range turns {
		if turn.Trigger == "delegation" {
			n++
		}
	}
	return n
}

// waitedOnChecks reports whether a run ever waited on its checks.
func (e env) waitedOnChecks(run store.Run) bool {
	e.t.Helper()
	var n int
	if err := e.pool.QueryRow(e.ctx, `SELECT count(*) FROM run_events WHERE run_id = $1 AND type = 'lifecycle' AND payload->>'reason' = 'checks'`, run.ID).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n > 0
}

// A sub agent that leaves its work uncommitted gets the failure back in its own
// session and fixes it; the main agent is woken once, with the passing result.
func TestCheckFailureIsSentBackToTheSubAgent(t *testing.T) {
	e := setup(t)
	logPath := filepath.Join(t.TempDir(), "log.jsonl")
	t.Setenv("FAKE_HARNESS_MODE", "delegate_script")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	t.Setenv("FAKE_HARNESS_CHILD_UNCOMMITTED", "1")
	t.Setenv("FAKE_HARNESS_DELEGATIONS", script(t, []args{{"task": "Write FILE=docs/a.txt", "allowed_paths": []string{"docs/"}, "test_command": "test -f docs/a.txt"}}))
	e.dispatch("PAY-214")
	e.until("completed", e.state("PAY-214=completed"))
	parent := e.run("PAY-214")
	out := deref(parent.Outcome)
	kid := e.children(parent)[0]
	c := e.checksOf(kid)
	if kid.State != "completed" || !c.Passed || !c.Merged || c.Bounces != 1 || e.contractOf(kid).Bounces != 1 {
		t.Fatalf("child %s checks %s contract %s", kid.State, kid.Checks, kid.Contract)
	}
	if deref(kid.Outcome) != "Fixed what the checks found" {
		t.Fatalf("child outcome %q", deref(kid.Outcome))
	}
	if n := e.delegationTurns(parent); n != 1 {
		t.Fatalf("parent woken %d times", n)
	}
	for _, want := range []string{"**PASSED**", "Passed on attempt 2 after the server sent the check failure back.", "**MERGED**"} {
		if !strings.Contains(out, want) {
			t.Fatalf("report lacks %q:\n%s", want, out)
		}
	}
	// The second attempt resumed the child's own session with the failure.
	session := deref(kid.HarnessSessionID)
	var child []map[string]string
	for _, l := range readLog(t, logPath) {
		if strings.Contains(l["prompt"], "delegated part of") || strings.HasPrefix(l["prompt"], "The server checked your work") {
			child = append(child, l)
		}
	}
	if session == "" || len(child) != 2 || child[0]["resume"] != "" || !strings.HasPrefix(child[1]["prompt"], "The server checked your work") || child[1]["resume"] != session {
		t.Fatalf("child invocations %v (session %q)", child, session)
	}
	turns, _ := e.q.ListTurns(e.ctx, kid.ID)
	if len(turns) != 2 || turns[1].Trigger != "resume" || !strings.Contains(turns[1].InputMessage, "docs/a.txt") ||
		!strings.Contains(turns[1].InputMessage, "Retry 1 of 2.") || strings.Contains(turns[1].InputMessage, "NOT MERGED") {
		t.Fatalf("child turns %+v", turns)
	}
	rows, err := e.q.DelegationEfficiency(e.ctx, e.ws)
	if err != nil || len(rows) != 1 || rows[0].Checked != 1 || rows[0].FirstPass != 0 || rows[0].Bounces != 1 {
		t.Fatalf("efficiency %+v err=%v", rows, err)
	}
}

// A test command that keeps failing is sent back twice; the third result goes
// to the main agent, once.
func TestCheckFailureBouncesAreBounded(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "delegate_script")
	t.Setenv("FAKE_HARNESS_DELEGATIONS", script(t, []args{{"task": "Write FILE=docs/a.txt", "allowed_paths": []string{"docs/"}, "test_command": "echo still broken; exit 3"}}))
	e.dispatch("PAY-214")
	e.until("completed", e.state("PAY-214=completed"))
	parent := e.run("PAY-214")
	out := deref(parent.Outcome)
	kid := e.children(parent)[0]
	c := e.checksOf(kid)
	if kid.State != "completed" || c.Passed || c.Merged || c.Bounces != runs.MaxCheckBounces || c.TestExit == nil || *c.TestExit != 3 {
		t.Fatalf("child %s checks %s", kid.State, kid.Checks)
	}
	if turns, _ := e.q.ListTurns(e.ctx, kid.ID); len(turns) != 1+runs.MaxCheckBounces {
		t.Fatalf("child turns %d", len(turns))
	}
	if n := e.delegationTurns(parent); n != 1 {
		t.Fatalf("parent woken %d times", n)
	}
	for _, want := range []string{"**FAILED**", "still broken", "Still failing on attempt 3", "**NOT MERGED**"} {
		if !strings.Contains(out, want) {
			t.Fatalf("report lacks %q:\n%s", want, out)
		}
	}
	rows, err := e.q.DelegationEfficiency(e.ctx, e.ws)
	if err != nil || len(rows) != 1 || rows[0].FirstPass != 0 || rows[0].Bounces != int64(runs.MaxCheckBounces) {
		t.Fatalf("efficiency %+v err=%v", rows, err)
	}
}

// A delegation with nothing to check completes at once, as before.
func TestEmptyContractCompletesWithoutChecksWait(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "delegate_script")
	t.Setenv("FAKE_HARNESS_DELEGATIONS", script(t, []args{{"task": "Write FILE=docs/a.txt"}}))
	e.dispatch("PAY-214")
	e.until("completed", e.state("PAY-214=completed"))
	parent := e.run("PAY-214")
	kid := e.children(parent)[0]
	c := e.checksOf(kid)
	if kid.State != "completed" || !c.Merged || c.Bounces != 0 || e.waitedOnChecks(kid) || e.delegationTurns(parent) != 1 {
		t.Fatalf("child %s checks %s waited=%v", kid.State, kid.Checks, e.waitedOnChecks(kid))
	}
	rows, err := e.q.DelegationEfficiency(e.ctx, e.ws)
	if err != nil || len(rows) != 1 || rows[0].FirstPass != 1 || rows[0].Bounces != 0 {
		t.Fatalf("efficiency %+v err=%v", rows, err)
	}
}

// Cancelling the main agent while its sub agent waits on its checks cancels
// the sub agent; the checks finishing afterwards change nothing.
func TestCancelledParentCancelsChildWaitingOnChecks(t *testing.T) {
	e := setup(t)
	hold := filepath.Join(t.TempDir(), "release")
	t.Setenv("FAKE_HARNESS_MODE", "delegate_script")
	t.Setenv("FAKE_HARNESS_DELEGATIONS", script(t, []args{{"task": "Write FILE=docs/a.txt", "allowed_paths": []string{"docs/"},
		"test_command": "while [ ! -f " + hold + " ]; do sleep 0.05; done"}}))
	e.dispatch("PAY-214")
	e.tickUntil("child waiting on its checks", func() bool {
		kids := e.children(e.run("PAY-214"))
		return len(kids) == 1 && kids[0].State == "waiting" && deref(kids[0].WaitReason) == "checks" && kids[0].ExecutionToken != nil
	})
	parent := e.run("PAY-214")
	if _, err := e.runs.SetRunControl(e.ctx, e.ws, e.me.ID, parent.ID, "cancel"); err != nil {
		t.Fatal(err)
	}
	kid := e.children(parent)[0]
	if kid.State != "cancelled" {
		t.Fatalf("child %s/%s after parent cancelled", kid.State, deref(kid.WaitReason))
	}
	releaseFile(t, hold)
	e.runner.Wait()
	for i := 0; i < 3; i++ {
		e.runner.Tick(e.ctx)
		e.runner.Wait()
	}
	parent = e.run("PAY-214")
	kid = e.children(parent)[0]
	if parent.State != "cancelled" || kid.State != "cancelled" || len(kid.Checks) != 0 || e.delegationTurns(parent) != 0 {
		t.Fatalf("parent %s child %s checks %s wakes %d", parent.State, kid.State, kid.Checks, e.delegationTurns(parent))
	}
}

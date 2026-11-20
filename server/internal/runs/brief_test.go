package runs_test

import (
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestRunBrief(t *testing.T) {
	f := newStepFixture(t)
	if _, err := f.svc.PostPlan(f.ctx, f.caller, "", []string{"Read the code", "Write the fix", "Ship it"}); err != nil {
		t.Fatal(err)
	}
	if _, err := f.svc.UpdateStep(f.ctx, f.caller, "", 1, "done", "  The bug is in ledger.go.\nKeep the old API.  "); err != nil {
		t.Fatal(err)
	}
	if err := f.svc.CheckCriterion(f.ctx, f.caller, "", 1, true); err != nil {
		t.Fatal(err)
	}
	long := strings.Repeat("d", 5000) + "TAIL-OF-DESCRIPTION"
	if _, err := f.svc.Pool.Exec(f.ctx, `UPDATE tickets SET description_md=$2, pr_url='https://github.com/acme/pay/pull/7' WHERE id=$1`, *f.run.TicketID, long); err != nil {
		t.Fatal(err)
	}
	// A finished delegated run with a verdict, checks and a long outcome.
	outcome := "Reviewed it. " + strings.Repeat("o", 1000) + "TAIL-OF-OUTCOME"
	var child uuid.UUID
	err := f.svc.Pool.QueryRow(f.ctx, `INSERT INTO runs (workspace_id, ticket_id, agent_id, mode, state, resolved_spec, harness, model, parent_run_id, purpose, outcome, checks)
		SELECT workspace_id, ticket_id, agent_id, mode, 'completed', resolved_spec, harness, model, id, purpose, $2, '{"passed":true,"merged":true,"branch":"sub/x"}'
		FROM runs WHERE id=$1 RETURNING id`, f.run.ID, outcome).Scan(&child)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.q.AddRunEvent(f.ctx, store.AddRunEventParams{RunID: child, Type: "lifecycle", Payload: []byte(`{"state":"completed","verdict":"` + runs.VerdictApproved + `"}`)}); err != nil {
		t.Fatal(err)
	}
	run, _ := f.q.GetRun(f.ctx, store.GetRunParams{ID: f.run.ID, WorkspaceID: f.ws})
	brief, err := runs.RunBrief(f.ctx, f.q, run)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := runs.RunBrief(f.ctx, f.q, run)
	if again != brief {
		t.Fatal("brief is not deterministic")
	}
	for _, want := range []string{
		"## Ticket PAY-214:",
		"1. [x] ",
		"3. [ ] ",
		"1. [done] Read the code\n   Note: The bug is in ledger.go.\n   Keep the old API.\n2.",
		"2. [current] Write the fix  <- current step",
		"3. [pending] Ship it",
		"https://github.com/acme/pay/pull/7",
		"(run " + runs.ShortRunID(child) + "): completed, verdict approved, checks passed, branch merged",
		"Outcome: Reviewed it.",
		"don't call claim_ticket or post_plan again",
	} {
		if !strings.Contains(brief, want) {
			t.Errorf("brief lacks %q:\n%s", want, brief)
		}
	}
	for _, clipped := range []string{"TAIL-OF-DESCRIPTION", "TAIL-OF-OUTCOME"} {
		if strings.Contains(brief, clipped) {
			t.Errorf("long field not clipped: %q present", clipped)
		}
	}
	if len(brief) > 6000 {
		t.Errorf("brief is %d bytes", len(brief))
	}
}

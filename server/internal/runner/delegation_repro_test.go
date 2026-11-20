package runner_test

import (
	"strings"
	"testing"
)

// A reviewer commits a failing test and reports it as repro_command; the
// server merges it because it fails, the main agent fixes the finding and
// calls recheck_review, the server reruns the repro in the main agent's
// checkout without another sub agent run, and Done then accepts the review's
// changes_requested only when the reviewer said its tests cover every finding.
func TestReviewReproRecheckClearsDone(t *testing.T) {
	for _, tc := range []struct {
		name      string
		coversAll bool
	}{{"covers all", true}, {"partial", false}} {
		t.Run(tc.name, func(t *testing.T) {
			e := setup(t)
			t.Setenv("FAKE_HARNESS_MODE", "delegate_script")
			t.Setenv("FAKE_HARNESS_DELEGATIONS", script(t, []args{
				{"task": "Review the change. FILE=checks/fix_test.sh", "allowed_paths": []string{"*_test.sh"}},
			}))
			t.Setenv("FAKE_HARNESS_CHILD_REPRO", "test -f checks/fix_test.sh && grep -q fixed app.txt")
			if tc.coversAll {
				t.Setenv("FAKE_HARNESS_CHILD_COVERS_ALL", "1")
			}
			t.Setenv("FAKE_HARNESS_RECHECK", "app.txt")
			e.dispatch("PAY-214")
			e.until("completed", e.state("PAY-214=completed"))
			parent := e.run("PAY-214")
			kids := e.children(parent)
			if len(kids) != 1 {
				t.Fatalf("want one delegated run (no re-review), got %d", len(kids))
			}
			c := e.checksOf(kids[0])
			if !c.Merged || c.ReproExit == nil || *c.ReproExit == 0 || !c.ReproFixed || c.RecheckRequested || c.RecheckSHA == "" {
				t.Fatalf("checks %s", kids[0].Checks)
			}
			if ct := e.contractOf(kids[0]); ct.ReproCommand == "" || ct.ReproCoversAll != tc.coversAll {
				t.Fatalf("contract %s", kids[0].Contract)
			}
			out := deref(parent.Outcome)
			if !strings.Contains(out, "## Review recheck") || !strings.Contains(out, "**PASSED**") {
				t.Fatalf("outcome:\n%s", out)
			}
			refused := strings.HasPrefix(out, "DONE REFUSED")
			if tc.coversAll == refused {
				t.Fatalf("covers_all=%v but outcome:\n%s", tc.coversAll, out)
			}
			if refused && !strings.Contains(out, "requested changes") {
				t.Fatalf("refusal reason:\n%s", out)
			}
		})
	}
}

// A repro that already passes doesn't demonstrate the findings: the reviewer's
// branch is not merged and the main agent is told why.
func TestPassingReproIsNotMerged(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "delegate_script")
	t.Setenv("FAKE_HARNESS_DELEGATIONS", script(t, []args{
		{"task": "Review the change. FILE=checks/fix_test.sh", "allowed_paths": []string{"*_test.sh"}},
	}))
	t.Setenv("FAKE_HARNESS_CHILD_REPRO", "true")
	e.dispatch("PAY-214")
	e.until("completed", e.state("PAY-214=completed"))
	parent := e.run("PAY-214")
	kid := e.children(parent)[0]
	c := e.checksOf(kid)
	if c.Merged || c.Passed || c.ReproExit == nil || *c.ReproExit != 0 {
		t.Fatalf("checks %s", kid.Checks)
	}
	out := deref(parent.Outcome)
	if !strings.Contains(out, "`true` already passes, so it doesn't demonstrate the findings; the branch was not merged") || !strings.Contains(out, "**NOT MERGED**") {
		t.Fatalf("report:\n%s", out)
	}
	if after := out[strings.Index(out, "[git ls-files]"):]; strings.Contains(after, "checks/fix_test.sh") {
		t.Fatalf("unmerged tests reached the parent branch:\n%s", out)
	}
}

// A recheck isn't run over uncommitted changes (the result is recorded for
// HEAD) or after the main agent changed the reviewer's tests, so Done stays
// refused.
func TestRecheckRefusesDirtyOrEditedTests(t *testing.T) {
	for _, tc := range []struct{ name, fix, repro, dirty, want string }{
		{"dirty", "app.txt", "test -f checks/fix_test.sh && grep -q fixed app.txt", "scratch.txt", "uncommitted changes (scratch.txt)"},
		{"edited tests", "checks/fix_test.sh", "grep -q fixed checks/fix_test.sh", "", "The reviewer's test files differ from what it committed"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := setup(t)
			t.Setenv("FAKE_HARNESS_MODE", "delegate_script")
			t.Setenv("FAKE_HARNESS_DELEGATIONS", script(t, []args{
				{"task": "Review the change. FILE=checks/fix_test.sh", "allowed_paths": []string{"*_test.sh"}},
			}))
			t.Setenv("FAKE_HARNESS_CHILD_REPRO", tc.repro)
			t.Setenv("FAKE_HARNESS_CHILD_COVERS_ALL", "1")
			t.Setenv("FAKE_HARNESS_RECHECK", tc.fix)
			t.Setenv("FAKE_HARNESS_RECHECK_DIRTY", tc.dirty)
			e.dispatch("PAY-214")
			e.until("completed", e.state("PAY-214=completed"))
			parent := e.run("PAY-214")
			c := e.checksOf(e.children(parent)[0])
			out := deref(parent.Outcome)
			if c.ReproFixed || c.RecheckExit != nil || !strings.Contains(out, "**NOT RUN**") || !strings.Contains(out, tc.want) || !strings.HasPrefix(out, "DONE REFUSED") {
				t.Fatalf("checks %+v\noutcome:\n%s", c, out)
			}
		})
	}
}

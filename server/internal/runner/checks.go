package runner

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	checkTimeout     = 30 * time.Second
	testCheckTimeout = 10 * time.Minute
)

// execOnce runs a shell script in a run's workspace and returns its combined
// output and exit code. The process is killed when ctx ends.
func (r *Runner) execOnce(ctx context.Context, ws, name, script string, env map[string]string) (string, int, error) {
	return r.execIn(ctx, ws, "", name, script, env)
}

// execIn is execOnce in a directory of the workspace (a delegated run's worktree).
func (r *Runner) execIn(ctx context.Context, ws, dir, name, script string, env map[string]string) (string, int, error) {
	proc, err := r.Backend.Start(ctx, ws, ExecSpec{Name: name, Argv: []string{"sh", "-c", script}, Env: env, Dir: dir})
	if err != nil {
		return "", -1, err
	}
	return captureProcess(ctx, proc)
}

// parseStatus lists the files `git status --porcelain` reports, minus
// Vesper's own.
func parseStatus(out string) []string {
	var files []string
	for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
		if len(l) < 4 {
			continue
		}
		f := l[3:]
		if i := strings.LastIndex(f, " -> "); i >= 0 {
			f = f[i+4:]
		}
		if f = strings.Trim(f, `"`); !strings.HasPrefix(f, ".lazyagents/") {
			files = append(files, f)
		}
	}
	return files
}

// parkDelegation holds the parent lock while checking children and parking it,
// so a child's concurrent WakeParent cannot be lost between those operations.
func (r *Runner) parkDelegation(ctx context.Context, parent store.Run, turn store.RunTurn) (bool, error) {
	tx, err := r.Pool.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	q := store.New(tx)
	locked, err := q.LockRun(ctx, parent.ID)
	if err != nil {
		return false, err
	}
	if locked.State != "running" {
		if err := q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")}); err != nil {
			return false, err
		}
		return true, tx.Commit(ctx)
	}
	live, err := q.HasLiveChild(ctx, &parent.ID)
	if err != nil {
		return false, err
	}
	if !live {
		return false, nil
	}
	wait := "delegation"
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: parent.ID, State: "waiting", WaitReason: &wait}); err != nil {
		return false, err
	}
	if err := q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, Usage: []byte("{}")}); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

// delegationReport checks every delegated run that ended since the parent was
// parked, in its worktree, merges the ones that passed into the parent's
// branch, stores the results on the runs and returns the text to append to the
// parent's resume message, after the results of any recheck_review. It returns
// "" when no finished child is waiting to be checked or rechecked.
func (r *Runner) delegationReport(ctx context.Context, parent runCtx, env map[string]string, reportedTurn int) string {
	kids, err := r.q().ChildRuns(ctx, &parent.run.ID)
	if err != nil {
		return ""
	}
	var ended []store.Run
	for _, k := range kids {
		if !isDone(k.State) {
			return ""
		}
		// Not yet reported (checked at completion or not at all), or reported
		// in this turn before a crash: replayed below.
		var checks runs.Checks
		if len(k.Checks) == 0 || (json.Unmarshal(k.Checks, &checks) == nil && (checks.ReportedTurn == 0 || checks.ReportedTurn == reportedTurn)) {
			ended = append(ended, k)
		}
	}
	recheck := r.recheckReport(ctx, parent, kids, env, reportedTurn)
	if len(ended) == 0 {
		return recheck
	}
	ws := wsID(parent.run)
	parentBranch := r.gitOut(ctx, ws, "", "lazyagents-branch-"+parent.run.ID.String(), "git symbolic-ref --short HEAD", env)
	var report strings.Builder
	report.WriteString(recheck)
	var mergedCmds []string // test commands of the children merged so far in this report
	merged := 0
	for _, child := range ended {
		var contract runs.Contract
		if len(child.Contract) > 0 {
			_ = json.Unmarshal(child.Contract, &contract)
		}
		var k runs.Checks
		if len(child.Checks) > 0 {
			_ = json.Unmarshal(child.Checks, &k)
		}
		if k.ReportedTurn == 0 {
			checksStart := time.Now()
			if len(child.Checks) == 0 {
				k = r.checkChild(ctx, child, contract, parentBranch, env)
			} // else checked when it completed (checkCompleted)
			k.ReportedTurn = reportedTurn
			r.mergeChild(ctx, ws, parentBranch, child, contract, &k, env)
			if k.Merged && merged > 0 {
				r.integrate(ctx, ws, child, &k, appendCmd(mergedCmds, k.TestCommand), env)
			}
			r.addTiming(child.ID, 0, 0, time.Since(checksStart))
			if b, err := json.Marshal(k); err == nil {
				if err := r.q().SetRunChecks(ctx, store.SetRunChecksParams{ID: child.ID, Checks: b}); err != nil {
					r.Log.Warn("store checks", "run", child.ID, "err", err)
				}
			}
			r.event(ctx, child.ID, "lifecycle", map[string]any{"state": "checks", "passed": k.Passed, "ran": k.Ran, "merged": k.Merged, "branch": k.Branch})
		}
		if k.Merged {
			merged++
			mergedCmds = appendCmd(mergedCmds, k.TestCommand)
		}
		report.WriteString("\n\n")
		if len(ended) > 1 {
			handle := child.AgentID.String()
			if a, err := r.q().GetAgent(ctx, store.GetAgentParams{ID: child.AgentID, WorkspaceID: child.WorkspaceID}); err == nil {
				handle = "@" + a.Handle
			}
			report.WriteString("---\n\n# " + handle + " (run " + runs.ShortRunID(child.ID) + ", " + child.State + ")\n\n")
		}
		report.WriteString(k.Report())
	}
	return report.String()
}

func appendCmd(cmds []string, cmd string) []string {
	if cmd == "" || slices.Contains(cmds, cmd) {
		return cmds
	}
	return append(slices.Clone(cmds), cmd)
}

// integrate runs the test commands of every delegated run merged so far in
// this report on the parent's merged checkout, after child's merge. The tree
// was green before it, so a failure is child's: its merge is undone, as long as
// HEAD is still that merge commit.
func (r *Runner) integrate(ctx context.Context, ws string, child store.Run, k *runs.Checks, cmds []string, env map[string]string) {
	if len(cmds) == 0 {
		return
	}
	for _, cmd := range cmds {
		tctx, cancel := context.WithTimeout(ctx, testCheckTimeout)
		out, code, err := r.execIn(tctx, ws, "", "lazyagents-integration-"+child.ID.String(), cmd, env)
		timedOut := tctx.Err() != nil
		cancel()
		if err == nil && !timedOut && code == 0 {
			continue
		}
		k.Integration = "failed"
		k.IntegrationCommand = cmd
		if timedOut {
			out += "\n(timed out)"
		}
		k.IntegrationTail = lastLines(redact(out, env), 40)
		r.undoMerge(ctx, ws, child, k, env)
		return
	}
	k.Integration = "passed"
}

// undoMerge resets the parent's branch to before child's merge commit, only
// when HEAD is that merge (second parent child's checked commit).
func (r *Runner) undoMerge(ctx context.Context, ws string, child store.Run, k *runs.Checks, env map[string]string) {
	defer r.wtLock(ws)()
	script := `[ "$(git rev-parse -q --verify HEAD^2)" = ` + shellQuote(k.HeadSHA) + ` ] || { echo NOT_HEAD; exit 1; }
git reset -q --hard HEAD^`
	mctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	out, code, err := r.execIn(mctx, ws, "", "lazyagents-unmerge-"+child.ID.String(), script, env)
	if err != nil || code != 0 {
		if strings.Contains(out, "NOT_HEAD") {
			k.MergeNote = "Its merge was kept: `" + k.IntegrationCommand + "` failed once combined with the other delegated runs' changes, but your branch has moved past the merge, so it wasn't undone."
		} else {
			k.MergeNote = "Its merge was kept: `" + k.IntegrationCommand + "` failed once combined with the other delegated runs' changes, and undoing the merge failed: " + lastLines(strings.TrimSpace(redact(out, env)), 8)
		}
		return
	}
	k.Merged = false
	k.MergeNote = "It merged cleanly, but `" + k.IntegrationCommand + "` failed once combined with the other delegated runs' changes, so the merge was undone."
}

// checkoutSection tells a delegated run's first turn exactly where its worktree
// stands: its HEAD and branch, the ticket's whole change as a diff range and,
// for a continued run, the commits the main agent's branch gained since the
// sub agent's previous run. A git query that fails omits its part.
func (r *Runner) checkoutSection(ctx context.Context, c runCtx, env map[string]string) string {
	var contract runs.Contract
	if len(c.run.Contract) == 0 || json.Unmarshal(c.run.Contract, &contract) != nil || contract.Worktree == "" || contract.BaseSHA == "" {
		return ""
	}
	ws, dir, name := wsID(c.run), contract.Worktree, "lazyagents-checkout-"+c.run.ID.String()
	git := func(script string) string { return r.gitOut(ctx, ws, dir, name, script, env) }
	head := contract.BaseSHA
	var b strings.Builder
	b.WriteString("\n\n## Checkout\n\nYou are at `" + head + "` on branch `" + contract.Branch + "`.")
	var bases []string
	if c.spec.Repository != nil && c.spec.Repository.EpicBranch != "" {
		bases = append(bases, "origin/"+c.spec.Repository.EpicBranch)
	}
	if c.project.DefaultBranch != "" {
		bases = append(bases, "origin/"+c.project.DefaultBranch, c.project.DefaultBranch)
	}
	for _, ref := range bases {
		fork := git("git rev-parse -q --verify " + shellQuote(ref+"^{commit}") + " >/dev/null && git merge-base " + shellQuote(ref) + " HEAD")
		if fork == "" {
			continue
		}
		b.WriteString("\n\nThe ticket's whole change (against `" + ref + "`) is `git diff " + fork + "..HEAD`")
		if stat := git("git diff --stat " + shellQuote(fork) + " HEAD"); stat != "" {
			b.WriteString(":\n\n```\n" + lastLines(stat, 40) + "\n```")
		} else {
			b.WriteString(".")
		}
		break
	}
	if contract.ContinueRunID != "" && contract.PrevHeadSHA != "" {
		prev := contract.PrevHeadSHA
		switch {
		case contract.Diverged:
			b.WriteString("\n\nYour branch has commits the main agent's branch doesn't, so it was not fast-forwarded")
			if pb := r.gitOut(ctx, ws, "", name, "git rev-parse HEAD", env); pb != "" {
				b.WriteString("; the main agent's branch is at `" + pb + "`")
			}
			b.WriteString(".")
		case prev == head:
			b.WriteString("\n\nThe main agent's branch has not changed since your previous run.")
		default:
			rng := shellQuote(prev + ".." + head)
			b.WriteString("\n\nSince your previous run the main agent's branch moved `" + prev + ".." + head + "`:")
			if log := git("git log --oneline -20 " + rng); log != "" {
				b.WriteString("\n\n```\n" + log + "\n```")
			}
			if stat := git("git diff --stat " + rng); stat != "" {
				b.WriteString("\n\n```\n" + lastLines(stat, 40) + "\n```")
			}
			b.WriteString("\n\nReview exactly this range.")
		}
	}
	return b.String()
}

func isDone(state string) bool {
	return state == "completed" || state == "failed" || state == "cancelled"
}

// gitOut runs a one-line git query and returns its trimmed output, "" on failure.
func (r *Runner) gitOut(ctx context.Context, ws, dir, name, script string, env map[string]string) string {
	cctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	out, code, err := r.execIn(cctx, ws, dir, name, script, env)
	if err != nil || code != 0 {
		return ""
	}
	return strings.TrimSpace(out)
}

// checkChild measures a delegated run's result in its worktree: uncommitted
// files, what its branch changed against the parent's branch, allowed paths
// and the test command.
func (r *Runner) checkChild(ctx context.Context, child store.Run, contract runs.Contract, parentBranch string, env map[string]string) runs.Checks {
	k := runs.Checks{ChildState: child.State, TestCommand: contract.TestCommand, Branch: contract.Branch, Bounces: contract.Bounces}
	if contract.Worktree == "" {
		k.Error = "the delegated run never got a worktree (it didn't start), so there is nothing to check"
		k.Evaluate(contract)
		return k
	}
	ws, dir := wsID(child), contract.Worktree
	git := func(script string) (string, bool) {
		cctx, cancel := context.WithTimeout(ctx, checkTimeout)
		defer cancel()
		out, code, err := r.execIn(cctx, ws, dir, "lazyagents-check-"+child.ID.String(), script, env)
		return out, err == nil && code == 0
	}
	head, ok := git("git rev-parse HEAD")
	if !ok {
		k.Error = "git HEAD could not be determined"
		k.Evaluate(contract)
		return k
	}
	k.HeadSHA = strings.TrimSpace(head)
	status, ok := git("git status --porcelain")
	if !ok {
		k.Error = "git status failed in the worktree"
		k.Evaluate(contract)
		return k
	}
	k.Uncommitted = parseStatus(status)
	// What the branch would add to the parent's: everything since it forked from it.
	base := ""
	if parentBranch != "" {
		base, _ = git("git merge-base " + shellQuote(parentBranch) + " " + shellQuote(k.HeadSHA))
		base = strings.TrimSpace(base)
	}
	if base == "" {
		k.Error = "the branch's fork point from the main agent's branch couldn't be found, so committed changes can't be listed"
	} else {
		k.BaseSHA = base
		names, ok := git("git diff --name-only " + shellQuote(base) + " " + shellQuote(k.HeadSHA))
		if !ok {
			k.Error = "git diff against the fork point failed"
		} else {
			for _, f := range strings.Split(strings.TrimSpace(names), "\n") {
				if f != "" {
					k.ChangedFiles = append(k.ChangedFiles, f)
				}
			}
			k.DiffStat, _ = git("git diff --stat " + shellQuote(base) + " " + shellQuote(k.HeadSHA))
			k.DiffStat = lastLines(strings.TrimSpace(k.DiffStat), 40)
		}
	}
	k.Ran = true
	if contract.TestCommand != "" {
		tctx, cancel := context.WithTimeout(ctx, testCheckTimeout)
		out, code, err := r.execIn(tctx, ws, dir, "lazyagents-test-"+child.ID.String(), contract.TestCommand, env)
		timedOut := tctx.Err() != nil
		cancel()
		if err == nil && !timedOut {
			k.TestExit = &code
		}
		k.TestTail = lastLines(redact(out, env), 40)
	}
	if contract.ReproCommand != "" {
		// A reviewer's failing tests: they must fail here to demonstrate its findings.
		k.ReproCommand = contract.ReproCommand
		k.ReproExit, k.ReproTail = r.runTimed(ctx, ws, dir, "lazyagents-repro-"+child.ID.String(), contract.ReproCommand, env)
	}
	k.Evaluate(contract)
	return k
}

// runTimed runs a test-like command with testCheckTimeout and returns its exit
// code (nil when it didn't finish) and the tail of its output.
func (r *Runner) runTimed(ctx context.Context, ws, dir, name, cmd string, env map[string]string) (*int, string) {
	tctx, cancel := context.WithTimeout(ctx, testCheckTimeout)
	defer cancel()
	out, code, err := r.execIn(tctx, ws, dir, name, cmd, env)
	if tctx.Err() != nil {
		out += "\n(timed out)"
	}
	tail := lastLines(redact(out, env), 40)
	if err != nil || tctx.Err() != nil {
		return nil, tail
	}
	return &code, tail
}

// recheckReport runs the repro_command of each review the main agent asked to
// recheck (recheck_review) in its checkout, stores the result on the review's
// checks and returns the "## Review recheck" sections. A turn retried after a
// crash reports the result stored for it instead of running again.
func (r *Runner) recheckReport(ctx context.Context, parent runCtx, kids []store.Run, env map[string]string, turn int) string {
	ws := wsID(parent.run)
	var b strings.Builder
	for _, child := range kids {
		var k runs.Checks
		if len(child.Checks) == 0 || json.Unmarshal(child.Checks, &k) != nil {
			continue
		}
		if !k.RecheckRequested && k.RecheckTurn != turn {
			continue
		}
		var contract runs.Contract
		_ = json.Unmarshal(child.Contract, &contract)
		if k.RecheckRequested {
			k.RecheckRequested, k.RecheckTurn = false, turn
			name := "lazyagents-recheck-" + child.ID.String()
			k.RecheckSHA = r.gitOut(ctx, ws, "", name, "git rev-parse HEAD", env)
			k.RecheckExit, k.RecheckTail, k.RecheckNote, k.ReproFixed = nil, "", "", false
			// The result is recorded for RecheckSHA, so it must be what ran, and
			// the reviewer's tests must be the ones it committed.
			status, _, serr := r.execIn(ctx, ws, "", name, "git status --porcelain", env)
			dirty := parseStatus(status)
			switch {
			case serr != nil || k.RecheckSHA == "":
				k.RecheckNote = "Your checkout's git state couldn't be read, so the tests weren't run."
			case len(dirty) > 0:
				k.RecheckNote = "Your checkout has uncommitted changes (" + strings.Join(dirty, ", ") + "), so the tests weren't run. Commit them, then call recheck_review again."
			case len(k.ChangedFiles) > 0 && k.HeadSHA != "" && r.gitOut(ctx, ws, "", name, "git diff --quiet "+shellQuote(k.HeadSHA)+" HEAD -- "+strings.Join(quoteAll(k.ChangedFiles), " ")+" && echo same", env) != "same":
				k.RecheckNote = "The reviewer's test files differ from what it committed (`git diff " + k.HeadSHA + " HEAD -- " + strings.Join(k.ChangedFiles, " ") + "`), so a passing run wouldn't verify its findings. Restore them, or delegate a re-review."
			default:
				k.RecheckExit, k.RecheckTail = r.runTimed(ctx, ws, "", name, k.ReproCommand, env)
				k.ReproFixed = k.RecheckExit != nil && *k.RecheckExit == 0
			}
			if raw, err := json.Marshal(k); err == nil {
				if err := r.q().SetRunChecks(ctx, store.SetRunChecksParams{ID: child.ID, Checks: raw}); err != nil {
					r.Log.Warn("store recheck", "run", child.ID, "err", err)
				}
			}
			r.event(ctx, child.ID, "lifecycle", map[string]any{"state": "recheck", "fixed": k.ReproFixed, "head": k.RecheckSHA})
		}
		b.WriteString("\n\n" + k.RecheckReport(child.ID.String(), contract.ReproCoversAll))
	}
	return b.String()
}

// gitBrief lists the run's git state for a fresh session: the branch,
// uncommitted files, and the commits and diff stat since it forked from
// origin/<epic or default branch>. Each part is left out when its command fails.
func (r *Runner) gitBrief(ctx context.Context, c runCtx, env map[string]string) string {
	ws, dir, name := wsID(c.run), childDir(c.run), "lazyagents-brief-"+c.run.ID.String()
	git := func(script string) (string, bool) {
		cctx, cancel := context.WithTimeout(ctx, checkTimeout)
		defer cancel()
		out, code, err := r.execIn(cctx, ws, dir, name, script, env)
		return strings.TrimSpace(out), err == nil && code == 0
	}
	var b strings.Builder
	if branch, ok := git("git symbolic-ref --short HEAD"); ok && branch != "" {
		b.WriteString("Branch: " + branch + "\n")
	}
	if status, ok := git("git status --porcelain"); ok {
		if files := parseStatus(status); len(files) > 0 {
			b.WriteString("Uncommitted files: " + strings.Join(files, ", ") + "\n")
		} else {
			b.WriteString("Uncommitted files: none\n")
		}
	}
	upstream := ""
	if c.spec.Repository != nil {
		upstream = cmp.Or(c.spec.Repository.EpicBranch, c.spec.Repository.DefaultBranch)
	}
	if upstream == "" {
		upstream = c.project.DefaultBranch
	}
	if upstream != "" {
		ref := "origin/" + upstream
		if base, ok := git("git merge-base " + shellQuote(ref) + " HEAD"); ok && base != "" {
			if log, ok := git("git log --oneline -20 " + shellQuote(base) + "..HEAD"); ok {
				b.WriteString("\nCommits since " + ref + ":\n" + cmp.Or(log, "(none)") + "\n")
			}
			if stat, ok := git("git diff --stat " + shellQuote(base) + "..HEAD"); ok && stat != "" {
				b.WriteString("\nDiff stat since " + ref + ":\n" + lastLines(stat, 40) + "\n")
			}
		}
	}
	if b.Len() == 0 {
		return ""
	}
	return "## Git\n\n" + b.String()
}

// tickChecks leases each delegated run that called complete_run and waits on
// its checks (runs.completeChild), once its process has exited, and checks it
// in a goroutine while slots last.
func (r *Runner) tickChecks(ctx context.Context) {
	for r.slot() {
		token, expires := uuid.New(), time.Now().Add(executionTTL)
		claimCtx, cancel := context.WithTimeout(ctx, controlTimeout)
		run, err := r.q().ClaimChecksRun(claimCtx, store.ClaimChecksRunParams{RunnerID: &r.Cfg.ID, ExecutionToken: &token, ExecutionExpiresAt: &expires})
		cancel()
		if err != nil {
			r.mu.Lock()
			r.active--
			r.mu.Unlock()
			if !errors.Is(err, pgx.ErrNoRows) && ctx.Err() == nil {
				r.Log.Error("claim delegated run checks", "err", err)
			}
			return
		}
		r.wg.Add(1)
		go func() {
			defer r.release()
			r.execute(ctx, run.ID, false, run.ExecutionToken, run.ExecutionExpiresAt, func(ctx context.Context) { r.checkCompleted(ctx, run) })
		}()
	}
}

// checkCompleted checks a delegated run that waits on its checks in its
// worktree, with its parent's secrets as delegationReport would. A pass
// completes it and wakes the parent; a mechanical failure with bounces left
// goes back to the sub agent's session; anything else completes it with the
// failing checks. The parent's branch only changes when it reports and merges.
func (r *Runner) checkCompleted(ctx context.Context, child store.Run) {
	log := r.Log.With("run", child.ID)
	env, err := r.parentEnv(ctx, child)
	if err != nil {
		// Don't retry forever: complete it unchecked, and the parent's report
		// checks it when it wakes, as for a run with nothing checked early.
		log.Warn("can't check a delegated run at completion; leaving it to the report", "err", err)
		if err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
			q := store.New(tx)
			if err := verifyExecution(ctx, q, child.ID); err != nil {
				return err
			}
			_, err := runs.FinishCheckedChild(ctx, q, child.ID, nil)
			return err
		}); err != nil && ctx.Err() == nil {
			log.Error("complete unchecked delegated run", "err", err)
		}
		return
	}
	var contract runs.Contract
	_ = json.Unmarshal(child.Contract, &contract)
	start := time.Now()
	parentBranch := r.gitOut(ctx, wsID(child), "", "lazyagents-branch-"+child.ID.String(), "git symbolic-ref --short HEAD", env)
	done := child
	done.State = "completed" // what it will be once the checks let it
	k := r.checkChild(ctx, done, contract, parentBranch, env)
	if ctx.Err() != nil {
		return // the lease was lost or the runner is stopping: checked again later
	}
	r.addTiming(child.ID, 0, 0, time.Since(start))
	bounce := k.Bounceable(contract.Verdict != "") && contract.Bounces < runs.MaxCheckBounces
	settled := false
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if err := verifyExecution(ctx, q, child.ID); err != nil {
			return err
		}
		if bounce {
			ok, err := runs.BounceChild(ctx, q, child.ID, k.BounceMessage(contract.Bounces+1, runs.MaxCheckBounces))
			settled = ok
			return err
		}
		var raw []byte
		if k.Ran { // otherwise delegationReport tries again when it reports
			if raw, err = json.Marshal(k); err != nil {
				return err
			}
		}
		ok, err := runs.FinishCheckedChild(ctx, q, child.ID, raw)
		settled = ok
		return err
	})
	if err != nil {
		if ctx.Err() == nil {
			log.Error("settle delegated run checks; retrying", "err", err)
		}
		return
	}
	if settled {
		r.event(ctx, child.ID, "lifecycle", map[string]any{"state": "checked", "passed": k.Passed, "ran": k.Ran, "bounced": bounce, "bounces": contract.Bounces})
	}
}

// parentEnv is the secrets env of a delegated run's parent, which its checks
// run with (as delegationReport's do).
func (r *Runner) parentEnv(ctx context.Context, child store.Run) (map[string]string, error) {
	parent, err := r.load(ctx, *child.ParentRunID)
	if err != nil {
		return nil, err
	}
	plan, err := PlanSecrets(ctx, r.q(), parent.run.WorkspaceID, &parent.project.ID, parent.spec)
	if err != nil {
		return nil, err
	}
	return SecretEnv(ctx, r.Secrets, parent.run.WorkspaceID, &parent.project.ID, plan)
}

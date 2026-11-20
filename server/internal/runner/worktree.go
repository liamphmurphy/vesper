package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Delegated runs work in git worktrees of the parent's checkout (see the
// runs package doc): .lazyagents/worktrees/<child run id>, on the branch
// <parent branch>--<handle>-<first 8 of the child run id>. .lazyagents/ is
// git-excluded, so worktrees never show up in the parent's status.

const worktreesDir = ".lazyagents/worktrees"

// errDirtyParent is why a delegated run can't start while the main agent has
// uncommitted work: the worktree would be cut from HEAD without it.
var errDirtyParent = errors.New("commit your work before delegating")

// wtLock serializes git work within a workspace in this runner process.
func (r *Runner) wtLock(ws string) func() {
	lock, _ := r.wtLocks.LoadOrStore(ws, &sync.Mutex{})
	mu := lock.(*sync.Mutex)
	mu.Lock()
	return mu.Unlock
}

// prepareWorktree creates (or, for a continued run, reuses) the child's
// worktree and returns its contract with Branch, Worktree and BaseSHA filled in.
func (r *Runner) prepareWorktree(ctx context.Context, c runCtx, env map[string]string) (runs.Contract, error) {
	var contract runs.Contract
	if len(c.run.Contract) > 0 {
		_ = json.Unmarshal(c.run.Contract, &contract)
	}
	ws := wsID(c.run)
	unlock := r.wtLock(ws)
	defer func() {
		if unlock != nil {
			unlock()
		}
	}()
	run := func(name, dir, script string) (string, error) {
		timeout := 2 * checkTimeout
		if name == "lazyagents-wt-dependencies" {
			timeout = 15 * time.Minute
		}
		cctx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		out, code, err := r.execIn(cctx, ws, dir, name+"-"+c.run.ID.String(), script, env)
		if err != nil {
			return out, err
		}
		if code != 0 {
			return out, fmt.Errorf("exit %d", code)
		}
		return strings.TrimSpace(out), nil
	}
	parentBranch, err := run("lazyagents-wt-branch", "", "git symbolic-ref --short HEAD")
	if err != nil || parentBranch == "" {
		return contract, errors.New("the main agent's checkout isn't on a branch, so a delegated run can't branch from it")
	}
	status, err := run("lazyagents-wt-status", "", "git status --porcelain")
	if err != nil {
		return contract, fmt.Errorf("couldn't read the main agent's checkout: %s", lastLines(status, 5))
	}
	if files := parseStatus(status); len(files) > 0 {
		if len(files) > 10 {
			files = append(files[:10], "…")
		}
		return contract, fmt.Errorf("%w: the checkout has uncommitted changes (%s)", errDirtyParent, strings.Join(files, ", "))
	}
	if contract.Worktree == "" {
		contract.Worktree = worktreesDir + "/" + c.run.ID.String()
		contract.Branch = fmt.Sprintf("%s--%s-%s", parentBranch, c.agent.Handle, runs.ShortRunID(c.run.ID))
	}
	wt, br, pb := shellQuote(contract.Worktree), shellQuote(contract.Branch), shellQuote(parentBranch)
	script := `set -eu
if ! git rev-parse -q --verify HEAD >/dev/null 2>&1; then git commit -q --allow-empty -m 'Initial commit'; fi
if [ ! -d ` + wt + ` ]; then
  git worktree prune
  if git show-ref -q --verify refs/heads/` + br + `; then git worktree add -q ` + wt + ` ` + br + `; else git worktree add -q -b ` + br + ` ` + wt + ` HEAD; fi
fi
cd ` + wt + `
echo "PREV $(git rev-parse HEAD)"
if git merge-base --is-ancestor HEAD ` + pb + `; then git merge -q --ff-only ` + pb + ` >/dev/null; else echo DIVERGED; fi
mkdir -p .lazyagents/context
if [ -f AGENTS.md ] && ! grep -q 'lazyagents:start' AGENTS.md; then cp AGENTS.md .lazyagents/AGENTS.repo.md; fi
if git ls-files --error-unmatch AGENTS.md >/dev/null 2>&1; then git update-index --skip-worktree AGENTS.md; fi
git rev-parse HEAD
`
	out, err := run("lazyagents-wt-add", "", script)
	if err != nil {
		return contract, fmt.Errorf("couldn't create the worktree: %s", lastLines(out, 8))
	}
	contract.BaseSHA = lastLines(out, 1)
	contract.BaseUncommitted = nil
	contract.PrevHeadSHA, contract.Diverged = "", false
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		if sha, ok := strings.CutPrefix(line, "PREV "); ok {
			contract.PrevHeadSHA = sha
		} else if line == "DIVERGED" {
			contract.Diverged = true
		}
	}
	unlock()
	unlock = nil
	output, setupErr := run("lazyagents-wt-dependencies", contract.Worktree, dependencySetupScript())
	output = r.recordEnvironment(ctx, c, output, setupErr != nil)
	if setupErr != nil {
		return contract, fmt.Errorf("environment setup failed: %s", lastLines(output, 15))
	}
	return contract, nil
}

// mergeChild merges a finished child's branch into the parent's when the child
// completed and its checks passed (or it had no contract), recording the
// outcome on k. A conflict is aborted and the branch kept.
func (r *Runner) mergeChild(ctx context.Context, ws, parentBranch string, child store.Run, contract runs.Contract, k *runs.Checks, env map[string]string) {
	if k.Merged || contract.Branch == "" {
		return
	}
	switch {
	case child.State != "completed":
		k.MergeNote = "The sub agent's run " + child.State + "."
		return
	case !contract.Empty() && !k.Passed:
		k.MergeNote = "Its automated checks failed."
		return
	case k.HeadSHA == "":
		k.MergeNote = "The checked commit could not be determined."
		return
	case parentBranch == "":
		k.MergeNote = "The main agent's branch couldn't be determined."
		return
	}
	defer r.wtLock(ws)()
	br, pb := shellQuote(k.HeadSHA), shellQuote(parentBranch)
	script := `if [ "$(git rev-list --count ` + pb + `..` + br + `)" = 0 ]; then echo 'EMPTY'; exit 0; fi
out=$(git merge --no-ff --no-edit ` + br + ` 2>&1) && { echo MERGED; exit 0; }
files=$(git diff --name-only --diff-filter=U)
git merge --abort >/dev/null 2>&1 || git reset -q --merge >/dev/null 2>&1 || true
echo CONFLICT
printf '%s\n' "$files"
echo '@@'
printf '%s\n' "$out" | tail -n 8
exit 1
`
	mctx, cancel := context.WithTimeout(ctx, 2*checkTimeout)
	defer cancel()
	out, code, err := r.execIn(mctx, ws, "", "lazyagents-merge-"+child.ID.String(), script, env)
	out = redact(out, env)
	switch {
	case err == nil && code == 0 && strings.HasPrefix(out, "MERGED"):
		k.Merged = true
	case err == nil && code == 0 && strings.HasPrefix(out, "EMPTY"):
		k.MergeNote = "It made no commits, so there was nothing to merge."
	case strings.HasPrefix(out, "CONFLICT"):
		files, detail, _ := strings.Cut(strings.TrimPrefix(out, "CONFLICT\n"), "@@\n")
		for _, f := range strings.Split(strings.TrimSpace(files), "\n") {
			if f != "" {
				k.MergeConflicts = append(k.MergeConflicts, f)
			}
		}
		k.MergeNote = "Merge conflict. " + strings.TrimSpace(detail)
		if len(k.MergeConflicts) == 0 {
			k.MergeConflicts = nil // the merge failed for another reason; the note says why
		}
	default:
		k.MergeNote = "The merge failed: " + lastLines(strings.TrimSpace(out), 8)
	}
}

// removeWorktrees deletes a finished parent's children's worktrees and the
// branches that were merged into its branch; unmerged branches stay (until the
// workspace itself goes).
func (r *Runner) removeWorktrees(ctx context.Context, parentID uuid.UUID) {
	kids, err := r.q().ChildRuns(ctx, &parentID)
	if err != nil || len(kids) == 0 {
		return
	}
	merged := map[string]bool{} // by branch; a continued run's later result wins
	var remove []string
	for _, k := range kids {
		var contract runs.Contract
		if json.Unmarshal(k.Contract, &contract) != nil || contract.Worktree == "" {
			continue
		}
		var checks runs.Checks
		_ = json.Unmarshal(k.Checks, &checks)
		merged[contract.Branch] = checks.Merged
		if !slices.Contains(remove, contract.Worktree) {
			remove = append(remove, contract.Worktree)
		}
	}
	if len(remove) == 0 {
		return
	}
	var sb strings.Builder
	for _, wt := range remove {
		sb.WriteString("git worktree remove --force " + shellQuote(wt) + " 2>/dev/null || rm -rf " + shellQuote(wt) + "\n")
	}
	sb.WriteString("git worktree prune\n")
	for br, ok := range merged {
		if ok {
			sb.WriteString("git branch -D " + shellQuote(br) + " >/dev/null 2>&1\n")
		}
	}
	sb.WriteString("true\n")
	defer r.wtLock(parentID.String())()
	cctx, cancel := context.WithTimeout(ctx, 2*checkTimeout)
	defer cancel()
	if _, _, err := r.execOnce(cctx, parentID.String(), "lazyagents-wt-clean-"+parentID.String(), sb.String(), map[string]string{}); err != nil {
		r.Log.Debug("remove worktrees", "run", parentID, "err", err)
	}
}

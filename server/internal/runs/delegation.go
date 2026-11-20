package runs

import (
	"context"
	"encoding/json"
	"fmt"
	"path"
	"slices"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// Delegation (docs/dev/plan.md §6.8). Main agents take tickets; sub agents only run
// when a main agent hands them part of a ticket. A delegated run is a child of
// the main agent's run: same ticket, but it works in its own git worktree
// (inside the parent's workspace) on its own branch cut from the parent's
// HEAD. The parent waits (wait_reason "delegation"); up to MaxParallelDelegations
// children run at once as long as their allowed_paths are disjoint. When the
// last active child ends the runner checks each finished child in its
// worktree, merges the ones that passed into the parent's branch, and resumes
// the parent once with a report covering all of them. A child can continue an
// earlier child's worktree, branch and harness session (continue_run_id).

const (
	VerbDelegated = "delegated" // {run_id, child_run_id, agent_id, agent_name, task}

	// MaxDelegations bounds the delegated runs under one parent run.
	MaxDelegations = 8
	// MaxParallelDelegations bounds the delegated runs of one parent that are live at once.
	MaxParallelDelegations = 3
	// MaxCheckBounces bounds the times one delegated run's mechanical check
	// failure is sent back to it before the main agent is woken with it.
	MaxCheckBounces = 2
	maxTaskRunes    = 20000
)

// Contract is what a main agent asks of a sub agent beyond the task text. The
// runner checks the result against it before waking the main agent.
type Contract struct {
	AcceptanceCriteria []string `json:"acceptance_criteria,omitempty"`
	// ReadOnly runs the copy without repo:write: it reports findings instead
	// of committing. A continued run stays read-only.
	ReadOnly bool `json:"read_only,omitempty"`
	// AllowedPaths are repo-relative files, directories (trailing "/") or
	// globs the sub agent may change. Empty means unrestricted.
	AllowedPaths []string `json:"allowed_paths,omitempty"`
	// TestCommand must exit 0 in the checkout for the result to pass.
	TestCommand string `json:"test_command,omitempty"`
	// ContinueRunID is an earlier, finished delegated run of the same parent
	// and sub agent to carry on: same worktree and branch, same harness session.
	ContinueRunID string `json:"continue_run_id,omitempty"`
	// BaseSHA is the worktree's HEAD when the sub agent started; the runner sets it.
	BaseSHA string `json:"base_sha,omitempty"`
	// BaseUncommitted is kept for old runs; a worktree starts clean, so it is empty.
	BaseUncommitted []string `json:"base_uncommitted,omitempty"`
	// Branch and Worktree (relative to the workspace) are the child's git
	// branch and worktree. The runner sets them, or they're copied from the run
	// being continued.
	Branch   string `json:"branch,omitempty"`
	Worktree string `json:"worktree,omitempty"`
	// ResumeSession is set while the run's first turn resumes the continued
	// run's harness session; the runner clears it if that session is gone.
	ResumeSession bool `json:"resume_session,omitempty"`
	// PrevHeadSHA is the worktree's HEAD before the runner fast-forwarded it to
	// the main agent's branch; for a continued run, where the sub agent last
	// stood. Diverged is set when the worktree's branch had commits the main
	// agent's didn't, so it wasn't fast-forwarded. The runner sets both.
	PrevHeadSHA string `json:"prev_head_sha,omitempty"`
	Diverged    bool   `json:"diverged,omitempty"`
	// ReproCommand is what a reviewer reported with complete_run: it runs the
	// failing tests it committed for its blocking findings. ReproCoversAll says
	// every blocking finding has one. Only completeChild sets them.
	ReproCommand   string `json:"repro_command,omitempty"`
	ReproCoversAll bool   `json:"repro_covers_all,omitempty"`
	// Bounces counts the times the server sent a mechanical check failure back
	// to the sub agent in this run (at most MaxCheckBounces). Verdict is the
	// review verdict of the complete_run still waiting on its checks. Only
	// completeChild and the runner set them.
	Bounces int    `json:"bounces,omitempty"`
	Verdict string `json:"verdict,omitempty"`
}

const (
	maxContractItems = 20
	maxContractRunes = 500
)

// Normalize trims the contract and rejects what can't be checked or rendered.
func (c Contract) Normalize() (Contract, error) {
	clean := func(field string, in []string) ([]string, error) {
		var out []string
		for _, v := range in {
			if v = strings.TrimSpace(v); v != "" {
				if len([]rune(v)) > maxContractRunes {
					return nil, apperr.Invalid(field, "each entry must be at most %d characters", maxContractRunes)
				}
				out = append(out, v)
			}
		}
		if len(out) > maxContractItems {
			return nil, apperr.Invalid(field, "at most %d entries", maxContractItems)
		}
		return out, nil
	}
	var err error
	if c.AcceptanceCriteria, err = clean("acceptance_criteria", c.AcceptanceCriteria); err != nil {
		return c, err
	}
	if c.AllowedPaths, err = clean("allowed_paths", c.AllowedPaths); err != nil {
		return c, err
	}
	for _, p := range c.AllowedPaths {
		if strings.HasPrefix(p, "/") || strings.Contains(p, "..") {
			return c, apperr.Invalid("allowed_paths", "%q must be a repo-relative path without ..", p)
		}
		if _, err := path.Match(p, "x"); err != nil {
			return c, apperr.Invalid("allowed_paths", "%q is not a valid glob", p)
		}
	}
	if c.TestCommand = strings.TrimSpace(c.TestCommand); len([]rune(c.TestCommand)) > maxContractRunes {
		return c, apperr.Invalid("test_command", "must be at most %d characters", maxContractRunes)
	}
	if c.ContinueRunID = strings.TrimSpace(c.ContinueRunID); c.ContinueRunID != "" {
		if _, err := uuid.Parse(c.ContinueRunID); err != nil {
			return c, apperr.Invalid("continue_run_id", "%q isn't a run id", c.ContinueRunID)
		}
	}
	c.BaseSHA, c.BaseUncommitted, c.Branch, c.Worktree, c.ResumeSession = "", nil, "", "", false
	c.PrevHeadSHA, c.Diverged = "", false
	c.ReproCommand, c.ReproCoversAll = "", false
	c.Bounces, c.Verdict = 0, ""
	return c, nil
}

// region is the part of the repository an allowed path claims: the path itself
// or, for a glob, the directory it is confined under ("" = anywhere, as for a
// glob without a "/", which matches base names in any directory).
func region(p string) string {
	p = strings.TrimSuffix(strings.TrimPrefix(p, "./"), "/")
	if !strings.ContainsAny(p, "*?[") {
		return p
	}
	var dir []string
	for _, el := range strings.Split(p, "/") {
		if strings.ContainsAny(el, "*?[") {
			break
		}
		dir = append(dir, el)
	}
	return strings.Join(dir, "/")
}

// PathsOverlap reports whether two sets of allowed paths might touch the same
// file. It is conservative: equal paths, one inside the other's directory, and
// globs (judged by the directory they're confined under, or anywhere if none)
// all count as overlapping.
func PathsOverlap(a, b []string) bool {
	for _, x := range a {
		rx := region(x)
		for _, y := range b {
			ry := region(y)
			if rx == "" || ry == "" || rx == ry || strings.HasPrefix(rx, ry+"/") || strings.HasPrefix(ry, rx+"/") {
				return true
			}
		}
	}
	return false
}

// Empty reports whether the contract adds nothing to the task.
func (c Contract) Empty() bool {
	return len(c.AcceptanceCriteria) == 0 && len(c.AllowedPaths) == 0 && c.TestCommand == "" && c.ReproCommand == ""
}

// PathAllowed reports whether a changed file is inside the contract's
// boundaries. A pattern matches a file exactly, as a directory prefix
// ("internal/runs/" or "internal/runs"), or as a path.Match glob on the whole
// path. A glob without a "/" ("*_test.go") also matches the file's base name,
// and a leading "**/" matches any directory ("**/testdata/*.json"). A plain
// name without a "/" ("go.mod") stays the file or directory at the root.
func (c Contract) PathAllowed(file string) bool {
	if len(c.AllowedPaths) == 0 {
		return true
	}
	file = strings.TrimPrefix(file, "./")
	for _, p := range c.AllowedPaths {
		p = strings.TrimPrefix(p, "./")
		if file == p || strings.HasPrefix(file, strings.TrimSuffix(p, "/")+"/") {
			return true
		}
		if globMatch(p, file) {
			return true
		}
	}
	return false
}

// globMatch is path.Match with the two extensions PathAllowed documents.
func globMatch(p, file string) bool {
	if rest, ok := strings.CutPrefix(p, "**/"); ok {
		for i := 0; i < len(file); i++ {
			if (i == 0 || file[i-1] == '/') && globMatch(rest, file[i:]) {
				return true
			}
		}
		return false
	}
	if ok, _ := path.Match(p, file); ok {
		return true
	}
	if !strings.Contains(p, "/") && strings.ContainsAny(p, "*?[") {
		ok, _ := path.Match(p, path.Base(file))
		return ok
	}
	return false
}

// ChildPrompt is the first message of a delegated run. canWrite is whether the
// sub agent may change files (repo:write allowed).
func ChildPrompt(ticket, parentHandle, task string, contract Contract, canWrite bool) string {
	p := "@" + parentHandle + " delegated part of " + ticket + " to you. You work in your own git worktree on your own branch, cut from the main agent's; " +
		"other sub agents may be working in parallel in theirs, so stay inside your task and do only what it says. "
	if canWrite {
		p += "AGENTS.md says how to commit and finish."
	} else {
		p += "You can't change files in this run (repo:write is not allowed): don't try to write notes or fixes, report them with complete_run."
	}
	if contract.ContinueRunID != "" {
		p += " This continues your earlier run on this ticket: same worktree and branch, so your earlier work is still here. The task below is the follow-up."
	}
	p += "\n\n## Task\n\n" + task
	if len(contract.AcceptanceCriteria) > 0 {
		p += "\n\n## Acceptance criteria\n\nThe task is done only when all of these hold:\n"
		for _, a := range contract.AcceptanceCriteria {
			p += "- " + a + "\n"
		}
	}
	if len(contract.AllowedPaths) > 0 {
		p += "\n\n## Allowed files\n\nChange only these paths. The server rejects work that touches anything else; if the task needs more, say so in complete_run instead:\n"
		for _, a := range contract.AllowedPaths {
			p += "- " + a + "\n"
		}
	}
	if contract.TestCommand != "" {
		p += "\n\n## Tests\n\nThis must exit 0 before you finish (the server runs it again after you): `" + contract.TestCommand + "`\n"
	}
	return strings.TrimRight(p, "\n")
}

type Delegation struct {
	Run   store.Run
	Agent store.Agent
	// ReadOnly: the copy can't change files (repo:write isn't allowed).
	ReadOnly bool
}

// Delegate starts a fresh copy of the caller (its persona and the run's
// frozen spec) on a task under the caller's run, and parks the caller until
// it finishes.
func (s *Service) Delegate(ctx context.Context, c Caller, ticketKey, task string) (Delegation, error) {
	return s.DelegateWithContract(ctx, c, ticketKey, task, Contract{})
}

// DelegateWithContract is Delegate with acceptance criteria, file boundaries,
// a test command the runner checks the result against, and read-only reviews.
func (s *Service) DelegateWithContract(ctx context.Context, c Caller, ticketKey, task string, contract Contract) (Delegation, error) {
	var out Delegation
	task = strings.TrimSpace(task)
	if task == "" {
		return out, apperr.Invalid("task", "say what the sub agent should do, with enough context to work alone")
	}
	if len([]rune(task)) > maxTaskRunes {
		return out, apperr.Invalid("task", "must be at most %d characters", maxTaskRunes)
	}
	contract, err := contract.Normalize()
	if err != nil {
		return out, err
	}
	err = s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.delegating(ctx, q, c, ticketKey)
		if err != nil {
			return err
		}
		// Match tracker/dispatch ordering. Child cancellation may already hold a
		// ticket FK lock when it wakes this parent; never hold the parent while
		// waiting for a project locked by a ticket patch.
		p, err := q.LockProject(ctx, store.LockProjectParams{ID: t.ProjectID, WorkspaceID: run.WorkspaceID})
		if err != nil {
			return err
		}
		// Serialise a parent's delegate calls (an agent may issue several at once):
		// the limits below read the other children.
		if run, err = q.LockRun(ctx, run.ID); err != nil {
			return err
		}
		if run.State != "running" && !(run.State == "waiting" && deref(run.WaitReason) == "delegation") {
			return apperr.Conflict("your run is no longer running")
		}
		if _, t, err = s.delegating(ctx, q, c, ticketKey); err != nil {
			return err
		}
		turns, err := q.ListTurns(ctx, run.ID)
		if err != nil {
			return err
		}
		for _, turn := range turns {
			if turn.Status == "pending" && turn.Trigger == "delegation" {
				return apperr.Conflict("your delegated runs already finished; end your turn to read their report")
			}
		}
		if run.ParentRunID != nil {
			return apperr.Conflict("a delegated run can't delegate further")
		}
		if run.Mode != "managed" || run.WorkspaceVolume == nil {
			return apperr.Conflict("delegating needs a managed run with a ready workspace; unmanaged sessions can't delegate")
		}
		ws := run.WorkspaceID
		kids, err := q.ChildRuns(ctx, &run.ID)
		if err != nil {
			return err
		}
		if len(kids) >= MaxDelegations {
			return apperr.Conflict("this run has already delegated %d times; finish the rest yourself or hand back with complete_run", len(kids))
		}
		prev, err := continuedRun(contract, kids)
		if err != nil {
			return err
		}
		if prev != nil {
			var pc Contract
			_ = json.Unmarshal(prev.Contract, &pc)
			contract.Branch, contract.Worktree = pc.Branch, pc.Worktree
			contract.ReadOnly = contract.ReadOnly || pc.ReadOnly
		}
		if err := checkParallel(kids, contract); err != nil {
			return err
		}
		// The copy runs on the caller's frozen spec, so it has the same
		// harness, model, instructions and scopes as the run it helps.
		resolved, err := Spec(run)
		if err != nil {
			return err
		}
		if contract.ReadOnly {
			resolved = withoutRepoWrite(resolved)
		}
		canWrite := resolved.Mode("repo:write") == agentdef.Allowed
		if !canWrite && len(contract.AllowedPaths) > 0 {
			return apperr.Invalid("allowed_paths", "the copy can't change files (repo:write is %s), so allowed_paths has nothing to bound; drop it and ask for findings in its report", resolved.Mode("repo:write"))
		}
		// The child inherits the ticket's epic context so an epic ticket's
		// children also leave the full suite to the epic review.
		if resolved.Repository, err = RepositoryFor(ctx, q, p, t); err != nil {
			return err
		}
		resolved.Repository.EpicTickets = nil
		raw, err := json.Marshal(resolved)
		if err != nil {
			return err
		}
		child, err := q.CreateRun(ctx, store.CreateRunParams{
			WorkspaceID: ws, TicketID: &t.ID, AgentID: c.Agent.ID, Mode: "managed", State: "queued",
			ResolvedSpec: raw, DefinitionVersionID: run.DefinitionVersionID, Harness: resolved.Harness, Model: resolved.Model, Purpose: "ticket",
			ParentRunID: &run.ID,
		})
		if err != nil {
			return err
		}
		if run.DispatchedByUserID != nil {
			if err := q.SetRunDispatcher(ctx, store.SetRunDispatcherParams{ID: child.ID, DispatchedByUserID: run.DispatchedByUserID}); err != nil {
				return err
			}
		}
		if _, err := q.StartTurn(ctx, store.StartTurnParams{RunID: child.ID, Trigger: "start", InputMessage: ChildPrompt(t.Key, c.Agent.Handle, task, contract, canWrite)}); err != nil {
			return err
		}
		if prev != nil && prev.Harness == child.Harness && prev.HarnessSessionID != nil {
			// Same harness: the first turn resumes the earlier run's conversation.
			if err := q.SetRunSession(ctx, store.SetRunSessionParams{ID: child.ID, HarnessSessionID: prev.HarnessSessionID}); err != nil {
				return err
			}
			contract.ResumeSession = true
		}
		if !contract.Empty() || contract.ReadOnly || prev != nil {
			raw, err := json.Marshal(contract)
			if err != nil {
				return err
			}
			if child, err = q.SetRunContract(ctx, store.SetRunContractParams{ID: child.ID, Contract: raw}); err != nil {
				return err
			}
		}
		if err := event(ctx, q, child.ID, "lifecycle", map[string]any{"state": "queued", "mode": "managed", "parent_run_id": run.ID, "delegated_by": c.Agent.Handle}); err != nil {
			return err
		}
		if run.State == "running" { // the first delegation of a turn parks the parent; later ones find it parked
			wait := "delegation"
			if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &wait}); err != nil {
				return err
			}
			if err := q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
				return err
			}
		}
		if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "waiting", "reason": "delegation", "child_run_id": child.ID, "agent": c.Agent.Handle}); err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, ws, t.ID, t.EpicID, agentActor(c), VerbDelegated, map[string]any{
			"run_id": run.ID, "child_run_id": child.ID, "agent_id": c.Agent.ID, "agent_name": c.Agent.Name, "task": truncate(task, 300), "has_contract": !contract.Empty(), "continues": contract.ContinueRunID,
		}, nil); err != nil {
			return err
		}
		if err := RecomputeAgentStatus(ctx, q, c.Agent.ID); err != nil {
			return err
		}
		out = Delegation{Run: child, Agent: c.Agent, ReadOnly: !canWrite}
		return nil
	})
	return out, err
}

// delegating is running, except that a parent parked by an earlier delegate
// call of the same turn (its harness process is still going) may delegate again.
func (s *Service) delegating(ctx context.Context, q *store.Queries, c Caller, key string) (store.Run, store.Ticket, error) {
	run, t, err := s.Active(ctx, q, c, key)
	if err == nil && run.State == "waiting" && deref(run.WaitReason) == "delegation" {
		turns, lerr := q.ListTurns(ctx, run.ID)
		if lerr != nil {
			return run, t, lerr
		}
		for _, tn := range turns {
			if tn.Status == "running" {
				return run, t, nil
			}
		}
	}
	return s.running(ctx, q, c, key)
}

// ShortRunID names a delegated run in branch names and reports. It's the
// UUIDv7's random tail: its first characters are a timestamp that changes
// about once a minute, so parallel copies of one agent would share them.
func ShortRunID(id uuid.UUID) string {
	s := id.String()
	return s[len(s)-8:]
}

// withoutRepoWrite is spec with repo:write denied, for a read-only copy. The
// strictest matching entry wins, so a denied entry also beats a repo:* grant.
func withoutRepoWrite(spec agentdef.Resolved) agentdef.Resolved {
	spec.Scopes = slices.DeleteFunc(slices.Clone(spec.Scopes), func(s agentdef.ResolvedScope) bool { return s.Scope == "repo:write" })
	spec.Scopes = append(spec.Scopes, agentdef.ResolvedScope{Scope: "repo:write", Mode: agentdef.Denied, Source: agentdef.FromDelegation})
	return spec
}

// continuedRun resolves contract.ContinueRunID: a finished delegated run of
// this parent that no later run has already taken over.
func continuedRun(contract Contract, kids []store.Run) (*store.Run, error) {
	if contract.ContinueRunID == "" {
		return nil, nil
	}
	var prev *store.Run
	at := 0
	for i := range kids {
		if kids[i].ID.String() == contract.ContinueRunID {
			prev, at = &kids[i], i
		}
	}
	switch {
	case prev == nil:
		return nil, apperr.Invalid("continue_run_id", "%s isn't a delegated run of this run; use the run_id delegate returned", contract.ContinueRunID)
	case !slices.Contains(Terminal, prev.State):
		return nil, apperr.Invalid("continue_run_id", "that run is still in progress; wait for it to finish")
	}
	if !reported(*prev) {
		return nil, apperr.Invalid("continue_run_id", "that run hasn't been checked and merged yet; wait for your delegation report")
	}
	var pc Contract
	_ = json.Unmarshal(prev.Contract, &pc)
	if pc.Worktree == "" {
		return nil, apperr.Invalid("continue_run_id", "that run never got a worktree (it failed to start), so there is nothing to continue; delegate afresh")
	}
	for _, k := range kids[at+1:] { // children are ordered by start
		var kc Contract
		if json.Unmarshal(k.Contract, &kc) == nil && kc.Worktree == pc.Worktree {
			return nil, apperr.Invalid("continue_run_id", "run %s already continued that one; continue the latest run instead", k.ID)
		}
	}
	return prev, nil
}

// checkParallel enforces the limits on children that are live at once: at most
// MaxParallelDelegations, and once two run together both need non-empty,
// disjoint allowed_paths so their worktrees can be merged without conflicts.
func checkParallel(kids []store.Run, contract Contract) error {
	var live []store.Run
	for _, k := range kids {
		if !slices.Contains(Terminal, k.State) {
			live = append(live, k)
		}
	}
	if len(live) == 0 {
		return nil
	}
	if len(live) >= MaxParallelDelegations {
		return apperr.Conflict("%d delegated runs are already in progress (the limit); wait for them to finish before delegating more", len(live))
	}
	if len(contract.AllowedPaths) == 0 {
		return apperr.Invalid("allowed_paths", "a delegated run is already in progress, so this one needs allowed_paths that don't overlap with it; set allowed_paths or delegate sequentially")
	}
	for _, k := range live {
		var kc Contract
		_ = json.Unmarshal(k.Contract, &kc)
		if len(kc.AllowedPaths) == 0 {
			return apperr.Conflict("the delegated run %s has no allowed_paths, so it may touch anything; wait for it to finish and then delegate, or delegate sequentially", k.ID)
		}
		if PathsOverlap(kc.AllowedPaths, contract.AllowedPaths) {
			return apperr.Conflict("allowed_paths overlap with the delegated run %s in progress (%s); narrow allowed_paths so they're disjoint, or delegate sequentially", k.ID, strings.Join(kc.AllowedPaths, ", "))
		}
	}
	return nil
}

// WakeParent resumes a waiting parent once its last live delegated run has
// ended, telling it how each run that ended since it was parked went. The
// parent stays parked while any child is live, or if a person paused or
// cancelled it.
func WakeParent(ctx context.Context, q *store.Queries, child store.Run, state, outcome string) error {
	if child.ParentRunID == nil {
		return nil
	}
	parent, err := q.LockRun(ctx, *child.ParentRunID)
	if err != nil {
		return err
	}
	if parent.State != "waiting" || deref(parent.WaitReason) != "delegation" {
		return nil
	}
	msg, ok, err := delegationWakeMessage(ctx, q, parent)
	if err != nil || !ok {
		return err
	}
	return resume(ctx, q, parent, "delegation", msg)
}

// delegationWakeMessage includes every terminal child not yet reported to the parent.
func delegationWakeMessage(ctx context.Context, q *store.Queries, parent store.Run) (string, bool, error) {
	kids, err := q.ChildRuns(ctx, &parent.ID)
	if err != nil {
		return "", false, err
	}
	var ended []store.Run
	first := true // no earlier report: the parent hasn't seen the full guidance yet
	for _, k := range kids {
		if !slices.Contains(Terminal, k.State) {
			return "", false, nil
		}
		if !reported(k) {
			ended = append(ended, k)
		} else {
			first = false
		}
	}
	if len(ended) == 0 {
		return "", false, nil
	}
	line := func(k store.Run) string {
		handle := k.AgentID.String()
		if a, err := q.GetAgent(ctx, store.GetAgentParams{ID: k.AgentID, WorkspaceID: k.WorkspaceID}); err == nil {
			handle = "@" + a.Handle
		}
		o := strings.TrimSpace(deref(k.Outcome))
		if o == "" {
			o = "(no summary)"
		}
		switch k.State {
		case "completed":
			if r := strings.TrimSpace(deref(k.Report)); r != "" {
				o += "\n\n#### Report\n\n" + r
			}
			return handle + " finished the delegated task.\n\n" + o
		case "cancelled":
			return handle + "'s delegated run was cancelled: " + o
		default:
			return handle + "'s delegated run failed: " + o
		}
	}
	var msg string
	if len(ended) == 1 {
		msg = line(ended[0])
	} else {
		msg = fmt.Sprintf("%d delegated runs have ended.", len(ended))
		for i, k := range ended {
			msg += fmt.Sprintf("\n\n### %d. %s", i+1, line(k))
		}
	}
	if !first {
		return msg + "\n\nChecks and merge results follow, as before.", true, nil
	}
	msg += "\n\nThe server checks each delegated run in its worktree against its contract (changed files, allowed paths, test command) and merges the ones that passed into your branch before you resume; those results follow. " +
		"Don't repeat checks that already ran or re-read the ticket you already have. Read the diff for what they can't judge, verify the acceptance criteria, and delegate again (continue_run_id sends fixes to the same sub agent) or fix small remaining work yourself. " +
		"When every criterion is verified and checked, commit and push any changes, record the PR with set_pr, and finish with complete_run status=done (delegate a review first only if the change is risky or large)."
	return msg, true, nil
}

// RecheckReview asks the runner to run a merged review's repro_command in the
// main agent's checkout. The caller is parked as for a delegation and resumed
// at once with a "delegation" turn; the runner runs the command before that
// turn starts and appends the result. No sub agent run starts.
func (s *Service) RecheckReview(ctx context.Context, c Caller, ticketKey, childRunID string) error {
	childID, err := uuid.Parse(strings.TrimSpace(childRunID))
	if err != nil {
		return apperr.Invalid("run_id", "%q isn't a run id", childRunID)
	}
	return s.tx(ctx, func(q *store.Queries) error {
		run, _, err := s.running(ctx, q, c, ticketKey)
		if err != nil {
			return err
		}
		if run, err = q.LockRun(ctx, run.ID); err != nil {
			return err
		}
		if run.State != "running" {
			return apperr.Conflict("your run is no longer running")
		}
		if !LeadRun(run) {
			return apperr.Conflict("recheck_review is for a main agent's ticket run")
		}
		kids, err := q.ChildRuns(ctx, &run.ID)
		if err != nil {
			return err
		}
		var child *store.Run
		for i := range kids {
			if !slices.Contains(Terminal, kids[i].State) {
				return apperr.Conflict("a delegated run is still in progress; end your turn and wait for its report")
			}
			if kids[i].ID == childID {
				child = &kids[i]
			}
		}
		if child == nil {
			return apperr.Invalid("run_id", "%s isn't a delegated run of this run", childID)
		}
		var contract Contract
		var checks Checks
		_ = json.Unmarshal(child.Contract, &contract)
		_ = json.Unmarshal(child.Checks, &checks)
		switch {
		case child.State != "completed":
			return apperr.Invalid("run_id", "that run didn't complete, so it has no tests to recheck")
		case contract.ReproCommand == "":
			return apperr.Invalid("run_id", "that run didn't report a repro_command; delegate a re-review instead")
		case !checks.Merged:
			return apperr.Invalid("run_id", "that run's tests weren't merged into your branch (see its checks), so there is nothing to recheck")
		}
		turns, err := q.ListTurns(ctx, run.ID)
		if err != nil {
			return err
		}
		for _, turn := range turns {
			if turn.Status == "pending" {
				return apperr.Conflict("your next turn is already queued; end your turn")
			}
		}
		checks.RecheckRequested = true
		raw, err := json.Marshal(checks)
		if err != nil {
			return err
		}
		if err := q.SetRunChecks(ctx, store.SetRunChecksParams{ID: child.ID, Checks: raw}); err != nil {
			return err
		}
		wait := "delegation"
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &wait}); err != nil {
			return err
		}
		if err := q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
			return err
		}
		return resume(ctx, q, run, "delegation", "The server ran `"+contract.ReproCommand+"` from review run "+child.ID.String()+" on your branch; the result follows.")
	})
}

// CancelChildren ends a parent's live delegated runs (the parent was cancelled
// or failed); the runner kills their processes.
func CancelChildren(ctx context.Context, q *store.Queries, parentID uuid.UUID, reason string) error {
	kids, err := q.ChildRuns(ctx, &parentID)
	if err != nil {
		return err
	}
	for _, k := range kids {
		if slices.Contains(Terminal, k.State) {
			continue
		}
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: k.ID, State: "cancelled", Outcome: &reason}); err != nil {
			return err
		}
		_ = q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: k.ID, ExitCode: ptr[int32](143)})
		_ = q.DropPendingTurns(ctx, k.ID)
		if err := q.ExpireRunApprovals(ctx, k.ID); err != nil {
			return err
		}
		if err := event(ctx, q, k.ID, "lifecycle", map[string]any{"state": "cancelled", "reason": reason}); err != nil {
			return err
		}
		if err := RecomputeAgentStatus(ctx, q, k.AgentID); err != nil {
			return err
		}
	}
	return nil
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

// completeChild ends a delegated run: no ticket status change. A run whose
// contract has something to check, and that may still be sent back, waits on
// "checks" for the runner (FinishCheckedChild, BounceChild); any other run
// completes and its parent is resumed with the summary.
func (s *Service) completeChild(ctx context.Context, c Caller, key, outcome, report, verdict string, repro Repro) error {
	return s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		if run.ParentRunID == nil {
			return fmt.Errorf("not a delegated run")
		}
		var contract Contract
		if len(run.Contract) > 0 {
			if err := json.Unmarshal(run.Contract, &contract); err != nil {
				return err
			}
		}
		// Recorded on the contract the runner checks the result against. A
		// reviewer sent back for uncommitted files keeps its earlier repro when
		// it doesn't repeat it.
		if repro.Command != "" {
			contract.ReproCommand, contract.ReproCoversAll = repro.Command, repro.CoversAll
		}
		park := !contract.Empty() && contract.Bounces < MaxCheckBounces
		if park {
			contract.Verdict = verdict
		}
		if len(run.Contract) > 0 || repro.Command != "" {
			raw, err := json.Marshal(contract)
			if err != nil {
				return err
			}
			if run, err = q.SetRunContract(ctx, store.SetRunContractParams{ID: run.ID, Contract: raw}); err != nil {
				return err
			}
		}
		// Always written, so a continued run doesn't keep its previous report.
		var rep *string
		if report != "" {
			rep = &report
		}
		if err := q.SetRunReport(ctx, store.SetRunReportParams{ID: run.ID, Report: rep}); err != nil {
			return err
		}
		if err := q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
			return err
		}
		if err := q.ExpireRunApprovals(ctx, run.ID); err != nil {
			return err
		}
		if park {
			// The outcome is kept on the run until the checks decide.
			wait := "checks"
			if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &wait, Outcome: &outcome}); err != nil {
				return err
			}
			if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "waiting", "reason": "checks", "outcome": outcome, "attempt": contract.Bounces + 1}); err != nil {
				return err
			}
			return RecomputeAgentStatus(ctx, q, c.Agent.ID)
		}
		return finishChild(ctx, q, run, t, agentActor(c), outcome, verdict)
	})
}

// finishChild completes a delegated run and wakes its parent once its last
// live delegated run has ended.
func finishChild(ctx context.Context, q *store.Queries, run store.Run, t store.Ticket, actor tracker.Actor, outcome, verdict string) error {
	done, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "completed", Outcome: &outcome})
	if err != nil {
		return err
	}
	life := map[string]any{"state": "completed", "outcome": outcome}
	if verdict != "" {
		life["verdict"] = verdict
	}
	if err := event(ctx, q, run.ID, "lifecycle", life); err != nil {
		return err
	}
	if err := tracker.Record(ctx, q, run.WorkspaceID, t.ID, t.EpicID, actor, VerbRunCompleted, map[string]any{"run_id": run.ID, "outcome": outcome, "delegated": true, "verdict": verdict}, nil); err != nil {
		return err
	}
	if err := RecomputeAgentStatus(ctx, q, run.AgentID); err != nil {
		return err
	}
	return WakeParent(ctx, q, done, "completed", outcome)
}

// lockCheckingChild locks a delegated run waiting on its checks, after its
// parent: the order CancelChildren takes them in, the likeliest race (a parent
// cancelled during the checks). A path that locks the child first (a person
// cancelling the child) can deadlock with it; Postgres aborts one side, and
// the runner retries its checks on a later tick. ok is false when it no longer
// waits on checks, e.g. its parent was cancelled meanwhile.
func lockCheckingChild(ctx context.Context, q *store.Queries, childID uuid.UUID) (store.Run, bool, error) {
	parentID, err := q.RunParentID(ctx, childID)
	if err != nil {
		return store.Run{}, false, err
	}
	if parentID != nil {
		if _, err := q.LockRun(ctx, *parentID); err != nil {
			return store.Run{}, false, err
		}
	}
	run, err := q.LockRun(ctx, childID)
	if err != nil {
		return run, false, err
	}
	return run, run.State == "waiting" && deref(run.WaitReason) == "checks" && run.ParentRunID != nil && run.TicketID != nil, nil
}

// FinishCheckedChild completes a delegated run that waited on its checks with
// the outcome and verdict it reported, stores checks (unless nil) and wakes its
// parent. It reports false, changing nothing, when the run no longer waits.
func FinishCheckedChild(ctx context.Context, q *store.Queries, childID uuid.UUID, checks []byte) (bool, error) {
	run, ok, err := lockCheckingChild(ctx, q, childID)
	if err != nil || !ok {
		return false, err
	}
	if checks != nil {
		if err := q.SetRunChecks(ctx, store.SetRunChecksParams{ID: run.ID, Checks: checks}); err != nil {
			return false, err
		}
	}
	t, err := q.GetTicketByID(ctx, *run.TicketID)
	if err != nil {
		return false, err
	}
	var contract Contract
	_ = json.Unmarshal(run.Contract, &contract)
	return true, finishChild(ctx, q, run, t, tracker.AgentActor(run.AgentID), deref(run.Outcome), contract.Verdict)
}

// BounceChild sends a mechanical check failure back to a delegated run that
// waited on its checks: one more bounce on its contract, and a turn in the
// same harness session with input. It reports false, changing nothing, when
// the run no longer waits.
func BounceChild(ctx context.Context, q *store.Queries, childID uuid.UUID, input string) (bool, error) {
	run, ok, err := lockCheckingChild(ctx, q, childID)
	if err != nil || !ok {
		return false, err
	}
	var contract Contract
	_ = json.Unmarshal(run.Contract, &contract)
	contract.Bounces++
	contract.Verdict = ""
	raw, err := json.Marshal(contract)
	if err != nil {
		return false, err
	}
	if _, err := q.SetRunContract(ctx, store.SetRunContractParams{ID: run.ID, Contract: raw}); err != nil {
		return false, err
	}
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "running"}); err != nil {
		return false, err
	}
	if err := q.SetIdleTurns(ctx, store.SetIdleTurnsParams{ID: run.ID, IdleTurns: 0}); err != nil {
		return false, err
	}
	// A turn a crashed runner requeued would otherwise run first.
	if err := q.DropPendingTurns(ctx, run.ID); err != nil {
		return false, err
	}
	if _, err := q.StartTurn(ctx, store.StartTurnParams{RunID: run.ID, Trigger: "resume", InputMessage: input}); err != nil {
		return false, err
	}
	if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "running", "reason": "checks_bounced", "bounce": contract.Bounces}); err != nil {
		return false, err
	}
	return true, RecomputeAgentStatus(ctx, q, run.AgentID)
}

// reported says the runner has reported a delegated run's checks to its parent.
func reported(k store.Run) bool {
	var c Checks
	return len(k.Checks) > 0 && json.Unmarshal(k.Checks, &c) == nil && c.ReportedTurn != 0
}

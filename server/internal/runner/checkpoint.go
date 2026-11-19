package runner

import (
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/pushreq"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// checkpointPrefix namespaces the branches Vesper pushes on its own behalf.
const checkpointPrefix = "vesper-checkpoint/"

const (
	checkpointPushed            = "vesper-checkpoint: pushed"
	checkpointRemoteHas         = "vesper-checkpoint: remote-has"
	checkpointSHAMarker         = "vesper-checkpoint-sha "
	checkpointTreeMarker        = "vesper-checkpoint-tree "
	checkpointBranchMarker      = "vesper-checkpoint-branch "
	checkpointUncommittedMarker = "vesper-checkpoint-uncommitted "
)

type checkpointMeta struct {
	commitSHA      string
	treeSHA        string
	sourceBranch   string
	hasUncommitted bool
}

func parseCheckpointMeta(out string) checkpointMeta {
	return checkpointMeta{
		commitSHA:      markerValue(out, checkpointSHAMarker),
		treeSHA:        markerValue(out, checkpointTreeMarker),
		sourceBranch:   markerValue(out, checkpointBranchMarker),
		hasUncommitted: markerValue(out, checkpointUncommittedMarker) == "1",
	}
}

// CheckpointBranch is per run, so only that run ever writes it and a retried
// push may safely replace an earlier attempt.
func CheckpointBranch(key string, runID uuid.UUID) string {
	return checkpointPrefix + strings.ToLower(key) + "/" + runID.String()
}

// CheckpointScript pushes the workspace's unsaved work to branch: a commit of
// the working tree on top of HEAD, built with a scratch copy of the index so
// the checkout is left as it was. The copy keeps AGENTS.md's skip-worktree bit,
// so Vesper's own section is not saved. Work already on a real remote branch
// needs no checkpoint; earlier checkpoints don't count as saved, so work
// recovered from one survives another run. It prints nothing when there is
// nothing to save, and checkpointPushed after a push.
func CheckpointScript(branch string) string {
	var b strings.Builder
	b.WriteString(checkpointCommit)
	b.WriteString(`if [ "$commit" = "$(git rev-parse HEAD)" ] && [ -z "$(git rev-list -1 HEAD --not --exclude='origin/` + checkpointPrefix + `*' --remotes)" ]; then exit 0; fi` + "\n")
	b.WriteString(`if remote_heads=$(git ls-remote --heads origin 2>/dev/null) && printf '%s\n' "$remote_heads" | grep -v '[[:space:]]refs/heads/` + checkpointPrefix + `' | grep -q "^${commit}[[:space:]]"; then echo '` + checkpointRemoteHas + `'; exit 0; fi` + "\n")
	b.WriteString(`git push --quiet --no-verify origin "+$commit:refs/heads/"` + shellQuote(branch) + "\n")
	b.WriteString("echo '" + checkpointPushed + "'\n")
	return b.String()
}

// checkpointCommit sets $commit to the workspace's work as one commit: HEAD,
// or a commit of the working tree on top of it when anything is uncommitted.
const checkpointCommit = `set -eu
[ -d .git ] || exit 0
git remote get-url origin >/dev/null 2>&1 || exit 0
git rev-parse -q --verify HEAD >/dev/null || exit 0
idx=$(git rev-parse --git-path vesper-checkpoint-index)
trap 'rm -f "$idx"' EXIT
cp "$(git rev-parse --git-path index)" "$idx"
GIT_INDEX_FILE="$idx" git add -A -- .
tree=$(GIT_INDEX_FILE="$idx" git write-tree)
commit=$(git rev-parse HEAD)
uncommitted=0
if [ "$tree" != "$(git rev-parse 'HEAD^{tree}')" ]; then
  commit=$(git commit-tree "$tree" -p HEAD -m 'Vesper checkpoint: uncommitted work from an earlier run')
  uncommitted=1
fi
branch_name=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
echo '` + checkpointSHAMarker + `'"$commit"
echo '` + checkpointTreeMarker + `'"$tree"
echo '` + checkpointBranchMarker + `'"$branch_name"
echo '` + checkpointUncommittedMarker + `'"$uncommitted"
`

// chatCheckpointRef holds a coding chat's checkpoint commit between building
// it (no credential) and pushing it (see BundleScript).
const chatCheckpointRef = "refs/vesper/checkpoint"

// ChatCheckpointCommitScript is step 1 of a coding chat's checkpoint, run
// with no credential: the work as one commit, at chatCheckpointRef.
func ChatCheckpointCommitScript() string {
	return checkpointCommit + "git update-ref " + chatCheckpointRef + ` "$commit"` + "\n"
}

// ScriptTimeout bounds one housekeeping script (a checkpoint push, a file
// scan). A push that hangs on the network would otherwise hold its caller,
// and a sweep or a run's start, indefinitely.
var ScriptTimeout = 5 * time.Minute

// runScript runs a script in a run's workspace and returns its combined
// output, redacted of env's values. It is killed after ScriptTimeout or when
// ctx ends.
func (r *Runner) runScript(ctx context.Context, runID uuid.UUID, name, script string, env map[string]string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, ScriptTimeout)
	defer cancel()
	if err := r.Backend.EnsureWorkspace(ctx, runID.String()); err != nil {
		return "", err
	}
	proc, err := r.Backend.Start(ctx, runID.String(), ExecSpec{Name: name + "-" + runID.String(), Argv: []string{"sh", "-c", script}, Env: env})
	if err != nil {
		return "", err
	}
	output, code, err := captureProcess(ctx, proc)
	output = redact(output, env)
	if err != nil {
		return output, err
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return output, fmt.Errorf("%s timed out after %s: %s", name, ScriptTimeout, lastLines(output, 10))
	}
	if code != 0 {
		return output, fmt.Errorf("exit %d: %s", code, lastLines(output, 10))
	}
	return output, nil
}

// checkpoint saves a ticket run's unsaved work before its workspace is given
// up. Runs with no repository or no repo:write have nowhere they may push, and
// are left alone. An error means the work is not safe: keep the workspace.
func (r *Runner) checkpoint(ctx context.Context, runID uuid.UUID) error {
	if has, err := r.Backend.HasWorkspace(ctx, runID.String()); err == nil && !has {
		return nil // on the other backend, which saves it
	}
	if run, err := r.q().LockRunNoWait(ctx, runID); err == nil && run.Purpose == "chat" {
		return r.checkpointChat(ctx, run)
	}
	c, err := r.load(ctx, runID)
	if c.run.Purpose != "ticket" || c.run.ParentRunID != nil || c.run.TicketID == nil {
		return nil
	}
	if err != nil {
		return err
	}
	if c.run.CheckpointAt != nil || c.project.RepoUrl == nil || *c.project.RepoUrl == "" || !allowedScope(c.spec, "repo:write") {
		return nil
	}
	env := map[string]string{}
	v, err := r.Secrets.Reveal(ctx, c.run.WorkspaceID, &c.project.ID, "git:pat")
	switch {
	case err == nil:
		env["GH_TOKEN"] = v
	case !errors.Is(err, apperr.ErrNotFound) && !errors.Is(err, secrets.ErrNoKey):
		return r.checkpointFailed(ctx, c, err)
	}
	branch := CheckpointBranch(c.ticket.Key, c.run.ID)
	var out string
	if r.usesHostGitAuth() {
		out, err = r.pushCheckpointOnHost(ctx, c.run.ID, ".", branch, *c.project.RepoUrl, env["GH_TOKEN"], nil)
	} else {
		out, err = r.runScript(ctx, c.run.ID, "lazyagents-checkpoint", CheckpointScript(branch), env)
	}
	if err != nil {
		return r.checkpointFailed(ctx, c, err)
	}
	meta := parseCheckpointMeta(out)
	var saved *string
	if strings.Contains(out, checkpointPushed) {
		saved = &branch
		if err := r.q().RecordRunCheckpoint(ctx, store.RecordRunCheckpointParams{
			WorkspaceID:    c.run.WorkspaceID,
			RunID:          &c.run.ID,
			TicketID:       c.run.TicketID,
			RepoUrl:        *c.project.RepoUrl,
			Branch:         branch,
			CommitSha:      optString(meta.commitSHA),
			TreeSha:        optString(meta.treeSHA),
			SourceBranch:   meta.sourceBranch,
			HasUncommitted: meta.hasUncommitted,
		}); err != nil {
			return r.checkpointFailed(ctx, c, err)
		}
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "checkpoint_pushed", "branch": branch})
	}
	if err := r.q().SetRunCheckpoint(ctx, store.SetRunCheckpointParams{ID: c.run.ID, Branch: saved}); err != nil {
		return err
	}
	if c.run.State == "completed" && c.ticket.PrUrl != nil && *c.ticket.PrUrl != "" && env["GH_TOKEN"] != "" {
		r.cleanupTicketCheckpoints(ctx, c, env["GH_TOKEN"], meta)
	}
	return nil
}

func optString(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func (r *Runner) cleanupTicketCheckpoints(ctx context.Context, c runCtx, token string, meta checkpointMeta) {
	if c.run.TicketID == nil || c.ticket.PrUrl == nil || *c.ticket.PrUrl == "" || token == "" {
		return
	}
	ckpts, err := r.q().OpenTicketCheckpoints(ctx, *c.run.TicketID)
	if err != nil || len(ckpts) == 0 {
		return
	}
	owner, name, prNum, ok := pushreq.ParsePRURL(*c.ticket.PrUrl)
	if !ok {
		return
	}
	gh := &pushreq.GitHub{BaseURL: r.Cfg.GitHubAPIURL, Token: token}
	pr, err := gh.GetPullRequest(ctx, owner, name, prNum)
	if err != nil {
		r.Log.Warn("fetch ticket PR for checkpoint cleanup", "ticket", c.ticket.Key, "err", err)
		return
	}
	if (pr.State != "open" && !pr.Merged) || pr.Head.SHA == "" {
		return
	}
	cleanHead := !meta.hasUncommitted && meta.commitSHA != "" && meta.commitSHA == pr.Head.SHA
	if _, err := pushreq.CleanupTicketCheckpoints(context.WithoutCancel(ctx), gh, r.q(), *c.run.TicketID, *c.ticket.PrUrl, pr.Head.Ref, pr.Head.SHA, &c.run.ID, cleanHead, false); err != nil {
		r.Log.Warn("cleanup ticket checkpoints", "ticket", c.ticket.Key, "err", err)
	}
}

// chatStrayFilesScript lists what a chat left that no checkpoint can save: any
// file beyond Vesper's own, when the workspace isn't a checkout with a remote.
const chatStrayFilesScript = `if [ -d .git ] && git remote get-url origin >/dev/null 2>&1 && git rev-parse -q --verify HEAD >/dev/null; then exit 0; fi
for f in * .[!.]* ..?*; do
  [ -e "$f" ] || continue
  case "$f" in AGENTS.md|CLAUDE.md|.lazyagents|.claude|.codex|.agents) ;; *) printf '%s\n' "$f" ;; esac
done`

// checkpointChat saves a chat's work before its workspace is given up: a
// coding chat's to a checkpoint branch. Files with nowhere to go stay on disk,
// and the run stops tracking them so the sweep doesn't keep retrying. An error
// means the workspace must not be removed. A deleted chat's goes with it.
func (r *Runner) checkpointChat(ctx context.Context, run store.Run) error {
	if run.CheckpointAt != nil {
		return nil
	}
	chat, err := r.q().ChatSessionForEndedRun(ctx, &run.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	spec, err := runs.Spec(run)
	if err != nil {
		return err
	}
	c := runCtx{run: run, spec: spec}
	c.project.ID = runs.ProjectIDOrNil(chat.ProjectID)
	var saved *string
	repos, err := r.q().ChatRepositories(ctx, chat.ID)
	if err != nil {
		return err
	}
	if allowedScope(c.spec, "repo:write") {
		env := map[string]string{}
		for name, key := range map[string]string{"git:pat": "GH_TOKEN", "git:ssh": SSHKeyEnv} {
			if r.Secrets == nil {
				continue
			}
			v, e := r.Secrets.Reveal(ctx, c.run.WorkspaceID, &c.project.ID, name)
			if e == nil {
				env[key] = v
			} else if !errors.Is(e, apperr.ErrNotFound) && !errors.Is(e, secrets.ErrNoKey) {
				return r.checkpointFailed(ctx, c, e)
			}
		}
		for _, repo := range repos {
			branch := CheckpointBranch(fmt.Sprintf("chat/%x", sha256.Sum256([]byte(repo.RepoUrl)))[:21], c.run.ID)
			out, e := r.pushChatCheckpoint(ctx, c, chat.ID, repo, branch, env)
			if e != nil {
				return r.checkpointFailed(ctx, c, e)
			}
			if strings.Contains(out, "vesper-checkpoint-absent") {
				continue
			}
			meta := parseCheckpointMeta(out)
			var checkpoint *string
			if strings.Contains(out, checkpointPushed) {
				checkpoint = &branch
				saved = &branch
				if err := r.q().RecordRunCheckpoint(ctx, store.RecordRunCheckpointParams{
					WorkspaceID:    c.run.WorkspaceID,
					RunID:          &c.run.ID,
					ChatID:         &chat.ID,
					RepoUrl:        repo.RepoUrl,
					Branch:         branch,
					CommitSha:      optString(meta.commitSHA),
					TreeSha:        optString(meta.treeSHA),
					SourceBranch:   meta.sourceBranch,
					HasUncommitted: meta.hasUncommitted,
				}); err != nil {
					return r.checkpointFailed(ctx, c, err)
				}
				r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "checkpoint_pushed", "repo": repo.RepoUrl, "branch": branch})
			}
			if err := r.q().SetRepositoryCheckpoint(ctx, store.SetRepositoryCheckpointParams{ChatID: chat.ID, RepoUrl: repo.RepoUrl, CheckpointBranch: checkpoint}); err != nil {
				return err
			}
			if checkpoint == nil && env["GH_TOKEN"] != "" {
				r.cleanupChatCheckpointsFromPRs(ctx, chat.ID, repo.RepoUrl, env["GH_TOKEN"], &c.run.ID)
			}
		}
	}

	out, err := r.runScript(ctx, c.run.ID, "lazyagents-chat-files", chatStrayFilesScript, nil)
	if err != nil {
		return r.checkpointFailed(ctx, c, err)
	}
	if files := strings.Fields(out); len(files) > 0 {
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "workspace_kept", "files": files, "path": r.Backend.WorkspaceDir(c.run.ID.String())})
		if err := r.q().SetRunWorkspace(ctx, store.SetRunWorkspaceParams{ID: c.run.ID, WorkspaceVolume: nil}); err != nil {
			return err
		}
		return fmt.Errorf("kept the workspace: %d file(s) can't be checkpointed", len(files))
	}
	return r.q().SetRunCheckpoint(ctx, store.SetRunCheckpointParams{ID: c.run.ID, Branch: saved})
}

func (r *Runner) chatCommitAlreadyInPR(ctx context.Context, chatID uuid.UUID, repoURL, token string, meta checkpointMeta) bool {
	if token == "" || meta.commitSHA == "" {
		return false
	}
	owner, name, ok := pushreq.ParseRepo(repoURL)
	if !ok {
		return false
	}
	prs, err := r.q().PushedChatPRsForRepo(ctx, store.PushedChatPRsForRepoParams{ChatID: chatID, RepoUrl: repoURL})
	if err != nil || len(prs) == 0 {
		return false
	}
	gh := &pushreq.GitHub{BaseURL: r.Cfg.GitHubAPIURL, Token: token}
	for _, p := range prs {
		if p.PrUrl == nil || *p.PrUrl == "" {
			continue
		}
		po, pn, prNum, ok := pushreq.ParsePRURL(*p.PrUrl)
		if !ok || !strings.EqualFold(po, owner) || !strings.EqualFold(pn, name) {
			continue
		}
		pr, err := gh.GetPullRequest(ctx, po, pn, prNum)
		if err != nil || pr.Head.SHA == "" || (pr.State != "open" && !pr.Merged) {
			continue
		}
		if contained, err := pushreq.CommitContainedInPR(ctx, gh, po, pn, pr.Head.SHA, meta.commitSHA, meta.treeSHA); err == nil && contained {
			return true
		}
	}
	return false
}

func (r *Runner) cleanupChatCheckpointsFromPRs(ctx context.Context, chatID uuid.UUID, repoURL, token string, runID *uuid.UUID) {
	if token == "" {
		return
	}
	ckpts, err := r.q().OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chatID, RepoUrl: repoURL})
	if err != nil || len(ckpts) == 0 {
		return
	}
	prs, err := r.q().PushedChatPRsForRepo(ctx, store.PushedChatPRsForRepoParams{ChatID: chatID, RepoUrl: repoURL})
	if err != nil || len(prs) == 0 {
		return
	}
	gh := &pushreq.GitHub{BaseURL: r.Cfg.GitHubAPIURL, Token: token}
	for _, p := range prs {
		if p.PrUrl == nil || *p.PrUrl == "" {
			continue
		}
		po, pn, prNum, ok := pushreq.ParsePRURL(*p.PrUrl)
		if !ok {
			continue
		}
		pr, err := gh.GetPullRequest(ctx, po, pn, prNum)
		if err != nil || pr.Head.SHA == "" || (pr.State != "open" && !pr.Merged) {
			continue
		}
		if _, err := pushreq.CleanupChatCheckpointsAtPR(context.WithoutCancel(ctx), gh, r.q(), chatID, repoURL, *p.PrUrl, pr.Head.Ref, pr.Head.SHA, runID, true); err != nil {
			r.Log.Warn("cleanup chat checkpoints from PR", "chat", chatID, "err", err)
		}
	}
}

// checkpointFailed records why, with one timeline entry per distinct failure
// since the sweep retries.
func (r *Runner) checkpointFailed(ctx context.Context, c runCtx, cause error) error {
	if ctx.Err() != nil {
		return ctx.Err()
	}
	msg := cause.Error()
	if c.run.CheckpointError == nil || *c.run.CheckpointError != msg {
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "checkpoint_failed", "reason": msg})
		if err := r.q().SetRunCheckpointError(ctx, store.SetRunCheckpointErrorParams{ID: c.run.ID, Error: &msg}); err != nil {
			r.Log.Warn("record checkpoint failure", "run", c.run.ID, "err", err)
		}
	}
	return cause
}

// recoverTicketWork checkpoints earlier runs of the ticket that still hold
// work, and returns the branch this run should start from ("" for none).
func (r *Runner) recoverTicketWork(ctx context.Context, c runCtx) (string, error) {
	ids, err := r.q().RunsToCheckpoint(ctx, store.RunsToCheckpointParams{TicketID: c.run.TicketID, ID: c.run.ID})
	if err != nil {
		return "", err
	}
	for _, id := range ids {
		if err := r.checkpoint(ctx, id); err != nil {
			return "", fmt.Errorf("run %s: %w", id, err)
		}
	}
	branch, err := r.q().LatestTicketCheckpoint(ctx, store.LatestTicketCheckpointParams{TicketID: c.run.TicketID, ID: c.run.ID})
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return branch, err
}

func (r *Runner) recordRecoveredChatCheckpoints(ctx context.Context, runID uuid.UUID, output string) {
	if !strings.Contains(output, checkpointRecovered) {
		return
	}
	chat, err := r.q().ChatSessionForRun(ctx, &runID)
	if err != nil {
		return
	}
	repos, err := r.q().ChatRepositories(ctx, chat.ID)
	if err != nil {
		return
	}
	for _, line := range strings.Split(output, "\n") {
		branch, ok := strings.CutPrefix(strings.TrimSpace(line), checkpointRecovered+" ")
		if !ok || branch == "" {
			continue
		}
		for _, repo := range repos {
			if repo.CheckpointBranch != nil && *repo.CheckpointBranch == branch {
				r.event(ctx, runID, "lifecycle", map[string]any{"state": "checkpoint_recovered", "branch": branch, "repo": repo.RepoUrl})
				_ = r.q().MarkCheckpointRecovered(ctx, store.MarkCheckpointRecoveredParams{
					RepoUrl:          repo.RepoUrl,
					Branch:           branch,
					RecoveredByRunID: runID,
				})
			}
		}
	}
}

// pushChatCheckpoint saves one checkout of a coding chat to branch in two
// steps (see BundleScript): the commit and bundle are made with no credential,
// and only a clean repository of ours pushes them with the token. Output says
// vesper-checkpoint-absent when there is no checkout, checkpointPushed after a
// push, and nothing (with commit metadata) when the work is already on the remote.
func (r *Runner) pushChatCheckpoint(ctx context.Context, c runCtx, chatID uuid.UUID, repo store.ChatRepository, branch string, env map[string]string) (string, error) {
	skipFn := func(meta checkpointMeta) bool {
		return r.chatCommitAlreadyInPR(ctx, chatID, repo.RepoUrl, env["GH_TOKEN"], meta)
	}
	if r.usesHostGitAuth() {
		return r.pushCheckpointOnHost(ctx, c.run.ID, repo.Directory, branch, repo.RepoUrl, env["GH_TOKEN"], skipFn)
	}
	dir := shellQuote(repo.Directory)
	script := "if [ ! -d " + shellQuote(repo.Directory+"/.git") + " ]; then echo vesper-checkpoint-absent; exit 0; fi\n(cd " + dir + "\n" + ChatCheckpointCommitScript() + ")\n"
	commitOut, err := r.runScript(ctx, c.run.ID, "lazyagents-checkpoint", script, nil)
	if err != nil || strings.Contains(commitOut, "vesper-checkpoint-absent") {
		return commitOut, err
	}
	bundle := pushRoot + "/checkpoint-" + c.run.ID.String() + ".bundle"
	bare := pushRoot + "/checkpoint-" + c.run.ID.String() + ".git"
	defer func() {
		_, _ = r.runScript(context.WithoutCancel(ctx), c.run.ID, "lazyagents-checkpoint-cleanup", "rm -rf "+shellQuote(bundle)+" "+shellQuote(bare), nil)
	}()
	out, err := r.runScript(ctx, c.run.ID, "lazyagents-checkpoint-bundle", BundleScript(repo.Directory, chatCheckpointRef, bundle), nil)
	if err != nil {
		return out, err
	}
	if !strings.Contains(out, bundleMarker) {
		return commitOut, nil // already on the remote
	}
	meta := parseCheckpointMeta(commitOut)
	if skipFn(meta) {
		return commitOut, nil
	}
	// The token only ever goes to github.com; another remote gets none.
	url, pushEnv := repo.RepoUrl, map[string]string(nil)
	if u, ok := pushreq.HTTPSURL(repo.RepoUrl); ok {
		url = u
		if env["GH_TOKEN"] != "" {
			pushEnv = map[string]string{"GH_TOKEN": env["GH_TOKEN"]}
		}
	}
	out, err = r.runScript(ctx, c.run.ID, "lazyagents-checkpoint-push", PushCheckpointBundleScript(bundle, bare, url, branch, r.isolatesGit()), pushEnv)
	if err != nil {
		return out, err
	}
	if strings.Contains(out, checkpointRemoteHas) {
		return commitOut, nil
	}
	return commitOut + "\n" + checkpointPushed, nil
}

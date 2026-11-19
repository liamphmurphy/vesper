package runner

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/pushreq"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Everything Vesper pushes for a coding chat leaves the persona's checkout in
// two steps, so the token never meets anything the persona controls. The
// checkout's config, hooks, filters and the home volume's git config are the
// persona's to edit, and any process sharing a container with the token can
// read it from /proc. So:
//   1. BundleScript runs with no credential: it bundles the commits the
//      remote doesn't have yet (persona-controlled git may run here, with
//      nothing to steal);
//   2. PushBundleScript runs in a fresh container with the token: a new bare
//      repository with only our config (global and system config ignored)
//      fetches the bundle's prerequisites from GitHub, takes the bundle and
//      pushes to the repository's https URL, never to a remote the checkout
//      names.

const (
	stagedMarker  = "vesper-staged "
	baseMarker    = "vesper-base "
	bundleMarker  = "vesper-bundled"
	pushRoot      = ".lazyagents/push"
	bundleRefName = "refs/vesper/push"
)

// stageDir is a request's bare repository, inside the workspace so the git
// reads that follow (each its own container) can find it.
func stageDir(id string) string { return pushRoot + "/" + id + ".git" }

func bundlePath(id string) string { return pushRoot + "/" + id + ".bundle" }

// BundleScript bundles rev (a ref or commit in the checkout at dir) as
// bundleRefName, leaving out what origin already has (except Vesper's own
// checkpoints, which aren't the branch's history). It prints bundleMarker
// once the bundle is written, nothing when rev adds nothing.
func BundleScript(dir, rev, bundle string) string {
	var b strings.Builder
	b.WriteString("set -eu\nroot=\"$PWD\"\n")
	b.WriteString("cd " + shellQuote(dir) + "\n")
	b.WriteString(`commit=$(git rev-parse --verify -q ` + shellQuote(rev+"^{commit}") + `) || { echo "vesper: no ` + strings.ReplaceAll(rev, "'", "") + ` in the checkout" >&2; exit 3; }` + "\n")
	b.WriteString("git update-ref " + bundleRefName + ` "$commit"` + "\n")
	b.WriteString(`mkdir -p "$root/` + pushRoot + `" && rm -f "$root/"` + shellQuote(bundle) + "\n")
	b.WriteString(`if [ -n "$(git rev-list -1 ` + bundleRefName + ` --not --exclude='origin/` + checkpointPrefix + `*' --remotes=origin)" ]; then` + "\n")
	b.WriteString(`  git bundle create -q "$root/"` + shellQuote(bundle) + " " + bundleRefName + ` --not --exclude='origin/` + checkpointPrefix + `*' --remotes=origin` + "\n")
	b.WriteString("  echo " + bundleMarker + "\nfi\n")
	b.WriteString("git update-ref -d " + bundleRefName + "\n")
	return b.String()
}

// PushBundleScript is step 2: into a new bare repository at bare (removed
// first), fetch the bundle's prerequisites shallowly from url, take the
// bundle's commit as refs/heads/stage, and push it to dest. It prints
// baseMarker with the newest prerequisite, where the pushed commits leave the
// remote's history. When base is set it also reads the remote's default
// branch and prints stagedMarker with its name.
func PushBundleScript(bundle, bare, url, dest string, base, isolate bool) string {
	return pushBundleScript(bundle, bare, url, dest, base, false, isolate)
}

// PushCheckpointBundleScript is PushBundleScript for checkpoints: before
// pushing, it skips if any non-checkpoint branch on url already points at the
// staged commit.
func PushCheckpointBundleScript(bundle, bare, url, dest string, isolate bool) string {
	return pushBundleScript(bundle, bare, url, dest, false, true, isolate)
}

func pushBundleScript(bundle, bare, url, dest string, base, skipIfRemoteHas, isolate bool) string {
	var b strings.Builder
	b.WriteString("set -eu\nexport GIT_TERMINAL_PROMPT=0\n")
	if isolate {
		b.WriteString(isolatedGitConfig)
	}
	b.WriteString(`helper='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'` + "\n")
	b.WriteString("bundle=\"$PWD\"/" + shellQuote(bundle) + "\nb=" + shellQuote(bare) + "\nurl=" + shellQuote(url) + "\n")
	b.WriteString(`rm -rf "$b" && mkdir -p "$(dirname "$b")" && git init -q --bare "$b" && cd "$b"` + "\n")
	b.WriteString(`git config credential.helper "$helper"` + "\n")
	// The header ends at the first blank line; prerequisites are "-<sha> <subject>".
	b.WriteString(`prereqs=$(sed '/^$/q' "$bundle" | sed -n 's/^-\([0-9a-f]\{40,64\}\).*/\1/p')` + "\n")
	b.WriteString(`for p in $prereqs; do git fetch -q --no-tags --depth=1 "$url" "$p" || { echo "vesper: GitHub no longer has $p, which this work builds on" >&2; exit 5; }; done` + "\n")
	b.WriteString(`git fetch -q --no-tags "$bundle" "+` + bundleRefName + `:refs/heads/stage"` + "\n")
	b.WriteString(`if [ -n "$prereqs" ]; then echo "` + baseMarker + `$(git log -1 --no-walk=sorted --format=%H $prereqs)"; fi` + "\n")
	if base {
		b.WriteString(`def=$(git ls-remote --symref "$url" HEAD | sed -n 's|^ref: refs/heads/\(.*\)	HEAD$|\1|p')` + "\n")
		b.WriteString(`[ -n "$def" ] || { echo "vesper: can't read the repository's default branch" >&2; exit 4; }` + "\n")
		b.WriteString(`echo "` + stagedMarker + `$def"` + "\n")
	}
	if skipIfRemoteHas {
		b.WriteString(`stage_sha=$(git rev-parse refs/heads/stage)` + "\n")
		b.WriteString(`if remote_heads=$(git ls-remote --heads "$url" 2>/dev/null) && printf '%s\n' "$remote_heads" | grep -v '[[:space:]]refs/heads/` + checkpointPrefix + `' | grep -q "^${stage_sha}[[:space:]]"; then echo '` + checkpointRemoteHas + `'; exit 0; fi` + "\n")
	}
	b.WriteString(`git push -q --no-verify "$url" ` + shellQuote("+refs/heads/stage:refs/heads/"+dest) + "\n")
	return b.String()
}

// isolatedGitConfig ignores the home volume's and the image's git config,
// which the persona can write on the microVM backend. The fake backend's is the
// runner host's own (tests rewrite URLs with it), so it is left alone there.
const isolatedGitConfig = "export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 HOME=/tmp\n"

// isolatesGit reports whether this runner's scripts must ignore global git config.
func (r *Runner) isolatesGit() bool { return r.Backend.Isolates() }

// markerValue is the text after the last line starting with marker.
func markerValue(out, marker string) string {
	v := ""
	for _, line := range strings.Split(out, "\n") {
		if rest, ok := strings.CutPrefix(strings.TrimSpace(line), strings.TrimSpace(marker)); ok {
			v = strings.TrimSpace(rest)
		}
	}
	return v
}

// stagePushRequests stages what the chat asked to push, at the end of a turn.
// A request that can't be staged fails with why; nothing here fails the turn.
// Repositories the person always allows ship at once.
func (r *Runner) stagePushRequests(ctx context.Context, c runCtx) {
	chat, err := r.q().ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		return
	}
	reqs, err := r.q().StagingPushRequests(ctx, chat.ID)
	if err != nil || len(reqs) == 0 {
		return
	}
	repos, err := r.q().ChatRepositories(ctx, chat.ID)
	if err != nil {
		return
	}
	token, err := r.gitToken(ctx, c)
	for _, req := range reqs {
		fail := func(msg string) {
			if _, e := r.q().FinishPushRequest(ctx, store.FinishPushRequestParams{ID: req.ID, State: "failed", Error: &msg}); e != nil {
				r.Log.Warn("fail push request", "id", req.ID, "err", e)
			}
		}
		if err != nil {
			fail("Couldn't read the GitHub token: " + err.Error())
			continue
		}
		if token == "" {
			fail("No GitHub token: add git:pat in Settings → Connections & secrets, then ask again.")
			continue
		}
		dir := ""
		for _, repo := range repos {
			if repo.RepoUrl == req.RepoUrl {
				dir = repo.Directory
			}
		}
		url, ok := pushreq.HTTPSURL(req.RepoUrl)
		if dir == "" || !ok {
			fail("Vesper only pushes github.com repositories attached to this chat.")
			continue
		}
		staged, err := r.stage(ctx, c, req, dir, url, token)
		if err != nil {
			r.Log.Warn("stage push request", "id", req.ID, "branch", req.Branch, "err", err)
			fail(err.Error())
			continue
		}
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "push_staged", "request": req.ID, "branch": req.Branch})
		r.autoShip(ctx, staged, token)
	}
}

// stage bundles the branch without the token, pushes it to the request's
// staging branch from a clean repository, and records the commits and diff
// the card shows.
func (r *Runner) stage(ctx context.Context, c runCtx, req store.PushRequest, dir, url, token string) (store.PushRequest, error) {
	if r.usesHostGitAuth() {
		return r.stageOnHost(ctx, c, req, dir, url, token)
	}
	id := req.ID.String()
	staging := pushreq.StagingBranch(req.ID)
	defer func() {
		_, _ = r.runScript(context.WithoutCancel(ctx), c.run.ID, "lazyagents-push-cleanup", "rm -rf "+shellQuote(stageDir(id))+" "+shellQuote(bundlePath(id)), nil)
	}()
	out, err := r.runScript(ctx, c.run.ID, "lazyagents-push-bundle", BundleScript(dir, "refs/heads/"+req.Branch, bundlePath(id)), nil)
	if err != nil {
		return req, &pushreq.Refusal{Reason: "Couldn't stage " + req.Branch + ": " + lastLine(out, err)}
	}
	if !strings.Contains(out, bundleMarker) {
		return req, &pushreq.Refusal{Reason: req.Branch + " has no commits GitHub doesn't already have. Commit the work, then ask again."}
	}
	out, err = r.runScript(ctx, c.run.ID, "lazyagents-push-stage", PushBundleScript(bundlePath(id), stageDir(id), url, staging, true, r.isolatesGit()), map[string]string{"GH_TOKEN": token})
	redactedOut := redact(out, map[string]string{"GH_TOKEN": token})
	if err != nil {
		return req, &pushreq.Refusal{Reason: "Couldn't stage " + req.Branch + ": " + PushErrorDetail(redactedOut, err)}
	}
	baseBranch, base := markerValue(out, stagedMarker), markerValue(out, baseMarker)
	if baseBranch == "" {
		return req, &pushreq.Refusal{Reason: "Couldn't stage " + req.Branch + ": " + PushErrorDetail(redactedOut, nil)}
	}
	if baseBranch == req.Branch {
		return req, &pushreq.Refusal{Reason: req.Branch + " is the default branch; push a work branch instead."}
	}
	rc := inRepository(ctx, stageDir(id))
	head := r.gitLine(rc, c.run.ID.String(), "rev-parse", "--verify", "-q", "refs/heads/stage")
	if !commitRe.MatchString(head) || !commitRe.MatchString(base) {
		return req, &pushreq.Refusal{Reason: req.Branch + " shares no history with the repository on GitHub."}
	}
	commits := r.commitList(rc, c.run.ID.String(), base, head)
	files, err := r.commitChanges(rc, c.run.ID.String(), base, head, map[string]string{"GH_TOKEN": token})
	if err != nil {
		r.Log.Warn("staged diff", "id", id, "err", err)
		files = []CodeChange{}
	}
	commitsJSON, _ := json.Marshal(commits)
	filesJSON, _ := json.Marshal(files)
	return r.q().SetPushRequestStaged(ctx, store.SetPushRequestStagedParams{ID: req.ID, BaseBranch: &baseBranch, BaseSha: &base,
		HeadSha: &head, StagingRef: &staging, Commits: commitsJSON, Files: filesJSON})
}

// commitChanges is the diff between two commits of a repository the runner
// made (no working tree, no untrusted config).
func (r *Runner) commitChanges(ctx context.Context, runID, from, to string, env map[string]string) ([]CodeChange, error) {
	args := func(mode ...string) []string {
		a := append([]string{"diff", "--no-ext-diff", "--no-textconv", "-M", "--src-prefix=a/", "--dst-prefix=b/"}, mode...)
		return append(a, from, to, "--")
	}
	numstat, cut, code, err := r.gitCmd(ctx, runID, nil, 1<<20, args("--numstat", "-z")...)
	if err != nil || code != 0 || cut {
		return nil, fmt.Errorf("git diff --numstat: exit %d: %v", code, err)
	}
	patch, patchCut, code, err := r.gitCmd(ctx, runID, nil, codeDiffReadLimit, args("-p", "--unified=3")...)
	if err != nil || code != 0 {
		return nil, fmt.Errorf("git diff -p: exit %d: %v", code, err)
	}
	changes, err := ParseCodeChanges(numstat, string(patch), patchCut)
	if err != nil {
		return nil, err
	}
	changes = ApplyCodeChangeBudget(changes)
	for i := range changes {
		if changes[i].Patch != nil {
			p := redact(*changes[i].Patch, env)
			changes[i].Patch = &p
		}
	}
	return changes, nil
}

// autoShip ships a staged request at once when the person always allows its
// repository.
func (r *Runner) autoShip(ctx context.Context, req store.PushRequest, token string) {
	p, err := r.q().GetRepositoryPushPolicy(ctx, store.GetRepositoryPushPolicyParams{UserID: req.UserID, RepoUrl: req.RepoUrl})
	if err != nil || !p.AutoPush {
		return
	}
	claimed, err := r.q().ClaimStagedPushRequest(ctx, req.ID)
	if err != nil {
		return
	}
	gh := &pushreq.GitHub{BaseURL: r.Cfg.GitHubAPIURL, Token: token}
	res, shipErr := pushreq.Ship(ctx, gh, claimed)
	done, err := pushreq.Finish(context.WithoutCancel(ctx), r.q(), claimed, res, shipErr)
	if err != nil {
		r.Log.Warn("finish push request", "id", req.ID, "err", err)
		return
	}
	if shipErr == nil && done.State == "pushed" && done.PrUrl != nil && *done.PrUrl != "" {
		if _, cerr := pushreq.CleanupChatCheckpoints(context.WithoutCancel(ctx), gh, r.q(), done); cerr != nil {
			r.Log.Warn("cleanup chat checkpoints", "push_request", done.ID, "err", cerr)
		}
	}
}

// PushErrorDetail summarizes a failed push script's output, keeping the remote
// rejection lines that precede git's generic "failed to push some refs" line.
func PushErrorDetail(out string, err error) string {
	var lines []string
	for _, raw := range strings.Split(strings.TrimSpace(out), "\n") {
		l := strings.TrimSpace(raw)
		if l == "" || strings.HasPrefix(l, stagedMarker) || strings.HasPrefix(l, baseMarker) {
			continue
		}
		lines = append(lines, strings.TrimPrefix(l, "vesper: "))
	}
	if len(lines) == 0 {
		if err != nil {
			return err.Error()
		}
		return "no output"
	}
	const maxLines = 6
	if len(lines) > maxLines {
		lines = lines[len(lines)-maxLines:]
	}
	detail := strings.Join(lines, "\n")
	const maxBytes = 600
	if len(detail) > maxBytes {
		detail = "..." + detail[len(detail)-(maxBytes-3):]
	}
	return detail
}

// lastLine is the most useful line of a failed script's output.
func lastLine(out string, err error) string {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return strings.TrimPrefix(l, "vesper: ")
		}
	}
	if err != nil {
		return err.Error()
	}
	return "no output"
}

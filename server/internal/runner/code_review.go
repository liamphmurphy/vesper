package runner

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/pushreq"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A coding chat's Code dock shows each repository's branch against the
// default branch, committed and uncommitted, while the persona works and after
// the workspace is gone. The runner reads it with the same git it reports a
// turn's changes with (codechanges_run.go) and keeps the latest in
// chat_code_reviews.

// CodeReviewInterval is how often a running turn's workspace is checked for
// changes to show live.
var CodeReviewInterval = 5 * time.Second

// reviewCommitLimit bounds the commits a review lists.
const reviewCommitLimit = 100

// reviewSnapshot is one repository's review, as stored.
type reviewSnapshot struct {
	branch, base, head string
	commits            []pushreq.Commit
	files              []CodeChange
	dirty              bool
	tree               []CodeReviewFile
	treeTruncated      bool
}

// gitLine is one trimmed line of git output, "" when the command fails.
func (r *Runner) gitLine(ctx context.Context, runID string, args ...string) string {
	out, _, code, err := r.gitCmd(ctx, runID, nil, 4<<10, args...)
	if err != nil || code != 0 {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// reviewBase is where the branch left the remote's default branch: the
// merge base with origin/HEAD, else the commit the checkout was cloned at.
func (r *Runner) reviewBase(ctx context.Context, runID, head string) string {
	if base := r.gitLine(ctx, runID, "merge-base", head, "refs/remotes/origin/HEAD"); commitRe.MatchString(base) {
		return base
	}
	if base := r.gitLine(ctx, runID, "config", "--get", "vesper.base"); commitRe.MatchString(base) {
		return base
	}
	return head
}

// commitList is `git log base..head`, newest first.
func (r *Runner) commitList(ctx context.Context, runID, base, head string) []pushreq.Commit {
	if base == head {
		return []pushreq.Commit{}
	}
	out, _, code, err := r.gitCmd(ctx, runID, nil, 1<<20, "log", "--no-color", "--format=%H%x1f%s%x1e", "-n", "100", base+".."+head)
	commits := []pushreq.Commit{}
	if err != nil || code != 0 {
		return commits
	}
	for _, rec := range bytes.Split(out, []byte{0x1e}) {
		sha, subject, ok := strings.Cut(strings.TrimSpace(string(rec)), "\x1f")
		if ok && commitRe.MatchString(sha) && len(commits) < reviewCommitLimit {
			commits = append(commits, pushreq.Commit{SHA: sha, Subject: subject})
		}
	}
	return commits
}

// snapshot reads one checkout's review. ok is false when it has no commit yet.
func (r *Runner) snapshot(ctx context.Context, runID string, env map[string]string) (reviewSnapshot, bool, error) {
	head := r.gitLine(ctx, runID, "rev-parse", "--verify", "-q", "HEAD")
	if !commitRe.MatchString(head) {
		return reviewSnapshot{}, false, nil
	}
	s := reviewSnapshot{head: head, branch: r.gitLine(ctx, runID, "symbolic-ref", "--quiet", "--short", "HEAD")}
	s.base = r.reviewBase(ctx, runID, head)
	s.commits = r.commitList(ctx, runID, s.base, head)
	files, err := r.codeChanges(ctx, runID, s.base, env)
	if err != nil {
		return s, false, err
	}
	s.files = files
	filterEnv, err := r.repoFilterEnv(ctx, runID)
	if err != nil {
		return s, true, nil
	}
	status, _, code, err := r.gitCmd(ctx, runID, filterEnv, 1<<20, append([]string{"status", "--porcelain=v1", "-z", "--untracked-files=normal"}, codeChangePathspec...)...)
	s.dirty = err == nil && code == 0 && len(status) > 0
	s.tree, s.treeTruncated = r.branchTree(ctx, runID, filterEnv, s.files, env)
	return s, true, nil
}

func isWorkspaceExcluded(p string) bool {
	return p == "" || p == "AGENTS.md" || p == ".lazyagents" || strings.HasPrefix(p, ".lazyagents/")
}

func extractAddedContent(patch string) string {
	var b strings.Builder
	first := true
	for _, line := range strings.Split(patch, "\n") {
		if strings.HasPrefix(line, "@@") || strings.HasPrefix(line, `\`) {
			continue
		}
		if strings.HasPrefix(line, "+") {
			if !first {
				b.WriteByte('\n')
			}
			first = false
			b.WriteString(strings.TrimPrefix(line, "+"))
		}
	}
	return b.String()
}

// branchTree reads the full non-ignored, non-excluded file tree for the
// checkout's current branch state along with bounded text contents for viewing.
func (r *Runner) branchTree(ctx context.Context, runID string, filterEnv map[string]string, files []CodeChange, env map[string]string) ([]CodeReviewFile, bool) {
	lsOut, _, lsCode, lsErr := r.gitCmd(ctx, runID, filterEnv, 2<<20, append([]string{"ls-files", "--cached", "--others", "--exclude-standard", "-z"}, codeChangePathspec...)...)
	if lsErr != nil || lsCode != 0 {
		return []CodeReviewFile{}, false
	}
	delOut, _, _, _ := r.gitCmd(ctx, runID, filterEnv, 1<<20, append([]string{"ls-files", "--deleted", "-z"}, codeChangePathspec...)...)
	deleted := map[string]bool{}
	for _, rec := range bytes.Split(delOut, []byte{0}) {
		if p := string(rec); p != "" {
			deleted[p] = true
		}
	}
	changedByPath := make(map[string]CodeChange, len(files))
	changedSet := make(map[string]bool, len(files))
	for _, ch := range files {
		if ch.Status == "deleted" {
			deleted[ch.Path] = true
			continue
		}
		if ch.Status == "renamed" && ch.OldPath != nil {
			deleted[*ch.OldPath] = true
		}
		changedByPath[ch.Path] = ch
		changedSet[ch.Path] = true
	}

	pathSet := map[string]bool{}
	for _, rec := range bytes.Split(lsOut, []byte{0}) {
		p := string(rec)
		if isWorkspaceExcluded(p) || deleted[p] {
			continue
		}
		pathSet[p] = true
	}
	for p := range changedByPath {
		if isWorkspaceExcluded(p) || deleted[p] {
			continue
		}
		pathSet[p] = true
	}
	paths := make([]string, 0, len(pathSet))
	for p := range pathSet {
		paths = append(paths, p)
	}
	sort.Strings(paths)

	treeTruncated := false
	if len(paths) > CodeReviewMaxTreeFiles {
		paths = paths[:CodeReviewMaxTreeFiles]
		treeTruncated = true
	}

	headSize := map[string]int{}
	headIsBlob := map[string]bool{}
	treeOut, _, treeCode, treeErr := r.gitCmd(ctx, runID, filterEnv, 2<<20, "ls-tree", "-r", "-l", "-z", "HEAD")
	if treeErr == nil && treeCode == 0 {
		for _, rec := range bytes.Split(treeOut, []byte{0}) {
			if len(rec) == 0 {
				continue
			}
			meta, path, ok := strings.Cut(string(rec), "\t")
			if !ok || isWorkspaceExcluded(path) {
				continue
			}
			fields := strings.Fields(meta)
			if len(fields) < 4 {
				continue
			}
			typ, szStr := fields[1], fields[3]
			if typ == "blob" {
				headIsBlob[path] = true
				if n, err := strconv.Atoi(szStr); err == nil {
					headSize[path] = n
				}
			}
		}
	}

	var unchangedCandidates, changedCandidates []string
	queuedBudget := 0
	for _, p := range paths {
		if !headIsBlob[p] || headSize[p] > CodeReviewOversizeFileBytes {
			continue
		}
		if ch, ok := changedByPath[p]; ok {
			if !ch.Binary {
				changedCandidates = append(changedCandidates, p)
			}
		} else {
			sliceEst := headSize[p]
			if sliceEst > CodeReviewMaxFileBytes {
				sliceEst = CodeReviewMaxFileBytes
			}
			if queuedBudget < CodeReviewMaxTreeTotalBytes*2 {
				unchangedCandidates = append(unchangedCandidates, p)
				queuedBudget += sliceEst
			}
		}
	}
	candidates := append(unchangedCandidates, changedCandidates...)

	blobData := make(map[string][]byte, len(candidates))
	if len(candidates) > 0 {
		archiveEnv := make(map[string]string, len(filterEnv)+1)
		for k, v := range filterEnv {
			archiveEnv[k] = v
		}
		archiveEnv["GIT_LITERAL_PATHSPECS"] = "1"
		const chunkSize = 100
		for start := 0; start < len(candidates); start += chunkSize {
			end := start + chunkSize
			if end > len(candidates) {
				end = len(candidates)
			}
			args := append([]string{"archive", "--format=tar", "HEAD", "--"}, candidates[start:end]...)
			tarBytes, _, code, err := r.gitCmd(ctx, runID, archiveEnv, 4<<20, args...)
			if err != nil || code != 0 || len(tarBytes) == 0 {
				continue
			}
			tr := tar.NewReader(bytes.NewReader(tarBytes))
			for {
				hdr, err := tr.Next()
				if err == io.EOF || err != nil {
					break
				}
				if hdr.Typeflag == tar.TypeDir || hdr.Typeflag == tar.TypeXHeader || hdr.Typeflag == tar.TypeXGlobalHeader {
					continue
				}
				name := strings.TrimPrefix(hdr.Name, "./")
				if hdr.Typeflag == tar.TypeSymlink {
					blobData[name] = []byte(hdr.Linkname)
					continue
				}
				raw, _ := io.ReadAll(io.LimitReader(tr, CodeReviewOversizeFileBytes+1))
				blobData[name] = raw
			}
		}
		// Fallback with git show for any missing candidate (e.g. export-ignore in .gitattributes)
		fallbackFetched := 0
		for _, p := range candidates {
			if _, ok := blobData[p]; ok {
				continue
			}
			if fallbackFetched >= CodeReviewMaxTreeTotalBytes*2 {
				break
			}
			raw, _, code, err := r.gitCmd(ctx, runID, filterEnv, CodeReviewOversizeFileBytes+1, "show", "HEAD:"+p)
			if err == nil && code == 0 {
				blobData[p] = raw
				if len(raw) > CodeReviewMaxFileBytes {
					fallbackFetched += CodeReviewMaxFileBytes
				} else {
					fallbackFetched += len(raw)
				}
			}
		}
	}

	entries := make([]CodeReviewFile, 0, len(paths))
	budgetChanged := make(map[string]bool, len(changedByPath))
	for _, p := range paths {
		redactedPath := redact(p, env)
		ch, hasChange := changedByPath[p]
		if hasChange {
			budgetChanged[redactedPath] = true
		}
		f := CodeReviewFile{
			Path:   redactedPath,
			Size:   headSize[p],
			Binary: hasChange && ch.Binary,
		}
		if headIsBlob[p] {
			if f.Size > CodeReviewOversizeFileBytes {
				f.Truncated = true
			} else if raw, ok := blobData[p]; ok {
				if bytes.IndexByte(raw, 0) >= 0 {
					f.Binary = true
				} else if !f.Binary {
					if f.Size == 0 {
						f.Size = len(raw)
					}
					s := redact(string(raw), env)
					f.Content = &s
				}
			}
		} else if hasChange && !f.Binary {
			if ch.Patch != nil {
				s := redact(extractAddedContent(*ch.Patch), env)
				f.Size = len(s)
				f.Content = &s
			} else if ch.Truncated {
				f.Truncated = true
			}
		}
		entries = append(entries, f)
	}
	out, budgetTruncated := ApplyCodeTreeBudgetWithChanged(entries, budgetChanged)
	return out, treeTruncated || budgetTruncated
}

// saveCodeReviews reads and stores the review of every checkout the chat has.
// Failures are logged and never fail the turn.
func (r *Runner) saveCodeReviews(ctx context.Context, c runCtx, env map[string]string, live bool) {
	chat, err := r.q().ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		return
	}
	if !live {
		if err := r.q().SetChatCodeReviewsSettled(ctx, chat.ID); err != nil {
			r.Log.Warn("settle code reviews", "run", c.run.ID, "err", err)
		}
	}
	repos, err := r.q().ChatRepositories(ctx, chat.ID)
	if err != nil {
		return
	}
	tctx, cancel := context.WithTimeout(ctx, codeChangesTimeout)
	defer cancel()
	for _, repo := range repos {
		s, ok, err := r.snapshot(inRepository(tctx, repo.Directory), c.run.ID.String(), env)
		if err != nil {
			r.Log.Warn("code review", "run", c.run.ID, "repo", repo.RepoUrl, "err", err)
		}
		if !ok {
			continue
		}
		commits, _ := json.Marshal(s.commits)
		files, _ := json.Marshal(s.files)
		if s.tree == nil {
			s.tree = []CodeReviewFile{}
		}
		tree, _ := json.Marshal(s.tree)
		var branch *string
		if s.branch != "" {
			branch = &s.branch
		}
		if err := r.q().UpsertChatCodeReview(ctx, store.UpsertChatCodeReviewParams{ChatID: chat.ID, RepoUrl: repo.RepoUrl, Branch: branch,
			BaseSha: &s.base, HeadSha: &s.head, Commits: commits, Files: files, Dirty: s.dirty, Live: live, Tree: tree, TreeTruncated: s.treeTruncated}); err != nil {
			r.Log.Warn("save code review", "run", c.run.ID, "err", err)
		}
	}
}

// reviewSignature changes whenever a checkout's commits, files or diff sizes
// do; the watcher refreshes the review only then. Three short git commands per
// checkout.
func (r *Runner) reviewSignature(ctx context.Context, c runCtx) string {
	chat, err := r.q().ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		return ""
	}
	repos, err := r.q().ChatRepositories(ctx, chat.ID)
	if err != nil {
		return ""
	}
	var b strings.Builder
	for _, repo := range repos {
		rc := inRepository(ctx, repo.Directory)
		id := c.run.ID.String()
		// Reading the working tree must never run the repository's programs.
		filterEnv, err := r.repoFilterEnv(rc, id)
		if err != nil {
			continue
		}
		status, _, _, _ := r.gitCmd(rc, id, filterEnv, 1<<20, append([]string{"status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all"}, codeChangePathspec...)...)
		numstat, _, _, _ := r.gitCmd(rc, id, filterEnv, 1<<20, append([]string{"diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "HEAD"}, codeChangePathspec...)...)
		b.WriteString(repo.RepoUrl)
		b.Write(status)
		b.Write(numstat)
	}
	return b.String()
}

// watchCodeReview keeps a coding chat's review live while its turn runs, and
// returns a stop that waits for the watcher to finish.
func (r *Runner) watchCodeReview(ctx context.Context, c runCtx, env map[string]string) (stop func()) {
	if c.run.Purpose != "chat" || !allowedScope(c.spec, "repo:write") || CodeReviewInterval <= 0 {
		return func() {}
	}
	wctx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		t := time.NewTicker(CodeReviewInterval)
		defer t.Stop()
		last := r.reviewSignature(wctx, c)
		for {
			select {
			case <-wctx.Done():
				return
			case <-t.C:
			}
			sig := r.reviewSignature(wctx, c)
			if sig == last || wctx.Err() != nil {
				continue
			}
			last = sig
			r.saveCodeReviews(wctx, c, env, true)
		}
	}()
	return func() { cancel(); wg.Wait() }
}

// withoutPushCredentials is a coding chat turn's environment without anything
// that can push: personas ask with request_push and the runner ships what the
// person approves. Setup, checkpoints and staging still get the credentials,
// in their own containers.
func withoutPushCredentials(env map[string]string) map[string]string {
	out := make(map[string]string, len(env))
	for k, v := range env {
		out[k] = v
	}
	for _, k := range []string{"GH_TOKEN", "GITHUB_TOKEN", envName("git:pat"), SSHKeyEnv} {
		delete(out, k)
	}
	out["GIT_TERMINAL_PROMPT"] = "0"
	return out
}

// gitToken is the workspace's GitHub token for the run's project, "" when none.
func (r *Runner) gitToken(ctx context.Context, c runCtx) (string, error) {
	if r.Secrets == nil {
		return "", nil
	}
	v, err := r.Secrets.Reveal(ctx, c.run.WorkspaceID, &c.project.ID, "git:pat")
	if errors.Is(err, apperr.ErrNotFound) || errors.Is(err, secrets.ErrNoKey) {
		return "", nil
	}
	return v, err
}

// chatSetupCredentialsDone ends the git part of a coding chat's setup: what
// follows (the repository's dependency installs, which run its own scripts)
// and the turn itself get no credential that can push. The SSH key file is
// removed too, as the turn shares the home volume it was written to.
func chatSetupCredentialsDone(c runCtx) string {
	if c.run.Purpose != "chat" || !allowedScope(c.spec, "repo:write") {
		return ""
	}
	return `rm -f "${` + SSHDirEnv + `:-$PWD/.lazyagents/ssh}/id"` + "\n" +
		"unset GH_TOKEN GITHUB_TOKEN " + envName("git:pat") + " " + SSHKeyEnv + "\n" +
		"export GIT_TERMINAL_PROMPT=0\n"
}

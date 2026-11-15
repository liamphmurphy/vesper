package runner

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
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

// repoReviewCache caches HEAD tree blobs across live code-review ticks within a
// turn (keyed by HEAD SHA) and skips redundant JSONB writes when the serialized
// tree is unchanged.
type repoReviewCache struct {
	head           string
	headSize       map[string]int
	headIsBlob     map[string]bool
	blobData       map[string][]byte
	hasSavedTree   bool
	savedTreeJSON  []byte
	savedTreeTrunc bool
}

type codeReviewCache struct {
	mu    sync.Mutex
	repos map[string]*repoReviewCache
}

func newCodeReviewCache() *codeReviewCache {
	return &codeReviewCache{repos: map[string]*repoReviewCache{}}
}

func (c *codeReviewCache) repo(repoURL string) *repoReviewCache {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	rc := c.repos[repoURL]
	if rc == nil {
		rc = &repoReviewCache{}
		c.repos[repoURL] = rc
	}
	return rc
}

// parseCommitList parses `git log --format=%H%x1f%s%x1e` output.
func parseCommitList(out []byte) []pushreq.Commit {
	commits := []pushreq.Commit{}
	for _, rec := range bytes.Split(out, []byte{0x1e}) {
		sha, subject, ok := strings.Cut(strings.TrimSpace(string(rec)), "\x1f")
		if ok && commitRe.MatchString(sha) && len(commits) < reviewCommitLimit {
			commits = append(commits, pushreq.Commit{SHA: sha, Subject: subject})
		}
	}
	return commits
}

// gitLine is one trimmed line of git output, "" when the command fails.
func (r *Runner) gitLine(ctx context.Context, runID string, args ...string) string {
	out, _, code, err := r.gitCmd(ctx, runID, nil, 4<<10, args...)
	if err != nil || code != 0 {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// commitList is `git log base..head`, newest first.
func (r *Runner) commitList(ctx context.Context, runID, base, head string) []pushreq.Commit {
	if base == head {
		return []pushreq.Commit{}
	}
	out, _, code, err := r.gitCmd(ctx, runID, nil, 1<<20, "log", "--no-color", "--format=%H%x1f%s%x1e", "-n", "100", base+".."+head)
	if err != nil || code != 0 {
		return []pushreq.Commit{}
	}
	return parseCommitList(out)
}

// snapshot reads one checkout's review in a single workspace process call. ok is
// false when the repository has no commit yet.
func (r *Runner) snapshot(ctx context.Context, runID string, env map[string]string, cache *repoReviewCache) (reviewSnapshot, bool, error) {
	cachedHead := ""
	if cache != nil {
		cachedHead = cache.head
	}
	res, err := r.runGitBatch(ctx, runID, gitBatchRequest{
		Mode:              "snapshot",
		CachedHead:        cachedHead,
		Pathspec:          codeChangePathspec,
		DiffLimit:         codeDiffReadLimit,
		UntrackedLimit:    codeUntrackedReadLimit,
		MaxFiles:          CodeChangeMaxFiles,
		MaxTreeFiles:      CodeReviewMaxTreeFiles,
		MaxFileBytes:      CodeReviewMaxFileBytes,
		OversizeFileBytes: CodeReviewOversizeFileBytes,
		MaxTreeTotalBytes: CodeReviewMaxTreeTotalBytes,
	})
	if err != nil {
		return reviewSnapshot{}, false, err
	}
	headRec, ok := res.get("head")
	head := strings.TrimSpace(string(headRec.Data))
	if !ok || headRec.Code != 0 || !commitRe.MatchString(head) {
		return reviewSnapshot{}, false, nil
	}
	branchRec, _ := res.get("branch")
	baseRec, _ := res.get("base")
	base := strings.TrimSpace(string(baseRec.Data))
	if !commitRe.MatchString(base) {
		base = head
	}
	commits := []pushreq.Commit{}
	if cr, ok := res.get("commits"); ok && cr.Code == 0 {
		commits = parseCommitList(cr.Data)
	}
	s := reviewSnapshot{
		head:    head,
		branch:  strings.TrimSpace(string(branchRec.Data)),
		base:    base,
		commits: commits,
	}
	files, err := r.buildCodeChanges(res, runID, env)
	if err != nil {
		return s, false, err
	}
	s.files = files
	if _, hasFilterErr := res.get("filter_err"); hasFilterErr {
		return s, true, nil
	}
	statusRec, hasStatus := res.get("status")
	s.dirty = hasStatus && statusRec.Code == 0 && len(statusRec.Data) > 0
	s.tree, s.treeTruncated = r.branchTree(ctx, runID, res, head, s.files, env, cache)
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
func (r *Runner) branchTree(ctx context.Context, runID string, res *gitBatchResult, head string, files []CodeChange, env map[string]string, cache *repoReviewCache) ([]CodeReviewFile, bool) {
	lsRec, hasLS := res.get("ls_tree_files")
	if !hasLS || lsRec.Code != 0 {
		return []CodeReviewFile{}, false
	}
	delRec, _ := res.get("ls_deleted")
	deleted := map[string]bool{}
	for _, rec := range bytes.Split(delRec.Data, []byte{0}) {
		if p := string(rec); p != "" {
			deleted[p] = true
		}
	}
	changedByPath := make(map[string]CodeChange, len(files))
	for _, ch := range files {
		if ch.Status == "deleted" {
			deleted[ch.Path] = true
			continue
		}
		if ch.Status == "renamed" && ch.OldPath != nil {
			deleted[*ch.OldPath] = true
		}
		changedByPath[ch.Path] = ch
	}

	pathSet := map[string]bool{}
	for _, rec := range bytes.Split(lsRec.Data, []byte{0}) {
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

	var headSize map[string]int
	var headIsBlob map[string]bool
	var blobData map[string][]byte

	if cache != nil && cache.head == head && head != "" {
		headSize = cache.headSize
		headIsBlob = cache.headIsBlob
		blobData = cache.blobData
		// If a previously unarchived unchanged file in a large repo became dirty on
		// the same HEAD, populate it lazily so tree contents stay complete.
		var filterEnv map[string]string
		var gotFilterEnv bool
		for _, p := range paths {
			ch, ok := changedByPath[p]
			if !ok || ch.Binary || !headIsBlob[p] || headSize[p] > CodeReviewOversizeFileBytes {
				continue
			}
			if _, ok := blobData[p]; ok {
				continue
			}
			if !gotFilterEnv {
				filterEnv, _ = r.repoFilterEnv(ctx, runID)
				gotFilterEnv = true
			}
			if raw, _, code, err := r.gitCmd(ctx, runID, filterEnv, CodeReviewOversizeFileBytes+1, "show", "HEAD:"+p); err == nil && code == 0 {
				blobData[p] = raw
			}
		}
	} else {
		headSize = map[string]int{}
		headIsBlob = map[string]bool{}
		blobData = map[string][]byte{}
		if treeRec, ok := res.get("ls_tree"); ok && treeRec.Code == 0 {
			for _, rec := range bytes.Split(treeRec.Data, []byte{0}) {
				if len(rec) == 0 {
					continue
				}
				meta, p, ok := strings.Cut(string(rec), "\t")
				if !ok || isWorkspaceExcluded(p) {
					continue
				}
				fields := strings.Fields(meta)
				if len(fields) < 4 {
					continue
				}
				if fields[1] == "blob" {
					headIsBlob[p] = true
					if n, err := strconv.Atoi(fields[3]); err == nil {
						headSize[p] = n
					}
				}
			}
		}
		for _, rec := range res.records {
			if strings.HasPrefix(rec.Key, "tar\x00") {
				tr := tar.NewReader(bytes.NewReader(rec.Data))
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
			} else if name, ok := strings.CutPrefix(rec.Key, "show\x00"); ok {
				blobData[name] = rec.Data
			}
		}
		if cache != nil {
			cache.head = head
			cache.headSize = headSize
			cache.headIsBlob = headIsBlob
			cache.blobData = blobData
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
func (r *Runner) saveCodeReviews(ctx context.Context, c runCtx, env map[string]string, live bool, cache *codeReviewCache) {
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
		rc := cache.repo(repo.RepoUrl)
		s, ok, err := r.snapshot(inRepository(tctx, repo.Directory), c.run.ID.String(), env, rc)
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
		var treeArg []byte
		treeChanged := rc == nil || !rc.hasSavedTree || !bytes.Equal(tree, rc.savedTreeJSON) || s.treeTruncated != rc.savedTreeTrunc
		if treeChanged {
			treeArg = tree
		}
		var branch *string
		if s.branch != "" {
			branch = &s.branch
		}
		if err := r.q().UpsertChatCodeReview(ctx, store.UpsertChatCodeReviewParams{ChatID: chat.ID, RepoUrl: repo.RepoUrl, Branch: branch,
			BaseSha: &s.base, HeadSha: &s.head, Commits: commits, Files: files, Dirty: s.dirty, Live: live, Tree: treeArg, TreeTruncated: s.treeTruncated}); err != nil {
			r.Log.Warn("save code review", "run", c.run.ID, "err", err)
			continue
		}
		if rc != nil && treeChanged {
			rc.hasSavedTree = true
			rc.savedTreeJSON = tree
			rc.savedTreeTrunc = s.treeTruncated
		}
	}
}

// reviewSignature changes whenever a checkout's commits, files or diff sizes
// do; the watcher refreshes the review only then. All checkouts are inspected
// in a single container invocation.
func (r *Runner) reviewSignature(ctx context.Context, c runCtx) string {
	chat, err := r.q().ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		return ""
	}
	repos, err := r.q().ChatRepositories(ctx, chat.ID)
	if err != nil || len(repos) == 0 {
		return ""
	}
	entries := make([]gitSignatureEntry, len(repos))
	for i, repo := range repos {
		entries[i] = gitSignatureEntry{Dir: repo.Directory}
	}
	res, err := r.runGitBatch(ctx, c.run.ID.String(), gitBatchRequest{
		Mode:     "signature",
		Pathspec: codeChangePathspec,
		Repos:    entries,
	})
	if err != nil {
		return ""
	}
	var b strings.Builder
	for i, repo := range repos {
		st, hasSt := res.get(fmt.Sprintf("sig\x00%d\x00status", i))
		ns, hasNs := res.get(fmt.Sprintf("sig\x00%d\x00numstat", i))
		if !hasSt && !hasNs {
			continue
		}
		b.WriteString(repo.RepoUrl)
		b.Write(st.Data)
		b.Write(ns.Data)
	}
	return b.String()
}

// watchCodeReview keeps a coding chat's review live while its turn runs, and
// returns a turn-scoped cache and a stop that waits for the watcher to finish.
func (r *Runner) watchCodeReview(ctx context.Context, c runCtx, env map[string]string) (*codeReviewCache, func()) {
	if c.run.Purpose != "chat" || !allowedScope(c.spec, "repo:write") {
		return nil, func() {}
	}
	cache := newCodeReviewCache()
	if CodeReviewInterval <= 0 {
		return cache, func() {}
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
			r.saveCodeReviews(wctx, c, env, true, cache)
		}
	}()
	return cache, func() { cancel(); wg.Wait() }
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

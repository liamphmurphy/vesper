package runner_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/pushreq"
	"github.com/liamphmurphy/vesper/server/internal/repositories"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// fakeGitHub serves the REST calls shipping makes, over a local bare
// repository standing in for github.com/acme/alpha.
type fakeGitHub struct {
	t     *testing.T
	bare  string
	mu    sync.Mutex
	pulls []map[string]any
	auth  []string
}

func (f *fakeGitHub) git(args ...string) (string, error) {
	out, err := exec.Command("git", append([]string{"-C", f.bare}, args...)...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func (f *fakeGitHub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.auth = append(f.auth, r.Header.Get("Authorization"))
	const repo = "/repos/acme/alpha"
	var in map[string]any
	_ = json.NewDecoder(r.Body).Decode(&in)
	reply := func(code int, v any) {
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(v)
	}
	switch p := r.URL.Path; {
	case r.Method == "GET" && strings.HasPrefix(p, repo+"/git/ref/heads/"):
		sha, err := f.git("rev-parse", "--verify", "-q", "refs/heads/"+strings.TrimPrefix(p, repo+"/git/ref/heads/"))
		if err != nil {
			reply(404, map[string]any{"message": "Not Found"})
			return
		}
		reply(200, map[string]any{"object": map[string]any{"sha": sha}})
	case r.Method == "POST" && p == repo+"/git/refs":
		if _, err := f.git("update-ref", in["ref"].(string), in["sha"].(string)); err != nil {
			reply(422, map[string]any{"message": "Object does not exist"})
			return
		}
		reply(201, map[string]any{})
	case r.Method == "PATCH" && strings.HasPrefix(p, repo+"/git/refs/heads/"):
		ref := "refs/heads/" + strings.TrimPrefix(p, repo+"/git/refs/heads/")
		if _, err := f.git("merge-base", "--is-ancestor", ref, in["sha"].(string)); err != nil {
			reply(422, map[string]any{"message": "Update is not a fast forward"})
			return
		}
		_, _ = f.git("update-ref", ref, in["sha"].(string))
		reply(200, map[string]any{})
	case r.Method == "DELETE" && strings.HasPrefix(p, repo+"/git/refs/heads/"):
		_, _ = f.git("update-ref", "-d", "refs/heads/"+strings.TrimPrefix(p, repo+"/git/refs/heads/"))
		w.WriteHeader(204)
	case r.Method == "GET" && p == repo+"/pulls":
		head := r.URL.Query().Get("head")
		var out []map[string]any
		for _, pr := range f.pulls {
			st, _ := pr["state"].(string)
			if st != "" && st != "open" {
				continue
			}
			headBranch, _ := pr["head_ref"].(string)
			if "acme:"+headBranch == head {
				out = append(out, pr)
			}
		}
		reply(200, out)
	case r.Method == "GET" && strings.HasPrefix(p, repo+"/pulls/"):
		num, err := strconv.Atoi(strings.TrimPrefix(p, repo+"/pulls/"))
		if err != nil {
			reply(404, map[string]any{"message": "Not Found"})
			return
		}
		for _, pr := range f.pulls {
			if n, _ := pr["number"].(int); n == num {
				headBranch, _ := pr["head_ref"].(string)
				headSHA, err := f.git("rev-parse", "--verify", "-q", "refs/heads/"+headBranch)
				if err != nil || headSHA == "" {
					headSHA, _ = pr["head_sha"].(string)
				}
				state, _ := pr["state"].(string)
				if state == "" {
					state = "open"
				}
				merged, _ := pr["merged"].(bool)
				reply(200, map[string]any{
					"number":   n,
					"html_url": pr["html_url"],
					"state":    state,
					"merged":   merged,
					"draft":    pr["draft"],
					"head":     map[string]any{"sha": headSHA, "ref": headBranch},
				})
				return
			}
		}
		reply(404, map[string]any{"message": "Not Found"})
	case r.Method == "POST" && p == repo+"/pulls":
		num := 7 + len(f.pulls)
		headBranch, _ := in["head"].(string)
		headSHA, _ := f.git("rev-parse", "--verify", "-q", "refs/heads/"+headBranch)
		pr := map[string]any{
			"number":   num,
			"html_url": "https://github.com/acme/alpha/pull/" + strconv.Itoa(num),
			"head":     map[string]any{"sha": headSHA, "ref": headBranch},
			"head_ref": headBranch,
			"head_sha": headSHA,
			"base":     in["base"],
			"title":    in["title"],
			"draft":    in["draft"],
			"state":    "open",
			"merged":   false,
		}
		f.pulls = append(f.pulls, pr)
		reply(201, pr)
	case r.Method == "GET" && strings.HasPrefix(p, repo+"/git/commits/"):
		sha := strings.TrimPrefix(p, repo+"/git/commits/")
		tree, err := f.git("rev-parse", "--verify", "-q", sha+"^{tree}")
		if err != nil {
			reply(404, map[string]any{"message": "Not Found"})
			return
		}
		reply(200, map[string]any{"sha": sha, "tree": map[string]any{"sha": tree}})
	case r.Method == "GET" && strings.HasPrefix(p, repo+"/compare/"):
		spec := strings.TrimPrefix(p, repo+"/compare/")
		base, head, ok := strings.Cut(spec, "...")
		if !ok {
			reply(404, map[string]any{"message": "Not Found"})
			return
		}
		baseSHA, err1 := f.git("rev-parse", "--verify", "-q", base+"^{commit}")
		headSHA, err2 := f.git("rev-parse", "--verify", "-q", head+"^{commit}")
		if err1 != nil || err2 != nil {
			reply(404, map[string]any{"message": "Not Found"})
			return
		}
		mb, err := f.git("merge-base", baseSHA, headSHA)
		if err != nil || mb == "" {
			reply(404, map[string]any{"message": "No common ancestor"})
			return
		}
		aheadStr, _ := f.git("rev-list", "--count", baseSHA+".."+headSHA)
		behindStr, _ := f.git("rev-list", "--count", headSHA+".."+baseSHA)
		ahead, _ := strconv.Atoi(aheadStr)
		behind, _ := strconv.Atoi(behindStr)
		status := "diverged"
		switch {
		case baseSHA == headSHA:
			status = "identical"
		case ahead == 0 && behind > 0:
			status = "behind"
		case ahead > 0 && behind == 0:
			status = "ahead"
		}
		baseTree, _ := f.git("rev-parse", baseSHA+"^{tree}")
		mbTree, _ := f.git("rev-parse", mb+"^{tree}")
		var commits []pushreq.CompareCommit
		if revList, err := f.git("rev-list", "--reverse", mb+".."+headSHA); err == nil && revList != "" {
			for _, csha := range strings.Split(revList, "\n") {
				csha = strings.TrimSpace(csha)
				if csha == "" {
					continue
				}
				ctree, _ := f.git("rev-parse", csha+"^{tree}")
				cc := pushreq.CompareCommit{SHA: csha}
				cc.Commit.Tree.SHA = ctree
				commits = append(commits, cc)
			}
		}
		var files []pushreq.CompareFile
		diffOut, _ := f.git("diff", "--raw", "--no-abbrev", "-M", mb, headSHA)
		for _, line := range strings.Split(diffOut, "\n") {
			if line == "" || !strings.HasPrefix(line, ":") {
				continue
			}
			meta, pathPart, ok := strings.Cut(line, "\t")
			if !ok {
				continue
			}
			fields := strings.Fields(meta)
			if len(fields) < 5 {
				continue
			}
			dstBlob := fields[3]
			st := fields[4]
			parts := strings.Split(pathPart, "\t")
			switch {
			case strings.HasPrefix(st, "R"):
				files = append(files, pushreq.CompareFile{Filename: parts[1], PreviousFilename: parts[0], Status: "renamed", SHA: dstBlob})
			case st == "A":
				files = append(files, pushreq.CompareFile{Filename: parts[0], Status: "added", SHA: dstBlob})
			case st == "D":
				files = append(files, pushreq.CompareFile{Filename: parts[0], Status: "removed"})
			default:
				files = append(files, pushreq.CompareFile{Filename: parts[0], Status: "modified", SHA: dstBlob})
			}
		}
		res := pushreq.CompareResult{
			Status: status, AheadBy: ahead, BehindBy: behind,
			Commits: commits, Files: files,
		}
		res.BaseCommit.SHA = baseSHA
		res.BaseCommit.Commit.Tree.SHA = baseTree
		res.MergeBaseCommit.SHA = mb
		res.MergeBaseCommit.Commit.Tree.SHA = mbTree
		reply(200, res)
	default:
		f.t.Errorf("unexpected GitHub call %s %s", r.Method, r.URL)
		reply(404, map[string]any{"message": "Not Found"})
	}
}

// A persona's push request is staged from a clean repository when its turn
// ends (the exact commit, on a staging branch), and shipping it needs only
// GitHub: the branch moves to that commit and a pull request opens, with the
// workspace untouched. The turn itself never holds the token.
func TestChatPushRequestIsStagedThenShipped(t *testing.T) {
	for _, name := range []string{"GH_TOKEN", "GITHUB_TOKEN", "GIT_PAT"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	bare := bareRepo(t)
	gitIn(t, bare, "symbolic-ref", "HEAD", "refs/heads/main")
	config := filepath.Join(t.TempDir(), "gitconfig")
	if out, err := exec.Command("git", "config", "--file", config, "url."+bare+".insteadOf", "https://github.com/acme/alpha.git").CombinedOutput(); err != nil {
		t.Fatalf("rewrite: %v %s", err, out)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	sec := e.runner.Secrets.(*secrets.Service)
	if _, err := sec.Set(e.ctx, e.ws, e.me.ID, secrets.SetInput{Name: "git:pat", Value: "ghp_testtoken123"}); err != nil {
		t.Fatal(err)
	}
	gh := &fakeGitHub{t: t, bare: bare}
	srv := httptest.NewServer(gh)
	t.Cleanup(srv.Close)
	e.runner.Cfg.GitHubAPIURL = srv.URL

	p := e.persona("Pusher", true, false)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{PersonaID: &p.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.SetChatRepository(e.ctx, e.ws, e.me.ID, chat.ID, "acme/alpha", nil); err != nil {
		t.Fatal(err)
	}
	dir := ".lazyagents/repos/acme/alpha"
	reply := e.postSh(chat.ID, "cd "+dir+" && git checkout -q -b feat/push-me && echo hi > new.txt && git add new.txt && git commit -qm 'Add new' && echo wip >> README.md && echo token=${GH_TOKEN:-none}")
	if !strings.Contains(reply, "err=<nil>") || !strings.Contains(reply, "token=none") {
		t.Fatalf("the turn must hold no token: %s", reply)
	}

	// The Code dock's review: the branch, its commit and the uncommitted edit.
	reviews, err := e.q.ChatCodeReviews(e.ctx, chat.ID)
	if err != nil || len(reviews) != 1 {
		t.Fatal(reviews, err)
	}
	rv := reviews[0]
	if rv.Branch == nil || *rv.Branch != "feat/push-me" || !rv.Dirty || rv.Live || !strings.Contains(string(rv.Commits), "Add new") ||
		!strings.Contains(string(rv.Files), `"new.txt"`) || !strings.Contains(string(rv.Files), `"README.md"`) {
		t.Fatalf("review: branch=%v dirty=%v live=%v commits=%s files=%.300s", *rv.Branch, rv.Dirty, rv.Live, rv.Commits, rv.Files)
	}

	run := e.chatRun(chat.ID)
	req, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run.ID,
		PersonaID: &p.ID, AgentID: run.AgentID, RepoUrl: "https://github.com/acme/alpha.git", Branch: "feat/push-me", Title: "Add new", Body: "Body"})
	if err != nil {
		t.Fatal(err)
	}
	// Committed after asking: staging takes the branch as the turn ends.
	e.postSh(chat.ID, "cd "+dir+" && echo two > two.txt && git add two.txt && git commit -qm 'Add two'")
	staged, err := e.q.GetPushRequest(e.ctx, store.GetPushRequestParams{ID: req.ID, WorkspaceID: e.ws, UserID: e.me.ID})
	if err != nil {
		t.Fatal(err)
	}
	msgsAfterTurn2 := e.messages(chat.ID)
	turn2Reply := msgsAfterTurn2[len(msgsAfterTurn2)-1]
	if staged.State != "pending" || staged.BaseBranch == nil || *staged.BaseBranch != "main" || staged.HeadSha == nil {
		t.Fatalf("staged = %+v (error %v)", staged, staged.Error)
	}
	if staged.MessageID == nil || *staged.MessageID != turn2Reply.ID {
		t.Fatalf("staged.MessageID = %v, want turn 2 reply %s", staged.MessageID, turn2Reply.ID)
	}
	var commits []pushreq.Commit
	_ = json.Unmarshal(staged.Commits, &commits)
	if len(commits) != 2 || commits[0].Subject != "Add two" || commits[1].Subject != "Add new" {
		t.Fatalf("commits = %+v", commits)
	}
	if !strings.Contains(string(staged.Files), "two.txt") || strings.Contains(string(staged.Files), "README.md") {
		t.Fatalf("staged files must be the commits only, not uncommitted work: %s", staged.Files)
	}
	stagingSHA, err := gh.git("rev-parse", "refs/heads/"+pushreq.StagingBranch(req.ID))
	if err != nil || stagingSHA != *staged.HeadSha {
		t.Fatalf("staging branch = %q (%v), want %s", stagingSHA, err, *staged.HeadSha)
	}
	if _, err := gh.git("rev-parse", "--verify", "-q", "refs/heads/feat/push-me"); err == nil {
		t.Fatal("nothing may reach the branch before the person approves")
	}

	// Approving ships through GitHub alone.
	claimed, err := e.q.ClaimPushRequest(e.ctx, store.ClaimPushRequestParams{ID: req.ID, WorkspaceID: e.ws, UserID: e.me.ID, Title: "Add new and two", Body: "Body", Draft: true})
	if err != nil {
		t.Fatal(err)
	}
	res, shipErr := pushreq.Ship(e.ctx, &pushreq.GitHub{BaseURL: srv.URL, Token: "ghp_testtoken123"}, claimed)
	done, err := pushreq.Finish(e.ctx, e.q, claimed, res, shipErr)
	if err != nil || done.State != "pushed" || done.PrNumber == nil || *done.PrNumber != 7 {
		t.Fatalf("shipped = %+v, %v (ship %v)", done, err, shipErr)
	}
	if sha, _ := gh.git("rev-parse", "refs/heads/feat/push-me"); sha != *staged.HeadSha {
		t.Fatalf("branch at %s, want %s", sha, *staged.HeadSha)
	}
	if _, err := gh.git("rev-parse", "--verify", "-q", "refs/heads/"+pushreq.StagingBranch(req.ID)); err == nil {
		t.Fatal("the staging branch should be gone")
	}
	if len(gh.pulls) != 1 || gh.pulls[0]["title"] != "Add new and two" || gh.pulls[0]["draft"] != true || gh.pulls[0]["base"] != "main" {
		t.Fatalf("pulls = %+v", gh.pulls)
	}
	for _, a := range gh.auth {
		if a != "Bearer ghp_testtoken123" {
			t.Fatalf("GitHub call authenticated as %q", a)
		}
	}
	repos, _ := e.q.ChatRepositories(e.ctx, chat.ID)
	if len(repos) != 1 || !strings.Contains(strings.Join(repos[0].WorkBranches, ","), "feat/push-me") {
		t.Fatalf("the chat should own the pushed branch: %+v", repos)
	}

	// A repository the person always allows ships at the end of the turn.
	if _, err := e.q.SetRepositoryPushPolicy(e.ctx, store.SetRepositoryPushPolicyParams{WorkspaceID: e.ws, UserID: e.me.ID, RepoUrl: "https://github.com/acme/alpha.git", AutoPush: true}); err != nil {
		t.Fatal(err)
	}
	again, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run.ID,
		PersonaID: &p.ID, AgentID: run.AgentID, RepoUrl: "https://github.com/acme/alpha.git", Branch: "feat/push-me", Title: "More"})
	if err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && echo three > three.txt && git add three.txt && git commit -qm 'Add three'")
	auto, _ := e.q.GetPushRequest(e.ctx, store.GetPushRequestParams{ID: again.ID, WorkspaceID: e.ws, UserID: e.me.ID})
	if auto.State != "pushed" || !auto.Auto {
		t.Fatalf("auto = %+v (error %v)", auto, auto.Error)
	}
	msgsAfterTurn3 := e.messages(chat.ID)
	turn3Reply := msgsAfterTurn3[len(msgsAfterTurn3)-1]
	if auto.MessageID == nil || *auto.MessageID != turn3Reply.ID {
		t.Fatalf("auto.MessageID = %v, want turn 3 reply %s", auto.MessageID, turn3Reply.ID)
	}
	firstAfterTurn3, _ := e.q.GetPushRequest(e.ctx, store.GetPushRequestParams{ID: req.ID, WorkspaceID: e.ws, UserID: e.me.ID})
	if firstAfterTurn3.MessageID == nil || *firstAfterTurn3.MessageID != turn2Reply.ID {
		t.Fatalf("first push request should stay anchored to turn 2 reply %s, got %v", turn2Reply.ID, firstAfterTurn3.MessageID)
	}
	if sha, _ := gh.git("rev-parse", "refs/heads/feat/push-me"); sha != *auto.HeadSha {
		t.Fatalf("branch at %s, want the fast-forward to %s", sha, *auto.HeadSha)
	}
	if len(gh.pulls) != 1 {
		t.Fatalf("the open pull request is reused, not duplicated: %+v", gh.pulls)
	}
}

func TestChatCodeReviewTreeSnapshotAndCleanup(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	bare := bareRepo(t)
	gitIn(t, bare, "symbolic-ref", "HEAD", "refs/heads/main")
	config := filepath.Join(t.TempDir(), "gitconfig")
	if out, err := exec.Command("git", "config", "--file", config, "url."+bare+".insteadOf", "https://github.com/acme/alpha.git").CombinedOutput(); err != nil {
		t.Fatalf("rewrite: %v %s", err, out)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", config)

	p := e.persona("TreeTester", true, false)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{PersonaID: &p.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.SetChatRepository(e.ctx, e.ws, e.me.ID, chat.ID, "acme/alpha", nil); err != nil {
		t.Fatal(err)
	}
	dir := ".lazyagents/repos/acme/alpha"
	cmd := strings.Join([]string{
		"cd " + dir,
		"git checkout -q -b feat/tree-view",
		"mkdir -p src assets big",
		`printf 'package src\nconst V = 1\n' > src/app.go`,
		"git mv old.txt renamed.txt",
		"git rm -q gone.txt",
		`python3 -c 'open("assets/icon.bin","wb").write(b"\x00\x01\x02\x03")'`,
		`python3 -c 'open("big/dump.txt","w").write("x"*140000)'`,
		"git add -A",
		`git commit -qm 'branch changes'`,
		`printf 'uncommitted line\n' > untracked.txt`,
		`mkdir -p .lazyagents/secret`,
		`printf 'hidden\n' > .lazyagents/secret/leak.txt`,
		`printf 'instructions\n' > AGENTS.md`,
	}, " && ")
	reply := e.postSh(chat.ID, cmd)
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatalf("command failed: %s", reply)
	}

	reviews, err := e.q.ChatCodeReviews(e.ctx, chat.ID)
	if err != nil || len(reviews) != 1 {
		t.Fatalf("reviews = %+v, err=%v", reviews, err)
	}
	rv := reviews[0]
	if rv.Branch == nil || *rv.Branch != "feat/tree-view" || !rv.Dirty || rv.Live || rv.HeadSha == nil {
		t.Fatalf("unexpected review header: %+v", rv)
	}
	var tree []runner.CodeReviewFile
	if err := json.Unmarshal(rv.Tree, &tree); err != nil {
		t.Fatalf("unmarshal tree: %v (%s)", err, rv.Tree)
	}
	byPath := make(map[string]runner.CodeReviewFile, len(tree))
	for _, f := range tree {
		byPath[f.Path] = f
	}
	// Unchanged tracked file from branch HEAD
	if f, ok := byPath["README.md"]; !ok || f.Binary || f.Truncated || f.Content == nil || *f.Content != "hello\n" {
		t.Fatalf("README.md in tree = %+v (ok=%v)", f, ok)
	}
	// Added nested file, renamed destination, and untracked file
	if f, ok := byPath["src/app.go"]; !ok || f.Content == nil || !strings.Contains(*f.Content, "const V = 1") {
		t.Fatalf("src/app.go = %+v (ok=%v)", f, ok)
	}
	if _, ok := byPath["renamed.txt"]; !ok {
		t.Fatalf("renamed.txt missing from tree: %+v", byPath)
	}
	if f, ok := byPath["untracked.txt"]; !ok || f.Content == nil || !strings.Contains(*f.Content, "uncommitted line") {
		t.Fatalf("untracked.txt = %+v (ok=%v)", f, ok)
	}
	// Deleted / renamed-from / workspace-excluded files are omitted from tree
	for _, excluded := range []string{"old.txt", "gone.txt", "AGENTS.md", ".lazyagents/secret/leak.txt"} {
		if _, ok := byPath[excluded]; ok {
			t.Fatalf("%s must not be in tree", excluded)
		}
	}
	// Binary and oversize boundaries
	if f, ok := byPath["assets/icon.bin"]; !ok || !f.Binary || f.Content != nil || f.Truncated {
		t.Fatalf("assets/icon.bin = %+v (ok=%v)", f, ok)
	}
	if f, ok := byPath["big/dump.txt"]; !ok || f.Binary || f.Content != nil || !f.Truncated {
		t.Fatalf("big/dump.txt = %+v (ok=%v)", f, ok)
	}

	// Simulate remote default-branch advancing AND workspace cleanup.
	other := t.TempDir()
	gitIn(t, other, "clone", "-q", bare, "work")
	work := filepath.Join(other, "work")
	if err := os.WriteFile(filepath.Join(work, "README.md"), []byte("newer remote main\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	gitIn(t, work, "add", "README.md")
	gitIn(t, work, "commit", "-qm", "advance main")
	gitIn(t, work, "push", "-q", "origin", "main")
	if err := os.RemoveAll(e.dir); err != nil {
		t.Fatal(err)
	}

	// Saved snapshot still serves the exact persona branch content after cleanup.
	after, err := e.q.ChatCodeReviews(e.ctx, chat.ID)
	if err != nil || len(after) != 1 || *after[0].HeadSha != *rv.HeadSha {
		t.Fatalf("after cleanup: %+v, err=%v", after, err)
	}
	var afterTree []runner.CodeReviewFile
	_ = json.Unmarshal(after[0].Tree, &afterTree)
	for _, f := range afterTree {
		if f.Path == "README.md" && (f.Content == nil || *f.Content != "hello\n") {
			t.Fatalf("README.md altered after cleanup: %+v", f)
		}
	}
}

func TestPushErrorDetailPreservesRemoteReasons(t *testing.T) {
	out := strings.Join([]string{
		"vesper-base abc123",
		"vesper-staged main",
		"remote: error: GH006: Protected branch update failed",
		"remote: refusing to allow a Personal Access Token to create or update workflow `.github/workflows/ci.yml` without `workflow` scope",
		"To https://github.com/acme/alpha.git",
		" ! [remote rejected] stage -> vesper-checkpoint/push/123 (refusing workflow update)",
		"error: failed to push some refs to 'https://github.com/acme/alpha.git'",
	}, "\n")
	got := runner.PushErrorDetail(out, nil)
	if !strings.Contains(got, "refusing to allow a Personal Access Token") {
		t.Fatalf("expected remote rejection reason in %q", got)
	}
	if strings.Contains(got, "vesper-base") || strings.Contains(got, "vesper-staged") {
		t.Fatalf("internal markers leaked into %q", got)
	}
	if !strings.Contains(got, "error: failed to push some refs") {
		t.Fatalf("expected final error line in %q", got)
	}
}

func TestChatPushRequestStageFailurePreservesRemoteReason(t *testing.T) {
	for _, name := range []string{"GH_TOKEN", "GITHUB_TOKEN", "GIT_PAT"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	bare := bareRepo(t)
	gitIn(t, bare, "symbolic-ref", "HEAD", "refs/heads/main")
	hookPath := filepath.Join(bare, "hooks", "pre-receive")
	if err := os.WriteFile(hookPath, []byte("#!/bin/sh\necho 'refusing workflow update without workflow scope' >&2\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	config := filepath.Join(t.TempDir(), "gitconfig")
	if out, err := exec.Command("git", "config", "--file", config, "url."+bare+".insteadOf", "https://github.com/acme/alpha.git").CombinedOutput(); err != nil {
		t.Fatalf("rewrite: %v %s", err, out)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	sec := e.runner.Secrets.(*secrets.Service)
	if _, err := sec.Set(e.ctx, e.ws, e.me.ID, secrets.SetInput{Name: "git:pat", Value: "ghp_testtoken123"}); err != nil {
		t.Fatal(err)
	}

	p := e.persona("Pusher", true, false)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{PersonaID: &p.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.SetChatRepository(e.ctx, e.ws, e.me.ID, chat.ID, "acme/alpha", nil); err != nil {
		t.Fatal(err)
	}
	dir := ".lazyagents/repos/acme/alpha"
	reply := e.postSh(chat.ID, "cd "+dir+" && git checkout -q -b feat/push-fail && echo hi > new.txt && git add new.txt && git commit -qm 'Add new'")
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatalf("setup command failed: %s", reply)
	}
	run := e.chatRun(chat.ID)
	req, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run.ID,
		PersonaID: &p.ID, AgentID: run.AgentID, RepoUrl: "https://github.com/acme/alpha.git", Branch: "feat/push-fail", Title: "Fail test", Body: "Body"})
	if err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && echo two > two.txt && git add two.txt && git commit -qm 'Add two'")

	failed, err := e.q.GetPushRequest(e.ctx, store.GetPushRequestParams{ID: req.ID, WorkspaceID: e.ws, UserID: e.me.ID})
	if err != nil {
		t.Fatal(err)
	}
	if failed.State != "failed" || failed.Error == nil {
		t.Fatalf("expected failed push request with error, got %+v", failed)
	}
	if !strings.Contains(*failed.Error, "refusing workflow update without workflow scope") {
		t.Fatalf("expected remote hook message in error, got %q", *failed.Error)
	}
}

func setupAlphaChatEnv(t *testing.T) (env, string, *fakeGitHub, *httptest.Server, store.ChatSession, string) {
	t.Helper()
	for _, name := range []string{"GH_TOKEN", "GITHUB_TOKEN", "GIT_PAT"} {
		t.Setenv(name, "")
		os.Unsetenv(name)
	}
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	bare := bareRepo(t)
	gitIn(t, bare, "symbolic-ref", "HEAD", "refs/heads/main")
	config := filepath.Join(t.TempDir(), "gitconfig")
	if out, err := exec.Command("git", "config", "--file", config, "url."+bare+".insteadOf", "https://github.com/acme/alpha.git").CombinedOutput(); err != nil {
		t.Fatalf("rewrite: %v %s", err, out)
	}
	t.Setenv("GIT_CONFIG_GLOBAL", config)
	sec := e.runner.Secrets.(*secrets.Service)
	if _, err := sec.Set(e.ctx, e.ws, e.me.ID, secrets.SetInput{Name: "git:pat", Value: "ghp_testtoken123"}); err != nil {
		t.Fatal(err)
	}
	gh := &fakeGitHub{t: t, bare: bare}
	srv := httptest.NewServer(gh)
	t.Cleanup(srv.Close)
	e.runner.Cfg.GitHubAPIURL = srv.URL

	p := e.persona("Pusher", true, false)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{PersonaID: &p.ID})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.SetChatRepository(e.ctx, e.ws, e.me.ID, chat.ID, "acme/alpha", nil); err != nil {
		t.Fatal(err)
	}
	return e, bare, gh, srv, chat, ".lazyagents/repos/acme/alpha"
}

func listCheckpointRefs(t *testing.T, bare string) []string {
	t.Helper()
	out := gitIn(t, bare, "for-each-ref", "--format=%(refname:short)", "refs/heads/vesper-checkpoint/")
	if strings.TrimSpace(out) == "" {
		return nil
	}
	var refs []string
	for _, ref := range strings.Split(strings.TrimSpace(out), "\n") {
		if ref != "" && !strings.HasPrefix(ref, pushreq.StagingPrefix) {
			refs = append(refs, ref)
		}
	}
	return refs
}

func TestChatCheckpointDeletedAfterPendingPushShipped(t *testing.T) {
	e, bare, _, srv, chat, dir := setupAlphaChatEnv(t)
	repoURL := "https://github.com/acme/alpha.git"

	reply := e.postSh(chat.ID, "cd "+dir+" && git checkout -q -b feat/x && echo one > one.txt && git add one.txt && git commit -qm 'Add one'")
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatal(reply)
	}
	run := e.chatRun(chat.ID)
	req, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{
		WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run.ID,
		AgentID: run.AgentID, RepoUrl: repoURL, Branch: "feat/x", Title: "Add one and two",
	})
	if err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && echo two > two.txt && git add two.txt && git commit -qm 'Add two'")

	// Chat goes idle before the person approves the push card -> checkpoint created.
	e.endIdleChat()
	ckpts := listCheckpointRefs(t, bare)
	if len(ckpts) != 1 || !strings.HasPrefix(ckpts[0], "vesper-checkpoint/chat/") {
		t.Fatalf("expected 1 chat checkpoint on bare, got %v", ckpts)
	}
	open, err := e.q.OpenChatCheckpoints(e.ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if err != nil || len(open) != 1 {
		t.Fatalf("open checkpoints = %+v, err = %v", open, err)
	}

	// Person approves & ships push request -> checkpoint is deleted.
	claimed, err := e.q.ClaimPushRequest(e.ctx, store.ClaimPushRequestParams{ID: req.ID, WorkspaceID: e.ws, UserID: e.me.ID, Title: "Add one and two", Body: ""})
	if err != nil {
		t.Fatal(err)
	}
	ghClient := &pushreq.GitHub{BaseURL: srv.URL, Token: "ghp_testtoken123"}
	res, shipErr := pushreq.Ship(e.ctx, ghClient, claimed)
	done, err := pushreq.Finish(e.ctx, e.q, claimed, res, shipErr)
	if err != nil || shipErr != nil {
		t.Fatalf("ship/finish failed: %v / %v", shipErr, err)
	}
	deleted, err := pushreq.CleanupChatCheckpoints(e.ctx, ghClient, e.q, done)
	if err != nil || len(deleted) != 1 {
		t.Fatalf("cleanup = %v, err = %v", deleted, err)
	}
	if refs := listCheckpointRefs(t, bare); len(refs) != 0 {
		t.Fatalf("checkpoint branch still on bare: %v", refs)
	}
	open, _ = e.q.OpenChatCheckpoints(e.ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 0 {
		t.Fatalf("expected 0 open checkpoints, got %+v", open)
	}
	repos, _ := e.q.ChatRepositories(e.ctx, chat.ID)
	if len(repos) != 1 || repos[0].CheckpointBranch != nil {
		t.Fatalf("expected checkpoint_branch cleared, got %+v", repos)
	}

	// Next segment starts cleanly and SetupScript tolerates a missing checkpoint ref.
	reply = e.postSh(chat.ID, "cd "+dir+" && git checkout -q feat/x && cat one.txt two.txt")
	if !strings.Contains(reply, "err=<nil>") || !strings.Contains(reply, "one") || !strings.Contains(reply, "two") {
		t.Fatalf("next segment failed: %s", reply)
	}
	gone := ckpts[0]
	resilientDir := filepath.Join(t.TempDir(), "resilient")
	script := repositories.SetupScript(bare, resilientDir, nil, &gone, "Tester", "tester@example.com")
	if out, err := exec.Command("sh", "-c", script).CombinedOutput(); err != nil || !strings.Contains(string(out), "is no longer on origin") {
		t.Fatalf("SetupScript should tolerate deleted checkpoint, got err=%v out=%s", err, out)
	}
}

func TestChatCheckpointKeptWhenUncommittedWorkNotInPR(t *testing.T) {
	e, bare, _, srv, chat, dir := setupAlphaChatEnv(t)
	repoURL := "https://github.com/acme/alpha.git"

	reply := e.postSh(chat.ID, "cd "+dir+" && git checkout -q -b feat/wip && echo c1 > c1.txt && git add c1.txt && git commit -qm 'C1' && echo wip > wip.txt")
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatal(reply)
	}
	run := e.chatRun(chat.ID)
	req, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{
		WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run.ID,
		AgentID: run.AgentID, RepoUrl: repoURL, Branch: "feat/wip", Title: "C1",
	})
	if err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && git status -s")
	e.endIdleChat()

	ckpts := listCheckpointRefs(t, bare)
	if len(ckpts) != 1 {
		t.Fatalf("expected 1 checkpoint, got %v", ckpts)
	}

	// Shipping C1 must KEEP the checkpoint because wip.txt is not in C1.
	claimed, err := e.q.ClaimPushRequest(e.ctx, store.ClaimPushRequestParams{ID: req.ID, WorkspaceID: e.ws, UserID: e.me.ID, Title: "C1", Body: ""})
	if err != nil {
		t.Fatal(err)
	}
	ghClient := &pushreq.GitHub{BaseURL: srv.URL, Token: "ghp_testtoken123"}
	res, shipErr := pushreq.Ship(e.ctx, ghClient, claimed)
	done, err := pushreq.Finish(e.ctx, e.q, claimed, res, shipErr)
	if err != nil || shipErr != nil {
		t.Fatalf("ship failed: %v / %v", shipErr, err)
	}
	deleted, err := pushreq.CleanupChatCheckpoints(e.ctx, ghClient, e.q, done)
	if err != nil || len(deleted) != 0 {
		t.Fatalf("expected 0 deleted, got %v / %v", deleted, err)
	}
	if refs := listCheckpointRefs(t, bare); len(refs) != 1 {
		t.Fatalf("checkpoint with uncommitted work was prematurely deleted: %v", refs)
	}

	// Next segment recovers wip.txt, commits it, and ships via auto_push -> NOW deleted.
	if _, err := e.q.SetRepositoryPushPolicy(e.ctx, store.SetRepositoryPushPolicyParams{WorkspaceID: e.ws, UserID: e.me.ID, RepoUrl: repoURL, AutoPush: true}); err != nil {
		t.Fatal(err)
	}
	reply = e.postSh(chat.ID, "cd "+dir+" && cat wip.txt && git reset --soft HEAD~1 && git checkout -q -B feat/wip && git add wip.txt && git commit -qm 'Add wip'")
	if !strings.Contains(reply, "wip") || !strings.Contains(reply, "err=<nil>") {
		t.Fatalf("recovery failed: %s", reply)
	}
	run2 := e.chatRun(chat.ID)
	if _, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{
		WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run2.ID,
		AgentID: run2.AgentID, RepoUrl: repoURL, Branch: "feat/wip", Title: "Add wip",
	}); err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && git status -s")

	if refs := listCheckpointRefs(t, bare); len(refs) != 0 {
		t.Fatalf("expected checkpoint deleted after follow-up push, still got %v", refs)
	}
	open, _ := e.q.OpenChatCheckpoints(e.ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 0 {
		t.Fatalf("expected 0 open checkpoints, got %+v", open)
	}
	repos, _ := e.q.ChatRepositories(e.ctx, chat.ID)
	if len(repos) != 1 || repos[0].CheckpointBranch != nil {
		t.Fatalf("expected checkpoint_branch cleared, got %+v", repos)
	}
}

func TestChatIdleAfterPRDoesNotCreateRedundantCheckpoint(t *testing.T) {
	e, bare, gh, _, chat, dir := setupAlphaChatEnv(t)
	repoURL := "https://github.com/acme/alpha.git"

	if _, err := e.q.SetRepositoryPushPolicy(e.ctx, store.SetRepositoryPushPolicyParams{WorkspaceID: e.ws, UserID: e.me.ID, RepoUrl: repoURL, AutoPush: true}); err != nil {
		t.Fatal(err)
	}
	reply := e.postSh(chat.ID, "cd "+dir+" && git checkout -q -b feat/auto && echo auto > auto.txt && git add auto.txt && git commit -qm 'Auto'")
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatal(reply)
	}
	run := e.chatRun(chat.ID)
	if _, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{
		WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run.ID,
		AgentID: run.AgentID, RepoUrl: repoURL, Branch: "feat/auto", Title: "Auto",
	}); err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && git status -s")
	e.endIdleChat()
	if refs := listCheckpointRefs(t, bare); len(refs) != 0 {
		t.Fatalf("idle after auto-shipped PR created checkpoint: %v", refs)
	}

	// Merged + remote branch deleted (squash merge with new commit SHA on main): still no redundant checkpoint.
	reply = e.postSh(chat.ID, "cd "+dir+" && git checkout -q -b feat/squashed && echo sq > sq.txt && git add sq.txt && git commit -qm 'Squashed'")
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatal(reply)
	}
	run2 := e.chatRun(chat.ID)
	if _, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{
		WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run2.ID,
		AgentID: run2.AgentID, RepoUrl: repoURL, Branch: "feat/squashed", Title: "Squashed",
	}); err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && git status -s")

	// Simulate squash merge onto main and deletion of feat/squashed on remote.
	tmpWork := filepath.Join(t.TempDir(), "squash")
	gitIn(t, filepath.Dir(tmpWork), "clone", "-q", bare, tmpWork)
	gitIn(t, tmpWork, "config", "user.name", "Merger")
	gitIn(t, tmpWork, "config", "user.email", "merger@example.com")
	gitIn(t, tmpWork, "merge", "--squash", "origin/feat/squashed")
	gitIn(t, tmpWork, "commit", "-qm", "Squashed (#8)")
	gitIn(t, tmpWork, "push", "-q", "origin", "main")
	gitIn(t, bare, "update-ref", "-d", "refs/heads/feat/squashed")
	gh.mu.Lock()
	gh.pulls[len(gh.pulls)-1]["state"] = "closed"
	gh.pulls[len(gh.pulls)-1]["merged"] = true
	gh.mu.Unlock()

	e.endIdleChat()
	if refs := listCheckpointRefs(t, bare); len(refs) != 0 {
		t.Fatalf("idle after squash-merged & deleted PR branch created redundant checkpoint: %v", refs)
	}
}

func TestChatMultipleCheckpointsAllDeletedOnShip(t *testing.T) {
	e, bare, _, _, chat, dir := setupAlphaChatEnv(t)
	repoURL := "https://github.com/acme/alpha.git"

	// Segment 1 leaves uncommitted a.txt -> ckpt-1
	reply := e.postSh(chat.ID, "cd "+dir+" && git checkout -q -b feat/multi && echo a > a.txt")
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatal(reply)
	}
	e.endIdleChat()

	// Segment 2 recovers ckpt-1, leaves uncommitted b.txt -> ckpt-2
	reply = e.postSh(chat.ID, "cd "+dir+" && cat a.txt && echo b > b.txt")
	if !strings.Contains(reply, "err=<nil>") || !strings.Contains(reply, "a") {
		t.Fatal(reply)
	}
	e.endIdleChat()

	ckpts := listCheckpointRefs(t, bare)
	if len(ckpts) != 2 {
		t.Fatalf("expected 2 checkpoints on bare, got %v", ckpts)
	}
	open, _ := e.q.OpenChatCheckpoints(e.ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 2 {
		t.Fatalf("expected 2 open checkpoints in DB, got %+v", open)
	}

	// Segment 3 recovers ckpt-2, squashes cleanly into a new commit on feat/multi, ships via auto_push.
	if _, err := e.q.SetRepositoryPushPolicy(e.ctx, store.SetRepositoryPushPolicyParams{WorkspaceID: e.ws, UserID: e.me.ID, RepoUrl: repoURL, AutoPush: true}); err != nil {
		t.Fatal(err)
	}
	reply = e.postSh(chat.ID, "cd "+dir+" && cat a.txt b.txt && git checkout -q -B feat/multi && git reset --soft main && git add -A && git commit -qm 'Clean multi PR'")
	if !strings.Contains(reply, "err=<nil>") {
		t.Fatal(reply)
	}
	run3 := e.chatRun(chat.ID)
	if _, err := e.q.CreatePushRequest(e.ctx, store.CreatePushRequestParams{
		WorkspaceID: e.ws, UserID: e.me.ID, ChatID: chat.ID, RunID: &run3.ID,
		AgentID: run3.AgentID, RepoUrl: repoURL, Branch: "feat/multi", Title: "Clean multi PR",
	}); err != nil {
		t.Fatal(err)
	}
	e.postSh(chat.ID, "cd "+dir+" && git status -s")

	if refs := listCheckpointRefs(t, bare); len(refs) != 0 {
		t.Fatalf("expected all checkpoints deleted after ship, still got %v", refs)
	}
	open, _ = e.q.OpenChatCheckpoints(e.ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 0 {
		t.Fatalf("expected 0 open checkpoints, got %+v", open)
	}
	repos, _ := e.q.ChatRepositories(e.ctx, chat.ID)
	if len(repos) != 1 || repos[0].CheckpointBranch != nil {
		t.Fatalf("expected checkpoint_branch cleared, got %+v", repos)
	}
}

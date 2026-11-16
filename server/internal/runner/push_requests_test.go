package runner_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/pushreq"
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
			if "acme:"+pr["head"].(string) == head {
				out = append(out, pr)
			}
		}
		reply(200, out)
	case r.Method == "POST" && p == repo+"/pulls":
		pr := map[string]any{"number": 7 + len(f.pulls), "html_url": "https://github.com/acme/alpha/pull/7", "head": in["head"], "base": in["base"], "title": in["title"], "draft": in["draft"]}
		f.pulls = append(f.pulls, pr)
		reply(201, pr)
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

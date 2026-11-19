package pushreq

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestParsePRURL(t *testing.T) {
	tests := []struct {
		url    string
		wantOK bool
		owner  string
		name   string
		num    int
	}{
		{"https://github.com/acme/alpha/pull/42", true, "acme", "alpha", 42},
		{"https://github.com/acme/alpha/pull/42/files?w=1#diff", true, "acme", "alpha", 42},
		{"  https://github.com/acme-org/app.go/pull/7  ", true, "acme-org", "app.go", 7},
		{"https://github.com/acme/alpha/issues/42", false, "", "", 0},
		{"https://gitlab.com/acme/alpha/pull/42", false, "", "", 0},
		{"https://github.com/acme/alpha/pull/0", false, "", "", 0},
		{"not-a-url", false, "", "", 0},
	}
	for _, tc := range tests {
		o, n, num, ok := ParsePRURL(tc.url)
		if ok != tc.wantOK || o != tc.owner || n != tc.name || num != tc.num {
			t.Errorf("ParsePRURL(%q) = (%q,%q,%d,%v), want (%q,%q,%d,%v)", tc.url, o, n, num, ok, tc.owner, tc.name, tc.num, tc.wantOK)
		}
	}
}

type testRepo struct {
	t    *testing.T
	dir  string
	bare string
}

func newTestRepo(t *testing.T) *testRepo {
	t.Helper()
	root := t.TempDir()
	work := filepath.Join(root, "work")
	bare := filepath.Join(root, "bare.git")
	run := func(dir string, args ...string) string {
		t.Helper()
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
		}
		return strings.TrimSpace(string(out))
	}
	if out, err := exec.Command("git", "init", "-q", "-b", "main", work).CombinedOutput(); err != nil {
		t.Fatalf("git init: %v %s", err, out)
	}
	run(work, "config", "user.name", "Test")
	run(work, "config", "user.email", "test@example.com")
	if err := os.WriteFile(filepath.Join(work, "README.md"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(work, "old.txt"), []byte("old content\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run(work, "add", "-A")
	run(work, "commit", "-qm", "init")
	if out, err := exec.Command("git", "clone", "-q", "--bare", work, bare).CombinedOutput(); err != nil {
		t.Fatalf("git clone --bare: %v %s", err, out)
	}
	run(work, "remote", "add", "origin", bare)
	return &testRepo{t: t, dir: work, bare: bare}
}

func (r *testRepo) git(args ...string) string {
	r.t.Helper()
	cmd := exec.Command("git", append([]string{"-C", r.dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		r.t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func (r *testRepo) gitBare(args ...string) (string, error) {
	cmd := exec.Command("git", append([]string{"-C", r.bare}, args...)...)
	out, err := cmd.CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func (r *testRepo) write(rel, content string) {
	r.t.Helper()
	p := filepath.Join(r.dir, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

func (r *testRepo) commit(msg string) string {
	r.git("add", "-A")
	r.git("commit", "-qm", msg)
	return r.git("rev-parse", "HEAD")
}

func (r *testRepo) pushBranch(branch string) string {
	r.git("push", "-q", "-f", "origin", "HEAD:refs/heads/"+branch)
	return r.git("rev-parse", "HEAD")
}

func (r *testRepo) githubHandler(compareCalls *atomic.Int32) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		const prefix = "/repos/acme/alpha"
		reply := func(code int, v any) {
			w.WriteHeader(code)
			_ = json.NewEncoder(w).Encode(v)
		}
		p := req.URL.Path
		switch {
		case req.Method == "GET" && strings.HasPrefix(p, prefix+"/git/ref/heads/"):
			branch := strings.TrimPrefix(p, prefix+"/git/ref/heads/")
			sha, err := r.gitBare("rev-parse", "--verify", "-q", "refs/heads/"+branch)
			if err != nil {
				reply(404, map[string]any{"message": "Not Found"})
				return
			}
			reply(200, map[string]any{"object": map[string]any{"sha": sha}})

		case req.Method == "DELETE" && strings.HasPrefix(p, prefix+"/git/refs/heads/"):
			branch := strings.TrimPrefix(p, prefix+"/git/refs/heads/")
			if _, err := r.gitBare("rev-parse", "--verify", "-q", "refs/heads/"+branch); err != nil {
				reply(404, map[string]any{"message": "Not Found"})
				return
			}
			_, _ = r.gitBare("update-ref", "-d", "refs/heads/"+branch)
			w.WriteHeader(204)

		case req.Method == "GET" && strings.HasPrefix(p, prefix+"/git/commits/"):
			sha := strings.TrimPrefix(p, prefix+"/git/commits/")
			tree, err := r.gitBare("rev-parse", "--verify", "-q", sha+"^{tree}")
			if err != nil {
				reply(404, map[string]any{"message": "Not Found"})
				return
			}
			reply(200, map[string]any{"sha": sha, "tree": map[string]any{"sha": tree}})

		case req.Method == "GET" && strings.HasPrefix(p, prefix+"/compare/"):
			if compareCalls != nil {
				compareCalls.Add(1)
			}
			spec := strings.TrimPrefix(p, prefix+"/compare/")
			base, head, ok := strings.Cut(spec, "...")
			if !ok {
				reply(404, map[string]any{"message": "Not Found"})
				return
			}
			baseSHA, err1 := r.gitBare("rev-parse", "--verify", "-q", base+"^{commit}")
			headSHA, err2 := r.gitBare("rev-parse", "--verify", "-q", head+"^{commit}")
			if err1 != nil || err2 != nil {
				reply(404, map[string]any{"message": "Not Found"})
				return
			}
			mb, err := r.gitBare("merge-base", baseSHA, headSHA)
			if err != nil || mb == "" {
				reply(404, map[string]any{"message": "No common ancestor"})
				return
			}
			aheadStr, _ := r.gitBare("rev-list", "--count", baseSHA+".."+headSHA)
			behindStr, _ := r.gitBare("rev-list", "--count", headSHA+".."+baseSHA)
			ahead, behind := 0, 0
			_, _ = strings.NewReader(aheadStr), strings.NewReader(behindStr)
			for _, c := range aheadStr {
				ahead = ahead*10 + int(c-'0')
			}
			for _, c := range behindStr {
				behind = behind*10 + int(c-'0')
			}
			status := "diverged"
			switch {
			case baseSHA == headSHA:
				status = "identical"
			case ahead == 0 && behind > 0:
				status = "behind"
			case ahead > 0 && behind == 0:
				status = "ahead"
			}
			baseTree, _ := r.gitBare("rev-parse", baseSHA+"^{tree}")
			mbTree, _ := r.gitBare("rev-parse", mb+"^{tree}")

			var commits []CompareCommit
			if revList, err := r.gitBare("rev-list", "--reverse", mb+".."+headSHA); err == nil && revList != "" {
				for _, csha := range strings.Split(revList, "\n") {
					csha = strings.TrimSpace(csha)
					if csha == "" {
						continue
					}
					ctree, _ := r.gitBare("rev-parse", csha+"^{tree}")
					cc := CompareCommit{SHA: csha}
					cc.Commit.Tree.SHA = ctree
					commits = append(commits, cc)
				}
			}
			var files []CompareFile
			diffOut, _ := r.gitBare("diff", "--raw", "--no-abbrev", "-M", mb, headSHA)
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
					files = append(files, CompareFile{Filename: parts[1], PreviousFilename: parts[0], Status: "renamed", SHA: dstBlob})
				case st == "A":
					files = append(files, CompareFile{Filename: parts[0], Status: "added", SHA: dstBlob})
				case st == "D":
					files = append(files, CompareFile{Filename: parts[0], Status: "removed"})
				default:
					files = append(files, CompareFile{Filename: parts[0], Status: "modified", SHA: dstBlob})
				}
			}
			res := CompareResult{
				Status: status, AheadBy: ahead, BehindBy: behind,
				Commits: commits, Files: files,
			}
			res.BaseCommit.SHA = baseSHA
			res.BaseCommit.Commit.Tree.SHA = baseTree
			res.MergeBaseCommit.SHA = mb
			res.MergeBaseCommit.Commit.Tree.SHA = mbTree
			reply(200, res)

		default:
			reply(404, map[string]any{"message": "Not Found"})
		}
	})
}

func TestCheckpointContainedGitCases(t *testing.T) {
	ctx := context.Background()

	t.Run("exact commit match skips compare", func(t *testing.T) {
		r := newTestRepo(t)
		var calls atomic.Int32
		srv := httptest.NewServer(r.githubHandler(&calls))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		r.git("checkout", "-qb", "feat/a")
		r.write("a.txt", "a\n")
		sha := r.commit("add a")
		r.pushBranch("feat/a")
		r.pushBranch("vesper-checkpoint/chat/1")

		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: sha}, store.RunCheckpoint{}, sha, false)
		if err != nil || !ok {
			t.Fatalf("got (%v, %v), want (true, nil)", ok, err)
		}
		if calls.Load() != 0 {
			t.Fatalf("expected 0 compare calls on exact SHA match, got %d", calls.Load())
		}
	})

	t.Run("strict ancestor deleted", func(t *testing.T) {
		r := newTestRepo(t)
		srv := httptest.NewServer(r.githubHandler(nil))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		r.git("checkout", "-qb", "feat/a")
		r.write("a.txt", "a1\n")
		ckptSHA := r.commit("c1")
		r.pushBranch("vesper-checkpoint/chat/1")
		r.write("b.txt", "b\n")
		prSHA := r.commit("c2")
		r.pushBranch("feat/a")

		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA}, store.RunCheckpoint{}, ckptSHA, false)
		if err != nil || !ok {
			t.Fatalf("got (%v, %v), want (true, nil)", ok, err)
		}
	})

	t.Run("identical tree snapshot (amended or squashed)", func(t *testing.T) {
		r := newTestRepo(t)
		srv := httptest.NewServer(r.githubHandler(nil))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		r.git("checkout", "-qb", "feat/a")
		r.write("a.txt", "a\n")
		ckptSHA := r.commit("wip commit")
		r.pushBranch("vesper-checkpoint/chat/1")

		r.git("commit", "--amend", "-qm", "clean PR commit")
		prSHA := r.git("rev-parse", "HEAD")
		r.pushBranch("feat/a")

		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA}, store.RunCheckpoint{}, ckptSHA, false)
		if err != nil || !ok {
			t.Fatalf("got (%v, %v), want (true, nil)", ok, err)
		}
	})

	t.Run("rebased checkpoint onto newer main plus extra PR commits", func(t *testing.T) {
		r := newTestRepo(t)
		srv := httptest.NewServer(r.githubHandler(nil))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		// Create feat/a off initial main
		r.git("checkout", "-qb", "feat/a")
		r.write("feature.txt", "v1\n")
		r.git("mv", "old.txt", "renamed.txt")
		ckptSHA := r.commit("feature + rename")
		r.pushBranch("vesper-checkpoint/chat/1")

		// Advance main on a separate file
		r.git("checkout", "-q", "main")
		r.write("main_only.txt", "main update\n")
		r.commit("main advances")
		r.pushBranch("main")

		// Rebase feat/a onto newer main and add another commit on another file
		r.git("checkout", "-q", "feat/a")
		r.git("rebase", "-q", "main")
		r.write("followup.txt", "extra\n")
		prSHA := r.commit("followup")
		r.pushBranch("feat/a")

		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA}, store.RunCheckpoint{}, ckptSHA, false)
		if err != nil || !ok {
			t.Fatalf("rebased checkpoint should be contained, got (%v, %v)", ok, err)
		}
	})

	t.Run("recovered checkpoint amended and evolved with clean head", func(t *testing.T) {
		r := newTestRepo(t)
		srv := httptest.NewServer(r.githubHandler(nil))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		r.git("checkout", "-qb", "feat/a")
		r.write("wip.txt", "draft\n")
		ckptSHA := r.commit("Vesper checkpoint: uncommitted work")
		r.pushBranch("vesper-checkpoint/chat/1")

		// Amend wip.txt further cleanly
		r.git("reset", "--soft", "HEAD~1")
		r.write("wip.txt", "polished\n")
		r.write("extra.txt", "more\n")
		prSHA := r.commit("final work")
		r.pushBranch("feat/a")

		ckpt := store.RunCheckpoint{HasUncommitted: true, SourceBranch: "feat/a"}
		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{
			Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA, CleanHead: true,
		}, ckpt, ckptSHA, true)
		if err != nil || !ok {
			t.Fatalf("recovered evolved checkpoint with clean head should be contained, got (%v, %v)", ok, err)
		}

		// With dirty workspace (CleanHead: false), must NOT delete because local uncommitted edits may differ
		okDirty, err := CheckpointContained(ctx, gh, CheckpointTarget{
			Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA, CleanHead: false,
		}, ckpt, ckptSHA, true)
		if err != nil || okDirty {
			t.Fatalf("dirty workspace must NOT delete diverged evolved checkpoint, got (%v, %v)", okDirty, err)
		}

		// Without recovery link (recoveredByTarget: false), must NOT delete
		okUnrecovered, err := CheckpointContained(ctx, gh, CheckpointTarget{
			Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA, CleanHead: true,
		}, ckpt, ckptSHA, false)
		if err != nil || okUnrecovered {
			t.Fatalf("unrecovered evolved checkpoint must NOT be deleted, got (%v, %v)", okUnrecovered, err)
		}
	})

	t.Run("checkpoint with extra unpushed commit or uncommitted file is kept", func(t *testing.T) {
		r := newTestRepo(t)
		srv := httptest.NewServer(r.githubHandler(nil))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		r.git("checkout", "-qb", "feat/a")
		r.write("a.txt", "shipped\n")
		prSHA := r.commit("c1")
		r.pushBranch("feat/a")

		// Extra commit/uncommitted work on top of shipped PR head
		r.write("wip.txt", "not shipped yet\n")
		ckptSHA := r.commit("Vesper checkpoint: uncommitted work")
		r.pushBranch("vesper-checkpoint/chat/1")

		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA, CleanHead: false}, store.RunCheckpoint{HasUncommitted: true}, ckptSHA, true)
		if err != nil || ok {
			t.Fatalf("ahead checkpoint must be kept, got (%v, %v)", ok, err)
		}
	})

	t.Run("unrelated branch PR does not delete checkpoint on another branch", func(t *testing.T) {
		r := newTestRepo(t)
		srv := httptest.NewServer(r.githubHandler(nil))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		// Branch feat/a has checkpoint
		r.git("checkout", "-qb", "feat/a")
		r.write("a.go", "package a\n")
		ckptSHA := r.commit("feat a")
		r.pushBranch("vesper-checkpoint/chat/1")

		// Separate PR fix/typo on main
		r.git("checkout", "-qb", "fix/typo", "main")
		r.write("README.md", "fixed\n")
		prSHA := r.commit("fix typo")
		r.pushBranch("fix/typo")

		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{
			Owner: "acme", Name: "alpha", PRBranch: "fix/typo", PRHeadSHA: prSHA, CleanHead: true,
		}, store.RunCheckpoint{SourceBranch: "feat/a"}, ckptSHA, true)
		if err != nil || ok {
			t.Fatalf("checkpoint on feat/a must NOT be deleted by fix/typo PR, got (%v, %v)", ok, err)
		}
	})

	t.Run("recovered checkpoint missing a deleted file in PR is kept", func(t *testing.T) {
		r := newTestRepo(t)
		srv := httptest.NewServer(r.githubHandler(nil))
		defer srv.Close()
		gh := &GitHub{BaseURL: srv.URL, Token: "t"}

		r.git("checkout", "-qb", "feat/a")
		r.write("one.txt", "1\n")
		r.write("two.txt", "2\n")
		ckptSHA := r.commit("both files")
		r.pushBranch("vesper-checkpoint/chat/1")

		// PR only has one.txt, dropped two.txt
		r.git("reset", "--hard", "HEAD~1")
		r.write("one.txt", "1 updated\n")
		prSHA := r.commit("only one")
		r.pushBranch("feat/a")

		ok, err := CheckpointContained(ctx, gh, CheckpointTarget{
			Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: prSHA, CleanHead: true,
		}, store.RunCheckpoint{HasUncommitted: true, SourceBranch: "feat/a"}, ckptSHA, true)
		if err != nil || ok {
			t.Fatalf("checkpoint with missing file must NOT be deleted, got (%v, %v)", ok, err)
		}
	})
}

func TestCheckpointContainedTruncatedDiffAndErrors(t *testing.T) {
	ctx := context.Background()

	t.Run("truncated diff (>=300 files) is never deleted", func(t *testing.T) {
		files := make([]CompareFile, 300)
		for i := range files {
			files[i] = CompareFile{Filename: "f.txt", Status: "modified", SHA: "blob"}
		}
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if strings.Contains(r.URL.Path, "/git/commits/") {
				_ = json.NewEncoder(w).Encode(map[string]any{"tree": map[string]any{"sha": "other-tree"}})
				return
			}
			res := CompareResult{Status: "diverged", AheadBy: 1, BehindBy: 1, Files: files}
			res.BaseCommit.Commit.Tree.SHA = "pr-tree"
			res.MergeBaseCommit.SHA = "mb"
			res.MergeBaseCommit.Commit.Tree.SHA = "mb-tree"
			_ = json.NewEncoder(w).Encode(res)
		}))
		defer srv.Close()

		ok, err := CheckpointContained(ctx, &GitHub{BaseURL: srv.URL, Token: "t"}, CheckpointTarget{
			Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: "prsha", CleanHead: true,
		}, store.RunCheckpoint{HasUncommitted: true, SourceBranch: "feat/a"}, "ckptsha", true)
		if err != nil || ok {
			t.Fatalf("truncated diff must return (false, nil), got (%v, %v)", ok, err)
		}
	})

	t.Run("transient error returns error and avoids marking checked", func(t *testing.T) {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(http.StatusInternalServerError)
			_, _ = w.Write([]byte(`{"message":"server error"}`))
		}))
		defer srv.Close()

		ok, err := CheckpointContained(ctx, &GitHub{BaseURL: srv.URL, Token: "t"}, CheckpointTarget{
			Owner: "acme", Name: "alpha", PRBranch: "feat/a", PRHeadSHA: "prsha",
		}, store.RunCheckpoint{}, "ckptsha", false)
		if err == nil || ok {
			t.Fatalf("expected error on 500, got (%v, %v)", ok, err)
		}
	})
}

func TestCleanupCheckpointsLifecycleAndSkipChecked(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	agents, err := q.ListAgents(ctx, ws)
	if err != nil || len(agents) == 0 {
		t.Fatal(err)
	}
	ag := agents[0]
	chat, err := q.CreateChatSession(ctx, store.CreateChatSessionParams{
		WorkspaceID: ws, CreatedBy: me.ID, AgentID: ag.ID, Title: "Ckpt test", Harness: "claude", Model: "claude-sonnet-4-6", Effort: "medium",
	})
	if err != nil {
		t.Fatal(err)
	}
	repoURL := "https://github.com/acme/alpha.git"
	if _, err := q.AttachChatRepository(ctx, store.AttachChatRepositoryParams{ChatID: chat.ID, RepoUrl: repoURL, Directory: "."}); err != nil {
		t.Fatal(err)
	}
	run, err := q.CreateRun(ctx, store.CreateRunParams{
		WorkspaceID: ws, AgentID: ag.ID, Mode: "managed", State: "completed", Harness: "claude", Model: "claude-sonnet-4-6", Purpose: "chat", ResolvedSpec: []byte("{}"),
	})
	if err != nil {
		t.Fatal(err)
	}

	r := newTestRepo(t)
	r.git("checkout", "-qb", "feat/x")
	r.write("a.txt", "a\n")
	prSHA := r.commit("shipped commit")
	r.pushBranch("feat/x")

	r.write("wip.txt", "extra\n")
	wipSHA := r.commit("wip commit")
	wipBranch := "vesper-checkpoint/chat/abc/wip"
	r.pushBranch(wipBranch)

	goneBranch := "vesper-checkpoint/chat/abc/gone"
	containedBranch := "vesper-checkpoint/chat/abc/contained"
	r.git("checkout", "-q", prSHA)
	r.pushBranch(containedBranch)

	if err := q.SetRepositoryCheckpoint(ctx, store.SetRepositoryCheckpointParams{ChatID: chat.ID, RepoUrl: repoURL, CheckpointBranch: &wipBranch}); err != nil {
		t.Fatal(err)
	}
	for _, b := range []struct {
		branch string
		sha    string
	}{
		{goneBranch, prSHA},
		{containedBranch, prSHA},
		{wipBranch, wipSHA},
	} {
		sha := b.sha
		if err := q.RecordRunCheckpoint(ctx, store.RecordRunCheckpointParams{
			WorkspaceID: ws, RunID: &run.ID, ChatID: &chat.ID, RepoUrl: repoURL, Branch: b.branch, CommitSha: &sha,
		}); err != nil {
			t.Fatal(err)
		}
	}

	var compareCalls atomic.Int32
	var failCompare atomic.Bool
	inner := r.githubHandler(&compareCalls)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if failCompare.Load() && strings.Contains(req.URL.Path, "/compare/") {
			w.WriteHeader(500)
			_, _ = w.Write([]byte(`{"message":"boom"}`))
			return
		}
		inner.ServeHTTP(w, req)
	}))
	defer srv.Close()
	gh := &GitHub{BaseURL: srv.URL, Token: "t"}

	// First pass with transient failure on Compare for wipBranch (containedBranch matches exact SHA without Compare):
	failCompare.Store(true)
	deleted, err := CleanupChatCheckpointsAtPR(ctx, gh, q, chat.ID, repoURL, "https://github.com/acme/alpha/pull/1", "feat/x", prSHA, &run.ID, true)
	if err == nil {
		t.Fatal("expected transient error for wipBranch compare")
	}
	if !slices.Equal(deleted, []string{containedBranch}) {
		t.Fatalf("deleted = %v, want [%s]", deleted, containedBranch)
	}
	// Open checkpoints: only wipBranch should remain (goneBranch was marked deleted, containedBranch was deleted).
	open, err := q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if err != nil || len(open) != 1 || open[0].Branch != wipBranch {
		t.Fatalf("open = %+v, err = %v", open, err)
	}
	if open[0].LastCheckedPrSha != nil {
		t.Fatalf("transient error must not set LastCheckedPrSha, got %v", *open[0].LastCheckedPrSha)
	}

	// Second pass without transient failure: wipBranch is ahead, so kept and LastCheckedPrSha set to prSHA.
	failCompare.Store(false)
	deleted, err = CleanupChatCheckpointsAtPR(ctx, gh, q, chat.ID, repoURL, "https://github.com/acme/alpha/pull/1", "feat/x", prSHA, &run.ID, true)
	if err != nil || len(deleted) != 0 {
		t.Fatalf("deleted = %v, err = %v", deleted, err)
	}
	open, _ = q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 1 || open[0].LastCheckedPrSha == nil || *open[0].LastCheckedPrSha != prSHA {
		t.Fatalf("expected LastCheckedPrSha = %s, got %+v", prSHA, open)
	}

	// Third pass with same prSHA and skipChecked=true: 0 Compare calls!
	before := compareCalls.Load()
	if _, err := CleanupChatCheckpointsAtPR(ctx, gh, q, chat.ID, repoURL, "https://github.com/acme/alpha/pull/1", "feat/x", prSHA, &run.ID, true); err != nil {
		t.Fatal(err)
	}
	if compareCalls.Load() != before {
		t.Fatalf("skipChecked=true should skip already-checked PR SHA, made %d compare calls", compareCalls.Load()-before)
	}

	// Now PR advances to include wipSHA -> wipBranch IS deleted and chat_repositories.checkpoint_branch cleared!
	r.git("checkout", "-q", wipSHA)
	r.pushBranch("feat/x")
	deleted, err = CleanupChatCheckpointsAtPR(ctx, gh, q, chat.ID, repoURL, "https://github.com/acme/alpha/pull/1", "feat/x", wipSHA, &run.ID, true)
	if err != nil || !slices.Equal(deleted, []string{wipBranch}) {
		t.Fatalf("deleted = %v, err = %v", deleted, err)
	}
	if _, err := r.gitBare("rev-parse", "--verify", "-q", "refs/heads/"+wipBranch); err == nil {
		t.Fatal("wipBranch should have been deleted from bare repo")
	}
	open, _ = q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 0 {
		t.Fatalf("expected 0 open checkpoints, got %+v", open)
	}
	repos, _ := q.ChatRepositories(ctx, chat.ID)
	if len(repos) != 1 || repos[0].CheckpointBranch != nil {
		t.Fatalf("expected chat_repositories.checkpoint_branch cleared, got %+v", repos)
	}
	evs, err := q.ListRunEvents(ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
	if err != nil {
		t.Fatal(err)
	}
	foundEvent := false
	for _, ev := range evs {
		if ev.Type == "lifecycle" && strings.Contains(string(ev.Payload), `"checkpoint_deleted"`) && strings.Contains(string(ev.Payload), wipBranch) {
			foundEvent = true
		}
	}
	if !foundEvent {
		t.Fatalf("expected checkpoint_deleted run event, got %+v", evs)
	}
}

func TestCleanupCheckpointsDeleteErrorAndMultiHopRecovery(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	agents, _ := q.ListAgents(ctx, ws)
	ag := agents[0]
	chat, err := q.CreateChatSession(ctx, store.CreateChatSessionParams{
		WorkspaceID: ws, CreatedBy: me.ID, AgentID: ag.ID, Title: "Multi hop", Harness: "claude", Model: "claude-sonnet-4-6", Effort: "medium",
	})
	if err != nil {
		t.Fatal(err)
	}
	repoURL := "https://github.com/acme/alpha.git"
	if _, err := q.AttachChatRepository(ctx, store.AttachChatRepositoryParams{ChatID: chat.ID, RepoUrl: repoURL, Directory: "."}); err != nil {
		t.Fatal(err)
	}
	mkRun := func() store.Run {
		r, err := q.CreateRun(ctx, store.CreateRunParams{
			WorkspaceID: ws, AgentID: ag.ID, Mode: "managed", State: "completed", Harness: "claude", Model: "claude-sonnet-4-6", Purpose: "chat", ResolvedSpec: []byte("{}"),
		})
		if err != nil {
			t.Fatal(err)
		}
		return r
	}
	run1, run2, run3 := mkRun(), mkRun(), mkRun()

	r := newTestRepo(t)
	r.git("checkout", "-qb", "feat/hop")
	r.write("wip.txt", "step 1\n")
	ckpt1SHA := r.commit("ckpt1")
	ckpt1Branch := "vesper-checkpoint/chat/hop/1"
	r.pushBranch(ckpt1Branch)

	r.write("wip.txt", "step 2\n")
	ckpt2SHA := r.commit("ckpt2")
	ckpt2Branch := "vesper-checkpoint/chat/hop/2"
	r.pushBranch(ckpt2Branch)

	r.git("reset", "--soft", "HEAD~2")
	r.write("wip.txt", "final clean\n")
	prSHA := r.commit("clean PR")
	r.pushBranch("feat/hop")
	hopBranch := "feat/hop"
	if err := q.UpsertChatCodeReview(ctx, store.UpsertChatCodeReviewParams{
		ChatID: chat.ID, RepoUrl: repoURL, Branch: &hopBranch, HeadSha: &prSHA,
		Commits: []byte("[]"), Files: []byte("[]"), Dirty: false,
	}); err != nil {
		t.Fatal(err)
	}

	if err := q.RecordRunCheckpoint(ctx, store.RecordRunCheckpointParams{
		WorkspaceID: ws, RunID: &run1.ID, ChatID: &chat.ID, RepoUrl: repoURL, Branch: ckpt1Branch,
		CommitSha: &ckpt1SHA, SourceBranch: "feat/hop", HasUncommitted: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := q.MarkCheckpointRecovered(ctx, store.MarkCheckpointRecoveredParams{
		RepoUrl: repoURL, Branch: ckpt1Branch, RecoveredByRunID: run2.ID,
	}); err != nil {
		t.Fatal(err)
	}
	if err := q.RecordRunCheckpoint(ctx, store.RecordRunCheckpointParams{
		WorkspaceID: ws, RunID: &run2.ID, ChatID: &chat.ID, RepoUrl: repoURL, Branch: ckpt2Branch,
		CommitSha: &ckpt2SHA, SourceBranch: "feat/hop", HasUncommitted: true,
	}); err != nil {
		t.Fatal(err)
	}
	if err := q.MarkCheckpointRecovered(ctx, store.MarkCheckpointRecoveredParams{
		RepoUrl: repoURL, Branch: ckpt2Branch, RecoveredByRunID: run3.ID,
	}); err != nil {
		t.Fatal(err)
	}

	var failDelete atomic.Bool
	inner := r.githubHandler(nil)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if failDelete.Load() && req.Method == "DELETE" {
			w.WriteHeader(500)
			_, _ = w.Write([]byte(`{"message":"delete error"}`))
			return
		}
		inner.ServeHTTP(w, req)
	}))
	defer srv.Close()
	gh := &GitHub{BaseURL: srv.URL, Token: "t"}

	// Delete 500 keeps DB rows open.
	failDelete.Store(true)
	deleted, err := CleanupChatCheckpointsAtPR(ctx, gh, q, chat.ID, repoURL, "https://github.com/acme/alpha/pull/2", "feat/hop", prSHA, &run3.ID, false)
	if err == nil || len(deleted) != 0 {
		t.Fatalf("expected delete error and 0 deleted, got %v, %v", deleted, err)
	}
	open, _ := q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 2 {
		t.Fatalf("expected both checkpoints kept on DELETE 500, got %d", len(open))
	}

	// Retry succeeds: multi-hop recovery chain marks both ckpt1 and ckpt2 deleted.
	failDelete.Store(false)
	deleted, err = CleanupChatCheckpointsAtPR(ctx, gh, q, chat.ID, repoURL, "https://github.com/acme/alpha/pull/2", "feat/hop", prSHA, &run3.ID, false)
	if err != nil || len(deleted) != 2 {
		t.Fatalf("expected both deleted, got %v, err=%v", deleted, err)
	}
	open, _ = q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chat.ID, RepoUrl: repoURL})
	if len(open) != 0 {
		t.Fatalf("expected 0 open checkpoints, got %+v", open)
	}
}

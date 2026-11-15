package runner

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

type countingBackend struct {
	Backend
	starts atomic.Int64
}

func (c *countingBackend) Start(ctx context.Context, runID string, spec ExecSpec) (Process, error) {
	c.starts.Add(1)
	return c.Backend.Start(ctx, runID, spec)
}

func runGitTestCmd(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=Tester",
		"GIT_AUTHOR_EMAIL=tester@example.com",
		"GIT_COMMITTER_NAME=Tester",
		"GIT_COMMITTER_EMAIL=tester@example.com",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
	}
	return string(out)
}

func initCommittedRepo(t *testing.T, dir string, files map[string]string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	runGitTestCmd(t, dir, "init", "-b", "main")
	for rel, content := range files {
		full := filepath.Join(dir, rel)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	runGitTestCmd(t, dir, "add", "-A")
	runGitTestCmd(t, dir, "commit", "-m", "initial commit")
	head := runGitTestCmd(t, dir, "rev-parse", "--verify", "HEAD")
	return string(head[:len(head)-1])
}

func setupBatchReviewChat(t *testing.T, repos []struct{ url, dir string }) (*Runner, *countingBackend, runCtx, uuid.UUID) {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)

	var wsID, userID, agentID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO workspaces (name, slug) VALUES ('W', 'w') RETURNING id`).Scan(&wsID); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO users (workspace_id, name, email, initials, password_hash) VALUES ($1, 'U', 'u@example.com', 'U', 'x') RETURNING id`, wsID).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `INSERT INTO agents (workspace_id, name, handle) VALUES ($1, 'Coder', 'coder') RETURNING id`, wsID).Scan(&agentID); err != nil {
		t.Fatal(err)
	}
	run, err := q.CreateRun(ctx, store.CreateRunParams{
		WorkspaceID:  wsID,
		AgentID:      agentID,
		Mode:         "managed",
		State:        "running",
		ResolvedSpec: json.RawMessage(`{}`),
		Harness:      "codex",
		Model:        "m",
		Purpose:      "chat",
	})
	if err != nil {
		t.Fatal(err)
	}
	var chatID uuid.UUID
	if err := pool.QueryRow(ctx, `INSERT INTO chat_sessions (workspace_id, title, created_by, agent_id, harness, model, current_run_id) VALUES ($1, 'Batch Test', $2, $3, 'codex', 'm', $4) RETURNING id`,
		wsID, userID, agentID, run.ID).Scan(&chatID); err != nil {
		t.Fatal(err)
	}
	for _, repo := range repos {
		if _, err := pool.Exec(ctx, `INSERT INTO chat_repositories (chat_id, repo_url, directory) VALUES ($1, $2, $3)`,
			chatID, repo.url, repo.dir); err != nil {
			t.Fatal(err)
		}
	}

	cb := &countingBackend{Backend: &Fake{Dir: t.TempDir()}}
	if err := cb.EnsureWorkspace(ctx, run.ID.String()); err != nil {
		t.Fatal(err)
	}
	r := &Runner{
		Pool:    pool,
		Backend: cb,
		Log:     slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
	return r, cb, runCtx{run: run}, chatID
}

func TestCodeReviewBatchOperations(t *testing.T) {
	ctx := context.Background()

	t.Run("reviewSignature batches multi-repo inspection into one call", func(t *testing.T) {
		r, cb, rc, _ := setupBatchReviewChat(t, []struct{ url, dir string }{
			{url: "owner/repo-a", dir: "repo-a"},
			{url: "owner/repo-b", dir: "repo-b"},
		})
		wsDir := cb.WorkspaceDir(rc.run.ID.String())
		initCommittedRepo(t, filepath.Join(wsDir, "repo-a"), map[string]string{"a.txt": "alpha\n"})
		initCommittedRepo(t, filepath.Join(wsDir, "repo-b"), map[string]string{"b.txt": "beta\n"})

		cb.starts.Store(0)
		sig1 := r.reviewSignature(ctx, rc)
		if got := cb.starts.Load(); got != 1 {
			t.Fatalf("reviewSignature across 2 repos invoked Backend.Start %d times, want 1", got)
		}
		if sig1 == "" {
			t.Fatal("reviewSignature returned empty signature")
		}

		// Modifying a tracked file in the second repo changes the signature in 1 call.
		if err := os.WriteFile(filepath.Join(wsDir, "repo-b", "b.txt"), []byte("beta updated\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		cb.starts.Store(0)
		sig2 := r.reviewSignature(ctx, rc)
		if got := cb.starts.Load(); got != 1 {
			t.Fatalf("second reviewSignature invoked Backend.Start %d times, want 1", got)
		}
		if sig2 == sig1 {
			t.Fatalf("reviewSignature did not change after file edit: %q", sig2)
		}
	})

	t.Run("codeChanges batches 5 untracked files and 1 modified file into one call", func(t *testing.T) {
		r, cb, rc, _ := setupBatchReviewChat(t, []struct{ url, dir string }{
			{url: "owner/single", dir: "."},
		})
		wsDir := cb.WorkspaceDir(rc.run.ID.String())
		head := initCommittedRepo(t, wsDir, map[string]string{"tracked.go": "package main\n"})

		if err := os.WriteFile(filepath.Join(wsDir, "tracked.go"), []byte("package main\n// edited\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		for _, name := range []string{"u1.txt", "u2.txt", "u3.txt", "u4.txt", "u5.txt"} {
			if err := os.WriteFile(filepath.Join(wsDir, name), []byte("hello "+name+"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}

		cb.starts.Store(0)
		changes, err := r.codeChanges(ctx, rc.run.ID.String(), head, nil)
		if err != nil {
			t.Fatalf("codeChanges: %v", err)
		}
		if got := cb.starts.Load(); got != 1 {
			t.Fatalf("codeChanges with 5 untracked files invoked Backend.Start %d times, want 1", got)
		}
		if len(changes) != 6 {
			t.Fatalf("got %d CodeChange entries, want 6: %+v", len(changes), changes)
		}
		byPath := map[string]CodeChange{}
		for _, ch := range changes {
			byPath[ch.Path] = ch
		}
		if byPath["tracked.go"].Status != "modified" || byPath["tracked.go"].Patch == nil {
			t.Fatalf("expected modified tracked.go with patch, got %+v", byPath["tracked.go"])
		}
		for _, name := range []string{"u1.txt", "u2.txt", "u3.txt", "u4.txt", "u5.txt"} {
			ch, ok := byPath[name]
			if !ok || ch.Status != "added" || ch.Patch == nil {
				t.Fatalf("expected added untracked %s with patch, got %+v", name, ch)
			}
		}
	})

	t.Run("saveCodeReviews caches HEAD tree across live and settled ticks without dropping JSONB tree", func(t *testing.T) {
		r, cb, rc, chatID := setupBatchReviewChat(t, []struct{ url, dir string }{
			{url: "owner/cached", dir: "."},
		})
		wsDir := cb.WorkspaceDir(rc.run.ID.String())
		initCommittedRepo(t, wsDir, map[string]string{
			"main.go":   "package main\nfunc main() {}\n",
			"README.md": "# Hello\n",
		})

		cache := newCodeReviewCache()

		// Tick 1 (live, HEAD uncached): 1 Backend.Start, saves full tree JSONB.
		cb.starts.Store(0)
		r.saveCodeReviews(ctx, rc, nil, true, cache)
		if got := cb.starts.Load(); got != 1 {
			t.Fatalf("tick 1 saveCodeReviews invoked Backend.Start %d times, want 1", got)
		}
		repoCache := cache.repo("owner/cached")
		if repoCache == nil || !repoCache.hasSavedTree {
			t.Fatalf("expected populated repo cache after tick 1, got %+v", repoCache)
		}

		// Modify tracked README.md without changing HEAD, then run tick 2 (live=true)
		// and final settled save (live=false). Both must run 1 Backend.Start each,
		// reuse cached HEAD blobs, and keep the full tree intact when Tree:nil skips
		// rewriting identical tree JSONB.
		if err := os.WriteFile(filepath.Join(wsDir, "README.md"), []byte("# Updated\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		cb.starts.Store(0)
		r.saveCodeReviews(ctx, rc, nil, true, cache)
		if got := cb.starts.Load(); got != 1 {
			t.Fatalf("tick 2 saveCodeReviews invoked Backend.Start %d times, want 1", got)
		}
		cb.starts.Store(0)
		r.saveCodeReviews(ctx, rc, nil, false, cache)
		if got := cb.starts.Load(); got != 1 {
			t.Fatalf("settled saveCodeReviews invoked Backend.Start %d times, want 1", got)
		}

		rows, err := store.New(r.Pool).ChatCodeReviews(ctx, chatID)
		if err != nil {
			t.Fatalf("ChatCodeReviews: %v", err)
		}
		if len(rows) != 1 {
			t.Fatalf("got %d code review rows, want 1", len(rows))
		}
		row := rows[0]
		if !row.Dirty {
			t.Fatal("expected Dirty=true after tracked edit")
		}
		if row.Live {
			t.Fatal("expected Live=false after settled save")
		}
		var tree []CodeReviewFile
		if err := json.Unmarshal(row.Tree, &tree); err != nil {
			t.Fatalf("unmarshal saved tree: %v", err)
		}
		if len(tree) != 2 {
			t.Fatalf("saved tree lost entries when Tree=nil skipped update: got %d entries (%s)", len(tree), row.Tree)
		}
		treeByPath := map[string]CodeReviewFile{}
		for _, f := range tree {
			treeByPath[f.Path] = f
		}
		if treeByPath["main.go"].Content == nil || *treeByPath["main.go"].Content != "package main\nfunc main() {}\n" {
			t.Fatalf("main.go content not preserved in cached tree: %+v", treeByPath["main.go"])
		}
		if treeByPath["README.md"].Content == nil || *treeByPath["README.md"].Content != "# Hello\n" {
			t.Fatalf("README.md HEAD content not preserved in cached tree: %+v", treeByPath["README.md"])
		}
		var files []CodeChange
		if err := json.Unmarshal(row.Files, &files); err != nil {
			t.Fatalf("unmarshal saved files: %v", err)
		}
		if len(files) != 1 || files[0].Path != "README.md" || files[0].Status != "modified" {
			t.Fatalf("unexpected changed files after settled save: %+v", files)
		}
	})
}

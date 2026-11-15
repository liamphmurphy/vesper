import test from "node:test";
import assert from "node:assert/strict";
import { ancestorDirs, baseName, branchFileTree, commentKey, fileTree, formatBytes, placePushRequests, pushStateLabel, repoName, resolveSelectedFile, reviewMessage, treeCounts } from "./code-review.ts";

test("reviewMessage anchors each comment to file:line, quotes the line and sorts like a review", () => {
  const msg = reviewMessage(
    [
      { path: "web/next.ts", line: 3, side: "new", code: "return next;", body: "Handle a missing value." },
      { path: "server/auth/callback.go", line: 42, side: "new", code: "  next := safeNext(state)", body: "Reject //evil.com.\nAdd a test." },
      { path: "server/auth/callback.go", line: 7, side: "old", code: "http.Redirect(w, r, \"/\")", body: "Why drop this?" },
      { path: "x.go", line: 1, side: "new", code: "", body: "   " },
    ],
    "fix/login-redirect",
  );
  assert.equal(
    msg,
    "Review of `fix/login-redirect` (3 comments). Please address each:\n\n" +
      "- `server/auth/callback.go:7` (removed line)\n  > http.Redirect(w, r, \"/\")\n  Why drop this?\n" +
      "- `server/auth/callback.go:42`\n  > next := safeNext(state)\n  Reject //evil.com.\n  Add a test.\n" +
      "- `web/next.ts:3`\n  > return next;\n  Handle a missing value.",
  );
  assert.equal(reviewMessage([{ path: "a", line: 1, side: "new", code: "", body: "" }]), "", "nothing to send");
  assert.match(reviewMessage([{ path: "a", line: 1, side: "new", code: "", body: "ok" }]), /^Review of your changes \(1 comment\)/);
});

test("commentKey keeps the two sides of a line apart", () => {
  assert.notEqual(commentKey({ path: "a", line: 1, side: "new" }), commentKey({ path: "a", line: 1, side: "old" }));
});

test("fileTree groups by directory, root first, sorted", () => {
  const f = (path) => ({ path, status: "modified", additions: 0, deletions: 0, binary: false, truncated: false });
  const tree = fileTree([f("web/b.ts"), f("README.md"), f("server/z.go"), f("web/a.ts")]);
  assert.deepEqual(tree.map((d) => [d.dir, d.files.map((x) => baseName(x.path))]), [["", ["README.md"]], ["server", ["z.go"]], ["web", ["a.ts", "b.ts"]]]);
});

test("repoName shortens GitHub URLs", () => {
  assert.equal(repoName("https://github.com/liamphmurphy/Vesper.git"), "liamphmurphy/Vesper");
  assert.equal(repoName("git@github.com:a/b.git"), "a/b");
  assert.equal(repoName("/tmp/origin"), "/tmp/origin");
});

test("pushStateLabel says what a card is waiting on", () => {
  assert.equal(pushStateLabel({ state: "staging", auto: false }, "Hackerman"), "Staged when Hackerman's turn ends");
  assert.equal(pushStateLabel({ state: "pushed", auto: true, pr_number: 412 }, "H"), "Pushed automatically · PR #412");
  assert.equal(pushStateLabel({ state: "failed", auto: false }, "H"), "Not pushed");
});

test("branchFileTree merges unchanged tree files with added, modified, renamed, and deleted changes", () => {
  const tree = [
    { path: "README.md", size: 120, binary: false, content: "# Project\n", truncated: false },
    { path: "src/config.ts", size: 80, binary: false, content: "export const cfg = {};\n", truncated: false },
    { path: "src/app.ts", size: 200, binary: false, content: "old", truncated: false },
    { path: "src/sub/util.ts", size: 42, binary: false, content: "export const u = 1;\n", truncated: false },
    { path: "docs/new-name.md", size: 64, binary: false, content: "renamed body\n", truncated: false },
  ];
  const changes = [
    { path: "src/app.ts", status: "modified", additions: 2, deletions: 1, binary: false, truncated: false, patch: "@@ -1 +1 @@\n-old\n+new\n" },
    { path: "docs/new-name.md", old_path: "docs/old-name.md", status: "renamed", additions: 0, deletions: 0, binary: false, truncated: false },
    { path: "legacy/drop.ts", status: "deleted", additions: 0, deletions: 10, binary: false, truncated: false, patch: "@@ -1 +0,0 @@\n-bye\n" },
    { path: "cmd/main.go", status: "added", additions: 3, deletions: 0, binary: false, truncated: false, patch: "@@ -0,0 +1,3 @@\n+package main\n" },
  ];
  const nodes = branchFileTree(tree, changes);
  assert.deepEqual(nodes.map((n) => `${n.kind}:${n.name}`), ["dir:cmd", "dir:docs", "dir:legacy", "dir:src", "file:README.md"]);

  const src = nodes.find((n) => n.kind === "dir" && n.name === "src");
  assert.equal(src.fileCount, 3);
  assert.equal(src.changedCount, 1);
  assert.deepEqual(src.children.map((n) => `${n.kind}:${n.name}`), ["dir:sub", "file:app.ts", "file:config.ts"]);

  const legacy = nodes.find((n) => n.kind === "dir" && n.name === "legacy");
  assert.equal(legacy.fileCount, 0);
  assert.equal(legacy.changedCount, 1);
  assert.equal(legacy.children[0].status, "deleted");
  assert.equal(legacy.children[0].exists, false);

  const docs = nodes.find((n) => n.kind === "dir" && n.name === "docs");
  assert.equal(docs.children[0].status, "renamed");
  assert.equal(docs.children[0].oldPath, "docs/old-name.md");

  assert.deepEqual(ancestorDirs("src/sub/util.ts"), ["src", "src/sub"]);
  assert.deepEqual(treeCounts(tree, changes), { totalFiles: 6, changedFiles: 4, unchangedFiles: 3, deletedFiles: 1, hasCompleteTree: true });

  // Preserves selected unchanged file when includeUnchanged is true, and falls back without mutating stored selection when false.
  assert.equal(resolveSelectedFile("src/config.ts", tree, changes, true).treeFile?.path, "src/config.ts");
  assert.equal(resolveSelectedFile("src/config.ts", tree, changes, false).path, "src/app.ts");
  assert.equal(formatBytes(512), "512 B");
  assert.equal(formatBytes(2048), "2.0 KB");
});

test("placePushRequests anchors linked, live, and legacy PR cards to their turns", () => {
  const msgs = [
    { id: "m1", role: "user", created_at: "2026-11-15T10:00:00Z" },
    { id: "m2", role: "assistant", created_at: "2026-11-15T10:00:05Z", run_id: "r1", turn_seq: 1 },
    { id: "m3", role: "assistant", created_at: "2026-11-15T10:01:00Z", run_id: "r1", turn_seq: 1 },
    { id: "m4", role: "user", created_at: "2026-11-15T10:02:00Z" },
    { id: "m5", role: "assistant", created_at: "2026-11-15T10:03:00Z", run_id: "r1", turn_seq: 2 },
    { id: "m6", role: "user", created_at: "2026-11-15T10:04:00Z" },
    { id: "m7", role: "user", created_at: "2026-11-15T10:05:00Z" },
  ];

  const req = (over) => ({
    id: "p0",
    state: "pending",
    created_at: "2026-11-15T10:00:30Z",
    run_id: "r1",
    ...over,
  });

  const placed = placePushRequests(
    [
      // Linked directly to turn 1 reply and turn 2 reply.
      req({ id: "linked-t1", state: "pushed", message_id: "m3", created_at: "2026-11-15T10:00:40Z" }),
      req({ id: "linked-t2", state: "pending", message_id: "m5", created_at: "2026-11-15T10:02:30Z" }),
      // Cleanly declined card stays hidden; declined with error stays on its reply.
      req({ id: "declined-clean", state: "declined", message_id: "m3" }),
      req({ id: "declined-err", state: "declined", error: "Replaced by newer request", message_id: "m5" }),
      // Legacy unlinked request created between m2 (opening line) and m3 (turn 1 final reply) stays on m3, not m5.
      req({ id: "legacy-t1", state: "pushed", created_at: "2026-11-15T10:00:20Z" }),
      // Legacy unlinked request between consecutive user messages m6 and m7 anchors right after m6.
      req({ id: "legacy-between-users", state: "failed", created_at: "2026-11-15T10:04:30Z" }),
      // Legacy unlinked request before the very first message goes to leading.
      req({ id: "legacy-first", state: "pushed", created_at: "2026-11-15T09:59:00Z" }),
      // Unlinked staging request created after m7 during active run r1 goes to live.
      req({ id: "live-staging", state: "staging", created_at: "2026-11-15T10:05:10Z" }),
      // Request linked to an older message outside the paginated window is omitted when hasMore=true.
      req({ id: "older-window", state: "pushed", message_id: "m0", created_at: "2026-11-15T09:00:00Z" }),
    ],
    msgs,
    { running: true, currentRunId: "r1", hasMore: true },
  );

  assert.deepEqual(placed.byMessage.get("m3")?.map((r) => r.id), ["linked-t1", "legacy-t1"]);
  assert.deepEqual(placed.byMessage.get("m5")?.map((r) => r.id), ["linked-t2", "declined-err"]);
  assert.deepEqual(placed.afterMessage.get("m6")?.map((r) => r.id), ["legacy-between-users"]);
  assert.deepEqual(placed.leading.map((r) => r.id), ["legacy-first"]);
  assert.deepEqual(placed.live.map((r) => r.id), ["live-staging"]);
  assert.deepEqual(placed.trailing.map((r) => r.id), []);

  // When not running, an unlinked post-last-message request falls back to trailing instead of vanishing.
  const idle = placePushRequests(
    [req({ id: "unlinked-end", state: "pending", created_at: "2026-11-15T10:05:10Z" })],
    msgs,
    { running: false, currentRunId: "r1" },
  );
  assert.deepEqual(idle.trailing.map((r) => r.id), ["unlinked-end"]);
  assert.deepEqual(idle.live, []);
});

import { expect, test } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// Code a coding persona wrote: the Changes block under a reply and highlighted fences in the markdown.

test("changes block is collapsed, expands to file diffs; long fences collapse", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill("code: add the thing");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");

  const block = page.getByTestId("code-changes");
  const toggle = block.getByRole("button", { name: /Changed 3 files/ });
  await expect(toggle).toHaveAttribute("aria-expanded", "false");
  await expect(toggle).toContainText("+5");
  await expect(toggle).toContainText("−1");
  await expect(page.getByTestId("code-change-file")).toHaveCount(0);

  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  const files = page.getByTestId("code-change-file");
  await expect(files).toHaveCount(3);
  await expect(files.nth(0)).toContainText("src/app.ts");
  await expect(files.nth(0)).toContainText("+2");
  await expect(files.nth(1)).toContainText("cmd/main.go");
  // Three files or fewer start open.
  await expect(files.nth(0).locator('[data-diff-row="add"]')).toHaveCount(3);
  await expect(files.nth(0).locator('[data-diff-row="hunk"]')).toHaveCount(2);
  await expect(files.nth(2)).toContainText("Binary file changed");

  // A file collapses on its own.
  await files.nth(1).getByRole("button", { name: /^Added cmd\/main\.go/ }).click();
  await expect(files.nth(1).locator('[data-diff-row="add"]')).toHaveCount(0);

  // The fence over 20 lines is collapsed behind a show-more button.
  const fence = page.getByTestId("code-fence");
  await expect(fence).toContainText("ts");
  // The block's <code> is not an inline chip: no border, background or padding
  // (those drew as empty pills around the first and last lines).
  const code = fence.locator("pre > code");
  await expect(code).toHaveCSS("border-top-width", "0px");
  await expect(code).toHaveCSS("padding-left", "0px");
  await expect(code).toHaveCSS("background-color", "rgba(0, 0, 0, 0)");
  await expect(code).toHaveCSS("display", "block");
  await fence.screenshot({ path: "test-results/code-fence.png" });
  await expect(fence.getByRole("button", { name: "Show 7 more lines" })).toBeVisible();
  await expect(fence).not.toContainText("const v24");
  await fence.getByRole("button", { name: /more lines/ }).click();
  await expect(fence).toContainText("const v24");
});

test("fullscreen code review preserves state across transitions, navigates branch tree and fallbacks, and handles Escape focus", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill("code: update auth");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");

  const block = page.getByTestId("code-changes");
  await block.getByRole("button", { name: /Changed 3 files/ }).click();
  await block.getByTestId("review-branch").click();

  const panel = page.getByTestId("code-panel");
  await expect(panel).toBeVisible();
  await expect(panel).toHaveAttribute("data-fullscreen", "false");
  await expect(panel.getByTestId("code-branch")).toContainText("feat/code-review");
  await expect(panel.getByTestId("code-revision")).toHaveText("abcdef1");
  await expect(panel.getByTestId("code-settled")).toHaveText("settled");

  // Select a file and add a draft review comment before entering fullscreen.
  await panel.getByTestId("code-tree-file").filter({ hasText: "main.go" }).click();
  await panel.getByRole("button", { name: "Comment on line 1" }).click();
  await panel.getByRole("textbox", { name: "Comment on cmd/main.go:1" }).fill("Add package doc");
  await panel.getByRole("button", { name: "Add to review" }).click();
  await expect(panel.getByTestId("code-review-bar")).toContainText("1 comment for the persona");

  // Switch mode tab to "Last reply", enter fullscreen, and verify state is preserved.
  await panel.getByRole("tab", { name: "Last reply" }).click();
  await expect(panel.getByRole("tab", { name: "Last reply" })).toHaveAttribute("aria-selected", "true");
  await panel.getByTestId("code-fullscreen-open").click();

  await expect(page).toHaveURL(/code=full/);
  await expect(panel).toHaveAttribute("data-fullscreen", "true");
  await expect(panel.getByRole("tab", { name: "Last reply" })).toHaveAttribute("aria-selected", "true");
  await expect(panel.getByTestId("code-detail-header")).toContainText("cmd/main.go");
  await expect(panel.getByTestId("code-review-bar")).toContainText("1 comment for the persona");

  // Escape inside an open comment textarea cancels only the editor, not fullscreen.
  await panel.getByRole("button", { name: "Comment on line 3" }).click();
  const editorBox = panel.getByRole("textbox", { name: "Comment on cmd/main.go:3" });
  await expect(editorBox).toBeFocused();
  await editorBox.press("Escape");
  await expect(editorBox).toHaveCount(0);
  await expect(panel).toHaveAttribute("data-fullscreen", "true");

  // Escape outside text inputs dismisses fullscreen and restores focus to the Full screen trigger.
  await panel.getByTestId("code-fullscreen-exit").focus();
  await page.keyboard.press("Escape");
  await expect(page).toHaveURL(/code=open/);
  await expect(panel).toHaveAttribute("data-fullscreen", "false");
  await expect(panel.getByTestId("code-fullscreen-open")).toBeFocused();
  await expect(panel.getByRole("tab", { name: "Last reply" })).toHaveAttribute("aria-selected", "true");

  // Re-enter fullscreen, switch to Branch, and explore the complete branch tree.
  await panel.getByTestId("code-fullscreen-open").click();
  await panel.getByRole("tab", { name: "Branch" }).click();
  const branchTree = panel.getByTestId("code-branch-tree");
  await expect(branchTree).toBeVisible();

  // Directory expand/collapse.
  const srcDir = branchTree.locator('[data-testid="code-tree-dir"][data-dir-path="src"]');
  await expect(srcDir).toHaveAttribute("aria-expanded", "true");
  await srcDir.click();
  await expect(srcDir).toHaveAttribute("aria-expanded", "false");
  await expect(branchTree.locator('[data-file-path="src/config.ts"]')).toHaveCount(0);
  await srcDir.click();
  await expect(srcDir).toHaveAttribute("aria-expanded", "true");

  // Unchanged tracked file viewer.
  await branchTree.locator('[data-file-path="src/config.ts"]').click();
  await expect(panel.getByTestId("code-detail-header")).toContainText("Unchanged");
  await expect(panel.getByTestId("code-file-content")).toContainText("API_URL");

  // Bounded fallback states: binary, too large, and truncated text.
  await branchTree.locator('[data-file-path="assets/unchanged.bin"]').click();
  await expect(panel.getByTestId("code-file-fallback")).toContainText("Binary file not shown.");

  await branchTree.locator('[data-file-path="data/huge.sql"]').click();
  await expect(panel.getByTestId("code-file-fallback")).toContainText("File not shown (too large).");

  await branchTree.locator('[data-file-path="docs/notes.txt"]').click();
  await expect(panel.getByTestId("code-file-content")).toContainText("First part of truncated notes");
  await expect(panel.getByTestId("code-file-truncated")).toContainText("File content truncated");

  // Renamed and deleted files.
  const renamedEntry = branchTree.locator('[data-file-path="docs/new-guide.md"]');
  await expect(renamedEntry).toHaveAttribute("data-file-status", "renamed");
  await renamedEntry.click();
  await expect(panel.getByTestId("code-detail-header")).toContainText("docs/old-guide.md → docs/new-guide.md");

  await branchTree.locator('[data-file-path="legacy/drop.ts"]').click();
  await expect(panel.getByTestId("code-detail-header")).toContainText("Deleted");

  // Filter toggle (Changed vs All files).
  await panel.getByTestId("code-tree-filter-changed").click();
  await expect(panel.locator('[data-testid="code-tree-file"][data-file-path="src/config.ts"]')).toHaveCount(0);
  await panel.getByTestId("code-tree-filter-all").click();
  await expect(branchTree.locator('[data-file-path="src/config.ts"]')).toBeVisible();

  // Exit via Back to chat and submit the retained review comment.
  await panel.getByTestId("code-fullscreen-exit").click();
  await expect(panel).toHaveAttribute("data-fullscreen", "false");
  await panel.getByRole("button", { name: "Send review" }).click();
  await expect(page.getByText(/^Review of feat\/code-review \(1 comment\)/)).toBeVisible();
  await expect(panel.getByTestId("code-review-bar")).toHaveCount(0);
});

test("multi-repository switching isolates branch trees, file contents, revisions, and draft comments", async ({ page }) => {
  const mock = await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill("code: multi repo");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
  await expect(page.getByTestId("code-changes")).toBeVisible();

  const chatId = mock.chats[0].id;
  mock.codeReviews.set(chatId, [
    {
      repository: "https://github.com/acme/alpha.git",
      branch: "feat/alpha",
      base_sha: "1111111111111111111111111111111111111111",
      head_sha: "aaaaaaa111111111111111111111111111111111",
      commits: [{ sha: "aaaaaaa111111111111111111111111111111111", subject: "Alpha work" }],
      files: [{ path: "alpha.go", status: "modified", additions: 1, deletions: 0, binary: false, truncated: false, patch: "@@ -1 +1,2 @@\n package alpha\n+const A = 1\n" }],
      dirty: true,
      live: false,
      tree: [
        { path: "alpha-only.txt", size: 13, binary: false, content: "alpha-content", truncated: false },
        { path: "alpha.go", size: 25, binary: false, content: "package alpha\n", truncated: false },
      ],
      tree_truncated: false,
      updated_at: "2026-11-14T12:00:00Z",
    },
    {
      repository: "https://github.com/acme/beta.git",
      branch: "feat/beta",
      base_sha: "2222222222222222222222222222222222222222",
      head_sha: "bbbbbbb222222222222222222222222222222222",
      commits: [{ sha: "bbbbbbb222222222222222222222222222222222", subject: "Beta work" }],
      files: [{ path: "beta.ts", status: "added", additions: 1, deletions: 0, binary: false, truncated: false, patch: "@@ -0,0 +1 @@\n+export const B = 2;\n" }],
      dirty: false,
      live: true,
      tree: [
        { path: "beta-only.txt", size: 12, binary: false, content: "beta-content", truncated: false },
        { path: "beta.ts", size: 20, binary: false, content: "export const B = 2;\n", truncated: false },
      ],
      tree_truncated: false,
      updated_at: "2026-11-14T12:00:00Z",
    },
  ]);

  await page.goto(`/chat/${chatId}?code=full&panel=code`);
  const panel = page.getByTestId("code-panel");
  await expect(panel).toHaveAttribute("data-fullscreen", "true");
  await expect(panel.getByTestId("code-revision")).toHaveText("aaaaaaa");
  await expect(panel.getByTestId("code-settled")).toHaveText("uncommitted");
  await expect(panel.locator('[data-file-path="alpha-only.txt"]')).toBeVisible();
  await expect(panel.locator('[data-file-path="beta-only.txt"]')).toHaveCount(0);

  // Add a draft comment on Alpha.
  await panel.getByRole("button", { name: "Comment on line 2" }).click();
  await panel.getByRole("textbox", { name: "Comment on alpha.go:2" }).fill("Alpha note");
  await panel.getByRole("button", { name: "Add to review" }).click();
  await expect(panel.getByTestId("code-review-bar")).toContainText("1 comment for the persona");

  // Switch to Beta: Beta has its own tree, live status, revision, and no Alpha draft comments.
  await panel.getByTestId("code-repo-select").selectOption("https://github.com/acme/beta.git");
  await expect(panel.getByTestId("code-revision")).toHaveText("bbbbbbb");
  await expect(panel.getByTestId("code-live")).toBeVisible();
  await expect(panel.locator('[data-file-path="beta-only.txt"]')).toBeVisible();
  await expect(panel.locator('[data-file-path="alpha-only.txt"]')).toHaveCount(0);
  await expect(panel.getByTestId("code-review-bar")).toHaveCount(0);
  await panel.locator('[data-file-path="beta-only.txt"]').click();
  await expect(panel.getByTestId("code-file-content")).toContainText("beta-content");

  // Switch back to Alpha: Alpha selection and draft comment are restored cleanly.
  await panel.getByTestId("code-repo-select").selectOption("https://github.com/acme/alpha.git");
  await expect(panel.getByTestId("code-revision")).toHaveText("aaaaaaa");
  await expect(panel.getByTestId("code-review-bar")).toContainText("1 comment for the persona");
  await expect(panel.getByTestId("line-comment")).toContainText("Alpha note");
});

test("Code dock tab is persistently available on repository chats before any edits", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/chat?project=WEB");
  const { repoChatId, plainChatId } = await page.evaluate(async () => {
    const post = async (body: Record<string, unknown>) => {
      const r = await fetch("/api/v1/chats", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(body),
      });
      return (await r.json()) as { id: string };
    };
    const coder = (await (
      await fetch("/api/v1/personas", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ name: "Coder", capabilities: { code: true, images: false }, repos: ["https://github.com/acme/alpha.git"] }),
      })
    ).json()) as { id: string };
    const repo = await post({ project: "WEB", persona_id: coder.id, repo_url: "https://github.com/acme/alpha.git" });
    const plain = await post({ project: "WEB" });
    return { repoChatId: repo.id, plainChatId: plain.id };
  });

  await page.goto(`/chat/${repoChatId}`);
  const codeRailBtn = page.getByRole("button", { name: "Open Code" });
  await expect(codeRailBtn).toBeVisible();
  await codeRailBtn.click();
  await expect(page.getByTestId("code-panel-empty")).toBeVisible();

  await page.goto(`/chat/${plainChatId}`);
  await expect(page.getByRole("button", { name: "Open Activity" })).toBeVisible();
  await expect(page.getByRole("button", { name: "Open Code" })).toHaveCount(0);
});

test("live branch creation glows the Code rail icon without auto-opening the Code dock", async ({ page }) => {
  const api = await installChatApi(page, { replyDelayMs: 1200 });
  await page.goto("/chat?project=WEB");
  await page.getByRole("combobox", { name: "Message" }).fill("slow: create a branch");
  await page.getByRole("combobox", { name: "Message" }).press("Enter");

  const chat = api.chats[0];
  api.codeReviews.set(chat.id, [
    {
      repository: "https://github.com/acme/alpha.git",
      branch: "feat/new-branch",
      base_sha: "1111111111111111111111111111111111111111",
      head_sha: "2222222222222222222222222222222222222222",
      commits: [],
      files: [],
      dirty: false,
      live: true,
      tree: [],
      tree_truncated: false,
      updated_at: new Date().toISOString(),
    },
  ]);
  await page.evaluate((cid) => {
    const data = JSON.stringify({ type: "code_review.updated", chat_id: cid });
    for (const s of (window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> }).__sse) {
      s.onmessage?.({ data });
    }
  }, chat.id);

  const codeBtn = page.getByRole("button", { name: /Open Code, working/ });
  await expect(codeBtn).toBeVisible();
  await expect(codeBtn.locator("[data-busy]")).toBeVisible();
  await expect(page.getByTestId("code-panel")).not.toBeVisible();
});

import { expect, test, type Page } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// The Docs app: documents (text canvases) you type on full page, beside their
// chat, with the persona's edits coming back as suggestions to review.

const DOC = "44444444-4444-4444-8444-444444444444";
const OTHER = "55555555-5555-4555-8555-555555555555";
const MOCKUP = "66666666-6666-4666-8666-666666666666";
const at = "2026-11-10T12:00:00Z";

type Version = { seq: number; author_type: "user" | "agent"; note: string; body: string };

async function install(page: Page, first = "# Trip plan\n\nFly to **Lisbon** on Friday.\n") {
  const mock = await installChatApi(page, { replyDelayMs: 10 });
  // A real chat in the mock, so the doc's conversation can load and send.
  // (/apps/docs itself now opens Knowledge; a canvas that never became a Doc
  // still opens in the Doc editor, which these tests cover.)
  await page.goto("/apps/docs");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const chatId = chat.id as string;
  const s = {
    versions: [{ seq: 1, author_type: "user", note: "", body: first }] as Version[],
    reviewed: 0,
    docsPosted: [] as unknown[],
    saves: [] as { base_seq: number; body: string; note?: string }[],
    reviewedPosts: [] as number[],
    library: 0,
    wiki: [] as { replace?: boolean }[],
    comments: [] as Record<string, unknown>[],
    sent: [] as Record<string, unknown>[],
  };
  const head = () => s.versions[s.versions.length - 1];
  const mine = (id: string, kind: string, title: string, chatTitle: string) => ({ id, kind, title, chat_id: chatId, chat_title: chatTitle, updated_at: at, reviewed_seq: s.reviewed });
  await page.route(/\/api\/v1\/(canvases|docs)(\/|$)/, (route) => {
    const req = route.request();
    const p = new URL(req.url()).pathname;
    const json = (data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
    if (p.endsWith("/reviewed")) {
      const seq = req.postDataJSON().seq as number;
      s.reviewedPosts.push(seq);
      s.reviewed = Math.max(s.reviewed, seq);
      return json({ reviewed_seq: s.reviewed });
    }
    if (p.endsWith("/wiki")) {
      const body = req.postDataJSON() as { replace?: boolean };
      s.wiki.push(body);
      // The first publish finds the page taken; replacing it works.
      if (!body.replace) return json({ code: "conflict", message: 'a wiki page called "Trip plan" already exists: choose another path, or replace it' }, 409);
      return json({ path: "Trip plan", created: false }, 201);
    }
    if (p.endsWith("/library")) {
      s.library++;
      return json({ id: "77777777-7777-4777-8777-777777777777", kind: "document", title: "Trip plan", filename: "Trip plan.md", content_type: "text/markdown", size_bytes: 10, created_at: at }, 201);
    }
    if (p.endsWith("/docs")) {
      s.docsPosted.push(req.postDataJSON());
      return json(mine(DOC, "text", "Trip plan", "Trip plan"), 201);
    }
    if (p.endsWith(`/canvases/${DOC}`)) return json(mine(DOC, "text", "Trip plan", "Trip plan"));
    return json({ canvases: [mine(DOC, "text", "Trip plan", "Trip plan"), mine(MOCKUP, "svg", "Login screen", "Design chat"), mine(OTHER, "text", "Retention policy", "Policy chat")] });
  });
  await page.route(/\/api\/v1\/chats\/[^/]+\/canvases\//, (route) => {
    const req = route.request();
    const u = new URL(req.url());
    const p = u.pathname;
    const json = (data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
    if (p.endsWith("/comments/send")) {
      s.sent.push(req.postDataJSON());
      return route.fulfill({ status: 204 });
    }
    if (p.endsWith("/comments")) {
      if (req.method() === "POST") {
        const c = { id: `c${s.comments.length + 1}`, author_type: "user", anchor: {}, target_lost: false, status: "draft", created_at: at, ...req.postDataJSON() };
        s.comments.push(c);
        return json(c, 201);
      }
      return json({ comments: [] });
    }
    if (p.endsWith("/versions")) {
      const body = req.postDataJSON();
      s.saves.push(body);
      if (body.base_seq !== head().seq) return json({ code: "conflict", message: `this canvas is at version ${head().seq}, not ${body.base_seq}` }, 409);
      const v = { seq: head().seq + 1, author_type: "user" as const, note: body.note ?? "", body: body.body };
      s.versions.push(v);
      return json({ seq: v.seq, note: v.note, author_type: "user", created_at: at }, 201);
    }
    const want = Number(u.searchParams.get("seq")) || head().seq;
    const v = s.versions.find((x) => x.seq === want)!;
    return json({ id: DOC, kind: "text", title: "Trip plan", seq: head().seq, viewing_seq: v.seq, created_at: at, updated_at: at, body: v.body, versions: [...s.versions].reverse().map((x) => ({ seq: x.seq, note: x.note, author_type: x.author_type, created_at: at })) });
  });
  /** The persona edits the document, as canvas_patch would. */
  const agentEdit = (body: string, note = "Edited") => s.versions.push({ seq: head().seq + 1, author_type: "agent", note, body });
  return { mock, chatId, s, head, agentEdit };
}

const editor = (page: Page) => page.getByTestId("doc-editor");
const dock = (page: Page) => page.getByRole("complementary", { name: "Panel", exact: true });
const rail = (page: Page) => page.getByRole("navigation", { name: "Panel rail" });
const dockTab = (page: Page, name: string) => rail(page).getByRole("tablist", { name: "Panel tabs" }).getByRole("tab", { name: new RegExp(`^${name}`) });
// Chat alone shows no tab strip: its panel, under the chat header in the dock\'s first row, is what shows.
const chatShown = (page: Page) => dock(page).getByRole("tabpanel", { name: /^Chat/ }).first();
const mod = process.platform === "darwin" ? "Meta" : "Control";

/**
 * Puts the caret at the end of the document's first paragraph. ProseMirror
 * reads a click's caret from the DOM a moment later; keys pressed sooner land
 * where its caret was, so wait until it has caught up.
 */
async function caretAtParagraphEnd(page: Page) {
  const p = editor(page).locator("p").first();
  await p.click();
  await page.keyboard.press("End");
  const end = await p.evaluate((el) => {
    const view = (el.closest(".ProseMirror") as unknown as { editor: { view: { posAtDOM: (n: Node, o: number) => number } } }).editor.view;
    return view.posAtDOM(el, el.childNodes.length);
  });
  await expect
    .poll(() => editor(page).evaluate((el) => (el as unknown as { editor: { state: { selection: { from: number } } } }).editor.state.selection.from))
    .toBe(end);
}

test("opening a document saves nothing, even when the editor tidies it", async ({ page }) => {
  // A table at the end gets a paragraph after it in the editor; that isn't an edit.
  const { s } = await install(page, "# Trip plan\n\nFour days in late March, flying in **Friday** morning.\n\n## Days\n\n- Fri: Alfama\n- Sat: Belém\n\n## Bookings\n\n- [x] Flights\n- [ ] Stay\n\n| Day | Plan |\n|---|---|\n| Fri | Alfama |\n");
  await page.goto(`/apps/docs/${DOC}`);
  await expect(editor(page).locator("table")).toContainText("Alfama");
  await editor(page).locator("p").first().click();
  // Past the save delay (1.5s): a negative, so it has to wait.
  await page.waitForTimeout(2000);
  await expect(page.getByTestId("doc-save-state")).toHaveText("Saved · v1");
  expect(s.saves).toEqual([]);
});

test("the persona's edits come back as suggestions to accept or reject", async ({ page }) => {
  const { s, agentEdit } = await install(page, "# Trip plan\n\nFly on Friday.\n\nStay in Alfama.\n");
  agentEdit("# Trip plan\n\nFly on Friday morning.\n\nStay in Alfama.\n\nDay trip to Sintra.\n");
  await page.goto(`/apps/docs/${DOC}`);

  // The suggestions sit in place on the page; the Review tab lists them, with a count.
  const review = page.getByTestId("doc-review");
  const list = page.getByTestId("doc-review-list");
  await expect(dockTab(page, "Review")).toHaveAttribute("aria-selected", "true");
  await expect(dockTab(page, "Review")).toContainText("2");
  await expect(list).toContainText("Assistant suggested 2 changes");
  await expect(list.getByRole("listitem")).toHaveCount(2);
  await expect(list.getByRole("listitem").nth(1)).toContainText("Day trip to Sintra");
  const changes = review.getByTestId("doc-change");
  await expect(changes).toHaveCount(2);
  await expect(changes.first()).toContainText("Fly on Friday.");
  await expect(changes.first()).toContainText("Fly on Friday morning.");

  // Keep the first, drop the second: the page goes back to editing on a version that says so.
  await changes.first().getByRole("button", { name: "Accept" }).click();
  // Deciding in place shows in the list too.
  await expect(list.getByRole("listitem").first()).toContainText("Accepted · Undo");
  await expect(dockTab(page, "Review")).toContainText("1");
  await changes.nth(1).getByRole("button", { name: "Reject" }).click();
  await expect(editor(page)).toContainText("Fly on Friday morning.");
  await expect(editor(page)).not.toContainText("Sintra");
  expect(s.saves).toEqual([{ base_seq: 2, body: "# Trip plan\n\nFly on Friday morning.\n\nStay in Alfama.\n", note: "Kept 1 of Assistant's 2 changes, rejected 1" }]);
  expect(s.reviewedPosts).toEqual([]);
  await expect(dockTab(page, "Review")).toHaveCount(0);

  // Accepting everything writes nothing; it records the review instead.
  agentEdit("# Trip plan\n\nFly on Friday morning.\n\nStay in Alfama, near the castle.\n");
  await page.reload();
  await page.getByRole("button", { name: "Accept all" }).click();
  await expect(editor(page)).toContainText("near the castle");
  expect(s.reviewedPosts).toEqual([4]);
  expect(s.saves).toHaveLength(1);
});

test("@persona on a line of its own asks for writing right there", async ({ page }) => {
  const { mock, chatId } = await install(page);
  await page.goto(`/apps/docs/${DOC}`);
  await expect(editor(page)).toContainText("Lisbon");
  await caretAtParagraphEnd(page);
  await page.keyboard.press("Enter");
  await page.keyboard.type("@Assistant add a packing list");
  await page.keyboard.press("Enter");

  await expect.poll(() => mock.posted.filter((x) => x.chat === chatId).map((x) => x.body.body)).toContainEqual(expect.stringContaining("add a packing list"));
  const asked = mock.posted.filter((x) => x.chat === chatId).at(-1)!.body.body as string;
  expect(asked).toContain("right after the passage “Fly to Lisbon on Friday.”");
  // The request line itself doesn't stay in the document.
  await expect(editor(page)).not.toContainText("@Assistant");
});

test("a selection can go to the persona as a comment on that passage", async ({ page }) => {
  const { s } = await install(page);
  await page.goto(`/apps/docs/${DOC}`);
  await editor(page).locator("p", { hasText: "Lisbon" }).evaluate((p) => {
    // Select "Lisbon on Friday" across the bold mark.
    const r = document.createRange();
    r.setStart(p.querySelector("strong")!.firstChild!, 0);
    r.setEnd(p.lastChild!, " on Friday".length);
    getSelection()!.removeAllRanges();
    getSelection()!.addRange(r);
  });
  const menu = page.getByTestId("doc-selection-menu");
  await expect(menu).toBeVisible();
  await menu.getByRole("button", { name: "Shorter" }).click();

  await expect.poll(() => s.sent.length).toBe(1);
  const body = "# Trip plan\n\nFly to **Lisbon** on Friday.\n";
  const c = s.comments[0] as { seq: number; start: number; end: number; body: string };
  expect({ seq: c.seq, quoted: body.slice(c.start, c.end), body: c.body }).toEqual({ seq: 1, quoted: "Lisbon** on Friday", body: "Make this shorter." });
  expect(s.sent[0]).toEqual({ comment_ids: ["c1"], message: "Make this shorter." });
});

test("exports to PDF, Word and Markdown, copies rich text, and saves to the Library", async ({ page, context }) => {
  const { s } = await install(page);
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto(`/apps/docs/${DOC}`);
  await expect(editor(page)).toContainText("Lisbon");
  const menu = async (name: string) => {
    await page.getByRole("button", { name: "Share" }).click();
    await page.getByRole("menuitem", { name: new RegExp(`^${name}`) }).click();
  };

  for (const [name, file] of [["Word", "Trip plan.docx"], ["Markdown", "Trip plan.md"]] as const) {
    const download = page.waitForEvent("download");
    await menu(name);
    expect((await download).suggestedFilename()).toBe(file);
  }

  const popup = page.waitForEvent("popup");
  await page.addInitScript(() => (window.print = () => {}));
  await menu("PDF");
  const print = await popup;
  await expect(print).toHaveURL(new RegExp(`/print/docs/${DOC}$`));

  await menu("Copy as rich text");
  await expect(page.getByRole("status").filter({ hasText: "Copied with formatting" })).toBeVisible();
  const html = await page.evaluate(async () => {
    const [item] = await navigator.clipboard.read();
    return (await item.getType("text/html")).text();
  });
  expect(html).toContain("<strong>Lisbon</strong>");

  await menu("Save to Library");
  await expect(page.getByRole("status").filter({ hasText: "Saved to your Library" })).toBeVisible();
  expect(s.library).toBe(1);

  // Promoting asks before replacing a page that exists, then links to the page.
  await menu("Promote to wiki");
  await page.getByRole("alertdialog").getByRole("button", { name: "Replace" }).click();
  const published = page.getByRole("status").filter({ hasText: "Published to the wiki as Trip plan" });
  await expect(published).toBeVisible();
  await expect(published.getByRole("link", { name: "Open" })).toHaveAttribute("href", "/wiki/Trip%20plan");
  expect(s.wiki).toEqual([{ replace: false }, { replace: true }]);
});

test("Markdown the editor can't keep opens as source instead", async ({ page }) => {
  await install(page, "# Trip plan\n\nA claim.[^1]\n\n[^1]: The source.\n");
  await page.goto(`/apps/docs/${DOC}`);
  await expect(page.getByText("This document has HTML or footnotes the editor can't keep")).toBeVisible();
  await expect(editor(page)).toHaveCount(0);
  await expect(page.getByTestId("doc-page")).toContainText("A claim.");
});

test("the dock collapses and reopens, with ⌘\\, ⌘J and ⌘., and the outline jumps to a heading", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await install(page, "# Trip plan\n\nFly to **Lisbon** on Friday.\n\n## Days\n\n- Fri: Alfama\n\n## Bookings\n\n- Flights\n");
  await page.goto(`/apps/docs/${DOC}`);
  await expect(editor(page)).toContainText("Lisbon");

  // Header: back, title, save state, Share; the chat is the dock's one tab, its header the dock's first row.
  await expect(page.getByRole("link", { name: "Docs" }).first()).toHaveAttribute("href", "/apps/docs");
  await expect(page.getByRole("heading", { name: "Trip plan", level: 1 }).first()).toBeVisible();
  await expect(chatShown(page)).toBeVisible();
  await expect(dock(page).getByTestId("doc-chat")).toBeVisible();

  // ⇥ collapses to the rail; the rail reopens it.
  await rail(page).getByRole("button", { name: "Collapse panel" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await rail(page).getByRole("button", { name: "Open Chat" }).click();
  await expect(chatShown(page)).toBeVisible();
  await rail(page).getByRole("button", { name: "Collapse panel" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();

  // ⌘\ reopens it; ⌘J brings Chat up with its composer focused.
  await page.locator("header").first().click({ position: { x: 600, y: 10 } });
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toBeVisible();
  await page.locator("header").first().click({ position: { x: 600, y: 10 } });
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await page.keyboard.press(`${mod}+j`);
  await expect(chatShown(page)).toBeVisible();
  await expect(dock(page).getByLabel("Message", { exact: true })).toBeFocused();

  // ⌘. hides every panel and pressing it again restores them.
  await page.locator("header").first().click({ position: { x: 600, y: 10 } });
  await page.keyboard.press(`${mod}+Period`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toHaveCount(0);
  await page.keyboard.press(`${mod}+Period`);
  await expect(dock(page)).toBeVisible();

  // The dock stays as it was left across a reload.
  await page.locator("header").first().click({ position: { x: 600, y: 10 } });
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await page.reload();
  await expect(editor(page)).toContainText("Lisbon");
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();

  // The outline starts collapsed and lists the headings.
  const outline = page.getByRole("navigation", { name: "Outline" });
  await expect(outline).toHaveCount(0);
  await page.getByRole("button", { name: "Show outline" }).click();
  await expect(outline.getByRole("list").getByRole("button")).toHaveText(["Trip plan", "Days", "Bookings"]);
  await outline.getByRole("button", { name: "Bookings" }).click();
  await expect(editor(page).getByRole("heading", { name: "Bookings" })).toBeInViewport();
  await outline.getByRole("button", { name: "Hide outline" }).click();
  await expect(outline).toHaveCount(0);
});

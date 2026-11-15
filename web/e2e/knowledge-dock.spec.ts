import { expect, test, type Page, type Route } from "@playwright/test";
import { installChatApi, persona, type MockOptions } from "./mock-chat-api";

// The persona chat dock on every Knowledge screen: folded to a rail by default, on the shared dock.
test.use({ viewport: { width: 1440, height: 900 } });

const P = "55555555-5555-4555-8555-555555555555";
const Q = "66666666-6666-4666-8666-666666666666";
const F1 = "88888888-8888-4888-8888-888888888881";
const F2 = "88888888-8888-4888-8888-888888888882";
const json = (route: Route, data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });

async function install(page: Page, options: MockOptions = {}) {
  const chat = await installChatApi(page, { replyDelayMs: 10, ...options });
  const s = { attached: [] as string[], page: { id: P, title: "Reading list", path: "Reading list", audience: "private", body_md: "Notes", version_id: "v1", seq: 1, properties: {}, direct: false, paused: false, chat_id: null as string | null, url: `/knowledge/${P}`, embeds: [], reviews: [], versions: [] } };
  const pages = [s.page, { ...s.page, id: Q, title: "Other notes", path: "Other notes", body_md: "Second page", url: `/knowledge/${Q}` },
    { ...s.page, id: F1, title: "Dawn", path: "Campaign/Sessions/Dawn", url: `/knowledge/${F1}` }, { ...s.page, id: F2, title: "Harbour", path: "Campaign/Harbour", url: `/knowledge/${F2}` }];
  await page.route(/\/api\/v1\/knowledge\//, (route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname.replace("/api/v1/knowledge", "");
    if (path === "/query") return json(route, { columns: [], rows: pages, total: pages.length, has_more: false });
    const target = pages.find((p) => path === `/pages/${p.id}` || path === `/pages/${p.id}/chat`);
    if (target && path.endsWith("/chat") && req.method() === "PUT") {
      target.chat_id = (req.postDataJSON() as { chat_id: string }).chat_id;
      s.attached.push(target.chat_id);
      return json(route, target);
    }
    if (target) {
      if (req.method() === "PUT") Object.assign(target, req.postDataJSON(), { seq: target.seq + 1 });
      return json(route, target);
    }
    if (path === "/network" || path === "/graph") return json(route, { nodes: [], edges: [] });
    if (path === "/backlinks") return json(route, { linked: [], unlinked: [] });
    return json(route, {});
  });
  return { ...s, chat };
}

const dock = (page: Page) => page.getByRole("complementary", { name: "Panel", exact: true });
const rail = (page: Page) => page.getByRole("navigation", { name: "Panel rail" });
const mod = process.platform === "darwin" ? "Meta" : "Control";

test("the chat starts folded to a rail on Home, opens from it, and a general chat starts there", async ({ page }) => {
  await install(page);
  await page.goto("/knowledge");
  await expect(rail(page)).toBeVisible();
  await expect(dock(page)).toHaveCount(0);

  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await expect(dock(page).getByRole("tabpanel", { name: /^Chat/ }).first()).toBeVisible();
  await dock(page).getByRole("button", { name: "Start a chat", exact: true }).click();
  await expect(dock(page).getByRole("combobox", { name: "Message" })).toBeVisible();

  // A reload in the same tab keeps it open, with the same chat.
  await page.reload();
  await expect(dock(page)).toBeVisible();
  await expect(dock(page).getByRole("combobox", { name: "Message" })).toBeVisible();

  // ⌘\ folds it again.
  await page.locator("body").click({ position: { x: 700, y: 400 } });
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
});

test("a new tab starts folded even if the dock was open elsewhere", async ({ page, context }) => {
  await install(page);
  await page.goto("/knowledge");
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await expect(dock(page)).toBeVisible();

  const other = await context.newPage();
  // Left behind by builds that remembered the open state across visits.
  await other.addInitScript(() => window.localStorage.setItem("lazyagents.editor-dock.knowledge", JSON.stringify({ open: true, tab: "chat" })));
  await install(other);
  await other.goto("/knowledge");
  await expect(rail(other)).toBeVisible();
  await expect(dock(other)).toHaveCount(0);
});

test("a remembered general chat that no longer exists falls back to Start a chat", async ({ page }) => {
  await install(page);
  await page.addInitScript(() => window.localStorage.setItem("vesper.knowledge.chat", "77777777-7777-4777-8777-777777777777"));
  await page.goto("/knowledge");
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await expect(dock(page).getByRole("button", { name: "Start a chat", exact: true })).toBeVisible();
  await expect(dock(page).getByText("This chat doesn’t exist")).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => window.localStorage.getItem("vesper.knowledge.chat"))).toBeNull();
});

test("on a page the dock holds that page's chat, and ⌘J opens it", async ({ page }) => {
  const s = await install(page);
  await page.goto(`/knowledge/${P}`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  // One right sidebar: the page's panels are the dock's, not a second aside beside it.
  await expect(page.getByRole("complementary", { name: "Page sidebar" })).toHaveCount(0);

  await page.keyboard.press(`${mod}+j`);
  await expect(dock(page)).toBeVisible();
  await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
  await expect.poll(() => s.attached.length).toBe(1);
  await expect(dock(page).getByRole("combobox", { name: "Message" })).toBeVisible();
});

test("every message carries the viewed page, including after the page changes", async ({ page }) => {
  const s = await install(page);
  await page.goto(`/knowledge/${P}`);
  await expect(rail(page)).toBeVisible();
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await expect(dock(page).getByText("Viewing: Reading list", { exact: true })).toBeVisible();
  // The dock always talks to a persona, named beside what the message carries.
  await expect(dock(page).getByTestId("dock-chat-to")).not.toHaveText("your persona");
  await expect(dock(page).getByTestId("dock-chat-to")).not.toBeEmpty();
  expect(s.chat.posted).toHaveLength(0);
  for (const question of ["Summarise this", "What changed?"]) {
    await input.fill(question);
    await input.press("Enter");
    await expect.poll(() => s.chat.posted.length).toBe(question === "Summarise this" ? 1 : 2);
    expect(s.chat.posted.at(-1)?.body.context_refs).toEqual([{ kind: "page", id: P }]);
    await expect(dock(page).getByRole("button", { name: "Send", exact: true })).toBeVisible();
    if (question === "Summarise this") {
      s.page.body_md = "Updated notes";
      s.page.seq++;
      await page.reload();
      await expect(page.getByTestId("doc-editor")).toContainText("Updated notes");
    }
  }
});

test("Ask a Persona captures unsaved selected text without sending", async ({ page }) => {
  const s = await install(page);
  await page.goto(`/knowledge/${P}`);
  const editor = page.getByTestId("doc-editor");
  await editor.fill("A passage that has not been saved yet.");
  await editor.press(`${mod}+a`);
  await editor.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Ask a Persona", exact: true }).click();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await expect(input).toBeFocused();
  await expect(dock(page).getByRole("button", { name: "Remove selection from Reading list" })).toBeVisible();
  expect(s.chat.posted).toHaveLength(0);
  expect(s.chat.created).toHaveLength(1);
  expect(s.chat.created[0].hidden).toBe(true);
  await input.fill("Explain this");
  await input.press("Enter");
  await expect.poll(() => s.chat.posted.length).toBe(1);
  expect(s.chat.posted[0].body.body).toContain("> A passage that has not been saved yet.");
  expect(s.chat.posted[0].body.body).toContain("\n\n<!-- vesper:knowledge-context -->\n");
  expect(s.chat.posted[0].body.body).toContain("[[Reading list]]");
  expect(s.chat.posted[0].body.context_refs).toEqual([{ kind: "page", id: P }]);
  await expect(dock(page).getByRole("button", { name: "Remove selection from Reading list" })).toHaveCount(0);
});

test("a failed send preserves the question and selection for retry", async ({ page }) => {
  const s = await install(page);
  let failed = false;
  await page.route(/\/api\/v1\/chats\/[^/]+\/messages$/, (route) => {
    if (route.request().method() === "POST" && !failed) {
      failed = true;
      return json(route, { code: "invalid", message: "Please retry this message" }, 422);
    }
    return route.fallback();
  });
  await page.goto(`/knowledge/${P}`);
  const editor = page.getByTestId("doc-editor");
  await editor.click();
  await editor.press(`${mod}+a`);
  await editor.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Ask a Persona", exact: true }).click();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await input.fill("Explain this");
  await input.press("Enter");
  await expect(dock(page).getByText("Please retry this message", { exact: true })).toBeVisible();
  await expect(input).toHaveValue("Explain this");
  await expect(dock(page).getByRole("button", { name: "Remove selection from Reading list" })).toBeVisible();
  await input.press("Enter");
  await expect.poll(() => s.chat.posted.length).toBe(1);
  await expect(dock(page).getByRole("button", { name: "Remove selection from Reading list" })).toHaveCount(0);
});

test("explorer attachments reuse the chat, can be removed, and preserve the question", async ({ page }) => {
  const s = await install(page);
  await page.goto(`/knowledge/${P}`);
  const other = page.getByRole("complementary", { name: "Knowledge explorer" }).getByRole("link", { name: "Other notes", exact: true });
  const ask = async () => {
    await other.click({ button: "right" });
    await page.getByRole("menuitem", { name: "Ask a Persona", exact: true }).click();
  };
  await ask();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await expect(input).toBeFocused();
  await input.fill("Compare these pages");
  await dock(page).getByRole("button", { name: "Remove Other notes" }).click();
  await expect(input).toHaveValue("Compare these pages");
  await ask();
  await ask();
  await expect(dock(page).getByRole("button", { name: "Remove Other notes" })).toHaveCount(1);
  expect(s.chat.created).toHaveLength(1);
  expect(s.chat.posted).toHaveLength(0);
  expect(new URL(page.url()).pathname).toBe(`/knowledge/${P}`);
  await input.press("Enter");
  await expect.poll(() => s.chat.posted.length).toBe(1);
  expect(s.chat.posted[0].body.context_refs).toEqual([{ kind: "page", id: P }, { kind: "page", id: Q }]);
});

test("a selected passage stays attached after navigation and a new page is not automatically given a chat", async ({ page }) => {
  const s = await install(page);
  await page.goto(`/knowledge/${P}`);
  const editor = page.getByTestId("doc-editor");
  await editor.click();
  await editor.press(`${mod}+a`);
  await editor.click({ button: "right" });
  await page.getByRole("menuitem", { name: "Ask a Persona", exact: true }).click();
  await expect(dock(page).getByRole("combobox", { name: "Message" })).toBeVisible();
  await page.getByRole("complementary", { name: "Knowledge explorer" }).getByRole("link", { name: "Other notes", exact: true }).click();
  await expect(dock(page).getByText("Viewing: Other notes", { exact: true })).toBeVisible();
  await expect(dock(page).getByRole("button", { name: "Remove selection from Reading list" })).toBeVisible();
  expect(s.chat.created).toHaveLength(1);
  await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await input.fill("Compare with this page");
  await input.press("Enter");
  await expect.poll(() => s.chat.posted.length).toBe(1);
  expect(s.chat.posted[0].body.body).toContain("Selected passage from [[Reading list]]:\n> Notes");
  expect(s.chat.posted[0].body.body).toContain("Currently viewing Knowledge page [[Other notes]]");
  expect(s.chat.posted[0].body.context_refs).toEqual([{ kind: "page", id: Q }, { kind: "page", id: P }]);
});

for (const [command, endpoint] of [["queue", "followups"], ["aside", "asides"]]) {
  test(`${command} includes a page snapshot while the persona is running`, async ({ page }) => {
    await install(page);
    await page.route(new RegExp(`/api/v1/chats/[^/]+/${endpoint}$`), (route) => route.request().method() === "POST"
      ? json(route, { id: "99999999-9999-4999-8999-999999999999", body: route.request().postDataJSON().body, created_at: new Date().toISOString() }, 202)
      : route.fallback());
    await page.goto(`/knowledge/${P}`);
    await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
    await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
    const input = dock(page).getByRole("combobox", { name: "Message" });
    await input.fill("slow: Keep working");
    await input.press("Enter");
    await expect(dock(page).getByRole("button", { name: "Stop", exact: true })).toBeVisible();
    const posted = page.waitForRequest((r) => r.method() === "POST" && new URL(r.url()).pathname.endsWith(`/${endpoint}`));
    await input.fill(`/${command} Explain this page`);
    await input.press("Enter");
    const body = (await posted).postDataJSON().body;
    expect(body).toContain("Explain this page");
    expect(body).toContain("Page snapshot of [[Reading list]]:\n> Notes");
    await expect(input).toHaveValue("");
  });
}

test("in the dock a running turn starts as a strip naming the step under way, and opens to every step", async ({ page }) => {
  await install(page);
  await page.goto(`/knowledge/${P}`);
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await input.fill("steps: work through it");
  await input.press("Enter");
  const card = dock(page).getByTestId("chat-status-card");
  await expect(card).toHaveAttribute("data-folded", "true");
  await expect(card.getByTestId("chat-step-now")).toHaveText(/^Fix the snapshot\s*2 of 3$/);
  await expect(card.getByTestId("chat-steps")).toHaveCount(0);
  await card.getByRole("button", { name: "Show steps" }).click();
  await expect(card.getByTestId("chat-steps").locator("li")).toHaveCount(3);
  await expect(card.getByTestId("chat-step-now")).toHaveCount(0);
  await dock(page).getByRole("button", { name: "Stop", exact: true }).click();
});

test("a docked chat has one header row: no Chat/Activity tabs or repository picker, Activity is a toggle", async ({ page }) => {
  await install(page);
  await page.goto(`/knowledge/${P}`);
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
  const header = dock(page).getByTestId("chat-header");
  await expect(header).toBeVisible();
  await expect(header.getByRole("tablist", { name: "Chat view" })).toHaveCount(0);
  // The pane's back and forward are on the rail; the dock doesn't repeat them.
  await expect(dock(page).getByRole("group", { name: "History" })).toHaveCount(0);
  expect((await header.boundingBox())!.height).toBeLessThanOrEqual(48);
  const activity = header.getByRole("button", { name: "Activity" });
  await activity.click();
  await expect(activity).toHaveAttribute("aria-pressed", "true");
  await expect(dock(page).getByRole("tabpanel", { name: "Activity" })).toBeVisible();
  await activity.click();
  await expect(dock(page).locator('[role="tabpanel"][aria-label="Chat"]')).toBeVisible();
});

test("switching persona keeps the draft and page context inside Knowledge", async ({ page }) => {
  const first = persona(1, { name: "Atlas", is_default: true });
  const second = persona(2, { name: "Nova" });
  const s = await install(page, { personas: [first, second] });
  await page.goto(`/knowledge/${P}`);
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await input.fill("Read this page");
  await dock(page).getByRole("button", { name: "Persona for this conversation: Atlas" }).click();
  await page.getByRole("menuitemradio", { name: /Nova/ }).click();
  await expect(input).toHaveValue("Read this page");
  await expect(dock(page).getByRole("button", { name: "Persona for this conversation: Nova" })).toBeVisible();
  expect(s.chat.created.map((chat) => chat.hidden)).toEqual([true, true]);
  expect(new URL(page.url()).pathname).toBe(`/knowledge/${P}`);
  expect(s.chat.posted).toHaveLength(0);
  await input.press("Enter");
  await expect.poll(() => s.chat.posted.length).toBe(1);
  expect(s.chat.posted[0].body.context_refs).toEqual([{ kind: "page", id: P }]);
});

test("off a page, messages say which Knowledge screen the person is on", async ({ page }) => {
  const s = await install(page);
  await page.goto("/knowledge");
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat", exact: true }).click();
  await expect(dock(page).getByText("On: Home", { exact: true })).toBeVisible();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await input.fill("Tidy my notes");
  await input.press("Enter");
  await expect.poll(() => s.chat.posted.length).toBe(1);
  expect(s.chat.posted[0].body.body).toBe("Tidy my notes\n\n<!-- vesper:knowledge-context -->\nOn the Knowledge Home screen, not viewing a page.");
});

test("Ask a Persona on a folder attaches its path and pages", async ({ page }) => {
  const s = await install(page);
  await page.goto("/knowledge");
  const explorer = page.getByRole("complementary", { name: "Knowledge explorer" });
  await explorer.getByRole("button", { name: "Campaign", exact: true }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Ask a Persona", exact: true }).click();
  const input = dock(page).getByRole("combobox", { name: "Message" });
  await expect(input).toBeFocused();
  await expect(dock(page).getByRole("button", { name: "Remove folder Campaign" })).toBeVisible();
  expect(s.chat.posted).toHaveLength(0);
  await input.fill("Move these into Archive");
  await input.press("Enter");
  await expect.poll(() => s.chat.posted.length).toBe(1);
  const body = s.chat.posted[0].body.body;
  expect(body).toContain("Attached folder Campaign/ (2 pages):\n- [[Campaign/Sessions/Dawn]]\n- [[Campaign/Harbour]]");
  expect(s.chat.posted[0].body.context_refs ?? []).toEqual([]);
  await expect(dock(page).getByRole("button", { name: "Remove folder Campaign" })).toHaveCount(0);
});

test("the dock keeps every Knowledge chat: New starts another in place and the switcher goes back", async ({ page }) => {
  const s = await install(page);
  await page.goto("/knowledge");
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat", exact: true }).click();
  const switcher = dock(page).getByTestId("dock-chat-switcher");
  await expect(switcher).toBeVisible();
  await expect.poll(() => s.chat.created.length).toBe(1);
  const stored = () => page.evaluate(() => window.localStorage.getItem("vesper.knowledge.chat"));
  await expect.poll(stored).not.toBeNull();
  const firstId = await stored();

  // New starts a second chat in the dock, without leaving Knowledge.
  await switcher.getByRole("button", { name: "New chat", exact: true }).click();
  await expect.poll(() => s.chat.created.length).toBe(2);
  await expect(page).toHaveURL(/\/knowledge$/);
  await expect(switcher.getByRole("button", { name: /^Switch chat/ })).toContainText("2");

  // The switcher lists both and opens the first again.
  await switcher.getByRole("button", { name: /^Switch chat/ }).click();
  const items = page.getByRole("menuitem");
  await expect(items.filter({ hasText: /ago|just now/ })).toHaveCount(2);
  await expect.poll(stored).not.toBe(firstId);
  await items.filter({ hasText: /ago|just now/ }).last().click();
  await expect.poll(stored).toBe(firstId);
});

test("the shell fits the viewport: a long tree and an open chat leave the composer and explorer footer on screen", async ({ page }) => {
  const s = await install(page);
  // Enough pages that the explorer tree is taller than the window.
  const many = Array.from({ length: 60 }, (_, i) => ({ ...s.page, id: `77777777-7777-4777-8777-${String(i).padStart(12, "0")}`, title: `Note ${i}`, path: `Note ${i}` }));
  await page.route(/\/api\/v1\/knowledge\/query/, (route) => json(route, { columns: [], rows: [s.page, ...many], total: many.length + 1, has_more: false }));
  await page.goto("/knowledge");
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat", exact: true }).click();
  const composer = dock(page).getByRole("combobox", { name: "Message" });
  await expect(composer).toBeInViewport({ ratio: 1 });
  await expect(page.getByRole("complementary", { name: "Knowledge explorer" }).getByRole("button", { name: /Quick capture/ })).toBeInViewport({ ratio: 1 });
  expect(await page.evaluate(() => document.scrollingElement!.scrollHeight - window.innerHeight)).toBeLessThanOrEqual(0);
});

const general = ["Tune PR #387", "Sheets engine", "Deploy plan", "Fix the error"].map((title) => ({ title, prompt: `${title}, please`, icon: "msg" }));

test("an empty Knowledge chat offers starters about the notes, not the person's general suggestions, under one header", async ({ page }) => {
  const s = await install(page, { suggestions: general });
  await page.goto("/knowledge");
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat", exact: true }).click();
  const starters = dock(page).getByRole("list", { name: "Conversation starters" });
  await expect(starters.getByRole("button", { name: /File my inbox/ })).toBeVisible();
  await expect(dock(page).getByText("Tune PR #387")).toHaveCount(0);
  // One header: the switcher sits in the conversation's header, not a bar of its own above it.
  await expect(dock(page).getByTestId("dock-chat-switcher")).toHaveCount(1);
  await expect(dock(page).getByRole("button", { name: /^Switch chat/ })).toHaveCount(1);
  await expect(dock(page).getByRole("button", { name: "New chat", exact: true })).toBeVisible();

  // Picking one sends its prompt.
  await starters.getByRole("button", { name: /File my inbox/ }).click();
  await expect.poll(() => s.chat.posted.length).toBe(1);
  expect(s.chat.posted[0].body.body).toContain("captures in my Inbox");
});

test("on a page the starters are about that page", async ({ page }) => {
  await install(page, { suggestions: general });
  await page.goto(`/knowledge/${P}`);
  await rail(page).getByRole("button", { name: /^Open Chat/ }).click();
  await dock(page).getByRole("button", { name: "Start a chat about this page" }).click();
  const starters = dock(page).getByRole("list", { name: "Conversation starters" });
  await expect(starters.getByRole("button", { name: /Summarise this page/ })).toBeVisible();
  await expect(dock(page).getByText(/on “Reading list”/)).toBeVisible();
  await expect(dock(page).getByText("Tune PR #387")).toHaveCount(0);
});

test("a page's Links, Outline, Calendar and History are dock tabs beside Chat, and the edit-mode pill opens History", async ({ page }) => {
  await install(page);
  await page.goto(`/knowledge/${P}`);
  for (const name of ["Links", "Outline", "Calendar and inbox", "History"]) await expect(rail(page).getByRole("button", { name: `Open ${name}` })).toBeVisible();
  await rail(page).getByRole("button", { name: "Open Links" }).click();
  await expect(rail(page).getByRole("tab", { name: "Links" })).toHaveAttribute("aria-selected", "true");
  await rail(page).getByRole("tab", { name: /Chat/ }).click();
  await expect(dock(page).getByRole("tabpanel", { name: /^Chat/ }).first()).toBeVisible();

  await page.getByRole("button", { name: /suggests changes|edits directly|paused/ }).click();
  await expect(rail(page).getByRole("tab", { name: "History" })).toHaveAttribute("aria-selected", "true");

  // Off a page there is only Chat.
  await page.goto("/knowledge");
  await expect(rail(page).getByRole("button", { name: "Open Links" })).toHaveCount(0);
});

test("the explorer pins pages to the top, caps long folders with + N more, and collapses every folder", async ({ page }) => {
  const s = await install(page);
  const folder = Array.from({ length: 12 }, (_, i) => ({ ...s.page, id: `99999999-9999-4999-8999-${String(i).padStart(12, "0")}`, title: `Creator ${String(i).padStart(2, "0")}`, path: `People/Creator ${String(i).padStart(2, "0")}` }));
  await page.route(/\/api\/v1\/knowledge\/query/, (route) => json(route, { columns: [], rows: [s.page, ...folder], total: folder.length + 1, has_more: false }));
  await page.goto("/knowledge");
  const explorer = page.getByRole("complementary", { name: "Knowledge explorer" });
  await explorer.getByRole("button", { name: "People" }).click();
  await expect(explorer.getByRole("link", { name: /Creator/ })).toHaveCount(8);
  await explorer.getByRole("button", { name: "+ 4 more" }).click();
  await expect(explorer.getByRole("link", { name: /Creator/ })).toHaveCount(12);

  await explorer.getByRole("link", { name: "Reading list" }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Pin to top" }).click();
  await expect(explorer.getByRole("region", { name: "Pinned" }).getByRole("link", { name: "Reading list" })).toBeVisible();

  await explorer.getByRole("button", { name: "Collapse all folders" }).click();
  await expect(explorer.getByRole("link", { name: /Creator/ })).toHaveCount(0);
  // Pins survive a reload.
  await page.reload();
  await expect(explorer.getByRole("region", { name: "Pinned" }).getByRole("link", { name: "Reading list" })).toBeVisible();
});

test("Home leads with what needs you, then where you left off, and tells untitled pages apart", async ({ page }) => {
  const s = await install(page);
  const at = new Date().toISOString();
  const rows = [
    { ...s.page, title: "Reading list", summary: "Books for the winter", updated_at: at, pending: 2 },
    { ...s.page, id: Q, title: "Untitled", path: "Docs/Untitled", summary: "Ideas for the theme picker", updated_at: at, pending: 0 },
    { ...s.page, id: F1, title: "Untitled", path: "Docs/Untitled 2", summary: "", updated_at: at, pending: 0 },
  ];
  const capture = { ...s.page, id: F2, title: "A thought", path: "Inbox/A thought", summary: "", updated_at: at, pending: 0 };
  await page.route(/\/api\/v1\/knowledge\/query/, (route) => {
    const q = route.request().postDataJSON() as { folder?: string };
    if (q.folder === "Inbox") return json(route, { columns: [], rows: [capture], has_more: false });
    if (q.folder === "Patterns/Proposed") return json(route, { columns: [], rows: [], has_more: false });
    return json(route, { columns: [], rows, has_more: false });
  });
  await page.goto("/knowledge");
  const needs = page.getByRole("region", { name: "Needs you" });
  await expect(needs.getByRole("button", { name: /1\s*page with suggestions to review/ })).toBeVisible();
  await expect(needs.getByRole("button", { name: /1\s*inbox captures to file/ })).toBeVisible();
  await expect(needs.getByRole("button", { name: /agent pattern proposals/ })).toHaveCount(0);
  await expect(page.getByRole("region", { name: "Pick up where you left off" })).toContainText("Reading list");
  await expect(page.getByText("Untitled · “Ideas for the theme picker”")).toBeVisible();
  await expect(page.getByText(/Docs · empty/)).toBeVisible();
  // The four quick-action cards are gone: the explorer and shortcuts already do them.
  await expect(page.getByRole("button", { name: "Today's note" })).toHaveCount(0);

  // Filing the inbox asks a persona with the Inbox attached.
  await needs.getByRole("button", { name: /inbox captures/ }).click();
  await expect(dock(page)).toBeVisible();
  await expect(dock(page).getByRole("button", { name: "Remove folder Inbox" })).toBeVisible();
});

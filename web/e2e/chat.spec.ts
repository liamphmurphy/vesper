import { expect, test, type Page } from "@playwright/test";
import { AGENTS, catalog, installChatApi, openEmptyChat, persona, composerOption } from "./mock-chat-api";

// History lives in the expanded menu.
test.beforeEach(({ page }) => page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1")));

const composer = (page: Page) => page.getByRole("combobox", { name: "Message" });
// Model and effort are one control in the composer ("Opus 5.5 · Auto"), with one menu.
const picker = (page: Page) => page.getByRole("button", { name: /^Model and effort for the next message/ });
const effort = picker;
const effortItems = (page: Page) => page.getByRole("group", { name: "Reasoning effort" }).getByRole("menuitem");

const chips = (page: Page) => page.getByTestId("context-chip");

// An empty conversation, with the full composer.
async function newChat(page: Page) {
  await openEmptyChat(page);
  await expect(composer(page)).toBeVisible();
}

async function contextCaretReady(page: Page) {
  // Picking context restores focus/caret on the next paint. Wait for that
  // transition before simulating the next burst of typing.
  await composer(page).evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())));
  await expect(composer(page)).toBeFocused();
  await expect.poll(() => composer(page).evaluate((el: HTMLTextAreaElement) => el.selectionStart === el.value.length)).toBe(true);
}

async function send(page: Page, text: string) {
  await composer(page).fill(text);
  await composer(page).press("Enter");
}

test("create, send, switch model, reload keeps history", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  // First visit: the welcome leads with who you're talking to (no personas yet: the built-in Assistant).
  await expect(page.getByRole("heading", { level: 1, name: "Assistant" })).toBeVisible();
  await expect(page.getByRole("list", { name: "Suggestions" }).getByRole("button")).toHaveCount(3);
  await expect(page.getByRole("combobox", { name: "Message" })).toBeVisible();

  await newChat(page);
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+/);
  await expect(page.getByText("A new conversation")).toBeVisible();
  await expect(composer(page)).toBeFocused();

  // Enter sends, Shift+Enter adds a line.
  await composer(page).fill("hello");
  await composer(page).press("Shift+Enter");
  await composer(page).pressSequentially("world");
  await expect(composer(page)).toHaveValue("hello\nworld");
  await composer(page).press("Enter");
  // While the reply runs, Send queues a follow-up by default.
  await expect(page.getByRole("button", { name: "Queue", exact: true })).toBeVisible();
  await expect(page.getByTestId("chat-status")).toHaveText(/ is thinking…$/);
  await expect(page.locator('[data-scene="thinking"]')).toBeAttached();
  const first = page.getByTestId("assistant-message").first();
  await expect(first).toContainText("Echo: hello");
  // The chat reads as a plain conversation: the model tag lives in the Activity tab.
  await expect(first.getByTestId("model-tag")).toHaveCount(0);
  await expect(composer(page)).toBeEnabled();
  await expect(composer(page)).toBeFocused();

  // Switch model: another harness asks first, then a pending indicator shows until the message is sent.
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-codex/ }).click();
  await page.getByRole("dialog", { name: "Switch to Codex · gpt-5-codex?" }).getByRole("button", { name: "Switch harness" }).click();
  await expect(page.getByTestId("pending-switch")).toContainText("Next message will use Codex · gpt-5-codex");
  await send(page, "second");
  await expect(page.getByTestId("assistant-message").nth(1)).toContainText("Echo: second");
  await expect(page.getByTestId("system-message")).toHaveText("Switched to Codex · gpt-5-codex");
  await expect(page.getByTestId("pending-switch")).toHaveCount(0);
  // Each turn's model shows in the Activity tab, which opens in the dock beside the conversation.
  await page.getByRole("button", { name: "Open Activity" }).click();
  await expect(page.getByTestId("activity-turn").nth(0).getByTestId("model-tag")).toHaveText("Claude Code · Opus 5.5");
  await expect(page.getByTestId("activity-turn").nth(1).getByTestId("model-tag")).toHaveText("Codex · gpt-5-codex");
  // The conversation stays beside it: there's no Chat/Activity switch on desktop.
  await expect(page.getByRole("tablist", { name: "Chat view" })).toHaveCount(0);
  await expect(page.getByTestId("assistant-message").nth(1)).toBeVisible();

  // History survives a reload.
  await page.reload();
  await expect(page.getByTestId("user-message")).toHaveCount(2);
  await expect(page.getByTestId("assistant-message").nth(1)).toContainText("Echo: second");

  // Revisiting the assistant resumes the newest conversation instead of the Welcome.
  const chatId = mock.posted[0].chat;
  await page.goto("/chat?project=WEB");
  await expect(page).toHaveURL(new RegExp(`/chat/${chatId}`));
  await expect(page.getByTestId("user-message")).toHaveCount(2);
  await expect(page.getByRole("heading", { name: /what can I help with/ })).toHaveCount(0);
  expect(mock.unhandled).toEqual([]);
});

test("effort is picked per message, kept on the chat, and limited to what the model offers", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await expect(effort(page)).toHaveAttribute("aria-label", /, Automatic effort$/);
  await expect(effort(page)).toHaveText("Opus 5.5 · Auto");
  await send(page, "hello");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: hello");
  expect(mock.posted.at(-1)?.body).not.toHaveProperty("effort");

  await effort(page).click();
  await expect(effortItems(page)).toHaveText(["Automatic", "Low", "Medium", "High", "Extra high", "Max"]);
  await page.getByRole("menuitem", { name: "Max" }).click();
  await expect(page.getByTestId("pending-effort")).toHaveText("Next message will use max effort");
  await send(page, "think hard");
  await expect(page.getByTestId("assistant-message").nth(1)).toContainText("Echo: think hard");
  expect(mock.posted.at(-1)?.body).toMatchObject({ effort: "max" });
  await expect(page.getByTestId("pending-effort")).toHaveCount(0);
  await expect(effort(page)).toHaveAttribute("aria-label", /, Max effort$/);
  await expect(effort(page)).toHaveText("Opus 5.5 · Max");

  // Unchanged effort isn't resent.
  await send(page, "again");
  await expect(page.getByTestId("assistant-message").nth(2)).toContainText("Echo: again");
  expect(mock.posted.at(-1)?.body).not.toHaveProperty("effort");

  // Codex here offers low–high, so max falls back to Automatic.
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-codex/ }).click();
  await page.getByRole("dialog", { name: "Switch to Codex · gpt-5-codex?" }).getByRole("button", { name: "Switch harness" }).click();
  await expect(effort(page)).toHaveAttribute("aria-label", /, Automatic effort$/);
  await effort(page).click();
  await expect(effortItems(page)).toHaveText(["Automatic", "Low", "Medium", "High"]);
  await page.keyboard.press("Escape");
  await send(page, "on codex");
  await expect(page.getByTestId("assistant-message").nth(3)).toContainText("Echo: on codex");
  expect(mock.posted.at(-1)?.body).toMatchObject({ harness: "codex", effort: "default" });

  // A model with no effort control shows only the model, and the menu has no effort section.
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-mini/ }).click();
  await expect(picker(page)).toHaveText("gpt-5-mini");
  await picker(page).click();
  await expect(page.getByRole("group", { name: "Reasoning effort" })).toHaveCount(0);
  await page.keyboard.press("Escape");
  expect(mock.unhandled).toEqual([]);
});

test("Send stays at the composer's bottom right, level with the model, at every width", async ({ page }) => {
  // A persona adds its switcher to a new chat's options, which is what pushes them past one line.
  await installChatApi(page, { personas: [persona(1, { name: "VesperBot", tone: "direct", color: "#4fd1c5", is_default: true })] });
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await composer(page).fill("hello");
  // Whether Send lands alone on a line depends on how much room the last line has left, so sweep widths.
  for (let width = 760; width <= 1400; width += 20) {
    await page.setViewportSize({ width, height: 800 });
    // Around 780px the composer swaps between its compact and desktop rows: measure the row that settled.
    await expect(page.getByRole("button", { name: "Send" })).toBeVisible();
    await expect(effort(page)).toBeVisible();
    const form = await composer(page).locator("xpath=ancestor::form").boundingBox();
    const sendBox = await page.getByRole("button", { name: "Send" }).boundingBox();
    const last = await effort(page).boundingBox();
    expect(form && sendBox && last, `boxes at ${width}px`).toBeTruthy();
    // Right-aligned, and level with the last row of options rather than on a line of its own below them.
    expect(form!.x + form!.width - (sendBox!.x + sendBox!.width), `right edge at ${width}px`).toBeLessThan(24);
    expect(sendBox!.y, `row at ${width}px`).toBeLessThan(last!.y + last!.height);
  }
});

test("stop ends a running reply", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "slow: take your time");
  await expect(composer(page)).toBeEnabled();
  await page.getByRole("button", { name: "Stop" }).click();
  await expect(composer(page)).toBeEnabled();
  await expect(page.getByRole("button", { name: "Send" })).toBeVisible();
  await expect(page.getByTestId("system-message")).toHaveText("Turn cancelled");
});

test("a message sent in Interrupt mode while a reply runs interrupts it, and the next reply answers both", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "slow: summarize the plan");
  await expect(page.getByTestId("chat-status")).toBeVisible();
  // The composer stays open; the model and effort wait for the reply to end.
  await expect(composer(page)).toBeEnabled();
  await expect(composer(page)).toHaveAttribute("placeholder", /^Queue a follow-up for when .+ finishes…$/);
  await expect(picker(page)).toBeDisabled();
  // Follow-up is the default; interrupting is picked explicitly.
  await page.getByRole("radiogroup", { name: "Send as" }).getByRole("radio", { name: "Interrupt" }).click();
  await expect(composer(page)).toHaveAttribute("placeholder", /^Stop .+ and steer it…$/);
  await composer(page).fill("focus on the risks");
  await page.getByRole("button", { name: "Interrupt" }).click();
  await expect(page.getByTestId("assistant-message").last()).toContainText("Echo: focus on the risks (interrupting: slow: summarize the plan)");
  await expect(page.getByRole("button", { name: "Send" })).toBeVisible();
  expect(mock.posted.map((p) => p.body.body)).toEqual(["slow: summarize the plan", "focus on the risks"]);
  expect(mock.unhandled).toEqual([]);
});

test("unavailable models are disabled with their reason", async ({ page }) => {
  await installChatApi(page, { codexAvailable: false });
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await picker(page).click();
  const item = page.getByRole("menuitem", { name: /Codex gpt-5-codex/ });
  await expect(item).toHaveAttribute("aria-disabled", "true");
  await expect(item).toContainText("No harness:openai secret");
});

test("a long model menu stays on screen and scrolls to its first harness", async ({ page }) => {
  // The Welcome's composer sits low: a menu opening upward has less room
  // than a share of the viewport, and its top (Claude) used to go off screen.
  await page.setViewportSize({ width: 1280, height: 720 });
  await installChatApi(page);
  const efforts = ["low", "medium", "high", "xhigh", "max"] as const;
  const models = (names: string[]) => names.map((n, i) => ({ id: n.toLowerCase().replace(/ /g, "-"), label: n, default: i === 0, efforts: [...efforts] }));
  await page.route("**/api/v1/chat-models", (route) => route.fulfill({ json: [
    { harness: "claude-code", label: "Claude Code", available: true, models: models(["Default (recommended)", "Opus 5.5", "Fable 5.2", "Sonnet 5.5", "Haiku 5.5"]) },
    { harness: "codex", label: "Codex", available: true, models: models(["GPT-6.1-Sol", "GPT-6-Astra", "GPT-6.1 Terra", "GPT-6-Sol", "GPT-6-Luna", "GPT-5.6-Sol", "GPT-5.6-Terra", "GPT-5.6-Luna", "GPT-5.5"]) },
  ] }));
  await page.goto("/chat?new");
  await picker(page).click();
  const menu = page.getByRole("menu");
  const box = (await menu.boundingBox())!;
  expect(box.y).toBeGreaterThanOrEqual(0);
  expect(box.y + box.height).toBeLessThanOrEqual(720);
  expect(box.height).toBeLessThanOrEqual(400);
  // Effort sits beside the models, all of it in view without scrolling past them.
  const effortGroup = page.getByRole("group", { name: "Reasoning effort" });
  const effortBox = (await effortGroup.boundingBox())!;
  expect(effortBox.x).toBeGreaterThan(box.x + 100);
  await expect(effortGroup.getByRole("menuitem").last()).toBeInViewport({ ratio: 1 });
  // The rest of the models are reached by scrolling their column, not the page.
  const opus = page.getByRole("menuitem", { name: "Claude Code Opus 5.5" });
  expect(await opus.evaluate((el) => { const col = el.closest("[role=menu] > div")!; return col.scrollHeight > col.clientHeight; })).toBe(true);
  const fable = page.getByRole("menuitem", { name: "Claude Code Fable 5.2" });
  await fable.scrollIntoViewIfNeeded();
  await expect(fable).toBeInViewport({ ratio: 1 });
  await fable.click();
  await expect(picker(page)).toHaveAccessibleName(/Claude Code, Fable 5\.2/);
});

test("[[ picks context as removable chips and sends them as context_refs", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);

  // Typing [[ offers pages, artifacts and tickets; picking adds a chip, not text.
  await composer(page).fill("see [[Pla");
  const list = page.getByRole("listbox", { name: "Link to" });
  await expect(list.getByRole("option")).toHaveCount(1);
  await list.getByRole("option", { name: /Eng\/Plan/ }).click();
  await expect(chips(page)).toHaveCount(1);
  await expect(chips(page).first()).toContainText("Eng/Plan");
  await expect(composer(page)).toHaveValue("see ");

  // Picking restores the caret on the next frame; don't type into that restoration.
  await page.evaluate(() => new Promise<void>((resolve) => requestAnimationFrame(() => resolve())));

  // Enter on the highlighted suggestion picks it with the keyboard.
  await contextCaretReady(page);
  await composer(page).pressSequentially("[[WEB-");
  await expect(page.getByRole("option", { name: /WEB-3/ })).toBeVisible();
  await composer(page).press("Enter");
  await expect(chips(page)).toHaveCount(2);

  // "Add context" opens the same picker.
  await (await composerOption(page, "context")).getByRole("button", { name: "Add context" }).click();
  await page.getByRole("combobox", { name: "Search pages, artifacts and tickets" }).fill("Q3");
  await page.getByRole("option", { name: /Q3 report/ }).click();
  await expect(chips(page)).toHaveCount(3);

  // Picking the same thing twice doesn't duplicate; chips can be removed.
  await contextCaretReady(page);
  await composer(page).pressSequentially("[[WEB-");
  await expect(page.getByRole("option", { name: /WEB-3/ })).toBeVisible();
  await composer(page).press("Enter");
  await expect(composer(page)).toHaveValue("see ");
  await expect(chips(page)).toHaveCount(3);
  await page.getByRole("button", { name: "Remove Q3 report" }).click();
  await expect(chips(page)).toHaveCount(2);

  await composer(page).press("Enter");
  await expect(page.getByTestId("assistant-message").first()).toContainText("Echo: see");
  expect(mock.posted.at(-1)?.body.context_refs).toEqual([
    { kind: "page", id: "11111111-1111-4111-8111-111111111111" },
    { kind: "ticket", key: "WEB-3" },
  ]);
  // Sent messages show read-only chips; the composer's chips are cleared.
  await expect(chips(page)).toHaveCount(0);
  await expect(page.getByTestId("user-message").getByTestId("sent-chip")).toHaveText(["Eng/Plan", "WEB-3"]);

  // Without attachments no context_refs are sent.
  await send(page, "plain");
  await expect(page.getByTestId("assistant-message").nth(1)).toContainText("Echo: plain");
  expect(mock.posted.at(-1)?.body).not.toHaveProperty("context_refs");
});

// Fires a paste carrying image files and, optionally, the text copied with them.
async function pasteImages(page: Page, types: string[], text = "") {
  await composer(page).evaluate((el, { types, text }) => {
    const data = new DataTransfer();
    for (const type of types) data.items.add(new File([new Uint8Array([1, 2, 3])], "image.png", { type }));
    if (text) data.setData("text/plain", text);
    el.dispatchEvent(new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true }));
  }, { types, text });
}

test("pasted images preview above the composer and go with the message", async ({ page }) => {
  const mock = await installChatApi(page);
  let uploaded = 0;
  await page.route("**/api/v1/chat-attachments", (route) => {
    uploaded++;
    return route.fulfill({ status: 201, json: { id: `att-${uploaded}`, filename: `pasted-image-${uploaded}.png`, content_type: "image/png", size_bytes: 3 } });
  });
  await page.goto("/chat?project=WEB");
  await newChat(page);

  await pasteImages(page, ["image/png", "image/jpeg"]);
  const previews = page.getByTestId("attachment-preview");
  await expect(previews).toHaveCount(2);
  await expect(page.getByTestId("attachment-chip").first()).toHaveAttribute("data-status", "done");
  await expect(page.getByTestId("attachment-chip").nth(1)).toHaveAttribute("data-status", "done");
  await page.getByRole("button", { name: "Remove pasted-image-2.jpg" }).click();
  await expect(previews).toHaveCount(1);

  // A picture of copied text, as spreadsheets add, stays a text paste.
  await pasteImages(page, ["image/png"], "A1\tB1");
  await expect(previews).toHaveCount(1);

  await send(page, "what is this?");
  await expect(page.getByTestId("assistant-message").first()).toContainText("Echo: what is this?");
  expect(mock.posted.at(-1)?.body.attachment_ids).toHaveLength(1);
  await expect(previews).toHaveCount(0);

  // The sent image shows in the message, and a click opens it with a Download link.
  const sent = page.getByTestId("message-attachments").getByTestId("image-attachment");
  await expect(sent).toHaveCount(1);
  await expect(sent.locator("img")).toHaveAttribute("src", "/api/v1/chat-attachments/att-1/content");
  await sent.click();
  const dialog = page.getByRole("dialog", { name: "att-1.png" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("link", { name: "Download" })).toHaveAttribute("download", "att-1.png");
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();
});

test("a rejected attachment shows the server error and keeps the chips", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await page.goto(page.url() + "?attach=ticket:OTHER-9&attach_title=Elsewhere");
  await expect(chips(page)).toHaveCount(1);
  await send(page, "hi");
  await expect(page.getByRole("alert").filter({ hasText: "OTHER-9" })).toContainText("was not found");
  await expect(chips(page)).toHaveCount(1);
  await expect(composer(page)).toHaveValue("hi");
});

test("Start chat links pre-attach the item and drop the query param", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  // Opened on a conversation, the item is attached to it and ?attach= leaves the URL.
  await page.goto(page.url() + "?attach=page:11111111-1111-4111-8111-111111111111&attach_title=Plan");
  await expect(chips(page)).toHaveCount(1);
  await expect(chips(page).first()).toContainText("Plan");
  await expect(page).not.toHaveURL(/attach/);
  await send(page, "summarise");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: summarise");
  expect(mock.posted.at(-1)?.body.context_refs).toEqual([{ kind: "page", id: "11111111-1111-4111-8111-111111111111" }]);
});

test("a ticket the chat carried opens beside it from the Linked row and from its sent chip", async ({ page }) => {
  await installChatApi(page);
  await page.route("**/api/v1/tickets/WEB-3", (route) => route.fulfill({ json: {
    id: "t3", key: "WEB-3", title: "Session refresh", description_md: "Refresh **before** expiry.", status: "in_progress", priority: "high",
    criteria: [{ id: "c1", position: 0, text: "Tokens refresh early", done: true }, { id: "c2", position: 1, text: "Expired sessions sign out", done: false }],
    labels: [], artifacts: [], approvals: [], blocked_by: [], blocks: [], revision: 1, dependency_revision: 1, project: { key: "WEB", name: "Web app" },
  } }));
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await page.goto(page.url() + "?attach=ticket:WEB-3&attach_title=Session%20refresh");
  await send(page, "where does this stand?");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo:");

  const row = page.getByRole("navigation", { name: "Linked items" });
  await row.getByRole("button", { name: "WEB-3" }).click();
  await expect(page).toHaveURL(/[?&]item=ticket%3AWEB-3/);
  const item = page.getByTestId("linked-item");
  await expect(item.getByRole("heading", { name: "WEB-3 · Session refresh" })).toBeVisible();
  await expect(item.getByRole("region", { name: "Acceptance criteria" })).toContainText("1/2");
  await expect(item.getByRole("link", { name: /Open ticket/ })).toHaveAttribute("href", "/tickets/WEB-3");
  // The conversation stays where it was, beside it.
  await expect(page.getByTestId("user-message").last()).toContainText("where does this stand?");
  await item.getByRole("button", { name: "Close WEB-3 · Session refresh" }).click();
  await expect(page.getByTestId("linked-item")).toHaveCount(0);
  await expect(page).not.toHaveURL(/item=/);

  await page.getByTestId("sent-chip").getByRole("button").click();
  await expect(page.getByTestId("linked-item").getByRole("heading", { name: "WEB-3 · Session refresh" })).toBeVisible();
});

test("sending from the Welcome creates the chat, posts the message and opens it", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await expect(page.getByRole("heading", { level: 1, name: "Assistant" })).toBeVisible();
  // A suggestion fills the composer; it is not sent.
  await page.getByRole("list", { name: "Suggestions" }).getByRole("button", { name: "Draft tickets from a spec" }).click();
  await expect(page.getByRole("combobox", { name: "Message" })).toHaveValue("Draft tickets from a spec");
  expect(mock.posted).toEqual([]);

  await page.getByRole("combobox", { name: "Message" }).fill("first words");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+$/);
  await expect(page.getByTestId("user-message")).toContainText("first words");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: first words");
  expect(mock.created).toEqual([{}]);
  expect(mock.posted).toHaveLength(1);
  expect(mock.posted[0].body).toEqual({ body: "first words", model: "auto" });
  expect(mock.unhandled).toEqual([]);
});

test("Temporary on the Welcome makes the chat temporary", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?new");
  await (await composerOption(page, "temporary")).getByRole("button", { name: "Temporary", exact: true }).click();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("composer-modes").getByRole("button", { name: "Temporary", exact: true })).toHaveAttribute("aria-pressed", "true");
  await page.getByRole("combobox", { name: "Message" }).fill("off the record");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+$/);
  expect(mock.created).toEqual([{ temporary: true }]);
  await expect(page.getByTestId("chat-title-status").getByRole("img", { name: /^Temporary chat/ })).toBeVisible();
  expect(mock.unhandled).toEqual([]);
});

test("the Welcome's box is a chat's: model and effort, / commands, @ mentions and context", async ({ page }) => {
  const mock = await installChatApi(page, { personas: [persona(1, { name: "Atlas", is_default: true }), persona(2, { name: "Nova" })] });
  await page.goto("/chat?new");
  const box = composer(page);
  // Before a pick a new chat routes its model automatically, from the agents' harness, at automatic effort.
  await expect(picker(page)).toHaveAccessibleName("Model and effort for the next message: Claude Code, automatic model, Automatic effort");
  await expect(picker(page)).toHaveText("Auto");
  await expect(await composerOption(page, "context")).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(page.getByTestId("composer-hints")).toContainText("/ commands");

  await box.pressSequentially("/");
  await expect(page.getByTestId("command-suggestions").getByRole("option")).toHaveCount(12);
  await box.fill("/model sonnet");
  await box.press("Enter");
  await expect(picker(page)).toHaveAccessibleName(/Sonnet 5\.5, Automatic effort/);
  await box.fill("/effort high");
  await box.press("Enter");
  await expect(picker(page)).toHaveAccessibleName(/Sonnet 5\.5, High effort/);
  await box.fill("/persona nova");
  await box.press("Enter");
  await expect(page.getByRole("heading", { level: 1, name: "Nova" })).toBeVisible();
  await box.fill("/stop");
  await box.press("Enter");
  await expect(page.getByTestId("command-error")).toHaveText("There’s no reply to stop.");

  await box.fill("");
  await box.pressSequentially("ask @at");
  await page.getByTestId("mention-suggestions").getByRole("option", { name: /Atlas/ }).click();
  await expect(box).toHaveValue("ask @Atlas ");
  await box.pressSequentially("too");
  await box.press("Enter");
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+$/);
  expect(mock.created).toEqual([{ persona_id: mock.personas[1].id }]);
  expect(mock.posted[0].body).toEqual({ body: "ask @Atlas too", harness: "claude-code", model: "sonnet-5.5", effort: "high" });
  expect(mock.unhandled).toEqual([]);
});

test("Start chat ?attach= on /chat shows chips in the Welcome and sends them with the first message", async ({ page }) => {
  const mock = await installChatApi(page);
  // An existing conversation doesn't hide the Welcome when context was brought along.
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "earlier");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: earlier");

  await page.goto("/chat?project=WEB&attach=page:11111111-1111-4111-8111-111111111111&attach_title=Plan");
  await expect(page.getByRole("heading", { level: 1, name: "Assistant" })).toBeVisible();
  await expect(chips(page)).toHaveCount(1);
  await expect(chips(page).first()).toContainText("Plan");
  await page.getByRole("combobox", { name: "Message" }).fill("summarise");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+$/);
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: summarise");
  expect(mock.posted.at(-1)?.body).toEqual({ body: "summarise", model: "auto", context_refs: [{ kind: "page", id: "11111111-1111-4111-8111-111111111111" }] });
  await expect(page.getByTestId("user-message").getByTestId("sent-chip")).toHaveCount(1);
  expect(mock.unhandled).toEqual([]);
});

test("assistant messages list deduplicated Sources with version and section", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "plain");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: plain");
  await expect(page.getByTestId("sources")).toHaveCount(0);

  await send(page, "cite: risks");
  const sources = page.getByTestId("assistant-message").nth(1).getByTestId("sources");
  await sources.getByRole("button", { name: /3 sources/ }).click();
  await expect(sources.getByTestId("source")).toHaveCount(3);
  const report = sources.getByRole("link", { name: /Q3 report/ });
  await expect(report).toContainText("v2");
  await expect(report).toContainText("risks");
  await expect(report).toHaveAttribute("href", "/artifacts/22222222-2222-4222-8222-222222222222?version=55555555-5555-4555-8555-555555555555#risks");
  await expect(sources.getByRole("link", { name: /Plan/ })).toHaveAttribute("href", "/wiki/Eng/Plan");
  await expect(sources.getByRole("link", { name: /WEB-3/ })).toHaveAttribute("href", "/tickets/WEB-3");
});

test("save a reply to the wiki with a link back to the chat", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "plain");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: plain");

  await page.getByTestId("assistant-message").last().getByRole("button", { name: "More message actions" }).click();
  await page.getByRole("menuitem", { name: "Save to wiki" }).click();
  const path = page.getByRole("textbox", { name: "Page path" });
  await expect(path).toHaveValue("Chats/plain");
  await path.fill("Notes/From chat");
  await page.getByRole("button", { name: "Save page" }).click();
  await expect(page.getByRole("link", { name: "Open Notes/From chat" })).toHaveAttribute("href", "/wiki/Notes/From%20chat");
  const chatId = mock.posted[0].chat;
  expect(mock.wikiPages).toHaveLength(1);
  expect(mock.wikiPages[0].project_key).toBeUndefined();
  expect(mock.wikiPages[0].body_md).toContain("Echo: plain");
  expect(mock.wikiPages[0].body_md).toContain(`(/chat/${chatId})`);
  await page.getByRole("button", { name: "Done" }).click();

  // A taken path shows the server's error and keeps the dialog open.
  await page.getByTestId("assistant-message").last().getByRole("button", { name: "More message actions" }).click();
  await page.getByRole("menuitem", { name: "Save to wiki" }).click();
  await page.getByRole("textbox", { name: "Page path" }).fill("Notes/From chat");
  await page.getByRole("button", { name: "Save page" }).click();
  await expect(page.getByRole("alert").filter({ hasText: "already exists" })).toBeVisible();
});

test("save a reply as a report artifact with a link back to the chat", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "plain");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: plain");
  await page.getByTestId("assistant-message").last().getByRole("button", { name: "More message actions" }).click();
  await page.getByRole("menuitem", { name: "Save as artifact" }).click();
  await page.getByRole("textbox", { name: "Title" }).fill("Plain answer");
  await page.getByRole("button", { name: "Save report" }).click();
  await expect(page.getByRole("link", { name: "Open Plain answer" })).toHaveAttribute("href", "/artifacts/66666666-6666-4666-8666-666666666666");
  const form = mock.artifactForms[0];
  expect(form).toContain("report");
  expect(form).toContain("Echo: plain");
  expect(form).toContain(`(/chat/${mock.posted[0].chat})`);
});

test("a model on another harness is chosen with the keyboard, posted, and survives reload", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await picker(page).focus();
  await page.keyboard.press("Enter");
  await expect(page.getByRole("menu")).toBeVisible();
  const target = page.getByRole("menuitem", { name: /Codex gpt-5-codex/ });
  // Walk down the menu until the target item has focus.
  for (let i = 0; i < 8 && !(await target.evaluate((el) => el === document.activeElement)); i++) {
    await page.keyboard.press("ArrowDown");
    await page.waitForTimeout(50);
  }
  await expect(target).toBeFocused();
  await page.keyboard.press("Enter");
  await expect(picker(page)).toHaveAttribute("aria-label", /Codex, gpt-5-codex/);
  await send(page, "hello codex");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: hello codex");
  expect(mock.posted.at(-1)?.body).toMatchObject({ harness: "codex", model: "gpt-5-codex" });
  await expect(page.getByTestId("model-tag")).toHaveText("Codex · gpt-5-codex");

  await page.reload();
  await expect(picker(page)).toHaveAttribute("aria-label", /Codex, gpt-5-codex/);
  await expect(page.getByTestId("model-tag")).toHaveText("Codex · gpt-5-codex");
  expect(mock.unhandled).toEqual([]);
});

test("an unavailable harness shows its reason and can't be selected", async ({ page }) => {
  await installChatApi(page, { codexAvailable: false });
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await picker(page).click();
  const item = page.getByRole("menuitem", { name: /Codex gpt-5-codex/ });
  await expect(item).toHaveAttribute("aria-disabled", "true");
  await expect(item).toContainText("No harness:openai secret");
  await item.click({ force: true });
  await page.keyboard.press("Escape");
  await expect(picker(page)).toHaveAttribute("aria-label", /Claude Code/);
});

for (const codexAvailable of [true, false]) {
  test(`new chat refreshes pending Claude discovery (${codexAvailable ? "Codex available" : "both pending"})`, async ({ page }) => {
    await installChatApi(page);
    let ready = false;
    let requests = 0;
    await page.route("**/api/v1/chat-models", (route) => {
      requests++;
      return route.fulfill({ json: catalog(true).map((g) =>
        !ready && (g.harness === "claude-code" || !codexAvailable)
          ? { ...g, available: false, checking: true, models: [], unavailable_reason: "Still checking models." }
          : g,
      ) });
    });
    await page.goto("/chat?new");
    await expect(page.getByRole("heading", { name: "Assistant", exact: true })).toBeVisible();
    if (codexAvailable) {
      await picker(page).click();
      await expect(page.getByRole("menu")).toContainText("Checking available models…");
      await expect(page.getByRole("menuitem", { name: /Codex gpt-5-codex/ })).toBeVisible();
      await expect(page.getByRole("menuitem", { name: /Claude Code Opus/ })).toHaveCount(0);
    } else {
      await expect(page.getByRole("status").filter({ hasText: "Checking available models… This updates automatically." })).toBeVisible();
      await expect(page.getByRole("status", { name: /Agents can’t run/ })).toHaveCount(0);
      await expect(composer(page)).toBeDisabled();
      await expect(page.getByRole("button", { name: "Send", exact: true })).toBeDisabled();
    }
    ready = true;
    // Discovery completes without navigation, focus changes, or a reload.
    if (!codexAvailable) {
      await expect(picker(page)).toBeEnabled({ timeout: 7_000 });
      await picker(page).click();
    }
    await expect(page.getByRole("menuitem", { name: /Claude Code Opus 5.5/ })).toBeVisible({ timeout: 7_000 });
    await expect(page.getByRole("menu")).not.toContainText("Checking available models…");
    await page.keyboard.press("Escape");
    await expect(picker(page)).toHaveAttribute("title", /Claude Code · Auto \(now Opus 5.5\)/);
    // Once resolved, stop polling instead of rediscovering forever.
    const resolvedRequests = requests;
    await page.waitForTimeout(2_500);
    expect(requests).toBe(resolvedRequests);
  });
}

test("pending discovery stops polling and shows the reason if the runner fails", async ({ page }) => {
  await installChatApi(page);
  let failed = false;
  let requests = 0;
  await page.route("**/api/v1/chat-models", (route) => {
    requests++;
    return route.fulfill({ json: catalog(true).map((g) => g.harness === "claude-code"
      ? { ...g, available: false, checking: !failed, models: [], unavailable_reason: failed ? "Sign in again in Settings." : "Still checking models." }
      : g,
    ) });
  });
  await page.goto("/chat?new");
  await picker(page).click();
  await expect(page.getByRole("menu")).toContainText("Checking available models…");
  failed = true;
  await expect(page.getByRole("menu")).toContainText("Sign in again in Settings.", { timeout: 7_000 });
  await expect(page.getByRole("menu")).not.toContainText("Checking available models…");
  const resolvedRequests = requests;
  await page.waitForTimeout(2_500);
  expect(requests).toBe(resolvedRequests);
});

test("with no harness available, chat says why before anything is sent", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  // The Anthropic key is removed: every harness becomes unavailable.
  await page.route("**/api/v1/chat-models", (route) =>
    route.fulfill({ json: catalog(false).map((g) => ({ ...g, available: false, unavailable_reason: g.unavailable_reason ?? "no harness:anthropic secret" })) }),
  );
  await page.reload();
  const guard = page.getByRole("status").filter({ hasText: "Claude Code is unavailable" });
  await expect(guard).toContainText("no harness:anthropic secret. Pick another model or add the key.");
  await expect(guard.getByRole("link", { name: "Add the key →" })).toHaveAttribute("href", "/settings#secrets");
  await composer(page).fill("hello");
  await expect(page.getByRole("button", { name: "Send" })).toBeDisabled();
  await composer(page).press("Enter");
  expect(mock.posted).toEqual([]);
  // New conversation is refused up front, naming the missing secrets.
  await expect(page.getByRole("button", { name: "New chat", exact: true }).first()).toBeDisabled();
  await expect(page.locator('p[role="status"]').filter({ hasText: "No harness is available: add harness:anthropic or harness:openai." })).toBeVisible();
  // The shell banner names the same secrets on every screen.
  await expect(page.getByRole("status", { name: /Agents can’t run/ })).toBeVisible();
});

test("a rejected post shows the error and keeps the selection", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await page.route("**/api/v1/chats/*/messages", (route) =>
    route.request().method() === "POST"
      ? route.fulfill({ status: 422, json: { code: "invalid", message: "Unknown or unavailable harness/model", field: "model" } })
      : route.fallback(),
  );
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-codex/ }).click();
  await send(page, "will fail");
  await expect(page.getByRole("alert").filter({ hasText: "Unknown or unavailable" })).toBeVisible();
  await expect(picker(page)).toHaveAttribute("aria-label", /Codex, gpt-5-codex/);
  await expect(composer(page)).toHaveValue("will fail");
  expect(mock.posted).toEqual([]);
});

test("a new chat has no agent picker and names no agent", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await expect(page.getByRole("button", { name: /Agent for new chats/ })).toHaveCount(0);
  await newChat(page);
  expect(mock.created.at(-1)).toEqual({});
  await expect(page.getByTestId("chat-agent")).toHaveCount(0);
  // The conversation header is the page's only header: no "Assistant" breadcrumb bar above it.
  await expect(page.getByRole("navigation", { name: "Breadcrumb" })).toHaveCount(0);
  await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
  expect(mock.unhandled).toEqual([]);
});

// Next keeps the page we navigated from mounted but hidden, so scope to what is on screen.
const history = (page: Page) => page.locator('aside[aria-label="Chat history"]:visible');
const historyNav = (page: Page) => history(page).getByRole("navigation", { name: "Chats" });

test("rename and archive from the history list", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  // A conversation nobody has named yet reads as New conversation.
  await expect(historyNav(page).getByRole("link", { name: "New conversation" })).toBeVisible();
  await page.getByRole("button", { name: "Rename New conversation" }).click();
  const title = page.getByRole("textbox", { name: "Conversation title" });
  await expect(title).toHaveValue("");
  await expect(title).toHaveAttribute("placeholder", "New conversation");
  await title.fill("Roadmap");
  await title.press("Enter");
  await expect(historyNav(page).getByRole("link", { name: "Roadmap" })).toBeVisible();
  await page.getByRole("button", { name: "Archive Roadmap" }).click();
  await expect(page).toHaveURL(/\/chat$/);
  await expect(historyNav(page).getByText("No conversations yet.")).toBeVisible();
});

test("delete asks first, Cancel keeps the conversation, and deleting the open one leaves it", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "delete me");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: delete me");
  const nav = historyNav(page);
  await nav.getByRole("button", { name: "Delete delete me" }).click();
  const confirm = nav.getByRole("group", { name: "Confirm delete delete me" });
  await expect(confirm).toContainText("This can’t be undone.");
  await confirm.getByRole("button", { name: "Cancel" }).click();
  await expect(nav.getByRole("link", { name: "delete me" })).toBeVisible();

  await nav.getByRole("button", { name: "Delete delete me" }).click();
  await nav.getByRole("group", { name: "Confirm delete delete me" }).getByRole("button", { name: "Delete", exact: true }).click();
  await expect(page).toHaveURL(/\/chat$/);
  await expect(nav.getByText("No conversations yet.")).toBeVisible();
});

test("archived conversations are listed under Archived and can be restored", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "keep me");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: keep me");
  const nav = historyNav(page);
  await expect(nav.getByRole("link", { name: "keep me" })).toBeVisible();
  await page.getByRole("button", { name: "Archive keep me" }).click();
  await expect(page).toHaveURL(/\/chat$/);
  await expect(nav.getByText("No conversations yet.")).toBeVisible();

  await history(page).getByRole("button", { name: "Archived conversations" }).click();
  await expect(nav.getByRole("link", { name: "keep me" })).toBeVisible();
  await expect(nav.getByText("Archived conversations are read-only")).toBeVisible();
  await expect(nav.getByRole("button", { name: "Archive keep me" })).toHaveCount(0);

  // Opened, an archived conversation is read-only with Restore in the header and in place of the composer.
  await nav.getByRole("link", { name: "keep me" }).click();
  const chat = page.getByRole("region", { name: "keep me" });
  await expect(chat.getByText("This chat is archived. Restore it to continue.")).toBeVisible();
  await expect(composer(page)).toHaveCount(0);
  await expect(chat.getByRole("button", { name: "Restore keep me" })).toHaveCount(2);
  await chat.getByRole("button", { name: "Restore keep me" }).last().click();
  await expect(composer(page)).toBeVisible();
  // The restored conversation is listed under Active again, next to the open one.
  await expect(history(page).getByRole("button", { name: "Archived conversations" })).toHaveAttribute("aria-pressed", "false");
  await expect(page).not.toHaveURL(/view=archived/);
  await expect(nav.getByRole("link", { name: "keep me" })).toBeVisible();
  await history(page).getByRole("button", { name: "Archived conversations" }).click();
  await expect(nav.getByText("No archived conversations.")).toBeVisible();
  await history(page).getByRole("button", { name: "Archived conversations" }).click();
  await expect(nav.getByRole("link", { name: "keep me" })).toBeVisible();

  // Restore straight from the list too. Archiving the open chat navigates back to the index first.
  await page.getByRole("button", { name: "Archive keep me" }).click();
  await expect(nav.getByText("No conversations yet.")).toBeVisible();
  await history(page).getByRole("button", { name: "Archived conversations" }).click();
  await expect(page).toHaveURL(/view=archived/);
  await nav.getByRole("button", { name: "Restore keep me" }).click();
  await expect(nav.getByText("No archived conversations.")).toBeVisible();
});

test("an archived chat opened by URL is read-only and Restore brings back the composer", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "keep me");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: keep me");
  const chatId = mock.posted[0].chat;
  // The UI has no archive control; archive through the API like another client would.
  await page.evaluate(async (id) => {
    const chat = await (await fetch(`/api/v1/chats/${id}`)).json();
    await fetch(`/api/v1/chats/${id}`, {
      method: "PATCH",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ revision: chat.revision, archived: true }),
    });
  }, chatId);

  await page.goto(`/chat/${chatId}?project=WEB`);
  const chat = page.getByRole("region", { name: "keep me" });
  await expect(chat.getByText("This chat is archived. Restore it to continue.")).toBeVisible();
  await expect(composer(page)).toHaveCount(0);
  await expect(chat.getByRole("button", { name: "Restore keep me" })).toHaveCount(2);
  await chat.getByRole("button", { name: "Restore keep me" }).last().click();
  await expect(composer(page)).toBeVisible();
  await expect(chat.getByRole("button", { name: "Restore keep me" })).toHaveCount(0);
  expect(mock.unhandled).toEqual([]);
});

test("a running turn shows its newest tool call as a live line with a linked page", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "slow: dig in");
  const live = page.getByTestId("live-activity");
  // The chat says what the persona is doing at a high level, never the exact call;
  // tool calls and their inputs show in the Activity tab.
  await expect(page.getByTestId("chat-status")).toHaveText(/ is looking through the wiki…$/);
  await expect(page.locator('[data-scene="wiki"]')).toBeAttached();
  await expect(page.getByTestId("chat-status")).not.toContainText("Plan");
  // Only the rail's active step names what it's on, by its safe label.
  await expect(page.getByTestId("chat-step-detail")).toHaveText("Reading Plan");
  await expect(live).toBeHidden();
  await page.getByRole("button", { name: "Open Activity" }).click();
  await expect(live).toHaveText("Reading Plan…");
  await expect(live.getByRole("link", { name: /Plan/ })).toHaveAttribute("href", "/wiki/Eng/Plan");
  await expect(page.getByText("Tool calls (1)")).toBeVisible();
  await page.getByRole("button", { name: "Stop" }).click();
  await expect(live).toHaveCount(0);
});

test("a narrated decision shows on its step, tagged, and links to the thinking in Activity", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "narrated: fix the flaky test");
  // The opening line stays the interim reply, not an intent line.
  await expect(page.getByTestId("interim-reply")).toHaveText(/On it\./);
  const intent = page.getByTestId("chat-step-intent");
  await expect(intent).toHaveText("It fails on main too, so it's the test.");
  await expect(page.getByTestId("chat-steps").getByTestId("intent-tag")).toHaveText("surprise");
  await expect(page.getByTestId("trace-thinking")).toBeHidden();
  await page.getByTestId("view-reasoning").click();
  await expect(page.getByRole("complementary", { name: "Panel" }).getByRole("tabpanel", { name: "Activity" })).toBeVisible();
  await expect(page.getByTestId("trace-thinking")).toHaveText("It fails on main as well, so the test races the backoff.");
  await expect(page.getByTestId("trace-intent")).toHaveText("It fails on main too, so it's the test.");
  await page.getByRole("button", { name: "Stop" }).click();
});

test("a running turn lists its plan in a rail that collapses to a strip", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "steps: work through it");
  const rail = page.getByTestId("chat-steps");
  await expect(rail.locator("li")).toHaveText(["Read the code", /^Fix the snapshot\s*added$/, "Run tests"]);
  await expect(rail.locator('[data-step-state="active"]')).toContainText("Fix the snapshot");
  await expect(page.getByTestId("chat-status-card")).toContainText("Step 2 of 3");
  // The main chat has room: the rail starts open.
  await expect(page.getByTestId("chat-status-card")).not.toHaveAttribute("data-folded");
  await page.getByRole("button", { name: "Hide steps" }).click();
  await expect(rail).toHaveCount(0);
  await page.getByRole("button", { name: "Show steps" }).click();
  await expect(rail).toBeVisible();
  await page.getByRole("button", { name: "Stop" }).click();
  await expect(page.getByTestId("chat-status-card")).toHaveCount(0);
});

test("the rail shows an interactive app being written", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "building-app: show me");
  await expect(page.getByTestId("chat-status")).toHaveText(/ is building an interactive app…$/);
  await expect(page.getByTestId("chat-steps").locator('[data-step-state="active"]')).toContainText("Building an interactive app");
  await page.getByRole("button", { name: "Stop" }).click();
});

test("once the newest call has finished, the card works out the next step instead of repeating it", async ({ page }) => {
  await page.clock.install();
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "between: carry on");
  const status = page.getByTestId("chat-status");
  await expect(status).toHaveText(/ is writing code…$/);
  await expect(page.getByTestId("chat-pulse")).not.toContainText(/last activity/);
  await page.clock.fastForward("00:06");
  await expect(status).toHaveText(/ is working out the next step…$/);
  await expect(page.locator('[data-scene="next-step"]')).toBeAttached();
  const rail = page.getByTestId("chat-steps");
  await expect(rail.locator('[data-step-state="done"]')).toContainText("Editing runner.go");
  await expect(rail.locator('[data-step-state="active"]')).toContainText("Working out the next step");
  await expect(rail.locator('[data-step-state="active"]').getByTestId("step-timer")).toHaveText(/^\d+s$/);
  await page.clock.fastForward("00:05");
  await expect(page.getByTestId("chat-pulse")).toContainText(/last activity \d+s ago/);
  await page.getByRole("button", { name: "Stop" }).click();
});

test("a long silence says so and offers to ask what it's doing, once", async ({ page }) => {
  await page.clock.install();
  const mock = await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "between: carry on");
  const card = page.getByTestId("chat-status-card");
  await expect(page.getByTestId("chat-status")).toHaveText(/ is writing code…$/);
  await expect(card.getByRole("button", { name: "Ask what it's doing" })).toHaveCount(0);
  await page.clock.fastForward("02:05");
  await expect(page.getByTestId("chat-status")).toHaveText(/ has been quiet for 2 minutes$/);
  await expect(page.getByTestId("chat-pulse")).toHaveText(/^Still running · last: writing code · 2m 0\ds in all$/);
  await card.getByRole("button", { name: "Ask what it's doing" }).click();
  await expect.poll(() => mock.asides).toEqual(["What are you working on right now, and is anything holding you up?"]);
  await expect(card.getByRole("button", { name: "Ask what it's doing" })).toHaveCount(0);
  await card.getByRole("button", { name: "Stop" }).click();
  await expect(card).toHaveCount(0);
});

test("switching harness asks first and lists what is lost; same harness doesn't", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  const dialog = page.getByRole("dialog");
  const pending = page.getByTestId("pending-switch");

  // An empty chat has no session to lose.
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-codex/ }).click();
  await expect(picker(page)).toHaveAttribute("aria-label", /Codex, gpt-5-codex/);
  await expect(dialog).toHaveCount(0);
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Claude Code Opus 5.5/ }).click();
  await send(page, "hello");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: hello");

  // Same harness, new model: no question.
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Claude Code Sonnet 5.5/ }).click();
  await expect(pending).toContainText("Claude Code · Sonnet 5.5");
  await expect(dialog).toHaveCount(0);

  // Another harness: what carries over and what is lost; Cancel keeps the previous pick.
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-codex/ }).click();
  await expect(dialog).toHaveAccessibleName("Switch to Codex · gpt-5-codex?");
  await expect(dialog.getByRole("region", { name: "Carries over" })).toContainText("The latest messages, up to 40 or 24,000 characters");
  await expect(dialog.getByRole("region", { name: "Is lost" })).toContainText("Claude Code’s hidden reasoning");
  await expect(dialog.getByRole("region", { name: "Is lost" })).toContainText("The prompt cache, so the first reply costs more");
  await dialog.getByRole("button", { name: "Cancel" }).click();
  await expect(dialog).toHaveCount(0);
  await expect(composer(page)).toBeFocused();
  await expect(pending).toContainText("Claude Code · Sonnet 5.5");

  await picker(page).click();
  await page.getByRole("menuitem", { name: /Codex gpt-5-codex/ }).click();
  await dialog.getByRole("button", { name: "Switch harness" }).click();
  await expect(pending).toContainText("Codex · gpt-5-codex");
  await expect(composer(page)).toBeFocused();
});

test("each reply shows its tokens and cost on hover or focus", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "hello");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: hello");
  await expect(page.getByTestId("assistant-message")).not.toContainText("$0.042");
  await page.getByRole("button", { name: "Open Activity" }).click();
  const reply = page.getByTestId("activity-turn");
  await expect(reply).toContainText("Claude Code · Opus 5.5 · $0.042");
  const tooltip = page.getByTestId("usage-tooltip");
  await expect(tooltip).toHaveCount(0);

  // The composer takes focus back once the send settles (it's beside Activity now), so focus until the tooltip holds.
  await expect(async () => {
    await reply.getByTestId("model-tag").focus();
    await expect(tooltip).toContainText("Input48.2K41K cached · 7.2K uncached", { timeout: 1000 });
  }).toPass();
  await expect(tooltip).toContainText("Output1.3K");
  await expect(tooltip).toContainText("Cost$0.042");
  await page.keyboard.press("Escape");
  await expect(tooltip).toHaveCount(0);

  await reply.getByTestId("model-tag").hover();
  await expect(tooltip).toContainText("Cost$0.042");
});

test("the history groups conversations by the day they were last active", async ({ page }) => {
  const mock = await installChatApi(page);
  const at = (days: number) => new Date(Date.now() - days * 86_400_000).toISOString();
  const chat = (n: number, title: string, when: string) =>
    ({
      id: `d0000000-0000-4000-8000-00000000000${n}`, title, agent_id: AGENTS[0].id, harness: "claude-code", model: "opus-5.5", state: "idle",
      archived: false, revision: 1, message_count: 2, created_at: when, updated_at: when, last_message_at: when,
    }) as (typeof mock.chats)[number];
  mock.chats.push(chat(1, "Fresh one", at(0)), chat(2, "Old one", at(5)));
  await page.goto("/chat?new");
  await expect(historyNav(page).getByRole("region", { name: "Today" }).getByRole("link")).toHaveText([/Fresh one/]);
  await expect(historyNav(page).getByRole("region", { name: "Earlier" }).getByRole("link")).toHaveText([/Old one/]);
  await expect(historyNav(page).getByRole("region", { name: "Yesterday" })).toHaveCount(0);
});

test("a reply shows the effort Vesper picked for it, and why", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  await send(page, "effort: try again");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: effort: try again");
  await page.getByRole("button", { name: "Open Activity" }).click();
  const tag = page.getByTestId("activity-turn").getByTestId("model-tag");
  await expect(tag).toHaveText("Claude Code · Opus 5.5 · High (auto)");
  await expect(async () => {
    await tag.focus();
    await expect(page.getByTestId("usage-tooltip")).toContainText("Effort", { timeout: 1000 });
  }).toPass();
  await expect(page.getByTestId("usage-tooltip")).toContainText("EffortHighautomatic · aimed for extra high · raised after a retry or edit");
});

test("a new chat routes its model automatically until one is picked", async ({ page }) => {
  const mock = await installChatApi(page);
  await page.goto("/chat?new");
  await picker(page).click();
  await expect(page.getByRole("menuitem", { name: "Automatic model" })).toBeVisible();
  await page.keyboard.press("Escape");
  await page.getByRole("combobox", { name: "Message" }).fill("hello");
  await page.getByRole("button", { name: "Send" }).click();
  await expect(page).toHaveURL(/\/chat\/[0-9a-f-]+$/);
  expect(mock.posted[0].body).toEqual({ body: "hello", model: "auto" });

  // Picking a model replaces Auto; picking Auto again goes back.
  await page.goto("/chat?new");
  await picker(page).click();
  await page.getByRole("menuitem", { name: /Claude Code Sonnet 5\.5/ }).click();
  await expect(picker(page)).toHaveAccessibleName(/Sonnet 5\.5, Automatic effort/);
  await picker(page).click();
  await page.getByRole("menuitem", { name: "Automatic model" }).click();
  await expect(picker(page)).toHaveText("Auto");
  expect(mock.unhandled).toEqual([]);
});

test("a finished turn keeps its steps as a folded strip above the reply", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/chat?project=WEB");
  await newChat(page);
  // A reply that used no tools gets no strip.
  await send(page, "hello");
  await expect(page.getByTestId("assistant-message").getByText("Echo: hello")).toBeVisible();
  await expect(page.getByTestId("turn-steps")).toHaveCount(0);
  await send(page, "web: tts pricing?");
  const strip = page.getByTestId("turn-steps");
  await expect(strip).toHaveAttribute("data-outcome", "done");
  await expect(page.getByTestId("chat-status-card")).toHaveCount(0);
  await expect(strip.getByTestId("turn-steps-summary")).toHaveText(/· 1 step$/);
  await expect(strip.getByTestId("chat-steps")).toHaveCount(0);
  await strip.getByRole("button", { name: /Show steps/ }).click();
  await expect(strip.getByTestId("chat-steps").locator('[data-step-state="done"]')).toHaveCount(1);
  await expect(strip.getByTestId("chat-steps").locator('[data-step-state="active"]')).toHaveCount(0);
  await strip.getByRole("button", { name: /Hide steps/ }).click();
  await expect(strip.getByTestId("chat-steps")).toHaveCount(0);
});

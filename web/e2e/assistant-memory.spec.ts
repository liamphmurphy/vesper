import { expect, test, type Page } from "@playwright/test";
import { installChatApi, openEmptyChat } from "./mock-chat-api";

const composer = (page: Page) => page.getByRole("combobox", { name: "Message" });
const notices = (page: Page) => page.getByTestId("memory-notice");
const panel = (page: Page) => page.getByRole("region", { name: "Settings", exact: true });
async function openMemory(page: Page) {
  await page.getByRole("complementary", { name: "Right rail" }).getByRole("link", { name: "Settings", exact: true }).click();
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /^Memory/ }).click();
}
// Next keeps the page we navigated from mounted but hidden, so count only what is on screen.
const rows = (page: Page) => page.locator('[data-testid="memory-row"]:visible');

async function send(page: Page, text: string) {
  await composer(page).fill(text);
  await composer(page).press("Enter");
}

// Memory notices live in the Activity tab, out of the conversation: on desktop it's a dock tab, opened from the rail.
async function showActivity(page: Page) {
  const tab = page.getByRole("tablist", { name: "Panel tabs" }).getByRole("tab", { name: /Activity/ });
  if (await tab.isVisible()) {
    if ((await tab.getAttribute("aria-selected")) !== "true") await tab.click();
    return;
  }
  await page.getByRole("button", { name: "Open Activity" }).click();
}

async function openChat(page: Page) {
  await page.goto("/chat?project=WEB");
  await openEmptyChat(page);
  await expect(composer(page)).toBeVisible();
}

function memory(i: number, over: Partial<{ title: string; summary: string; tags: string[]; type: string }> = {}) {
  const t = "2026-10-01T09:00:00.000Z";
  return {
    id: `99999999-9999-4999-8999-${String(i).padStart(12, "0")}`,
    title: `Memory ${i}`, summary: `Summary ${i}`, body: `Body ${i}`, tags: [], type: "fact",
    source: "manual", created_at: t, updated_at: t, ...over,
  };
}

test("a saved memory shows an inline notice; Undo deletes it", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await send(page, "remember: I prefer tea");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: remember: I prefer tea");
  const notice = notices(page);
  await expect(notice).toHaveCount(1);
  await expect(notice).toBeHidden();
  await showActivity(page);
  await expect(notice).toContainText("Saved to memory: “I prefer tea”");
  await expect(notice.getByRole("button", { name: "View" })).toBeVisible();
  await expect(notice.getByRole("button", { name: "Forget" })).toBeVisible();
  expect(mock.memories).toHaveLength(1);

  await notice.getByRole("button", { name: "Undo" }).click();
  await expect(notice).toContainText("Not saved. I won’t remember this.");
  await expect(notice.getByRole("button")).toHaveCount(0);
  expect(mock.memories).toHaveLength(0);
  expect(mock.unhandled).toEqual([]);
});

test("Forget on a saved notice removes the entry and says so", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await send(page, "remember: Dog is called Rex");
  await showActivity(page);
  await expect(notices(page)).toContainText("Saved to memory: “Dog is called Rex”");
  await notices(page).getByRole("button", { name: "Forget" }).click();
  await expect(notices(page)).toContainText("Forgot 1 memory: “Dog is called Rex”");
  expect(mock.memories).toHaveLength(0);
  expect(mock.unhandled).toEqual([]);
});

test("a forget turn shows a Forgot notice", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await send(page, "remember: Old habit");
  await expect(notices(page)).toHaveCount(1);
  await send(page, "forget: Old habit");
  await expect(page.getByTestId("assistant-message").nth(1)).toContainText("Echo: forget: Old habit");
  await showActivity(page);
  const second = page.getByTestId("activity-turn").nth(1).getByTestId("memory-notice");
  await expect(second).toHaveText("Forgot 1 memory: “Old habit”");
  expect(mock.memories).toHaveLength(0);
  expect(mock.unhandled).toEqual([]);
});

test("a turn without memory tools shows no notice", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await send(page, "just chatting");
  await expect(page.getByTestId("assistant-message")).toContainText("Echo: just chatting");
  await expect(notices(page)).toHaveCount(0);
  expect(mock.unhandled).toEqual([]);
});

test("View opens the Memory page focused on that entry", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await send(page, "remember: Likes hiking");
  await showActivity(page);
  await notices(page).getByRole("button", { name: "View" }).click();
  const id = mock.memories[0].id;
  await expect(page).toHaveURL(new RegExp(`/settings\\?section=memory&id=${id}`));
  await expect(panel(page)).toBeVisible();
  const form = panel(page).getByRole("form", { name: "Edit Likes hiking" });
  await expect(form).toBeVisible();
  await expect(form.getByRole("textbox", { name: "Title" })).toHaveValue("Likes hiking");

  await form.getByRole("button", { name: "Cancel" }).click();
  await expect(form).toHaveCount(0);
  await expect(page).toHaveURL(/\/settings\?section=memory$/);
  expect(mock.unhandled).toEqual([]);
});

test("the Settings Memory link opens Memory on its own page, without the chat", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  const toggle = page.getByRole("complementary", { name: "Right rail" }).getByRole("link", { name: "Settings", exact: true });
  await expect(toggle).not.toHaveAttribute("aria-current", "page");
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-current", "page");
  await page.getByRole("navigation", { name: "Settings sections" }).getByRole("link", { name: /^Memory/ }).click();
  await expect(panel(page)).toBeVisible();
  await expect(panel(page)).toContainText("Nothing remembered yet");
  await expect(page).toHaveURL(/\/settings\?section=memory$/);
  await expect(composer(page)).toHaveCount(0);
  expect(mock.unhandled).toEqual([]);
});

test("search and the type filter narrow the list", async ({ page }) => {
  const mock = await installChatApi(page);
  mock.memories.push(
    memory(1, { title: "Prefers dark mode", summary: "UI theme", type: "preference", tags: ["ui"] }),
    memory(2, { title: "Sister is Ana", summary: "Family", type: "person", tags: ["family"] }),
    memory(3, { title: "Ships on Fridays", summary: "Release day", type: "work" }),
  );
  await openChat(page);
  await openMemory(page);
  await expect(rows(page)).toHaveCount(3);

  await panel(page).getByRole("searchbox", { name: "Search memories" }).fill("family");
  await expect(rows(page)).toHaveCount(1);
  await expect(rows(page).first()).toContainText("Sister is Ana");
  await expect(rows(page).first()).toContainText("Person");
  expect(mock.memoryRequests.some((r) => r.includes("q=family"))).toBe(true);

  await panel(page).getByRole("searchbox", { name: "Search memories" }).fill("nothing like this");
  await expect(panel(page).getByText("No memories match.")).toBeVisible();

  await panel(page).getByRole("searchbox", { name: "Search memories" }).fill("");
  await expect(rows(page)).toHaveCount(3);
  const filter = panel(page).getByRole("group", { name: "Filter by type" });
  await filter.getByRole("button", { name: "Work" }).click();
  await expect(filter.getByRole("button", { name: "Work" })).toHaveAttribute("aria-pressed", "true");
  await expect(rows(page)).toHaveCount(1);
  await expect(rows(page).first()).toContainText("Ships on Fridays");
  expect(mock.memoryRequests.some((r) => r.includes("type=work"))).toBe(true);
  await filter.getByRole("button", { name: "All" }).click();
  await expect(rows(page)).toHaveCount(3);
  expect(mock.unhandled).toEqual([]);
});

test("editing an entry and saving sends a PATCH", async ({ page }) => {
  const mock = await installChatApi(page);
  mock.memories.push(memory(1, { title: "Prefers dark mode", summary: "UI theme", type: "preference" }));
  await openChat(page);
  await openMemory(page);
  await expect(rows(page)).toHaveCount(1);
  await rows(page).getByRole("button", { name: "Edit Prefers dark mode" }).click();

  const form = panel(page).getByRole("form", { name: "Edit Prefers dark mode" });
  await form.getByRole("textbox", { name: "Title" }).fill("Prefers light mode");
  await form.getByRole("textbox", { name: "Summary" }).fill("Changed their mind");
  await form.getByRole("textbox", { name: "Details" }).fill("Since October");
  await form.getByLabel("Type").selectOption("life");
  await form.getByRole("textbox", { name: "Tags" }).fill("UI, theme, ui");
  await form.getByRole("button", { name: "Save" }).click();

  await expect(form).toHaveCount(0);
  await expect(rows(page).first()).toContainText("Prefers light mode");
  await expect(rows(page).first()).toContainText("Life");
  expect(mock.memoryPatches).toEqual([
    { title: "Prefers light mode", summary: "Changed their mind", body: "Since October", type: "life", tags: ["ui", "theme"] },
  ]);

  // Cancel closes the form without another PATCH.
  await rows(page).first().getByRole("button", { name: "Edit Prefers light mode" }).click();
  await panel(page).getByRole("form", { name: "Edit Prefers light mode" }).getByRole("button", { name: "Cancel" }).click();
  await expect(panel(page).getByRole("form")).toHaveCount(0);
  expect(mock.memoryPatches).toHaveLength(1);
  expect(mock.unhandled).toEqual([]);
});

test("delete removes one entry, from the row or from its editor", async ({ page }) => {
  const mock = await installChatApi(page);
  mock.memories.push(memory(1, { title: "One" }), memory(2, { title: "Two" }), memory(3, { title: "Three" }));
  await openChat(page);
  await openMemory(page);
  await expect(rows(page)).toHaveCount(3);

  await panel(page).getByRole("button", { name: "Delete One" }).click();
  await expect(rows(page)).toHaveCount(2);
  expect(mock.memories.map((m) => m.title)).toEqual(["Two", "Three"]);

  await rows(page).getByRole("button", { name: "Edit Two" }).click();
  await panel(page).getByRole("form", { name: "Edit Two" }).getByRole("button", { name: "Delete", exact: true }).click();
  await expect(rows(page)).toHaveCount(1);
  expect(mock.memories.map((m) => m.title)).toEqual(["Three"]);
  expect(mock.unhandled).toEqual([]);
});

test("Delete everything asks first, and Cancel keeps the entries", async ({ page }) => {
  const mock = await installChatApi(page);
  mock.memories.push(memory(1), memory(2));
  await openChat(page);
  await openMemory(page);
  await expect(rows(page)).toHaveCount(2);

  await panel(page).getByRole("button", { name: "Delete everything…" }).click();
  const confirm = panel(page).getByRole("group", { name: "Confirm delete everything" });
  await expect(confirm).toContainText("Forget all 2 memories?");
  await confirm.getByRole("button", { name: "Cancel" }).click();
  await expect(confirm).toHaveCount(0);
  expect(mock.memories).toHaveLength(2);

  await panel(page).getByRole("button", { name: "Delete everything…" }).click();
  await panel(page).getByRole("group", { name: "Confirm delete everything" }).getByRole("button", { name: "Delete everything" }).click();
  await expect(rows(page)).toHaveCount(0);
  await expect(panel(page)).toContainText("Nothing remembered yet");
  expect(mock.memories).toHaveLength(0);
  expect(mock.memoryRequests).toContain("DELETE /memories?confirm=true");
  expect(mock.unhandled).toEqual([]);
});

test("the Export menu offers JSON and Markdown downloads", async ({ page }) => {
  const mock = await installChatApi(page);
  mock.memories.push(memory(1, { title: "Prefers dark mode", tags: ["ui"] }));
  await openChat(page);
  await openMemory(page);
  await panel(page).getByText("Export", { exact: true }).click();
  const json = panel(page).getByRole("button", { name: "JSON (all entries)" });
  const md = panel(page).getByRole("button", { name: "Markdown (all entries)" });
  await expect(json).toBeVisible();
  await expect(md).toBeVisible();

  const [jsonDownload] = await Promise.all([page.waitForEvent("download"), json.click()]);
  expect(jsonDownload.suggestedFilename()).toMatch(/^memory-\d{4}-\d{2}-\d{2}\.json$/);

  const [mdDownload] = await Promise.all([page.waitForEvent("download"), md.click()]);
  expect(mdDownload.suggestedFilename()).toMatch(/^memory-\d{4}-\d{2}-\d{2}\.md$/);
  expect(mock.memoryRequests.filter((r) => r === "GET /memories/export")).toHaveLength(2);
  expect(mock.unhandled).toEqual([]);
});

test("Import previews a pasted reply, saves it, and lists the entries as imported", async ({ page }) => {
  const mock = await installChatApi(page);
  await openChat(page);
  await openMemory(page);
  await panel(page).getByRole("button", { name: "Import", exact: true }).click();
  await expect(panel(page).getByRole("button", { name: "Import", exact: true })).toHaveAttribute("aria-pressed", "true");
  await expect(panel(page).getByText("I'm moving to a new personal assistant called Vesper")).toBeVisible();
  await expect(panel(page).getByRole("button", { name: "Copy prompt" })).toBeVisible();

  const reply = [
    "Sure, here is everything I know:",
    "```json",
    JSON.stringify({ memories: [
      { title: "Prefers metric units", summary: "Uses km and Celsius.", type: "preference", tags: ["units"] },
      { title: "Sister is Ana", summary: "Lives in Lisbon.", type: "person", tags: ["family"] },
    ] }),
    "```",
    "Let me know if you need more!",
  ].join("\n");
  await panel(page).getByRole("textbox", { name: "2. Paste its reply" }).fill(reply);
  await expect(panel(page)).toContainText("Found 2 memories");
  await panel(page).getByRole("button", { name: "Import 2 memories" }).click();
  await expect(panel(page)).toContainText("Added 2, updated 0");
  expect(mock.memoryImports).toHaveLength(1);
  expect(mock.memories.map((m) => m.title).sort()).toEqual(["Prefers metric units", "Sister is Ana"]);

  await panel(page).getByRole("button", { name: "Done" }).click();
  await expect(rows(page)).toHaveCount(2);
  await expect(rows(page).first()).toContainText("imported");
  await expect(rows(page).nth(1)).toContainText("imported");
  expect(mock.unhandled).toEqual([]);
});

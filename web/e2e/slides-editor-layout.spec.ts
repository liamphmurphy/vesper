import { expect, test, type Page } from "@playwright/test";
import { DECK, deckWith, installDeck as install } from "./mock-deck-api";

// LAZYAGENTS-160: the Slides editor on the shared EditorLayout. Thumbnails on
// the left, Chat and Review in the dock, Present and Share ▾ in the header.

const dock = (page: Page) => page.getByRole("complementary", { name: "Panel", exact: true });
const rail = (page: Page) => page.getByRole("navigation", { name: "Panel rail" });
const tabs = (page: Page) => rail(page).getByRole("tablist", { name: "Panel tabs" });
const mod = process.platform === "darwin" ? "Meta" : "Control";

test.use({ viewport: { width: 1440, height: 900 } });

test("a long dock conversation scrolls inside the app at desktop and overlay widths", async ({ page }) => {
  await install(page, [{ seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" }]);
  await page.route(/\/api\/v1\/chats\/[^/]+\/messages(\?|$)/, (route) => route.fulfill({
    json: {
      messages: Array.from({ length: 40 }, (_, i) => ({
        id: `message-${i}`, seq: i + 1, role: i % 2 ? "assistant" : "user",
        body_md: `Message ${i + 1}\n\n${"A detailed discussion of the quarterly slides. ".repeat(12)}`,
        created_at: "2026-11-12T12:00:00Z",
      })),
      has_more: false,
    },
  }));
  await page.reload();
  const conversation = dock(page).getByRole("log", { name: "Conversation" });
  await expect(conversation.getByText(/^Message 40$/)).toBeVisible();

  for (const viewport of [{ width: 1440, height: 900 }, { width: 1440, height: 500 }, { width: 1000, height: 500 }]) {
    await page.setViewportSize(viewport);
    const panel = dock(page).locator("[data-dock-panel]");
    await expect.poll(() => panel.evaluate((el) => el.getBoundingClientRect().bottom)).toBeLessThanOrEqual(viewport.height);
    const scroller = conversation.locator("..");
    expect(await scroller.evaluate((el) => el.scrollHeight > el.clientHeight)).toBe(true);
    await scroller.evaluate((el) => { el.scrollTop = 0; });
    await expect(conversation.getByText(/^Message 1$/)).toBeVisible();
    await scroller.evaluate((el) => { el.scrollTop = el.scrollHeight; });
    await expect(conversation.getByText(/^Message 40$/)).toBeVisible();
    await expect(dock(page).getByRole("combobox", { name: "Message" })).toBeInViewport();
    await expect(page.getByRole("button", { name: /Present/ })).toBeInViewport();
    expect(await page.evaluate(() => document.documentElement.scrollHeight)).toBeLessThanOrEqual(viewport.height);
  }
});

test("the deck renders in the editor layout and its dock collapses and reopens", async ({ page }) => {
  await install(page, [{ seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" }]);

  // Thumbnails on the left, chat in the dock, no Hide chat.
  await expect(page.getByRole("complementary", { name: "Structure" }).getByRole("navigation", { name: "Slides" })).toBeVisible();
  await expect(dock(page).getByRole("tabpanel", { name: /^Chat/ }).first()).toBeVisible();
  await expect(tabs(page).getByRole("tab", { name: /Review/ })).toHaveCount(0);
  await expect(page.getByRole("button", { name: /Hide chat/ })).toHaveCount(0);
  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v1/);

  await rail(page).getByRole("button", { name: "Collapse panel" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await rail(page).getByRole("button", { name: "Expand panel" }).click();
  await expect(dock(page).getByRole("tabpanel", { name: /^Chat/ }).first()).toBeVisible();

  await page.locator("body").click();
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await page.keyboard.press(`${mod}+j`);
  await expect(dock(page)).toBeVisible();
  await expect(dock(page).getByRole("combobox", { name: "Message" })).toBeFocused();

  // The collapsed state is remembered across a reload.
  await rail(page).getByRole("button", { name: "Collapse panel" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await page.reload();
  await expect(page.getByTestId("deck-save-state")).toBeVisible();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
});

test("Share holds both exports and Present stays in the header", async ({ page }) => {
  await install(page, [{ seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" }]);

  for (const [item, file] of [[/^PDF \(\.pdf\)/, "Layout.pdf"], [/^PowerPoint \(\.pptx\)/, "Layout.pptx"]] as const) {
    await page.getByRole("button", { name: "Share" }).click();
    const download = page.waitForEvent("download");
    await page.getByRole("menuitem", { name: item }).click();
    expect((await download).suggestedFilename()).toBe(file);
  }

  await page.getByRole("button", { name: /Present/ }).click();
  await expect(page).toHaveURL(new RegExp(`/present/slides/${DECK}\\?slide=1`));
});

test("Share can keep an export in the Library, linked to the deck", async ({ page }) => {
  await install(page, [{ seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" }]);
  const saved: { url: string; body: string }[] = [];
  await page.route(`**/api/v1/slides/${DECK}/library`, (route) => {
    saved.push({ url: route.request().url(), body: route.request().postData() ?? "" });
    return route.fulfill({ status: 201, contentType: "application/json", body: JSON.stringify({ id: "x", kind: "export", title: "Layout", filename: "Layout.pdf", content_type: "application/pdf", size_bytes: 1, created_at: new Date().toISOString() }) });
  });
  await page.getByRole("button", { name: "Share" }).click();
  await page.getByRole("menuitem", { name: /^Save PDF to Library/ }).click();
  await expect(page.getByText("Saved “Layout.pdf” to your Library")).toBeVisible();
  expect(saved).toHaveLength(1);
  expect(saved[0].body).toContain('filename="Layout.pdf"');
  expect(saved[0].body).toContain("%PDF-");
});

test("a persona's suggestions open in the Review tab and can be accepted or rejected", async ({ page }) => {
  const s = await install(page, [
    { seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" },
    { seq: 2, body: JSON.stringify(deckWith("Q4 business review")), author: "agent" },
  ]);

  await expect(tabs(page).getByRole("tab", { name: /Review/ })).toHaveAttribute("aria-selected", "true");
  const review = page.getByTestId("deck-review");
  await expect(review.getByText(/suggested 1 change/)).toBeVisible();
  await expect(page.getByText("Editing is paused until you decide them in Review.")).toBeVisible();

  // Rejecting records a version that keeps the person's title.
  await review.getByRole("button", { name: "Reject", exact: true }).click();
  await expect.poll(() => s.reviewed).toEqual([3]);
  expect(JSON.parse(s.versions[2].body).slides[0].elements[0].paragraphs[0].runs[0].text).toBe("Quarterly review");
});

test("accepting every suggestion marks the review done without a new version", async ({ page }) => {
  const s = await install(page, [
    { seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" },
    { seq: 2, body: JSON.stringify(deckWith("Q4 business review")), author: "agent" },
  ]);
  const review = page.getByTestId("deck-review");
  await review.getByRole("button", { name: "Accept all" }).click();
  await expect.poll(() => s.reviewed).toEqual([2]);
  expect(s.versions).toHaveLength(2);
  // The review ends: the dock is back on Chat and the slide is editable.
  await expect(tabs(page).getByRole("tab", { name: /Review/ })).toHaveCount(0);
  await expect(dock(page).getByRole("tabpanel", { name: /^Chat/ }).first()).toBeVisible();
  await expect(page.getByRole("toolbar", { name: "Slide formatting" }).getByRole("button", { name: "T Text" })).toBeEnabled();
});

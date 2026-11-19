import { expect, test, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";

// LAZYAGENTS-156: the shared editor layout, on its demo route.
const dock = (page: Page) => page.getByRole("complementary", { name: "Panel", exact: true });
const rail = (page: Page) => page.getByRole("navigation", { name: "Panel rail" });
const structure = (page: Page) => page.getByRole("complementary", { name: "Structure" });
const mod = process.platform === "darwin" ? "Meta" : "Control";

test.use({ viewport: { width: 1440, height: 900 } });

test.beforeEach(async ({ page }) => {
  await installBoardApi(page);
  // The person prefers the expanded menu; the editor must show the rail without changing that.
  await page.addInitScript(() => {
    if (!sessionStorage.getItem("seeded")) {
      localStorage.setItem("lazyagents.sidebar-expanded", "1");
      sessionStorage.setItem("seeded", "1");
    }
  });
});

test("the dock collapses to a rail in place and reopens from it", async ({ page }) => {
  await page.goto("/dev/editor-layout");
  await expect(rail(page).getByRole("tab", { name: /Chat/ })).toHaveAttribute("aria-selected", "true");
  await expect(dock(page).getByRole("tablist")).toHaveCount(0);
  await expect(dock(page).getByRole("button", { name: "Collapse panel" })).toHaveCount(0);

  await rail(page).getByRole("button", { name: "Collapse panel" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();

  await rail(page).getByRole("button", { name: "Open Comments" }).click();
  await expect(rail(page).getByRole("tab", { name: "Comments" })).toHaveAttribute("aria-selected", "true");
  await expect(dock(page).getByText("No comments")).toBeVisible();

  // Clicking the active tab collapses; another tab switches.
  await rail(page).getByRole("tab", { name: "Inspect" }).click();
  await expect(dock(page).getByText("Nothing selected")).toBeVisible();
  await rail(page).getByRole("tab", { name: "Inspect" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await rail(page).getByRole("button", { name: "Expand panel" }).click();
  await expect(rail(page).getByRole("tab", { name: "Inspect" })).toHaveAttribute("aria-selected", "true");
});

test("⌘\\ toggles the dock, ⌘J opens Chat and focuses it, ⌘. hides and restores both panels", async ({ page }) => {
  await page.goto("/dev/editor-layout");
  await expect(dock(page)).toBeVisible();
  await page.locator("body").click();

  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toBeVisible();

  await rail(page).getByRole("tab", { name: "Comments" }).click();
  await page.keyboard.press(`${mod}+j`);
  await expect(rail(page).getByRole("tab", { name: /Chat/ })).toHaveAttribute("aria-selected", "true");
  await expect(page.getByRole("textbox", { name: "Message" })).toBeFocused();

  // While typing only ⌘J applies.
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dock(page)).toBeVisible();

  await page.locator("body").click();
  await page.keyboard.press(`${mod}+Period`);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toHaveCount(0);
  await expect(structure(page)).toHaveCount(0);
  await page.keyboard.press(`${mod}+Period`);
  await expect(dock(page)).toBeVisible();
  await expect(structure(page)).toBeVisible();
});

test("the dock's state persists per app across a reload, and the structure is the left column's list", async ({ page }) => {
  await page.goto("/dev/editor-layout");
  const menu = page.getByRole("complementary", { name: "Main menu" });
  // One column: the editor's structure is its list, in place of Chats, not a second column.
  await expect(menu).toHaveAttribute("data-expanded");
  await expect(menu.getByRole("complementary", { name: "Structure" })).toBeVisible();
  await expect(menu.getByRole("complementary", { name: "Chat history" })).toHaveCount(0);

  await rail(page).getByRole("tab", { name: "Comments" }).click();
  await rail(page).getByRole("tab", { name: "Comments" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toBeVisible();
  await expect.poll(() => page.evaluate(() => localStorage.getItem("lazyagents.editor-dock.demo"))).toBe(JSON.stringify({ open: false, tab: "comments" }));

  await page.reload();
  await expect(rail(page)).toBeVisible();
  await rail(page).getByRole("button", { name: "Expand panel" }).click();
  await expect(rail(page).getByRole("tab", { name: "Comments" })).toHaveAttribute("aria-selected", "true");

  // Leaving the editor gives the column back to Chats.
  await page.goto("/chat");
  await expect(menu.getByRole("complementary", { name: "Chat history" })).toBeVisible();
  await expect(menu.getByRole("complementary", { name: "Structure" })).toHaveCount(0);
});

test("the busy and unread marks show on the Chat tab", async ({ page }) => {
  await page.goto("/dev/editor-layout");
  const chat = rail(page).getByRole("tab", { name: /Chat/ });
  await expect(chat).toHaveAccessibleName(/unread/);
  await page.getByLabel("Persona busy").check();
  await expect(chat).toHaveAccessibleName(/working, unread/);
});

test("opening and collapsing the dock slides cleanly on the compositor transform", async ({ page }) => {
  await page.goto("/dev/editor-layout");
  const aside = page.locator('aside[aria-label="Panel"]');
  // Initial load with the dock already open does not animate.
  await expect(aside).toBeVisible();
  await expect(aside).not.toHaveClass(/\bmotion-dock\b/);

  // Collapsing starts a transform transition off-screen, then hides the panel once it finishes.
  await rail(page).getByRole("button", { name: "Collapse panel" }).click();
  await expect(aside).toHaveClass(/\bmotion-dock\b/);
  await expect(aside).toHaveAttribute("data-open", "false");
  await expect(aside).toHaveCSS("transition-property", /transform/);
  await expect(dock(page)).toHaveCount(0);

  // Reopening from the right rail slides back to 360px wide and clears motion-dock on settle.
  await rail(page).getByRole("button", { name: "Open Comments" }).click();
  await expect(aside).toHaveAttribute("data-open", "true");
  await expect(aside).toBeVisible();
  await expect(aside).not.toHaveClass(/\bmotion-dock\b/);
  await expect.poll(() => aside.evaluate((el) => Math.round(el.getBoundingClientRect().width))).toBe(360);
});

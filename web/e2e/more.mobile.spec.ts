import { expect, test, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";

// VESPER-17: More (project "mobile", 390×844) lists the sidebar's pages beyond the four tabs.
const bar = (page: Page) => page.getByRole("navigation", { name: "Primary" });
const main = (page: Page) => page.locator("main");

test("More lists the apps, tools and your pages with the nav badges", async ({ page }) => {
  const api = await installBoardApi(page);
  api.counts.wiki_suggestions = 2;
  // No secrets key: Settings shows the amber dot.
  await page.route("**/api/v1/secrets", (route) => route.fulfill({ json: { key_configured: false, known: [], secrets: [] } }));
  await page.goto("/more");

  const apps = main(page).getByRole("region", { name: "Apps" });
  await expect(apps.getByRole("link")).toHaveText(["Knowledge2", "Finance", "Library"]);
  await expect(apps.getByRole("link", { name: "Knowledge, 2 suggested edits to review" })).toBeVisible();
  const tools = main(page).getByRole("region", { name: "Tools" });
  await expect(tools.getByRole("link")).toHaveText(["Workflows", "Scheduled", "Learn", "Reports"]);
  const you = main(page).getByRole("region", { name: "You" });
  await expect(you.getByRole("link", { name: "Customization" })).toBeVisible();
  await expect(you.getByRole("link", { name: "Settings: a setting runs need is missing" }).getByTestId("more-dot")).toBeVisible();

  // Every row is a comfortable touch target, and nothing scrolls sideways.
  for (const link of await main(page).getByRole("region").getByRole("link").all()) expect((await link.boundingBox())!.height).toBeGreaterThanOrEqual(44);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
});

test("Knowledge and Settings open from More, which stays the current tab", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/more");
  await main(page).getByRole("link", { name: /^Knowledge/ }).tap();
  await expect(page).toHaveURL(/\/knowledge$/);
  await expect(bar(page).locator('[aria-current="page"]')).toHaveText("More");

  await bar(page).getByRole("link", { name: "More" }).tap();
  await expect(page).toHaveURL(/\/more$/);
  await main(page).getByRole("link", { name: /^Settings/ }).tap();
  await expect(page).toHaveURL(/\/settings/);
  await expect(bar(page).locator('[aria-current="page"]')).toHaveText("More");
});

test("the search field opens the command menu full screen, usable by touch", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/more");
  await main(page).getByRole("button", { name: "Search" }).tap();
  const dialog = page.getByRole("dialog", { name: "Search and commands" });
  await expect(dialog).toBeVisible();
  await expect.poll(async () => dialog.boundingBox()).toEqual({ x: 0, y: 0, width: 390, height: 844 });
  await expect(dialog.getByRole("combobox", { name: "Search everything" })).toBeFocused();

  const close = dialog.getByRole("button", { name: "Close search" });
  expect(Math.round((await close.boundingBox())!.height)).toBeGreaterThanOrEqual(44);
  await close.tap();
  await expect(dialog).toHaveCount(0);

  await main(page).getByRole("button", { name: "Search" }).tap();
  await dialog.getByRole("combobox", { name: "Search everything" }).fill("knowledge");
  const option = dialog.getByRole("option", { name: /^Knowledge/ });
  // Polled: the option renders at once, inside the dialog's 100ms scale-in.
  await expect.poll(async () => Math.round((await option.boundingBox())!.height)).toBeGreaterThanOrEqual(44);
  await option.tap();
  await expect(page).toHaveURL(/\/knowledge$/);
  await expect(dialog).toHaveCount(0);
});

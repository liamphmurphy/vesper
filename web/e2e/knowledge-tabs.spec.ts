import { expect, test, type Page, type Route } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

test.use({ viewport: { width: 1440, height: 900 } });

const at = "2026-11-15T06:00:00Z";
const PAGES = [
  { id: "11111111-1111-4111-8111-111111111111", title: "Alpha", path: "Alpha", body_md: "Alpha notes" },
  { id: "22222222-2222-4222-8222-222222222222", title: "Beta", path: "Beta", body_md: "Beta notes" },
  { id: "33333333-3333-4333-8333-333333333333", title: "Gamma", path: "Gamma", body_md: "Gamma notes" },
].map((p) => ({
  ...p,
  audience: "private",
  summary: "",
  properties: {},
  updated_at: at,
  version_id: "v1",
  seq: 1,
  direct: false,
  paused: false,
  chat_id: null,
  url: `/knowledge/${p.id}`,
  embeds: [],
  reviews: [],
  versions: [],
}));

const json = (route: Route, data: unknown) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });

async function install(page: Page) {
  await installChatApi(page);
  await page.route(/\/api\/v1\/knowledge\//, (route) => {
    const path = new URL(route.request().url()).pathname.replace("/api/v1/knowledge", "");
    if (path === "/query") return json(route, { columns: [], rows: PAGES, total: PAGES.length, has_more: false });
    const target = PAGES.find((p) => path === `/pages/${p.id}`);
    if (target) return json(route, target);
    if (path === "/network" || path === "/graph") return json(route, { nodes: [], edges: [] });
    if (path === "/backlinks") return json(route, { linked: [], unlinked: [] });
    return json(route, {});
  });
}

const tablist = (page: Page) => page.getByRole("tablist", { name: "Open pages" });
const tabTitles = async (page: Page) => {
  const tabs = tablist(page).getByRole("tab");
  const count = await tabs.count();
  const names: string[] = [];
  for (let i = 0; i < count; i++) {
    names.push((await tabs.nth(i).locator("a").innerText()).trim());
  }
  return names;
};

test("Knowledge tabs close with Alt+W, Alt+Shift+W, middle-click and the tab context menu", async ({ page }) => {
  await install(page);
  await page.goto("/knowledge");

  const explorer = page.getByRole("navigation", { name: "Pages" });
  await explorer.getByRole("link", { name: "Alpha" }).click();
  await expect(tablist(page).getByRole("tab", { name: /Alpha/ })).toBeVisible();
  await explorer.getByRole("link", { name: "Beta" }).click();
  await expect(tablist(page).getByRole("tab", { name: /Beta/ })).toBeVisible();
  await explorer.getByRole("link", { name: "Gamma" }).click();
  await expect(tablist(page).getByRole("tab", { name: /Gamma/ })).toBeVisible();

  expect(await tabTitles(page)).toEqual(["New tab", "Alpha", "Beta", "Gamma"]);

  // Alt+W does not close a tab while a modal dialog (Quick Switcher) is open.
  await page.keyboard.press("ControlOrMeta+o");
  await expect(page.getByRole("dialog")).toBeVisible();
  await page.keyboard.press("Alt+w");
  await page.keyboard.press("Escape");
  await expect(page.getByRole("dialog")).toBeHidden();
  expect(await tabTitles(page)).toEqual(["New tab", "Alpha", "Beta", "Gamma"]);

  // Alt+W works while focused in the page body and closes the active tab (Gamma -> Beta).
  await page.locator(".kn-editor [contenteditable]").first().click();
  await page.keyboard.press("Alt+w");
  await expect(page).toHaveURL(new RegExp(`/knowledge/${PAGES[1].id}`));
  expect(await tabTitles(page)).toEqual(["New tab", "Alpha", "Beta"]);

  // Re-open Gamma, then close Beta with middle-click without opening a browser popup.
  await explorer.getByRole("link", { name: "Gamma" }).click();
  await expect(tablist(page).getByRole("tab", { name: /Gamma/ })).toBeVisible();
  expect(await tabTitles(page)).toEqual(["New tab", "Alpha", "Beta", "Gamma"]);
  await tablist(page).getByRole("tab", { name: /Beta/ }).click({ button: "middle" });
  expect(await tabTitles(page)).toEqual(["New tab", "Alpha", "Gamma"]);

  // Context menu on the rightmost tab disables "Close tabs to the right".
  await tablist(page).getByRole("tab", { name: /Gamma/ }).click({ button: "right" });
  const rightMenu = page.getByRole("menu");
  await expect(rightMenu.getByRole("menuitem", { name: "Close tabs to the right" })).toBeDisabled();
  await page.keyboard.press("Escape");

  // "Close tabs to the right" on Alpha closes Gamma and switches back to Alpha.
  await tablist(page).getByRole("tab", { name: /Alpha/ }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Close tabs to the right" }).click();
  await expect(page).toHaveURL(new RegExp(`/knowledge/${PAGES[0].id}`));
  expect(await tabTitles(page)).toEqual(["New tab", "Alpha"]);

  // "Close others" on New tab closes Alpha and switches to New tab.
  await tablist(page).getByRole("tab", { name: /New tab/ }).click({ button: "right" });
  await page.getByRole("menuitem", { name: "Close others" }).click();
  await expect(page).toHaveURL(/\/knowledge$/);
  expect(await tabTitles(page)).toEqual(["New tab"]);

  // When only New tab is open, Close others / Close all tabs are disabled.
  await tablist(page).getByRole("tab", { name: /New tab/ }).click({ button: "right" });
  await expect(page.getByRole("menuitem", { name: "Close others" })).toBeDisabled();
  await expect(page.getByRole("menuitem", { name: "Close all tabs" })).toBeDisabled();
  await page.keyboard.press("Escape");

  // Open two pages, then close all tabs via Alt+Shift+W and via the context menu.
  await explorer.getByRole("link", { name: "Alpha" }).click();
  await expect(tablist(page).getByRole("tab", { name: /Alpha/ })).toBeVisible();
  await explorer.getByRole("link", { name: "Beta" }).click();
  await expect(tablist(page).getByRole("tab", { name: /Beta/ })).toBeVisible();
  await page.locator("body").click({ position: { x: 700, y: 20 } });
  await page.keyboard.press("Alt+Shift+W");
  await expect(page).toHaveURL(/\/knowledge$/);
  expect(await tabTitles(page)).toEqual(["New tab"]);

  await explorer.getByRole("link", { name: "Alpha" }).click();
  await expect(tablist(page).getByRole("tab", { name: /Alpha/ })).toBeVisible();
  await tablist(page).getByRole("tab", { name: /Alpha/ }).click({ button: "right" });
  await page.getByRole("menuitem", { name: /Close all tabs/ }).click();
  await expect(page).toHaveURL(/\/knowledge$/);
  expect(await tabTitles(page)).toEqual(["New tab"]);
});

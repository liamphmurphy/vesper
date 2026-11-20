import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { installBoardApi } from "./mock-board-api";

type App = components["schemas"]["CustomAppDetail"];

// A custom app's playVideo opens a player docked above the app, not a popup; theater widens it and
// asks the Mac shell to fold its sidebar, and the app hears the player's state through onPlayer.

// The bundled app, as the bridge runtime would deliver it: buttons post play-video and the page
// records the vesper:player messages it receives.
const bundleJs = `
window.__player = [];
window.addEventListener("message", (e) => { if (e.data && e.data.type === "vesper:player") window.parent.postMessage({ channel: "test", player: { open: e.data.open, theater: e.data.theater } }, "*"); });
const play = (theater) => window.parent.postMessage({ channel: "vesper:custom-app", type: "play-video", payload: { url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", title: "Demo video", ...(theater ? { theater: true } : {}) } }, "*");
document.getElementById("root").innerHTML = '<button id="play">Play</button><button id="theater">Play in theater</button>';
document.getElementById("play").onclick = () => play(false);
document.getElementById("theater").onclick = () => play(true);
`;

const now = new Date().toISOString();
const manifest = { entry: "app.tsx", tool_scope: "chats" as const };
const app: App = {
  id: "app-1", slug: "demo", name: "Demo", description: "", icon: "film", current_seq: 1, manifest, capabilities: {},
  db_size_bytes: 0, has_mcp_server: false, created_at: now, updated_at: now, versions: [], schema: [],
  current: { seq: 1, note: "", author_type: "user", created_at: now, manifest, files: { "app.tsx": "" }, bundle_js: bundleJs, bundle_css: "" },
};

async function open(page: Page) {
  await installBoardApi(page);
  await page.route("**/api/v1/custom-apps/demo", (route) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(app) }));
  // Stand in for the Mac shell: record what the page asks of it.
  await page.addInitScript(() => {
    const sent: unknown[] = [];
    Object.assign(window, {
      __shellMessages: sent,
      __VESPER_NATIVE__: { v: 1, platform: "macos" },
      webkit: { messageHandlers: { vesper: { postMessage: (m: unknown) => sent.push(m) } } },
    });
    const heard: unknown[] = [];
    Object.assign(window, { __playerStates: heard });
    window.addEventListener("message", (e) => { if (e.data?.channel === "test") heard.push(e.data.player); });
  });
  // Keep the real embed out of the test.
  await page.route("https://www.youtube-nocookie.com/**", (route) => route.fulfill({ status: 200, contentType: "text/html", body: "<p>player</p>" }));
  await page.goto("/apps/demo");
  return page.frameLocator('[data-testid="custom-app-frame"]');
}

const sidebarMessages = (page: Page) =>
  page.evaluate(() => (window as unknown as { __shellMessages: Array<{ type: string; hidden?: boolean }> }).__shellMessages.filter((m) => m.type === "sidebarHidden").map((m) => m.hidden));
const playerStates = (page: Page) => page.evaluate(() => (window as unknown as { __playerStates: unknown[] }).__playerStates);

test("playVideo docks the player above the app instead of opening a dialog", async ({ page }) => {
  const frame = await open(page);
  await frame.locator("#play").click();

  const player = page.getByTestId("custom-app-player");
  await expect(player).toBeVisible();
  await expect(player).toHaveAttribute("data-theater", "false");
  await expect(player.getByRole("heading", { name: "Demo video" })).toBeVisible();
  await expect(player.locator('iframe[src*="youtube-nocookie.com/embed/dQw4w9WgXcQ"]')).toHaveCount(1);
  await expect(page.getByRole("dialog")).toHaveCount(0);
  // The app stays usable underneath.
  await expect(frame.locator("#theater")).toBeVisible();
  await expect.poll(() => playerStates(page)).toContainEqual({ open: true, theater: false });

  await player.getByRole("button", { name: /Close video player/ }).click();
  await expect(player).toHaveCount(0);
  await expect.poll(() => playerStates(page)).toContainEqual({ open: false, theater: false });
  expect(await sidebarMessages(page)).toEqual([]);
});

test("theater mode folds the shell's sidebar and gives it back", async ({ page }) => {
  const frame = await open(page);
  await frame.locator("#play").click();
  const player = page.getByTestId("custom-app-player");

  const theaterButton = player.getByRole("button", { name: "Theater", exact: true });
  await expect(theaterButton).toHaveAttribute("aria-pressed", "false");
  await theaterButton.click();
  await expect(player).toHaveAttribute("data-theater", "true");
  await expect(theaterButton).toHaveAttribute("aria-pressed", "true");
  await expect.poll(() => sidebarMessages(page)).toEqual([true]);
  await expect.poll(() => playerStates(page)).toContainEqual({ open: true, theater: true });

  // Esc leaves theater first, then closes the player.
  await page.locator("body").press("Escape");
  await expect(player).toHaveAttribute("data-theater", "false");
  await expect.poll(() => sidebarMessages(page)).toEqual([true, false]);
  await page.locator("body").press("Escape");
  await expect(player).toHaveCount(0);
});

test("an app can open the player straight into theater, and closing restores the sidebar", async ({ page }) => {
  const frame = await open(page);
  await frame.locator("#theater").click();
  const player = page.getByTestId("custom-app-player");
  await expect(player).toHaveAttribute("data-theater", "true");
  await expect.poll(() => sidebarMessages(page)).toEqual([true]);

  await player.getByRole("button", { name: /Close video player/ }).click();
  await expect(player).toHaveCount(0);
  await expect.poll(() => sidebarMessages(page)).toEqual([true, false]);
});

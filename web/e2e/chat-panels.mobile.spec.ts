import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test, type Page, type Route } from "@playwright/test";
import { routeCanvasPage } from "./mock-canvas-pages";
import { installChatApi } from "./mock-chat-api";

// VESPER-13 (project "mobile", 390×844): a chat's panels open as one full-height sheet over the
// chat, with a switch over the open ones, a close button, Escape and a drag down back to the chat.

const DOC = "11111111-1111-4111-8111-111111111111";
const PG = "01a1c6cb-986d-73de-b7f4-52e0cef03de9";
const GATEWAY = "http://localhost:8091";
const at = "2026-11-12T12:00:00Z";

const comment = { id: "k1", seq: 2, author_type: "user", body: "Say 60 days", anchor: { start: 0, end: 8, quote: "# Policy" }, target_lost: false, status: "open", created_at: at };
const playground = {
  id: PG, chat_id: "c", state: "running", step: "", action: null, port: 8091, branch: "feat/runner-settings",
  error: null, error_log: "", stop_reason: "", idle_ttl_seconds: 1800, started_at: at, data_reset_at: at, last_used_at: at, updated_at: at,
  processes: [{ name: "web", port: 3000 }], services: [], routes: [{ path: "/", process: "web" }], openapi: "",
};

async function open(page: Page) {
  const loads = { app: 0 };
  await installChatApi(page, { replyDelayMs: 10 });
  await page.route(/\/api\/v1\/chats\/[^/]+\/canvases(\/|\?|$)/, (route) => {
    const p = new URL(route.request().url()).pathname;
    const json = (data: unknown) => route.fulfill({ contentType: "application/json", body: JSON.stringify(data) });
    const summary = { id: DOC, kind: "text", title: "Retention policy", seq: 2, created_at: at, updated_at: at };
    if (p.endsWith("/comments")) return json({ comments: [comment] });
    if (p.endsWith("/canvases")) return json({ canvases: [summary] });
    return json({ ...summary, viewing_seq: 2, body: "# Policy\n\nArchive **after** 60 days.", versions: [{ seq: 2, note: "x", author_type: "agent", created_at: at }] });
  });
  await page.route(/\/api\/v1\/chats\/[^/]+\/playground(\/[a-z]+)?$/, (route) => route.fulfill({ contentType: "application/json", body: JSON.stringify({ playground, saved_spec: false }) }));
  await page.route(`${GATEWAY}/**`, (route) => {
    const url = new URL(route.request().url());
    if (url.pathname.startsWith("/__vesper/")) return route.fulfill({ status: 404, body: "" });
    loads.app++;
    return route.fulfill({ contentType: "text/html", body: "<!doctype html><title>Acme</title><h1>Acme Admin</h1>" });
  });
  await page.goto("/chat?project=WEB");
  return loads;
}

const send = async (page: Page, text: string) => {
  await page.getByRole("combobox", { name: "Message" }).fill(text);
  await page.getByRole("combobox", { name: "Message" }).press("Enter");
};

test("a canvas, then a playground, open in one sheet and switch without reloading", async ({ page }) => {
  const loads = await open(page);
  const sheet = page.getByTestId("panel-sheet");
  const tabs = sheet.getByRole("tablist", { name: "Panel" }).getByRole("tab");

  // The canvas card's Fullscreen opens the sheet over the whole chat area.
  await send(page, `canvas: ${DOC}`);
  await expect(page.getByTestId("canvas-panel")).toContainText("60 days.");
  await page.getByTestId("canvas-panel").getByRole("button", { name: "Fullscreen" }).click();
  await expect(sheet).toBeVisible();
  await expect(sheet).toHaveAttribute("data-panel", "canvas");
  await expect(sheet.getByTestId("canvas-fullscreen")).toContainText("60 days.");
  const box = (await sheet.boundingBox())!;
  expect(box.x).toBe(0);
  expect(box.width).toBe(390);
  expect(box.y).toBe(0);
  // Down to the tab bar, which stays below it.
  const tabBar = (await page.getByRole("navigation", { name: "Primary" }).boundingBox())!;
  expect(Math.abs(box.y + box.height - tabBar.y)).toBeLessThanOrEqual(1);
  await expect(tabs).toHaveText(["Canvas"]);
  expect(await page.evaluate(() => document.documentElement.scrollWidth)).toBe(390);
  // The bottom bar counts the canvas's comments; no design, so no Review.
  await expect(sheet.getByTestId("panel-sheet-bar").getByRole("button", { name: "Comments 1" })).toBeEnabled();
  await expect(sheet.getByRole("button", { name: /^Review/ })).toHaveCount(0);

  // The close button returns to the chat; the canvas stays open behind the header's Panels button.
  await sheet.getByRole("button", { name: "Close panels" }).click();
  await expect(sheet).toBeHidden();
  await expect(page.getByRole("button", { name: "Panels (open)" })).toBeVisible();

  // Opening the playground brings the sheet back, on the playground, with both in the switch.
  await send(page, `playground: ${PG}`);
  await page.getByTestId("playground-card").getByRole("button", { name: "Open" }).click();
  await expect(sheet).toHaveAttribute("data-panel", "playground");
  await expect(tabs).toHaveText(["Canvas", "Playground"]);
  await expect(page.frameLocator("[data-testid=playground-preview]").getByRole("heading", { name: "Acme Admin" })).toBeVisible();
  expect(loads.app).toBe(1);
  await expect(sheet.getByTestId("panel-sheet-bar")).toHaveCount(0);

  // Switching keeps both mounted: the canvas shows, and the playground doesn't load again.
  await tabs.filter({ hasText: "Canvas" }).click();
  await expect(sheet).toHaveAttribute("data-panel", "canvas");
  await expect(tabs.filter({ hasText: "Canvas" })).toHaveAttribute("aria-selected", "true");
  await expect(sheet.getByTestId("canvas-fullscreen")).toBeVisible();
  await expect(page.getByTestId("playground-panel")).toBeHidden();
  await tabs.filter({ hasText: "Playground" }).click();
  await expect(page.getByTestId("playground-panel")).toBeVisible();
  await expect(page.frameLocator("[data-testid=playground-preview]").getByRole("heading", { name: "Acme Admin" })).toBeVisible();
  expect(loads.app).toBe(1);
});

test("Escape and a drag down return to the chat; the Panels button reopens the sheet", async ({ page }) => {
  await open(page);
  const sheet = page.getByTestId("panel-sheet");
  await send(page, `canvas: ${DOC}`);
  await page.getByTestId("canvas-panel").getByRole("button", { name: "Fullscreen" }).click();
  await expect(sheet).toBeVisible();

  await page.keyboard.press("Escape");
  await expect(sheet).toBeHidden();
  const reopen = page.getByRole("button", { name: "Panels (open)" });
  await reopen.click();
  await expect(sheet).toBeVisible();
  await expect(sheet.getByTestId("canvas-fullscreen")).toContainText("60 days.");

  // A short drag snaps back; a long one closes it.
  const grab = (await sheet.getByTestId("panel-sheet-grabber").boundingBox())!;
  const drag = async (dy: number) => {
    await page.mouse.move(grab.x + 20, grab.y + 6);
    await page.mouse.down();
    await page.mouse.move(grab.x + 20, grab.y + 6 + dy, { steps: 8 });
    await page.mouse.up();
  };
  await drag(30);
  await expect(sheet).toBeVisible();
  await expect.poll(() => sheet.evaluate((e) => e.getBoundingClientRect().y)).toBe(0);
  await drag(400);
  await expect(sheet).toBeHidden();
  await expect(reopen).toBeVisible();
});

test("a design with pending suggestions has an amber Review button in the sheet's bottom bar", async ({ page }) => {
  const D = "44444444-4444-4444-8444-444444444444";
  const fixture = readFileSync(join(__dirname, "../../docs/design/fixtures/acceptance-design.json"), "utf8");
  const s = { created: false };
  const proposal = (id: string) => ({ id, agent_id: "a", base_seq: 1, summary: "Tighter header", ops: [], status: "pending", decisions: [], created_at: at });
  await installChatApi(page, { replyDelayMs: 10 });
  await routeCanvasPage(page, { id: D, kind: "design", title: "Onboarding" });
  const json = (route: Route, data: unknown) => route.fulfill({ contentType: "application/json", body: JSON.stringify(data) });
  await page.route(/\/api\/v1\/chats\/[^/]+\/canvases(\/|\?|$)/, (route) => json(route, { canvases: s.created ? [{ id: D, kind: "design", title: "Onboarding", seq: 1, created_at: at, updated_at: at }] : [] }));
  await page.route(/\/api\/v1\/designs\//, (route) => {
    const p = new URL(route.request().url()).pathname.replace(`/api/v1/designs/${D}`, "");
    if (p === "/versions/1") return json(route, { seq: 1, note: "", author_type: "agent", created_at: at, body: fixture });
    if (p === "/proposals") return json(route, { proposals: [proposal("p1"), proposal("p2")] });
    if (p === "/settings") return json(route, { direct_edit: false, persona_paused: false });
    if (p === "") return json(route, { id: D, kind: "design", title: "Onboarding", chat_id: "x", chat_title: "x", updated_at: at, reviewed_seq: 0, seq: 1, settings: { direct_edit: false, persona_paused: false }, pending_proposals: 2 });
    return route.fulfill({ status: 404, contentType: "application/json", body: '{"code":"not_found","message":"not found"}' });
  });
  await page.goto("/chat?project=WEB");
  await send(page, "Now sketch onboarding");
  await expect(page).toHaveURL(/\/chat\/[^/?]+/);
  // The persona's design_create opens it in the sheet by itself.
  s.created = true;
  await send(page, `canvas: ${D}`);
  const sheet = page.getByTestId("panel-sheet");
  await expect(sheet).toHaveAttribute("data-panel", "design");
  await expect(sheet.getByTestId("design-panel").getByRole("heading", { name: "Onboarding" })).toBeVisible();
  await expect(sheet.getByRole("tablist", { name: "Panel" }).getByRole("tab")).toHaveText(["Design"]);
  const review = sheet.getByTestId("panel-sheet-bar").getByRole("button", { name: "Review 2 suggestions" });
  await expect(review).toBeVisible();
  // Amber: the approve button's state-human fill.
  expect(await review.evaluate((el) => getComputedStyle(el).backgroundColor)).toBe(await page.evaluate(() => {
    const probe = document.createElement("i");
    probe.style.backgroundColor = "var(--state-human)";
    document.body.append(probe);
    const c = getComputedStyle(probe).backgroundColor;
    probe.remove();
    return c;
  }));
  await review.click();
  // The design opens as its page in Knowledge, still on review.
  await expect(page).toHaveURL(new RegExp(`/knowledge/[^?]+\\?review=1`));
  // The proposals are already cached from the sheet, yet the editor still opens on its Review tab (LAZYAGENTS-157).
  await expect(page.getByRole("dialog", { name: "Review" }).getByTestId("review-panel")).toBeVisible();
});

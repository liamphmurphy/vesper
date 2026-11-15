import { expect, test, type Page } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { installBoardApi } from "./mock-board-api";
import { installChatApi, openEmptyChat } from "./mock-chat-api";

type S = components["schemas"];
const inHours = (h: number) => new Date(Date.now() + h * 3_600_000).toISOString();

function harnesses(over: { claude?: Partial<S["HarnessActivity"]>; codex?: Partial<S["HarnessActivity"]>; agy?: Partial<S["HarnessActivity"]> } = {}): S["HarnessActivity"][] {
  return [
    { harness: "claude-code", label: "Claude", connected: true, running: 2, usage_available: true, usage_checking: false, usage_checked_at: new Date().toISOString(),
      windows: [{ id: "five_hour", kind: "session", label: "Session", used_percent: 42, resets_at: inHours(2) }, { id: "seven_day", kind: "weekly", label: "Weekly", used_percent: 68 }], ...over.claude },
    { harness: "codex", label: "Codex", connected: true, running: 1, usage_available: true, usage_checking: false, usage_checked_at: new Date().toISOString(),
      windows: [{ id: "codex_300", kind: "session", label: "Session", used_percent: 18, resets_at: inHours(3) }], ...over.codex },
    { harness: "antigravity", label: "Antigravity", connected: true, running: 0, usage_available: false, usage_checking: false, windows: [], ...over.agy },
  ];
}

async function installFooter(page: Page, state: { dock: S["PersonaDock"] }, expanded = true) {
  await installBoardApi(page);
  await page.addInitScript((expanded) => {
    if (!expanded) localStorage.setItem("lazyagents.column-collapsed", "1");
    const w = window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> };
    w.__sse = [];
    class FakeEventSource {
      onopen?: () => void;
      onmessage?: (e: { data: string }) => void;
      constructor() { w.__sse.push(this); setTimeout(() => this.onopen?.(), 0); }
      close() { w.__sse = w.__sse.filter((x) => x !== this); }
    }
    (window as unknown as { EventSource: unknown }).EventSource = FakeEventSource;
  }, expanded);
  await page.route("**/api/v1/persona-dock", (route) => route.fulfill({ json: state.dock }));
}

async function refresh(page: Page) {
  await page.evaluate(() => {
    const data = JSON.stringify({ type: "chat.updated", ids: [] });
    for (const s of (window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> }).__sse) s.onmessage?.({ data });
  });
}

const footer = (page: Page) => page.getByRole("region", { name: "Harness activity" });
const bubble = (page: Page, label: string) => page.getByRole("dialog", { name: `${label} usage` });

test("the permanent right rail holds the characters stacked above Customization and Settings", async ({ page }) => {
  await installFooter(page, { dock: { personas: [], space_chats: [], harnesses: harnesses() } });
  await page.goto("/board?project=WEB");
  await expect(footer(page).getByRole("button", { name: /show usage/ })).toHaveCount(3);
  // Only the characters: no "Harnesses · All idle" summary row under them.
  await expect(footer(page).getByRole("button")).toHaveCount(3);
  await expect(footer(page)).not.toContainText("Harnesses");
  await expect(page.locator(".orb-root")).toHaveCount(0);
  const menu = page.getByRole("complementary", { name: "Main menu" });
  await expect(menu.getByText("Liam", { exact: true })).toHaveCount(0);
  await expect(menu.getByRole("region", { name: "Harness activity" })).toHaveCount(0);
  const rail = page.getByRole("complementary", { name: "Right rail" });
  const settings = (await rail.getByRole("link", { name: "Settings", exact: true }).boundingBox())!;
  const customization = (await rail.getByRole("link", { name: "Customization", exact: true }).boundingBox())!;
  const bounds = (await rail.boundingBox())!;
  const bottom = (await footer(page).boundingBox())!;
  // The characters stack in the right rail above Customization and Settings, which close the rail.
  await expect(footer(page)).toHaveAttribute("data-rail", "true");
  expect(Math.abs(customization.x - settings.x)).toBeLessThan(2);
  expect(customization.y).toBeLessThan(settings.y);
  expect(bottom.y + bottom.height).toBeLessThanOrEqual(customization.y);
  expect(bounds.y + bounds.height - (settings.y + settings.height)).toBeLessThan(20);
  expect(await footer(page).evaluate((el) => getComputedStyle(el).borderRadius)).toBe("0px");
});

test("only connected harnesses show, and the row fits however many there are", async ({ page }) => {
  const state = { dock: { personas: [], space_chats: [], harnesses: harnesses({ claude: { running: 0 }, codex: { connected: false, running: 0 }, agy: { connected: false } }) } };
  await installFooter(page, state);
  await page.goto("/board?project=WEB");
  const buttons = footer(page).getByRole("button", { name: /show usage/ });
  await expect(buttons).toHaveCount(1);
  await expect(buttons.first()).toHaveAccessibleName("Claude, idle; show usage");
  // A lone character sits in the middle of the footer rather than at one edge.
  const centre = async (box: { x: number; width: number } | null) => box!.x + box!.width / 2;
  expect(Math.abs(await centre(await buttons.first().boundingBox()) - await centre(await footer(page).boundingBox()))).toBeLessThan(2);
  state.dock.harnesses = harnesses({ agy: { connected: false } });
  await refresh(page);
  await expect(buttons).toHaveCount(2);
  await expect(footer(page).getByRole("button", { name: /Antigravity/ })).toHaveCount(0);
  // A harness still working stays visible after its key is removed.
  state.dock.harnesses = harnesses({ codex: { connected: false }, agy: { connected: false } });
  await refresh(page);
  await expect(footer(page).getByRole("button", { name: "Codex, working; show usage" })).toBeVisible();
  state.dock.harnesses = harnesses({ claude: { connected: false, running: 0 }, codex: { connected: false, running: 0 }, agy: { connected: false } });
  await refresh(page);
  await expect(footer(page)).toHaveCount(0);
});

test("a character opens a bubble with its own usage to its left; Escape restores focus", async ({ page }) => {
  await installFooter(page, { dock: { personas: [], space_chats: [], harnesses: harnesses() } });
  await page.goto("/board?project=WEB");
  const trigger = footer(page).getByRole("button", { name: "Codex, working; show usage" });
  await trigger.click();
  const codex = bubble(page, "Codex");
  await expect(codex).toBeVisible();
  await expect(codex.getByRole("progressbar", { name: "Codex allowance used" })).toHaveAttribute("aria-valuenow", "18");
  await expect(codex).toContainText("1 working");
  await expect(codex).toContainText(/5h · resets/);
  await expect(codex.getByRole("progressbar", { name: "Claude allowance used" })).toHaveCount(0);
  await expect(codex.getByRole("link", { name: "Usage settings →" })).toHaveAttribute("href", "/settings/runner");
  // A bubble, not a panel: small, and sitting beside the right-rail character to its left.
  await expect.poll(async () => (await codex.boundingBox())!.height).toBeLessThan(200);
  const at = (await trigger.boundingBox())!, box = (await codex.boundingBox())!;
  expect(box.width).toBeLessThan(260);
  expect(box.x + box.width).toBeLessThanOrEqual(at.x);
  expect(at.x - (box.x + box.width)).toBeLessThan(20);
  expect(box.y).toBeLessThan(at.y + at.height);
  expect(box.y + box.height).toBeGreaterThan(at.y);
  await page.keyboard.press("Escape");
  await expect(codex).toBeHidden();
  await expect(trigger).toBeFocused();
  // Another character swaps the bubble; clicking away closes it.
  await trigger.click();
  await footer(page).getByRole("button", { name: /Claude, working/ }).click();
  await expect(codex).toBeHidden();
  await expect(bubble(page, "Claude").getByRole("progressbar", { name: "Claude allowance used" })).toHaveAttribute("aria-valuenow", "42");
  await expect(bubble(page, "Claude")).toContainText("weekly 68%");
  await footer(page).getByRole("button", { name: /Antigravity, idle/ }).click();
  await expect(bubble(page, "Claude")).toBeHidden();
  await expect(bubble(page, "Antigravity")).toContainText("Antigravity doesn’t report an allowance");
  await page.mouse.click(1000, 70);
  await expect(bubble(page, "Antigravity")).toBeHidden();
});

test("working follows live harness activity; the approved characters idle at rest", async ({ page }) => {
  const state = { dock: { personas: [], space_chats: [], harnesses: harnesses({ claude: { running: 0 }, codex: { running: 0 } }) } };
  await installFooter(page, state);
  await page.goto("/board?project=WEB");
  const body = (kind: string) => footer(page).locator(`.harness-character.${kind} .body`);
  await expect(body("robot")).toHaveCSS("animation-name", "harness-breathe");
  await expect(body("comet")).toHaveCSS("animation-name", "harness-float");
  await expect(body("jet")).toHaveCSS("animation-name", "harness-float");
  state.dock.harnesses = harnesses({ agy: { running: 1 } });
  await refresh(page);
  await expect(body("robot")).toHaveCSS("animation-name", "harness-tap");
  await expect(body("comet")).toHaveCSS("animation-name", "harness-comet");
  await expect(body("jet")).toHaveCSS("animation-name", "harness-boost");
  state.dock.harnesses = harnesses({ codex: { limited_until: inHours(1) } });
  await refresh(page);
  await expect(footer(page).getByRole("button", { name: "Codex, limited; show usage" })).toBeVisible();
  await expect(body("comet")).toHaveCSS("animation-name", "harness-float");
});

test("zero, unavailable, checking, warning and limited readings stay distinct", async ({ page }) => {
  const state = { dock: { personas: [], space_chats: [], harnesses: harnesses({ claude: { windows: [{ id: "s", kind: "session" as const, label: "Session", used_percent: 0 }], usage_checking: true }, codex: { usage_available: false, usage_checking: true, windows: [] } }) } };
  await installFooter(page, state);
  await page.goto("/board?project=WEB");
  const claude = bubble(page, "Claude").locator('[data-harness="claude-code"].harness-usage-row');
  const codex = bubble(page, "Codex").locator('[data-harness="codex"].harness-usage-row');
  await footer(page).getByRole("button", { name: /Claude, working/ }).click();
  await expect(claude).toContainText("0%");
  await expect(claude.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "0");
  await footer(page).getByRole("button", { name: /Codex, working/ }).click();
  await expect(codex).toContainText("Checking usage…");
  await expect(codex.getByRole("progressbar")).toHaveCount(0);
  await expect(codex.locator(".harness-usage-track")).toHaveAttribute("data-unavailable", "true");
  state.dock.harnesses = harnesses({ claude: { usage_checking: true, windows: [{ id: "s", kind: "session", label: "Session", used_percent: 86 }] }, codex: { limited_until: inHours(1) } });
  await refresh(page);
  await expect(codex).toHaveAttribute("data-tone", "limited");
  await expect(codex).toContainText("100%");
  await expect(codex).toContainText(/Limited until .*falls back to Claude/);
  await footer(page).getByRole("button", { name: /Claude, working/ }).click();
  await expect(claude).toContainText("86%");
  await expect(claude).toHaveAttribute("data-tone", "warn");
});

test("on a short window the bubble still opens to the left, inside the viewport", async ({ page }) => {
  await page.setViewportSize({ width: 1100, height: 650 });
  await installFooter(page, { dock: { personas: [], space_chats: [], harnesses: harnesses({ claude: { running: 0 }, codex: { running: 0 } }) } }, false);
  await page.goto("/board?project=WEB");
  await expect(footer(page)).toHaveAttribute("data-rail", "true");
  await expect(footer(page).getByRole("button", { name: /show usage/ })).toHaveCount(3);
  await expect(footer(page).locator(".harness-character").first()).toHaveCSS("width", "24px");
  const trigger = footer(page).getByRole("button", { name: /Antigravity, idle/ });
  await trigger.click();
  const agy = bubble(page, "Antigravity");
  await expect(agy).toBeVisible();
  await expect(agy.getByRole("progressbar")).toHaveCount(0);
  const at = (await trigger.boundingBox())!;
  await expect.poll(async () => {
    const b = await agy.boundingBox();
    return b ? b.x + b.width : Infinity;
  }).toBeLessThanOrEqual(at.x);
  const bounds = (await agy.boundingBox())!;
  expect(at.x - (bounds.x + bounds.width)).toBeLessThan(20);
  expect(bounds.x).toBeGreaterThanOrEqual(7);
  expect(bounds.y).toBeGreaterThanOrEqual(7);
  expect(bounds.y + bounds.height).toBeLessThanOrEqual(643);
  await page.keyboard.press("Escape");
  await expect(agy).toBeHidden();
});

test("reduced motion holds all three characters still and opens the bubble without animation", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await installFooter(page, { dock: { personas: [], space_chats: [], harnesses: harnesses({ agy: { running: 1 } }) } });
  await page.goto("/board?project=WEB");
  // evaluateAll does not wait, so let the dock's data reach the footer first.
  await expect(footer(page).getByRole("button", { name: /Antigravity, working/ })).toBeVisible();
  const animations = await footer(page).locator(".harness-character svg *").evaluateAll((els) => els.map((e) => getComputedStyle(e).animationName));
  expect(animations.length).toBeGreaterThan(0);
  expect(new Set(animations)).toEqual(new Set(["none"]));
  await footer(page).getByRole("button", { name: /Antigravity, working/ }).click();
  await expect(bubble(page, "Antigravity")).toHaveCSS("animation-name", "none");
});

for (const [width, showHarnessActivity] of [[1280, true], [1280, false], [390, false]] as const) {
  test(`the visible chat is marked read at ${width}px with the footer ${showHarnessActivity ? "on" : "off"}`, async ({ page }) => {
    await page.setViewportSize({ width, height: 844 });
    await page.addInitScript((showHarnessActivity) => localStorage.setItem("la-appearance", JSON.stringify({ version: 1, palette: "dusk", showHarnessActivity })), showHarnessActivity);
    await installChatApi(page);
    const id = await openEmptyChat(page);
    const chat: S["PersonaDockChat"] = { id, title: "Read tracking", state: "replied", harness: "codex", unread: 1, last_line: "A reply", last_seq: 3, waiting_approval: false, last_activity_at: new Date().toISOString() };
    const state: S["PersonaDock"] = { personas: [{ persona: { id: "00000000-0000-4000-8000-000000000001", name: "Assistant", color: "#9fd8c4" }, state: "replied", unread: 1, last_activity_at: chat.last_activity_at, chats: [chat] }], space_chats: [], harnesses: [] };
    const reads: number[] = [];
    await page.route("**/api/v1/persona-dock", (route) => route.fulfill({ json: state }));
    await page.route(`**/api/v1/chats/${id}/read`, (route) => {
      reads.push(route.request().postDataJSON().seq);
      chat.unread = 0;
      return route.fulfill({ status: 204 });
    });
    await refresh(page);
    await expect.poll(() => reads).toContain(3);
    chat.unread = 1;
    chat.last_seq = 4;
    await refresh(page);
    await expect.poll(() => reads).toContain(4);
  });
}

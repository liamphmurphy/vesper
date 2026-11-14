import { expect, test, type Page } from "@playwright/test";
import { routeCanvasPage } from "./mock-canvas-pages";
import { installChatApi } from "./mock-chat-api";

// Slides toolbar controls (LAZYAGENTS-114): custom colours with recent
// colours, and line arrowheads, each one undo step that autosaves and reopens.

const DECK = "88888888-8888-4888-8888-888888888888";
const at = "2026-11-11T12:00:00Z";

const deck = {
  schema: 1,
  size: { w: 1920, h: 1080 },
  theme: { name: "Light", fonts: { heading: "sans", body: "sans" }, colors: { background: "#FFFFFF", text: "#1F2328", heading: "#111418", accent: "#3B6FE0", accent2: "#E8A33D", muted: "#6B7280", surface: "#F3F5F9" } },
  assets: {},
  slides: [
    {
      id: "s_one",
      layout: "blank",
      elements: [
        { id: "e_box", type: "shape", shape: "rect", frame: { x: 200, y: 160, w: 400, h: 300 }, fill: "accent" },
        { id: "e_line", type: "line", frame: { x: 200, y: 800, w: 1200, h: 0 }, stroke: "text", strokeWidth: 6 },
      ],
    },
  ],
};

type Version = { seq: number; body: string };

async function install(page: Page) {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/slides");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const chatId = chat.id as string;
  const s = { versions: [{ seq: 1, body: JSON.stringify(deck) }] as Version[], saves: [] as { base_seq: number; body: string }[] };
  const head = () => s.versions[s.versions.length - 1];
  const json = (route: Parameters<Parameters<Page["route"]>[1]>[0], data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  await page.route(new RegExp(`/api/v1/canvases/${DECK}$`), (route) => json(route, { id: DECK, kind: "deck", title: "Controls", chat_id: chatId, chat_title: "Controls", updated_at: at, reviewed_seq: 0 }));
  await page.route(new RegExp(`/api/v1/chats/[^/]+/canvases/${DECK}(/|\\?|$)`), (route) => {
    const req = route.request();
    const p = new URL(req.url()).pathname;
    if (p.endsWith("/comments")) return json(route, { comments: [] });
    if (p.endsWith("/versions")) {
      const body = req.postDataJSON();
      s.saves.push(body);
      if (body.base_seq !== head().seq) return json(route, { code: "conflict", message: "conflict" }, 409);
      s.versions.push({ seq: head().seq + 1, body: body.body });
      return json(route, { seq: head().seq, note: "Edited", author_type: "user", created_at: at }, 201);
    }
    return json(route, {
      id: DECK, kind: "deck", title: "Controls", seq: head().seq, viewing_seq: head().seq, created_at: at, updated_at: at, body: head().body,
      versions: [...s.versions].reverse().map((v) => ({ seq: v.seq, note: "Edited", author_type: "user", created_at: at })),
    });
  });
  await routeCanvasPage(page, { id: DECK, kind: "deck", title: "Deck" });
  await page.goto(`/apps/slides/${DECK}`);
  const saved = () => JSON.parse(head().body) as { slides: { elements: Record<string, unknown>[] }[] };
  const element = (id: string) => saved().slides[0].elements.find((e) => e.id === id)!;
  return { s, element };
}

const toolbar = (page: Page) => page.getByRole("toolbar", { name: "Slide formatting" });
const select = (page: Page, id: string) => page.locator(`[data-element="${id}"]`).click();

test("any hex colour applies, is refused when malformed, and becomes a recent colour", async ({ page }) => {
  const { element } = await install(page);
  await select(page, "e_box");

  await toolbar(page).getByRole("button", { name: "Fill" }).click();
  await page.getByRole("menuitem", { name: "Custom colour…" }).click();
  const hex = page.getByRole("textbox", { name: "Fill: custom hex" });
  await expect(hex).toBeFocused();
  await hex.fill("blue");
  await hex.press("Enter");
  await expect(page.getByRole("alert").filter({ hasText: "#RRGGBB" })).toBeVisible();
  await hex.fill("#c2410c");
  await hex.press("Enter");
  await expect(page.getByRole("menu")).toHaveCount(0);

  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v2/, { timeout: 5000 });
  expect(element("e_box").fill).toBe("#C2410C");

  // The colour is offered again in every colour menu, newest first.
  await toolbar(page).getByRole("button", { name: "Outline", exact: true }).click();
  await page.getByRole("menuitem", { name: "Recent colour #C2410C" }).click();
  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v3/, { timeout: 5000 });
  expect(element("e_box").stroke).toBe("#C2410C");

  // One undo step per change.
  await toolbar(page).getByRole("button", { name: "Undo" }).click();
  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v4/, { timeout: 5000 });
  expect(element("e_box").stroke).toBeUndefined();
  expect(element("e_box").fill).toBe("#C2410C");

  // Recent colours are kept for this deck across reopening.
  await page.reload();
  await select(page, "e_line");
  await toolbar(page).getByRole("button", { name: "Line colour" }).click();
  await expect(page.getByRole("menuitem", { name: "Recent colour #C2410C" })).toBeVisible();
});

test("line arrowheads toggle, undo one at a time and survive reopening", async ({ page }) => {
  const { element } = await install(page);
  await select(page, "e_line");
  const end = toolbar(page).getByRole("button", { name: "End arrowhead" });
  const start = toolbar(page).getByRole("button", { name: "Start arrowhead" });
  await expect(end).toHaveAttribute("aria-pressed", "false");

  await end.click();
  await start.click();
  await expect(end).toHaveAttribute("aria-pressed", "true");
  await expect(start).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByRole("group", { name: /Slide canvas/ }).locator("svg line[marker-start][marker-end]")).toHaveCount(1);

  await toolbar(page).getByRole("button", { name: "Undo" }).click();
  await expect(start).toHaveAttribute("aria-pressed", "false");
  await expect(end).toHaveAttribute("aria-pressed", "true");
  await expect(page.getByTestId("deck-save-state")).toHaveText(/^Saved/, { timeout: 5000 });
  await expect.poll(() => element("e_line").endArrow).toBe(true);
  expect(element("e_line").startArrow).toBeUndefined();

  await page.reload();
  await select(page, "e_line");
  await expect(toolbar(page).getByRole("button", { name: "End arrowhead" })).toHaveAttribute("aria-pressed", "true");
  await expect(toolbar(page).getByRole("button", { name: "Start arrowhead" })).toHaveAttribute("aria-pressed", "false");
});

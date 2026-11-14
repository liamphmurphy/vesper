import { expect, test, type Page } from "@playwright/test";
import { routeCanvasPage } from "./mock-canvas-pages";
import { THEMES, type Deck, type Element } from "../lib/slides/schema";
import { installChatApi } from "./mock-chat-api";

// Arranging on a slide (LAZYAGENTS-115): multi-select by Shift-click and
// marquee, align and distribute, z-order, duplicate, nudge and snap guides.
// Each operation saves the deck; the spec reads the saved bodies.

const DECK = "88888888-8888-4888-8888-888888888888";
const at = "2026-11-11T12:00:00Z";

const shape = (id: string, x: number, y: number, w: number, h: number): Element => ({ id, type: "shape", shape: "rect", frame: { x, y, w, h }, fill: "accent" });
const deck: Deck = {
  schema: 1,
  size: { w: 1920, h: 1080 },
  theme: THEMES.light,
  assets: {},
  slides: [{ id: "s_one", layout: "blank", elements: [shape("e_a", 100, 100, 200, 200), shape("e_b", 600, 300, 200, 200), shape("e_c", 1200, 500, 300, 100)] }],
};

async function install(page: Page) {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/slides");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const chatId = chat.id as string;
  const versions = [{ seq: 1, author_type: "user", note: "", body: JSON.stringify(deck) }];
  const head = () => versions[versions.length - 1];
  const ref = { id: DECK, kind: "deck", title: "Arrange", chat_id: chatId, chat_title: "Arrange", updated_at: at, reviewed_seq: 1 };
  await page.route(/\/api\/v1\/canvases(\/|$)/, (route) => route.fulfill({ contentType: "application/json", body: JSON.stringify(new URL(route.request().url()).pathname.endsWith(DECK) ? ref : { canvases: [ref] }) }));
  await page.route(/\/api\/v1\/chats\/[^/]+\/canvases\//, (route) => {
    const req = route.request();
    const u = new URL(req.url());
    const json = (data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
    if (u.pathname.endsWith("/comments")) return json({ comments: [] });
    if (u.pathname.endsWith("/versions")) {
      const body = req.postDataJSON();
      if (body.base_seq !== head().seq) return json({ code: "conflict", message: "conflict" }, 409);
      versions.push({ seq: head().seq + 1, author_type: "user", note: body.note ?? "", body: body.body });
      return json({ seq: head().seq, note: body.note ?? "", author_type: "user", created_at: at }, 201);
    }
    const want = Number(u.searchParams.get("seq")) || head().seq;
    const v = versions.find((x) => x.seq === want)!;
    return json({ id: DECK, kind: "deck", title: "Arrange", seq: head().seq, viewing_seq: v.seq, created_at: at, updated_at: at, body: v.body, versions: [...versions].reverse().map((x) => ({ seq: x.seq, note: x.note, author_type: x.author_type, created_at: at })) });
  });
  await routeCanvasPage(page, { id: DECK, kind: "deck", title: "Deck" });
  await page.goto(`/apps/slides/${DECK}`);
  await expect(page.locator('[data-element="e_c"]')).toBeVisible();
  /** The elements of the last saved version. */
  const saved = () => (JSON.parse(head().body) as Deck).slides[0].elements;
  return { saved, savedCount: () => versions.length };
}

const canvas = (page: Page) => page.getByRole("group", { name: /Slide canvas/ });
const el = (page: Page, id: string) => page.locator(`[data-element="${id}"]`);
const order = (els: Element[]) => els.map((e) => e.id).join(",");
const frames = (els: Element[]) => Object.fromEntries(els.map((e) => [e.id, e.frame]));

/** Screen coordinates of a point in slide units. */
async function point(page: Page, x: number, y: number) {
  const b = (await canvas(page).boundingBox())!;
  return { x: b.x + (x * b.width) / 1920, y: b.y + (y * b.height) / 1080 };
}

test("Shift-click selects several elements, which align and distribute in one undo step each", async ({ page }) => {
  const { saved } = await install(page);
  await el(page, "e_a").click();
  await el(page, "e_b").click({ modifiers: ["Shift"] });
  await el(page, "e_c").click({ modifiers: ["Shift"] });
  await expect(page.getByTestId("slide-selection-group")).toContainText("3 elements");
  await expect(page.getByRole("button", { name: "Delete 3 elements" })).toBeVisible();

  await page.getByRole("button", { name: "Arrange" }).click();
  await page.getByRole("menuitem", { name: "Align top" }).click();
  await expect.poll(() => saved().map((e) => e.frame.y)).toEqual([100, 100, 100]);

  await page.getByRole("button", { name: "Arrange" }).click();
  await page.getByRole("menuitem", { name: "Distribute horizontally" }).click();
  // 100…1500 with 700 of boxes: gaps of 350, so B starts at 650.
  await expect.poll(() => saved().map((e) => e.frame.x)).toEqual([100, 650, 1200]);

  // Undo takes back only the distribute.
  await page.keyboard.press("Control+z");
  await expect.poll(() => saved().map((e) => e.frame.x)).toEqual([100, 600, 1200]);
  expect(saved().map((e) => e.frame.y)).toEqual([100, 100, 100]);

  // Shift-click again takes one out.
  await el(page, "e_c").click({ modifiers: ["Shift"] });
  await expect(page.getByTestId("slide-selection-group")).toContainText("2 elements");
});

test("a marquee selects what it covers; z-order, duplicate and nudge work from the keyboard and the menu", async ({ page }) => {
  const { saved } = await install(page);
  // Drag from empty canvas around A and B, not C.
  const from = await point(page, 50, 50), to = await point(page, 850, 550);
  await page.mouse.move(from.x, from.y);
  await page.mouse.down();
  await page.mouse.move((from.x + to.x) / 2, (from.y + to.y) / 2);
  await expect(page.getByTestId("slide-marquee")).toBeVisible();
  await page.mouse.move(to.x, to.y);
  await page.mouse.up();
  await expect(page.getByTestId("slide-selection-group")).toContainText("2 elements");
  await expect(canvas(page)).toBeFocused();

  // ⌥⌘] brings the pair to the front, keeping their order.
  await page.keyboard.press("Control+Alt+BracketRight");
  await expect.poll(() => order(saved())).toBe("e_c,e_a,e_b");
  // ⌘[ sends them back one step.
  await page.keyboard.press("Control+BracketLeft");
  await expect.poll(() => order(saved())).toBe("e_a,e_b,e_c");

  // One element from the menu: Bring to front, then Send backward.
  await el(page, "e_a").click();
  await page.getByRole("button", { name: "Arrange" }).click();
  await page.getByRole("menuitem", { name: "Bring to front" }).click();
  await expect.poll(() => order(saved())).toBe("e_b,e_c,e_a");
  await page.getByRole("button", { name: "Arrange" }).click();
  await page.getByRole("menuitem", { name: "Send backward" }).click();
  await expect.poll(() => order(saved())).toBe("e_b,e_a,e_c");
  // Aligned to the slide when one element is selected.
  await page.getByRole("button", { name: "Arrange" }).click();
  await page.getByRole("menuitem", { name: "Align centre" }).click();
  await expect.poll(() => frames(saved()).e_a.x).toBe(860);

  // Arrow keys nudge by 1 px, Shift by 10.
  await canvas(page).focus();
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("Shift+ArrowDown");
  await expect.poll(() => frames(saved()).e_a).toEqual({ x: 861, y: 110, w: 200, h: 200 });

  // ⌘D duplicates with a fresh id, 40 px down and right, just above the original.
  await page.keyboard.press("Control+d");
  await expect.poll(() => saved().length).toBe(4);
  const els = saved();
  const copy = els[2];
  expect(copy.id).toMatch(/^e_[a-z2-7]{10}$/);
  expect(copy.frame).toEqual({ x: 901, y: 150, w: 200, h: 200 });
  expect(order(els)).toBe(`e_b,e_a,${copy.id},e_c`);

  // ⌘A then Delete removes everything.
  await page.keyboard.press("Control+a");
  await expect(page.getByTestId("slide-selection-group")).toContainText("4 elements");
  await page.keyboard.press("Delete");
  await expect.poll(() => saved().length).toBe(0);
});

test("dragging snaps to the slide's centre line with a visible guide; ⌘/Ctrl places freely", async ({ page }) => {
  const { saved } = await install(page);
  // A is 200 wide at x 100: its centre at 200. Move it by 755 → centre 955, 5 short of 960.
  const start = await point(page, 200, 200), end = await point(page, 955, 200);
  await page.mouse.move(start.x, start.y);
  await page.mouse.down();
  await page.mouse.move((start.x + end.x) / 2, end.y, { steps: 4 });
  await page.mouse.move(end.x, end.y, { steps: 4 });
  await expect(page.getByTestId("slide-snap-guides")).toBeVisible();
  await page.mouse.up();
  await expect(page.getByTestId("slide-snap-guides")).toHaveCount(0);
  await expect.poll(() => frames(saved()).e_a.x).toBe(860);

  // Holding Ctrl: no snapping, so it lands where it was dropped (give or take a pixel of scaling).
  const s2 = await point(page, 960, 200), e2 = await point(page, 955, 400);
  // Ctrl goes down after the press: a Ctrl-click itself toggles the selection.
  await page.mouse.move(s2.x, s2.y);
  await page.mouse.down();
  await page.keyboard.down("Control");
  await page.mouse.move(e2.x, e2.y, { steps: 4 });
  await expect(page.getByTestId("slide-snap-guides")).toHaveCount(0);
  await page.mouse.up();
  await page.keyboard.up("Control");
  await expect.poll(() => Math.abs(frames(saved()).e_a.x - 855) <= 2).toBe(true);
});

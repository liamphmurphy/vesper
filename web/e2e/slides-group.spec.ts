import { expect, test, type Page } from "@playwright/test";
import { routeCanvasPage } from "./mock-canvas-pages";
import { THEMES, type Deck, type Element, type GroupElement } from "../lib/slides/schema";
import { installChatApi } from "./mock-chat-api";

// Grouping on a slide (LAZYAGENTS-116): ⌘G groups the selection, ⇧⌘G
// ungroups it, resizing a group scales its elements, and double-clicking a
// group enters it to select one of them. Each operation saves the deck; the
// spec reads the saved bodies.

const DECK = "88888888-8888-4888-8888-888888888888";
const at = "2026-11-11T12:00:00Z";

const shape = (id: string, x: number, y: number, w: number, h: number): Element => ({ id, type: "shape", shape: "rect", frame: { x, y, w, h }, fill: "accent" });
const deck: Deck = {
  schema: 1,
  size: { w: 1920, h: 1080 },
  theme: THEMES.light,
  assets: {},
  slides: [{ id: "s_one", layout: "blank", elements: [shape("e_a", 100, 100, 200, 200), { ...shape("e_b", 600, 300, 200, 200), rotation: 15 } as Element, shape("e_c", 1200, 700, 300, 100)] }],
};

async function install(page: Page) {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/slides");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const chatId = chat.id as string;
  const versions = [{ seq: 1, author_type: "user", note: "", body: JSON.stringify(deck) }];
  const head = () => versions[versions.length - 1];
  const ref = { id: DECK, kind: "deck", title: "Groups", chat_id: chatId, chat_title: "Groups", updated_at: at, reviewed_seq: 1 };
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
    return json({ id: DECK, kind: "deck", title: "Groups", seq: head().seq, viewing_seq: v.seq, created_at: at, updated_at: at, body: v.body, versions: [...versions].reverse().map((x) => ({ seq: x.seq, note: x.note, author_type: x.author_type, created_at: at })) });
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

const near = (a: number, b: number) => Math.abs(a - b) <= 3;

/** Screen coordinates of a point in slide units. */
async function point(page: Page, x: number, y: number) {
  const b = (await canvas(page).boundingBox())!;
  return { x: b.x + (x * b.width) / 1920, y: b.y + (y * b.height) / 1080 };
}

test("⌘G groups the selection and ⇧⌘G ungroups it without moving anything", async ({ page }) => {
  const { saved } = await install(page);
  const before = saved();
  await el(page, "e_a").click();
  await el(page, "e_b").click({ modifiers: ["Shift"] });
  await page.keyboard.press("Control+g");
  await expect.poll(() => saved().length).toBe(2);
  const g = saved()[0] as GroupElement;
  expect(g.type).toBe("group");
  expect(order(g.elements)).toBe("e_a,e_b");
  expect(g.frame).toEqual({ x: 100, y: 100, w: 700, h: 400 });
  await expect(page.getByText("Group · 2", { exact: true })).toBeVisible();

  await page.keyboard.press("Control+Shift+g");
  await expect.poll(() => order(saved())).toBe("e_a,e_b,e_c");
  expect(saved()).toEqual(before);

  // The Arrange menu does the same.
  await page.getByRole("button", { name: "Arrange" }).click();
  await page.getByRole("menuitem", { name: /^Group/ }).click();
  await expect.poll(() => saved()[0].type).toBe("group");
});

test("resizing a group scales its elements; double-clicking enters it to select one", async ({ page }) => {
  const { saved } = await install(page);
  await el(page, "e_a").click();
  await el(page, "e_b").click({ modifiers: ["Shift"] });
  await page.keyboard.press("Control+g");
  await expect.poll(() => saved()[0].type).toBe("group");

  // Drag the bottom-right handle from (800, 500) to (1500, 900): twice as wide and high. Ctrl places freely.
  const h = page.locator('[data-handle="se"]');
  const hb = (await h.boundingBox())!;
  const end = await point(page, 1500, 900);
  await page.mouse.move(hb.x + hb.width / 2, hb.y + hb.height / 2);
  await page.mouse.down();
  await page.keyboard.down("Control");
  await page.mouse.move(end.x, end.y, { steps: 6 });
  await page.mouse.up();
  await page.keyboard.up("Control");
  await expect.poll(() => near((saved()[0] as GroupElement).frame.w, 1400)).toBe(true);
  const [a, b] = (saved()[0] as GroupElement).elements;
  expect(near(a.frame.x, 100) && near(a.frame.w, 400) && near(a.frame.h, 400)).toBe(true);
  expect(near(b.frame.x, 1100) && near(b.frame.y, 500) && near(b.frame.w, 400)).toBe(true);
  expect(b.rotation).toBe(15);

  // Double-click A's middle: into the group with A selected; Delete takes it out and the group dissolves.
  const p = await point(page, a.frame.x + a.frame.w / 2, a.frame.y + a.frame.h / 2);
  await page.mouse.dblclick(p.x, p.y);
  await expect(page.getByTestId("slide-entered-group")).toBeVisible();
  await expect(page.getByText("Shape · rect selected in a group")).toBeAttached();
  await page.keyboard.press("Delete");
  await expect.poll(() => order(saved())).toBe("e_b,e_c");
  await expect(page.getByTestId("slide-entered-group")).toHaveCount(0);
});

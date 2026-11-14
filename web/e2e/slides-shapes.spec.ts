import { expect, test, type Page } from "@playwright/test";
import { routeCanvasPage } from "./mock-canvas-pages";
import { installChatApi } from "./mock-chat-api";

// The Slides toolbar's shape grid picker (LAZYAGENTS-117): search, keyboard
// navigation and inserting a preset shape that holds text.

const DECK = "88888888-8888-4888-8888-888888888888";
const at = "2026-11-11T12:00:00Z";
const theme = { name: "Light", fonts: { heading: "sans", body: "sans" }, colors: { background: "#FFFFFF", text: "#1F2328", heading: "#111418", accent: "#3B6FE0", accent2: "#E8A33D", muted: "#6B7280", surface: "#F3F5F9" } };
const deck = { schema: 1, size: { w: 1920, h: 1080 }, theme, assets: {}, slides: [{ id: "s_one", layout: "blank", elements: [] }] };

async function install(page: Page) {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/slides");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const chatId = chat.id as string;
  const versions = [{ seq: 1, author_type: "user", note: "", body: JSON.stringify(deck) }];
  const saves: { base_seq: number; body: string }[] = [];
  const head = () => versions[versions.length - 1];
  const ref = { id: DECK, kind: "deck", title: "Shapes", chat_id: chatId, chat_title: "Shapes", updated_at: at, reviewed_seq: 1 };
  await page.route(/\/api\/v1\/canvases\//, (route) => route.fulfill({ contentType: "application/json", body: JSON.stringify(ref) }));
  await page.route(/\/api\/v1\/chats\/[^/]+\/canvases\//, (route) => {
    const req = route.request();
    const p = new URL(req.url()).pathname;
    const json = (data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
    if (p.endsWith("/versions")) {
      const body = req.postDataJSON();
      saves.push(body);
      versions.push({ seq: head().seq + 1, author_type: "user", note: body.note ?? "", body: body.body });
      return json({ seq: head().seq, note: "", author_type: "user", created_at: at }, 201);
    }
    if (p.endsWith("/comments")) return json({ comments: [] });
    if (p.endsWith("/reviewed")) return json({ reviewed_seq: head().seq });
    return json({ id: DECK, kind: "deck", title: "Shapes", seq: head().seq, viewing_seq: head().seq, created_at: at, updated_at: at, body: head().body, versions: [...versions].reverse().map((v) => ({ seq: v.seq, note: v.note, author_type: v.author_type, created_at: at })) });
  });
  await routeCanvasPage(page, { id: DECK, kind: "deck", title: "Deck" });
  await page.goto(`/apps/slides/${DECK}`);
  return { saves };
}

test("the shape grid filters, moves by keyboard and inserts a preset shape", async ({ page }) => {
  const { saves } = await install(page);
  await page.getByRole("button", { name: "Insert shape" }).click();
  const grid = page.getByRole("grid", { name: "Shapes" });
  await expect(grid.getByRole("gridcell")).toHaveCount(21);
  for (const c of ["Basics", "Arrows & flow", "Callouts", "Accents"]) await expect(grid.getByRole("rowgroup", { name: c })).toBeVisible();
  await page.screenshot({ path: test.info().outputPath("picker.png") });

  // Search keeps focus in the box and hides empty categories.
  const search = page.getByRole("searchbox", { name: "Search shapes" });
  await expect(search).toBeFocused();
  await search.fill("arrow");
  await expect(grid.getByRole("gridcell")).toHaveCount(6); // the whole Arrows & flow category
  await expect(grid.getByRole("rowgroup", { name: "Basics" })).toHaveCount(0);

  // ↓ enters the grid, → moves along it, ↑ from the first row returns to search.
  await search.press("ArrowDown");
  await expect(grid.getByRole("gridcell", { name: "Right arrow" })).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(grid.getByRole("gridcell", { name: "Left arrow" })).toBeFocused();
  await page.keyboard.press("ArrowUp");
  await expect(search).toBeFocused();

  // ↓ and ↑ keep the column across rows and categories.
  await search.fill("");
  await search.press("ArrowDown");
  await page.keyboard.press("ArrowRight");
  await page.keyboard.press("ArrowDown");
  await expect(grid.getByRole("gridcell", { name: "Hexagon" })).toBeFocused();
  await page.keyboard.press("ArrowDown");
  await expect(grid.getByRole("gridcell", { name: "Left arrow" })).toBeFocused();

  // Enter inserts and closes; the shape is saved with its preset name.
  await search.focus();
  await search.fill("heart");
  await search.press("Enter");
  await expect(grid).toBeHidden();
  await expect.poll(() => saves.length, { timeout: 10_000 }).toBeGreaterThan(0);
  const saved = JSON.parse(saves.at(-1)!.body);
  const shape = saved.slides[0].elements.find((e: { type: string }) => e.type === "shape");
  expect(shape.shape).toBe("heart");
  expect(shape.text).toBeTruthy();

  // Its text is edited inside the heart's text rectangle (w/6 to 5w/6), not across the whole frame.
  const before = saves.length;
  const hit = page.locator("[data-element]").first();
  const frame = (await hit.boundingBox())!;
  await hit.dblclick();
  const box = page.getByRole("textbox", { name: "Slide text" });
  await expect(box).toBeFocused();
  await page.keyboard.type("Love");
  const r = (await box.boundingBox())!;
  expect(r.width / frame.width).toBeCloseTo(2 / 3, 1);
  expect(r.x - frame.x).toBeCloseTo(frame.width / 6, -1);
  await page.keyboard.press("Escape");
  await expect.poll(() => saves.length, { timeout: 10_000 }).toBeGreaterThan(before);
  const text = JSON.parse(saves.at(-1)!.body).slides[0].elements[0].text.paragraphs[0].runs[0].text;
  expect(text).toBe("Love");
  await page.screenshot({ path: test.info().outputPath("inserted.png") });
});

import { readFileSync } from "node:fs";
import { routeCanvasPage } from "./mock-canvas-pages";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import type { Deck } from "../lib/slides/schema";
import { installChatApi } from "./mock-chat-api";

// The whole acceptance deck in presentation mode (LAZYAGENTS-124): every
// slide of the second Slides epic (layouts, presets, styles, groups) is
// presented in order with its image loaded, and each slide's drawing is the
// one the editor draws.

const DECK = "12412412-4124-4124-8124-124124124124";
const at = "2026-11-11T12:00:00Z";
const FIX = join(__dirname, "../../docs/slides/fixtures/");
const deck = JSON.parse(readFileSync(FIX + "acceptance-deck.json", "utf8")) as Deck;
const png = readFileSync(FIX + "landscape.png");

test("presents every acceptance slide in order, drawn as in the editor", async ({ page }) => {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/slides");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const ref = { id: DECK, kind: "deck", title: "Acceptance", chat_id: chat.id, chat_title: "Acceptance", updated_at: at, reviewed_seq: 1 };
  const json = (data: unknown) => ({ contentType: "application/json", body: JSON.stringify(data) });
  await page.route(/\/api\/v1\/canvases(\/|$)/, (route) => route.fulfill(json(new URL(route.request().url()).pathname.endsWith(DECK) ? ref : { canvases: [ref] })));
  await page.route(/\/api\/v1\/slides\/[^/]+\/assets\//, (route) => route.fulfill({ contentType: "image/png", body: png }));
  await page.route(/\/api\/v1\/chats\/[^/]+\/canvases\//, (route) => {
    const u = new URL(route.request().url());
    if (u.pathname.endsWith("/comments")) return route.fulfill(json({ comments: [] }));
    return route.fulfill(json({ id: DECK, kind: "deck", title: "Acceptance", seq: 1, viewing_seq: 1, created_at: at, updated_at: at, body: JSON.stringify(deck), versions: [{ seq: 1, note: "", author_type: "user", created_at: at }] }));
  });

  const shown = deck.slides.filter((s) => !s.hidden);
  // The editor's drawing of each slide, from its thumbnail strip.
  await routeCanvasPage(page, { id: DECK, kind: "deck", title: "Deck" });
  await page.goto(`/apps/slides/${DECK}`);
  const thumbs = page.locator("[data-thumb] svg");
  await expect(thumbs).toHaveCount(shown.length);
  // What each thumbnail draws, as a signature of its primitives.
  const PRIMS = "rect,ellipse,path,line,polygon,polyline,text,image,g,linearGradient";
  const signature = (el: Element, sel: string) => [...el.querySelectorAll(sel)].map((n) => n.tagName).join(",");
  const editor: string[] = [];
  for (const t of await thumbs.all()) editor.push(await t.evaluate(signature, PRIMS));
  expect(editor.filter((sig) => sig.split(",").length > 1)).toHaveLength(shown.length);

  await page.goto(`/present/slides/${DECK}`);
  for (const [i, s] of shown.entries()) {
    const svg = page.getByRole("img", { name: new RegExp(`^Slide ${i + 1} of ${shown.length}:`) });
    await expect(svg).toBeVisible();
    await expect(page.getByText(`${i + 1} / ${shown.length}`)).toBeVisible();
    // Every image element is drawn and loaded.
    const images = s.elements.flatMap((e) => (e.type === "group" ? e.elements : [e])).filter((e) => e.type === "image").length;
    await expect(svg.locator("image")).toHaveCount(images);
    for (const im of await svg.locator("image").all()) await expect(im).toHaveAttribute("href", /\/assets\//);
    // The presented slide draws what the editor draws, primitive for primitive.
    expect(await svg.evaluate(signature, PRIMS), s.id).toBe(editor[i]);
    await page.keyboard.press("ArrowRight");
  }
  await expect(page.getByText(`${shown.length} / ${shown.length}`)).toBeVisible();
});

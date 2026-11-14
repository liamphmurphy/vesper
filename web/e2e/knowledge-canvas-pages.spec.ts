import { expect, test, type Route } from "@playwright/test";
import { DECK, deckWith, installDeck } from "./mock-deck-api";

// Decks and designs are Knowledge pages (LAZYAGENTS-212): the explorer lists them in their folders,
// and opening one shows its editor inside Knowledge, under the same top bar and tabs.
test.use({ viewport: { width: 1440, height: 900 } });

const json = (route: Route, data: unknown) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });

test("a deck is a page in the explorer that opens its editor inside Knowledge", async ({ page }) => {
  await installDeck(page, [{ seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" }]);
  const deckPage = `a${DECK.slice(1)}`;
  const doc = { id: "55555555-5555-4555-8555-555555555555", title: "Reading list", path: "Reading list", audience: "private", kind: "document" };
  const deck = { id: deckPage, title: "Layout", path: "Slides/Layout", audience: "private", kind: "deck", canvas_id: DECK };
  await page.route(/\/api\/v1\/knowledge\/query/, (route) => json(route, { columns: [], rows: [doc, deck], total: 2, has_more: false }));
  await page.goto("/knowledge");

  const explorer = page.getByRole("complementary", { name: "Knowledge explorer" });
  await explorer.getByRole("button", { name: "Slides" }).click();
  await explorer.getByRole("link", { name: "Layout" }).click();
  await expect(page).toHaveURL(new RegExp(`/knowledge/${deckPage}`));

  // The deck's editor, with its slides in the left column in place of the explorer.
  await expect(page.getByRole("navigation", { name: "Slides" }).getByRole("button", { name: /Slide 2/ })).toBeVisible();
  await expect(explorer).toHaveCount(0);
  const structure = page.getByRole("complementary", { name: "Structure" });
  await expect(structure.getByRole("link", { name: /Knowledge/ })).toHaveAttribute("href", "/knowledge");
  // Its tab sits beside the others in Knowledge's one bar, which also holds the deck's controls.
  const bar = page.locator("header").filter({ has: page.getByRole("tablist") }).first();
  await expect(bar.getByRole("tab", { name: /Layout/ })).toHaveAttribute("aria-selected", "true");
  await expect(bar.getByRole("button", { name: /Present/ })).toBeVisible();

  // Back to Knowledge: the explorer returns.
  await structure.getByRole("link", { name: /Knowledge/ }).click();
  await expect(explorer).toBeVisible();
});

test("New page makes a deck from a starter and opens it in Knowledge", async ({ page }) => {
  await installDeck(page, [{ seq: 1, body: JSON.stringify(deckWith("Quarterly review")), author: "user" }]);
  const made: unknown[] = [];
  await page.route(/\/api\/v1\/slide-starters$/, (route) => json(route, { starters: [{ key: "pitch", name: "Pitch", description: "Problem to ask", slide_count: 8, cover: "{}" }] }));
  await page.route(/\/api\/v1\/slides$/, (route) => {
    made.push(route.request().postDataJSON());
    return json(route, { id: DECK, kind: "deck", title: "Untitled deck", chat_id: "c", chat_title: "c", updated_at: "2026-11-14T12:00:00Z", reviewed_seq: 0 });
  });
  await page.route(/\/api\/v1\/knowledge\/query/, (route) => json(route, { columns: [], rows: [], total: 0, has_more: false }));
  await page.goto("/knowledge");

  await page.getByRole("button", { name: "New page" }).click();
  await page.getByRole("menuitem", { name: "Deck" }).hover();
  await expect(page.getByRole("menuitem", { name: "Blank" })).toBeVisible();
  await page.getByRole("menuitem", { name: /Pitch/ }).click();
  await expect(page).toHaveURL(new RegExp(`/knowledge/a${DECK.slice(1)}`));
  expect(made).toEqual([{ title: "Untitled deck", starter: "pitch" }]);
  await expect(page.getByRole("navigation", { name: "Slides" }).getByRole("button", { name: /Slide 2/ })).toBeVisible();
});

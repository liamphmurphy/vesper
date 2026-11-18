import { expect, test, type APIRequestContext, type Page } from "@playwright/test";

// Slides New deck chooser (LAZYAGENTS-123) on the real stack: no page.route
// mocks. Draft from outline sends the outline to the deck's persona (the fake
// harness in chat-read mode, which adds one slide per top-level outline line
// with canvas_patch); the slides arrive as per-slide suggestions in the deck
// review, and only accepted ones are kept. A starter deck starts with its
// slides in the chosen theme.

const API = process.env.E2E_STACK_API_URL;
if (!API) throw new Error("E2E_STACK_API_URL is not set; run `npm run e2e:stack`");

type Deck = { theme: { name: string }; slides: { elements: { placeholder?: string; paragraphs?: { runs: { text: string }[] }[] }[] }[] };
const titles = (d: Deck) => d.slides.map((s) => s.elements.find((e) => e.placeholder === "title")?.paragraphs?.[0]?.runs.map((r) => r.text).join("") ?? "");

// A new deck opens at /apps/slides/<canvas id>, which redirects to its Knowledge page
// (LAZYAGENTS-212). Wait for that page, then read the deck's canvas id from it.
async function openedDeck(page: Page, request: APIRequestContext): Promise<string> {
  const knowledgePage = /\/knowledge\/([0-9a-f-]{36})(\/[^/?#]*)?(\?.*)?$/;
  await expect(page).toHaveURL(knowledgePage);
  const pageId = knowledgePage.exec(page.url())![1];
  const res = await request.get(`${API}/api/v1/artifacts/${pageId}`);
  expect(res.ok(), `/artifacts/${pageId}: ${res.status()}`).toBeTruthy();
  const { canvas_id } = await res.json();
  expect(canvas_id).toMatch(/^[0-9a-f-]{36}$/);
  return canvas_id;
}

test("Draft from outline: suggestions per slide, nothing kept until accepted", async ({ page, request }) => {
  const get = async (path: string) => {
    const res = await request.get(`${API}/api/v1${path}`);
    expect(res.ok(), `${path}: ${res.status()}`).toBeTruthy();
    return res.json();
  };

  await page.goto("/apps/slides");
  await page.getByRole("radio", { name: /Draft from outline/ }).click();
  await page.getByLabel("Outline").fill("Q3 roadmap\nWhy now\n  - churn up 4% in EU\n  - two competitors launched\nPlan\n  - ship offline mode\n  - hire two engineers");
  await page.getByRole("button", { name: "✦ Create & draft" }).click();
  const id = await openedDeck(page, request);
  const ref = await get(`/canvases/${id}`);
  expect(ref.title).toBe("Q3 roadmap");

  // The persona's slides arrive as suggestions; the deck itself is unchanged.
  const review = page.getByTestId("deck-review");
  await expect(review).toBeVisible({ timeout: 90_000 });
  await expect(review.getByText(/suggested 2 changes/)).toBeVisible();
  await expect(review.getByText("Slide 2 · Why now")).toBeVisible();
  await expect(review.getByText("Slide 3 · Plan")).toBeVisible();
  const first = await get(`/chats/${ref.chat_id}/canvases/${id}?seq=1`);
  expect(titles(JSON.parse(first.body))).toEqual(["Q3 roadmap"]);
  expect((await get(`/canvases/${id}`)).reviewed_seq ?? 0).toBeLessThan((await get(`/chats/${ref.chat_id}/canvases/${id}`)).seq);

  // Accept one slide and reject the other: only the accepted one is kept.
  const card = (t: string) => review.locator("li[data-change]", { hasText: t });
  await card("Slide 2 · Why now").getByRole("button", { name: "Accept" }).click();
  await card("Slide 3 · Plan").getByRole("button", { name: "Reject" }).click();
  await expect(review).toBeHidden({ timeout: 15_000 });
  await expect.poll(async () => titles(JSON.parse((await get(`/chats/${ref.chat_id}/canvases/${id}`)).body))).toEqual(["Q3 roadmap", "Why now"]);
});

test("A starter deck starts with its slides in the chosen theme", async ({ page, request }) => {
  await page.goto("/apps/slides");
  await page.getByLabel("Theme").selectOption("forest");
  await page.getByRole("radio", { name: /^Retro/ }).click();
  await page.getByRole("button", { name: "New deck" }).click();
  const id = await openedDeck(page, request);
  const ref = await (await request.get(`${API}/api/v1/canvases/${id}`)).json();
  expect(ref.title).toBe("Retro");
  const deck: Deck = JSON.parse((await (await request.get(`${API}/api/v1/chats/${ref.chat_id}/canvases/${id}`)).json()).body);
  expect(deck.theme.name).toBe("Forest");
  expect(titles(deck)[0]).toBe("Sprint 42 retro");
  expect(deck.slides.length).toBe(6);
});

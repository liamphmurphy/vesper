import { expect, test, type Page, type Route } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";
import { routeCanvasPage } from "./mock-canvas-pages";
import { installChatApi } from "./mock-chat-api";

const palette = (page: Page) => page.getByRole("dialog");
const scopedInput = (page: Page, name: string) => page.getByRole("combobox", { name });
const results = (page: Page) => page.getByRole("listbox", { name: "Results" });
const json = (route: Route, data: unknown) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });

const at = "2026-11-14T12:00:00Z";
const PAGE_DOC = "11111111-1111-4111-8111-111111111111";
const PAGE_DESIGN = "22222222-2222-4222-8222-222222222222";
const CANVAS_DESIGN = "33333333-3333-4333-8333-333333333333";
const PAGE_DECK = "44444444-4444-4444-8444-444444444444";
const PAGE_AGENT = "55555555-5555-4555-8555-555555555555";
const PAGE_CREATED = "66666666-6666-4666-8666-666666666666";

const knowledgeRow = (id: string, title: string, path: string, kind: string, extra: Record<string, unknown> = {}) => ({
  id,
  title,
  path,
  audience: "private",
  summary: `${title} summary`,
  properties: {},
  updated_at: at,
  version_id: "v1",
  pending: 0,
  unresolved: 0,
  kind,
  ...extra,
});

const KNOWLEDGE_ROWS = [
  knowledgeRow(PAGE_DOC, "Reading list", "Reading list", "document", { properties: { tags: ["reading"] } }),
  knowledgeRow(PAGE_DECK, "Q4 review", "Work/Q4 review", "deck", { canvas_id: "77777777-7777-4777-8777-777777777777" }),
  knowledgeRow(PAGE_DESIGN, "Checkout flow", "Designs/Checkout flow", "design", { canvas_id: CANVAS_DESIGN }),
];

const AGENT_ROWS = [
  knowledgeRow(PAGE_AGENT, "Agent runbook", "Agent/Agent runbook", "document", { audience: "agent" }),
];

async function pressScopedPalette(page: Page, expectedInputLabel: string) {
  await expect(async () => {
    if (!(await palette(page).isVisible())) await page.keyboard.press("ControlOrMeta+Shift+K");
    await expect(scopedInput(page, expectedInputLabel)).toBeVisible({ timeout: 250 });
  }).toPass({ timeout: 10_000 });
}

async function installKnowledgeMocks(page: Page) {
  const queries: Array<{ q?: string; tag?: string; kind?: string; include_agent?: boolean }> = [];
  const created: unknown[] = [];

  await page.route(/\/api\/v1\/knowledge\/query/, (route) => {
    const body = (route.request().postDataJSON() ?? {}) as { q?: string; tag?: string; kind?: string; include_agent?: boolean };
    queries.push(body);
    let rows = [...KNOWLEDGE_ROWS];
    if (body.include_agent) rows = [...rows, ...AGENT_ROWS];
    if (body.kind) rows = rows.filter((r) => r.kind === body.kind);
    if (body.tag) {
      const tag = body.tag.toLowerCase();
      rows = rows.filter((r) => Array.isArray((r.properties as { tags?: string[] }).tags) && (r.properties as { tags: string[] }).tags.some((t) => t.toLowerCase().includes(tag)));
    }
    if (body.q) {
      const q = body.q.toLowerCase();
      rows = rows.filter((r) => r.title.toLowerCase().includes(q) || r.path.toLowerCase().includes(q));
    }
    return json(route, { columns: [], rows, has_more: false });
  });

  await page.route(/\/api\/v1\/knowledge\/pages\/created/, async (route) => route.fallback());
  await page.route(/\/api\/v1\/knowledge\/pages$/, async (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    const payload = route.request().postDataJSON();
    created.push(payload);
    return json(route, {
      id: PAGE_CREATED,
      title: payload.title,
      path: `Inbox/${payload.title}`,
      audience: "private",
      kind: "document",
      body_md: "",
      version_id: "v1",
      seq: 1,
      properties: {},
      direct: false,
      paused: false,
      chat_id: null,
      url: `/knowledge/${PAGE_CREATED}`,
      embeds: [],
      reviews: [],
      versions: [],
    });
  });

  await page.route(`**/api/v1/knowledge/pages/${PAGE_CREATED}`, (route) => json(route, {
    id: PAGE_CREATED,
    title: "Brand new idea",
    path: "Inbox/Brand new idea",
    audience: "private",
    kind: "document",
    body_md: "# Brand new idea\n",
    version_id: "v1",
    seq: 1,
    properties: {},
    direct: false,
    paused: false,
    chat_id: null,
    url: `/knowledge/${PAGE_CREATED}`,
    embeds: [],
    reviews: [],
    versions: [],
  }));

  return { queries, created };
}

test("⌘⇧K in Knowledge searches only Knowledge items, supports kind chips, #tags, Agent toggle, Inbox create, and widening to global", async ({ page }) => {
  await installBoardApi(page);
  const searchCalls: string[] = [];
  await page.route("**/api/v1/search?**", (route) => {
    searchCalls.push(route.request().url());
    return json(route, {
      hits: [
        { target: { kind: "ticket", id: "ticket-1", title: "Should not appear", display_id: "WEB-1", href: "/tickets/WEB-1" }, snippet: "", score: 5 },
      ],
    });
  });
  const { queries, created } = await installKnowledgeMocks(page);

  await page.goto("/knowledge");
  await pressScopedPalette(page, "Search Knowledge");

  const searchInput = scopedInput(page, "Search Knowledge");
  await expect(searchInput).toBeFocused();
  // Shows recent Knowledge pages immediately without hitting /api/v1/search or showing global Actions / Go to.
  const opts = results(page).getByRole("option");
  await expect(opts).toHaveCount(3);
  await expect(opts).toContainText(["Reading list", "Q4 review", "Checkout flow"]);
  await expect(results(page).getByRole("group", { name: "Actions" })).toHaveCount(0);
  await expect(results(page).getByRole("group", { name: "Go to" })).toHaveCount(0);
  expect(searchCalls).toHaveLength(0);

  // Kind filter chip + Tab stepping narrow strictly to Decks / Designs.
  await palette(page).getByRole("button", { name: "Decks" }).click();
  await expect(results(page).getByRole("option")).toHaveCount(1);
  await expect(results(page).getByRole("option")).toHaveText([/Q4 review/]);

  await page.keyboard.press("Tab");
  await expect(results(page).getByRole("option")).toHaveCount(1);
  await expect(results(page).getByRole("option")).toHaveText([/Checkout flow/]);

  // Reset to All and filter by #tag.
  await palette(page).getByRole("button", { name: "All", exact: true }).click();
  await searchInput.fill("#reading");
  await expect(results(page).getByRole("option")).toHaveCount(1);
  await expect(results(page).getByRole("option")).toHaveText([/Reading list/]);
  expect(queries.some((q) => q.tag === "reading")).toBe(true);

  // Agent knowledge toggle brings in agent-audience pages.
  await searchInput.fill("");
  await palette(page).getByRole("button", { name: "Agent knowledge" }).click();
  await expect(results(page).getByRole("option")).toHaveCount(4);
  await expect(results(page).getByRole("option", { name: /Agent runbook/ })).toBeVisible();
  expect(queries.some((q) => q.include_agent === true)).toBe(true);

  // Unknown query offers Create in Inbox with ⇧↵ / click.
  await searchInput.fill("Brand new idea");
  const createOption = results(page).getByRole("option", { name: /Create “Brand new idea” in Inbox/ });
  await expect(createOption).toBeVisible();
  expect(searchCalls).toHaveLength(0);

  // All Vesper widens to global palette; ⌘⇧K from All Vesper closes only on Esc or stays switched.
  await palette(page).getByRole("button", { name: "All Vesper" }).click();
  await expect(scopedInput(page, "Search everything")).toBeVisible();

  // Reopen via ⌘O alias and via Explorer Search button — both open the unified Knowledge palette.
  await page.keyboard.press("Escape");
  await expect(palette(page)).toBeHidden();
  await page.keyboard.press("ControlOrMeta+o");
  await expect(scopedInput(page, "Search Knowledge")).toBeVisible();
  await searchInput.fill("Brand new idea");
  await results(page).getByRole("option", { name: /Create “Brand new idea” in Inbox/ }).click();
  await expect(page).toHaveURL(new RegExp(`/knowledge/${PAGE_CREATED}`));
  expect(created).toEqual([{ body_md: "", path: "Inbox/Brand new idea", title: "Brand new idea" }]);
});

test("⌘⇧K inside a Design Knowledge page opens Knowledge palette instead of triggering image upload", async ({ page }) => {
  await installBoardApi(page);
  await installKnowledgeMocks(page);
  const designPageId = await routeCanvasPage(page, { id: CANVAS_DESIGN, kind: "design", title: "Checkout flow" });
  const designDoc = JSON.stringify({
    schema: 1,
    mode: "light",
    token_sets: {},
    assets: {},
    links: [],
    pages: [{ id: "p_one", name: "Flows", children: [{ id: "n_box", type: "shape", shape: "rect", name: "Box", x: 0, y: 0, w: 120, h: 80, fill: "#7C6AF0" }] }],
  });
  await page.route(`**/api/v1/designs/${CANVAS_DESIGN}/versions/1`, (route) => json(route, {
    seq: 1,
    note: "Initial",
    author_type: "user",
    created_at: at,
    body: designDoc,
  }));
  await page.route(`**/api/v1/designs/${CANVAS_DESIGN}`, (route) => json(route, {
    id: CANVAS_DESIGN,
    kind: "design",
    title: "Checkout flow",
    chat_id: null,
    chat_title: "Checkout flow",
    updated_at: at,
    reviewed_seq: 0,
    seq: 1,
    settings: { direct_edit: false, persona_paused: false, project_id: null },
    pending_proposals: 0,
  }));

  await page.goto(`/knowledge/${designPageId}`);
  await expect(page.getByTestId("design-zoom")).toBeVisible();

  let fileChooserOpened = false;
  page.on("filechooser", () => {
    fileChooserOpened = true;
  });

  await pressScopedPalette(page, "Search Knowledge");
  await expect(scopedInput(page, "Search Knowledge")).toBeFocused();
  expect(fileChooserOpened).toBe(false);
});

test("⌘⇧K on Tickets, Epics, Chats, and Settings scopes appropriately", async ({ page }) => {
  await installBoardApi(page);
  const searches: Array<{ q: string; kind: string | null }> = [];
  await page.route("**/api/v1/search?**", (route) => {
    const url = new URL(route.request().url());
    const q = url.searchParams.get("q") ?? "";
    const kind = url.searchParams.get("kind");
    searches.push({ q, kind });
    if (kind === "ticket") {
      return json(route, {
        hits: [{ target: { kind: "ticket", id: "ticket-1", title: "Deploy staging", display_id: "WEB-1", href: "/tickets/WEB-1" }, snippet: "", score: 3 }],
      });
    }
    if (kind === "epic") {
      return json(route, {
        hits: [{ target: { kind: "epic", id: "epic-1", title: "Payments rollout", display_id: "EP-1", href: "/epics/epic-1" }, snippet: "", score: 3 }],
      });
    }
    return json(route, { hits: [] });
  });

  // Tickets view -> Search Tickets (passes kind=ticket, hides Actions / Go to).
  await page.goto("/tickets?project=WEB");
  await pressScopedPalette(page, "Search Tickets");
  await expect(results(page).getByRole("group", { name: "Actions" })).toHaveCount(0);
  await expect(results(page).getByRole("group", { name: "Go to" })).toHaveCount(0);
  await scopedInput(page, "Search Tickets").fill("deploy");
  await expect(results(page).getByRole("option", { name: /Deploy staging/ })).toBeVisible();
  expect(searches.some((s) => s.kind === "ticket" && s.q === "deploy")).toBe(true);

  // Epics view -> Search Epics (passes kind=epic).
  await page.keyboard.press("Escape");
  await page.goto("/tickets?layout=epics&project=WEB");
  await pressScopedPalette(page, "Search Epics");
  await scopedInput(page, "Search Epics").fill("pay");
  await expect(results(page).getByRole("option", { name: /Payments rollout/ })).toBeVisible();
  expect(searches.some((s) => s.kind === "epic" && s.q === "pay")).toBe(true);

  // Chat -> Search Chats (lists chats immediately without requiring a query).
  await page.keyboard.press("Escape");
  await installChatApi(page);
  await page.goto("/chat");
  const chatRes = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ title: "Release planning" }) }).then((r) => r.json()));
  await page.goto(`/chat/${chatRes.id}`);
  await pressScopedPalette(page, "Search Chats");
  await expect(results(page).getByRole("option", { name: /Release planning/ })).toBeVisible();

  // Global fallback on unscoped routes (/settings) opens global palette directly.
  await page.keyboard.press("Escape");
  await page.goto("/settings");
  await pressScopedPalette(page, "Search everything");
  await expect(scopedInput(page, "Search everything")).toBeVisible();
});

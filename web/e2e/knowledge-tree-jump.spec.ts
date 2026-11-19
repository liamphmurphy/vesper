import { expect, test, type Locator, type Page, type Route } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

test.use({ viewport: { width: 1440, height: 700 } });

const at = "2026-11-15T06:00:00Z";
const uuid = (n: number) => `11111111-1111-4111-8111-${String(n).padStart(12, "0")}`;

function makePage(id: string, title: string, path: string, audience: "private" | "agent" = "private") {
  return {
    id,
    title,
    path,
    audience,
    kind: "document",
    summary: "",
    body_md: `Body for ${title}`,
    properties: {},
    updated_at: at,
    version_id: "v1",
    seq: 1,
    direct: false,
    paused: false,
    chat_id: null,
    url: `/knowledge/${id}`,
    embeds: [],
    reviews: [],
    versions: [],
  };
}

const TARGET_ID = uuid(999);
const AGENT_ID = uuid(998);
const TOP_ID = uuid(1);

const FILLER_PAGES = Array.from({ length: 32 }, (_, i) => {
  const num = String(i + 1).padStart(2, "0");
  return makePage(uuid(i + 1), `Alpha Note ${num}`, `Folder ${num}/Alpha Note ${num}`);
});
const TARGET_PAGE = makePage(TARGET_ID, "Target Note", "Zeta/Deep/Target Note");
const AGENT_PAGE = makePage(AGENT_ID, "Agent Pattern", "AgentNotes/Sub/Agent Pattern", "agent");

const ALL_PAGES = [...FILLER_PAGES, TARGET_PAGE, AGENT_PAGE];

const json = (route: Route, data: unknown) => route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify(data) });

async function install(page: Page) {
  await installChatApi(page);
  await page.route(/\/api\/v1\/search(\?|$)/, (route) => {
    const q = new URL(route.request().url()).searchParams.get("q")?.toLowerCase() ?? "";
    const hits = ALL_PAGES.filter((p) => p.title.toLowerCase().includes(q) || p.path.toLowerCase().includes(q)).map((p) => ({
      target: {
        kind: "artifact",
        artifact_type: "note",
        id: p.id,
        title: p.title,
        path: p.path,
        href: `/knowledge/${p.id}`,
      },
      snippet: p.body_md,
      score: 1,
      detail: p.path.split("/").slice(0, -1).join(" / "),
      updated_at: at,
    }));
    return json(route, { hits, counts: { page: hits.length } });
  });
  await page.route(/\/api\/v1\/knowledge\//, (route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname.replace("/api/v1/knowledge", "");
    if (path === "/query") {
      const body = (req.postDataJSON() ?? {}) as { text?: string; include_agent?: boolean; audience?: string };
      let rows = ALL_PAGES;
      if (body.audience === "agent") {
        rows = rows.filter((p) => p.audience === "agent");
      } else if (!body.include_agent) {
        rows = rows.filter((p) => p.audience !== "agent");
      }
      if (body.text) {
        const q = body.text.toLowerCase();
        rows = rows.filter((p) => p.title.toLowerCase().includes(q) || p.path.toLowerCase().includes(q));
      }
      return json(route, { columns: [], rows, total: rows.length, has_more: false });
    }
    const target = ALL_PAGES.find((p) => path === `/pages/${p.id}`);
    if (target) return json(route, target);
    if (path === "/network" || path === "/graph") return json(route, { nodes: [], edges: [] });
    if (path === "/backlinks") return json(route, { linked: [], unlinked: [] });
    return json(route, {});
  });
}

async function expectInScrollContainer(nav: Locator, item: Locator) {
  await expect(item).toBeVisible();
  await expect
    .poll(async () => {
      const navBox = await nav.boundingBox();
      const itemBox = await item.boundingBox();
      if (!navBox || !itemBox) return false;
      return itemBox.y >= navBox.y - 1 && itemBox.y + itemBox.height <= navBox.y + navBox.height + 1;
    })
    .toBe(true);
}

test("opening a Knowledge note via command palette expands its path and scrolls the tree to it", async ({ page }) => {
  await install(page);
  await page.goto("/knowledge");

  const nav = page.getByRole("navigation", { name: "Pages" });
  await expect(nav.getByRole("button", { name: "Folder 01" })).toBeVisible();
  const overflows = await nav.evaluate((el) => el.scrollHeight > el.clientHeight);
  expect(overflows).toBe(true);
  await expect(nav.getByRole("link", { name: "Target Note" })).toHaveCount(0);

  // Jump to the deeply nested note at the bottom via the Knowledge command palette.
  await page.keyboard.press("ControlOrMeta+o");
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await dialog.getByRole("combobox").fill("Target Note");
  await dialog.getByRole("option", { name: /^Target Note/ }).click();

  await expect(page).toHaveURL(new RegExp(`/knowledge/${TARGET_ID}`));
  await expectInScrollContainer(nav, nav.getByRole("link", { name: "Target Note" }));

  // Collapse Zeta manually, jump away to a top note, then return via command palette: Zeta must re-open.
  await nav.getByRole("button", { name: "Zeta" }).click();
  await expect(nav.getByRole("link", { name: "Target Note" })).toHaveCount(0);

  await page.keyboard.press("ControlOrMeta+o");
  await dialog.getByRole("combobox").fill("Alpha Note 01");
  await dialog.getByRole("option", { name: /^Alpha Note 01/ }).click();
  await expect(page).toHaveURL(new RegExp(`/knowledge/${TOP_ID}`));
  await expectInScrollContainer(nav, nav.getByRole("link", { name: "Alpha Note 01" }));

  await page.keyboard.press("ControlOrMeta+o");
  await dialog.getByRole("combobox").fill("Target Note");
  await dialog.getByRole("option", { name: /^Target Note/ }).click();
  await expect(page).toHaveURL(new RegExp(`/knowledge/${TARGET_ID}`));
  await expectInScrollContainer(nav, nav.getByRole("link", { name: "Target Note" }));
});

test("opening an Agent knowledge note via command palette switches to Agent view and reveals it in the tree", async ({ page }) => {
  await install(page);
  await page.goto("/knowledge");

  const explorer = page.getByRole("complementary", { name: "Knowledge explorer" });
  const nav = page.getByRole("navigation", { name: "Pages" });
  await expect(explorer.getByRole("radio", { name: "Yours" })).toHaveAttribute("aria-checked", "true");

  // Open an agent knowledge note from the global command palette.
  await page.keyboard.press("ControlOrMeta+k");
  const dialog = page.getByRole("dialog");
  await expect(dialog).toBeVisible();
  await dialog.getByRole("combobox").fill("Agent Pattern");
  await dialog.getByRole("option", { name: /^Agent Pattern/ }).click();

  await expect(page).toHaveURL(new RegExp(`/knowledge/${AGENT_ID}`));
  await expect(explorer.getByRole("radio", { name: "Agent knowledge" })).toHaveAttribute("aria-checked", "true");
  await expectInScrollContainer(nav, nav.getByRole("link", { name: "Agent Pattern" }));
});

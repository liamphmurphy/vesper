import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test, type Page, type Route } from "@playwright/test";
import { installChatApi, composerOption } from "./mock-chat-api";

// Designs from chat (LAZYAGENTS-151, docs/design/designs-from-chat.svg): the + menu and
// /design ask the chat's persona for a design, the design it starts opens beside the chat,
// and the reply's Design card shows a thumbnail, counts, Present/Open and the review badge.

test.beforeEach(({ page }) => page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1")));

const D = "44444444-4444-4444-8444-444444444444";
const at = "2026-11-12T12:00:00Z";
const acceptance = readFileSync(join(__dirname, "../../docs/design/fixtures/acceptance-design.json"), "utf8");
const PNG = readFileSync(join(__dirname, "../../docs/design/fixtures/landscape.png"));

async function install(page: Page) {
  const s = { created: false, pending: 2, paused: false, settings: [] as Record<string, unknown>[], proposals: [] as unknown[], resolved: [] as unknown[] };
  await installChatApi(page, { replyDelayMs: 10 });
  const json = (route: Route, data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  await page.route(/\/api\/v1\/chats\/[^/]+\/canvases(\/|\?|$)/, (route) =>
    json(route, { canvases: s.created ? [{ id: D, kind: "design", title: "Onboarding", seq: 1, created_at: at, updated_at: at }] : [] }),
  );
  await page.route(/\/api\/v1\/designs\//, (route) => {
    const req = route.request();
    const p = new URL(req.url()).pathname.replace(`/api/v1/designs/${D}`, "");
    if (p === "/render") return route.fulfill({ status: 200, contentType: "image/png", body: PNG });
    if (p === "/versions/1") return json(route, { seq: 1, note: "", author_type: "agent", created_at: at, body: acceptance });
    if (p === "/proposals") return json(route, { proposals: s.proposals });
    const resolve = p.match(/^\/proposals\/([^/]+)\/resolve$/);
    if (resolve && req.method() === "POST") {
      s.resolved.push(req.postDataJSON());
      const done = s.proposals.find((x) => (x as { id: string }).id === resolve[1]);
      s.proposals = s.proposals.filter((x) => x !== done);
      s.pending = s.proposals.length;
      return json(route, { proposal: { ...(done as object), status: "resolved" } });
    }
    if (p === "/settings") {
      const b = req.postDataJSON() as { persona_paused?: boolean };
      s.settings.push(b);
      if (b.persona_paused !== undefined) s.paused = b.persona_paused;
      return json(route, { direct_edit: false, persona_paused: s.paused });
    }
    if (p === "") return json(route, { id: D, kind: "design", title: "Onboarding", chat_id: "x", chat_title: "x", updated_at: at, reviewed_seq: 0, seq: 1, settings: { direct_edit: false, persona_paused: s.paused }, pending_proposals: s.pending });
    return json(route, { code: "not_found", message: "not found" }, 404);
  });
  await page.goto("/chat?project=WEB");
  return s;
}

const box = (page: Page) => page.getByRole("combobox", { name: "Message" });

test("the + menu and /design ask the persona for a design", async ({ page }) => {
  await install(page);
  await (await composerOption(page, "context")).getByRole("button", { name: "Add context" }).click();
  const create = page.getByTestId("create-with");
  await expect(create).toContainText(/Create with/);
  await expect(create.getByRole("button")).toHaveText([/Doc/, /Slides/, /Design.*Flow, diagram or wireframe.*\/design/]);
  await create.getByRole("button", { name: /Design/ }).click();
  await expect(box(page)).toHaveValue("/design ");
  await box(page).pressSequentially("onboarding for the Designs app");
  await box(page).press("Enter");
  await expect(page.locator(":text-is(\"Create a design: onboarding for the Designs app\"):visible").first()).toBeVisible();
  await expect(box(page)).toHaveValue("");

  await box(page).fill("/design ");
  await box(page).press("Enter");
  await expect(page.getByTestId("command-error")).toHaveText("Say what to design: /design <what to design>");
});

test("a design the persona starts opens beside the chat and leaves a Design card", async ({ page }) => {
  const s = await install(page);
  // The chat exists before the persona's design_create does.
  await box(page).fill("Now sketch onboarding");
  await box(page).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[^/?]+/);
  await expect(page.getByTestId("design-chat-card")).toHaveCount(0);
  s.created = true;
  await box(page).fill(`canvas: ${D}`);
  await box(page).press("Enter");

  const panel = page.getByTestId("design-panel");
  await expect(panel).toBeVisible();
  await expect(panel.getByRole("heading", { name: "Onboarding" })).toBeVisible();
  await expect(panel.getByRole("toolbar", { name: "Tools" }).getByRole("button")).toHaveCount(6);

  const card = page.getByTestId("design-chat-card");
  await expect(card).toContainText("Onboarding");
  await expect(card.getByTestId("design-card-counts")).toHaveText("4 frames · 3 links · 3 pages");
  await expect(card.getByTestId("design-card-thumb")).toHaveAttribute("src", `/api/v1/designs/${D}/render?v=1`);
  await expect(card.getByTestId("design-card-review")).toHaveText("2 to review");

  // Pause stops the persona's patches until resumed.
  await panel.getByTestId("design-pause").click();
  await expect.poll(() => s.settings).toEqual([{ persona_paused: true }]);
  await expect(panel.getByTestId("design-pause")).toHaveText("Resume");
  await panel.getByTestId("design-pause").click();
  await expect.poll(() => s.settings.at(-1)).toEqual({ persona_paused: false });

  // Accepting the suggestions elsewhere clears the badge on the next refresh.
  s.pending = 0;
  await panel.getByRole("button", { name: "Close the design" }).click();
  await expect(panel).toHaveCount(0);
  await box(page).fill(`canvas: ${D}`);
  await box(page).press("Enter");
  await expect(card.first().getByTestId("design-card-review")).toHaveCount(0);

  await card.first().getByRole("button", { name: "Open", exact: true }).click();
  await expect(page.getByTestId("design-panel")).toBeVisible();
  await card.first().getByRole("button", { name: "Present" }).click();
  await expect(page).toHaveURL(new RegExp(`/present/designs/${D}`));
});

// The chat's panels share the apps' dock (LAZYAGENTS-165): a tab per open panel plus Activity.
const dock = (page: Page) => page.getByRole("complementary", { name: "Panel" });
const rail = (page: Page) => page.getByRole("navigation", { name: "Panel rail" });
const dockTab = (page: Page, name: string) => dock(page).getByRole("tablist", { name: "Panel tabs" }).getByRole("tab", { name: new RegExp(name) });
const mod = process.platform === "darwin" ? "Meta" : "Control";

async function openDesign(page: Page) {
  const s = await install(page);
  await box(page).fill("Now sketch onboarding");
  await box(page).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[^/?]+/);
  s.created = true;
  await box(page).fill(`canvas: ${D}`);
  await box(page).press("Enter");
  // It opens by itself when the chat saw it appear; if the chat's canvases first loaded with it there, open it from its card.
  const card = page.getByTestId("design-chat-card").first();
  await expect(card).toBeVisible();
  if (!(await page.getByTestId("design-panel").isVisible())) await card.getByRole("button", { name: "Open", exact: true }).click();
  await expect(page.getByTestId("design-panel")).toBeVisible();
  return s;
}

test("with a design open, the dock collapses to its rail and reopens, and the URL keeps it", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openDesign(page);
  await expect(dockTab(page, "Design")).toHaveAttribute("aria-selected", "true");
  await expect(dockTab(page, "Activity")).toBeVisible();
  await expect(rail(page)).toHaveCount(0);

  // ⇥ collapses it in place; the rail's icon reopens that tab.
  await dock(page).getByRole("button", { name: "Collapse panel" }).click();
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page).getByRole("button", { name: "Open Design" })).toBeVisible();
  await rail(page).getByRole("button", { name: "Open Design" }).click();
  await expect(page.getByTestId("design-panel")).toBeVisible();

  // Clicking the active tab collapses it; ⌘\ reopens it.
  await dockTab(page, "Design").click();
  await expect(rail(page)).toBeVisible();
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(dockTab(page, "Design")).toHaveAttribute("aria-selected", "true");

  // Activity sits beside the conversation, and a reload keeps the tab and the open panels.
  await dockTab(page, "Activity").click();
  await expect(page.getByTestId("chat-activity")).toBeVisible();
  await expect(page.getByRole("log", { name: "Conversation" })).toBeVisible();
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(rail(page)).toBeVisible();
  await page.reload();
  await expect(rail(page).getByRole("button", { name: "Open Design" })).toBeVisible();
  await expect(dock(page)).toHaveCount(0);
  await rail(page).getByRole("button", { name: "Open Activity" }).click();
  await expect(dockTab(page, "Activity")).toHaveAttribute("aria-selected", "true");
  await page.reload();
  await expect(dockTab(page, "Activity")).toHaveAttribute("aria-selected", "true");
  await expect(dockTab(page, "Design")).toBeVisible();

  // Closing the design removes its tab.
  await dockTab(page, "Design").click();
  await page.getByTestId("design-panel").getByRole("button", { name: "Close the design" }).click();
  await expect(dockTab(page, "Design")).toHaveCount(0);
  // Activity is then the only tab: no tab strip, its panel under the dock's header.
  await expect(page.getByRole("complementary", { name: "Panel" }).getByRole("tabpanel", { name: "Activity" })).toBeVisible();
});

test("⌘. hides the Vesper sidebar and the dock, and restores both without touching the preference", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await openDesign(page);
  const menu = page.getByRole("complementary", { name: "Main menu" });
  await expect(menu).toBeVisible();
  await expect(dock(page)).toBeVisible();

  await page.keyboard.press(`${mod}+Period`);
  await expect(menu).toHaveCount(0);
  await expect(dock(page)).toHaveCount(0);
  await expect(rail(page)).toHaveCount(0);
  await expect(page.getByRole("log", { name: "Conversation" })).toBeVisible();

  await page.keyboard.press(`${mod}+Period`);
  await expect(menu).toBeVisible();
  await expect(menu).toHaveAttribute("data-expanded", "true");
  await expect(dockTab(page, "Design")).toHaveAttribute("aria-selected", "true");
  expect(await page.evaluate(() => localStorage.getItem("lazyagents.sidebar-expanded"))).toBe("1");
});

test("a design out of sight in the dock doesn't take editing keys", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const writes: string[] = [];
  page.on("request", (r) => {
    if (r.method() !== "GET" && r.url().includes(`/api/v1/designs/${D}`) && !r.url().endsWith("/settings")) writes.push(`${r.method()} ${r.url()}`);
  });
  await openDesign(page);
  const panel = page.getByTestId("design-panel");
  const selectAll = async () => {
    await panel.locator("svg").first().click({ position: { x: 5, y: 5 } });
    await page.keyboard.press(`${mod}+a`);
  };

  // Behind the Activity tab, Backspace with the focus on the page deletes nothing.
  await selectAll();
  await dockTab(page, "Activity").click();
  await page.getByRole("log", { name: "Conversation" }).click({ position: { x: 20, y: 20 } });
  await page.keyboard.press("Backspace");
  await page.keyboard.press("ArrowRight");
  // Nor in the collapsed dock.
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(rail(page)).toBeVisible();
  await page.keyboard.press("Backspace");
  await page.waitForTimeout(1500);
  expect(writes).toEqual([]);

  // In sight it does (so the check above would have seen a deletion).
  await rail(page).getByRole("button", { name: /Open Design/ }).click();
  await selectAll();
  await page.keyboard.press("Backspace");
  await expect.poll(() => writes.length, { timeout: 5000 }).toBeGreaterThan(0);
});

// A suggestion is reviewed in the chat's dock, not the Designs app (LAZYAGENTS-170).
test("Review on the Design card reviews the suggestion in the dock, survives a reload, and Done resolves it", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const s = await install(page);
  s.pending = 1;
  s.proposals = [
    {
      id: "55555555-5555-4555-8555-555555555555",
      agent_id: "a",
      base_seq: 1,
      summary: "Tighter cart",
      status: "pending",
      decisions: [],
      created_at: at,
      ops: [
        { op: "set_text", id: "n_cart_title", text: "Your cart", why: "Says whose cart it is" },
        { op: "remove_node", id: "n_ship_rule", why: "The spacing already separates them" },
      ],
    },
  ];
  await box(page).fill("Now sketch onboarding");
  await box(page).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[^/?]+/);
  s.created = true;
  await box(page).fill(`canvas: ${D}`);
  await box(page).press("Enter");
  const card = page.getByTestId("design-chat-card").first();
  await expect(card.getByTestId("design-card-review")).toHaveText("1 to review");

  // Review opens the review in the dock's Design tab, without leaving the chat.
  await card.getByRole("button", { name: "Review", exact: true }).click();
  await expect(page).toHaveURL(/\/chat\/[^/?]+\?.*review=1/);
  const panel = page.getByTestId("design-panel");
  await expect(dockTab(page, "Design")).toHaveAttribute("aria-selected", "true");
  await expect(panel.getByTestId("review-pill")).toBeVisible();
  // The dock widens for the canvas and the changes side by side, leaving the conversation 400px.
  expect((await dock(page).boundingBox())!.width).toBeGreaterThan(600);
  const changes = panel.getByTestId("beside-review");
  await expect(changes.getByTestId("review-status")).toContainText("2 of 2 left");

  // The pill: Before / After / Diff and ‹ n of m ›.
  const pill = panel.getByTestId("review-pill");
  for (const v of ["Before", "After", "Diff"]) {
    await pill.getByRole("button", { name: v }).click();
    await expect(pill.getByRole("button", { name: v })).toHaveAttribute("aria-pressed", "true");
  }
  await expect(pill.getByTestId("review-step")).toHaveText("2 changes");
  await pill.getByRole("button", { name: "Next change" }).click();
  await expect(pill.getByTestId("review-step")).toHaveText("1 of 2");
  await pill.getByRole("button", { name: "Next change" }).click();
  await expect(pill.getByTestId("review-step")).toHaveText("2 of 2");

  // A reload keeps the review open.
  await page.reload();
  await expect(page.getByTestId("design-panel").getByTestId("review-pill")).toBeVisible();
  await expect(page).toHaveURL(/review=1/);

  // Accept one, reject the other with a reason, then Done: one resolve, rejections with their reason.
  await changes.getByTestId("review-change-1").getByRole("button", { name: "Accept", exact: true }).click();
  await changes.getByTestId("review-change-2").getByRole("button", { name: "Reject", exact: true }).click();
  await changes.getByRole("textbox", { name: /Why reject change 2/ }).fill("Keep the divider");
  await changes.getByTestId("review-change-2").getByRole("button", { name: "Reject", exact: true }).click();
  await expect(changes.getByTestId("review-status")).toContainText("0 of 2 left");
  await changes.getByRole("button", { name: "Done" }).click();
  await expect.poll(() => s.resolved).toEqual([{ decisions: [{ i: 0, state: "accepted" }, { i: 1, state: "rejected", reason: "Keep the divider" }] }]);
  // The last suggestion ends the review: the design stays open in the dock, and the URL drops review=1.
  await expect(panel.getByTestId("review-pill")).toHaveCount(0);
  await expect(panel).toBeVisible();
  await expect(page).not.toHaveURL(/review=1/);
  await expect(page).toHaveURL(/\/chat\//);
});

// The person sees a persona's finished result, not its work: outside review the canvas is the
// design as it is, with no faded preview of the suggestion; the review is where it shows.
test("a pending suggestion draws nothing on the canvas until the review opens", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const s = await install(page);
  s.pending = 1;
  s.proposals = [
    {
      id: "66666666-6666-4666-8666-666666666666",
      agent_id: "a",
      base_seq: 1,
      summary: "Add a receipt screen",
      status: "pending",
      decisions: [],
      created_at: at,
      ops: [
        { op: "add_node", parent: "p_flows", why: "Show the receipt", node: { id: "n_receipt", type: "frame", name: "Receipt", x: 0, y: 900, w: 390, h: 400, fill: "#FFFFFF", children: [] } },
        { op: "connect", id: "n_to_receipt", from: "n_done", to: "n_receipt", why: "Where Confirmation leads" },
        { op: "set_text", id: "n_cart_title", text: "Your cart", why: "Says whose cart it is" },
      ],
    },
  ];
  await box(page).fill("Now sketch onboarding");
  await box(page).press("Enter");
  await expect(page).toHaveURL(/\/chat\/[^/?]+/);
  s.created = true;
  await box(page).fill(`canvas: ${D}`);
  await box(page).press("Enter");

  const panel = page.getByTestId("design-panel");
  await expect(panel.getByTestId("design-canvas")).toBeVisible();
  await expect(panel.getByTestId("suggestion-ghosts")).toHaveCount(0);
  await expect(panel.getByTestId("review-overlay")).toHaveCount(0);
  await expect(panel.getByRole("treeitem", { name: "Receipt", exact: true })).toHaveCount(0);

  // The review shows it, pinned on the canvas.
  await page.getByTestId("design-chat-card").first().getByRole("button", { name: "Review", exact: true }).click();
  await expect(panel.getByTestId("review-pill")).toContainText("3 changes");
  await expect(panel.getByTestId("review-overlay").locator('[data-pin="1"][data-kind="added"]')).toHaveCount(1);
});

// One bar: what waits on a design sits on the editor's bar beside its save state, not as a card
// stacked over the chat in the dock (whose first row is the chat's header).
test("in the Designs app, waiting suggestions are a Review pill on the editor's bar that opens the review", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  const s = await install(page);
  s.created = true;
  s.pending = 1;
  s.proposals = [
    {
      id: "77777777-7777-4777-8777-777777777777",
      agent_id: "a",
      base_seq: 1,
      summary: "Retitle the cart",
      status: "pending",
      decisions: [],
      created_at: at,
      ops: [
        { op: "set_text", id: "n_cart_title", text: "Your cart", why: "Says whose cart it is" },
        { op: "set_text", id: "n_cart_title", text: "Your basket", why: "Matches the copy deck" },
      ],
    },
  ];
  await page.goto(`/apps/designs/${D}`);
  const pill = page.getByTestId("suggestion-card");
  await expect(pill).toHaveAccessibleName("Review 2 suggested changes");
  // On the editor's bar, level with the dock's first row (the chat's header; one-bar.spec checks that).
  const bar = (await page.locator("header").filter({ has: pill }).boundingBox())!;
  const dockRow = (await page.getByTestId("dock-header").boundingBox())!;
  expect(Math.abs(bar.y - dockRow.y)).toBeLessThan(1);
  expect(Math.abs(bar.height - dockRow.height)).toBeLessThan(1);
  await expect(page.locator("[data-design-chat]").getByTestId("suggestion-card")).toHaveCount(0);

  await pill.click();
  await expect(page.getByRole("tablist", { name: "Panel tabs" }).getByRole("tab", { name: /^Review/ })).toHaveAttribute("aria-selected", "true");
});

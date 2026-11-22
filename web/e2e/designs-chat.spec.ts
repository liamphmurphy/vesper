import { readFileSync } from "node:fs";
import { routeCanvasPage } from "./mock-canvas-pages";
import { join } from "node:path";
import { expect, test, type Page, type Route } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// Designs from chat (LAZYAGENTS-151, docs/design/designs-from-chat.svg): a persona's waiting
// suggestions on a design. The chat-side flows went with the web chat screen; the Mac app's
// native chat covers them now.

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
  await routeCanvasPage(page, { id: D, kind: "design", title: "Onboarding" });
  return s;
}

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

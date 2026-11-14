import { readFileSync } from "node:fs";
import { routeCanvasPage } from "./mock-canvas-pages";
import { join } from "node:path";
import { expect, test, type Page, type Route } from "@playwright/test";
import { installChatApi } from "./mock-chat-api";

// The Designs app (LAZYAGENTS-147): Home, the editor's rendering, autosave
// with a debounce, undo, reopening, 409 recovery, and pan/zoom on ~2k nodes.
// The designs API is mocked here; the chat rail uses the chat mock.

const at = "2026-11-12T12:00:00Z";
const acceptance = JSON.parse(readFileSync(join(__dirname, "../../docs/design/fixtures/acceptance-design.json"), "utf8"));
const PNG = readFileSync(join(__dirname, "../../docs/design/fixtures/landscape.png"));

type Version = { seq: number; body: string; author: "user" | "agent" };
type Stored = { id: string; title: string; chat_id: string; versions: Version[] };

const simple = () => ({
  schema: 1, mode: "light", token_sets: {}, assets: {}, links: [],
  pages: [
    {
      id: "p_one", name: "Flows",
      children: [
        { id: "n_frame", type: "frame", name: "Home", preset: "iphone-15", x: 0, y: 0, w: 393, h: 852, fill: "#FFFFFF", clip: true, children: [
          { id: "n_title", type: "text", name: "Title", x: 24, y: 64, w: 200, h: 34, sizing: { w: "hug", h: "hug" }, paragraphs: [{ runs: [{ text: "Welcome", size: 28, weight: 700 }] }] },
          { id: "n_box", type: "shape", shape: "rect", name: "Box", x: 24, y: 140, w: 120, h: 80, fill: "#7C6AF0" },
        ] },
      ],
    },
    { id: "p_two", name: "Diagrams", children: [] },
  ],
});

async function install(page: Page, designs: Record<string, object>) {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/designs");
  const chatId = (await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()))).id as string;
  const s = {
    designs: Object.entries(designs).map(([id, body], i) => ({ id, title: i ? `Design ${i}` : "Checkout flow", chat_id: chatId, versions: [{ seq: 1, body: JSON.stringify(body), author: "user" as const }] })) as Stored[],
    saves: [] as { id: string; base_seq: number; body: string }[],
    calls: [] as string[],
    /** Files the Export menu saved to the Library (name and first bytes); libraryFull refuses them. */
    library: [] as { name: string; head: string }[],
    libraryFull: false,
  };
  // Each design is a Knowledge page: its /apps/designs/<id> address opens it there.
  for (const d of s.designs) await routeCanvasPage(page, { id: d.id, kind: "design", title: d.title, chatId });
  const head = (d: Stored) => d.versions[d.versions.length - 1];
  const json = (route: Route, data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  const mine = (d: Stored) => ({ id: d.id, kind: "design", title: d.title, chat_id: d.chat_id, chat_title: d.title, updated_at: at, reviewed_seq: 0 });
  const version = (v: Version) => ({ seq: v.seq, note: "Edited", author_type: v.author, created_at: at, body: v.body });
  await page.route(/\/api\/v1\/designs(\/|\?|$)/, async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    const parts = url.pathname.replace(/^\/api\/v1\/designs\/?/, "").split("/").filter(Boolean);
    const method = req.method();
    s.calls.push(`${method} /${parts.join("/")}`);
    if (!parts.length) {
      if (method === "POST") {
        const body = req.postDataJSON() ?? {};
        const d: Stored = { id: `00000000-0000-4000-8000-${String(s.designs.length + 1).padStart(12, "0")}`, title: body.title || "Untitled design", chat_id: chatId, versions: [{ seq: 1, body: JSON.stringify(simple()), author: "user" }] };
        s.designs.unshift(d);
        return json(route, mine(d), 201);
      }
      return json(route, {
        designs: s.designs.map((d) => ({ id: d.id, title: d.title, chat_id: d.chat_id, updated_at: at, seq: head(d).seq, pages: JSON.parse(head(d).body).pages.length, frames: 1, pending_proposals: d.title === "Checkout flow" ? 3 : 0, persona_edited: d.versions.some((v) => v.author === "agent") })),
      });
    }
    const d = s.designs.find((x) => x.id === parts[0]);
    if (!d) return json(route, { code: "not_found", message: "not found" }, 404);
    if (parts[1] === "versions" && method === "POST") {
      const body = req.postDataJSON();
      s.saves.push({ id: d.id, ...body });
      if (body.base_seq !== head(d).seq) return json(route, { code: "conflict", message: `this canvas is at version ${head(d).seq}, not ${body.base_seq}` }, 409);
      d.versions.push({ seq: head(d).seq + 1, body: body.body, author: "user" });
      return json(route, version(head(d)), 201);
    }
    if (parts[1] === "versions") return json(route, version(d.versions.find((v) => v.seq === Number(parts[2]))!));
    if (parts[1] === "render") {
      if (url.searchParams.get("scale") === "3") return json(route, { code: "invalid", message: "the image would be 5436×2556 px; the longest edge is at most 4096" }, 422);
      return route.fulfill({ status: 200, contentType: "image/png", body: PNG });
    }
    if (parts[1] === "library" && method === "POST") {
      if (s.libraryFull) return json(route, { code: "invalid", field: "file", message: "your Library is full (1 GB): remove items you no longer need" }, 422);
      const raw = req.postDataBuffer()!.toString("latin1");
      const name = /filename="([^"]+)"/.exec(raw)![1];
      const head = raw.slice(raw.indexOf("\r\n\r\n", raw.indexOf("filename=")) + 4).slice(0, 8);
      s.library.push({ name, head });
      return json(route, { id: "33333333-3333-4333-8333-333333333333", kind: name.endsWith(".pdf") ? "document" : "image", title: name.replace(/\.\w+$/, ""), filename: name, content_type: "application/pdf", size_bytes: raw.length, created_at: at }, 201);
    }
    if (parts[1] === "assets" && method === "POST") return json(route, { id: "a_upload", mime: "image/png", w: 640, h: 400 }, 201);
    if (parts[1] === "assets") return route.fulfill({ status: 200, contentType: "image/png", body: PNG });
    if (parts[1] === "duplicate") {
      const copy: Stored = { ...d, id: `00000000-0000-4000-8000-${String(s.designs.length + 1).padStart(12, "0")}`, title: `${d.title} (copy)`, versions: [{ ...head(d), seq: 1 }] };
      s.designs.unshift(copy);
      return json(route, mine(copy), 201);
    }
    if (method === "PATCH") {
      d.title = req.postDataJSON().title;
      return json(route, mine(d));
    }
    if (method === "DELETE") {
      s.designs = s.designs.filter((x) => x !== d);
      return route.fulfill({ status: 204 });
    }
    return json(route, { ...mine(d), seq: head(d).seq, settings: { direct_edit: false, persona_paused: false, project_id: null }, pending_proposals: 0 });
  });
  /** A version written elsewhere (a persona with direct edit on), on top of the current one. */
  const external = (id: string, edit: (body: ReturnType<typeof simple>) => void) => {
    const d = s.designs.find((x) => x.id === id)!;
    const body = JSON.parse(head(d).body);
    edit(body);
    d.versions.push({ seq: head(d).seq + 1, body: JSON.stringify(body), author: "agent" });
  };
  const latest = (id: string) => JSON.parse(head(s.designs.find((x) => x.id === id)!).body);
  return { s, external, latest };
}

const D1 = "11111111-1111-4111-8111-111111111111";
const node = (body: { pages: { children: unknown[] }[] }, id: string): Record<string, unknown> | undefined => {
  let found: Record<string, unknown> | undefined;
  const walk = (list: Record<string, unknown>[]) => list.forEach((n) => (n.id === id ? (found = n) : Array.isArray(n.children) && walk(n.children as Record<string, unknown>[])));
  body.pages.forEach((p) => walk(p.children as Record<string, unknown>[]));
  return found;
};
const savedState = (page: Page) => page.getByTestId("design-save-state");
const canvas = (page: Page) => page.getByTestId("design-canvas");
/** The inspector (Design / Prototype / Inspect) lives in the dock's Design tab; the dock opens on Chat. */
async function openInspector(page: Page) {
  const tab = page.getByRole("complementary", { name: "Panel", exact: true }).getByRole("tablist", { name: "Panel tabs" }).getByRole("tab", { name: /Design/ });
  // Clicking the active dock tab collapses the dock, so only click it when it isn't active.
  if ((await tab.getAttribute("aria-selected")) !== "true") await tab.click();
  await expect(tab).toHaveAttribute("aria-selected", "true");
}

test("designs live in Knowledge: the old index goes there, and New page makes a design that opens in it", async ({ page }) => {
  const { s } = await install(page, { [D1]: acceptance });
  await page.goto("/apps/designs");
  await expect(page).toHaveURL(/\/knowledge$/);
  // Designs is no longer an app of its own.
  await page.getByRole("button", { name: "Apps" }).click();
  await expect(page.getByRole("dialog", { name: "Apps" }).getByRole("link", { name: "Designs" })).toHaveCount(0);
  await page.keyboard.press("Escape");

  // The next design the mock makes; its page is routed before it exists.
  const made = "00000000-0000-4000-8000-000000000002";
  await routeCanvasPage(page, { id: made, kind: "design", title: "Untitled design" });
  await page.getByRole("button", { name: "New page" }).click();
  for (const name of ["Document", "Deck"]) await expect(page.getByRole("menuitem", { name })).toBeVisible();
  await page.getByRole("menuitem", { name: "Design" }).hover();
  for (const name of ["Blank", "Mobile flow", "Web flow", "Diagram", "Wireframe"]) await expect(page.getByRole("menuitem", { name })).toBeVisible();
  await page.getByRole("menuitem", { name: "Mobile flow" }).click();
  expect(s.calls).toContain("POST /");
  await expect(page).toHaveURL(/\/knowledge\/a0000000-0000-4000-8000-000000000002/);
  await expect(canvas(page)).toBeVisible();
});

test("every node type in the acceptance design renders in the editor", async ({ page }) => {
  await install(page, { [D1]: acceptance });
  await page.goto(`/apps/designs/${D1}`);
  const svg = canvas(page).locator("svg").first();
  // Text is one <text> per measured word.
  await expect(svg.locator("text", { hasText: "$84.00" })).toHaveCount(2);
  await expect(svg.locator("image")).toHaveCount(1);
  await expect(svg.locator("ellipse").first()).toBeAttached();
  await expect(svg.locator("path").first()).toBeAttached();
  await expect(svg.locator("clipPath").first()).toBeAttached();
  // Layers list the page's frames; another page shows its own (connectors, sticky, section).
  await expect(page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Payment" })).toBeVisible();
  await page.getByRole("list", { name: "Pages" }).getByRole("button", { name: "Diagrams" }).click();
  await expect(svg.locator("polyline").first()).toBeAttached();
  await expect(svg.locator("text", { hasText: "Order state" })).toHaveCount(1);
});

test("drawing, autosave, undo and reopening: rapid edits save as one version", async ({ page }) => {
  const { s, latest } = await install(page, { [D1]: simple() });
  await page.goto(`/apps/designs/${D1}`);
  await expect(savedState(page)).toContainText("Saved · v1");

  // Draw a rectangle over the frame's empty right half. Aim at the frame's box on screen
  // (select it from Layers, then deselect), not at the canvas edge: the canvas width
  // depends on the panels around it.
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Home" }).locator("div").first().click();
  const frame = (await page.locator('[data-selected="n_frame"]').boundingBox())!;
  await page.keyboard.press("Escape");
  await expect(page.locator('[data-selected="n_frame"]')).toHaveCount(0);
  await page.getByRole("button", { name: "Rectangle (R)" }).click();
  await page.mouse.move(frame.x + frame.width * 0.6, frame.y + frame.height * 0.3);
  await page.mouse.down();
  await page.mouse.move(frame.x + frame.width * 0.85, frame.y + frame.height * 0.4, { steps: 4 });
  await page.mouse.up();
  await expect(page.getByTestId("design-size-badge")).toBeVisible();
  await expect(savedState(page)).toContainText("Saved · v2");
  expect(s.saves).toHaveLength(1);
  // Drawn over the frame, it went into the frame, on top.
  const added = (latest(D1).pages[0].children[0].children as { id: string; x: number }[]).at(-1)!;
  expect(added).toMatchObject({ type: "shape", shape: "rect" });
  expect(["n_title", "n_box"]).not.toContain(added.id);

  // Ten nudges in quick succession are debounced into one version.
  for (let i = 0; i < 10; i++) await page.keyboard.press("ArrowRight");
  await expect(savedState(page)).toContainText("Saved · v3");
  await page.waitForTimeout(1200);
  expect(s.saves).toHaveLength(2);
  expect(node(latest(D1), added.id)!.x).toBe(added.x + 10);

  // Undo: the nudges were one step.
  await page.keyboard.press("ControlOrMeta+z");
  await expect(savedState(page)).toContainText("Saved · v4");
  expect(node(latest(D1), added.id)!.x).toBe(added.x);
  await page.keyboard.press("ControlOrMeta+Shift+z");
  await expect(savedState(page)).toContainText("Saved · v5");
  expect(node(latest(D1), added.id)!.x).toBe(added.x + 10);

  // Auto layout from the inspector: the frame's children reflow.
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Home" }).locator("div").first().click();
  await openInspector(page);
  await page.getByRole("button", { name: "Add auto layout" }).click();
  await expect(savedState(page)).toContainText("Saved · v6");
  const title = node(latest(D1), "n_title") as { y: number; h: number };
  expect(title.y).toBe(16);
  expect(node(latest(D1), "n_box")!.y).toBe(title.y + title.h + 16);
  await page.getByRole("textbox", { name: "Gap" }).fill("40");
  await expect(savedState(page)).toContainText("Saved · v7");
  expect(node(latest(D1), "n_box")!.y).toBe(title.y + title.h + 40);

  // Delete, then reopen: what's saved is what opens.
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Home" }).getByRole("button", { name: "Expand" }).click();
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Rectangle" }).locator("div").first().click();
  await page.keyboard.press("Delete");
  await expect(savedState(page)).toContainText("Saved · v8");
  await page.reload();
  await expect(savedState(page)).toContainText("Saved · v8");
  await expect(page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Rectangle" })).toHaveCount(0);
  await expect(page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Home" })).toBeVisible();
});

test("text edits in place; a page can be added and renamed", async ({ page }) => {
  const { latest } = await install(page, { [D1]: simple() });
  await page.goto(`/apps/designs/${D1}`);
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Home" }).getByRole("button", { name: "Expand" }).click();
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Title" }).locator("div").first().click();
  await page.keyboard.press("Enter");
  const editor = page.getByTestId("design-text-editor");
  await expect(editor).toBeFocused();
  await editor.fill("Welcome back");
  await page.keyboard.press("Escape");
  await expect(savedState(page)).toContainText("Saved · v2");
  expect((node(latest(D1), "n_title") as { paragraphs: { runs: { text: string; weight: number }[] }[] }).paragraphs[0].runs[0]).toMatchObject({ text: "Welcome back", weight: 700 });
  await page.getByRole("button", { name: "Add a page" }).click();
  await page.getByRole("textbox", { name: "Page name" }).fill("Explorations");
  await page.keyboard.press("Enter");
  await expect(savedState(page)).toContainText("Saved · v3");
  expect(latest(D1).pages.map((p: { name: string }) => p.name)).toEqual(["Flows", "Diagrams", "Explorations"]);
});

test("a 409 merges another layer's change, and asks about the same layer without dropping either side", async ({ page }) => {
  const { s, external, latest } = await install(page, { [D1]: simple() });
  await page.goto(`/apps/designs/${D1}`);
  await expect(savedState(page)).toContainText("Saved · v1");

  // A persona changes the title meanwhile; my nudge of the box merges with it.
  external(D1, (b) => ((b.pages[0].children[0] as { children: { name: string }[] }).children[0].name = "Heading"));
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Home" }).getByRole("button", { name: "Expand" }).click();
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Box" }).locator("div").first().click();
  await page.keyboard.press("ArrowDown");
  await expect(savedState(page)).toContainText("Saved · v3");
  expect(s.saves.map((x) => x.base_seq)).toEqual([1, 2]);
  expect(node(latest(D1), "n_title")!.name).toBe("Heading");
  expect(node(latest(D1), "n_box")!.y).toBe(141);

  // Now both change the box: nothing saves until the person chooses.
  external(D1, (b) => ((b.pages[0].children[0] as { children: { fill?: string }[] }).children[1].fill = "#FF0000"));
  await page.keyboard.press("ArrowDown");
  const banner = page.getByText("This design changed while you were editing");
  await expect(banner).toBeVisible();
  await expect(page.getByText(/both changed Box/)).toBeVisible();
  await expect(savedState(page)).toContainText("Not saved");
  expect(s.designs[0].versions.at(-1)!.author).toBe("agent");
  // Keep mine saves over theirs; theirs stays as a version.
  await page.getByRole("button", { name: "Keep mine" }).click();
  await expect(savedState(page)).toContainText("Saved · v5");
  expect(node(latest(D1), "n_box")).toMatchObject({ y: 142, fill: "#7C6AF0" });
  expect(node(JSON.parse(s.designs[0].versions[3].body), "n_box")).toMatchObject({ fill: "#FF0000" });

  // And Use the latest version takes theirs, dropping only the unsaved edit.
  external(D1, (b) => ((b.pages[0].children[0] as { children: { fill?: string }[] }).children[1].fill = "#00FF00"));
  await page.keyboard.press("ArrowDown");
  await expect(banner).toBeVisible();
  await page.getByRole("button", { name: "Use the latest version" }).click();
  await expect(banner).toHaveCount(0);
  await expect(savedState(page)).toContainText("Saved · v6");
  // History restarted with their version: undo has nothing to take back.
  await page.keyboard.press("ControlOrMeta+z");
  await page.waitForTimeout(1200);
  expect(s.designs[0].versions).toHaveLength(6);
});

/** The PoC's ~2k-node design (docs/design/poc/large.mjs): 40 phone frames of 12 auto-layout rows, wired by connectors. */
function largeDesign(frames = 40, rows = 12) {
  const children: unknown[] = [];
  const cols = 8;
  for (let f = 0; f < frames; f++) {
    const kids: unknown[] = [{ id: `n_f${f}_title`, type: "text", name: "Title", x: 24, y: 64, w: 345, h: 31, sizing: { w: "fill", h: "hug" }, paragraphs: [{ runs: [{ text: `Screen ${f + 1}`, size: 26, weight: 600, color: "$text" }] }] }];
    for (let r = 0; r < rows; r++) {
      const id = `n_f${f}_r${r}`;
      kids.push({
        id, type: "frame", name: `Row ${r + 1}`, x: 24, y: 0, w: 345, h: 52, sizing: { w: "fill", h: "hug" }, fill: "$surface", radius: 10,
        auto_layout: { direction: "horizontal", gap: 12, padding: [8, 12, 8, 12], align: "center" },
        children: [
          { id: `${id}_av`, type: "shape", shape: "ellipse", name: "Avatar", x: 0, y: 0, w: 36, h: 36, fill: r % 2 ? "$agent-quill" : "$agent-atlas" },
          { id: `${id}_name`, type: "text", name: "Name", x: 0, y: 0, w: 150, h: 18, sizing: { w: "fill", h: "hug" }, paragraphs: [{ runs: [{ text: `Item ${r + 1} on screen ${f + 1}`, size: 15, weight: 500, color: "$text" }] }] },
          { id: `${id}_meta`, type: "text", name: "Meta", x: 0, y: 0, w: 60, h: 16, sizing: { w: "hug", h: "hug" }, paragraphs: [{ runs: [{ text: `${(r * 7 + f) % 59}m ago`, size: 13, color: "$text-tertiary" }] }] },
        ],
      });
    }
    children.push({ id: `n_f${f}`, type: "frame", name: `Screen ${f + 1}`, preset: "iphone-15", x: (f % cols) * 473, y: Math.floor(f / cols) * 952, w: 393, h: 852, fill: "$bg-panel", clip: true, auto_layout: { direction: "vertical", gap: 8, padding: [64, 24, 32, 24] }, children: kids });
    if (f > 0 && f % cols) children.push({ id: `n_w${f}`, type: "connector", from: { node: `n_f${f - 1}`, anchor: "right" }, to: { node: `n_f${f}`, anchor: "left" }, route: "orthogonal", stroke: "$accent", stroke_width: 2, end_arrow: "arrow" });
  }
  return { ...acceptance, pages: [{ id: "p_large", name: "Large", background: "$bg", children }], links: [] };
}

test("pan and zoom stay smooth on the ~2k-node PoC design", async ({ page }, info) => {
  test.setTimeout(120_000);
  await page.setViewportSize({ width: 1440, height: 900 });
  await install(page, { [D1]: largeDesign() });
  await page.goto(`/apps/designs/${D1}`);
  const svg = canvas(page).locator("svg").first();
  await expect(svg.locator("text", { hasText: /^40$/ }).first()).toBeAttached();
  // Collapse the dock so the canvas is the PoC's size.
  await page.getByRole("button", { name: "Collapse panel" }).click();
  // The PoC's camera path through the editor's own wheel handling: pan across the grid at
  // overview zoom (every node visible), zoom 0.1× ↔ 2×, pan at 100 %. One wheel event per frame.
  const result = await canvas(page).evaluate(async (el) => {
    const r = el.getBoundingClientRect();
    const fire = (dx: number, dy: number, zoom: boolean, x = r.left + r.width / 2, y = r.top + r.height / 2) =>
      el.dispatchEvent(new WheelEvent("wheel", { deltaX: dx, deltaY: dy, ctrlKey: zoom, clientX: x, clientY: y, bubbles: true, cancelable: true }));
    const frame = () => new Promise<number>((res) => requestAnimationFrame(res));
    // Overview first: zoom out until the whole grid fits.
    for (let i = 0; i < 4; i++) {
      fire(0, 60, true);
      await frame();
    }
    const steps: (() => void)[] = [];
    for (let i = 0; i < 120; i++) steps.push(() => fire(i < 60 ? 12 : -12, i % 40 < 20 ? 4 : -4, false));
    for (let i = 0; i < 120; i++) steps.push(() => fire(0, i < 60 ? -17 : 17, true));
    for (let i = 0; i < 120; i++) steps.push(() => fire(i < 60 ? 20 : -20, i < 60 ? 10 : -10, false));
    const times: number[] = [];
    let last = await frame();
    for (const step of steps) {
      step();
      const t = await frame();
      times.push(t - last);
      last = t;
    }
    const sorted = [...times].sort((a, b) => a - b);
    const pct = (p: number) => sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))];
    return { frames: times.length, fps: Math.round((1000 * times.length) / times.reduce((a, b) => a + b, 0)), p50: pct(0.5), p95: pct(0.95), max: sorted.at(-1)!, over33: times.filter((t) => t > 33.4).length, nodes: el.querySelectorAll("svg:first-of-type g[data-testid=design-camera] *").length };
  });
  await info.attach("panzoom.json", { body: JSON.stringify(result, null, 2), contentType: "application/json" });
  console.log("pan/zoom on the 2k-node design:", JSON.stringify(result));
  expect(result.nodes).toBeGreaterThan(4000);
  // 60 fps target; the bound leaves room for a loaded CI machine, the attachment has the numbers.
  expect(result.p95).toBeLessThan(34);
  expect(result.over33 / result.frames).toBeLessThan(0.05);
});

// ---- Prototype links and Present mode (LAZYAGENTS-149).

/** simple() with a second frame, and optionally links. */
const twoFrames = (links: unknown[] = []) => {
  const b = simple();
  (b.pages[0].children as unknown[]).push({ id: "n_next", type: "frame", name: "Details", x: 500, y: 0, w: 393, h: 852, fill: "#F4F4F8", clip: true, children: [] });
  return { ...b, links };
};

test("the Prototype tab adds, edits and removes a layer's links, and they're saved in the body", async ({ page }) => {
  const { latest } = await install(page, { [D1]: twoFrames() });
  await page.goto(`/apps/designs/${D1}`);
  await expect(savedState(page)).toContainText("Saved · v1");
  const layers = page.getByRole("tree", { name: "Layers" });
  await layers.getByRole("treeitem", { name: "Home" }).getByRole("button", { name: "Expand" }).click();
  await layers.getByRole("treeitem", { name: "Box" }).locator("div").first().click();
  await openInspector(page);
  await page.getByRole("tab", { name: "Prototype" }).click();

  await page.getByRole("button", { name: "Add interaction" }).click();
  await expect(savedState(page)).toContainText("Saved · v2");
  expect(latest(D1).links).toEqual([expect.objectContaining({ from: "n_box", to: "n_next", trigger: "click", transition: "dissolve" })]);
  await expect(page.getByTestId("design-wires").locator("[data-wire]")).toHaveCount(1);

  await page.getByRole("combobox", { name: "Transition" }).selectOption({ label: "Slide left" });
  await page.getByRole("combobox", { name: "Trigger" }).selectOption({ label: "After delay" });
  await expect(savedState(page)).toContainText("Saved · v3");
  expect(latest(D1).links[0]).toMatchObject({ transition: "slide-left", trigger: "after-delay", delay_ms: 800 });

  await page.getByRole("button", { name: "Remove", exact: true }).click();
  await expect(savedState(page)).toContainText("Saved · v4");
  expect(latest(D1).links).toEqual([]);
});

test("a link to a deleted frame shows as broken in the editor and is skipped in Present", async ({ page }) => {
  const broken = { id: "k_gone", from: "n_box", to: "n_gone", trigger: "click", transition: "dissolve", duration_ms: 300 };
  const live = { id: "k_live", from: "n_title", to: "n_next", trigger: "click", transition: "instant" };
  await install(page, { [D1]: twoFrames([broken, live]) });
  await page.goto(`/apps/designs/${D1}`);
  await openInspector(page);
  await page.getByRole("tab", { name: "Prototype" }).click();
  await expect(page.getByRole("region", { name: "Flow" })).toContainText("1 broken");
  await expect(page.locator('[data-link="k_gone"][data-broken]')).toContainText("deleted frame (broken)");
  await expect(page.locator('[data-wire="k_gone"][data-broken]')).toBeAttached();
  await page.locator('[data-link="k_gone"] button').first().click();
  await expect(page.getByRole("alert").filter({ hasText: "Broken link" })).toBeVisible();

  await page.goto(`/present/designs/${D1}?start=n_frame`);
  await expect(page.getByTestId("present-frame")).toHaveAttribute("data-at", "n_frame");
  await expect(page.locator("[data-hotspot]")).toHaveCount(1);
  await page.locator('[data-hotspot="k_live"]').click();
  await expect(page.getByTestId("present-frame")).toHaveAttribute("data-at", "n_next");
});

test("Present starts from a chosen frame, follows hotspots, and goes back, restarts and exits by keyboard", async ({ page }) => {
  const errors: string[] = [];
  page.on("pageerror", (e) => errors.push(e.message));
  await install(page, { [D1]: acceptance });
  await page.goto(`/apps/designs/${D1}`);
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Shipping" }).locator("div").first().click();
  await openInspector(page);
  await page.getByRole("tab", { name: "Prototype" }).click();
  await page.getByRole("button", { name: "Present from “Shipping”" }).click();
  await expect(page).toHaveURL(new RegExp(`/present/designs/${D1}\\?start=n_ship`));
  const frame = page.getByTestId("present-frame");
  await expect(frame).toHaveAttribute("data-at", "n_ship");

  await page.getByRole("button", { name: "Go to Payment" }).click();
  await expect(frame).toHaveAttribute("data-at", "n_pay");
  await page.getByRole("button", { name: "Go to Confirmation" }).click();
  await expect(frame).toHaveAttribute("data-at", "n_done");
  await page.keyboard.press("ArrowLeft");
  await expect(frame).toHaveAttribute("data-at", "n_pay");
  await page.keyboard.press("r");
  await expect(frame).toHaveAttribute("data-at", "n_ship");
  // Back to the design, which is its page in Knowledge.
  await page.keyboard.press("Escape");
  await expect(page).toHaveURL(new RegExp(`/knowledge/${"a" + D1.slice(1)}`));
  expect(errors).toEqual([]);
});

test("Export downloads SVG, saves a PDF of every frame to the Library, and explains failures without saving", async ({ page }) => {
  const { s } = await install(page, { [D1]: acceptance });
  await page.goto(`/apps/designs/${D1}`);
  await expect(savedState(page)).toContainText("Saved · v1");
  // Export lives under the header's Share ▾.
  const exportButton = page.getByRole("button", { name: "Share" });
  const panel = page.getByRole("dialog", { name: "Export" });
  const notice = page.getByTestId("design-export-notice");

  // Nothing selected: the page's first frame, as SVG with text as text.
  await exportButton.click();
  await expect(panel.getByRole("radio", { name: "Selection" })).toBeDisabled();
  await expect(panel.getByRole("radio", { name: "Frame: Cart" })).toBeChecked();
  await expect(panel.getByRole("radio", { name: "All frames (4)" })).toBeEnabled();
  await panel.getByRole("radio", { name: /^SVG/ }).check();
  const [svgDownload] = await Promise.all([page.waitForEvent("download"), panel.getByRole("button", { name: "Download" }).click()]);
  expect(svgDownload.suggestedFilename()).toBe("Checkout flow - Cart.svg");
  const svg = readFileSync((await svgDownload.path())!, "utf8");
  expect(svg).toContain("<text");
  expect(svg).toContain("data:font/woff2;base64,");
  await expect(notice).toContainText("Downloaded “Checkout flow - Cart.svg”");

  // Every frame as one PDF, saved to the Library.
  await exportButton.click();
  await panel.getByRole("radio", { name: "All frames (4)" }).check();
  await panel.getByRole("radio", { name: /^PNG/ }).check();
  // Four PNGs are four files: the Library takes one at a time.
  await expect(panel.getByRole("button", { name: "Save to Library" })).toBeDisabled();
  await panel.getByRole("radio", { name: /^PDF/ }).check();
  await panel.getByRole("button", { name: "Save to Library" }).click();
  await expect(notice).toContainText("Saved “Checkout flow - All frames.pdf” to your Library");
  await expect(notice.getByRole("link", { name: "Open" })).toHaveAttribute("href", "/library");
  expect(s.library).toEqual([{ name: "Checkout flow - All frames.pdf", head: "%PDF-1.3" }]);

  // The renderer refuses a PNG that's too large: the message says why and nothing is saved.
  await page.getByRole("tree", { name: "Layers" }).getByRole("treeitem", { name: "Payment" }).click();
  await exportButton.click();
  // The last scope chosen is kept; the selection is now one choice.
  await expect(panel.getByRole("radio", { name: "All frames (4)" })).toBeChecked();
  await expect(panel.getByRole("radio", { name: "Selection (1)" })).toBeEnabled();
  await panel.getByRole("radio", { name: "Page: Flows" }).check();
  await panel.getByRole("radio", { name: /^PNG/ }).check();
  await panel.getByRole("radio", { name: "3×" }).click();
  await panel.getByRole("button", { name: "Save to Library" }).click();
  await expect(notice).toContainText("PNG to your Library");
  await expect(notice).toContainText("a PNG is at most 4096 px");
  expect(s.calls.filter((c) => c.includes("render"))).toEqual([]);

  // The server's refusal (a full Library) is shown, and nothing was kept.
  s.libraryFull = true;
  await exportButton.click();
  await panel.getByRole("radio", { name: "Selection (1)" }).check();
  await panel.getByRole("radio", { name: "1×" }).click();
  await panel.getByRole("button", { name: "Save to Library" }).click();
  await expect(notice).toContainText("your Library is full (1 GB)");
  await expect(notice).toContainText("Nothing was saved.");
  expect(s.calls).toContain("GET /11111111-1111-4111-8111-111111111111/render");
  expect(s.library).toHaveLength(1);
});

test("diagram tools: connect two nodes, add a sticky, and draw a section that takes them in", async ({ page }) => {
  const shapeAt = (id: string, name: string, x: number) => ({ id, type: "shape", shape: "roundRect", name, x, y: 0, w: 140, h: 60, fill: "#E5E7EB" });
  const body = { schema: 1, mode: "light", token_sets: {}, assets: {}, links: [], pages: [{ id: "p_diag", name: "Diagram", children: [shapeAt("n_a", "Start", 0), shapeAt("n_b", "End", 480)] }] };
  const { latest } = await install(page, { [D1]: body });
  await page.goto(`/apps/designs/${D1}`);
  await expect(savedState(page)).toContainText("Saved · v1");
  const layers = page.getByRole("tree", { name: "Layers" });
  const centre = async (name: string, id: string) => {
    await layers.getByRole("treeitem", { name }).locator("div").first().click();
    const b = (await page.locator(`[data-selected="${id}"]`).boundingBox())!;
    return { x: b.x + b.width / 2, y: b.y + b.height / 2, b };
  };
  const a = await centre("Start", "n_a");
  const b = await centre("End", "n_b");

  // Connector: drag from Start to End.
  await page.getByRole("button", { name: "Connector (C)" }).click();
  await page.mouse.move(a.x, a.y);
  await page.mouse.down();
  await page.mouse.move(b.x, b.y, { steps: 6 });
  await expect(page.getByTestId("design-connect-preview")).toBeVisible();
  await page.mouse.up();
  await expect.poll(() => latest(D1).pages[0].children.find((n: { type: string }) => n.type === "connector")).toMatchObject({ from: { node: "n_a" }, to: { node: "n_b" } });

  // Sticky: click below Start and type.
  await page.getByRole("button", { name: "Sticky (S)" }).click();
  await page.mouse.click(a.x, a.y + a.b.height * 4);
  const sticky = page.getByTestId("design-sticky-editor");
  await expect(sticky).toBeFocused();
  await sticky.fill("Check the copy");
  await page.keyboard.press("Escape");
  await expect.poll(() => latest(D1).pages[0].children.find((n: { type: string }) => n.type === "sticky")?.text).toBe("Check the copy");

  // Section: drawn around both shapes, it takes them (and their connector) in.
  await page.getByRole("button", { name: "Section (⇧S)" }).click();
  await page.mouse.move(a.b.x - 30, a.b.y - 60);
  await page.mouse.down();
  await page.mouse.move(b.b.x + b.b.width + 30, b.b.y + b.b.height + 30, { steps: 6 });
  await page.mouse.up();
  await expect.poll(() => (latest(D1).pages[0].children[0] as { type: string; children?: { id: string }[] }).children?.map((c) => c.id).slice(0, 2)).toEqual(["n_a", "n_b"]);
  const section = latest(D1).pages[0].children[0] as { id: string; type: string; x: number; children: { id: string; type: string; x: number }[] };
  expect(section.type).toBe("section");
  expect(section.children.some((c) => c.type === "connector")).toBe(true);

  // Moving the section moves its contents: children keep their place relative to it.
  const startX = section.children.find((c) => c.id === "n_a")!.x;
  await layers.getByRole("treeitem", { name: "Section" }).locator("div").first().click();
  await page.keyboard.press("Shift+ArrowRight");
  await expect.poll(() => (latest(D1).pages[0].children[0] as { x: number }).x).toBe(section.x + 10);
  expect(node(latest(D1), "n_a")!.x).toBe(startX);
});

// ---- The shared editor layout (LAZYAGENTS-157).
test("a design opens in the shared layout: slim header, Pages and layers, and a dock that collapses and reopens", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await install(page, { [D1]: acceptance });
  const settings: unknown[] = [];
  await page.route(/\/api\/v1\/designs\/[^/]+\/settings$/, async (route) => {
    settings.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ direct_edit: true, persona_paused: false, project_id: null }) });
  });
  await page.goto(`/apps/designs/${D1}`);
  await expect(savedState(page)).toContainText("Saved · v1");
  const header = page.locator("header").filter({ has: savedState(page) });
  const dock = page.getByRole("complementary", { name: "Panel", exact: true });
  const rail = page.getByRole("navigation", { name: "Panel rail" });
  const tab = (name: string) => dock.getByRole("tablist", { name: "Panel tabs" }).getByRole("tab", { name: new RegExp(name) });
  const mod = process.platform === "darwin" ? "Meta" : "Control";

  // Header: back and forward, title, save state, Present and Share; no Hide chat or Export of its own.
  // The way back to Knowledge, where the design lives, heads the left column's Structure.
  await expect(header.getByRole("group", { name: "History" })).toBeVisible();
  await expect(page.getByRole("complementary", { name: "Structure" }).getByRole("link", { name: /Knowledge/ })).toHaveAttribute("href", "/knowledge");
  await expect(header.getByRole("heading", { name: "Checkout flow" })).toBeVisible();
  await expect(header.getByRole("button", { name: "▶ Present" })).toBeVisible();
  await expect(header.getByRole("button", { name: "Share" })).toBeVisible();
  await expect(header.getByRole("button", { name: "More" })).toBeVisible();
  await expect(page.getByRole("button", { name: /Hide chat|^Export$/ })).toHaveCount(0);
  await expect(page.getByRole("toolbar", { name: "Tools" }).getByRole("button", { name: /Ask/ })).toHaveCount(0);

  // Three panels: Pages and layers, the canvas, the dock (Chat · Design; Review only with suggestions).
  await expect(page.getByRole("navigation", { name: "Pages and layers" })).toBeVisible();
  await expect(canvas(page)).toBeVisible();
  await expect(tab("Chat")).toBeVisible();
  await expect(tab("Design")).toBeVisible();
  await expect(tab("Review")).toHaveCount(0);

  // Direct edit sits in the chat's one header row, not a bar of its own.
  const pill = page.getByTestId("chat-header").getByTestId("direct-edit");
  await expect(pill).toHaveText(/^Suggests/);
  await expect(pill).toHaveAccessibleName(/suggests changes$/);
  await pill.click();
  await page.getByRole("menuitemradio", { name: /Edits directly/ }).click();
  await expect.poll(() => settings).toEqual([{ direct_edit: true }]);

  // The Design tab holds the inspector's Design / Prototype / Inspect.
  await tab("Design").click();
  await expect(dock.getByRole("tablist", { name: "Inspector" }).getByRole("tab", { name: "Prototype" })).toBeVisible();

  // Collapse with ⇥, reopen from the rail; clicking the active tab collapses too.
  await dock.getByRole("button", { name: "Collapse panel" }).click();
  await expect(dock).toHaveCount(0);
  await expect(rail).toBeVisible();
  await rail.getByRole("button", { name: "Open Design" }).click();
  await expect(tab("Design")).toHaveAttribute("aria-selected", "true");
  await tab("Design").click();
  await expect(rail).toBeVisible();
  await rail.getByRole("button", { name: "Expand panel" }).click();
  await expect(dock).toBeVisible();

  // ⌘J opens Chat and focuses the design chat's composer.
  await canvas(page).click({ position: { x: 20, y: 20 } });
  await page.keyboard.press(`${mod}+j`);
  await expect(tab("Chat")).toHaveAttribute("aria-selected", "true");
  await expect(dock.getByRole("combobox", { name: "Message" })).toBeFocused();

  // ⌘. hides every panel and pressing it again restores them.
  const structure = page.getByRole("complementary", { name: "Structure" });
  await canvas(page).click({ position: { x: 20, y: 20 } });
  await page.keyboard.press(`${mod}+Period`);
  await expect(dock).toHaveCount(0);
  await expect(rail).toHaveCount(0);
  await expect(structure).toHaveCount(0);
  await page.keyboard.press(`${mod}+Period`);
  await expect(dock).toBeVisible();
  await expect(structure).toBeVisible();

  // The dock is remembered across a reload.
  await canvas(page).click({ position: { x: 20, y: 20 } });
  await page.keyboard.press(`${mod}+Backslash`);
  await expect(rail).toBeVisible();
  await page.reload();
  await expect(savedState(page)).toContainText("Saved");
  await expect(rail).toBeVisible();
});

import { expect, test, type Page } from "@playwright/test";
import { routeCanvasPage } from "./mock-canvas-pages";
import { installChatApi } from "./mock-chat-api";

// Slides themes (LAZYAGENTS-122): ten built-in themes, the Customise editor
// with live preview and a contrast warning, and saved themes (My themes) that
// can be applied, edited, renamed and deleted without changing decks.

const DECK = "88888888-8888-4888-8888-888888888888";
const at = "2026-11-11T12:00:00Z";

const deck = {
  schema: 1,
  size: { w: 1920, h: 1080 },
  theme: { name: "Light", fonts: { heading: "sans", body: "sans" }, colors: { background: "#FFFFFF", text: "#1F2328", heading: "#111418", accent: "#3B6FE0", accent2: "#E8A33D", muted: "#5F6673", surface: "#F3F5F9" } },
  assets: {},
  slides: [
    {
      id: "s_one",
      layout: "blank",
      elements: [
        { id: "e_box", type: "shape", shape: "rect", frame: { x: 200, y: 160, w: 400, h: 300 }, fill: "accent" },
        { id: "e_line", type: "line", frame: { x: 200, y: 800, w: 1200, h: 0 }, stroke: "text", strokeWidth: 6 },
      ],
    },
  ],
};

type Version = { seq: number; body: string };

async function install(page: Page) {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/slides");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const chatId = chat.id as string;
  const s = { versions: [{ seq: 1, body: JSON.stringify(deck) }] as Version[], saves: [] as { base_seq: number; body: string }[] };
  const head = () => s.versions[s.versions.length - 1];
  const json = (route: Parameters<Parameters<Page["route"]>[1]>[0], data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  await page.route(new RegExp(`/api/v1/canvases/${DECK}$`), (route) => json(route, { id: DECK, kind: "deck", title: "Controls", chat_id: chatId, chat_title: "Controls", updated_at: at, reviewed_seq: 0 }));
  await page.route(new RegExp(`/api/v1/chats/[^/]+/canvases/${DECK}(/|\\?|$)`), (route) => {
    const req = route.request();
    const p = new URL(req.url()).pathname;
    if (p.endsWith("/comments")) return json(route, { comments: [] });
    if (p.endsWith("/versions")) {
      const body = req.postDataJSON();
      s.saves.push(body);
      if (body.base_seq !== head().seq) return json(route, { code: "conflict", message: "conflict" }, 409);
      s.versions.push({ seq: head().seq + 1, body: body.body });
      return json(route, { seq: head().seq, note: "Edited", author_type: "user", created_at: at }, 201);
    }
    return json(route, {
      id: DECK, kind: "deck", title: "Controls", seq: head().seq, viewing_seq: head().seq, created_at: at, updated_at: at, body: head().body,
      versions: [...s.versions].reverse().map((v) => ({ seq: v.seq, note: "Edited", author_type: "user", created_at: at })),
    });
  });
  // The saved themes API (owner-scoped on the server), kept in memory.
  const themes: { id: string; name: string; fonts: unknown; colors: Record<string, string>; updated_at: string }[] = [];
  let n = 0;
  await page.route(/\/api\/v1\/slide-themes(\/[^/?]+)?(\?.*)?$/, (route) => {
    const req = route.request();
    const id = new URL(req.url()).pathname.split("/slide-themes/")[1];
    if (!id && req.method() === "GET") return json(route, { themes: [...themes].sort((a, b) => a.name.localeCompare(b.name)) });
    if (!id && req.method() === "POST") {
      const body = req.postDataJSON();
      if (themes.some((t) => t.name.toLowerCase() === body.name.toLowerCase())) return json(route, { code: "conflict", message: "You already have a theme with that name" }, 409);
      const t = { id: `11111111-1111-4111-8111-00000000000${++n}`, ...body, updated_at: at };
      themes.push(t);
      return json(route, t, 201);
    }
    const i = themes.findIndex((t) => t.id === id);
    if (i < 0) return json(route, { code: "not_found", message: "not found" }, 404);
    if (req.method() === "PATCH") {
      themes[i] = { ...themes[i], ...req.postDataJSON() };
      return json(route, themes[i]);
    }
    themes.splice(i, 1);
    return route.fulfill({ status: 204 });
  });
  await routeCanvasPage(page, { id: DECK, kind: "deck", title: "Deck" });
  await page.goto(`/apps/slides/${DECK}`);
  const saved = () => JSON.parse(head().body) as { slides: { elements: Record<string, unknown>[] }[] };
  const element = (id: string) => saved().slides[0].elements.find((e) => e.id === id)!;
  const theme = () => (JSON.parse(head().body) as { theme: { name: string; fonts: Record<string, string>; colors: Record<string, string> } }).theme;
  return { s, element, themes, theme };
}

const themeMenu = (page: Page) => page.getByRole("toolbar", { name: "Slide formatting" }).getByRole("button", { name: "Deck theme" });

test("the theme menu lists ten built-in themes and applies one", async ({ page }) => {
  const { theme } = await install(page);
  await themeMenu(page).click();
  for (const name of ["Light", "Dark", "Paper", "Contrast", "Dusk", "Ocean", "Forest", "Sunset", "Mono", "Blueprint"]) {
    await expect(page.getByRole("menuitem", { name, exact: true })).toBeVisible();
  }
  await expect(page.getByText("Save a customised theme to reuse it in every deck.")).toBeVisible();
  await page.getByRole("menuitem", { name: "Ocean", exact: true }).click();
  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v2/, { timeout: 5000 });
  expect(theme().name).toBe("Ocean");
  expect(theme().colors.background).toBe("#0B2540");
  await expect(themeMenu(page)).toHaveText(/Theme: Ocean/);
});

test("customise, save, apply, rename and delete a theme", async ({ page }) => {
  const { theme, themes } = await install(page);
  await themeMenu(page).click();
  await page.getByRole("menuitem", { name: "Customise current theme…" }).click();
  const editor = page.getByTestId("theme-editor");
  await expect(editor.getByRole("img", { name: "Theme preview" })).toBeVisible();
  await expect(editor.getByTestId("contrast-warning")).toHaveCount(0);

  // A low-contrast muted colour warns; a malformed hex isn't applied.
  const muted = editor.getByRole("textbox", { name: "Muted hex" });
  await muted.fill("#nothex");
  await expect(muted).toHaveAttribute("aria-invalid", "true");
  await muted.fill("#CCCCCC");
  await expect(editor.getByTestId("contrast-warning")).toContainText("Muted on Background");
  await editor.getByRole("textbox", { name: "Accent hex" }).fill("#E4572E");
  await editor.getByRole("radio", { name: "Serif" }).first().click();
  await editor.getByRole("textbox", { name: "Theme name" }).fill("Acme brand");
  await editor.getByRole("button", { name: "Save as theme" }).click();
  await expect(editor).toHaveCount(0);
  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v2/, { timeout: 5000 });
  expect(themes.map((t) => t.name)).toEqual(["Acme brand"]);
  expect(theme()).toMatchObject({ name: "Acme brand", fonts: { heading: "serif" }, colors: { accent: "#E4572E", muted: "#CCCCCC" } });

  // Rename it from My themes.
  await themeMenu(page).click();
  await page.getByRole("menuitem", { name: "Edit or rename Acme brand" }).click();
  await editor.getByRole("textbox", { name: "Theme name" }).fill("Acme 2026");
  await editor.getByRole("button", { name: "Update theme" }).click();
  await expect(editor).toHaveCount(0);
  expect(themes[0].name).toBe("Acme 2026");

  // Switch away and back.
  await themeMenu(page).click();
  await page.getByRole("menuitem", { name: "Dark", exact: true }).click();
  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v3/, { timeout: 5000 });
  await themeMenu(page).click();
  await page.getByRole("menuitem", { name: "Acme 2026", exact: true }).click();
  await expect(page.getByTestId("deck-save-state")).toHaveText(/Saved · v4/, { timeout: 5000 });
  expect(theme()).toMatchObject({ name: "Acme 2026", colors: { accent: "#E4572E" } });

  // Deleting it leaves the deck's copy alone.
  await themeMenu(page).click();
  await page.getByRole("menuitem", { name: "Delete Acme 2026" }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "Delete theme" }).click();
  await expect.poll(() => themes.length).toBe(0);
  await themeMenu(page).click();
  await expect(page.getByRole("menuitem", { name: "Acme 2026", exact: true })).toHaveCount(0);
  expect(theme()).toMatchObject({ name: "Acme 2026", colors: { accent: "#E4572E" } });
});

import { expect, test, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";
import { persona } from "./mock-chat-api";

// LAZYAGENTS-43: ⌘K command palette and the ? shortcut reference.
const palette = (page: Page) => page.getByRole("dialog", { name: "Search and commands" });
const input = (page: Page) => page.getByRole("combobox", { name: "Search everything" });
const results = (page: Page) => page.getByRole("listbox", { name: "Results" });

/** ⌘K right after a page load, pressed again until the palette opens: a press before the shell hydrates has no listener yet. */
async function openPalette(page: Page) {
  await expect(async () => {
    if (!(await palette(page).isVisible())) await page.keyboard.press("ControlOrMeta+k");
    await expect(palette(page)).toBeVisible({ timeout: 250 });
  }).toPass({ timeout: 10_000 });
}

async function install(page: Page) {
  const api = await installBoardApi(page);
  const searches: string[] = [];
  const chats: unknown[] = [];
  // Registered after the board mock, so these win for their paths.
  await page.route("**/api/v1/search?**", (route) => {
    const url = new URL(route.request().url());
    searches.push(url.search);
    const q = url.searchParams.get("q") ?? "";
    if (q !== "deploy") return route.fulfill({ json: { hits: [] } });
    return route.fulfill({
      json: {
        hits: [
          { target: { kind: "agent", id: "agent-deployer", title: "Deployer", href: "/agents/deployer" }, snippet: "", score: 0 },
          { target: { kind: "ticket", id: "ticket-1", title: "Deploy staging", display_id: "WEB-1", href: "/tickets/WEB-1" }, snippet: "", score: 3 },
          { target: { kind: "artifact", artifact_type: "note", id: "page-1", title: "Deploy runbook", path: "Payments/Deploy runbook", href: "/wiki/Payments/Deploy%20runbook" }, snippet: "", score: 2 },
          { target: { kind: "artifact", artifact_type: "adr", id: "adr-1", title: "Blue/green deploys", display_id: "ADR-014", href: "/artifacts/adr-1" }, snippet: "", score: 1 },
          { target: { kind: "chat", id: "chat-9", title: "Why did the deploy fail?", href: "/chat/chat-9" }, snippet: "", score: 0 },
        ],
      },
    });
  });
  await page.route("**/api/v1/chats", (route) => {
    if (route.request().method() !== "POST") return route.fallback();
    chats.push(route.request().postDataJSON());
    return route.fulfill({ status: 201, json: { id: "chat-new" } });
  });
  return { api, searches, chats };
}

test("⌘K opens from any screen, Esc closes it and focus returns", async ({ page }) => {
  await install(page);
  await page.goto("/board?project=WEB");
  const tickets = page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Tickets", exact: true });
  await tickets.focus();
  await openPalette(page);
  await expect(palette(page)).toBeVisible();
  await expect(input(page)).toBeFocused();
  await expect(input(page)).toHaveAttribute("aria-controls", "command-results");
  await expect(input(page)).toHaveAttribute("aria-autocomplete", "list");
  await page.keyboard.press("Escape");
  await expect(palette(page)).toBeHidden();
  await expect(tickets).toBeFocused();
});

test("a ticket key jumps to it and is listed under Recent next time", async ({ page }) => {
  await install(page);
  await page.goto("/board?project=WEB");
  await openPalette(page);
  await input(page).fill("web-3");
  const jump = results(page).getByRole("group", { name: "Jump to" }).getByRole("option");
  await expect(jump).toHaveText(/Open WEB-3/);
  await expect(jump).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/tickets\/WEB-3$/);

  await page.keyboard.press("ControlOrMeta+k");
  await expect(results(page).getByRole("group", { name: "Recent" }).getByRole("option")).toHaveText([/WEB-3/]);
});

test("an item opened any way, not only from ⌘K, is listed under Recent", async ({ page }) => {
  await install(page);
  await page.goto("/tickets/WEB-1");
  await expect(page.getByRole("heading", { name: "Build ticket modal" })).toBeVisible();
  await page.goto("/settings");
  await openPalette(page);
  await expect(results(page).getByRole("group", { name: "Recent" }).getByRole("option")).toHaveText([/Build ticket modal/]);
});

test("free text returns grouped results from the server with keyboard navigation", async ({ page }) => {
  const { searches } = await install(page);
  await page.goto("/board?project=WEB");
  await openPalette(page);
  await input(page).fill("deploy");
  for (const [group, text] of [
    ["Tickets", /Deploy staging/], ["Pages", /Payments\/Deploy runbook/], ["Artifacts", /Blue\/green deploys/],
    ["Chats", /Why did the deploy fail\?/], ["Agents", /Deployer/],
  ] as const) await expect(results(page).getByRole("group", { name: group }).getByRole("option")).toHaveText([text]);
  await page.screenshot({ path: "/tmp/palette-results.png" });
  // Groups render in the mockup's order regardless of server order.
  await expect(results(page).getByRole("group")).toHaveCount(6);
  await expect(results(page).getByRole("group").first()).toHaveAccessibleName("Tickets");
  // Scoped to the URL's project and searched once typing paused (no fetch-everything).
  expect(searches.at(-1)).toBe("?q=deploy&project=WEB");

  const options = results(page).getByRole("option");
  await expect(options.first()).toHaveAttribute("aria-selected", "true");
  await page.keyboard.press("ArrowDown");
  await expect(options.nth(1)).toHaveAttribute("aria-selected", "true");
  await expect(input(page)).toHaveAttribute("aria-activedescendant", (await options.nth(1).getAttribute("id"))!);
  await page.keyboard.press("ArrowUp");
  await page.keyboard.press("ArrowUp");
  await expect(options.last()).toHaveAttribute("aria-selected", "true");

  await page.keyboard.press("Home");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("ArrowDown");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/artifacts\/adr-1$/);
});

test("Enter waits for results instead of falling through to an action", async ({ page }) => {
  await install(page);
  await page.goto("/tickets?layout=board&project=WEB");
  await openPalette(page);
  await input(page).fill("deploy");
  await page.keyboard.press("Enter");
  await expect(palette(page)).toBeVisible();
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=WEB$/);
  await expect(results(page).getByRole("option").first()).toHaveText(/Deploy staging/);
});

test("a persona's name offers a new chat with them as the top result", async ({ page }) => {
  await install(page);
  const laura = persona(1, { name: "Laura" });
  const lauren = persona(2, { name: "Lauren" });
  await page.route("**/api/v1/personas", (route) => route.fulfill({ json: { personas: [lauren, laura, persona(3, { name: "Health Coach" })] } }));
  await page.goto("/board?project=WEB");
  await openPalette(page);
  await input(page).fill("laura");
  const top = results(page).getByRole("group", { name: "Top result" }).getByRole("option");
  await expect(top).toHaveText([/Chat with Laura.*new chat/]);
  await expect(top).toHaveAttribute("aria-selected", "true");
  await expect(results(page).getByRole("group", { name: "Start a chat" })).toHaveCount(0);

  await input(page).fill("lau");
  await expect(top).toHaveText([/Chat with Lauren/]);
  await expect(results(page).getByRole("group", { name: "Start a chat" }).getByRole("option")).toHaveText([/Chat with Laura/]);

  // Matched locally, so ↵ takes it without waiting for the search.
  await input(page).fill("chat with coach");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(new RegExp(`/chat\\?new&persona=${persona(3).id}$`));
});

test("an app's name jumps to the app, and apps lists them all", async ({ page }) => {
  await install(page);
  await page.goto("/board?project=WEB");
  await openPalette(page);
  await input(page).fill("apps");
  await expect(results(page).getByRole("group", { name: "Top result" }).getByRole("option")).toHaveText([/Knowledge/]);
  await expect(results(page).getByRole("group", { name: "Apps" }).getByRole("option")).toHaveText([/Finance/, /Library/, /Workflows/, /Scheduled/, /Learn/, /Reports/]);

  await input(page).fill("finance");
  await expect(results(page).getByRole("group", { name: "Top result" }).getByRole("option")).toHaveText([/Finance.*app/]);
  // Offered once: not again under Go to.
  await expect(results(page).getByRole("option", { name: /Go to Finance/ })).toHaveCount(0);
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/apps\/finance$/);
});

test("actions: new ticket, start planning, new chat and switch project", async ({ page }) => {
  const { chats } = await install(page);
  await page.goto("/tickets?layout=board&project=WEB");
  const run = async (query: string, option: RegExp) => {
    await openPalette(page);
    await input(page).fill(query);
    await results(page).getByRole("group", { name: "Actions" }).getByRole("option", { name: option }).click();
  };

  await run("deploy", /^New ticket: deploy/);
  await expect(page).toHaveURL(/\/tickets\/new\?title=deploy&project=WEB$/);

  await page.goto("/tickets?layout=board&project=WEB");
  await run("deploy", /Start planning: deploy/);
  await expect(page).toHaveURL(/\/plans\?project=WEB&goal=deploy$/);

  await page.goto("/tickets/WEB-1");
  const visited: string[] = [];
  page.on("framenavigated", (f) => visited.push(f.url()));
  await run("> chat", /New chat with WEB-1 attached/);
  // The chat seeds its chips from ?attach=, then drops it from the URL.
  await expect(page).toHaveURL(/\/chat\/chat-new\?project=WEB$/);
  expect(visited.some((u) => /\/chat\/chat-new\?project=WEB&attach=ticket%3AWEB-1/.test(u))).toBe(true);
  expect(chats).toEqual([{ project: "WEB" }]);

  await page.goto("/tickets?layout=board&project=WEB");
  await run("> switch", /Switch project…/);
  await expect(page.getByRole("combobox", { name: "Switch to project" })).toBeFocused();
  await page.keyboard.type("oper");
  await page.keyboard.press("Enter");
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=OPS$/);
});

test("? opens the keyboard shortcut reference, but not while typing", async ({ page }) => {
  await install(page);
  await page.goto("/board?project=WEB");
  await page.locator("body").press("?");
  const dialog = page.getByRole("dialog", { name: "Keyboard shortcuts" });
  await expect(dialog).toBeVisible();
  await expect(dialog.getByRole("heading")).toHaveText(["Keyboard shortcuts", "Global", "Chat", "Palette", "Ticket", "Needs you tray", "Inbox"]);
  await page.keyboard.press("Escape");
  await expect(dialog).toBeHidden();

  await page.keyboard.press("ControlOrMeta+k");
  await input(page).press("?");
  await expect(input(page)).toHaveValue("?");
  await expect(dialog).toBeHidden();
});

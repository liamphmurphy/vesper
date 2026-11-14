import { expect, test, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";
import { installChatApi } from "./mock-chat-api";

// LAZYAGENTS-42: project pickers, the one menu and project states.
const nav = (page: Page) => page.getByRole("navigation", { name: "Primary" });
const switcher = (page: Page) => page.getByRole("button", { name: /^Switch project/ });
const board = (page: Page) => page.locator('[data-testid="board-screen"]:visible');

async function installWithArchived(page: Page) {
  const api = await installBoardApi(page);
  api.projects.push({ ...api.projects[0], id: "project-old", key: "OLD", name: "Legacy", archived: true });
  return api;
}

// The Chats navigator starts hidden; these tests show it where it applies.
test.beforeEach(({ page }) => page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1")));

test("switching projects from the board layout rescopes it, and is remembered", async ({ page }) => {
  const api = await installWithArchived(page);
  await page.goto("/tickets?layout=board&project=WEB");
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Web app");
  const crumbs = page.getByRole("navigation", { name: "Breadcrumb" });
  // The project is the breadcrumb's pill (the switcher itself), not a link.
  await expect(crumbs.getByRole("button", { name: "Switch project, current: Web app" })).toBeVisible();
  await expect(crumbs.locator('[aria-current="page"]')).toHaveText("Tickets");
  const layouts = page.getByRole("navigation", { name: "Tickets layout" });
  await expect(layouts.getByRole("link")).toHaveText(["List", "Board", "Epics"]);
  await expect(layouts.locator('[aria-current="page"]')).toHaveText("Board");
  await expect(nav(page).locator('[aria-current="page"]')).toHaveAccessibleName("Tickets");

  await switcher(page).click();
  // Radix names the menu after its trigger.
  const menu = page.getByRole("menu", { name: /^Switch project/ });
  // Archived projects are never offered, and the board shows one project at a time.
  await expect(menu.getByRole("menuitemradio")).toHaveText([/Web app/, /Operations/]);
  await expect(menu.getByRole("menuitemradio", { name: /^Web app/ })).toHaveAttribute("aria-checked", "true");
  await menu.getByRole("menuitemradio", { name: /^Operations/ }).click();

  await expect(page).toHaveURL(/\/tickets\?layout=board&project=OPS$/);
  await expect(board(page).getByText("No tickets", { exact: true })).toHaveCount(5);
  expect(api.boardRequests.at(-1)).toContain("/projects/OPS/board");
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Operations");
  // The project carries across layouts.
  await expect(layouts.getByRole("link", { name: "List" })).toHaveAttribute("href", "/tickets?project=OPS");
  await expect(layouts.getByRole("link", { name: "Epics" })).toHaveAttribute("href", "/tickets?layout=epics&project=OPS");

  // No project in the URL resolves to the remembered one; the old /board URL lands here.
  await page.goto("/board");
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=OPS$/);
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Operations");

  // With nothing remembered, the board asks for a project.
  await page.evaluate(() => localStorage.removeItem("lazyagents.project"));
  await page.goto("/tickets?layout=board");
  const chooser = page.getByRole("region", { name: "Choose a project" });
  await expect(chooser.getByRole("link")).toHaveText([/Web app/, /Operations/]);
  await chooser.getByRole("link", { name: /^Web app/ }).click();
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=WEB$/);
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Web app");
  expect(api.unhandled).toEqual([]);
});

test("one column switches areas; a screen's own list takes the place of Chats", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.route("**/api/v1/runs?*", (route) => route.fulfill({ json: { runs: [], has_more: false } }));
  await page.goto("/runs");
  const menu = page.getByRole("complementary", { name: "Main menu" });
  // Runs brings its own list into the column's middle: Chats steps aside, no second column.
  await expect(menu.getByRole("complementary", { name: "Runs" })).toBeVisible();
  await expect(menu.getByRole("complementary", { name: "Chat history" })).toHaveCount(0);
  await expect(menu.getByRole("button", { name: "Search" })).toBeVisible();
  await expect(page.getByRole("radiogroup", { name: "Menu mode" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Projects & tickets" })).toHaveCount(0);
  await expect(page.getByRole("link", { name: "Chats & personas" })).toHaveCount(0);
  const work = nav(page);
  // The areas, then Apps; Inbox left the menu: the Needs you button opens the tray instead.
  const areas = page.getByRole("list", { name: "Areas" });
  const names = await areas.getByRole("link").evaluateAll((els) => els.map((e) => e.getAttribute("aria-label")));
  expect(names).toEqual(["Chat", "Runs", "Tickets", "Knowledge"]);
  await expect(page.getByRole("button", { name: /^Needs you/ })).toBeVisible();
  await expect(menu.getByRole("link", { name: "Customization" })).toHaveAttribute("href", "/customization");
  await expect(menu.getByRole("link", { name: "Settings" })).toHaveAttribute("href", "/settings");


  // Apps opens a grid to the right: Apps, then Tools, then New space.
  const apps = work.getByRole("button", { name: "Apps" });
  await expect(apps).toHaveAttribute("aria-expanded", "false");
  await apps.click();
  const flyout = page.getByRole("dialog", { name: "Apps" });
  await expect(flyout.getByRole("group", { name: "Apps" }).getByRole("link")).toHaveText([/Knowledge/, "Finance", "Library"]);
  await expect(flyout.getByRole("group", { name: "Tools" }).getByRole("link")).toHaveText(["Workflows", /Scheduled/, "Learn", "Reports"]);
  await expect(flyout.getByRole("button", { name: "New space" })).toBeVisible();
  const flyoutBox = await flyout.boundingBox();
  const appsBox = await apps.boundingBox();
  expect(flyoutBox!.x).toBeGreaterThan(appsBox!.x + appsBox!.width);
  // Arrow keys move through the grid; Esc closes and returns to the row.
  await expect(flyout.getByRole("link", { name: /^Knowledge/ })).toBeFocused();
  await page.keyboard.press("ArrowRight");
  await expect(flyout.getByRole("link", { name: "Finance" })).toBeFocused();
  // Down keeps the column: Finance is second in Apps, Scheduled second in Tools.
  await page.keyboard.press("ArrowDown");
  await expect(flyout.getByRole("link", { name: /Scheduled/ })).toBeFocused();
  await page.keyboard.press("Escape");
  await expect(flyout).toHaveCount(0);
  await expect(apps).toBeFocused();

  // Picking a tile goes there and closes the flyout; the row reads as current.
  await apps.click();
  await flyout.getByRole("link", { name: "Library" }).click();
  await expect(page).toHaveURL(/\/library$/);
  await expect(flyout).toHaveCount(0);
  await expect(apps).toHaveAttribute("aria-current", "page");
  expect(api.unhandled.filter((r) => !r.includes("/library"))).toEqual([]);
});

test("the Chat area brings back the Chats list, and the mark collapses the column to a strip on every screen", async ({ page }) => {
  await installChatApi(page);
  await page.goto("/settings");
  const menu = page.getByRole("complementary", { name: "Main menu" });
  await nav(page).getByRole("link", { name: "Chat", exact: true }).click();
  await expect(page).toHaveURL(/\/chat/);
  await expect(menu.getByRole("heading", { name: "Chats", level: 2 })).toBeVisible();
  await expect(menu.getByRole("complementary", { name: "Chat history" })).toBeVisible();
  await expect(page.getByRole("list", { name: "Areas" }).getByRole("link", { name: "Chat", exact: true })).toHaveAttribute("aria-current", "page");
  // New chat is a button-high row beside the list's title, with the history right under it.
  expect((await menu.getByRole("button", { name: "New chat" }).boundingBox())!.height).toBeLessThan(40);
  await menu.getByRole("button", { name: "Collapse sidebar" }).click();
  await expect(menu).not.toHaveAttribute("data-expanded");
  await expect(menu.getByRole("complementary", { name: "Chat history" })).toHaveCount(0);
  expect(await page.evaluate(() => localStorage.getItem("lazyagents.column-collapsed"))).toBe("1");
  // The strip keeps the same fixed items wherever you go.
  await page.goto("/settings");
  await expect(menu).not.toHaveAttribute("data-expanded");
  await expect(page.getByRole("list", { name: "Areas" }).getByRole("link")).toHaveCount(4);
  await menu.getByRole("button", { name: "Expand sidebar" }).click();
  await expect(menu).toHaveAttribute("data-expanded");
  expect(await page.evaluate(() => localStorage.getItem("lazyagents.column-collapsed"))).toBeNull();
});

test("back and forward sit at the top left of the page content, whatever its header", async ({ page }) => {
  await installBoardApi(page);
  // Settings draws a PageHeader under its TopBar: the controls come once, outside the column.
  await page.goto("/settings");
  const history = page.getByRole("group", { name: "History" });
  await expect(history).toHaveCount(1);
  await expect(page.getByRole("complementary", { name: "Main menu" }).getByRole("group", { name: "History" })).toHaveCount(0);
  // First in the content's top bar: just right of the column, on the breadcrumb's line, before it.
  const column = (await page.getByRole("complementary", { name: "Main menu" }).boundingBox())!;
  const back = (await history.getByRole("button", { name: "Go back" }).boundingBox())!;
  const crumb = (await page.getByRole("navigation", { name: "Breadcrumb" }).boundingBox())!;
  expect(back.x).toBeGreaterThanOrEqual(column.x + column.width);
  expect(back.x).toBeLessThan(column.x + column.width + 40);
  expect(back.x).toBeLessThan(crumb.x);
  expect(Math.abs(back.y + back.height / 2 - (crumb.y + crumb.height / 2))).toBeLessThan(4);
  // Reports is a tool now, in the Apps flyout.
  await nav(page).getByRole("button", { name: "Apps" }).click();
  await page.getByRole("dialog", { name: "Apps" }).getByRole("link", { name: "Reports" }).click();
  await expect(page).toHaveURL(/\/reports/);
  await history.getByRole("button", { name: "Go back" }).click();
  await expect(page).toHaveURL(/\/settings$/);
  await history.getByRole("button", { name: "Go forward" }).click();
  await expect(page).toHaveURL(/\/reports/);
});

test("back and forward keep your place across Tickets layouts", async ({ page }) => {
  await installBoardApi(page);
  await page.goto("/tickets?layout=board&project=WEB");
  const history = page.getByRole("group", { name: "History" });
  await expect(history.getByRole("button", { name: "Go forward" })).toBeDisabled();
  await page.getByRole("navigation", { name: "Tickets layout" }).getByRole("link", { name: "List" }).click();
  await expect(page).toHaveURL(/\/tickets\?project=WEB$/);
  await history.getByRole("button", { name: "Go back" }).click();
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=WEB$/);
  await expect(history.getByRole("button", { name: "Go forward" })).toBeEnabled();
  await history.getByRole("button", { name: "Go forward" }).click();
  await expect(page).toHaveURL(/\/tickets\?project=WEB$/);
});

test("an archived or unknown project shows an explicit empty state with a way back", async ({ page }) => {
  const api = await installWithArchived(page);
  await page.goto("/tickets?layout=board&project=OPS");
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Operations");

  await page.goto("/tickets?layout=board&project=OLD");
  await expect(page.getByRole("heading", { name: "Project unavailable" })).toBeVisible();
  await expect(page.getByText("OLD is archived. Restore it in Settings to work on it here.")).toBeVisible();
  await expect(page.getByRole("link", { name: "Manage projects" })).toHaveAttribute("href", "/settings/projects");
  // Back keeps the layout.
  await page.getByRole("link", { name: "Back to Operations" }).click();
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=OPS$/);

  await page.goto("/tickets?layout=board&project=NOPE");
  await expect(page.getByText("No project with the key NOPE.")).toBeVisible();
  // Unavailable projects are never remembered.
  expect(await page.evaluate(() => localStorage.getItem("lazyagents.project"))).toBe("OPS");
  expect(api.boardRequests.some((u) => /OLD|NOPE/.test(u))).toBe(false);
  expect(api.unhandled).toEqual([]);
});

test("Needs you and Runs nav counts refresh on live updates", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/tickets?layout=board&project=WEB");
  const inbox = page.getByRole("button", { name: /^Needs you/ });
  const runs = nav(page).getByRole("link", { name: /^Runs/ });
  await expect(inbox).toHaveAccessibleName("Needs you, nothing waiting");
  await expect(runs).toHaveAccessibleName("Runs");
  // Unread Updates never reach the badge: only needs_you counts.
  api.counts.inbox = 5;
  api.counts.needs_you = 2;
  api.runner.busy = 1;
  api.runner.live = 1;
  await api.emit("run.started");
  await expect(inbox).toHaveAccessibleName("Needs you, 2 waiting");
  await expect(runs).toHaveAccessibleName(/^Runs\s*1\s*running$/);
  expect(api.unhandled).toEqual([]);
});

test("Runs lists live work and marks the nav item current", async ({ page }) => {
  const api = await installBoardApi(page);
  api.runner.busy = 1;
  const agent = { id: "agent-builder", name: "Builder", handle: "builder", color_index: 0 };
  const listed = [{
    id: "11111111-1111-4111-8111-111111111111", ticket_key: "WEB-1", purpose: "ticket", work_title: "Build ticket modal", project_key: "WEB",
    agent, mode: "managed", state: "running", harness: "claude-code", model: "opus", started_at: new Date().toISOString(),
    tool_calls: 0, input_tokens: 0, output_tokens: 0, cost_usd: 0, plan: [], scopes: [], approval_scopes: [],
  }];
  await page.route("**/api/v1/runs?*", (route) => route.fulfill({ json: { runs: listed, has_more: false } }));
  await page.route("**/api/v1/runs/11111111-1111-4111-8111-111111111111?*", (route) => route.fulfill({ json: { run: listed[0], child_runs: [], turns: [], approvals: [], events: [] } }));
  await page.goto("/runs");
  // /runs opens the first live run beside the list.
  await expect(page).toHaveURL(/\/runs\/11111111-1111-4111-8111-111111111111$/);
  await expect(page.getByRole("list", { name: "Areas" }).locator('[aria-current="page"]')).toHaveAccessibleName(/^Runs/);
  const list = page.getByRole("complementary", { name: "Runs" });
  await expect(list.getByRole("status")).toContainText("1 busy · 0 queued · 3 slots");
  const running = list.getByRole("region", { name: "Running" });
  await expect(running.getByRole("listitem")).toHaveCount(1);
  await expect(running).toContainText("WEB-1 · Builder");
  await expect(running.getByRole("link", { name: /Build ticket modal/ })).toHaveAttribute("href", "/runs/11111111-1111-4111-8111-111111111111");
  expect(api.unhandled).toEqual([]);
});

test("cross-project links keep all projects while bare routes use the remembered one", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/tickets?layout=board&project=OPS");
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Operations");

  // e.g. an agent's "Review assigned tickets" link: not narrowed to OPS.
  await page.goto("/tickets?view=all&assignee=builder");
  await expect(page.getByRole("link", { name: "Build ticket modal" })).toBeVisible();
  await expect(page).toHaveURL(/\/tickets\?view=all&assignee=builder$/);
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: All projects");

  // Opening the route itself resolves to the remembered project.
  await page.goto("/tickets");
  await expect(page).toHaveURL(/\/tickets\?project=OPS$/);
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Operations");
  expect(api.unhandled).toEqual([]);
});

test("a stale remembered project is replaced by the valid project in the URL", async ({ page }) => {
  const api = await installWithArchived(page);
  await page.addInitScript(() => {
    if (!sessionStorage.getItem("seeded")) {
      localStorage.setItem("lazyagents.project", "OLD");
      sessionStorage.setItem("seeded", "1");
    }
  });
  await page.goto("/tickets?layout=board&project=WEB");
  await expect(switcher(page)).toHaveAccessibleName("Switch project, current: Web app");
  await expect.poll(() => page.evaluate(() => localStorage.getItem("lazyagents.project"))).toBe("WEB");
  // And the bare route now resolves to it.
  await page.goto("/tickets?layout=board");
  await expect(page).toHaveURL(/\/tickets\?layout=board&project=WEB$/);
  expect(api.unhandled).toEqual([]);
});

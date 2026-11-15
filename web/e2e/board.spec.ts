import { expect, test, type Page } from "@playwright/test";
import { installBoardApi } from "./mock-board-api";

const screen = (page: Page) => page.locator('[data-testid="board-screen"]:visible');
const card = (page: Page, key = "WEB-1") => screen(page).getByRole("article", { name: `Ticket ${key}`, exact: true });
const column = (page: Page, status: string) => screen(page).getByTestId(`column-${status}`);
async function switchProject(page: Page, name: string) {
  await page.getByRole("button", { name: /^Switch space/ }).click();
  await page.getByRole("menuitemradio", { name: new RegExp(`^${name}`) }).click();
}
async function move(page: Page, key: string, to: string) {
  await card(page, key).getByRole("button", { name: `Move ${key} to…` }).click();
  await page.getByRole("menuitem", { name: to, exact: true }).click();
}

// The menu starts as an icon rail; these tests use what the expanded menu shows.
test.beforeEach(({ page }) => page.addInitScript(() => localStorage.setItem("lazyagents.sidebar-expanded", "1")));

test("renders agreed columns, card anatomy, navigation and empty states", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  for (const s of ["backlog", "todo", "in_progress", "in_review", "done"]) await expect(column(page, s)).toBeVisible();
  await expect(column(page, "canceled")).toHaveCount(0);
  await expect(card(page)).toContainText("Build ticket modal");
  await expect(card(page)).toContainText("High");
  await expect(card(page)).toContainText("3 pt");
  await expect(card(page)).toContainText("Builder");
  await expect(card(page)).toContainText("Blocked");
  await expect(card(page).getByLabel("1 of 1 criteria met")).toBeVisible();
  await expect(card(page, "WEB-2")).not.toContainText("unestimated");
  await expect(card(page, "WEB-2")).toContainText("Unassigned");
  await expect(card(page, "WEB-3")).not.toContainText("Blocked");
  await expect(card(page).getByRole("link", { name: "WEB-1" })).toHaveAttribute("href", "/tickets/WEB-1");
  await expect(card(page).getByRole("link", { name: "Build ticket modal" })).toBeVisible();
  // The old /board URL is Tickets' board layout.
  await expect(page).toHaveURL(/\/tickets\?(?=.*layout=board)(?=.*project=WEB)/);
  await expect(page.getByRole("navigation", { name: "Primary" }).getByRole("link", { name: "Work", exact: true })).toHaveAttribute("aria-current", "page");
  await expect(page.getByRole("navigation", { name: "Tickets layout" }).getByRole("link", { name: "Board" })).toHaveAttribute("aria-current", "page");
  await switchProject(page, "Operations");
  await expect(screen(page).getByText("No tickets", { exact: true })).toHaveCount(5);
  expect(api.unhandled).toEqual([]);
});

test("epic filter shows points, criteria and blockers, and assignee/canceled filters reach the API", async ({ page }, testInfo) => {
  const api = await installBoardApi(page);
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/board?project=WEB");
  const workNav = page.getByRole("navigation", { name: "Work", exact: true });
  await workNav.getByRole("group", { name: "Board epics" }).getByRole("button", { name: "Kanban board" }).click();
  const summary = screen(page).getByRole("region", { name: "Epic summary" });
  await expect(summary).toContainText("Kanban board");
  await expect(summary).toContainText("5 / 10 pts done");
  await expect(summary).toContainText("1 / 2 met");
  await expect(summary).toContainText("Board shows all statuses");
  await expect(summary).toContainText("Cards can move");
  await expect(summary.getByRole("region", { name: "Done blockers" }).getByRole("list", { name: "Unchecked criteria" })).toHaveText("2. Cards can move");
  await expect(summary.getByRole("button", { name: "Mark epic done" })).toBeDisabled();
  await expect(card(page, "WEB-4")).toHaveCount(0);
  await page.screenshot({ path: testInfo.outputPath("board.png"), fullPage: true });
  await workNav.getByRole("button", { name: "Persona: All personas" }).click();
  await page.getByRole("menuitemradio", { name: "Builder" }).click();
  await expect(card(page, "WEB-2")).toHaveCount(0);
  await expect(card(page)).toBeVisible();
  await workNav.getByRole("button", { name: "Persona: Builder" }).click();
  await page.getByRole("menuitemradio", { name: "All personas" }).click();
  await screen(page).getByRole("switch", { name: "Show canceled" }).click();
  await expect(screen(page).getByRole("switch", { name: "Show canceled" })).toBeChecked();
  await expect(column(page, "canceled").getByRole("article", { name: "Ticket WEB-6" })).toBeVisible();
  const url = new URL(api.boardRequests.at(-1)!);
  expect(url.searchParams.get("epic")).toBe("epic-1");
  expect(url.searchParams.get("include_canceled")).toBe("true");
  await switchProject(page, "Operations");
  await expect(page).not.toHaveURL(/epic=/);
  await expect(summary).toHaveCount(0);
  expect(api.unhandled).toEqual([]);
});

test("canceled dependencies remain blockers until done", async ({ page }) => {
  const api = await installBoardApi(page);
  api.tickets[0].blocked_by[0].status = "canceled";
  await page.goto("/board?project=WEB");
  await expect(card(page)).toContainText("Blocked");
  api.tickets[0].blocked_by[0].status = "done";
  await api.emit("ticket.updated");
  await expect(card(page)).not.toContainText("Blocked");
});

test("keyboard Move to menu optimistically PATCHes status plus detail revision", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  const release = api.holdNextPatch();
  await card(page).focus();
  await page.keyboard.press("Space");
  const target = page.getByRole("menuitem", { name: "In Progress", exact: true });
  await target.focus();
  await page.keyboard.press("Enter");
  await expect(column(page, "in_progress").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
  await expect(card(page).getByRole("button", { name: "Move WEB-1 to…" })).toBeDisabled();
  await expect.poll(() => api.patches).toEqual([{ key: "WEB-1", body: { status: "in_progress", revision: 1 } }]);
  release();
  await expect(card(page)).toHaveAttribute("aria-busy", "false");
  expect(api.tickets[0].status).toBe("in_progress");
  expect(api.unhandled).toEqual([]);
});

test("native drag to another column PATCHes and persists", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await card(page).dragTo(column(page, "in_review"));
  await expect(column(page, "in_review").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
  await expect(card(page)).toHaveAttribute("aria-busy", "false");
  expect(api.patches).toEqual([{ key: "WEB-1", body: { status: "in_review", revision: 1 } }]);
  await page.reload();
  await expect(column(page, "in_review").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
});

for (const status of [409, 422]) test(`${status} rolls back optimistic move and displays the server message`, async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  const release = api.holdNextPatch();
  const message = status === 409 ? "Ticket changed elsewhere; refresh and retry" : "This transition is not allowed";
  api.rejectNext(status, message);
  await move(page, "WEB-1", "Done");
  await expect(column(page, "done").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
  await expect.poll(() => api.patches.length).toBe(1);
  release();
  // A conflict is a toast (the board refetched, so it only explains the snap-back); other errors stay inline.
  const alert = status === 409 ? page.getByRole("region", { name: "Notifications" }).getByText("WEB-1 changed elsewhere").locator("../..") : screen(page).getByRole("alert").filter({ hasText: message });
  await expect(alert).toContainText(message);
  if (status === 409) await expect(alert).toContainText("WEB-1 changed elsewhere");
  await expect(column(page, "todo").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
  await expect(column(page, "done").getByRole("article", { name: "Ticket WEB-1" })).toHaveCount(0);
  await expect(card(page)).toHaveAttribute("aria-busy", "false");
  expect(api.tickets[0].status).toBe("todo");
  await alert.getByRole("button", { name: status === 409 ? "Dismiss notification" : "Dismiss move error" }).click();
  await expect(alert).toHaveCount(0);
});

test("stale displayed card is refreshed without sending a PATCH", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  await expect(card(page)).toBeVisible();
  api.editTicket("WEB-1", { status: "in_review", title: "Agent changed this" });
  await move(page, "WEB-1", "Done");
  await expect(page.getByRole("region", { name: "Notifications" })).toContainText("Ticket changed elsewhere");
  await expect(column(page, "in_review").getByRole("article", { name: "Ticket WEB-1" })).toContainText("Agent changed this");
  expect(api.patches).toEqual([]);
});

test("an intervening revision change rejects PATCH and keeps the newer server status", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  const release = api.holdNextPatch();
  await move(page, "WEB-1", "Done");
  await expect.poll(() => api.patches.length).toBe(1);
  api.editTicket("WEB-1", { status: "in_review" });
  release();
  await expect(page.getByRole("region", { name: "Notifications" })).toContainText("Revision changed elsewhere");
  await expect(column(page, "in_review").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
  expect(api.tickets[0].status).toBe("in_review");
});

test("ticket.updated, epic.updated and reset refetch without a page reload", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB&epic=epic-1");
  await expect(card(page)).toBeVisible();
  await page.evaluate(() => Object.assign(window, { __stillHere: true }));
  api.editTicket("WEB-1", { status: "done", title: "Updated by agent" });
  await api.emit("ticket.updated");
  await expect(column(page, "done").getByRole("article", { name: "Ticket WEB-1" })).toContainText("Updated by agent");
  await expect(screen(page).getByRole("region", { name: "Epic summary" })).toContainText("8 / 10 pts done");
  api.criteria[1].done = true;
  await api.emit("epic.updated");
  await expect(screen(page).getByRole("region", { name: "Epic summary" })).toContainText("2 / 2 met");
  api.editTicket("WEB-2", { title: "After reset" });
  await api.emit("reset");
  await expect(card(page, "WEB-2")).toContainText("After reset");
  expect(await page.evaluate(() => (window as unknown as { __stillHere: boolean }).__stillHere)).toBe(true);
});

test("SSE during a rejected move preserves unrelated edits and independent pending moves", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  const release = api.holdNextPatch();
  await move(page, "WEB-1", "Done");
  await expect.poll(() => api.patches.length).toBe(1);
  api.editTicket("WEB-2", { title: "External edit survives" });
  await api.emit("ticket.updated");
  await expect(card(page, "WEB-2")).toContainText("External edit survives");
  await expect(column(page, "done").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
  // Commit the second card while the first remains in flight.
  await move(page, "WEB-2", "In Progress");
  await expect(card(page, "WEB-2")).toHaveAttribute("aria-busy", "false");
  api.rejectNext(409, "First move conflicted");
  release();
  await expect(column(page, "todo").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
  await expect(column(page, "in_progress").getByRole("article", { name: "Ticket WEB-2" })).toContainText("External edit survives");
});

test("an in-flight move cannot leak into another project view", async ({ page }) => {
  const api = await installBoardApi(page);
  await page.goto("/board?project=WEB");
  const release = api.holdNextPatch();
  await move(page, "WEB-1", "Done");
  await expect.poll(() => api.patches.length).toBe(1);
  await switchProject(page, "Operations");
  await expect(screen(page).getByText("No tickets", { exact: true })).toHaveCount(5);
  release();
  await expect.poll(() => api.tickets[0].status).toBe("done");
  await expect(card(page)).toHaveCount(0);
  await switchProject(page, "Web app");
  await expect(column(page, "done").getByRole("article", { name: "Ticket WEB-1" })).toBeVisible();
});

test("board loading error is visible and retry recovers", async ({ page }) => {
  const api = await installBoardApi(page);
  api.failBoard(true);
  await page.goto("/board?project=WEB");
  await expect(screen(page).getByRole("alert").filter({ hasText: "Board service unavailable" })).toBeVisible({ timeout: 15000 });
  api.failBoard(false);
  await screen(page).getByRole("button", { name: "Retry", exact: true }).click();
  await expect(card(page)).toBeVisible();
});
